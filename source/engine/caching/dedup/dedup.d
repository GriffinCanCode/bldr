module engine.caching.dedup.dedup;

import std.algorithm : map, filter, sum, each;
import std.array : array, appender;
import std.conv : to;
import std.datetime : Clock, SysTime;
import core.atomic : atomicOp, atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import engine.caching.storage.cas : ContentAddressableStorage;
import engine.caching.storage.chunked : ChunkedCAS;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.files.cdc : shouldChunk, LARGE_ARTIFACT_THRESHOLD, ChunkManifest;
import infrastructure.utils.serialization : Codec;
import infrastructure.utils.simd.bloom : BloomFilter;
import infrastructure.utils.crypto.merkle : MerkleTree, MerkleProof;
import infrastructure.errors;

/// Blob reference - pointer to content-addressed blob
/// Enables action results to reference blobs without storing duplicate data
struct BlobRef
{
    string hash;          // Content hash (BLAKE3)
    size_t size;          // Original size in bytes
    string path;          // Logical path (e.g., "lib/foo.a")
    bool executable;      // Preserve executable bit
    
    /// Create ref from raw data
    static BlobRef fromData(const(ubyte)[] data, string path = "", bool exec = false) @system
    {
        BlobRef r;
        r.hash = FastHash.hashBytes(data);
        r.size = data.length;
        r.path = path;
        r.executable = exec;
        return r;
    }
    
    /// Null ref sentinel
    static BlobRef nil() pure @safe => BlobRef.init;
    
    bool isValid() const pure @safe => hash.length > 0;
}

/// Shard for reference count map - reduces lock contention via striping
private struct RefCountShard
{
    Mutex mutex;
    size_t[string] refCounts;
    
    static RefCountShard create() @system
    {
        RefCountShard shard;
        shard.mutex = new Mutex();
        return shard;
    }
}

/// Atomic statistics counters for lock-free updates
private struct AtomicDedupStats
{
    shared long uniqueBlobs;
    shared long duplicateRefs;
    shared long uniqueBytes;
    shared long savedBytes;
    shared long totalStores;
    shared long totalFetches;
    shared long bloomFilterSaves;
    shared long largeBlobs;
    
    /// Snapshot to regular DedupStats for reporting
    DedupStats snapshot() const @trusted nothrow @nogc
    {
        DedupStats s;
        s.uniqueBlobs = cast(size_t)atomicLoad(uniqueBlobs);
        s.duplicateRefs = cast(size_t)atomicLoad(duplicateRefs);
        s.uniqueBytes = cast(size_t)atomicLoad(uniqueBytes);
        s.savedBytes = cast(size_t)atomicLoad(savedBytes);
        s.totalStores = cast(size_t)atomicLoad(totalStores);
        s.totalFetches = cast(size_t)atomicLoad(totalFetches);
        s.bloomFilterSaves = cast(size_t)atomicLoad(bloomFilterSaves);
        s.largeBlobs = cast(size_t)atomicLoad(largeBlobs);
        return s;
    }
}

/// Content deduplication engine
/// Maps action outputs to content-addressed blobs, achieving 30-70% storage reduction
/// 
/// Design Philosophy:
/// - Write-once, read-many: blobs are immutable
/// - Reference counting: safe deletion when unreferenced
/// - Lazy materialization: fetch blob content on-demand
/// - Batch-optimized: minimize I/O for bulk operations
/// - Bloom filter prefilter: eliminates 80-95% of negative lookups
/// - FastCDC: Large blobs (>100MB) use content-defined chunking
/// 
/// Concurrency:
/// - Sharded locking: 32 ref-count shards for parallel store/fetch
/// - Lock-free stats: atomic counters eliminate stats contention
/// - Bloom reads are lock-free (writes use dedicated mutex)
final class DedupEngine
{
    private ContentAddressableStorage cas;
    private ChunkedCAS chunkedCas;  // For large blobs (>100MB)
    
    // Sharded ref counts - 32 shards for lock striping
    private enum SHARD_COUNT = 32;
    private RefCountShard[SHARD_COUNT] shards;
    
