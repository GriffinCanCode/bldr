module engine.caching.distributed.remote.delta;

import std.algorithm : map, filter, sum, min, max;
import std.array : array, appender;
import std.bitmanip : nativeToBigEndian, bigEndianToNative;
import std.datetime : Duration, MonoTime, seconds;
import std.file : exists, read, write, mkdirRecurse;
import std.path : buildPath, dirName;
import std.conv : to;
import engine.caching.distributed.remote.artifact;
import engine.caching.storage.chunked : ChunkedCAS;
import infrastructure.utils.files.cdc : ChunkManifest, DeltaStats, FastCDC;
import infrastructure.utils.crypto.blake3 : Blake3, toHexString;
import infrastructure.utils.crypto.merkle : MerkleTree, MerkleProof;
import infrastructure.utils.compression.zstd;
import infrastructure.utils.compression.streaming : ZstdStream;
import infrastructure.errors;

/// Rolling Checksum (rsync-style Adler32 variant)
/// Uses a weak rolling hash for fast block matching + strong hash for verification
/// Enables O(1) checksum updates when sliding window by one byte
struct RollingChecksum
{
    private uint a;        // Sum of bytes
    private uint b;        // Weighted sum
    private size_t window; // Window size
    
    enum MOD = 65521;      // Largest prime < 2^16
    
    /// Initialize with window size
    static RollingChecksum create(size_t windowSize) pure @safe nothrow @nogc
    {
        RollingChecksum rc;
        rc.window = windowSize;
        return rc;
    }
    
    /// Compute initial checksum from data
    void init(const(ubyte)[] data) pure @safe nothrow @nogc
    {
        a = b = 0;
        foreach (i, byte_; data[0 .. min(window, data.length)])
        {
            a = (a + byte_) % MOD;
            b = (b + (window - i) * byte_) % MOD;
        }
    }
    
    /// Roll checksum forward by removing old byte and adding new byte
    void roll(ubyte oldByte, ubyte newByte) pure @safe nothrow @nogc
    {
        a = (a - oldByte + newByte) % MOD;
        b = (b - window * oldByte + a) % MOD;
    }
    
    /// Get current 32-bit checksum
    uint digest() const pure @safe nothrow @nogc => (b << 16) | a;
    
    /// Compute full checksum (for comparison)
    static uint full(const(ubyte)[] data) pure @safe nothrow @nogc
    {
        uint a_ = 0, b_ = 0;
        foreach (i, byte_; data)
        {
            a_ = (a_ + byte_) % MOD;
            b_ = (b_ + a_) % MOD;
        }
        return (b_ << 16) | a_;
    }
}

/// Block signature for delta computation
struct BlockSignature
{
    size_t offset;          // Block offset in original data
    uint weakHash;          // Rolling checksum (fast match)
    ubyte[32] strongHash;   // BLAKE3 hash (verification)
    
    /// Serialize signature
    ubyte[] serialize() const pure @trusted
    {
        auto buf = appender!(ubyte[])();
        buf ~= nativeToBigEndian(cast(ulong)offset)[];
        buf ~= nativeToBigEndian(weakHash)[];
        buf ~= strongHash[];
        return buf[];
    }
    
    /// Deserialize signature
    static BlockSignature deserialize(const(ubyte)[] data) pure @safe
    {
        BlockSignature sig;
        if (data.length < 44) return sig;
        
        sig.offset = bigEndianToNative!ulong(data[0 .. 8][0 .. 8]);
        sig.weakHash = bigEndianToNative!uint(data[8 .. 12][0 .. 4]);
        sig.strongHash = data[12 .. 44][0 .. 32];
        return sig;
    }
}

/// Delta instruction types
enum DeltaOp : ubyte
{
    Copy = 0,   // Copy block from base
    Insert = 1  // Insert new data
}

/// Delta instruction
struct DeltaInstruction
{
    DeltaOp op;
    size_t offset;      // Source offset (Copy) or data length (Insert)
    size_t length;      // Block length
    ubyte[] data;       // New data (Insert only)
}

/// Delta encoder using rsync algorithm
/// Produces minimal diff between old and new versions
final class RsyncDelta
{
    private size_t blockSize;
    private uint[uint] weakHashIndex;  // Weak hash -> block index
    private BlockSignature[] signatures;
    
