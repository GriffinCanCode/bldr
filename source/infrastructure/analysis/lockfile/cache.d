module infrastructure.analysis.lockfile.cache;

import std.file : exists, readText, write, mkdirRecurse, remove, dirEntries, SpanMode, isFile;
import std.path : buildPath, dirName;
import std.datetime : Clock, SysTime;
import std.algorithm : sort, map, filter;
import std.array : array;
import std.conv : to;
import core.sync.mutex : Mutex;
import infrastructure.analysis.lockfile.types;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.serialization;
import infrastructure.errors;

/// Content-addressed lockfile cache
/// Caches resolved dependencies by manifest content hash to avoid re-resolution
final class LockfileCache
{
    private string cacheDir;
    private Mutex cacheMutex;
    private CacheEntry[string] entries;  // manifestHash -> entry
    private bool dirty;
    
    this(string cacheDir = ".builder-cache/lockfiles") @system
    {
        this.cacheDir = cacheDir;
        this.cacheMutex = new Mutex();
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        load();
    }
    
    /// Get cached lockfile for manifest
    BuildResult!Lockfile get(string manifestHash) @system
    {
        synchronized (cacheMutex)
        {
            auto entry = manifestHash in entries;
            if (entry is null)
                return Err!(Lockfile, BuildError)(
                    Errors.cache("Lockfile not cached", ErrorCode.CacheNotFound).build());
            
            // Update access time for LRU
            entry.lastAccess = Clock.currTime.stdTime;
            dirty = true;
            
            // Load lockfile from disk
            auto lockfilePath = buildPath(cacheDir, manifestHash ~ ".lock");
            return loadLockfile(lockfilePath);
        }
    }
    
    /// Cache lockfile for manifest
    void put(string manifestHash, const ref Lockfile lockfile) @system
    {
        synchronized (cacheMutex)
        {
            // Store lockfile to disk
            auto lockfilePath = buildPath(cacheDir, manifestHash ~ ".lock");
            auto result = saveLockfile(lockfile, lockfilePath);
            
            if (result.isErr)
                return;
            
            // Update cache entry
            CacheEntry entry;
            entry.manifestHash = manifestHash;
            entry.lockfileHash = lockfile.hash();
            entry.depCount = lockfile.count().to!uint;
            entry.lastAccess = Clock.currTime.stdTime;
            entry.created = Clock.currTime.stdTime;
            
            entries[manifestHash] = entry;
            dirty = true;
        }
    }
    
    /// Check if manifest has cached lockfile
    bool has(string manifestHash) @system
    {
        synchronized (cacheMutex)
        {
            return (manifestHash in entries) !is null;
        }
    }
    
    /// Invalidate cache entry
    void invalidate(string manifestHash) @system
    {
        synchronized (cacheMutex)
        {
            if (auto entry = manifestHash in entries)
            {
                // Remove lockfile from disk
                auto lockfilePath = buildPath(cacheDir, manifestHash ~ ".lock");
                if (exists(lockfilePath))
                    remove(lockfilePath);
                
                entries.remove(manifestHash);
                dirty = true;
            }
        }
    }
    
    /// Prune old entries (LRU eviction)
    void prune(size_t maxEntries = 1000) @system
    {
        synchronized (cacheMutex)
        {
            if (entries.length <= maxEntries)
                return;
            
            // Sort by last access time
            auto sorted = entries.byKeyValue
                .array
                .sort!((a, b) => a.value.lastAccess < b.value.lastAccess);
            
            // Remove oldest entries
            size_t toRemove = entries.length - maxEntries;
            foreach (ref kv; sorted[0 .. toRemove])
            {
                auto lockfilePath = buildPath(cacheDir, kv.key ~ ".lock");
                if (exists(lockfilePath))
                    remove(lockfilePath);
                entries.remove(kv.key);
            }
            
            dirty = true;
        }
    }
    
    /// Get cache statistics
    CacheStats stats() @system
    {
        synchronized (cacheMutex)
        {
            CacheStats s;
            s.entryCount = entries.length;
            
            foreach (ref e; entries.byValue)
                s.totalDeps += e.depCount;
            
            return s;
        }
    }
    
    /// Persist cache index to disk
    void save() @system
    {
        synchronized (cacheMutex)
        {
            if (!dirty)
                return;
            
            auto indexPath = buildPath(cacheDir, "index.bin");
            auto data = Codec.serialize(CacheIndex(entries.byValue.array));
            write(indexPath, data);
            dirty = false;
        }
    }
    
    /// Compute manifest hash from file
    static string hashManifest(string manifestPath) @system
    {
        return exists(manifestPath) ? FastHash.hashFile(manifestPath) : "";
    }
    
private:
    void load() @system
    {
        auto indexPath = buildPath(cacheDir, "index.bin");
        if (!exists(indexPath))
            return;
        
        try
        {
            import std.file : read;
            auto data = cast(ubyte[])read(indexPath);
            auto result = Codec.deserialize!CacheIndex(data);
            
            if (result.isOk)
            {
                auto idx = result.unwrap();
                foreach (ref e; idx.entries)
                    entries[e.manifestHash] = e;
            }
        }
        catch (Exception e) {}
    }
    
    BuildResult!Lockfile loadLockfile(string path) @system
    {
        if (!exists(path))
            return Err!(Lockfile, BuildError)(
                Errors.cache("Lockfile not found: " ~ path, ErrorCode.CacheNotFound).build());
        
        try
        {
            import std.file : read;
            auto data = cast(ubyte[])read(path);
            auto result = Codec.deserialize!Lockfile(data);
            
            return result.isOk 
                ? Ok!(Lockfile, BuildError)(result.unwrap())
                : Err!(Lockfile, BuildError)(
                    Errors.cache("Failed to deserialize lockfile", ErrorCode.CacheLoadFailed).build());
        }
        catch (Exception e)
        {
            return Err!(Lockfile, BuildError)(
                Errors.cache("Failed to load lockfile: " ~ e.msg, ErrorCode.CacheLoadFailed).build());
        }
    }
    
    BuildResult!void saveLockfile(const ref Lockfile lockfile, string path) @system
    {
        try
        {
            auto data = Codec.serialize(lockfile);
            write(path, data);
            return Ok!(void, BuildError)();
        }
        catch (Exception e)
        {
            return Err!(void, BuildError)(
                Errors.cache("Failed to save lockfile: " ~ e.msg, ErrorCode.CacheSaveFailed).build());
        }
    }
}

/// Cache entry metadata
@Serializable(SchemaVersion(1, 0))
struct CacheEntry
{
    @Field(1) string manifestHash;
    @Field(2) string lockfileHash;
    @Field(3) @Packed uint depCount;
    @Field(4) @Packed long lastAccess;
    @Field(5) @Packed long created;
}

/// Cache index for persistence
@Serializable(SchemaVersion(1, 0), 0x4C4B4358) // "LKCX"
struct CacheIndex
{
    @Field(1) CacheEntry[] entries;
}

/// Cache statistics
struct CacheStats
{
    size_t entryCount;
    size_t totalDeps;
    
    /// Estimated memory usage
    size_t estimatedBytes() const pure @safe 
        => entryCount * 256 + totalDeps * 64;
}

