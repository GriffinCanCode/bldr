module engine.caching.storage.source_repository;

import std.file : exists, read, write, mkdirRecurse;
import std.path : buildPath, dirName;
import std.algorithm : map, filter;
import std.array : array;
import std.conv : to;
import core.sync.mutex : Mutex;
import engine.caching.storage.cas : ContentAddressableStorage;
import engine.caching.storage.source_ref : SourceRef, SourceRefSet;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// Content-addressed source repository (git-like)
/// All sources stored in CAS by content hash with automatic deduplication
/// Enables:
/// - Zero-cost branching (sources shared across branches)
/// - Time-travel builds (any historical state can be reconstructed)
/// - Automatic deduplication (identical files stored once)
/// - Distributed caching (sources referenced by hash, not path)
final class SourceRepository
{
    private ContentAddressableStorage cas;
    private SourceTrackingIndex index;
    private Mutex repoMutex;
    private string repoDir;
    
    // Statistics
    private size_t sourcesStored;
    private size_t sourcesFetched;
    private size_t deduplicationHits;
    private ulong bytesStored;
    private ulong bytesSaved;  // From deduplication
    
    this(ContentAddressableStorage cas, string repoDir = ".builder-cache/sources") @system
    {
        this.cas = cas;
        this.repoDir = repoDir;
        this.repoMutex = new Mutex();
        this.index = new SourceTrackingIndex(buildPath(repoDir, "index.bin"));
        
        if (!exists(repoDir))
            mkdirRecurse(repoDir);
    }
    
    /// Store source file in CAS and return reference
    BuildResult!SourceRef store(string path) @system
    {
        synchronized (repoMutex)
        {
            // Create source ref (computes hash)
            auto refResult = SourceRef.fromFile(path);
            if (refResult.isErr)
                return refResult;
            
            auto ref_ = refResult.unwrap();
            
            // Check if already stored (deduplication)
            if (cas.hasBlob(ref_.hash))
            {
                deduplicationHits++;
                bytesSaved += ref_.size;
                
                // Update index
                index.track(path, ref_.hash);
                return Ok!(SourceRef, BuildError)(ref_);
            }
            
            // Read and store in CAS
            try
            {
                auto content = cast(ubyte[])read(path);
                auto putResult = cas.putBlob(content);
                
                if (putResult.isErr)
                    return Err!(SourceRef, BuildError)(putResult.unwrapErr());
                
                // Verify hash matches
                immutable storedHash = putResult.unwrap();
                if (storedHash != ref_.hash)
                    return Err!(SourceRef, BuildError)(
                        createCacheError(
                            "Hash mismatch during source storage",
                            ErrorCode.CacheCorrupted,
                            path
                        )
                    );
                
                // Update statistics
                sourcesStored++;
                bytesStored += ref_.size;
                
                // Update index
                index.track(path, ref_.hash);
                
                return Ok!(SourceRef, BuildError)(ref_);
            }
            catch (Exception e)
            {
                return Err!(SourceRef, BuildError)(
                    new IOError(path, "Failed to store source: " ~ e.msg, ErrorCode.FileReadFailed)
                );
            }
        }
    }
    
    /// Store multiple source files (batch operation)
    BuildResult!SourceRefSet storeBatch(const(string)[] paths) @system
    {
        SourceRefSet refSet;
        
        foreach (path; paths)
        {
            auto result = store(path);
            if (result.isErr)
                return Err!(SourceRefSet, BuildError)(result.unwrapErr());
            
            refSet.add(result.unwrap());
        }
        
        return Ok!(SourceRefSet, BuildError)(refSet);
    }
    
    /// Retrieve source file by hash
    BuildResult!(ubyte[]) fetch(string hash) @system
    {
        synchronized (repoMutex)
        {
            auto result = cas.getBlob(hash);
            if (result.isOk)
                sourcesFetched++;
            
            return result;
        }
    }
    
