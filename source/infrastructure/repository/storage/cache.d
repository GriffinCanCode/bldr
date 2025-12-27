module infrastructure.repository.storage.cache;

import std.file : exists, mkdirRecurse, read, write, dirEntries, SpanMode, remove, isDir;
import std.path : buildPath;
import std.datetime : Clock, SysTime;
import std.algorithm : map, filter;
import std.array : array;
import std.conv : to;
import infrastructure.repository.core.types;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Repository cache manager
/// Stores fetched repositories and their metadata
final class RepositoryCache
{
    private string cacheDir;
    private CachedRepository[string] cache;  // name -> cached repo
    private string metadataPath;
    
    this(string cacheDir = ".builder-cache/repositories") @safe
    {
        this.cacheDir = cacheDir;
        this.metadataPath = buildPath(cacheDir, "metadata.bin");
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        loadMetadata();
    }
    
    /// Get cached repository by name
    Result!(CachedRepository, RepositoryError) get(string name) @system
    {
        auto cached = name in cache;
        if (cached is null)
        {
            return Result!(CachedRepository, RepositoryError).err(
                new RepositoryError("Repository not in cache: " ~ name));
        }
        
        // Validate cache entry
        if (!cached.isValid())
        {
            // Invalid cache entry - remove it
            structuredLog.warning("invalid_cache_entry_for_").field("detail", "Invalid cache entry for " ~ name ~ ", removing...").emit();
            cache.remove(name);
            saveMetadata();
            
            return Result!(CachedRepository, RepositoryError).err(
                new RepositoryError("Cached repository is invalid: " ~ name));
        }
        
        return Result!(CachedRepository, RepositoryError).ok(*cached);
    }
    
    /// Put repository in cache
    Result!RepositoryError put(string name, string localPath, string cacheKey) @trusted
    {
        import std.algorithm : each;
        
        if (!exists(localPath) || !isDir(localPath))
        {
            return Result!RepositoryError.err(
                new RepositoryError("Repository path does not exist or is not a directory: " ~ localPath));
        }
        
        // Gather file list for dependency tracking
        string[] files;
        try
        {
            files = dirEntries(localPath, SpanMode.depth)
                .filter!(e => e.isFile)
                .map!(e => e.name)
                .array;
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_enumerate_files_in_repository_").field("detail", "Failed to enumerate files in repository: " ~ e.msg).emit();
        }
        
        // Calculate size
        size_t size = 0;
        try
        {
            import std.file : getSize;
            foreach (file; files)
            {
                size += getSize(file);
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_calculate_repository_size_").field("detail", "Failed to calculate repository size: " ~ e.msg).emit();
        }
        
        auto cached = CachedRepository(
            name,
            cacheKey,
            localPath,
            Clock.currTime(),
            size,
            files
        );
        
        cache[name] = cached;
        saveMetadata();
        
        structuredLog.debug_("cached_repository_").field("detail", "Cached repository: " ~ name ~ " (" ~ (size / 1024).to!string ~ " KB)").emit();
        
        return Ok!RepositoryError();
    }
    
    /// Check if repository is cached
    bool has(string name) const pure @safe nothrow
    {
        return (name in cache) !is null;
    }
    
    /// Remove repository from cache
    Result!RepositoryError remove(string name) @trusted
    {
        auto cached = name in cache;
        if (cached is null)
        {
            return Result!RepositoryError.err(
                new RepositoryError("Repository not in cache: " ~ name));
        }
        
        // Remove from disk
        try
        {
            import std.file : rmdirRecurse;
            if (exists(cached.localPath))
            {
                rmdirRecurse(cached.localPath);
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_remove_repository_from_disk_").field("detail", "Failed to remove repository from disk: " ~ e.msg).emit();
        }
        
        // Remove from memory cache
        cache.remove(name);
        saveMetadata();
        
        structuredLog.info("removed_repository_from_cache_").field("detail", "Removed repository from cache: " ~ name).emit();
        
        return Ok!RepositoryError();
    }
    
    /// Clear all cached repositories
    Result!RepositoryError clear() @trusted
    {
        structuredLog.info("clearing_repository_cache").emit();
        
        foreach (name; cache.byKey().array)
        {
            auto result = remove(name);
            if (result.isErr)
            {
                structuredLog.warning("failed_to_remove_").field("detail", "Failed to remove " ~ name ~ ": " ~ result.unwrapErr().message()).emit();
            }
        }
        
        cache.clear();
        saveMetadata();
        
        structuredLog.info("repository_cache_cleared").emit();
        
        return Ok!RepositoryError();
    }
    
    /// Get cache statistics
    struct CacheStats
    {
        size_t count;
        size_t totalSize;
        SysTime oldestFetch;
        SysTime newestFetch;
    }
    
    CacheStats getStats() const @safe
    {
        CacheStats stats;
        stats.count = cache.length;
        
        if (cache.length == 0)
            return stats;
        
        stats.oldestFetch = Clock.currTime();
        stats.newestFetch = SysTime.min;
        
        foreach (ref cached; cache.byValue)
        {
            stats.totalSize += cached.size;
            
            if (cached.fetchedAt < stats.oldestFetch)
                stats.oldestFetch = cached.fetchedAt;
            
            if (cached.fetchedAt > stats.newestFetch)
                stats.newestFetch = cached.fetchedAt;
        }
        
        return stats;
    }
    
    /// Load metadata from disk
    private void loadMetadata() @trusted
    {
        if (!exists(metadataPath))
            return;
        
        try
        {
            import std.json : parseJSON, JSONValue;
            
            auto content = cast(string)read(metadataPath);
            auto json = parseJSON(content);
            
            foreach (string name, ref JSONValue repoJson; json.object)
            {
                CachedRepository cached;
                cached.name = name;
                cached.cacheKey = repoJson["cacheKey"].str;
                cached.localPath = repoJson["localPath"].str;
                cached.size = repoJson["size"].integer.to!size_t;
                
                // Parse timestamp
                import std.datetime : SysTime, UTC;
                cached.fetchedAt = SysTime.fromISOExtString(repoJson["fetchedAt"].str);
                
                // Parse files array
                if ("files" in repoJson.object)
                {
                    foreach (ref fileJson; repoJson["files"].array)
                    {
                        cached.files ~= fileJson.str;
                    }
                }
                
                cache[name] = cached;
            }
            
            structuredLog.debug_("loaded_").field("detail", "Loaded " ~ cache.length.to!string ~ " cached repositories").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_load_repository_cache_metadata").field("detail", "Failed to load repository cache metadata: " ~ e.msg).emit();
        }
    }
    
    /// Save metadata to disk
    private void saveMetadata() @trusted
    {
        try
        {
            import std.json : JSONValue;
            
            JSONValue json = JSONValue.emptyObject;
            
            foreach (name, ref cached; cache)
            {
                JSONValue repoJson = JSONValue.emptyObject;
                repoJson["cacheKey"] = cached.cacheKey;
                repoJson["localPath"] = cached.localPath;
                repoJson["size"] = cached.size;
                repoJson["fetchedAt"] = cached.fetchedAt.toISOExtString();
                
                // Save files array (limit to avoid huge metadata)
                JSONValue[] filesJson;
                foreach (file; cached.files[0 .. $])
                {
                    filesJson ~= JSONValue(file);
                }
                repoJson["files"] = filesJson;
                
                json[name] = repoJson;
            }
            
            write(metadataPath, json.toPrettyString());
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_save_repository_cache_metadata").field("detail", "Failed to save repository cache metadata: " ~ e.msg).emit();
        }
    }
}

