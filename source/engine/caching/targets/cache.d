module engine.caching.targets.cache;

import std.stdio;
import std.file;
import std.path;
import std.conv;
import std.algorithm;
import std.array;
import std.datetime;
import std.typecons : tuple;
import core.sync.mutex;
import infrastructure.utils.files.hash;
import infrastructure.utils.simd.hash;
import engine.caching.targets.storage;
import engine.caching.policies.eviction;
import infrastructure.utils.security.integrity;
import infrastructure.utils.concurrency.lockfree;
import infrastructure.errors;

/// High-performance build cache with lazy writes and LRU eviction
/// 
/// Thread Safety:
/// - All public methods are synchronized via internal mutex
/// - Safe for concurrent access from multiple build threads
/// 
/// Security:
/// - BLAKE3-based HMAC signatures prevent cache tampering
/// - Workspace-specific keys for isolation
/// - Automatic expiration (30 days default)
/// - Constant-time signature verification
/// 
/// Optimizations:
/// - Binary format: 5-10x faster than JSON
/// - Lazy writes: Write once per build instead of per target
/// - Two-tier hashing: Check metadata before content hash (SIMD-accelerated)
/// - LRU eviction: Automatic cache size management
/// - SIMD comparisons: 2-3x faster hash validation
final class BuildCache
{
    /// Configuration constants
    private enum size_t SIMD_HASH_THRESHOLD = 32;  // Min hash string length for SIMD comparison
    
    private string cacheDir;
    private immutable string cacheFilePath;  // Pre-computed to avoid allocation in destructor
    private CacheEntry[string] entries;
    private bool dirty;
    private EvictionPolicy eviction;
    private CacheConfig config;
    private size_t contentHashCount;  // Stats: how many content hashes performed
    private size_t metadataHitCount;  // Stats: how many metadata hits
    private Mutex cacheMutex;  // Protects all mutable state
    private IntegrityValidator validator;  // HMAC validation for tampering detection
    private FastHashCache hashCache;  // Per-build-session hash memoization
    private bool closed = false;  // Track if explicitly closed
    
    /// Constructor: Initialize cache with directory and configuration
    /// 
    /// Safety: This constructor is @system because:
    /// 1. buildPath() is safe string concatenation
    /// 2. File system operations (exists, mkdirRecurse) are inherently unsafe I/O
    /// 3. Mutex creation is safe
    /// 4. loadCache() is a member function call
    /// 
    /// Invariants:
    /// - cacheDir directory exists after construction
    /// - cacheMutex is properly initialized
    /// - validator is initialized with workspace-specific key
    /// 
    /// What could go wrong:
    /// - Directory creation could fail due to permissions: throws exception
    /// - loadCache() could fail to read existing cache: handled gracefully
    /// - getcwd() could fail: throws exception (caller must handle)
    this(string cacheDir = ".builder-cache", CacheConfig config = CacheConfig.init) @system
    {
        this.cacheDir = cacheDir;
        this.cacheFilePath = buildPath(cacheDir, "cache.bin");  // Pre-compute path
        this.config = config;
        this.dirty = false;
        this.eviction = EvictionPolicy(config.maxSize, config.maxEntries, config.maxAge);
        this.cacheMutex = new Mutex();
        
        // Initialize hash cache with mutex for thread safety
        this.hashCache.initialize();
        
        // Initialize integrity validator with workspace-specific key
        import std.file : getcwd;
        this.validator = IntegrityValidator.fromEnvironment(getcwd());
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        loadCache();
    }
    
    /// Explicitly close cache and flush to disk
    /// Call this before program termination to ensure data is saved
    /// Prevents data loss from abnormal shutdown or GC finalization
    /// Multiple calls are safe (idempotent)
    void close() @system
    {
        synchronized (cacheMutex)
        {
            if (!closed)
            {
                if (dirty) flush(false); // Flush without eviction on close
                closed = true;
            }
        }
    }
    
    /// Destructor: ensure cache is written (best-effort fallback)
    /// NOTE: Always call close() explicitly before program termination
    ~this()
    {
        import core.memory : GC;
        if (closed || !dirty || GC.inFinalizer()) return;
        
        try
        {
            import infrastructure.utils.logging.logger;
            Logger.debugLog("Warning: Cache destroyed without explicit close() - flushing as fallback");
            flush(false);
        }
        catch (Exception e) {}
    }
    
