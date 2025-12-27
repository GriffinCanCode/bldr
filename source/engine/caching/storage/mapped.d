module engine.caching.storage.mapped;

import std.file : exists, read, write, remove, mkdirRecurse, dirEntries, SpanMode, getSize;
import std.path : buildPath, dirName, baseName;
import std.algorithm : map, filter, sum, min, max;
import std.array : array;
import std.conv : to;
import core.sync.mutex : Mutex;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode, MapAdvice;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Size threshold for memory-mapped access (files larger than this use mmap)
private enum size_t MMAP_THRESHOLD = 256 * 1024;  // 256 KB

/// Maximum number of cached mappings
private enum size_t MAX_CACHED_MAPPINGS = 64;

/// Handle to a memory-mapped blob for zero-copy access
/// Automatically unmaps when destroyed
final class MappedBlob
{
    private MmapRegion _region;
    private string _hash;
    
    private this() {}
    
    /// Get read-only data slice (zero-copy)
    const(ubyte)[] data() @system nothrow @nogc => _region !is null ? _region[] : null;
    
    /// Get blob content hash
    string hash() const @safe pure nothrow => _hash;
    
    /// Get blob size
    size_t length() const @safe nothrow @nogc => _region !is null ? _region.length : 0;
    
    /// Check if valid
    bool valid() const @safe nothrow @nogc => _region !is null && _region.valid;
    
    /// Optimize for sequential access
    void sequential() @system nothrow
    {
        if (_region !is null && _region.valid)
            _region.advise(MapAdvice.Sequential);
    }
    
    /// Optimize for random access
    void random() @system nothrow
    {
        if (_region !is null && _region.valid)
            _region.advise(MapAdvice.Random);
    }
    
    /// Lock in physical memory
    bool pin() @system nothrow => _region !is null ? _region.lock() : false;
    
    /// Unpin from physical memory
    bool unpin() @system nothrow => _region !is null ? _region.unlock() : false;
}

/// Zero-copy blob storage with memory-mapped I/O
/// 
/// Design:
/// - Small blobs (<256KB): Standard file read
/// - Large blobs (>=256KB): Memory-mapped for zero-copy
/// - Shared page cache across processes
/// - Automatic deduplication via content addressing
/// 
/// Performance:
/// - Zero heap allocation for large blob access
/// - Kernel-managed page cache (efficient memory)
/// - Direct file-to-memory mapping (no copies)
/// - LRU cache for frequently accessed mappings
final class MappedBlobStore
{
    private string storageDir;
    private Mutex storageMutex;
    private size_t[string] refCounts;
    private MappedBlobStats _stats;
    
    this(string storageDir = ".builder-cache/blobs") @system
    {
        this.storageDir = storageDir;
        this.storageMutex = new Mutex();
        
        if (!exists(storageDir))
            mkdirRecurse(storageDir);
    }
    