    /// Retrieve source and write to specific path (materialization)
    VoidBuildResult materialize(string hash, string targetPath) @system
    {
        synchronized (repoMutex)
        {
            try
            {
                auto fetchResult = cas.getBlob(hash);
                if (fetchResult.isErr)
                    return VoidBuildResult.err(fetchResult.unwrapErr());
                
                auto content = fetchResult.unwrap();
                
                // Ensure target directory exists
                immutable dir = dirName(targetPath);
                if (!exists(dir))
                    mkdirRecurse(dir);
                
                // Write to target path
                write(targetPath, content);
                
                // Update index
                index.track(targetPath, hash);
                
                return Ok!BuildError();
            }
            catch (Exception e)
            {
                return VoidBuildResult.err(
                    new IOError(
                        targetPath,
                        "Failed to materialize source: " ~ e.msg,
                        ErrorCode.FileWriteFailed
                    )
                );
            }
        }
    }
    
    /// Materialize multiple sources (workspace restoration)
    VoidBuildResult materializeBatch(SourceRefSet refSet) @system
    {
        foreach (ref source; refSet.sources)
        {
            if (source.originalPath.length == 0)
                continue;
            
            auto result = materialize(source.hash, source.originalPath);
            if (result.isErr)
                return result;
        }
        
        return Ok!BuildError();
    }
    
    /// Check if source exists by hash
    bool has(string hash) @system
    {
        synchronized (repoMutex)
        {
            return cas.hasBlob(hash);
        }
    }
    
    /// Get source ref from path (if tracked)
    BuildResult!SourceRef getRefByPath(string path) @system
    {
        synchronized (repoMutex)
        {
            auto hashOpt = index.lookup(path);
            if (!hashOpt.found)
                return Err!(SourceRef, BuildError)(
                    new IOError(path, "Source not tracked", ErrorCode.CacheNotFound)
                );
            
            return Ok!(SourceRef, BuildError)(
                SourceRef.fromHash(hashOpt.hash, path)
            );
        }
    }
    
    /// Verify source file matches stored hash (integrity check)
    BuildResult!bool verify(string path) @system
    {
        synchronized (repoMutex)
        {
            try
            {
                if (!exists(path))
                    return Err!(bool, BuildError)(
                        new IOError(path, "File not found", ErrorCode.FileNotFound)
                    );
                
                auto hashOpt = index.lookup(path);
                if (!hashOpt.found)
                    return Ok!(bool, BuildError)(false);
                
                immutable currentHash = FastHash.hashFile(path);
                return Ok!(bool, BuildError)(currentHash == hashOpt.hash);
            }
            catch (Exception e)
            {
                return Err!(bool, BuildError)(
                    new IOError(path, "Verification failed: " ~ e.msg, ErrorCode.FileReadFailed)
                );
            }
        }
    }
    
    /// Get repository statistics
    struct RepositoryStats
    {
        size_t sourcesStored;
        size_t sourcesFetched;
        size_t deduplicationHits;
        size_t uniqueSources;
        ulong bytesStored;
        ulong bytesSaved;
        float deduplicationRatio;
        size_t trackedPaths;
    }
    
    RepositoryStats getStats() @system
    {
        synchronized (repoMutex)
        {
            RepositoryStats stats;
            stats.sourcesStored = sourcesStored;
            stats.sourcesFetched = sourcesFetched;
            stats.deduplicationHits = deduplicationHits;
            stats.bytesStored = bytesStored;
            stats.bytesSaved = bytesSaved;
            stats.trackedPaths = index.size();
            
            // Get CAS stats for unique sources
            auto casStats = cas.getStats();
            stats.uniqueSources = casStats.uniqueBlobs;
            
            // Calculate deduplication ratio
            immutable totalStorageWithoutDedup = bytesStored + bytesSaved;
            if (totalStorageWithoutDedup > 0)
                stats.deduplicationRatio = (bytesSaved * 100.0) / totalStorageWithoutDedup;
            
            return stats;
        }
    }
    
    /// Clear repository (dangerous - removes all tracked sources)
    void clear() @system
    {
        synchronized (repoMutex)
        {
            index.clear();
            sourcesStored = 0;
            sourcesFetched = 0;
            deduplicationHits = 0;
            bytesStored = 0;
            bytesSaved = 0;
        }
    }
    