    /// Check if a target is cached and up-to-date
    /// Uses two-tier hashing for 1000x speedup on unchanged files
    /// Thread-safe via internal mutex
    /// 
    /// WARNING: TOCTOU race condition exists but is benign for build caching.
    /// Safe failure mode: unnecessary rebuild. NOT for security-critical use.
    bool isCached(string targetId, scope const(string)[] sources, scope const(string)[] deps) @system
    {
        synchronized (cacheMutex)
        {
            auto entryPtr = targetId in entries;
            if (entryPtr is null) return false;
            
            entryPtr.lastAccess = Clock.currTime();
            dirty = true;
            
            // Check if any source files changed (two-tier strategy)
            foreach (source; sources)
            {
                if (!exists(source)) return false;
                
                const hashResult = FastHash.hashFileTwoTier(source, entryPtr.sourceMetadata.get(source, ""));
                
                hashResult.contentHashed ? contentHashCount++ : metadataHitCount++;
                
                if (hashResult.contentHashed && 
                    !SIMDHash.equals(hashResult.contentHash, entryPtr.sourceHashes.get(source, "")))
                    return false;
            }
            
            // Check if any dependencies changed
            return !deps.any!(dep => dep !in entries || 
                !SIMDHash.equals(entries[dep].buildHash, entryPtr.depHashes.get(dep, "")));
        }
    }
    
    /// Reusable workspace for parallel hashing to reduce allocations
    private static string[] hashWorkspace;
    
    /// Update cache entry for a target
    /// Defers write until flush() is called
    /// Uses SIMD-aware parallel hashing for multiple sources
    /// Thread-safe: synchronized via internal mutex
    /// 
    /// Safety: This function is @system because:
    /// 1. Mutex synchronization ensures thread-safe access to entries
    /// 2. File system operations (FastHash.hashFile, timeLastModified) are unsafe I/O
    /// 3. Parallel hashing may spawn threads (synchronized internally)
    /// 4. Associative array insert/update is memory-safe
    /// 
    /// Invariants:
    /// - cacheMutex must be held during entry creation and insertion
    /// - dirty flag is set to ensure flush() will persist changes
    /// - All file hashes are computed before entry is created
    /// 
    /// What could go wrong:
    /// - Hash computation could fail for missing files: exception propagates
    /// - Parallel hashing could fail: exception propagates to caller
    /// - Memory usage could grow: limited by eviction policy on flush()
    /// - File modification during hashing: hash reflects state at that moment
    void update(string targetId, scope const(string)[] sources, scope const(string)[] deps, string outputHash) @system
    {
        synchronized (cacheMutex)
        {
            CacheEntry entry;
            entry.targetId = targetId;
            entry.timestamp = Clock.currTime();
            entry.lastAccess = Clock.currTime();
            entry.buildHash = outputHash;
        
        // Hash all source files with memoization to avoid duplicate hashing
        auto existingSources = sources.filter!exists;
        
        if (sources.length > 4) {
            // Use work-stealing parallel execution for better load balancing
            import infrastructure.utils.concurrency.parallel;
            import std.typecons : Tuple, tuple;
            
            alias HashResult = Tuple!(string, string, string);
            auto hashes = ParallelExecutor.mapWorkStealing(
                cast(string[])existingSources.array,
                (string source) {
                    auto cached = hashCache.get(source);
                    if (cached.found)
                        return tuple(source, cached.contentHash, cached.metadataHash);
                    
                    auto contentHash = FastHash.hashFile(source);
                    auto metadataHash = FastHash.hashMetadata(source);
                    hashCache.put(source, contentHash, metadataHash);
                    return tuple(source, contentHash, metadataHash);
                }
            );
            
            foreach (r; hashes)
            {
                entry.sourceHashes[r[0]] = r[1];
                entry.sourceMetadata[r[0]] = r[2];
            }
        } else {
            // Sequential for small number of files (avoid overhead)
            foreach (source; existingSources)
            {
                auto cached = hashCache.get(source);
                if (cached.found) {
                    entry.sourceHashes[source] = cached.contentHash;
                    entry.sourceMetadata[source] = cached.metadataHash;
                } else {
                    auto contentHash = FastHash.hashFile(source);
                    auto metadataHash = FastHash.hashMetadata(source);
                    hashCache.put(source, contentHash, metadataHash);
                    entry.sourceHashes[source] = contentHash;
                    entry.sourceMetadata[source] = metadataHash;
                }
            }
        }
        
            // Store dependency hashes
            foreach (dep; deps)
            {
                if (dep in entries)
                    entry.depHashes[dep] = entries[dep].buildHash;
            }
            
            entries[targetId] = entry;
            dirty = true;
        }
    }
    
    /// Invalidate cache for a target
    void invalidate(in string targetId) @system nothrow
    {
        try synchronized (cacheMutex)
        {
            entries.remove(targetId);
            dirty = true;
        }
        catch (Exception) {}
    }
    
