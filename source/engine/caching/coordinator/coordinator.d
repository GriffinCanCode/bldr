module engine.caching.coordinator.coordinator;

import std.datetime : Clock, Duration, dur;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.conv : to;
import core.sync.mutex : Mutex;
import engine.caching.targets.cache : BuildCache, CacheConfig;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId;
import engine.caching.incremental.dependency : DependencyCache;
import engine.caching.incremental.filter : IncrementalFilter;
import engine.caching.distributed.remote.client : RemoteCacheClient;
import engine.caching.distributed.remote.protocol : RemoteCacheConfig;
import engine.caching.storage : ContentAddressableStorage, CacheGarbageCollector, SourceRepository, SourceTracker, SourceRef, SourceRefSet;
import engine.caching.events;
import frontend.cli.events.events : EventPublisher;
import infrastructure.errors;
import infrastructure.utils.logging.logger;
import infrastructure.utils.files.directories : ensureDirectoryWithGitignore;

/// Unified cache coordinator orchestrating all caching tiers
/// Single source of truth for cache operations with:
/// - Multi-tier caching (local target, action, remote)
/// - Incremental compilation and smart filtering
/// - Content-addressable storage with deduplication
/// - Automatic garbage collection
/// - Event emission for telemetry integration
/// - Batch validation
final class CacheCoordinator
{
    private BuildCache targetCache;
    private ActionCache actionCache;
    private DependencyCache depCache;
    private IncrementalFilter filter;
    private RemoteCacheClient remoteCache;
    private ContentAddressableStorage cas;
    private CacheGarbageCollector gc;
    private SourceRepository sourceRepo;
    private SourceTracker sourceTracker;
    private EventPublisher publisher;
    private Mutex coordinatorMutex;
    private CoordinatorConfig config;
    
    this(
        string cacheDir = ".builder-cache",
        EventPublisher publisher = null,
        CoordinatorConfig config = CoordinatorConfig.init
    ) @system
    {
        this.config = config;
        this.publisher = publisher;
        this.coordinatorMutex = new Mutex();
        
        // Ensure cache directory exists and is ignored by git
        ensureDirectoryWithGitignore(cacheDir);
        
        // Initialize content-addressable storage
        this.cas = new ContentAddressableStorage(cacheDir ~ "/blobs");
        
        // Initialize source repository (content-addressed sources)
        this.sourceRepo = new SourceRepository(cas, cacheDir ~ "/sources");
        
        // Initialize source tracker
        this.sourceTracker = new SourceTracker(sourceRepo);
        
        // Initialize target cache
        auto targetConfig = CacheConfig.fromEnvironment();
        this.targetCache = new BuildCache(cacheDir, targetConfig);
        
        // Initialize action cache
        auto actionConfig = ActionCacheConfig.fromEnvironment();
        this.actionCache = new ActionCache(cacheDir ~ "/actions", actionConfig);
        
        // Initialize dependency cache for incremental compilation
        this.depCache = new DependencyCache(cacheDir ~ "/incremental");
        
        // Initialize smart filter
        this.filter = IncrementalFilter.create(depCache, actionCache);
        
        // Initialize remote cache if configured
        auto remoteConfig = RemoteCacheConfig.fromEnvironment();
        if (remoteConfig.enabled()) this.remoteCache = new RemoteCacheClient(remoteConfig);
        
        // Initialize garbage collector
        this.gc = new CacheGarbageCollector(cas, publisher);
    }
    
    /// Check if target is cached (checks all tiers)
    bool isCached(string targetId, const(string)[] sources, const(string)[] deps) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        
        // Check local target cache first (fastest)
        if (targetCache.isCached(targetId, sources, deps))
        {
            emitEvent!CacheHitEvent(targetId, 0, timer.peek(), false);
            return true;
        }
        
        // Check remote cache if available
        if (remoteCache !is null)
        {
            immutable contentHash = computeContentHash(targetId, sources, deps);
            if (contentHash.length && remoteCache.has(contentHash).match((bool ok) => ok, (BuildError _) => false))
            {
                emitEvent!CacheHitEvent(targetId, 0, timer.peek(), true);
                return true;
            }
        }
        
