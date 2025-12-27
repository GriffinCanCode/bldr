module engine.caching.storage.cas;

import std.file : exists, read, write, remove, mkdirRecurse, dirEntries, SpanMode, getSize;
import std.path : buildPath, dirName;
import std.algorithm : map, filter, sum;
import std.array : array;
import std.conv : to;
import core.sync.mutex : Mutex;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode;
import infrastructure.utils.compression.streaming : zstdCompress, zstdDecompress;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Size threshold for memory-mapped reads (files larger than this use mmap)
private enum size_t CAS_MMAP_THRESHOLD = 256 * 1024;  // 256 KB
/// Minimum size to compress (below this, compression overhead isn't worth it)
private enum size_t CAS_COMPRESS_THRESHOLD = 1024;    // 1 KB

/// Content-addressable storage with automatic deduplication and compression
/// Stores blobs by content hash, enabling zero-copy artifact sharing
/// Uses zstd compression for blobs > 1KB (typically 30-70% reduction)
final class ContentAddressableStorage
{
    private string storageDir;
    private Mutex storageMutex;
    private size_t[string] refCounts;  // Track blob references
    private bool compressionEnabled;
    
    this(string storageDir = ".builder-cache/blobs", bool compress = true) @system
    {
        this.storageDir = storageDir;
        this.storageMutex = new Mutex();
        this.compressionEnabled = compress;
        
        if (!exists(storageDir))
            mkdirRecurse(storageDir);
    }
    
    /// Store blob by content hash (deduplicates automatically)
    /// Returns: content hash of stored blob
    BuildResult!string putBlob(const(ubyte)[] data) @system
    {
        string blobPath;
        try
        {
            // Hash original data (before compression) for content addressing
            immutable hash = FastHash.hashBytes(data);
            blobPath = getBlobPath(hash);
            
            synchronized (storageMutex)
            {
                // Check if blob already exists (deduplication)
                if (exists(blobPath))
                {
                    refCounts[hash] = refCounts.get(hash, 1) + 1;
                    return Ok!(string, BuildError)(hash);
                }
                
                // Store new blob (with optional compression)
                immutable dir = dirName(blobPath);
                if (!exists(dir)) mkdirRecurse(dir);
                
                const(ubyte)[] toStore = data;
                
                // Compress if beneficial (size > threshold)
                if (compressionEnabled && data.length >= CAS_COMPRESS_THRESHOLD)
                {
                    auto compResult = zstdCompress(data, 3);  // Level 3: fast + good ratio
                    if (compResult.isOk)
                    {
                        auto compressed = compResult.unwrap();
                        // Only use if >10% smaller (accounting for header)
                        if (compressed.length + 5 < data.length * 9 / 10)
                            toStore = makeCompressedBlob(compressed, data.length);
                    }
                }
                
                write(blobPath, toStore);
                refCounts[hash] = 1;
            }
            
            return Ok!(string, BuildError)(hash);
        }
        catch (Exception e)
        {
            return Err!(string, BuildError)(
                createCacheError("Failed to store blob: " ~ e.msg, Cache.WriteFailed, blobPath)
            );
        }
    }
    
    /// Retrieve blob by content hash
    /// Automatically decompresses if stored compressed
    BuildResult!(ubyte[]) getBlob(string hash) @system
    {
        try
        {
            immutable blobPath = getBlobPath(hash);
            
            synchronized (storageMutex)
            {
                if (!exists(blobPath))
                    return Err!(ubyte[], BuildError)(
                        createCacheError("Blob not found: " ~ hash, Cache.NotFound, blobPath)
                    );
                
                immutable size = getSize(blobPath);
                
                ubyte[] rawData;
                
                // Small blobs: standard read
                if (size < CAS_MMAP_THRESHOLD)
                {
                    rawData = cast(ubyte[])read(blobPath);
                }
                else
                {
                    // Large blobs: memory-mapped read
                    auto region = MmapRegion.map(blobPath, MapMode.ReadOnly);
                    if (region is null)
                        rawData = cast(ubyte[])read(blobPath);
                    else
                    {
                        scope(exit) region.unmap();
                        rawData = region[].dup;
                    }
                }
                
                // Check for compression header and decompress if needed
                return decompressBlobIfNeeded(rawData);
            }
        }
        catch (Exception e)
        {
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Failed to read blob: " ~ e.msg, Cache.LoadFailed).build());
        }
    }
    