    /// Clear entire cache
    /// Thread-safe: synchronized via internal mutex
    void clear() @system
    {
        synchronized (cacheMutex)
        {
            entries.clear();
            dirty = false;
        }
        
        if (exists(cacheDir))
            rmdirRecurse(cacheDir);
        mkdirRecurse(cacheDir);
    }
    
    /// Flush cache to disk (lazy write)
    /// Called once at end of build instead of on every update
    void flush(in bool runEviction = true) @system
    {
        synchronized (cacheMutex)
        {
            if (!dirty) return;
        
            // Run eviction policy before saving
            if (runEviction)
            {
                try
                {
                    auto toEvict = eviction.selectEvictions(entries, eviction.calculateTotalSize(entries));
                    toEvict.each!(key => entries.remove(key));
                    
                    if (toEvict.length > 0)
                        writeln("Cache evicted ", toEvict.length, " entries");
                }
                catch (Exception)
                {
                    writeln("Warning: Cache eviction failed, saving without eviction");
                }
            }
        
            saveCache();
            dirty = false;
            hashCache.clear();
        }
    }
    
    /// Get cache statistics
    struct CacheStats
    {
        size_t totalEntries;
        size_t totalSize;
        SysTime oldestEntry;
        SysTime newestEntry;
        size_t contentHashes;    // How many content hashes performed
        size_t metadataHits;     // How many metadata hits (fast path)
        float metadataHitRate;   // Percentage of fast path hits
        size_t hashCacheHits;    // How many build-session hash cache hits
        size_t hashCacheMisses;  // How many build-session hash cache misses
        float hashCacheHitRate;  // Percentage of hash cache hits
    }
    
    /// Get cache statistics
    /// Thread-safe: synchronized via internal mutex
    CacheStats getStats() const @system
    {
        synchronized (cast(Mutex)cacheMutex)  // const_cast for read-only access
        {
            CacheStats stats;
            stats.totalEntries = entries.length;
            
            if (entries.empty)
                return stats;
            
            stats.oldestEntry = entries.values.map!(e => e.timestamp).minElement;
            stats.newestEntry = entries.values.map!(e => e.timestamp).maxElement;
            
            // Calculate cache size
            stats.totalSize = eviction.calculateTotalSize(entries);
            
            // Hash statistics
            stats.contentHashes = contentHashCount;
            stats.metadataHits = metadataHitCount;
            
            immutable total = contentHashCount + metadataHitCount;
            if (total > 0)
                stats.metadataHitRate = (metadataHitCount * 100.0) / total;
            
            // Build-session hash cache statistics
            auto hashCacheStats = hashCache.getStats();
            stats.hashCacheHits = hashCacheStats.hits;
            stats.hashCacheMisses = hashCacheStats.misses;
            stats.hashCacheHitRate = hashCacheStats.hitRate;
            
            return stats;
        }
    }
    
    private void loadCache() @system
    {
        if (!exists(cacheFilePath))
        {
            // Try loading old JSON format for migration
            string jsonCacheFile = buildPath(cacheDir, "cache.json");
            if (exists(jsonCacheFile))
            {
                try
                {
                    loadJsonCache(jsonCacheFile);
                    writeln("Migrated cache from JSON to binary format");
                    dirty = true; // Will save as binary on next flush
                    return;
                }
                catch (Exception e)
                {
                    // Migration failed, start fresh
                    writeln("Warning: Could not migrate old cache format");
                    
                    // Log with new error system
                    // Use smart constructor with typed suggestions
                    auto error = cacheLoadError(jsonCacheFile, "Failed to migrate legacy JSON cache format: " ~ e.msg);
                    error.addContext(ErrorContext("migrating JSON cache", jsonCacheFile));
                    error.addSuggestion("The legacy JSON cache format is incompatible with the current version");
                    error.addSuggestion("The cache will be automatically rebuilt using the new binary format");
                }
            }
            return;
        }
        
        try
        {
            // Read file data - ubyte[] is automatically allocated by read()
            auto fileData = cast(ubyte[])std.file.read(cacheFilePath);
            
            // Deserialize signed data
            auto signed = SignedData.deserialize(fileData);
            
            // Verify integrity signature
            if (!validator.verifyWithMetadata(signed))
            {
                writeln("Warning: Cache signature verification failed, starting fresh");
                entries.clear();
                
                // Use builder pattern with typed suggestions for corruption
                import infrastructure.errors.types.context : ErrorSuggestion;
                
                auto error = ErrorBuilder!CacheError.create("Cache signature verification failed - possible tampering or corruption detected", ErrorCode.CacheCorrupted)
                    .withContext("verifying cache integrity", cacheFilePath)
                    .withFileCheck("The cache file may have been modified or corrupted")
                    .withCommand("Remove corrupted cache", "bldr clean")
                    .withCommand("Check file system integrity", "fsck")
                    .withFileCheck("Ensure no other processes are modifying files in .builder-cache/")
                    .build();
                error.cachePath = cacheFilePath;
                return;
            }
            
            // Check if cache is expired (30 days max age)
            import core.time : days;
            if (IntegrityValidator.isExpired(signed, 30.days))
            {
                writeln("Cache expired, starting fresh");
                entries.clear();
                return;
            }
            
            // Deserialize cache entries from verified data
            // Uses zero-copy string slicing from data
            entries = BinaryStorage.deserialize!CacheEntry(signed.data);
            
            // Note: data is now referenced by strings in entries
            // GC will keep it alive as long as entries exist
        }
        catch (Exception e)
        {
            // Cache corrupted, start fresh
            writeln("Warning: Cache corrupted, starting fresh: ", e.msg);
            entries.clear();
            
            // Log with new error system
            // Use smart constructor with typed suggestions
            auto error = cacheLoadError(cacheFilePath, e.msg);
            error.addContext(ErrorContext("loading binary cache", cacheFilePath));
            error.addSuggestion("The cache file is corrupted or from an incompatible version");
            error.addSuggestion(ErrorSuggestion.command("Check available disk space", "df -h"));
            error.addSuggestion(ErrorSuggestion.fileCheck("Ensure .builder-cache/ directory has proper permissions"));
        }
    }
    
