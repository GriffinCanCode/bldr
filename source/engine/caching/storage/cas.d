module engine.caching.storage.cas;

import std.file : exists, read, write, remove, mkdirRecurse, dirEntries, SpanMode, getSize;
import std.path : buildPath, dirName;
import std.algorithm : map, filter, sum;
import std.array : array;
import std.conv : to;
import core.sync.mutex : Mutex;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Size threshold for memory-mapped reads (files larger than this use mmap)
private enum size_t CAS_MMAP_THRESHOLD = 256 * 1024;  // 256 KB

/// Content-addressable storage with automatic deduplication
/// Stores blobs by content hash, enabling zero-copy artifact sharing
final class ContentAddressableStorage
{
    private string storageDir;
    private Mutex storageMutex;
    private size_t[string] refCounts;  // Track blob references
    
    this(string storageDir = ".builder-cache/blobs") @system
    {
        this.storageDir = storageDir;
        this.storageMutex = new Mutex();
        
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
                
                // Store new blob
                immutable dir = dirName(blobPath);
                if (!exists(dir)) mkdirRecurse(dir);
                
                write(blobPath, data);
                refCounts[hash] = 1;
            }
            
            return Ok!(string, BuildError)(hash);
        }
        catch (Exception e)
        {
            return Err!(string, BuildError)(
                createCacheError("Failed to store blob: " ~ e.msg, ErrorCode.CacheWriteFailed, blobPath)
            );
        }
    }
    
    /// Retrieve blob by content hash
    /// Uses mmap for large blobs to reduce memory copies
    BuildResult!(ubyte[]) getBlob(string hash) @system
    {
        try
        {
            immutable blobPath = getBlobPath(hash);
            
            synchronized (storageMutex)
            {
                if (!exists(blobPath))
                    return Err!(ubyte[], BuildError)(
                        createCacheError("Blob not found: " ~ hash, ErrorCode.CacheNotFound, blobPath)
                    );
                
                immutable size = getSize(blobPath);
                
                // Small blobs: standard read
                if (size < CAS_MMAP_THRESHOLD)
                    return Ok!(ubyte[], BuildError)(cast(ubyte[])read(blobPath));
                
                // Large blobs: memory-mapped read (zero kernel-to-user copy)
                auto region = MmapRegion.map(blobPath, MapMode.ReadOnly);
                if (region is null)
                    return Ok!(ubyte[], BuildError)(cast(ubyte[])read(blobPath)); // Fallback
                
                scope(exit) region.unmap();
                return Ok!(ubyte[], BuildError)(region[].dup);
            }
        }
        catch (Exception e)
        {
            return Err!(ubyte[], BuildError)(Errors.cache(
                "Failed to read blob: " ~ e.msg, ErrorCode.CacheLoadFailed).build());
        }
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
                        "Cannot delete blob with active references", ErrorCode.CacheInUse).build());
                
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
                "Failed to delete blob: " ~ e.msg, ErrorCode.CacheDeleteFailed).build());
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