    enum DEFAULT_BLOCK_SIZE = 4096;
    
    @system
    this(size_t blockSize = DEFAULT_BLOCK_SIZE) { this.blockSize = blockSize; }
    
    /// Generate signatures for base data (server-side)
    @system
    BlockSignature[] generateSignatures(const(ubyte)[] data)
    {
        auto sigs = appender!(BlockSignature[])();
        weakHashIndex.clear();
        
        size_t offset = 0;
        while (offset < data.length)
        {
            immutable len = min(blockSize, data.length - offset);
            auto block = data[offset .. offset + len];
            
            BlockSignature sig;
            sig.offset = offset;
            sig.weakHash = RollingChecksum.full(block);
            
            auto hasher = Blake3(0);
            hasher.put(block);
            sig.strongHash = hasher.finish(32)[0 .. 32];
            
            weakHashIndex[sig.weakHash] = cast(uint)sigs[].length;
            sigs ~= sig;
            offset += len;
        }
        
        signatures = sigs[];
        return signatures;
    }
    
    /// Compute delta from new data using signatures (client-side)
    @system
    DeltaInstruction[] computeDelta(const(ubyte)[] newData, const(BlockSignature)[] baseSigs)
    {
        // Build weak hash lookup
        uint[uint] lookup;
        foreach (i, ref sig; baseSigs)
            lookup[sig.weakHash] = cast(uint)i;
        
        auto instructions = appender!(DeltaInstruction[])();
        auto pendingInsert = appender!(ubyte[])();
        
        auto rc = RollingChecksum.create(blockSize);
        size_t pos = 0;
        
        while (pos < newData.length)
        {
            immutable remaining = newData.length - pos;
            
            if (remaining >= blockSize)
            {
                // Compute rolling checksum
                rc.init(newData[pos .. pos + blockSize]);
                auto weakHash = rc.digest();
                
                // Check for match
                if (auto idx = weakHash in lookup)
                {
                    auto sig = baseSigs[*idx];
                    
                    // Verify with strong hash
                    auto hasher = Blake3(0);
                    hasher.put(newData[pos .. pos + blockSize]);
                    auto strongHash = hasher.finish(32)[0 .. 32];
                    
                    if (strongHash == sig.strongHash)
                    {
                        // Emit pending insert
                        if (pendingInsert[].length > 0)
                        {
                            DeltaInstruction ins;
                            ins.op = DeltaOp.Insert;
                            ins.length = pendingInsert[].length;
                            ins.data = pendingInsert[].dup;
                            instructions ~= ins;
                            pendingInsert.clear();
                        }
                        
                        // Emit copy instruction
                        DeltaInstruction copy;
                        copy.op = DeltaOp.Copy;
                        copy.offset = sig.offset;
                        copy.length = blockSize;
                        instructions ~= copy;
                        
                        pos += blockSize;
                        continue;
                    }
                }
            }
            
            // No match, add to pending insert
            pendingInsert ~= newData[pos];
            pos++;
        }
        
        // Emit final pending insert
        if (pendingInsert[].length > 0)
        {
            DeltaInstruction ins;
            ins.op = DeltaOp.Insert;
            ins.length = pendingInsert[].length;
            ins.data = pendingInsert[];
            instructions ~= ins;
        }
        
        return instructions[];
    }
    
    /// Apply delta to base data (server-side)
    @system
    BuildResult!(ubyte[]) applyDelta(const(ubyte)[] baseData, const(DeltaInstruction)[] delta)
    {
        auto output = appender!(ubyte[])();
        
        foreach (ref inst; delta)
        {
            final switch (inst.op)
            {
                case DeltaOp.Copy:
                    if (inst.offset + inst.length > baseData.length)
                        return Err!(ubyte[], BuildError)(Errors.cache(
                            "Delta copy out of bounds", Cache.Corrupted).build());
                    output ~= baseData[inst.offset .. inst.offset + inst.length];
                    break;
                    
                case DeltaOp.Insert:
                    output ~= inst.data;
                    break;
            }
        }
        
        return Ok!(ubyte[], BuildError)(output[]);
    }
    
