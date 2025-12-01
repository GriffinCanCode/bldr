module engine.caching.actions.action;

import std.stdio;
import std.file;
import std.path;
import std.conv;
import std.algorithm;
import std.array;
import std.datetime;
import std.typecons : tuple, Tuple;
import core.sync.mutex;
import infrastructure.utils.files.hash;
import infrastructure.utils.simd.hash;
import engine.caching.policies.eviction;
import infrastructure.utils.security.integrity;
import infrastructure.utils.concurrency.lockfree;
import engine.caching.actions.storage;
import infrastructure.errors;

/// Action types for fine-grained caching
enum ActionType : ubyte
{
    Compile,      // Compilation step (per file or batch)
    Link,         // Linking step
    Codegen,      // Code generation (protobuf, etc)
    Test,         // Test execution
    Package,      // Packaging/bundling
    Transform,    // Asset transformation
    Lint,         // Linting/static analysis
    TypeCheck,    // Type checking
    Custom        // Custom user-defined action
}

/// Strongly-typed action identifier
/// Composite key: targetId + actionType + inputHash
/// Provides fine-grained uniqueness for caching individual build steps
struct ActionId
{
    string targetId;      // Parent target
    ActionType type;      // Type of action
    string inputHash;     // Hash of action inputs (sources, deps, flags)
    string subId;         // Optional sub-identifier (e.g., source file name)
    
    /// Generate stable string representation for storage
    string toString() const pure @system
    {
        import std.format : format;
        if (subId.length > 0)
            return format("%s:%s:%s:%s", targetId, type, subId, inputHash);
        return format("%s:%s:%s", targetId, type, inputHash);
    }
    
    /// Parse action ID from string
    /// Returns: Result with ActionId or BuildError
    static Result!(ActionId, BuildError) parse(string str) @system
    {
        auto parts = str.split(":");
        if (parts.length < 3)
        {
            auto error = new ParseError(
                str,
                "Invalid ActionId format (expected format: targetId:type:inputHash or targetId:type:subId:inputHash)"
            );
            error.addSuggestion("Check ActionId format - should have at least 3 colon-separated parts");
            error.addContext(ErrorContext("parsing action ID", str));
            return Err!(ActionId, BuildError)(error);
        }
        
        ActionId id;
        id.targetId = parts[0];
        
        try
        {
            id.type = parts[1].to!ActionType;
        }
        catch (Exception e)
        {
            auto error = new ParseError(
                str,
                "Invalid ActionType in ActionId: " ~ parts[1] ~ " (valid types: Build, Test, Run, etc.)"
            );
            error.addSuggestion("Check that action type is a valid ActionType enum value");
            error.addContext(ErrorContext("parsing action type", parts[1]));
            return Err!(ActionId, BuildError)(error);
        }
        
        if (parts.length == 4)
        {
            id.subId = parts[2];
            id.inputHash = parts[3];
        }
        else
        {
            id.inputHash = parts[2];
        }
        
        return Ok!(ActionId, BuildError)(id);
    }
}

/// Action cache entry with incremental build metadata
struct ActionEntry
{
    ActionId actionId;                  // Composite identifier
    string[] inputs;                    // Input files
    string[string] inputHashes;         // Input file hashes
    string[] outputs;                   // Output files
    string[string] outputHashes;        // Output file hashes
    string[string] metadata;            // Additional metadata (flags, env, etc)
    SysTime timestamp;                  // When action was performed
    SysTime lastAccess;                 // Last access time (LRU)
    string executionHash;               // Hash of execution context
    bool success;                       // Whether action succeeded
    
    // Determinism tracking
    bool isDeterministic = false;       // Verified deterministic?
    string verificationHash;            // Hash for determinism verification
    uint determinismVerifications = 0;  // Number of successful verifications
}

/// High-performance action-level cache with incremental builds
/// 
/// Design Philosophy:
/// - Finer granularity than target-level caching
/// - Cache individual compile steps, link steps, etc.
/// - Enable partial rebuilds when only some actions fail
/// - Reuse successful action results across builds
/// 
/// Thread Safety:
/// - All public methods are synchronized via internal mutex
/// - Safe for concurrent access from multiple build threads
/// 
/// Security:
/// - BLAKE3-based HMAC signatures prevent tampering
/// - Workspace-specific keys for isolation
/// - Automatic expiration (30 days default)
/// 
/// Optimizations:
/// - Lock-free hash cache for per-session memoization
/// - Two-tier hashing for fast validation
/// - Binary serialization (5-10x faster than JSON)
/// - SIMD-accelerated hash comparisons
final class ActionCache
{
    private string cacheDir;
    private immutable string cacheFilePath;
    private ActionEntry[string] entries;  // Key: ActionId.toString()
    private bool dirty;
    private EvictionPolicy eviction;
    private ActionCacheConfig config;
    private Mutex cacheMutex;
    private IntegrityValidator validator;
    private FastHashCache hashCache;
    private bool closed = false;
    
