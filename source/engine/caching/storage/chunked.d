module engine.caching.storage.chunked;

import std.algorithm : map, filter;
import std.array : array, appender;
import std.file : exists, read, write, remove, mkdirRecurse, getSize;
import std.path : buildPath, dirName;
import core.sync.mutex : Mutex;
import engine.caching.storage.cas : ContentAddressableStorage;
import infrastructure.utils.files.cdc;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.crypto.blake3 : Blake3, toHexString;
import infrastructure.utils.crypto.merkle : MerkleTree, MerkleProof;
import infrastructure.errors;

/// Chunked Content-Addressable Storage
/// Extends CAS with automatic chunking for large blobs (>100MB)
/// Enables delta transfers with 80-95% bandwidth savings
/// 
/// Storage layout:
///   blobs/     - Small blobs (whole-file storage)
///   chunks/    - Individual chunk storage
///   manifests/ - Chunk manifests for chunked blobs
final class ChunkedCAS
{
    private ContentAddressableStorage cas;
    private FastCDC chunker;
    private string storageDir;
    private string chunksDir;
    private string manifestsDir;
    private Mutex storageMutex;
    private ChunkStats stats;
    
    /// Initialize chunked CAS
    @system
    this(string storageDir = ".builder-cache", FastCDC.Config config = FastCDC.Config.large())
    {
        this.storageDir = storageDir;
        this.chunksDir = buildPath(storageDir, "chunks");
        this.manifestsDir = buildPath(storageDir, "manifests");
        this.storageMutex = new Mutex();
        this.chunker = FastCDC(config);
        this.cas = new ContentAddressableStorage(buildPath(storageDir, "blobs"));
        
        // Ensure directories exist
        foreach (dir; [chunksDir, manifestsDir])
            if (!exists(dir)) mkdirRecurse(dir);
    }
    
    /// Store blob with automatic chunking for large data
    /// Returns blob hash
    @system
    BuildResult!string put(const(ubyte)[] data)
    {
        if (data.length == 0)
            return Ok!(string, BuildError)("");
        
        // Small blobs: use standard CAS
        if (!shouldChunk(data.length))
            return cas.putBlob(data);
        
        // Large blobs: chunk and store
        return putChunked(data);
    }
    
    /// Get blob, reassembling from chunks if needed
    @system
    BuildResult!(ubyte[]) get(string blobHash)
    {
        // Check for manifest (chunked blob)
        auto manifestPath = getManifestPath(blobHash);
        
        synchronized (storageMutex)
        {
            if (exists(manifestPath))
                return getChunked(blobHash, manifestPath);
        }
        
        // Small blob: direct CAS lookup
        return cas.getBlob(blobHash);
    }
    
    /// Check if blob exists
    @system
    bool has(string blobHash)
    {
        synchronized (storageMutex)
        {
            return exists(getManifestPath(blobHash)) || cas.hasBlob(blobHash);
        }
    }
    
    /// Get manifest for chunked blob (for delta transfer)
    @system
    BuildResult!ChunkManifest getManifest(string blobHash)
    {
        auto manifestPath = getManifestPath(blobHash);
        
        synchronized (storageMutex)
        {
            if (!exists(manifestPath))
                return Err!(ChunkManifest, BuildError)(Errors.cache(
                    "Manifest not found: " ~ blobHash, Cache.NotFound).build());
            
            auto data = cast(ubyte[])read(manifestPath);
            auto result = ChunkManifest.deserialize(data);
            if (result.isErr)
                return Err!(ChunkManifest, BuildError)(Errors.cache(
                    result.unwrapErr(), Cache.LoadFailed).build());
            
            return Ok!(ChunkManifest, BuildError)(result.unwrap());
        }
    }
    