    // Bloom filter for fast negative lookups (avoids disk I/O)
    // Reads are thread-safe; writes need bloomMutex
    private BloomFilter bloomFilter;
    private Mutex bloomMutex;  // Only for bloom writes
    private enum BLOOM_EXPECTED_ITEMS = 100_000;
    private enum BLOOM_FPR = 0.001;  // 0.1% false positive rate
    
    // Lock-free statistics
    private AtomicDedupStats stats;
    
    this(ContentAddressableStorage cas) @system
    {
        this.cas = cas;
        this.bloomMutex = new Mutex();
        this.bloomFilter = BloomFilter.create(BLOOM_EXPECTED_ITEMS, BLOOM_FPR);
        foreach (i; 0 .. SHARD_COUNT)
            shards[i] = RefCountShard.create();
    }
    
    /// Constructor with ChunkedCAS for large blob support
    this(ContentAddressableStorage cas, ChunkedCAS chunkedCas) @system
    {
        this.cas = cas;
        this.chunkedCas = chunkedCas;
        this.bloomMutex = new Mutex();
        this.bloomFilter = BloomFilter.create(BLOOM_EXPECTED_ITEMS, BLOOM_FPR);
        foreach (i; 0 .. SHARD_COUNT)
            shards[i] = RefCountShard.create();
    }
    
    /// Get shard index from hash (FNV-1a for fast distribution)
    private static size_t shardIndex(string hash) pure @safe nothrow @nogc
    {
        if (hash.length == 0) return 0;
        // Use first 8 chars of hash for shard selection
        size_t h = 0;
        foreach (c; hash[0 .. (hash.length < 8 ? hash.length : 8)])
            h = h * 31 + c;
        return h & (SHARD_COUNT - 1);
    }
    
    /// Store blob and get reference (deduplicates automatically)
    /// Uses FastCDC for large blobs (>100MB)
    /// Returns: BlobRef pointing to stored content
    BuildResult!BlobRef store(const(ubyte)[] data, string path = "", bool executable = false) @system
    {
        if (data.length == 0)
            return Ok!(BlobRef, BuildError)(BlobRef.nil);
        
        auto ref_ = BlobRef.fromData(data, path, executable);
        immutable shardIdx = shardIndex(ref_.hash);
        
        // Use ChunkedCAS for large blobs (>100MB)
        if (shouldChunk(data.length) && chunkedCas !is null)
        {
            auto storeResult = chunkedCas.put(data);
            if (storeResult.isErr)
                return Err!(BlobRef, BuildError)(storeResult.unwrapErr());
            
            // Track reference in shard
            size_t prevCount;
            synchronized (shards[shardIdx].mutex)
            {
                prevCount = shards[shardIdx].refCounts.get(ref_.hash, 0);
                shards[shardIdx].refCounts[ref_.hash] = prevCount + 1;
            }
            
            // Bloom write needs its own lock
            if (bloomFilter.valid)
                synchronized (bloomMutex) bloomFilter.insert(ref_.hash);
            
            // Atomic stats update (lock-free)
            if (prevCount == 0) {
                atomicOp!"+="(stats.uniqueBlobs, 1);
                atomicOp!"+="(stats.uniqueBytes, cast(long)data.length);
                atomicOp!"+="(stats.largeBlobs, 1);
            } else {
                atomicOp!"+="(stats.duplicateRefs, 1);
                atomicOp!"+="(stats.savedBytes, cast(long)data.length);
            }
            atomicOp!"+="(stats.totalStores, 1);
            
            return Ok!(BlobRef, BuildError)(ref_);
        }
        
        // Store in CAS (handles dedup internally)
        auto storeResult = cas.putBlob(data);
        if (storeResult.isErr)
            return Err!(BlobRef, BuildError)(storeResult.unwrapErr());
        
        // Track reference in shard
        size_t prevCount;
        synchronized (shards[shardIdx].mutex)
        {
            prevCount = shards[shardIdx].refCounts.get(ref_.hash, 0);
            shards[shardIdx].refCounts[ref_.hash] = prevCount + 1;
        }
        
        // Bloom write needs its own lock
        if (bloomFilter.valid)
            synchronized (bloomMutex) bloomFilter.insert(ref_.hash);
        
        // Atomic stats update (lock-free)
        if (prevCount == 0)
        {
            atomicOp!"+="(stats.uniqueBlobs, 1);
            atomicOp!"+="(stats.uniqueBytes, cast(long)data.length);
        }
        else
        {
            atomicOp!"+="(stats.duplicateRefs, 1);
            atomicOp!"+="(stats.savedBytes, cast(long)data.length);
        }
        atomicOp!"+="(stats.totalStores, 1);
        
        return Ok!(BlobRef, BuildError)(ref_);
    }
    