        emitEvent!CacheMissEvent(targetId, timer.peek());
        return false;
    }
    
    /// Batch validate multiple targets in parallel - validates multiple targets concurrently using work-stealing scheduler - returns results indexed by target ID
    BatchValidationResult batchValidate(const(TargetValidationRequest)[] requests) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        
        if (requests.length == 0) return BatchValidationResult.init;
        
        // Single target optimization - avoid parallel overhead
        if (requests.length == 1)
        {
            auto req = requests[0];
            auto cached = isCached(req.targetId, req.sources, req.deps);
            return BatchValidationResult(
                [req.targetId: TargetValidationResult(req.targetId, cached, false)],
                1, cached ? 1 : 0, 0, timer.peek(), timer.peek()
            );
        }
        
        // Parallel validation with work-stealing for optimal load balancing
        import infrastructure.utils.concurrency.parallel : ParallelExecutor;
        import std.typecons : tuple;
        
        // Convert to mutable array for parallel processing
        TargetValidationRequest[] mutableRequests;
        mutableRequests.reserve(requests.length);
        foreach (req; requests)
            mutableRequests ~= TargetValidationRequest(req.targetId, req.sources.dup, req.deps.dup);
        
        auto results = ParallelExecutor.mapWorkStealing(
            mutableRequests,
            (TargetValidationRequest req) @system {
                // Check local cache first
                if (targetCache.isCached(req.targetId, req.sources, req.deps))
                    return tuple(req.targetId, true, false);
                
                // Check remote cache if available
                if (remoteCache !is null)
                {
                    auto contentHash = computeContentHash(req.targetId, req.sources, req.deps);
                    if (contentHash.length && remoteCache.has(contentHash).match((bool ok) => ok, (BuildError _) => false))
                        return tuple(req.targetId, true, true);
                }
                
                return tuple(req.targetId, false, false);
            }
        );
        
        // Aggregate results
        BatchValidationResult batchResult = { totalTargets: requests.length };
        
        foreach (r; results)
        {
            auto targetId = r[0];
            auto cached = r[1];
            auto fromRemote = r[2];
            
            batchResult.results[targetId] = TargetValidationResult(targetId, cached, fromRemote);
            
            if (cached)
            {
                batchResult.cachedTargets++;
                if (fromRemote) batchResult.remoteCachedTargets++;
                emitEvent!CacheHitEvent(targetId, 0, dur!"msecs"(0), fromRemote);
            }
            else
                emitEvent!CacheMissEvent(targetId, dur!"msecs"(0));
        }
        
        batchResult.duration = timer.peek();
        batchResult.averageTimePerTarget = batchResult.duration / requests.length;
        
        return batchResult;
    }
    
    /// Update cache after successful build
    void update(string targetId, const(string)[] sources, const(string)[] deps, string outputHash) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        
        synchronized (coordinatorMutex)
        {
            targetCache.update(targetId, sources, deps, outputHash);
            emitEvent!CacheUpdateEvent(targetId, 0, timer.peek());
            
            // Push to remote cache asynchronously if configured
            if (remoteCache !is null && config.enableRemotePush)
            {
                import core.thread : Thread;
                (new Thread(() => pushToRemote(targetId, sources, deps, outputHash))).start();
            }
        }
    }
    
    /// Check if action is cached
    bool isActionCached(ActionId actionId, const(string)[] inputs, const(string[string]) metadata) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        immutable cached = actionCache.isCached(actionId, inputs, metadata);
        emitEvent!ActionCacheEvent(
            cached ? CacheEventType.ActionHit : CacheEventType.ActionMiss,
            actionId.toString(), actionId.targetId, timer.peek()
        );
        return cached;
    }
    
    /// Batch validate multiple actions in parallel for improved throughput - similar speedup gains as batch target validation
    BatchActionValidationResult batchValidateActions(const(ActionValidationRequest)[] requests) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        
        if (requests.length == 0) return BatchActionValidationResult.init;
        
        // Single action optimization
        if (requests.length == 1)
        {
            auto req = requests[0];
            auto cached = actionCache.isCached(req.actionId, req.inputs, req.metadata);
            return BatchActionValidationResult(
                [req.actionId.toString(): ActionValidationResult(req.actionId, cached)],
                1, cached ? 1 : 0, timer.peek(), timer.peek()
            );
        }
        
        // Parallel validation
        import infrastructure.utils.concurrency.parallel : ParallelExecutor;
        import std.typecons : tuple;
        
        // Convert to mutable array for parallel processing
        ActionValidationRequest[] mutableRequests;
        mutableRequests.reserve(requests.length);
        foreach (req; requests)
        {
            string[string] mutableMetadata;
            foreach (k, v; req.metadata)
                mutableMetadata[k] = v;
            mutableRequests ~= ActionValidationRequest(req.actionId, req.inputs.dup, mutableMetadata);
        }
        
        auto results = ParallelExecutor.mapWorkStealing(
            mutableRequests,
            (ActionValidationRequest req) @system =>
                tuple(req.actionId, actionCache.isCached(req.actionId, req.inputs, req.metadata))
        );
        
        // Aggregate results
        BatchActionValidationResult batchResult = { totalActions: requests.length };
        
        foreach (r; results)
        {
            auto actionId = r[0];
            auto cached = r[1];
            
            batchResult.results[actionId.toString()] = ActionValidationResult(actionId, cached);
            if (cached) batchResult.cachedActions++;
            
            // Emit events
            emitEvent!ActionCacheEvent(
                cached ? CacheEventType.ActionHit : CacheEventType.ActionMiss,
                actionId.toString(), actionId.targetId, dur!"msecs"(0)
            );
        }
        
        batchResult.duration = timer.peek();
        batchResult.averageTimePerAction = batchResult.duration / requests.length;
        
        return batchResult;
    }
    
    /// Record action result
    void recordAction(ActionId actionId, const(string)[] inputs, const(string)[] outputs,
                     const(string[string]) metadata, bool success) @system
        => actionCache.update(actionId, inputs, outputs, metadata, success);
    
    /// Flush all caches to disk
    void flush() @system
    {
        synchronized (coordinatorMutex)
        {
            targetCache.flush();
            actionCache.flush();
            sourceRepo.flush();
        }
    }
    
    /// Close all caches
    void close() @system
    {
        synchronized (coordinatorMutex)
        {
            if (targetCache) targetCache.close();
            if (actionCache) actionCache.close();
        }
    }
    
    /// Run garbage collection
    Result!(size_t, BuildError) runGC() @system
        => gc.collect(targetCache, actionCache).match(
            (result) => Ok!(size_t, BuildError)(result.bytesFreed),
            (err) => Err!(size_t, BuildError)(err)
        );
    
    /// Get unified cache statistics
    struct CacheCoordinatorStats
    {
        size_t targetCacheEntries;
        size_t targetCacheSize;
        float targetHitRate;
        
        size_t actionCacheEntries;
        size_t actionCacheSize;
        float actionHitRate;
        
        size_t uniqueBlobs;
        size_t totalBlobSize;
        float deduplicationRatio;
        
        size_t remoteHits;
        size_t remoteMisses;
        float remoteHitRate;
        
        // Source repository stats
        size_t sourcesStored;
        size_t sourceDeduplicationHits;
        ulong sourceBytes;
        ulong sourceBytesSaved;
        float sourceDeduplicationRatio;
    }
    
    CacheCoordinatorStats getStats() @system
    {
        synchronized (coordinatorMutex)
        {
            auto targetStats = targetCache.getStats();
            auto actionStats = actionCache.getStats();
            auto casStats = cas.getStats();
            auto sourceStats = sourceRepo.getStats();
            
            CacheCoordinatorStats stats = {
                // Target cache stats
                targetCacheEntries: targetStats.totalEntries,
                targetCacheSize: targetStats.totalSize,
                targetHitRate: targetStats.metadataHitRate,
                
                // Action cache stats
                actionCacheEntries: actionStats.totalEntries,
                actionCacheSize: actionStats.totalSize,
                actionHitRate: actionStats.hitRate,
                
                // CAS stats
                uniqueBlobs: casStats.uniqueBlobs,
                totalBlobSize: casStats.totalSize,
                deduplicationRatio: casStats.deduplicationRatio,
                
                // Source repository stats
                sourcesStored: sourceStats.sourcesStored,
                sourceDeduplicationHits: sourceStats.deduplicationHits,
                sourceBytes: sourceStats.bytesStored,
                sourceBytesSaved: sourceStats.bytesSaved,
                sourceDeduplicationRatio: sourceStats.deduplicationRatio
            };
            
            // Remote cache stats
            if (remoteCache)
            {
                auto remoteStats = remoteCache.getStats();
                stats.remoteHits = remoteStats.hits;
                stats.remoteMisses = remoteStats.misses;
                stats.remoteHitRate = remoteStats.hitRate;
            }
            
            return stats;
        }
    }
    
    /// Push artifact to remote cache (runs asynchronously)
    private void pushToRemote(string targetId, const(string)[] sources, const(string)[] deps, string outputHash) @system nothrow
    {
        auto timer = StopWatch(AutoStart.yes);
        
        try
        {
            immutable contentHash = computeContentHash(targetId, sources, deps);
            if (!contentHash.length) return;
            
            auto metadata = serializeCacheMetadata(targetId, sources, deps, outputHash);
            auto pushResult = remoteCache.put(contentHash, metadata);
            
            emitEvent!RemoteCacheEvent(CacheEventType.RemotePush, targetId, metadata.length, timer.peek(), pushResult.isOk);
            
            if (pushResult.isErr) Logger.debugLog("Remote push failed: " ~ pushResult.unwrapErr().message);
        }
        catch (Exception e)
        {
            try { Logger.debugLog("Remote push exception: " ~ e.msg); } catch (Exception) {}
        }
    }
    
    /// Compute content hash for remote cache key
    private string computeContentHash(string targetId, const(string)[] sources, const(string)[] deps) @system nothrow
    {
        try
        {
            import std.digest.sha : SHA256, toHexString;
            import infrastructure.utils.files.hash : FastHash;
            import std.file : exists;
            import std.algorithm : filter, each;
            
            SHA256 hash;
            hash.start();
            hash.put(cast(ubyte[])targetId);
            
            sources.filter!exists.each!(s => hash.put(cast(ubyte[])FastHash.hashFile(s)));
            deps.each!(d => hash.put(cast(ubyte[])d));
            
            return toHexString(hash.finish()).to!string;
        }
        catch (Exception) { return ""; }
    }
    
    /// Serialize cache metadata for remote storage
    private ubyte[] serializeCacheMetadata(string targetId, const(string)[] sources, const(string)[] deps, string outputHash) @system nothrow
    {
        void writeString(ref ubyte[] buf, string s)
        {
            import std.bitmanip : write;
            auto bytes = cast(const(ubyte)[])s;
            buf.write!uint(cast(uint)bytes.length, buf.length);
            buf ~= bytes;
        }
        
        try
        {
            import std.bitmanip : write;
            import std.algorithm : each;
            
            ubyte[] buffer;
            buffer.reserve(1024);
            buffer.write!ubyte(1, buffer.length); // Version
            
            writeString(buffer, targetId);
            
            buffer.write!uint(cast(uint)sources.length, buffer.length);
            sources.each!(s => writeString(buffer, s));
            
            buffer.write!uint(cast(uint)deps.length, buffer.length);
            deps.each!(d => writeString(buffer, d));
            
            writeString(buffer, outputHash);
            
            return buffer;
        }
        catch (Exception) { return []; }
    }
    
    // Event emission helper
    private void emitEvent(T, Args...)(Args args) nothrow
    {
        if (publisher) try { publisher.publish(new T(args)); } catch (Exception) {}
    }
    
    /// Get action cache
    ActionCache getActionCache() @system => actionCache;
    
    /// Get dependency cache
    DependencyCache getDependencyCache() @system => depCache;
    
    /// Get incremental filter
    IncrementalFilter getFilter() @system => filter;
    
    /// Get source repository
    SourceRepository getSourceRepository() @system => sourceRepo;
    
    /// Get source tracker
    SourceTracker getSourceTracker() @system => sourceTracker;
    
    /// Store sources in CAS and return references
    Result!(SourceRefSet, BuildError) storeSources(const(string)[] paths) @system
    {
        auto timer = StopWatch(AutoStart.yes);
        synchronized (coordinatorMutex)
        {
            auto result = sourceTracker.trackBatch(paths);
            
            // Emit telemetry event
            if (result.isOk && publisher !is null)
            {
                try
                {
                    import std.format : format;
                    auto refSet = result.unwrap();
                    immutable msg = format("Stored %d sources (%d bytes) in CAS", refSet.length, refSet.totalSize);
                    // Could emit custom SourceStorageEvent here if needed
                }
                catch (Exception) {}
            }
            
            return result;
        }
    }
    
    /// Materialize sources from CAS to workspace
    Result!BuildError materializeSources(SourceRefSet refSet) @system
    {
        synchronized (coordinatorMutex) return sourceRepo.materializeBatch(refSet);
    }
    
    /// Detect changed sources and update CAS
    Result!(SourceTracker.ChangedFile[], BuildError) detectSourceChanges(const(string)[] paths) @system
    {
        synchronized (coordinatorMutex)
        {
            auto result = sourceTracker.detectChanges(paths);
            
            // Emit telemetry event
            if (result.isOk && publisher !is null)
            {
                auto changes = result.unwrap();
                if (changes.length > 0)
                {
                    try
                    {
                        import std.format : format;
                        immutable msg = format("%d source file(s) changed", changes.length);
                        // Could emit SourceChangeEvent here
                    }
                    catch (Exception) {}
                }
            }
            
            return result;
        }
    }
}

