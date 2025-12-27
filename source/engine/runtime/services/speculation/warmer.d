module engine.runtime.services.speculation.warmer;

import std.algorithm : map, filter, sort, min, max;
import std.array : array;
import std.datetime : Duration, msecs, Clock, SysTime;
import std.conv : to;
import std.parallelism : task, taskPool;
import core.atomic;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.utils.logging;
import engine.runtime.services.speculation.predictor : ChangePredictor, ChangeProbability, PredictorState, PredictorConfig;
import engine.runtime.services.speculation.history : HistoryTracker, HistoryConfig;

/// Warmup status for monitoring startup latency
enum WarmupStatus : ubyte
{
    Cold,       // Not started
    Loading,    // Loading persisted state
    Computing,  // Pre-computing predictions  
    Ready,      // Fully warmed
    Failed      // Warmup failed
}

/// Pre-computed predictions cache for O(1) lookup
struct PredictionCache
{
    ChangeProbability[string] byTarget;
    ChangeProbability[] ranked;       // Sorted by score descending
    SysTime computedAt;
    
    /// Top N predictions by score
    const(ChangeProbability)[] top(size_t n) const pure @safe nothrow
        => ranked[0 .. min(n, ranked.length)];
    
    /// Get prediction for target, null if not cached
    const(ChangeProbability)* get(string targetKey) const pure @safe nothrow @nogc
        => targetKey in byTarget;
}

/// Warmup metrics for telemetry
struct WarmupMetrics
{
    Duration loadDuration;      // Time to load from disk
    Duration computeDuration;   // Time to pre-compute predictions
    Duration totalDuration;     // Total warmup time
    size_t targetsLoaded;       // Number of targets from persisted state
    size_t predictionsComputed; // Predictions pre-computed
    size_t coChangeEdges;       // Co-change relationships loaded
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Warmup: load=%dms compute=%dms total=%dms targets=%d predictions=%d edges=%d",
            loadDuration.total!"msecs", computeDuration.total!"msecs",
            totalDuration.total!"msecs", targetsLoaded, 
            predictionsComputed, coChangeEdges
        );
    }
}

/// Configuration for predictor warmup
struct WarmerConfig
{
    string cacheDir = ".builder-cache/speculation";
    size_t maxPredictions = 10_000;  // Limit pre-computed predictions
    bool asyncWarmup = true;          // Enable background warmup
    Duration warmupTimeout = 5000.msecs; // Max warmup wait time
    PredictorConfig predictorConfig = PredictorConfig.init;
    HistoryConfig historyConfig = HistoryConfig.init;
}

/// Predictor pre-warmer - loads persisted state and pre-computes predictions
/// Enables sub-millisecond prediction lookups after warmup completes
final class PredictorWarmer
{
    private Mutex _mutex;
    private Condition _readyCondition;
    private shared WarmupStatus _status;
    private WarmerConfig _config;
    
    // Warmed components
    private ChangePredictor _predictor;
    private HistoryTracker _history;
    private PredictionCache _cache;
    private WarmupMetrics _metrics;
    
    // Async warmup state
    private SysTime _warmupStart;
    private Exception _warmupError;
    
    this(WarmerConfig config = WarmerConfig.init) @trusted
    {
        _config = config;
        _mutex = new Mutex();
        _readyCondition = new Condition(_mutex);
        atomicStore(_status, WarmupStatus.Cold);
    }
    
    /// Start warmup (async if configured)
    void start() @trusted
    {
        if (atomicLoad(_status) != WarmupStatus.Cold)
            return;
        
        _warmupStart = Clock.currTime();
        atomicStore(_status, WarmupStatus.Loading);
        
        if (_config.asyncWarmup)
        {
            // Background warmup - doesn't block startup
            auto warmupTask = task(&warmupAsync);
            warmupTask.executeInNewThread();
        }
        else
        {
            // Synchronous warmup
            warmupSync();
        }
    }
    
    /// Wait for warmup to complete (with timeout)
    bool awaitReady(Duration timeout = Duration.zero) @trusted
    {
        auto effectiveTimeout = timeout == Duration.zero ? _config.warmupTimeout : timeout;
        
        synchronized (_mutex)
        {
            auto status = atomicLoad(_status);
            if (status == WarmupStatus.Ready || status == WarmupStatus.Failed)
                return status == WarmupStatus.Ready;
            
            // Wait with timeout
            _readyCondition.wait(effectiveTimeout);
            return atomicLoad(_status) == WarmupStatus.Ready;
        }
    }
    
    /// Check if warmup is complete (non-blocking)
    @property bool isReady() const @safe nothrow 
        => atomicLoad(_status) == WarmupStatus.Ready;
    
    /// Get current warmup status
    @property WarmupStatus status() const @safe nothrow 
        => atomicLoad(_status);
    
    /// Get warmup metrics (valid after Ready)
    WarmupMetrics metrics() @trusted
    {
        synchronized (_mutex) { return _metrics; }
    }
    