    /// Store multiple blobs in batch (optimized I/O)
    BuildResult!(BlobRef[]) storeBatch(const(ubyte)[][] blobs, string[] paths = null) @system
    {
        auto refs = appender!(BlobRef[])();
        refs.reserve(blobs.length);
        
        foreach (i, data; blobs)
        {
            immutable path = (paths !is null && i < paths.length) ? paths[i] : "";
            auto result = store(data, path);
            if (result.isErr)
                return Err!(BlobRef[], BuildError)(result.unwrapErr());
            refs ~= result.unwrap();
        }
        
        return Ok!(BlobRef[], BuildError)(refs[]);
    }
    
    /// Fetch blob content by reference
    /// Handles both regular CAS and ChunkedCAS blobs
    BuildResult!(ubyte[]) fetch(BlobRef ref_) @system
    {
        if (!ref_.isValid)
            return Ok!(ubyte[], BuildError)(null);
        
        // Atomic stats update (lock-free)
        atomicOp!"+="(stats.totalFetches, 1);
        
        // Try ChunkedCAS first for large blobs
        if (chunkedCas !is null && ref_.size >= LARGE_ARTIFACT_THRESHOLD)
            if (chunkedCas.has(ref_.hash))
                return chunkedCas.get(ref_.hash);
        
        return cas.getBlob(ref_.hash);
    }
    
    /// Fetch multiple blobs (batch optimized)
    BuildResult!(ubyte[][]) fetchBatch(BlobRef[] refs) @system
    {
        auto results = appender!(ubyte[][])();
        results.reserve(refs.length);
        
        foreach (ref ref_; refs)
        {
            auto result = fetch(ref_);
            if (result.isErr)
                return Err!(ubyte[][], BuildError)(result.unwrapErr());
            results ~= result.unwrap();
        }
        
        return Ok!(ubyte[][], BuildError)(results[]);
    }
    
    /// Check if blob exists (bloom filter prefiltered)
    /// Bloom reads are lock-free; stats use atomic ops
    bool exists(BlobRef ref_) @system
    {
        if (!ref_.isValid) return false;
        
        // Fast path: bloom filter says definitely not present (lock-free read)
        if (bloomFilter.valid && !bloomFilter.mayContain(ref_.hash))
        {
            atomicOp!"+="(stats.bloomFilterSaves, 1);
            return false;
        }
        
        // Bloom filter says maybe present - verify with disk lookup
        return cas.hasBlob(ref_.hash);
    }
    
    /// Check if hash exists (bloom filter prefiltered)
    /// Bloom reads are lock-free; stats use atomic ops
    bool existsHash(string hash) @system
    {
        if (hash.length == 0) return false;
        
        // Fast path: bloom filter says definitely not present (lock-free read)
        if (bloomFilter.valid && !bloomFilter.mayContain(hash))
        {
            atomicOp!"+="(stats.bloomFilterSaves, 1);
            return false;
        }
        
        return cas.hasBlob(hash);
    }
    
    /// Batch check existence (SIMD-accelerated bloom filter)
    /// Bloom reads are lock-free; stats batched via atomic add
    bool[] existsBatch(const(string)[] hashes) @system
    {
        auto results = new bool[hashes.length];
        
        if (!bloomFilter.valid)
        {
            foreach (i, hash; hashes)
                results[i] = hash.length > 0 && cas.hasBlob(hash);
            return results;
        }
        
        // Pre-filter with bloom - only check disk for potential matches
        long bloomSaves = 0;
        foreach (i, hash; hashes)
        {
            if (hash.length == 0)
                results[i] = false;
            else if (!bloomFilter.mayContain(hash))
            {
                results[i] = false;
                bloomSaves++;
            }
            else
                results[i] = cas.hasBlob(hash);
        }
        
        // Batch atomic update
        if (bloomSaves > 0)
            atomicOp!"+="(stats.bloomFilterSaves, bloomSaves);
        
        return results;
    }
    
