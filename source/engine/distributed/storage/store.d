module engine.distributed.storage.store;

import std.file : exists, read, write, mkdirRecurse, remove, getSize;
import std.path : buildPath, dirName;
import std.algorithm : min, filter, sort, sum;
import std.array : array;
import std.datetime : Clock, SysTime, Duration;
import core.sync.mutex : Mutex;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.protocol : DistributedError;
import infrastructure.errors : BuildError, Result, Ok, Err;
import infrastructure.utils.memory.mmap : MmapRegion, MapMode;

/// Size threshold for mmap reads (files larger use mmap)
private enum size_t ARTIFACT_MMAP_THRESHOLD = 256 * 1024;  // 256 KB

/// Helper function to convert hex character to value
private ubyte hexCharToValue(char c) pure @safe
{
    if (c >= '0' && c <= '9')
        return cast(ubyte)(c - '0');
    else if (c >= 'a' && c <= 'f')
        return cast(ubyte)(c - 'a' + 10);
    else if (c >= 'A' && c <= 'F')
        return cast(ubyte)(c - 'A' + 10);
    else
        return 0;
}

/// Artifact store interface
interface ArtifactStore
{
    /// Check if artifact exists
    Result!(bool, DistributedError) has(ArtifactId id);
    
    /// Fetch artifact data
    Result!(ubyte[], DistributedError) get(ArtifactId id);
    
    /// Store artifact data
    Result!(ArtifactId, DistributedError) put(ubyte[] data);
    
    /// Batch operations (more efficient)
    Result!(bool[], DistributedError) hasMany(ArtifactId[] ids);
    Result!(ubyte[][], DistributedError) getMany(ArtifactId[] ids);
}

/// Local filesystem artifact store
final class LocalArtifactStore : ArtifactStore
{
    private string cacheDir;
    private Mutex mutex;
    private size_t maxSize;
    private size_t currentSize;
    
    /// Cache entry metadata
    private struct CacheEntry
    {
        ArtifactId id;
        size_t size;
        SysTime lastAccess;
    }
    
    private CacheEntry[ArtifactId] entries;
    
    this(string cacheDir, size_t maxSize) @trusted
    {
        this.cacheDir = cacheDir;
        this.maxSize = maxSize;
        this.mutex = new Mutex();
        
        // Ensure cache directory exists
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        // Load existing entries
        loadEntries();
    }
    
    Result!(bool, DistributedError) has(ArtifactId id) @trusted =>
        Ok!(bool, DistributedError)(exists(artifactPath(id)));
    
    Result!(ubyte[], DistributedError) get(ArtifactId id) @trusted
    {
        synchronized (mutex)
        {
            immutable path = artifactPath(id);
            if (!exists(path)) return Err!(ubyte[], DistributedError)(new DistributedError("Artifact not found: " ~ id.toString()));
            
            try
            {
                if (auto entry = id in entries) entry.lastAccess = Clock.currTime;
                
                immutable size = getSize(path);
                
                // Small artifacts: standard read
                if (size < ARTIFACT_MMAP_THRESHOLD)
                    return Ok!(ubyte[], DistributedError)(cast(ubyte[])read(path));
                
                // Large artifacts: memory-mapped (reduces kernel-to-user copies)
                auto region = MmapRegion.map(path, MapMode.ReadOnly);
                if (region is null)
                    return Ok!(ubyte[], DistributedError)(cast(ubyte[])read(path)); // Fallback
                
                scope(exit) region.unmap();
                return Ok!(ubyte[], DistributedError)(region[].dup);
            }
            catch (Exception e)
            {
                return Err!(ubyte[], DistributedError)(new DistributedError("Failed to read artifact: " ~ e.msg));
            }
        }
    }
    
