module engine.caching.incremental.dependency;

import std.algorithm;
import std.array;
import std.conv : to;
import std.datetime;
import std.file;
import std.path;
import core.sync.mutex;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// File-level dependency relationship
/// Tracks which source files depend on which other files (headers, modules, etc.)
struct FileDependency
{
    string sourceFile;        // Source file path
    string[] dependencies;    // Files this source depends on
    string sourceHash;        // Hash of source file content
    string[] depHashes;       // Hashes of dependency files
    SysTime timestamp;        // When this was recorded
    
    /// Check if this dependency is still valid
    bool isValid() const @system
    {
        if (!exists(sourceFile) || FastHash.hashFile(sourceFile) != sourceHash)
            return false;
        
        foreach (i, dep; dependencies)
        {
            if (!exists(dep) || (i < depHashes.length && FastHash.hashFile(dep) != depHashes[i]))
                return false;
        }
        return true;
    }
    
    /// Check if any dependency has changed
    bool hasDependencyChanges() const @system
    {
        foreach (i, dep; dependencies)
        {
            if (!exists(dep) || (i < depHashes.length && FastHash.hashFile(dep) != depHashes[i]))
                return true;
        }
        return false;
    }
}

/// Dependency change analysis result
struct DependencyChanges
{
    string[] filesToRebuild;      // Files that need recompilation
    string[] changedDependencies; // Dependencies that changed
    string[string] changeReasons; // Reason for each file rebuild
}

/// Module-level dependency tracking cache
/// Persists file-to-dependency relationships for incremental compilation
final class DependencyCache
{
    private string cacheDir;
    private FileDependency[string] dependencies; // Key: normalized source path
    private bool dirty;
    private core.sync.mutex.Mutex mutex;
    
    this(string cacheDir = ".builder-cache/incremental") @system
    {
        this.cacheDir = cacheDir;
        this.dirty = false;
        this.mutex = new core.sync.mutex.Mutex();
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        load();
    }
    
    /// Record dependencies for a source file
    void recordDependencies(string sourceFile, string[] dependencies) @system
    {
        synchronized (mutex)
        {
            FileDependency dep;
            dep.sourceFile = sourceFile;
            dep.dependencies = dependencies.dup;
            dep.timestamp = Clock.currTime();
            
            if (exists(sourceFile))
                dep.sourceHash = FastHash.hashFile(sourceFile);
            
            foreach (depFile; dependencies)
            {
                if (exists(depFile))
                    dep.depHashes ~= FastHash.hashFile(depFile);
            }
            
            this.dependencies[buildNormalizedPath(sourceFile)] = dep;
            dirty = true;
            
            Logger.debugLog("Recorded " ~ dependencies.length.to!string ~ 
                          " dependencies for " ~ sourceFile);
        }
    }
    
    /// Get dependencies for a source file
    BuildResult!(FileDependency*) getDependencies(string sourceFile) @system
    {
        synchronized (mutex)
        {
            auto depPtr = buildNormalizedPath(sourceFile) in dependencies;
            return depPtr is null 
                ? BuildResult!(FileDependency*).err(
                    Errors.generic("No dependencies recorded for: " ~ sourceFile, ErrorCode.FileNotFound)
                        .withLocation(__FILE__, __LINE__)
                        .build())
                : BuildResult!(FileDependency*).ok(depPtr);
        }
    }
    
    /// Analyze what needs to be rebuilt based on changed files
    /// Returns list of source files that need recompilation
    DependencyChanges analyzeChanges(string[] changedFiles) @system
    {
        synchronized (mutex)
        {
            DependencyChanges changes;
            bool[string] toRebuild;
            bool[string] changedSet;
            
            // Normalize all changed files
            foreach (file; changedFiles)
            {
                changedSet[buildNormalizedPath(file)] = true;
            }
            
            // Find all sources that depend on changed files
            foreach (key, dep; dependencies)
            {
                // Check if source itself changed
                if (key in changedSet)
                {
                    toRebuild[dep.sourceFile] = true;
                    changes.changeReasons[dep.sourceFile] = "source file modified";
                    continue;
                }
                
                // Check if any dependency changed
                foreach (depFile; dep.dependencies)
                {
                    auto normalizedDep = buildNormalizedPath(depFile);
                    if (normalizedDep in changedSet)
                    {
                        toRebuild[dep.sourceFile] = true;
                        changes.changeReasons[dep.sourceFile] = 
                            "dependency changed: " ~ baseName(depFile);
                        changes.changedDependencies ~= depFile;
                        break;
                    }
                }
            }
            
            changes.filesToRebuild = toRebuild.keys;
            return changes;
        }
    }
    
    /// Invalidate dependencies for specific files
    void invalidate(string[] sourceFiles) @system
    {
        synchronized (mutex)
        {
            foreach (file; sourceFiles)
            {
                auto key = buildNormalizedPath(file);
                dependencies.remove(key);
            }
            dirty = true;
        }
    }
    
    /// Clear all cached dependencies
    void clear() @system
    {
        synchronized (mutex)
        {
            dependencies.clear();
            dirty = true;
        }
    }
    
    /// Flush to disk
    void flush() @system
    {
        synchronized (mutex)
        {
            if (!dirty) return;
            
            try
            {
                save();
                dirty = false;
            }
            catch (Exception e)
            {
                Logger.warning("Failed to flush dependency cache: " ~ e.msg);
            }
        }
    }
    
    /// Get statistics
    struct Stats
    {
        size_t totalSources;
        size_t totalDependencies;
        size_t validEntries;
        size_t invalidEntries;
    }
    
    Stats getStats() @system
    {
        synchronized (mutex)
        {
            Stats stats;
            stats.totalSources = dependencies.length;
            
            foreach (dep; dependencies.values)
            {
                stats.totalDependencies += dep.dependencies.length;
                if (dep.isValid())
                    stats.validEntries++;
                else
                    stats.invalidEntries++;
            }
            
            return stats;
        }
    }
    
    private void load() @system
    {
        import engine.caching.incremental.storage;
        
        try
        {
            auto storage = new DependencyStorage(cacheDir);
            auto result = storage.load();
            
            if (result.isOk)
            {
                auto loaded = result.unwrap();
                foreach (dep; loaded)
                {
                    auto key = buildNormalizedPath(dep.sourceFile);
                    dependencies[key] = dep;
                }
                
                Logger.debugLog("Loaded " ~ dependencies.length.to!string ~ 
                              " dependency entries from cache");
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to load dependency cache: " ~ e.msg);
        }
    }
    
    private void save() @system
    {
        import engine.caching.incremental.storage;
        
        auto storage = new DependencyStorage(cacheDir);
        auto entries = dependencies.values;
        
        auto result = storage.save(entries);
        if (result.isErr)
        {
            Logger.warning("Failed to save dependency cache: " ~ 
                         result.unwrapErr().message());
        }
        else
        {
            Logger.debugLog("Saved " ~ entries.length.to!string ~ 
                          " dependency entries to cache");
        }
    }
    
    ~this() @nogc nothrow
    {
        // Don't attempt to flush in destructor - allocation is not allowed during GC
        // Users should call flush() explicitly before the cache goes out of scope
    }
}