    /// Serialize delta instructions
    @system
    static ubyte[] serializeDelta(const(DeltaInstruction)[] delta)
    {
        auto buf = appender!(ubyte[])();
        buf ~= nativeToBigEndian(cast(uint)delta.length)[];
        
        foreach (ref inst; delta)
        {
            buf ~= cast(ubyte)inst.op;
            buf ~= nativeToBigEndian(cast(ulong)inst.offset)[];
            buf ~= nativeToBigEndian(cast(ulong)inst.length)[];
            
            if (inst.op == DeltaOp.Insert)
                buf ~= inst.data;
        }
        
        return buf[];
    }
    
    /// Deserialize delta instructions
    @system
    static BuildResult!(DeltaInstruction[]) deserializeDelta(const(ubyte)[] data)
    {
        if (data.length < 4)
            return Err!(DeltaInstruction[], BuildError)(Errors.cache(
                "Delta data too short", Cache.Corrupted).build());
        
        auto count = bigEndianToNative!uint(data[0 .. 4][0 .. 4]);
        auto instructions = appender!(DeltaInstruction[])();
        size_t pos = 4;
        
        foreach (_; 0 .. count)
        {
            if (pos + 17 > data.length)
                return Err!(DeltaInstruction[], BuildError)(Errors.cache(
                    "Truncated delta instruction", Cache.Corrupted).build());
            
            DeltaInstruction inst;
            inst.op = cast(DeltaOp)data[pos++];
            inst.offset = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
            inst.length = bigEndianToNative!ulong(data[pos .. pos + 8][0 .. 8]); pos += 8;
            
            if (inst.op == DeltaOp.Insert)
            {
                if (pos + inst.length > data.length)
                    return Err!(DeltaInstruction[], BuildError)(Errors.cache(
                        "Truncated insert data", Cache.Corrupted).build());
                inst.data = cast(ubyte[])data[pos .. pos + inst.length].dup;
                pos += inst.length;
            }
            
            instructions ~= inst;
        }
        
        return Ok!(DeltaInstruction[], BuildError)(instructions[]);
    }
}

/// Zstd dictionary compression for artifact families (FFI-based)
/// Trains dictionaries on similar artifacts for 30-50% better compression
/// Uses direct libzstd FFI bindings for optimal performance
final class ZstdDictionary
{
    private string dictionaryPath;
    private ubyte[] dictionary;
    private size_t dictSize;
    private ZSTD_CCtx* cctx;
    private ZSTD_DCtx* dctx;
    private ZSTD_CDict* cdict;
    private ZSTD_DDict* ddict;
    
    enum DEFAULT_DICT_SIZE = 110 * 1024;  // 110KB default
    
    @system
    this(string storagePath, size_t dictSize = DEFAULT_DICT_SIZE)
    {
        this.dictSize = dictSize;
        this.dictionaryPath = buildPath(storagePath, "zstd_dict");
        
        // Create contexts
        cctx = ZSTD_createCCtx();
        dctx = ZSTD_createDCtx();
        
        if (!exists(dirName(dictionaryPath)))
            mkdirRecurse(dirName(dictionaryPath));
        
        if (exists(dictionaryPath))
        {
            dictionary = cast(ubyte[])read(dictionaryPath);
            compileDictionary();
        }
    }
    
    ~this() @trusted
    {
        if (cctx) ZSTD_freeCCtx(cctx);
        if (dctx) ZSTD_freeDCtx(dctx);
        if (cdict) ZSTD_freeCDict(cdict);
        if (ddict) ZSTD_freeDDict(ddict);
    }
    
    /// Compile dictionary into optimized form
    private void compileDictionary() @trusted
    {
        if (dictionary.length == 0) return;
        
        if (cdict) ZSTD_freeCDict(cdict);
        if (ddict) ZSTD_freeDDict(ddict);
        
        cdict = ZSTD_createCDict(dictionary.ptr, dictionary.length, 5);
        ddict = ZSTD_createDDict(dictionary.ptr, dictionary.length);
    }
    