    /// Get warmed predictor (null if not ready)
    ChangePredictor predictor() @trusted
    {
        if (!isReady) return null;
        synchronized (_mutex) { return _predictor; }
    }
    
    /// Get warmed history tracker (null if not ready)
    HistoryTracker history() @trusted
    {
        if (!isReady) return null;
        synchronized (_mutex) { return _history; }
    }
    
    /// Get pre-computed prediction for target (O(1) after warmup)
    const(ChangeProbability)* getCachedPrediction(TargetId targetId) @trusted
    {
        if (!isReady) return null;
        synchronized (_mutex) { return _cache.get(targetId.toString()); }
    }
    
    /// Get top N predictions by probability (pre-sorted)
    ChangeProbability[] topPredictions(size_t n = 100) @trusted
    {
        if (!isReady) return [];
        synchronized (_mutex) {
            auto top = _cache.top(n);
            auto result = new ChangeProbability[top.length];
            foreach (i, ref r; result) r = cast(ChangeProbability)top[i];
            return result;
        }
    }
    
    /// Get all cached predictions
    PredictionCache predictionCache() @trusted
    {
        synchronized (_mutex) { return _cache; }
    }
    
    /// Refresh predictions (after new changes recorded)
    void refresh() @trusted
    {
        if (!isReady) return;
        
        synchronized (_mutex)
        {
            auto start = Clock.currTime();
            computePredictions();
            _metrics.computeDuration = Clock.currTime() - start;
        }
    }
    
private:
    /// Synchronous warmup implementation
    void warmupSync() @trusted
    {
        try
        {
            loadState();
            computePredictions();
            finalizeWarmup();
        }
        catch (Exception e)
        {
            handleWarmupError(e);
        }
    }
    
    /// Async warmup implementation (runs in background thread)
    void warmupAsync() @trusted nothrow
    {
        try
        {
            loadState();
            computePredictions();
            finalizeWarmup();
        }
        catch (Exception e)
        {
            try { handleWarmupError(e); }
            catch (Exception) { /* Ignore logging errors */ }
        }
    }
    
    /// Load persisted state from disk
    void loadState() @trusted
    {
        auto loadStart = Clock.currTime();
        
        // Load history (also loads predictor state)
        _history = new HistoryTracker(_config.cacheDir, _config.historyConfig);
        
        // Create predictor and import state
        _predictor = new ChangePredictor(_config.predictorConfig);
        auto state = _history.getPredictorState();
        _predictor.importState(state);
        
        synchronized (_mutex)
        {
            _metrics.loadDuration = Clock.currTime() - loadStart;
            _metrics.targetsLoaded = state.targetStats.length;
            
            // Parse co-change matrix to count edges
            import std.json : parseJSON, JSONType;
            if (state.coChangeMatrix.length > 0)
            {
                try
                {
                    auto matrix = parseJSON(state.coChangeMatrix);
                    if (matrix.type == JSONType.object)
                    {
                        foreach (_, row; matrix.objectNoRef)
                            if (row.type == JSONType.object)
                                _metrics.coChangeEdges += row.objectNoRef.length;
                    }
                }
                catch (Exception) { /* Ignore parse errors */ }
            }
        }
        
        atomicStore(_status, WarmupStatus.Computing);
        structuredLog.debug_("predictor_warmup_loaded_state").field("targets", _metrics.targetsLoaded).emit();
    }
    
    /// Pre-compute predictions for all known targets
    void computePredictions() @trusted
    {
        auto computeStart = Clock.currTime();
        
        // Get all predictions from predictor
        auto predictions = _predictor.predict();
        
        // Limit to configured max
        if (predictions.length > _config.maxPredictions)
            predictions = predictions[0 .. _config.maxPredictions];
        
        // Build cache
        synchronized (_mutex)
        {
            _cache.byTarget.clear();
            foreach (ref pred; predictions)
                _cache.byTarget[pred.targetId.toString()] = pred;
            
            _cache.ranked = predictions.dup;
            _cache.computedAt = Clock.currTime();
            _metrics.computeDuration = Clock.currTime() - computeStart;
            _metrics.predictionsComputed = predictions.length;
        }
        
        structuredLog.debug_("predictor_warmup_computed_predictions").field("count", predictions.length).emit();
    }
    
    /// Finalize warmup and signal ready
    void finalizeWarmup() @trusted
    {
        synchronized (_mutex)
        {
            _metrics.totalDuration = Clock.currTime() - _warmupStart;
            atomicStore(_status, WarmupStatus.Ready);
            _readyCondition.notifyAll();
        }
        
        structuredLog.info("predictor_warmup_complete")
            .field("total_ms", _metrics.totalDuration.total!"msecs")
            .field("targets", _metrics.targetsLoaded)
            .field("predictions", _metrics.predictionsComputed)
            .emit();
    }
    