    Result!(ArtifactId, DistributedError) put(ubyte[] data) @trusted
    {
        auto id = computeArtifactId(data);
        
        synchronized (mutex)
        {
            immutable path = artifactPath(id);
            if (exists(path)) return Ok!(ArtifactId, DistributedError)(id);
            
            if (currentSize + data.length > maxSize)
            {
                auto evictResult = evictLRU(data.length);
                if (evictResult.isErr) return Err!(ArtifactId, DistributedError)(evictResult.unwrapErr());
            }
            
            try
            {
                immutable dir = dirName(path);
                if (!exists(dir)) mkdirRecurse(dir);
                
                write(path, data);
                
                entries[id] = CacheEntry(id, data.length, Clock.currTime);
                currentSize += data.length;
                
                return Ok!(ArtifactId, DistributedError)(id);
            }
            catch (Exception e)
            {
                return Err!(ArtifactId, DistributedError)(new DistributedError("Failed to write artifact: " ~ e.msg));
            }
        }
    }
    
    Result!(bool[], DistributedError) hasMany(ArtifactId[] ids) @trusted
    {
        bool[] results;
        results.reserve(ids.length);
        
        foreach (id; ids)
        {
            auto result = has(id);
            if (result.isErr)
                return Err!(bool[], DistributedError)(result.unwrapErr());
            results ~= result.unwrap();
        }
        
        return Ok!(bool[], DistributedError)(results);
    }
    
    Result!(ubyte[][], DistributedError) getMany(ArtifactId[] ids) @trusted
    {
        ubyte[][] results;
        results.reserve(ids.length);
        
        foreach (id; ids)
        {
            auto result = get(id);
            if (result.isErr)
                return Err!(ubyte[][], DistributedError)(result.unwrapErr());
            results ~= result.unwrap();
        }
        
        return Ok!(ubyte[][], DistributedError)(results);
    }
    
    private ArtifactId computeArtifactId(const ubyte[] data) @trusted
    {
        import infrastructure.utils.crypto.blake3 : Blake3;
        return ArtifactId(Blake3.hash(data));
    }
    
    private string artifactPath(ArtifactId id) @safe
    {
        auto idStr = id.toString();
        return buildPath(cacheDir, idStr[0 .. 2], idStr);
    }
    
    /// Load existing cache entries
    private void loadEntries() @trusted
    {
        import std.file : dirEntries, SpanMode, DirEntry, getTimes, isFile;
        import std.path : baseName;
        import std.string : strip;
        import std.conv : parse, to;
        
        currentSize = 0;
        entries.clear();
        
        try
        {
            // Scan cache directory recursively
            foreach (DirEntry entry; dirEntries(cacheDir, SpanMode.depth))
            {
                if (!entry.isFile)
                    continue;
                
                try
                {
                    // Parse artifact ID from filename
                    immutable filename = baseName(entry.name);
                    
                    // Validate it looks like a hash (hex string - should be 64 chars for 32 bytes)
                    if (filename.length != 64)
                        continue;
                    
                    // Parse hex string to bytes
                    ubyte[32] hashBytes;
                    bool validHex = true;
                    
                    try
                    {
                        import std.string : toLower;
                        import std.ascii : isHexDigit;
                        
                        // Validate all characters are hex digits
                        foreach (c; filename)
                        {
                            if (!isHexDigit(c))
                            {
                                validHex = false;
                                break;
                            }
                        }
                        
                        if (validHex)
                        {
                            for (size_t i = 0; i < 32; i++)
                            {
                                immutable hexPair = filename[i * 2 .. i * 2 + 2];
                                // Manual hex parsing to avoid string mutation
                                immutable highNibble = hexCharToValue(hexPair[0]);
                                immutable lowNibble = hexCharToValue(hexPair[1]);
                                hashBytes[i] = cast(ubyte)((highNibble << 4) | lowNibble);
                            }
                        }
                    }
                    catch (Exception)
                    {
                        validHex = false;
                    }
                    
                    if (!validHex)
                        continue;
                    
                    // Create ArtifactId from parsed hash
                    auto id = ArtifactId(hashBytes);
                    
                    // Get file metadata
                    immutable size = entry.size;
                    SysTime accessTime, modificationTime;
                    getTimes(entry.name, accessTime, modificationTime);
                    
                    // Create cache entry
                    CacheEntry cacheEntry;
                    cacheEntry.id = id;
                    cacheEntry.size = size;
                    cacheEntry.lastAccess = accessTime;
                    
                    entries[id] = cacheEntry;
                    currentSize += size;
                }
                catch (Exception e)
                {
                    // Skip files that can't be read
                    continue;
                }
            }
        }
        catch (Exception e)
        {
            // If cache directory doesn't exist or can't be read, start fresh
            currentSize = 0;
            entries.clear();
        }
    }
    