    /// Train dictionary on sample data using FFI
    @system
    VoidBuildResult train(const(ubyte)[][] samples)
    {
        if (samples.length == 0)
            return VoidBuildResult.err(Errors.generic("No samples for dictionary training").build());
        
        // Concatenate samples into single buffer
        size_t totalSize = 0;
        foreach (s; samples) totalSize += s.length;
        
        auto samplesBuffer = new ubyte[](totalSize);
        auto samplesSizes = new size_t[](samples.length);
        
        size_t offset = 0;
        foreach (i, sample; samples)
        {
            samplesBuffer[offset .. offset + sample.length] = sample[];
            samplesSizes[i] = sample.length;
            offset += sample.length;
        }
        
        // Train dictionary using ZDICT API
        auto dictBuffer = new ubyte[](dictSize);
        auto trainedSize = ZDICT_trainFromBuffer(
            dictBuffer.ptr, dictBuffer.length,
            samplesBuffer.ptr, samplesSizes.ptr,
            cast(uint)samples.length
        );
        
        if (ZDICT_isError(trainedSize))
            return VoidBuildResult.err(Errors.generic(
                "Dictionary training failed: " ~ 
                cast(string)ZDICT_getErrorName(trainedSize)[0..strLen(ZDICT_getErrorName(trainedSize))]
            ).build());
        
        // Save trained dictionary
        dictionary = dictBuffer[0 .. trainedSize].dup;
        write(dictionaryPath, dictionary);
        compileDictionary();
        
        return Ok!BuildError();
    }
    
    /// Compress data with dictionary using FFI
    @system
    BuildResult!(ubyte[]) compress(const(ubyte)[] data, int level = 5)
    {
        if (data.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot compress empty data").build());
        
        auto dstCapacity = ZSTD_compressBound(data.length);
        auto output = new ubyte[](dstCapacity);
        
        size_t written;
        if (cdict !is null)
        {
            written = ZSTD_compress_usingCDict(cctx, 
                output.ptr, output.length, 
                data.ptr, data.length, cdict);
        }
        else
        {
            written = ZSTD_compressCCtx(cctx, 
                output.ptr, output.length, 
                data.ptr, data.length, level);
        }
        
        if (ZSTD_isError(written))
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Zstd compression failed", Cache.CompressionFailed).build());
        
        return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
    }
    
    /// Decompress data with dictionary using FFI
    @system
    BuildResult!(ubyte[]) decompress(const(ubyte)[] data)
    {
        if (data.length == 0)
            return Err!(ubyte[], BuildError)(Errors.generic("Cannot decompress empty data").build());
        
        // Get decompressed size from frame
        auto frameSize = ZSTD_getFrameContentSize(data.ptr, data.length);
        size_t dstCapacity = (frameSize != ZSTD_CONTENTSIZE_UNKNOWN && frameSize != ZSTD_CONTENTSIZE_ERROR)
            ? cast(size_t)frameSize
            : data.length * 4;  // Heuristic
        
        auto output = new ubyte[](dstCapacity);
        
        size_t written;
        if (ddict !is null)
        {
            written = ZSTD_decompress_usingDDict(dctx, 
                output.ptr, output.length, 
                data.ptr, data.length, ddict);
        }
        else
        {
            written = ZSTD_decompressDCtx(dctx, 
                output.ptr, output.length, 
                data.ptr, data.length);
        }
        
        if (ZSTD_isError(written))
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Zstd decompression failed", Cache.CompressionFailed).build());
        
        return Ok!(ubyte[], BuildError)(output[0 .. written].dup);
    }
    
    /// Has trained dictionary
    bool hasDictionary() const @safe => dictionary.length > 0;
    
    /// Get dictionary size
    size_t getDictSize() const @safe => dictionary.length;
    
    /// Get dictionary ID (for frame verification)
    uint getDictID() const @trusted
    {
        if (dictionary.length == 0) return 0;
        return ZSTD_getDictID_fromDict(dictionary.ptr, dictionary.length);
    }
}

// Helper to get null-terminated string length
private size_t strLen(const(char)* s) @trusted nothrow @nogc
{
    if (s is null) return 0;
    size_t len = 0;
    while (s[len] != '\0') len++;
    return len;
}

/// Delta Transfer Protocol
/// Enables 80-95% bandwidth savings for large artifact transfers
/// by only uploading/downloading changed chunks
/// 
/// Protocol flow:
/// 1. Client sends manifest hash to server
/// 2. Server responds with list of missing chunks
/// 3. Client uploads only missing chunks
/// 4. Server stores manifest linking to chunks
final class DeltaTransfer
{
    private StreamingArtifactTransport transport;
    private ChunkedCAS localStore;
    private DeltaConfig config;
    