    /// Store blob by content hash (zero-copy write for large blobs)
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
                    _stats.dedupHits++;
                    return Ok!(string, BuildError)(hash);
                }
                
                // Store new blob
                immutable dir = dirName(blobPath);
                if (!exists(dir)) mkdirRecurse(dir);
                
                write(blobPath, data);
                refCounts[hash] = 1;
                
                _stats.blobsWritten++;
                _stats.bytesWritten += data.length;
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
    
    /// Get blob with zero-copy memory mapping for large blobs
    /// 
    /// Small blobs (<256KB): Returns heap-allocated copy
    /// Large blobs (>=256KB): Returns memory-mapped view
    BuildResult!(const(ubyte)[]) getBlob(string hash) @system
    {
        try
        {
            immutable blobPath = getBlobPath(hash);
            
            synchronized (storageMutex)
            {
                if (!exists(blobPath))
                    return Err!(const(ubyte)[], BuildError)(
                        createCacheError("Blob not found: " ~ hash, Cache.NotFound, blobPath)
                    );
                
                immutable size = getSize(blobPath);
                _stats.blobsRead++;
                
                // Small blobs: standard read
                if (size < MMAP_THRESHOLD)
                {
                    _stats.bytesReadCopied += size;
                    return Ok!(const(ubyte)[], BuildError)(cast(const(ubyte)[])read(blobPath));
                }
                
                // Large blobs: memory-mapped (but return copy since caller doesn't own region)
                auto region = MmapRegion.map(blobPath, MapMode.ReadOnly);
                if (region is null)
                {
                    // Fallback to standard read
                    _stats.bytesReadCopied += size;
                    return Ok!(const(ubyte)[], BuildError)(cast(const(ubyte)[])read(blobPath));
                }
                scope(exit) region.unmap();
                
                _stats.bytesReadMapped += size;
                _stats.mappingsCreated++;
                
                // Copy data since caller doesn't own the mapping
                // For true zero-copy, use getMappedBlob() instead
                return Ok!(const(ubyte)[], BuildError)(region[].dup);
            }
        }
        catch (Exception e)
        {
            return Err!(const(ubyte)[], BuildError)(Errors.cache(
                "Failed to read blob: " ~ e.msg, Cache.LoadFailed).build());
        }
    }
    
    /// Get memory-mapped blob handle for true zero-copy access
    /// 
    /// Returns owned MappedBlob that maintains mapping lifetime.
    /// The returned handle MUST be kept alive while data is accessed.
    /// 
    /// For blobs < MMAP_THRESHOLD, returns error (use getBlob instead)
    BuildResult!MappedBlob getMappedBlob(string hash) @system
    {
        try
        {
            immutable blobPath = getBlobPath(hash);
            
            synchronized (storageMutex)
            {
                if (!exists(blobPath))
                    return Err!(MappedBlob, BuildError)(
                        createCacheError("Blob not found: " ~ hash, Cache.NotFound, blobPath)
                    );
                
                immutable size = getSize(blobPath);
                
                // Only map large blobs
                if (size < MMAP_THRESHOLD)
                    return Err!(MappedBlob, BuildError)(
                        createCacheError("Blob too small for mapping: " ~ hash, Cache.NotFound, blobPath)
                    );
                
                string mapError;
                auto region = MmapRegion.map(blobPath, MapMode.ReadOnly, 0, 0, &mapError);
                if (region is null)
                    return Err!(MappedBlob, BuildError)(
                        createCacheError("Failed to map blob: " ~ mapError, Cache.LoadFailed, blobPath)
                    );
                
                auto blob = new MappedBlob();
                blob._region = region;
                blob._hash = hash;
                
                // Hint sequential access by default
                region.advise(MapAdvice.Sequential);
                
                _stats.blobsRead++;
                _stats.bytesReadMapped += size;
                _stats.mappingsCreated++;
                
                return Ok!(MappedBlob, BuildError)(blob);
            }
        }
        catch (Exception e)
        {
            return Err!(MappedBlob, BuildError)(Errors.cache(
                "Failed to map blob: " ~ e.msg, Cache.LoadFailed).build());
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
    
    /// Get blob size without loading
    BuildResult!size_t blobSize(string hash) @system
    {
        try
        {
            synchronized (storageMutex)
            {
                immutable path = getBlobPath(hash);
                if (!exists(path))
                    return Err!(size_t, BuildError)(
                        createCacheError("Blob not found", Cache.NotFound, path)
                    );
                return Ok!(size_t, BuildError)(getSize(path));
            }
        }
        catch (Exception e)
        {
            return Err!(size_t, BuildError)(Errors.cache(e.msg, Cache.LoadFailed).build());
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
                    .map!(e => baseName(e.name))
                    .array;
            }
            catch (Exception)
            {
                return [];
            }
        }
    }
    
    /// Statistics for storage
    struct MappedBlobStats
    {
        size_t blobsWritten;
        size_t blobsRead;
        size_t bytesWritten;
        size_t bytesReadCopied;
        size_t bytesReadMapped;
        size_t mappingsCreated;
        size_t dedupHits;
        
        /// Percentage of reads using zero-copy
        double zeroCopyRatio() const pure nothrow @nogc
        {
            immutable total = bytesReadCopied + bytesReadMapped;
            return total > 0 ? (cast(double)bytesReadMapped / total) * 100.0 : 0.0;
        }
        
        /// Average bytes saved per dedup hit
        size_t avgDedupSavings() const pure nothrow @nogc
        {
            return dedupHits > 0 ? bytesWritten / max(1, dedupHits) : 0;
        }
    }
    
    MappedBlobStats stats() const @safe nothrow => _stats;
    
    /// Get storage statistics
    struct StorageStats
    {
        size_t totalBlobs;
        size_t totalSize;
        size_t uniqueBlobs;
        size_t duplicateRefs;
        float deduplicationRatio;
    }
    
    StorageStats getStorageStats() @system
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
            
            try
            {
                stats.totalSize = dirEntries(storageDir, SpanMode.depth)
                    .filter!(e => e.isFile)
                    .map!(e => e.size)
                    .sum;
            }
            catch (Exception) {}
            
            if (stats.totalBlobs > 0)
                stats.deduplicationRatio = (stats.uniqueBlobs * 100.0) / stats.totalBlobs;
            
            return stats;
        }
    }
    
    /// Get blob path from hash (uses sharding for performance)
    private string getBlobPath(string hash) const pure @safe
    {
        if (hash.length < 2)
            return buildPath(storageDir, "00", hash);
        
        immutable shard = hash[0 .. 2];
        return buildPath(storageDir, shard, hash);
    }
}

