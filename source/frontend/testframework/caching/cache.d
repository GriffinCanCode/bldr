module frontend.testframework.caching.cache;

import std.stdio;
import std.file : exists, mkdirRecurse;
import std.path : buildPath;
import std.datetime : Clock, SysTime, Duration, dur;
import std.algorithm : filter, map, sort;
import std.array : array, join;
import std.conv : to;
import core.sync.mutex : Mutex;
import frontend.testframework.results : TestResult, TestCase;
import frontend.testframework.caching.storage : TestCacheStorage, StorageEntry = TestCacheEntry;
import engine.caching.policies.eviction : EvictionPolicy;
import engine.caching.incremental.dependency : DependencyCache;
import frontend.testframework.incremental.selector : IncrementalTestSelector;
import infrastructure.utils.logging;

/// Test cache configuration
struct TestCacheConfig
{
    size_t maxEntries = 10_000;         // Max cached tests
    size_t maxSize = 512 * 1024 * 1024; // 512 MB
    Duration maxAge = dur!"days"(30);    // 30 days
    bool hermetic = true;                // Verify environment
}

/// Test cache entry
struct TestCacheEntry
{
    string testId;              // Test identifier
    string contentHash;         // Hash of test code + dependencies
    string envHash;             // Hash of environment (hermetic)
    TestResult result;          // Cached result
    SysTime timestamp;          // When test was run
    SysTime lastAccess;         // Last cache access (LRU)
    size_t runCount;            // Number of times executed
    size_t failCount;           // Number of failures
}

/// Multi-level test result cache
/// Integrates with ActionCache and incremental test selection
final class TestCache
{
    private string cacheDir;
    private string cacheFile;
    private TestCacheConfig config;
    private TestCacheEntry[string] entries;
    private Mutex mutex;
    private bool dirty;
    private EvictionPolicy evictionPolicy;
    private IncrementalTestSelector selector;
    
    // Statistics
    private size_t hits;
    private size_t misses;
    
    this(string cacheDir = ".builder-cache/tests", TestCacheConfig config = TestCacheConfig.init) @system
    {
        this.cacheDir = cacheDir;
        this.cacheFile = buildPath(cacheDir, "test-results.bin");
        this.config = config;
        this.mutex = new Mutex();
        this.dirty = false;
        
        // Initialize eviction policy with config values
        this.evictionPolicy = EvictionPolicy(
            config.maxSize,
            config.maxEntries,
            cast(size_t)config.maxAge.total!"days"
        );
        
        // Initialize incremental test selector
        auto depCache = new DependencyCache(buildPath(cacheDir, "test-deps"));
        this.selector = new IncrementalTestSelector(depCache);
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        loadCache();
    }
    
    /// Check if test result is cached
    bool isCached(
        string testId,
        string contentHash,
        string envHash = ""
    ) @system
    {
        synchronized (mutex)
        {
            auto entryPtr = testId in entries;
            if (entryPtr is null)
            {
                misses++;
                return false;
            }
            
            // Validate content hash
            if (entryPtr.contentHash != contentHash)
            {
                misses++;
                return false;
            }
            
            // Validate environment hash (hermetic)
            if (config.hermetic && envHash.length > 0)
            {
                if (entryPtr.envHash != envHash)
                {
                    structuredLog.debug_("test_cache_miss_environment_changed_for_").field("detail", "Test cache miss: environment changed for " ~ testId).emit();
                    misses++;
                    return false;
                }
            }
            
            // Check age
            immutable now = Clock.currTime();
            immutable age = now - entryPtr.timestamp;
            if (age > config.maxAge)
            {
                structuredLog.debug_("test_cache_miss_entry_too_old_for_").field("detail", "Test cache miss: entry too old for " ~ testId).emit();
                misses++;
                return false;
            }
            
            // Update access time
            entryPtr.lastAccess = now;
            dirty = true;
            hits++;
            
            return true;
        }
    }
    
    /// Get cached test result
    TestResult get(string testId) @system
    {
        synchronized (mutex)
        {
            auto entryPtr = testId in entries;
            if (entryPtr is null)
                return TestResult.init;
            
            entryPtr.lastAccess = Clock.currTime();
            dirty = true;
            
            auto result = entryPtr.result;
            result.cached = true;
            return result;
        }
    }
    
    /// Store test result in cache
    void put(
        string testId,
        string contentHash,
        string envHash,
        TestResult result
    ) @system
    {
        synchronized (mutex)
        {
            TestCacheEntry entry;
            entry.testId = testId;
            entry.contentHash = contentHash;
            entry.envHash = envHash;
            entry.result = result;
            entry.timestamp = Clock.currTime();
            entry.lastAccess = Clock.currTime();
            
            // Update statistics from previous entry
            auto existingPtr = testId in entries;
            if (existingPtr !is null)
            {
                entry.runCount = existingPtr.runCount + 1;
                entry.failCount = existingPtr.failCount + (result.passed ? 0 : 1);
            }
            else
            {
                entry.runCount = 1;
                entry.failCount = result.passed ? 0 : 1;
            }
            
            entries[testId] = entry;
            dirty = true;
            
            // Check if we need to evict
            if (entries.length > config.maxEntries)
                evictOldest();
        }
    }
    