    /// Delta transfer configuration
    struct DeltaConfig
    {
        size_t chunkBatchSize = 16;           // Chunks per batch upload
        size_t minDeltaSize = 100 * 1024 * 1024;  // 100MB minimum for delta
        Duration timeout = 30.seconds;
        bool verifyChunks = true;
    }
    
    @system
    this(StreamingArtifactTransport transport, ChunkedCAS store, DeltaConfig cfg = DeltaConfig.init)
    {
        this.transport = transport;
        this.localStore = store;
        this.config = cfg;
    }
    
    /// Upload artifact using delta transfer
    /// Returns transfer statistics
    @system
    BuildResult!TransferResult upload(string blobHash, const(ubyte)[] data)
    {
        auto startTime = MonoTime.currTime;
        TransferResult result;
        result.blobHash = blobHash;
        result.totalSize = data.length;
        
        // Small artifacts: direct upload
        if (data.length < config.minDeltaSize)
        {
            auto putResult = transport.put(blobHash, data);
            if (putResult.isErr)
                return Err!(TransferResult, BuildError)(putResult.unwrapErr());
            
            result.bytesTransferred = data.length;
            result.duration = MonoTime.currTime - startTime;
            return Ok!(TransferResult, BuildError)(result);
        }
        
        // Large artifacts: delta transfer
        
        // 1. Get or create local manifest
        auto manifestResult = localStore.getManifest(blobHash);
        ChunkManifest manifest;
        
        if (manifestResult.isErr)
        {
            // Chunk locally first
            auto storeResult = localStore.put(data);
            if (storeResult.isErr)
                return Err!(TransferResult, BuildError)(storeResult.unwrapErr());
            
            manifestResult = localStore.getManifest(blobHash);
            if (manifestResult.isErr)
                return Err!(TransferResult, BuildError)(manifestResult.unwrapErr());
        }
        manifest = manifestResult.unwrap();
        
        // 2. Query server for missing chunks
        auto chunkHashes = manifest.refs.map!(r => toHexString(r.hash[])).array;
        
        string[] missingHashes;
        if (auto batchTransport = cast(BatchArtifactTransport)transport)
        {
            auto missingResult = batchTransport.findMissing(chunkHashes);
            if (missingResult.isErr)
                return Err!(TransferResult, BuildError)(missingResult.unwrapErr());
            missingHashes = missingResult.unwrap();
        }
        else
        {
            // Fallback: check each chunk
            foreach (hash; chunkHashes)
            {
                auto hasResult = transport.has(hash);
                if (hasResult.isErr)
                    return Err!(TransferResult, BuildError)(hasResult.unwrapErr());
                if (!hasResult.unwrap())
                    missingHashes ~= hash;
            }
        }
        
        result.chunksTotal = manifest.chunkCount;
        result.chunksTransferred = missingHashes.length;
        
        // 3. Upload missing chunks
        foreach (hashStr; missingHashes)
        {
            // Find chunk in manifest
            foreach (ref r; manifest.refs)
            {
                if (toHexString(r.hash[]) == hashStr)
                {
                    auto chunkResult = localStore.getChunk(r.hash);
                    if (chunkResult.isErr)
                        return Err!(TransferResult, BuildError)(chunkResult.unwrapErr());
                    
                    auto chunkData = chunkResult.unwrap();
                    auto putResult = transport.put(hashStr, chunkData);
                    if (putResult.isErr)
                        return Err!(TransferResult, BuildError)(putResult.unwrapErr());
                    
                    result.bytesTransferred += chunkData.length;
                    break;
                }
            }
        }
        
        // 4. Upload manifest
        auto manifestData = manifest.serialize();
        auto manifestHash = "manifest:" ~ blobHash;
        auto putResult = transport.put(manifestHash, manifestData);
        if (putResult.isErr)
            return Err!(TransferResult, BuildError)(putResult.unwrapErr());
        
        result.bytesTransferred += manifestData.length;
        result.bytesSaved = result.totalSize - result.bytesTransferred;
        result.duration = MonoTime.currTime - startTime;
        
        return Ok!(TransferResult, BuildError)(result);
    }
    