    /// Add reference to blob (when action result references it)
    void addRef(string hash) @system
    {
        immutable shardIdx = shardIndex(hash);
        synchronized (shards[shardIdx].mutex)
            shards[shardIdx].refCounts[hash] = shards[shardIdx].refCounts.get(hash, 0) + 1;
        cas.addRef(hash);
    }
    
    /// Remove reference from blob (when action result is evicted)
    /// Returns: true if blob has no more references
    bool removeRef(string hash) @system
    {
        immutable shardIdx = shardIndex(hash);
        synchronized (shards[shardIdx].mutex)
        {
            auto countPtr = hash in shards[shardIdx].refCounts;
            if (countPtr !is null && --(*countPtr) <= 0)
            {
                atomicOp!"-="(stats.uniqueBlobs, 1);
                shards[shardIdx].refCounts.remove(hash);
            }
        }
        return cas.removeRef(hash);
    }
    
    /// Bulk add references (optimized for manifest loading)
    /// Groups by shard to minimize lock acquisitions
    void addRefs(const(string)[] hashes) @system
    {
        // Group hashes by shard for batched locking
        size_t[][SHARD_COUNT] shardGroups;
        foreach (i, hash; hashes)
            shardGroups[shardIndex(hash)] ~= i;
        
        foreach (shardIdx; 0 .. SHARD_COUNT)
        {
            if (shardGroups[shardIdx].length == 0) continue;
            
            synchronized (shards[shardIdx].mutex)
            {
                foreach (idx; shardGroups[shardIdx])
                {
                    auto hash = hashes[idx];
                    shards[shardIdx].refCounts[hash] = shards[shardIdx].refCounts.get(hash, 0) + 1;
                    cas.addRef(hash);
                }
            }
        }
    }
    
    /// Bulk remove references (optimized for eviction)
    /// Groups by shard to minimize lock acquisitions
    string[] removeRefs(const(string)[] hashes) @system
    {
        auto orphans = appender!(string[])();
        long removedCount = 0;
        
        // Group hashes by shard for batched locking
        size_t[][SHARD_COUNT] shardGroups;
        foreach (i, hash; hashes)
            shardGroups[shardIndex(hash)] ~= i;
        
        foreach (shardIdx; 0 .. SHARD_COUNT)
        {
            if (shardGroups[shardIdx].length == 0) continue;
            
            synchronized (shards[shardIdx].mutex)
            {
                foreach (idx; shardGroups[shardIdx])
                {
                    auto hash = hashes[idx];
                    auto countPtr = hash in shards[shardIdx].refCounts;
                    if (countPtr !is null && --(*countPtr) <= 0)
                    {
                        removedCount++;
                        shards[shardIdx].refCounts.remove(hash);
                        if (cas.removeRef(hash))
                            orphans ~= hash;
                    }
                }
            }
        }
        
        // Batch atomic update
        if (removedCount > 0)
            atomicOp!"-="(stats.uniqueBlobs, removedCount);
        
        return orphans[];
    }
    
    /// Get deduplication statistics (lock-free snapshot)
    DedupStats getStats() const @trusted nothrow @nogc
    {
        return stats.snapshot();
    }
    
    /// Get estimated storage savings (lock-free)
    float getSavingsRatio() const @trusted nothrow @nogc
    {
        immutable s = stats.snapshot();
        immutable total = s.uniqueBytes + s.savedBytes;
        return total > 0 ? (s.savedBytes * 100.0f) / total : 0;
    }
}

/// Deduplication statistics
struct DedupStats
{
    size_t uniqueBlobs;      // Unique content-addressed blobs
    size_t duplicateRefs;    // References to existing blobs (deduped)
    size_t uniqueBytes;      // Total bytes stored (deduplicated)
    size_t savedBytes;       // Bytes saved through deduplication
    size_t totalStores;      // Total store operations
    size_t totalFetches;     // Total fetch operations
    size_t bloomFilterSaves; // Disk lookups avoided via bloom filter
    size_t largeBlobs;       // Blobs stored via ChunkedCAS (>100MB)
    
    /// Deduplication ratio (lower = better dedup)
    float dedupRatio() const pure @safe
    {
        immutable total = uniqueBlobs + duplicateRefs;
        return total > 0 ? (uniqueBlobs * 100.0f) / total : 100;
    }
    