    /// Create compressed blob with header: [MAGIC:1][ORIG_SIZE:4][COMPRESSED_DATA]
    private static ubyte[] makeCompressedBlob(const(ubyte)[] compressed, size_t origSize) pure @trusted
    {
        ubyte[] blob;
        blob.reserve(5 + compressed.length);
        blob ~= 0xCB;  // Magic byte: Compressed Blob
        blob ~= (origSize & 0xFF);
        blob ~= ((origSize >> 8) & 0xFF);
        blob ~= ((origSize >> 16) & 0xFF);
        blob ~= ((origSize >> 24) & 0xFF);
        blob ~= compressed;
        return blob;
    }
    
    /// Check if blob is compressed and decompress
    private static BuildResult!(ubyte[]) decompressBlobIfNeeded(ubyte[] data) @trusted
    {
        if (data.length < 5 || data[0] != 0xCB)
            return Ok!(ubyte[], BuildError)(data);  // Not compressed
        
        // Extract original size
        uint origSize = data[1] | (data[2] << 8) | (data[3] << 16) | (data[4] << 24);
        
        // Decompress
        auto decompResult = zstdDecompress(data[5 .. $]);
        if (decompResult.isErr)
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Blob decompression failed", Cache.CompressionFailed).build());
        
        return Ok!(ubyte[], BuildError)(decompResult.unwrap());
    }
    
    /// Check if blob exists
    bool hasBlob(string hash) @system
    {
        synchronized (storageMutex)
        {
            return exists(getBlobPath(hash));
        }
    }
    
    /// Increment reference count for blob
    void addRef(string hash) @system
    {
        synchronized (storageMutex)
        {
            refCounts[hash] = refCounts.get(hash, 0) + 1;
        }
    }
    
    /// Decrement reference count for blob
    /// Returns: true if blob can be deleted (ref count reached zero)
    bool removeRef(string hash) @system
    {
        synchronized (storageMutex)
        {
            if (auto countPtr = hash in refCounts)
            {
                if (--(*countPtr) <= 0)
                    refCounts.remove(hash);
                else
                    return false;
            }
            return true;
        }
    }
    
    /// Delete blob (only if no references)
    VoidBuildResult deleteBlob(string hash) @system
    {
        try
        {
            synchronized (storageMutex)
            {
                // Check reference count
                if (refCounts.get(hash, 0) > 0)
                    return VoidBuildResult.err(Errors.cache(
                        "Cannot delete blob with active references", Cache.InUse).build());
                
                immutable blobPath = getBlobPath(hash);
                if (exists(blobPath))
                    remove(blobPath);
                
                refCounts.remove(hash);
            }
            
            return Ok!BuildError();
        }
        catch (Exception e)
        {
            return VoidBuildResult.err(Errors.cache(
                "Failed to delete blob: " ~ e.msg, Cache.DeleteFailed).build());
        }
    }
    
    /// Get all blob hashes
    string[] listBlobs() @system
    {
        synchronized (storageMutex)
        {
            try
            {
                return dirEntries(storageDir, SpanMode.depth)
                    .filter!(e => e.isFile)
                    .map!(e => extractHashFromPath(e.name))
                    .array;
            }
            catch (Exception)
            {
                return [];
            }
        }
    }
    
    /// Get storage statistics
    struct StorageStats
    {
        size_t totalBlobs;
        size_t totalSize;
        size_t uniqueBlobs;
        size_t duplicateRefs;
        float deduplicationRatio;
    }
    
    StorageStats getStats() @system
    {
        synchronized (storageMutex)
        {
            StorageStats stats;
            stats.uniqueBlobs = refCounts.length;
            
            foreach (count; refCounts.byValue)
            {
                stats.totalBlobs += count;
                stats.duplicateRefs += count > 1 ? count - 1 : 0;
            }
            
            // Calculate total size
            try
            {
                stats.totalSize = dirEntries(storageDir, SpanMode.depth)
                    .filter!(e => e.isFile)
                    .map!(e => e.size)
                    .sum;
            }
            catch (Exception) {}
            
            // Deduplication ratio
            if (stats.totalBlobs > 0)
                stats.deduplicationRatio = (stats.uniqueBlobs * 100.0) / stats.totalBlobs;
            
            return stats;
        }
    }
    
    /// Get blob path from hash (uses sharding for performance)
    private string getBlobPath(string hash) const pure @safe
    {
        // Shard by first 2 characters for better filesystem performance
        if (hash.length < 2)
            return buildPath(storageDir, "00", hash);
        
        immutable shard = hash[0 .. 2];
        return buildPath(storageDir, shard, hash);
    }
    
    /// Extract hash from full path
    private string extractHashFromPath(string path) const pure @safe
    {
        import std.path : baseName;
        return baseName(path);
    }
}