    // Statistics
    private size_t actionHits;
    private size_t actionMisses;
    
    /// Constructor: Initialize action cache
    this(string cacheDir = ".builder-cache/actions", ActionCacheConfig config = ActionCacheConfig.init) @system
    {
        this.cacheDir = cacheDir;
        this.cacheFilePath = buildPath(cacheDir, "actions.bin");
        this.config = config;
        this.dirty = false;
        this.eviction = EvictionPolicy(config.maxSize, config.maxEntries, config.maxAge);
        this.cacheMutex = new Mutex();
        
        // Initialize hash cache
        this.hashCache.initialize();
        
        // Initialize integrity validator
        import std.file : getcwd;
        this.validator = IntegrityValidator.fromEnvironment(getcwd());
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        loadCache();
    }
    
    /// Explicitly close cache and flush to disk
    void close() @system
    {
        synchronized (cacheMutex)
        {
            if (!closed)
            {
                if (dirty) 
                    flush(false);
                closed = true;
            }
        }
    }
    
    ~this()
    {
        // Let GC handle cleanup - explicit flush in destructor can cause issues
    }
    
    /// Check if an action is cached and up-to-date
    /// Validates: entry exists, inputs unchanged, outputs exist, metadata unchanged
    bool isCached(ActionId actionId, scope const(string)[] inputs, scope const(string[string]) metadata) @system
    {
        synchronized (cacheMutex)
        {
            auto entryPtr = actionId.toString() in entries;
            if (entryPtr is null || !entryPtr.success)
                return recordMiss();
            
            entryPtr.lastAccess = Clock.currTime();
            dirty = true;
            
            // Validate input files haven't changed
            foreach (input; inputs)
            {
                if (!exists(input))
                    return recordMiss();
                
                auto cached = hashCache.get(input);
                string currentHash = cached.found ? cached.contentHash : FastHash.hashFile(input);
                
                if (!cached.found)
                    hashCache.put(input, currentHash, FastHash.hashMetadata(input));
                
                if (!SIMDHash.equals(currentHash, entryPtr.inputHashes.get(input, "")))
                    return recordMiss();
            }
            
            // Validate all output files exist and metadata unchanged
            if (entryPtr.outputs.any!(o => !exists(o)))
                return recordMiss();
            
            if (metadata.byKeyValue.any!(kv => entryPtr.metadata.get(kv.key, "") != kv.value))
                return recordMiss();
            
            actionHits++;
            return true;
        }
    }
    
    private bool recordMiss() @safe nothrow
    {
        actionMisses++;
        return false;
    }
    
    /// Update action cache entry
    /// Records inputs, outputs, metadata, and success status
    void update(
        ActionId actionId,
        scope const(string)[] inputs,
        scope const(string)[] outputs,
        scope const(string[string]) metadata,
        bool success
    ) @system
    {
        synchronized (cacheMutex)
        {
            immutable now = Clock.currTime();
            ActionEntry entry;
            entry.actionId = actionId;
            entry.timestamp = now;
            entry.lastAccess = now;
            entry.success = success;
            entry.inputs = inputs.dup;
            entry.outputs = outputs.dup;
            
            // Hash all input files
            foreach (input; inputs)
            {
                if (!exists(input))
                    continue;
                
                auto cached = hashCache.get(input);
                if (cached.found)
                    entry.inputHashes[input] = cached.contentHash;
                else
                {
                    hashCache.put(input, FastHash.hashFile(input), FastHash.hashMetadata(input));
                    entry.inputHashes[input] = hashCache.get(input).contentHash;
                }
            }
            
            // Hash all output files
            foreach (output; outputs.filter!exists)
                entry.outputHashes[output] = FastHash.hashFile(output);
            
            entry.metadata = cast(string[string])metadata.dup;
            entry.executionHash = computeExecutionHash(metadata);
            entries[actionId.toString()] = entry;
            dirty = true;
        }
    }
    
    /// Invalidate action cache entry
    void invalidate(ActionId actionId) @system nothrow
    {
        try synchronized (cacheMutex)
        {
            entries.remove(actionId.toString());
            dirty = true;
        }
        catch (Exception) {}
    }
    
    /// Clear entire action cache
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
    
    /// Flush cache to disk
    void flush(bool runEviction = true) @system
    {
        synchronized (cacheMutex)
        {
            if (!dirty) return;
            
            // Run eviction policy
            if (runEviction)
            {
                try
                {
                    auto toEvict = eviction.selectEvictions(entries, eviction.calculateTotalSize(entries));
                    toEvict.each!(key => entries.remove(key));
                }
                catch (Exception) {}
            }
            
            saveCache();
            dirty = false;
            hashCache.clear();
        }
    }
    