    /// Handle warmup error
    void handleWarmupError(Exception e) @trusted
    {
        synchronized (_mutex)
        {
            _warmupError = e;
            _metrics.totalDuration = Clock.currTime() - _warmupStart;
            atomicStore(_status, WarmupStatus.Failed);
            _readyCondition.notifyAll();
        }
        
        structuredLog.warning("predictor_warmup_failed").field("error", e.msg).emit();
    }
}

/// Create pre-warmed predictor (convenience factory)
/// Starts warmup immediately and returns warmer handle
PredictorWarmer createWarmedPredictor(string cacheDir = ".builder-cache/speculation") @trusted
{
    WarmerConfig config;
    config.cacheDir = cacheDir;
    
    auto warmer = new PredictorWarmer(config);
    warmer.start();
    return warmer;
}

/// Unit tests
unittest
{
    import std.stdio;
    import std.file : tempDir, exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;
    
    writeln("\x1b[36m[TEST]\x1b[0m speculation.warmer - Cold start warmup");
    
    auto testDir = buildPath(tempDir(), "bldr-test-warmer");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    
    WarmerConfig config;
    config.cacheDir = testDir;
    config.asyncWarmup = false; // Sync for testing
    
    auto warmer = new PredictorWarmer(config);
    assert(warmer.status == WarmupStatus.Cold);
    
    warmer.start();
    assert(warmer.isReady);
    assert(warmer.predictor !is null);
    assert(warmer.history !is null);
    
    auto metrics = warmer.metrics();
    assert(metrics.totalDuration > Duration.zero);
    
    writeln("\x1b[32m  ✓ Cold start warmup\x1b[0m");
}

unittest
{
    import std.stdio;
    import std.file : tempDir, exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;
    
    writeln("\x1b[36m[TEST]\x1b[0m speculation.warmer - Warm start with history");
    
    auto testDir = buildPath(tempDir(), "bldr-test-warmer-warm");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    // First: populate history
    {
        auto tracker = new HistoryTracker(testDir);
        foreach (i; 0 .. 5)
            tracker.recordChange(TargetId("target" ~ i.to!string), ChangeType.SourceModified);
        tracker.flush();
    }
    
    // Second: warm start
    WarmerConfig config;
    config.cacheDir = testDir;
    config.asyncWarmup = false;
    
    auto warmer = new PredictorWarmer(config);
    warmer.start();
    
    assert(warmer.isReady);
    auto metrics = warmer.metrics();
    assert(metrics.targetsLoaded >= 5);
    
    writeln("\x1b[32m  ✓ Warm start with history\x1b[0m");
}

unittest
{
    import std.stdio;
    import std.file : tempDir, exists, rmdirRecurse, mkdirRecurse;
    import std.path : buildPath;
    import core.thread : Thread;
    import core.time : msecs;
    
    writeln("\x1b[36m[TEST]\x1b[0m speculation.warmer - Async warmup");
    
    auto testDir = buildPath(tempDir(), "bldr-test-warmer-async");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    
    WarmerConfig config;
    config.cacheDir = testDir;
    config.asyncWarmup = true;
    config.warmupTimeout = 1000.msecs;
    
    auto warmer = new PredictorWarmer(config);
    warmer.start();
    
    // Should complete quickly for empty cache
    auto ready = warmer.awaitReady(500.msecs);
    assert(ready);
    assert(warmer.status == WarmupStatus.Ready);
    
    writeln("\x1b[32m  ✓ Async warmup\x1b[0m");
}

unittest
{
    import std.stdio;
    import std.file : tempDir, exists, rmdirRecurse;
    import std.path : buildPath;
    
    writeln("\x1b[36m[TEST]\x1b[0m speculation.warmer - Prediction cache lookup");
    
    auto testDir = buildPath(tempDir(), "bldr-test-warmer-cache");
    scope(exit) if (exists(testDir)) rmdirRecurse(testDir);
    
    // Populate with known targets
    {
        auto tracker = new HistoryTracker(testDir);
        foreach (i; 0 .. 10)
            tracker.recordChange(TargetId("module" ~ i.to!string), ChangeType.SourceModified);
        tracker.flush();
    }
    
    WarmerConfig config;
    config.cacheDir = testDir;
    config.asyncWarmup = false;
    
    auto warmer = new PredictorWarmer(config);
    warmer.start();
    
    // Test cache lookup
    auto pred = warmer.getCachedPrediction(TargetId("module0"));
    assert(pred !is null);
    assert(pred.targetId == TargetId("module0"));
    
    // Test top predictions
    auto top = warmer.topPredictions(5);
    assert(top.length == 5);
    
    // Verify sorted by score descending
    foreach (i; 0 .. top.length - 1)
        assert(top[i].score >= top[i + 1].score);
    
    writeln("\x1b[32m  ✓ Prediction cache lookup\x1b[0m");
}

// Private import for tests
import engine.runtime.services.speculation.history : ChangeType;