/// Stream large blobs in chunks using mmap windows
/// Useful for processing files larger than available RAM
final class MappedBlobStream
{
    private string _path;
    private size_t _fileSize;
    private size_t _windowSize;
    private size_t _position;
    private MmapRegion _currentWindow;
    
    private this() {}
    
    /// Create stream for file
    static BuildResult!MappedBlobStream open(
        string path,
        size_t windowSize = 64 * 1024 * 1024  // 64 MB default window
    ) @system
    {
        if (!exists(path))
            return Err!(MappedBlobStream, BuildError)(
                Errors.cache("File not found: " ~ path, Cache.NotFound).build()
            );
        
        auto stream = new MappedBlobStream();
        stream._path = path;
        stream._fileSize = getSize(path);
        stream._windowSize = windowSize;
        stream._position = 0;
        
        return Ok!(MappedBlobStream, BuildError)(stream);
    }
    
    /// Read next chunk
    const(ubyte)[] read() @system
    {
        if (_position >= _fileSize)
            return null;
        
        // Calculate window parameters
        immutable remaining = _fileSize - _position;
        immutable windowLen = min(_windowSize, remaining);
        
        // Unmap previous window
        if (_currentWindow !is null && _currentWindow.valid)
            _currentWindow.unmap();
        
        // Map new window
        _currentWindow = MmapRegion.map(_path, MapMode.ReadOnly, _position, windowLen);
        if (_currentWindow is null)
            return null;
        
        _currentWindow.advise(MapAdvice.Sequential);
        
        _position += windowLen;
        
        return _currentWindow[];
    }
    
    /// Reset to beginning
    void reset() @safe nothrow @nogc
    {
        _position = 0;
    }
    
    /// Current position
    size_t position() const @safe pure nothrow @nogc => _position;
    
    /// File size
    size_t size() const @safe pure nothrow @nogc => _fileSize;
    
    /// Remaining bytes
    size_t remaining() const @safe pure nothrow @nogc =>
        _position < _fileSize ? _fileSize - _position : 0;
    
    /// Check if at end
    bool eof() const @safe pure nothrow @nogc => _position >= _fileSize;
}

unittest
{
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;
    
    // Create test blob store
    immutable testDir = buildPath(tempDir(), "mapped_blob_test");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new MappedBlobStore(testDir);
    
    // Test small blob (copied)
    ubyte[] smallData = new ubyte[1024];
    foreach (i, ref b; smallData) b = cast(ubyte)(i & 0xFF);
    
    auto putResult = store.putBlob(smallData);
    assert(putResult.isOk);
    
    auto hash = putResult.unwrap();
    auto getResult = store.getBlob(hash);
    assert(getResult.isOk);
    
    auto retrieved = getResult.unwrap();
    assert(retrieved.length == smallData.length);
    assert(retrieved[0] == 0);
    assert(retrieved[255] == 255);
}

unittest
{
    import std.file : tempDir, rmdirRecurse;
    import std.path : buildPath;
    
    // Test large blob (should use mmap)
    immutable testDir = buildPath(tempDir(), "mapped_blob_large_test");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    auto store = new MappedBlobStore(testDir);
    
    // Create 512KB blob (above MMAP_THRESHOLD)
    ubyte[] largeData = new ubyte[512 * 1024];
    foreach (i, ref b; largeData) b = cast(ubyte)(i & 0xFF);
    
    auto putResult = store.putBlob(largeData);
    assert(putResult.isOk);
    
    auto hash = putResult.unwrap();
    
    // Test mapped blob access
    auto mappedResult = store.getMappedBlob(hash);
    assert(mappedResult.isOk);
    
    auto mapped = mappedResult.unwrap();
    assert(mapped.valid);
    assert(mapped.length == largeData.length);
    
    auto data = mapped.data();
    assert(data[0] == 0);
    assert(data[255] == 255);
    assert(data[256] == 0);  // Wrap at byte boundary
}