    /// Get action cache statistics
    struct ActionCacheStats
    {
        size_t totalEntries;
        size_t totalSize;
        size_t hits;
        size_t misses;
        float hitRate;
        size_t successfulActions;
        size_t failedActions;
    }
    
    ActionCacheStats getStats() const @system
    {
        synchronized (cast(Mutex)cacheMutex)
        {
            ActionCacheStats stats;
            stats.totalEntries = entries.length;
            stats.hits = actionHits;
            stats.misses = actionMisses;
            
            immutable total = actionHits + actionMisses;
            if (total > 0)
                stats.hitRate = (actionHits * 100.0) / total;
            
            foreach (entry; entries.byValue)
            {
                if (entry.success)
                    stats.successfulActions++;
                else
                    stats.failedActions++;
            }
            
            stats.totalSize = eviction.calculateTotalSize(entries);
            
            return stats;
        }
    }
    
    /// Get all cached actions for a target
    ActionEntry[] getActionsForTarget(string targetId) const @system
    {
        synchronized (cast(Mutex)cacheMutex)
        {
            return entries.byValue
                .filter!(e => e.actionId.targetId == targetId)
                .map!(e => duplicateEntry(e))
                .array;
        }
    }
    
    private static ActionEntry duplicateEntry(const ref ActionEntry entry) @system
    {
        ActionEntry copy;
        copy.actionId = entry.actionId;
        copy.inputs = entry.inputs.dup;
        copy.outputs = entry.outputs.dup;
        copy.inputHashes = cast(string[string])entry.inputHashes.dup;
        copy.outputHashes = cast(string[string])entry.outputHashes.dup;
        copy.metadata = cast(string[string])entry.metadata.dup;
        copy.timestamp = entry.timestamp;
        copy.lastAccess = entry.lastAccess;
        copy.executionHash = entry.executionHash;
        copy.success = entry.success;
        return copy;
    }
    
    private void loadCache() @system
    {
        if (!exists(cacheFilePath))
            return;
        
        try
        {
            auto fileData = cast(ubyte[])std.file.read(cacheFilePath);
            auto signed = SignedData.deserialize(fileData);
            
            if (!validator.verifyWithMetadata(signed))
            {
                writeln("Warning: Action cache signature verification failed, starting fresh");
                entries.clear();
                return;
            }
            
            import core.time : days;
            if (IntegrityValidator.isExpired(signed, 30.days))
            {
                writeln("Action cache expired, starting fresh");
                entries.clear();
                return;
            }
            
            entries = ActionStorage.deserialize!ActionEntry(signed.data);
        }
        catch (Exception e)
        {
            writeln("Warning: Action cache corrupted, starting fresh: ", e.msg);
            entries.clear();
        }
    }
    
    private void saveCache() nothrow
    {
        try
        {
            auto data = ActionStorage.serialize(entries);
            auto signed = validator.signWithMetadata(data);
            std.file.write(cacheFilePath, signed.serialize());
        }
        catch (Exception) {}
    }
    
    /// Compute hash of execution context (flags, env, etc)
    private static string computeExecutionHash(scope const(string[string]) metadata) @system
    {
        import std.digest.sha : SHA256, toHexString;
        
        SHA256 hash;
        hash.start();
        // Sort keys for deterministic hashing
        foreach (key; metadata.keys.array.sort())
        {
            hash.put(cast(ubyte[])key);
            hash.put(cast(ubyte[])metadata[key]);
        }
        
        return toHexString(hash.finish()).to!string;
    }
}

/// Action cache configuration
struct ActionCacheConfig
{
    size_t maxSize = 1_073_741_824;   // 1 GB default
    size_t maxEntries = 50_000;       // 50k actions default (more than targets)
    size_t maxAge = 30;               // 30 days default
    
    static ActionCacheConfig fromEnvironment() @system
    {
        import std.process : environment;
        
        ActionCacheConfig config;
        
        auto maxSizeEnv = environment.get("BUILDER_ACTION_CACHE_MAX_SIZE");
        if (maxSizeEnv)
            config.maxSize = maxSizeEnv.to!size_t;
        
        auto maxEntriesEnv = environment.get("BUILDER_ACTION_CACHE_MAX_ENTRIES");
        if (maxEntriesEnv)
            config.maxEntries = maxEntriesEnv.to!size_t;
        
        auto maxAgeEnv = environment.get("BUILDER_ACTION_CACHE_MAX_AGE_DAYS");
        if (maxAgeEnv)
            config.maxAge = maxAgeEnv.to!size_t;
        
        return config;
    }
}