    /// Download artifact using delta transfer with Merkle verification
    @system
    BuildResult!(ubyte[]) download(string blobHash)
    {
        // Try to get manifest first
        auto manifestHash = "manifest:" ~ blobHash;
        auto manifestResult = transport.get(manifestHash);
        
        // No manifest: download whole blob
        if (manifestResult.isErr)
            return transport.get(blobHash);
        
        auto manifestData = manifestResult.unwrap();
        auto parseResult = ChunkManifest.deserialize(manifestData);
        if (parseResult.isErr)
            return transport.get(blobHash);
        
        auto manifest = parseResult.unwrap();
        
        // Identify chunks we already have locally
        auto localMissing = appender!(ubyte[32][])();
        uint[] missingIndices;
        
        foreach (i, ref r; manifest.refs)
        {
            auto chunkResult = localStore.getChunk(r.hash);
            if (chunkResult.isErr)
            {
                localMissing ~= r.hash;
                missingIndices ~= cast(uint)i;
            }
        }
        
        // Download missing chunks with Merkle proof verification
        foreach (j, hash; localMissing[])
        {
            auto chunkResult = transport.get(toHexString(hash[]));
            if (chunkResult.isErr)
                return Err!(ubyte[], BuildError)(chunkResult.unwrapErr());
            
            auto chunkData = chunkResult.unwrap();
            
            // Verify chunk with Merkle proof if available
            if (config.verifyChunks)
            {
                auto proof = manifest.generateProof(missingIndices[j]);
                if (!ChunkedCAS.verifyChunkAgainstRoot(chunkData, hash, proof, manifest.merkleRoot))
                    return Err!(ubyte[], BuildError)(Errors.cache(
                        "Chunk verification failed: " ~ toHexString(hash[]), Cache.Corrupted).build());
            }
            
            auto storeResult = localStore.putChunk(chunkData, hash);
            if (storeResult.isErr)
                return Err!(ubyte[], BuildError)(storeResult.unwrapErr());
        }
        
        // Store manifest and reassemble
        auto storeResult = localStore.storeManifest(blobHash, manifest);
        if (storeResult.isErr)
            return Err!(ubyte[], BuildError)(storeResult.unwrapErr());
        
        return localStore.get(blobHash);
    }
    
    /// Download with incremental verification using Merkle tree diff
    /// Only downloads chunks that differ from local version
    @system
    BuildResult!TransferResult downloadIncremental(string blobHash, string localBlobHash)
    {
        auto startTime = MonoTime.currTime;
        TransferResult result;
        result.blobHash = blobHash;
        
        // Get both manifests
        auto remoteManifest = transport.get("manifest:" ~ blobHash);
        if (remoteManifest.isErr)
        {
            auto fullResult = transport.get(blobHash);
            if (fullResult.isErr)
                return Err!(TransferResult, BuildError)(fullResult.unwrapErr());
            
            auto data = fullResult.unwrap();
            result.totalSize = data.length;
            result.bytesTransferred = data.length;
            result.chunksTotal = 1;
            result.chunksTransferred = 1;
            result.duration = MonoTime.currTime - startTime;
            return Ok!(TransferResult, BuildError)(result);
        }
        
        auto parseResult = ChunkManifest.deserialize(remoteManifest.unwrap());
        if (parseResult.isErr)
            return Err!(TransferResult, BuildError)(Errors.cache(
                "Failed to parse remote manifest", Cache.LoadFailed).build());
        
        auto remoteMf = parseResult.unwrap();
        result.totalSize = remoteMf.totalSize;
        result.chunksTotal = remoteMf.chunkCount;
        
        // Get local manifest for diff
        auto localManifest = localStore.getManifest(localBlobHash);
        
        uint[] changedIndices;
        if (localManifest.isOk)
        {
            // Use Merkle tree diff to find changed chunks (O(log n) for sparse changes)
            auto localMf = localManifest.unwrap();
            changedIndices = remoteMf.findChanged(localMf);
        }
        else
        {
            // No local version - download all chunks
            foreach (i; 0 .. remoteMf.chunkCount)
                changedIndices ~= cast(uint)i;
        }
        
        result.chunksTransferred = changedIndices.length;
        
        // Download only changed chunks
        foreach (idx; changedIndices)
        {
            if (idx >= remoteMf.refs.length)
                continue;
            
            auto ref_ = remoteMf.refs[idx];
            auto chunkResult = transport.get(toHexString(ref_.hash[]));
            if (chunkResult.isErr)
                return Err!(TransferResult, BuildError)(chunkResult.unwrapErr());
            
            auto chunkData = chunkResult.unwrap();
            result.bytesTransferred += chunkData.length;
            
            // Verify with Merkle proof
            if (config.verifyChunks)
            {
                auto proof = remoteMf.generateProof(idx);
                if (!ChunkedCAS.verifyChunkAgainstRoot(chunkData, ref_.hash, proof, remoteMf.merkleRoot))
                    return Err!(TransferResult, BuildError)(Errors.cache(
                        "Incremental chunk verification failed", Cache.Corrupted).build());
            }
            
            auto storeResult = localStore.putChunk(chunkData, ref_.hash);
            if (storeResult.isErr)
                return Err!(TransferResult, BuildError)(storeResult.unwrapErr());
        }
        
        // Store new manifest
        auto storeResult = localStore.storeManifest(blobHash, remoteMf);
        if (storeResult.isErr)
            return Err!(TransferResult, BuildError)(storeResult.unwrapErr());
        
        result.bytesSaved = result.totalSize - result.bytesTransferred;
        result.duration = MonoTime.currTime - startTime;
        
        return Ok!(TransferResult, BuildError)(result);
    }
    