    /// Storage efficiency (how much space saved)
    float efficiency() const pure @safe
    {
        immutable total = uniqueBytes + savedBytes;
        return total > 0 ? (savedBytes * 100.0f) / total : 0;
    }
    
    /// Bloom filter effectiveness (disk lookups avoided)
    float bloomEfficiency() const pure @safe
    {
        immutable total = totalFetches + bloomFilterSaves;
        return total > 0 ? (bloomFilterSaves * 100.0f) / total : 0;
    }
}

/// Verify blob integrity
BuildResult!bool verifyBlob(DedupEngine engine, BlobRef ref_) @system
{
    auto fetchResult = engine.fetch(ref_);
    if (fetchResult.isErr)
        return Err!(bool, BuildError)(fetchResult.unwrapErr());
    
    auto data = fetchResult.unwrap();
    if (data is null && !ref_.isValid)
        return Ok!(bool, BuildError)(true);
    
    // Verify content hash
    immutable actualHash = FastHash.hashBytes(data);
    immutable matches = actualHash == ref_.hash;
    
    if (!matches)
    {
        return Err!(bool, BuildError)(Errors.cache(
            "Blob integrity check failed: expected " ~ ref_.hash ~ ", got " ~ actualHash,
            Cache.Corrupted).build());
    }
    
    // Verify size
    if (data.length != ref_.size)
    {
        return Err!(bool, BuildError)(Errors.cache(
            "Blob size mismatch: expected " ~ ref_.size.to!string ~ ", got " ~ data.length.to!string,
            Cache.Corrupted).build());
    }
    
    return Ok!(bool, BuildError)(true);
}

/// Verify large blob integrity using Merkle tree (partial verification)
/// Only verifies the Merkle root matches - individual chunks verified lazily
BuildResult!bool verifyBlobMerkle(DedupEngine engine, BlobRef ref_) @system
{
    if (!ref_.isValid)
        return Ok!(bool, BuildError)(true);
    
    // Check if this is a chunked blob
    if (engine.chunkedCas is null)
        return verifyBlob(engine, ref_);  // Fallback to full verification
    
    // Try to get manifest for Merkle verification
    auto manifestResult = engine.chunkedCas.getManifest(ref_.hash);
    if (manifestResult.isErr)
        return verifyBlob(engine, ref_);  // No manifest, use full verification
    
    auto manifest = manifestResult.unwrap();
    
    // Rebuild Merkle tree from stored chunk hashes
    auto tree = manifest.rebuildMerkleTree();
    
    // Verify Merkle root matches stored root
    if (tree.root != manifest.merkleRoot)
    {
        return Err!(bool, BuildError)(Errors.cache(
            "Merkle root mismatch for blob: " ~ ref_.hash, Cache.Corrupted).build());
    }
    
    // Verify total size
    if (manifest.totalSize != ref_.size)
    {
        return Err!(bool, BuildError)(Errors.cache(
            "Blob size mismatch: expected " ~ ref_.size.to!string ~ 
            ", manifest reports " ~ manifest.totalSize.to!string, Cache.Corrupted).build());
    }
    
    return Ok!(bool, BuildError)(true);
}

/// Verify specific chunk of a large blob with Merkle proof
/// Useful for partial artifact validation without downloading entire blob
BuildResult!bool verifyChunkWithProof(
    DedupEngine engine, 
    string blobHash, 
    uint chunkIndex
) @system
{
    if (engine.chunkedCas is null)
        return Err!(bool, BuildError)(Errors.cache(
            "ChunkedCAS not available", Cache.NotFound).build());
    
    return Ok!(bool, BuildError)(engine.chunkedCas.verifyChunkWithProof(blobHash, chunkIndex));
}

/// Find which chunks differ between two versions of a blob
/// Uses Merkle tree diff for O(log n) detection of sparse changes
BuildResult!(uint[]) findChangedChunks(
    DedupEngine engine,
    string oldBlobHash,
    string newBlobHash
) @system
{
    if (engine.chunkedCas is null)
        return Err!(uint[], BuildError)(Errors.cache(
            "ChunkedCAS not available", Cache.NotFound).build());
    
    return engine.chunkedCas.findChangedChunks(oldBlobHash, newBlobHash);
}