    /// Store individual chunk (for incremental upload)
    @system
    VoidBuildResult putChunk(const(ubyte)[] data, ubyte[32] expectedHash)
    {
        // Verify hash
        auto hasher = Blake3(0);
        hasher.put(data);
        auto actualHash = hasher.finish(32)[0 .. 32];
        
        if (actualHash != expectedHash)
            return VoidBuildResult.err(Errors.cache(
                "Chunk hash mismatch", Cache.Corrupted).build());
        
        auto path = getChunkPath(expectedHash);
        
        synchronized (storageMutex)
        {
            if (!exists(path))
            {
                auto dir = dirName(path);
                if (!exists(dir)) mkdirRecurse(dir);
                write(path, data);
                stats.chunksStored++;
                stats.chunkBytesStored += data.length;
            }
            else
            {
                stats.chunkHits++;
            }
        }
        
        return Ok!BuildError();
    }
    
    /// Get individual chunk
    @system
    BuildResult!(ubyte[]) getChunk(ubyte[32] hash)
    {
        auto path = getChunkPath(hash);
        
        synchronized (storageMutex)
        {
            if (!exists(path))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "Chunk not found: " ~ toHexString(hash[]),
                    Cache.NotFound).build());
            
            return Ok!(ubyte[], BuildError)(cast(ubyte[])read(path));
        }
    }
    
    /// Check which chunks are missing (for delta upload)
    @system
    ubyte[32][] findMissingChunks(const(ubyte[32])[] hashes)
    {
        auto missing = appender!(ubyte[32][])();
        
        synchronized (storageMutex)
        {
            foreach (h; hashes)
                if (!exists(getChunkPath(h)))
                    missing ~= h;
        }
        
        return missing[];
    }
    
    /// Store manifest and mark blob as chunked
    @system
    VoidBuildResult storeManifest(string blobHash, ref const ChunkManifest manifest)
    {
        auto path = getManifestPath(blobHash);
        
        synchronized (storageMutex)
        {
            auto dir = dirName(path);
            if (!exists(dir)) mkdirRecurse(dir);
            write(path, manifest.serialize());
            stats.manifestsStored++;
        }
        
        return Ok!BuildError();
    }
    
    /// Get statistics
    ChunkStats getStats() const @trusted
    {
        synchronized (cast(Mutex)storageMutex)
            return stats;
    }
    
    /// Verify blob integrity using Merkle tree
    /// Returns: true if all chunks verify, false otherwise
    @system
    bool verifyBlobIntegrity(string blobHash)
    {
        auto manifestResult = getManifest(blobHash);
        if (manifestResult.isErr)
            return false;
        
        auto manifest = manifestResult.unwrap();
        return verifyManifestIntegrity(manifest);
    }
    
    /// Verify manifest integrity using Merkle tree
    @system
    bool verifyManifestIntegrity(ref const ChunkManifest manifest)
    {
        // Rebuild tree from chunks and compare root
        auto hashes = new ubyte[32][manifest.refs.length];
        
        foreach (i, ref r; manifest.refs)
        {
            auto chunkPath = getChunkPath(r.hash);
            
            synchronized (storageMutex)
            {
                if (!exists(chunkPath))
                    return false;
                
                // Verify chunk hash
                auto chunkData = cast(ubyte[])read(chunkPath);
                auto hasher = Blake3(0);
                hasher.put(chunkData);
                auto actualHash = hasher.finish(32)[0 .. 32];
                
                if (actualHash != r.hash)
                    return false;
            }
            
            hashes[i] = r.hash;
        }
        
        // Verify Merkle root
        auto tree = MerkleTree.build(hashes);
        return tree.root == manifest.merkleRoot;
    }
    
    /// Verify single chunk with Merkle proof (for partial validation)
    @system
    bool verifyChunkWithProof(string blobHash, uint chunkIndex)
    {
        auto manifestResult = getManifest(blobHash);
        if (manifestResult.isErr)
            return false;
        
        auto manifest = manifestResult.unwrap();
        if (chunkIndex >= manifest.refs.length)
            return false;
        
        // Generate proof
        auto proof = manifest.generateProof(chunkIndex);
        
        // Get chunk and verify
        auto chunkResult = getChunk(manifest.refs[chunkIndex].hash);
        if (chunkResult.isErr)
            return false;
        
        auto chunkData = chunkResult.unwrap();
        auto hasher = Blake3(0);
        hasher.put(chunkData);
        auto actualHash = hasher.finish(32)[0 .. 32];
        
        if (actualHash != manifest.refs[chunkIndex].hash)
            return false;
        
        return MerkleTree.verifyProof(proof, manifest.merkleRoot);
    }
    
    /// Find changed chunks between two blobs using Merkle tree diff
    /// Returns indices of chunks that differ (for incremental sync)
    @system
    BuildResult!(uint[]) findChangedChunks(string oldBlobHash, string newBlobHash)
    {
        auto oldManifest = getManifest(oldBlobHash);
        auto newManifest = getManifest(newBlobHash);
        
        if (oldManifest.isErr)
            return Err!(uint[], BuildError)(oldManifest.unwrapErr());
        if (newManifest.isErr)
            return Err!(uint[], BuildError)(newManifest.unwrapErr());
        
        auto old_ = oldManifest.unwrap();
        auto new_ = newManifest.unwrap();
        
        auto changed = old_.findChanged(new_);
        return Ok!(uint[], BuildError)(changed);
    }
    
    /// Generate Merkle proof for a chunk (for remote validation)
    @system
    BuildResult!MerkleProof generateChunkProof(string blobHash, uint chunkIndex)
    {
        auto manifestResult = getManifest(blobHash);
        if (manifestResult.isErr)
            return Err!(MerkleProof, BuildError)(manifestResult.unwrapErr());
        
        auto manifest = manifestResult.unwrap();
        if (chunkIndex >= manifest.refs.length)
            return Err!(MerkleProof, BuildError)(Errors.cache(
                "Chunk index out of range", Cache.NotFound).build());
        
        auto proof = manifest.generateProof(chunkIndex);
        return Ok!(MerkleProof, BuildError)(proof);
    }
    
    /// Verify a chunk against expected Merkle root (for incremental download)
    @system
    static bool verifyChunkAgainstRoot(
        const(ubyte)[] chunkData,
        ubyte[32] expectedChunkHash,
        ref const MerkleProof proof,
        ubyte[32] expectedRoot
    )
    {
        // Verify chunk hash
        auto hasher = Blake3(0);
        hasher.put(chunkData);
        auto actualHash = hasher.finish(32)[0 .. 32];
        
        if (actualHash != expectedChunkHash)
            return false;
        
        return MerkleTree.verifyProof(proof, expectedRoot);
    }
    
    /// Delete blob (removes chunks if chunked)
    @system
    VoidBuildResult remove(string blobHash)
    {
        synchronized (storageMutex)
        {
            auto manifestPath = getManifestPath(blobHash);
            
            if (exists(manifestPath))
            {
                // Remove manifest and orphaned chunks
                .remove(manifestPath);
                // Note: chunk GC should be run separately
            }
            
            return cas.deleteBlob(blobHash);
        }
    }
    
    // === Private implementation ===
    
    /// Store large blob as chunks
    @system
    private BuildResult!string putChunked(const(ubyte)[] data)
    {
        // Compute blob hash first
        immutable blobHash = FastHash.hashBytes(data);
        
        // Check if already stored
        synchronized (storageMutex)
        {
            if (exists(getManifestPath(blobHash)))
            {
                stats.blobHits++;
                return Ok!(string, BuildError)(blobHash);
            }
        }
        
        // Chunk the data
        auto result = chunker.chunkData(data);
        
        if (result.chunks.length == 0)
            return Err!(string, BuildError)(Errors.cache(
                "Chunking failed", Cache.WriteFailed).build());
        
        // Store each chunk
        foreach (ref chunk; result.chunks)
        {
            auto chunkData = data[chunk.offset .. chunk.offset + chunk.length];
            auto storeResult = putChunk(chunkData, chunk.hash);
            if (storeResult.isErr)
                return Err!(string, BuildError)(storeResult.unwrapErr());
        }
        
        // Create and store manifest
        ubyte[32] hashBytes;
        if (blobHash.length >= 64)
        {
            foreach (i; 0 .. 32)
            {
                immutable hi = hexVal(blobHash[i * 2]);
                immutable lo = hexVal(blobHash[i * 2 + 1]);
                hashBytes[i] = cast(ubyte)((hi << 4) | lo);
            }
        }
        
        auto manifest = ChunkManifest.fromResult(result, hashBytes[]);
        auto storeResult = storeManifest(blobHash, manifest);
        if (storeResult.isErr)
            return Err!(string, BuildError)(storeResult.unwrapErr());
        
        synchronized (storageMutex)
        {
            stats.chunkedBlobs++;
            stats.totalChunks += result.chunks.length;
        }
        
        return Ok!(string, BuildError)(blobHash);
    }
    
    /// Get chunked blob by reassembling
    @system
    private BuildResult!(ubyte[]) getChunked(string blobHash, string manifestPath)
    {
        // Load manifest
        auto manifestData = cast(ubyte[])read(manifestPath);
        auto parseResult = ChunkManifest.deserialize(manifestData);
        if (parseResult.isErr)
            return Err!(ubyte[], BuildError)(Errors.cache(
                parseResult.unwrapErr(), Cache.LoadFailed).build());
        
        auto manifest = parseResult.unwrap();
        
        // Allocate output buffer
        auto output = new ubyte[manifest.totalSize];
        
        // Reassemble chunks
        foreach (ref r; manifest.refs)
        {
            auto chunkPath = getChunkPath(r.hash);
            if (!exists(chunkPath))
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "Missing chunk: " ~ toHexString(r.hash[]),
                    Cache.NotFound).build());
            
            auto chunkData = cast(ubyte[])read(chunkPath);
            if (chunkData.length != r.length)
                return Err!(ubyte[], BuildError)(Errors.cache(
                    "Chunk size mismatch", Cache.Corrupted).build());
            
            output[r.offset .. r.offset + r.length] = chunkData[];
        }
        
        // Verify reassembled hash
        immutable actualHash = FastHash.hashBytes(output);
        if (actualHash != blobHash)
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Reassembled blob hash mismatch", Cache.Corrupted).build());
        
        return Ok!(ubyte[], BuildError)(output);
    }
    
    /// Get chunk storage path (sharded by first 2 bytes)
    private string getChunkPath(ubyte[32] hash) const @trusted
    {
        immutable hex = toHexString(hash[]);
        return buildPath(chunksDir, hex[0 .. 2], hex);
    }
    
    /// Get manifest path
    private string getManifestPath(string blobHash) const @safe
    {
        if (blobHash.length < 2)
            return buildPath(manifestsDir, "00", blobHash ~ ".manifest");
        return buildPath(manifestsDir, blobHash[0 .. 2], blobHash ~ ".manifest");
    }
    
    /// Convert hex char to value
    private static ubyte hexVal(char c) pure @safe nothrow @nogc
    {
        if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
        if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
        if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
        return 0;
    }
}

/// Chunked storage statistics
struct ChunkStats
{
    size_t chunkedBlobs;       // Large blobs stored as chunks
    size_t totalChunks;        // Total chunks created
    size_t chunksStored;       // Unique chunks stored
    size_t chunkBytesStored;   // Bytes in chunk storage
    size_t chunkHits;          // Chunk dedup hits
    size_t manifestsStored;    // Manifests created
    size_t blobHits;           // Full blob dedup hits
    size_t merkleVerifications;   // Successful Merkle verifications
    size_t merkleProofsGenerated; // Proofs generated for partial validation
    
    /// Chunk deduplication ratio
    double dedupRatio() const pure @safe nothrow @nogc
        => totalChunks > 0 ? 100.0 * chunkHits / totalChunks : 0.0;
}