    /// Evict least-recently-used entries to free space
    private Result!DistributedError evictLRU(size_t needed) @trusted
    {
        import std.algorithm : sort;
        
        auto sorted = entries.values.array.sort!((a, b) => a.lastAccess < b.lastAccess);
        size_t freed = 0;
        
        foreach (entry; sorted)
        {
            if (freed >= needed) break;
            
            try
            {
                immutable path = artifactPath(entry.id);
                if (exists(path)) remove(path);
                entries.remove(entry.id);
                freed += entry.size;
                currentSize -= entry.size;
            }
            catch (Exception) {}
        }
        
        return freed >= needed ? Ok!DistributedError() : Result!DistributedError.err(new DistributedError("Failed to evict enough space"));
    }
}

/// Tiered artifact store (L1 local, L2 shared, L3 remote)
final class TieredArtifactStore : ArtifactStore
{
    private ArtifactStore l1;  // Local cache
    private ArtifactStore l2;  // Shared cache (optional)
    private ArtifactStore l3;  // Remote cache (optional)
    
    this(ArtifactStore l1, ArtifactStore l2 = null, ArtifactStore l3 = null) @safe
    {
        this.l1 = l1;
        this.l2 = l2;
        this.l3 = l3;
    }
    
    Result!(bool, DistributedError) has(ArtifactId id) @trusted
    {
        // Check L1 first
        auto l1Result = l1.has(id);
        if (l1Result.isOk && l1Result.unwrap())
            return l1Result;
        
        // Check L2
        if (l2 !is null)
        {
            auto l2Result = l2.has(id);
            if (l2Result.isOk && l2Result.unwrap())
                return l2Result;
        }
        
        // Check L3
        if (l3 !is null)
            return l3.has(id);
        
        return Ok!(bool, DistributedError)(false);
    }
    
    Result!(ubyte[], DistributedError) get(ArtifactId id) @trusted
    {
        // Try L1 (local cache)
        auto l1Result = l1.get(id);
        if (l1Result.isOk)
            return l1Result;
        
        // Try L2 (shared cache)
        if (l2 !is null)
        {
            auto l2Result = l2.get(id);
            if (l2Result.isOk)
            {
                auto data = l2Result.unwrap();
                // Populate L1
                l1.put(data);
                return Ok!(ubyte[], DistributedError)(data);
            }
        }
        
        // Try L3 (remote cache)
        if (l3 !is null)
        {
            auto l3Result = l3.get(id);
            if (l3Result.isOk)
            {
                auto data = l3Result.unwrap();
                // Populate L1 and L2
                l1.put(data);
                if (l2 !is null)
                    l2.put(data);
                return Ok!(ubyte[], DistributedError)(data);
            }
        }
        
        return Err!(ubyte[], DistributedError)(new DistributedError("Artifact not found in any tier: " ~ id.toString()));
    }
    
    Result!(ArtifactId, DistributedError) put(ubyte[] data) @trusted
    {
        // Write to all tiers
        auto l1Result = l1.put(data);
        if (l1Result.isErr)
            return l1Result;
        
        auto id = l1Result.unwrap();
        
        // Best-effort write to L2 and L3
        if (l2 !is null)
            l2.put(data);
        
        if (l3 !is null)
            l3.put(data);
        
        return Ok!(ArtifactId, DistributedError)(id);
    }
    
    Result!(bool[], DistributedError) hasMany(ArtifactId[] ids) @trusted
    {
        return l1.hasMany(ids);
    }
    
    Result!(ubyte[][], DistributedError) getMany(ArtifactId[] ids) @trusted
    {
        ubyte[][] results;
        results.reserve(ids.length);
        
        foreach (id; ids)
        {
            auto result = get(id);
            if (result.isErr)
                return Err!(ubyte[][], DistributedError)(result.unwrapErr());
            results ~= result.unwrap();
        }
        
        return Ok!(ubyte[][], DistributedError)(results);
    }
}