    /// Check if delta transfer is beneficial for size
    static bool shouldUseDelta(size_t size) pure @safe nothrow @nogc
        => size >= 100 * 1024 * 1024;  // 100MB threshold
}

/// Result of delta transfer operation
struct TransferResult
{
    string blobHash;
    size_t totalSize;
    size_t bytesTransferred;
    size_t bytesSaved;
    size_t chunksTotal;
    size_t chunksTransferred;
    Duration duration;
    
    /// Bandwidth savings percentage
    double savingsPercent() const pure @safe nothrow @nogc
        => totalSize > 0 ? 100.0 * bytesSaved / totalSize : 0.0;
    
    /// Transfer efficiency
    double efficiency() const pure @safe nothrow @nogc
        => chunksTotal > 0 ? 100.0 * (chunksTotal - chunksTransferred) / chunksTotal : 0.0;
    
    /// Throughput in bytes/sec
    double throughput() const @trusted
        => duration.total!"msecs" > 0 ? bytesTransferred * 1000.0 / duration.total!"msecs" : 0.0;
}

/// Batch delta upload for multiple artifacts
@system
BuildResult!(TransferResult[]) batchDeltaUpload(
    DeltaTransfer delta,
    string[] blobHashes,
    const(ubyte)[][] blobs
)
{
    if (blobHashes.length != blobs.length)
        return Err!(TransferResult[], BuildError)(Errors.generic(
            "Hash/blob count mismatch", Internal.InvalidArgument).build());
    
    auto results = appender!(TransferResult[])();
    
    foreach (i, hash; blobHashes)
    {
        auto result = delta.upload(hash, blobs[i]);
        if (result.isErr)
            return Err!(TransferResult[], BuildError)(result.unwrapErr());
        results ~= result.unwrap();
    }
    
    return Ok!(TransferResult[], BuildError)(results[]);
}

/// Aggregate statistics from batch transfer
TransferResult aggregateResults(TransferResult[] results) pure @safe
{
    TransferResult agg;
    
    foreach (ref r; results)
    {
        agg.totalSize += r.totalSize;
        agg.bytesTransferred += r.bytesTransferred;
        agg.bytesSaved += r.bytesSaved;
        agg.chunksTotal += r.chunksTotal;
        agg.chunksTransferred += r.chunksTransferred;
    }
    
    return agg;
}

/// Delta compression manager for artifact updates
/// Combines rsync-style delta + zstd dictionary compression
final class DeltaCompressor
{
    private RsyncDelta rsync;
    private ZstdDictionary zstd;
    private string storageDir;
    private DeltaCompressionStats stats;
    
    /// Configuration
    struct Config
    {
        size_t blockSize = 4096;           // rsync block size
        size_t dictSize = 110 * 1024;      // zstd dictionary size
        size_t minDeltaSize = 1024 * 1024; // 1MB minimum for delta
        int compressionLevel = 5;
        bool useDictionary = true;
    }
    
    @system
    this(string storageDir, Config config = Config.init)
    {
        this.storageDir = storageDir;
        this.rsync = new RsyncDelta(config.blockSize);
        
        if (config.useDictionary)
            this.zstd = new ZstdDictionary(storageDir, config.dictSize);
    }
    