    /// Flush index to disk
    void flush() @system
    {
        synchronized (repoMutex)
        {
            index.flush();
        }
    }
}

/// Source tracking index (path -> hash mappings)
/// Persistent mapping for quick lookups without CAS traversal
private final class SourceTrackingIndex
{
    private string[string] pathToHash;  // path -> hash
    private string[string] hashToPath;  // hash -> path (for reverse lookup)
    private string indexPath;
    private bool dirty;
    
    this(string indexPath) @system
    {
        this.indexPath = indexPath;
        this.dirty = false;
        load();
    }
    
    /// Track source file
    void track(string path, string hash) @safe
    {
        pathToHash[path] = hash;
        hashToPath[hash] = path;
        dirty = true;
    }
    
    /// Lookup hash by path
    struct LookupResult
    {
        bool found;
        string hash;
    }
    
    LookupResult lookup(string path) const @safe nothrow
    {
        if (auto hashPtr = path in pathToHash)
            return LookupResult(true, *hashPtr);
        return LookupResult(false, "");
    }
    
    /// Reverse lookup: path by hash
    LookupResult reverseLookup(string hash) const @safe nothrow
    {
        if (auto pathPtr = hash in hashToPath)
            return LookupResult(true, *pathPtr);
        return LookupResult(false, "");
    }
    
    /// Number of tracked paths
    size_t size() const @safe nothrow @nogc
    {
        return pathToHash.length;
    }
    
    /// Clear index
    void clear() @safe
    {
        pathToHash.clear();
        hashToPath.clear();
        dirty = true;
    }
    
    /// Load index from disk
    private void load() @system
    {
        if (!exists(indexPath))
            return;
        
        try
        {
            import std.bitmanip : read;
            import std.file : readFile = read;
            
            auto data = cast(ubyte[])readFile(indexPath);
            if (data.length < 4)
                return;
            
            size_t offset = 0;
            
            // Version
            auto range = data[offset..$];
            immutable version_ = read!uint(range);
            offset += uint.sizeof;
            if (version_ != 1)
                return;
            
            // Entry count
            range = data[offset..$];
            immutable count = read!uint(range);
            offset += uint.sizeof;
            
            // Read entries
            foreach (_; 0 .. count)
            {
                if (offset + 8 > data.length)
                    break;
                
                range = data[offset..$];
                immutable pathLen = read!uint(range);
                offset += uint.sizeof;
                if (offset + pathLen > data.length)
                    break;
                
                immutable path = cast(string)data[offset .. offset + pathLen].idup;
                offset += pathLen;
                
                if (offset + 4 > data.length)
                    break;
                
                range = data[offset..$];
                immutable hashLen = read!uint(range);
                offset += uint.sizeof;
                if (offset + hashLen > data.length)
                    break;
                
                immutable hash = cast(string)data[offset .. offset + hashLen].idup;
                offset += hashLen;
                
                pathToHash[path] = hash;
                hashToPath[hash] = path;
            }
        }
        catch (Exception) {}
    }
    
    /// Flush index to disk
    void flush() @system
    {
        if (!dirty)
            return;
        
        try
        {
            import std.bitmanip : write;
            
            ubyte[] buffer;
            buffer.reserve(pathToHash.length * 128);  // Estimate
            
            // Version
            buffer.write!uint(1, buffer.length);
            
            // Entry count
            buffer.write!uint(cast(uint)pathToHash.length, buffer.length);
            
            // Write entries
            foreach (path, hash; pathToHash)
            {
                buffer.write!uint(cast(uint)path.length, buffer.length);
                buffer ~= cast(ubyte[])path;
                
                buffer.write!uint(cast(uint)hash.length, buffer.length);
                buffer ~= cast(ubyte[])hash;
            }
            
            // Ensure directory exists
            import std.file : writeFile = write;
            
            immutable dir = dirName(indexPath);
            if (!exists(dir))
                mkdirRecurse(dir);
            
            writeFile(indexPath, buffer);
            dirty = false;
        }
        catch (Exception) {}
    }
}