    /// Invalidate cached test
    void invalidate(string testId) @system nothrow
    {
        try
        {
            synchronized (mutex)
            {
                entries.remove(testId);
                dirty = true;
            }
        }
        catch (Exception) {}
    }
    
    /// Clear entire cache
    void clear() @system nothrow
    {
        try
        {
            synchronized (mutex)
            {
                entries.clear();
                dirty = true;
            }
        }
        catch (Exception) {}
    }
    
    /// Flush cache to disk
    void flush() @system
    {
        synchronized (mutex)
        {
            if (!dirty)
                return;
            
            try
            {
                // Convert to storage entries
                StorageEntry[string] storageEntries;
                foreach (key, entry; entries)
                {
                    StorageEntry se;
                    se.testId = entry.testId;
                    se.contentHash = entry.contentHash;
                    se.envHash = entry.envHash;
                    se.result = entry.result;
                    se.timestamp = entry.timestamp;
                    se.duration = entry.result.duration;
                    storageEntries[key] = se;
                }
                
                TestCacheStorage.save(cacheFile, storageEntries);
                dirty = false;
                structuredLog.debug_("flushed_test_cache_").field("detail", "Flushed test cache: " ~ entries.length.to!string ~ " entries").emit();
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_flush_test_cache_").field("detail", "Failed to flush test cache: " ~ e.msg).emit();
            }
        }
    }
    
    /// Load cache from disk
    private void loadCache() @system
    {
        if (!exists(cacheFile))
            return;
        
        try
        {
            // Load storage entries and convert
            auto storageEntries = TestCacheStorage.load(cacheFile);
            foreach (key, se; storageEntries)
            {
                TestCacheEntry entry;
                entry.testId = se.testId;
                entry.contentHash = se.contentHash;
                entry.envHash = se.envHash;
                entry.result = se.result;
                entry.timestamp = se.timestamp;
                entry.lastAccess = se.timestamp;
                entry.runCount = 1;
                entry.failCount = se.result.passed ? 0 : 1;
                entries[key] = entry;
            }
            structuredLog.debug_("loaded_test_cache_").field("detail", "Loaded test cache: " ~ entries.length.to!string ~ " entries").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_load_test_cache_").field("detail", "Failed to load test cache: " ~ e.msg).emit();
            entries.clear();
        }
    }
    
    /// Evict entries using central eviction policy
    private void evictOldest() @system
    {
        if (entries.length <= config.maxEntries)
            return;
        
        // Calculate current size (sum of result data)
        size_t currentSize = 0;
        foreach (ref entry; entries)
        {
            currentSize += entry.testId.length + entry.contentHash.length + 
                          entry.envHash.length + 256; // Estimated overhead
        }
        
        // Delegate to eviction policy
        auto toEvict = evictionPolicy.selectEvictions(entries, currentSize);
        
        foreach (key; toEvict)
        {
            entries.remove(key);
        }
        
        if (toEvict.length > 0)
        {
            structuredLog.debug_("test_cache_evicted_").field("detail", "Test cache evicted " ~ toEvict.length.to!string ~ " entries").emit();
        }
    }
    
    /// Get cache statistics
    struct CacheStats
    {
        size_t totalEntries;
        size_t hits;
        size_t misses;
        double hitRate;
        size_t totalRuns;
        size_t totalFailures;
    }
    
    CacheStats getStats() @system
    {
        synchronized (mutex)
        {
            CacheStats stats;
            stats.totalEntries = entries.length;
            stats.hits = hits;
            stats.misses = misses;
            
            immutable total = hits + misses;
            if (total > 0)
                stats.hitRate = cast(double)hits / total;
            
            foreach (ref entry; entries)
            {
                stats.totalRuns += entry.runCount;
                stats.totalFailures += entry.failCount;
            }
            
            return stats;
        }
    }
    
    /// Compute content hash for test
    /// Includes test code, dependencies, and configuration
    /// Uses FastHash for consistency
    static string computeContentHash(
        string testCode,
        string[] dependencies,
        string config
    ) @trusted
    {
        import infrastructure.utils.files.hash : FastHash;
        return FastHash.hashString(testCode ~ dependencies.join("") ~ config);
    }
    
    /// Compute environment hash (hermetic verification)
    /// Includes environment variables, system info, tool versions
    /// Uses FastHash for consistency
    static string computeEnvHash(
        string[string] envVars,
        string toolVersions
    ) @trusted
    {
        import std.algorithm : sort;
        import std.array : join;
        import infrastructure.utils.files.hash : FastHash;
        
        // Sort env vars for deterministic hash
        auto keys = envVars.keys.sort().array;
        string envString;
        foreach (key; keys)
        {
            envString ~= key ~ "=" ~ envVars[key] ~ "\n";
        }
        
        return FastHash.hashString(envString ~ toolVersions);
    }
}