    private void saveCache() nothrow
    {
        try
        {
            // Serialize cache entries
            auto data = BinaryStorage.serialize(entries);
            
            // Sign the data with integrity validator
            auto signed = validator.signWithMetadata(data);
            
            // Serialize and write signed data
            auto serialized = signed.serialize();
            std.file.write(cacheFilePath, serialized);
        }
        catch (Exception e)
        {
            // Can't print during GC, just fail silently
            try { writeln("Warning: Could not save cache: ", e.msg); } 
            catch (Exception) 
            {
                // writeln may fail during GC - this is expected and safe to ignore
            }
        }
    }
    
    /// Load old JSON format for migration
    private void loadJsonCache(string cacheFile)
    {
        import std.json;
        
        auto json = parseJSON(readText(cacheFile));
        
        foreach (targetId, entryJson; json.object)
        {
            CacheEntry entry;
            entry.targetId = targetId;
            entry.buildHash = entryJson["buildHash"].str;
            entry.timestamp = entry.lastAccess = SysTime.fromISOExtString(entryJson["timestamp"].str);
            
            foreach (source, hash; entryJson["sourceHashes"].object)
            {
                entry.sourceHashes[source] = hash.str;
                if (exists(source))
                    entry.sourceMetadata[source] = FastHash.hashMetadata(source);
            }
            
            entryJson["depHashes"].object.byKeyValue.each!(kv => entry.depHashes[kv.key] = kv.value.str);
            
            entries[targetId] = entry;
        }
    }
    
}

/// Cache entry with LRU tracking and metadata
/// 
/// Memory Management:
/// - Strings reference data from deserialized file buffer (zero-copy)
/// - Associative arrays are rehashed after bulk insertion for optimal layout
/// - No postblit to avoid accidental copies (use pointers via 'in entries')
private struct CacheEntry
{
    string targetId;
    string buildHash;
    string[string] sourceHashes;      // Content hashes
    string[string] sourceMetadata;    // Metadata hashes (new)
    string[string] depHashes;
    SysTime timestamp;                // When entry was created
    SysTime lastAccess;               // When entry was last accessed (LRU)
    string metadataHash;              // Reserved for future use
}

/// Cache configuration
struct CacheConfig
{
    size_t maxSize = 1_073_741_824;   // 1 GB default
    size_t maxEntries = 10_000;       // 10k entries default
    size_t maxAge = 30;               // 30 days default
    
    /// Load from environment variables
    static CacheConfig fromEnvironment() @system
    {
        import std.process : environment;
        
        CacheConfig config;
        
        auto maxSizeEnv = environment.get("BUILDER_CACHE_MAX_SIZE");
        if (maxSizeEnv)
            config.maxSize = maxSizeEnv.to!size_t;
        
        auto maxEntriesEnv = environment.get("BUILDER_CACHE_MAX_ENTRIES");
        if (maxEntriesEnv)
            config.maxEntries = maxEntriesEnv.to!size_t;
        
        auto maxAgeEnv = environment.get("BUILDER_CACHE_MAX_AGE_DAYS");
        if (maxAgeEnv)
            config.maxAge = maxAgeEnv.to!size_t;
        
        return config;
    }
}