    /// Create delta between old and new versions
    @system
    BuildResult!DeltaPackage createDelta(
        const(ubyte)[] oldData,
        const(ubyte)[] newData,
        Config config = Config.init
    )
    {
        auto startTime = MonoTime.currTime;
        DeltaPackage pkg;
        pkg.originalNewSize = newData.length;
        
        // Generate signatures from old data
        auto sigs = rsync.generateSignatures(oldData);
        
        // Compute delta instructions
        auto delta = rsync.computeDelta(newData, sigs);
        
        // Serialize and optionally compress
        auto serialized = RsyncDelta.serializeDelta(delta);
        
        if (zstd !is null && serialized.length > 1024)
        {
            auto compResult = zstd.compress(serialized, config.compressionLevel);
            if (compResult.isOk)
            {
                auto compressed = compResult.unwrap();
                if (compressed.length < serialized.length)
                {
                    pkg.data = compressed;
                    pkg.compressed = true;
                }
                else
                {
                    pkg.data = serialized;
                    pkg.compressed = false;
                }
            }
            else
            {
                pkg.data = serialized;
                pkg.compressed = false;
            }
        }
        else
        {
            pkg.data = serialized;
            pkg.compressed = false;
        }
        
        pkg.deltaSize = pkg.data.length;
        
        // Update stats
        synchronized
        {
            stats.deltasCreated++;
            stats.totalOriginalBytes += newData.length;
            stats.totalDeltaBytes += pkg.deltaSize;
        }
        
        return Ok!(DeltaPackage, BuildError)(pkg);
    }
    
    /// Apply delta to reconstruct new version
    @system
    BuildResult!(ubyte[]) applyDelta(const(ubyte)[] oldData, ref const DeltaPackage pkg)
    {
        // Decompress if needed
        const(ubyte)[] serialized;
        
        if (pkg.compressed)
        {
            if (zstd is null)
                return Err!(ubyte[], BuildError)(Errors.generic(
                    "No dictionary available for decompression").build());
            
            auto decompResult = zstd.decompress(pkg.data);
            if (decompResult.isErr)
                return Err!(ubyte[], BuildError)(decompResult.unwrapErr());
            serialized = decompResult.unwrap();
        }
        else
        {
            serialized = pkg.data;
        }
        
        // Deserialize instructions
        auto deltaResult = RsyncDelta.deserializeDelta(serialized);
        if (deltaResult.isErr)
            return Err!(ubyte[], BuildError)(deltaResult.unwrapErr());
        
        // Apply delta
        return rsync.applyDelta(oldData, deltaResult.unwrap());
    }
    
    /// Train dictionary on artifact samples
    @system
    VoidBuildResult trainDictionary(const(ubyte)[][] samples)
    {
        if (zstd is null)
            return VoidBuildResult.err(Errors.generic(
                "Dictionary compression disabled").build());
        
        return zstd.train(samples);
    }
    
    /// Check if dictionary is available
    bool hasDictionary() const @safe
        => zstd !is null && zstd.hasDictionary();
    
    /// Get compression statistics
    DeltaCompressionStats getStats() const @trusted
    {
        synchronized return stats;
    }
}

/// Serialized delta package
struct DeltaPackage
{
    ubyte[] data;           // Serialized (and optionally compressed) delta
    size_t deltaSize;       // Size of delta package
    size_t originalNewSize; // Original size of new data
    bool compressed;        // Whether zstd compression was applied
    
    /// Compression savings
    double savingsPercent() const pure @safe nothrow @nogc
        => originalNewSize > 0 ? 100.0 * (originalNewSize - deltaSize) / originalNewSize : 0.0;
}

/// Statistics for delta compression
struct DeltaCompressionStats
{
    size_t deltasCreated;
    size_t totalOriginalBytes;
    size_t totalDeltaBytes;
    
    /// Overall compression ratio
    double compressionRatio() const pure @safe nothrow @nogc
        => totalOriginalBytes > 0 ? cast(double)totalDeltaBytes / totalOriginalBytes : 1.0;
    
    /// Total bytes saved
    size_t bytesSaved() const pure @safe nothrow @nogc
        => totalOriginalBytes > totalDeltaBytes ? totalOriginalBytes - totalDeltaBytes : 0;
}