/// Target validation request for batch operations
struct TargetValidationRequest
{
    string targetId;
    string[] sources;
    string[] deps;
}

/// Result of validating a single target
struct TargetValidationResult
{
    string targetId;
    bool cached;           // Whether target is cached
    bool fromRemote;       // Whether cache hit came from remote
}

/// Batch validation results with statistics
struct BatchValidationResult
{
    TargetValidationResult[string] results;  // Results indexed by targetId
    size_t totalTargets;
    size_t cachedTargets;
    size_t remoteCachedTargets;
    Duration duration;
    Duration averageTimePerTarget;
    
    /// Calculate cache hit rate
    float hitRate() const pure nothrow @safe
        => totalTargets ? (cast(float)cachedTargets / totalTargets) * 100.0 : 0.0;
    
    /// Calculate remote cache hit rate
    float remoteHitRate() const pure nothrow @safe
        => cachedTargets ? (cast(float)remoteCachedTargets / cachedTargets) * 100.0 : 0.0;
}

/// Action validation request for batch operations
struct ActionValidationRequest
{
    ActionId actionId;
    string[] inputs;
    string[string] metadata;
}

/// Result of validating a single action
struct ActionValidationResult
{
    ActionId actionId;
    bool cached;
}

/// Batch action validation results with statistics
struct BatchActionValidationResult
{
    ActionValidationResult[string] results;  // Results indexed by actionId string
    size_t totalActions;
    size_t cachedActions;
    Duration duration;
    Duration averageTimePerAction;
    
    /// Calculate cache hit rate
    float hitRate() const pure nothrow @safe
        => totalActions ? (cast(float)cachedActions / totalActions) * 100.0 : 0.0;
}

/// Coordinator configuration
struct CoordinatorConfig
{
    bool enableRemotePush = true;
    bool enableAutoGC = false;
    Duration gcInterval = dur!"hours"(24);
}

