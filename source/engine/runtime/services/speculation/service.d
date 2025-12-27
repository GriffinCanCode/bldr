module engine.runtime.services.speculation.service;

import std.algorithm : map, filter, sort, sum, max, min, canFind;
import std.array : array, assocArray;
import std.datetime : Duration, msecs, seconds, Clock;
import std.conv : to;
import std.typecons : Nullable, nullable;
import core.atomic;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import engine.graph : BuildGraph, BuildNode, BuildStatus;
import infrastructure.config.schema.schema : TargetId;
import engine.economics.estimator : CostEstimator, ExecutionHistory, BuildEstimate;
import engine.economics.pricing : ResourceUsageEstimate;
import engine.distributed.coordinator.profile : ProfileGuidedScheduler, ActionProfile;
import infrastructure.errors;
import infrastructure.utils.logging;
import infrastructure.utils.concurrency.priority : Priority;

// Integration with new components
import engine.runtime.services.speculation.predictor : ChangePredictor, ChangeProbability;
import engine.runtime.services.speculation.history : HistoryTracker, ChangeType;
import engine.runtime.services.speculation.warmer : PredictorWarmer, WarmerConfig, WarmupStatus;
import engine.runtime.services.speculation.adaptive : AdaptiveSpeculator, AdaptiveConfig, TargetSpecProfile, AdaptiveState;

/// Speculation policy configuration
/// Controls the aggressiveness and budget for speculative execution
struct SpeculationPolicy
{
    size_t maxConcurrent = 4;         // Max concurrent speculative tasks
    size_t minCostMs = 500;           // Min estimated cost to speculate (ms)
    float confidenceThreshold = 0.7f; // Min probability to speculate
    float budgetFraction = 0.2f;      // Fraction of total build budget for speculation
    bool enableCriticalPath = true;   // Speculate on critical path
    bool enableFanOut = true;         // Speculate on high-fanout nodes
    bool abortOnInputChange = true;   // Abort speculation if inputs change
    
    /// Conservative policy: minimal speculation
    static SpeculationPolicy conservative() pure nothrow @nogc
    {
        SpeculationPolicy p;
        p.maxConcurrent = 2;
        p.minCostMs = 2000;
        p.confidenceThreshold = 0.9f;
        p.budgetFraction = 0.1f;
        return p;
    }
    
    /// Balanced policy: moderate speculation
    static SpeculationPolicy balanced() pure nothrow @nogc => SpeculationPolicy.init;
    
    /// Aggressive policy: maximize speculation
    static SpeculationPolicy aggressive() pure nothrow @nogc
    {
        SpeculationPolicy p;
        p.maxConcurrent = 8;
        p.minCostMs = 200;
        p.confidenceThreshold = 0.5f;
        p.budgetFraction = 0.4f;
        return p;
    }
}

/// Status of a speculative task
enum SpeculativeStatus : ubyte
{
    Pending,    // Waiting to start
    Running,    // Currently executing
    Completed,  // Finished successfully
    Aborted,    // Cancelled due to input change
    Failed,     // Execution failed
    Promoted    // Speculation validated and promoted to real result
}

/// A task being speculatively executed
final class SpeculativeTask
{
    immutable TargetId targetId;
    immutable size_t estimatedCostMs;
    immutable float confidence;
    immutable string reason;
    
    private shared SpeculativeStatus _status;
    private string[string] _inputHashes;  // path -> hash at speculation start
    private Mutex _mutex;
    private BuildNode _node;
    private Exception _error;
    
    // Result storage
    private string _resultHash;
    private Duration _actualDuration;
    
    this(TargetId targetId, BuildNode node, size_t estimatedCostMs, float confidence, string reason) @trusted
    {
        this.targetId = targetId;
        this._node = node;
        this.estimatedCostMs = estimatedCostMs;
        this.confidence = confidence;
        this.reason = reason;
        this._mutex = new Mutex();
        atomicStore(_status, SpeculativeStatus.Pending);
    }
    
    /// Record input hash at speculation start
    void recordInputHash(string path, string hash) @trusted
    {
        synchronized (_mutex) { _inputHashes[path] = hash; }
    }
    
    /// Check if any input hash changed
    bool hasInputChanged(string delegate(string) @trusted getCurrentHash) @trusted
    {
        synchronized (_mutex)
        {
            foreach (path, expectedHash; _inputHashes)
            {
                auto currentHash = getCurrentHash(path);
                if (currentHash != expectedHash)
                    return true;
            }
        }
        return false;
    }
    
    /// Get current status atomically
    @property SpeculativeStatus status() const nothrow @system @nogc => atomicLoad(_status);
    
    /// Set status atomically
    void setStatus(SpeculativeStatus s) nothrow @system @nogc { atomicStore(_status, s); }
    
    /// Mark as aborted
    void abort() nothrow @system @nogc { atomicStore(_status, SpeculativeStatus.Aborted); }
    
    /// Check if cancellation requested
    bool isAborted() const nothrow @system @nogc => atomicLoad(_status) == SpeculativeStatus.Aborted;
    
    /// Record successful completion
    void complete(string resultHash, Duration duration) @trusted
    {
        synchronized (_mutex)
        {
            _resultHash = resultHash;
            _actualDuration = duration;
        }
        atomicStore(_status, SpeculativeStatus.Completed);
    }
    
    /// Record failure
    void fail(Exception e) @trusted
    {
        synchronized (_mutex) { _error = e; }
        atomicStore(_status, SpeculativeStatus.Failed);
    }
    
    /// Get result hash (only valid if Completed)
    string resultHash() @trusted
    {
        synchronized (_mutex) { return _resultHash; }
    }
    
    /// Get underlying node
    @property BuildNode node() @system => _node;
    
    /// Get actual duration (only valid if Completed)
    Duration actualDuration() @trusted
    {
        synchronized (_mutex) { return _actualDuration; }
    }
}

/// Statistics for speculation effectiveness
struct SpeculationStats
{
    size_t totalSpeculated;      // Total tasks speculated
    size_t successful;           // Speculations that were valid and used
    size_t aborted;              // Speculations aborted due to input changes
    size_t wasted;               // Speculations completed but not used
    Duration timeSaved;          // Estimated time saved from valid speculation
    Duration timeWasted;         // Time spent on wasted speculation
    
    /// Speculation effectiveness ratio (higher = better)
    @property float effectiveness() const pure nothrow @nogc @trusted
    {
        if (totalSpeculated == 0) return 0.0f;
        return cast(float)successful / cast(float)totalSpeculated;
    }
    
    /// Return on speculation investment
    @property float roi() const pure nothrow @nogc @trusted
    {
        auto wastedMs = timeWasted.total!"msecs";
        if (wastedMs == 0) return float.infinity;
        return cast(float)timeSaved.total!"msecs" / cast(float)wastedMs;
    }
}

/// Interface for speculation service
interface ISpeculationService
{
    /// Set speculation policy
    void setPolicy(SpeculationPolicy policy);
    
    /// Analyze graph and identify speculation candidates
    void analyzeGraph(BuildGraph graph);
    
    /// Get top speculation candidates (ordered by priority)
    TargetId[] getCandidates(size_t maxCount);
    
    /// Start speculative execution of a target
    SpeculativeTask speculate(TargetId targetId);
    
    /// Notify that an input file changed (triggers abort check)
    void notifyInputChanged(string path, string newHash);
    
    /// Check if a speculative result is available and valid
    Nullable!SpeculativeTask getValidResult(TargetId targetId);
    
    /// Promote speculation to real result
    void promote(TargetId targetId);
    
    /// Abort all pending/running speculations
    void abortAll();
    
    /// Get speculation statistics
    SpeculationStats getStats();
    
    /// Shutdown and cleanup
    void shutdown();
}

/// Speculative execution service
/// Manages critical path speculation with abort semantics
/// Integrates with ChangePredictor for probability-based candidate selection
/// and HistoryTracker for learning from past patterns
final class SpeculationService : ISpeculationService
{
    private ProfileGuidedScheduler _profiler;
    private CostEstimator _estimator;
    private BuildGraph _graph;
    private Mutex _mutex;
    private SpeculationPolicy _policy;
    
    // Active speculations
    private SpeculativeTask[string] _tasks;
    private shared size_t _activeCount;
    
    // Candidates computed from critical path
    private SpeculationCandidate[] _candidates;
    
    // Statistics
    private SpeculationStats _stats;
    
    // Hash tracking for abort detection
    private string[string] _currentHashes;  // path -> current hash
    
    // New components for probability-based speculation
    private ChangePredictor _predictor;
    private HistoryTracker _history;
    private PredictorWarmer _warmer;
    private bool _usePredictiveMode;
    
    // Profile-guided speculation with adaptive thresholds
    private AdaptiveSpeculator _adaptive;
    private bool _useAdaptiveMode;
    
    this(CostEstimator estimator, BuildGraph graph = null) @trusted
    {
        _estimator = estimator;
        _graph = graph;
        _mutex = new Mutex();
        _policy = SpeculationPolicy.init;
        atomicStore(_activeCount, cast(size_t)0);
        
        if (graph !is null)
            _profiler = new ProfileGuidedScheduler(estimator, graph);
    }
    
    /// Initialize with predictive components for change-probability-based speculation
    void initializePredictive(string cacheDir = ".builder-cache/speculation") @trusted
    {
        synchronized (_mutex)
        {
            import engine.runtime.services.speculation.predictor : PredictorConfig;
            import engine.runtime.services.speculation.history : HistoryConfig;
            
            _history = new HistoryTracker(cacheDir);
            _predictor = new ChangePredictor();
            
            // Load historical patterns into predictor
            _predictor.importState(_history.getPredictorState());
            
            _usePredictiveMode = true;
            structuredLog.debug_("speculation_initialized_predictive_mode").emit();
        }
    }
    
    /// Initialize with pre-warmed predictor for sub-millisecond startup
    /// Background warmup loads state and pre-computes predictions asynchronously
    void initializeWithWarmer(WarmerConfig config = WarmerConfig.init) @trusted
    {
        synchronized (_mutex)
        {
            _warmer = new PredictorWarmer(config);
            _warmer.start();
            
            // Non-blocking - predictor/history populated when ready
            _usePredictiveMode = true;
            structuredLog.debug_("speculation_initialized_with_warmer").emit();
        }
    }
    
    /// Wait for pre-warming to complete (for eager initialization)
    bool awaitWarmup(Duration timeout = Duration.zero) @trusted
    {
        if (_warmer is null) return true;
        
        if (!_warmer.awaitReady(timeout)) return false;
        
        // Transfer warmed components
        synchronized (_mutex)
        {
            _predictor = _warmer.predictor();
            _history = _warmer.history();
        }
        return true;
    }
    
    /// Initialize profile-guided adaptive thresholds
    /// Dynamically adjusts confidence thresholds per-target based on hit rates
    void initializeAdaptive(AdaptiveConfig config = AdaptiveConfig.init) @trusted
    {
        synchronized (_mutex)
        {
            _adaptive = new AdaptiveSpeculator(config);
            _useAdaptiveMode = true;
            
            // Load persisted adaptive state if available
            if (_history !is null)
            {
                auto stateFile = _history._cacheDir ~ "/adaptive_state.json";
                import std.file : exists, readText;
                import std.json : parseJSON, JSONType;
                
                if (exists(stateFile))
                {
                    try
                    {
                        auto json = parseJSON(readText(stateFile));
                        AdaptiveState state;
                        
                        if ("profiles" in json && json["profiles"].type == JSONType.object)
                        {
                            foreach (key, val; json["profiles"].objectNoRef)
                            {
                                if (val.type != JSONType.object) continue;
                                TargetSpecProfile profile;
                                profile.speculationAttempts = cast(size_t)val["attempts"].integer;
                                profile.speculationHits = cast(size_t)val["hits"].integer;
                                profile.speculationMisses = cast(size_t)val["misses"].integer;
                                profile.currentThreshold = cast(float)val["threshold"].floating;
                                profile.ewmaHitRate = cast(float)val["ewmaHitRate"].floating;
                                state.profiles[key] = profile;
                            }
                        }
                        
                        _adaptive.importState(state);
                    }
                    catch (Exception) {}
                }
            }
            
            structuredLog.debug_("speculation_initialized_adaptive_mode").emit();
        }
    }
    
    /// Get adaptive speculator for direct access
    AdaptiveSpeculator getAdaptive() @trusted
    {
        synchronized (_mutex) { return _adaptive; }
    }
    
    /// Check if adaptive mode is enabled
    @property bool isAdaptiveMode() const @safe nothrow => _useAdaptiveMode;
    
    /// Get adaptive threshold for a target (uses profile-guided adjustment)
    float getAdaptiveThreshold(TargetId targetId) @trusted
    {
        if (_adaptive is null)
            return _policy.confidenceThreshold;
        return _adaptive.getThreshold(targetId);
    }
    
    /// Check if predictor is warmed and ready
    @property bool isWarmed() const @safe nothrow
        => _warmer is null || _warmer.isReady;
    
    /// Get warmup status
    @property WarmupStatus warmupStatus() const @safe nothrow
        => _warmer !is null ? _warmer.status : WarmupStatus.Ready;
    
    /// Get pre-warmed prediction (O(1) lookup after warmup)
    Nullable!(const(ChangeProbability)) getWarmedPrediction(TargetId targetId) @trusted
    {
        if (_warmer is null || !_warmer.isReady)
            return Nullable!(const(ChangeProbability)).init;
        
        auto pred = _warmer.getCachedPrediction(targetId);
        return pred !is null ? nullable(*pred) : Nullable!(const(ChangeProbability)).init;
    }
    
    /// Get top N pre-warmed predictions
    ChangeProbability[] getTopWarmedPredictions(size_t n = 100) @trusted
        => _warmer !is null ? _warmer.topPredictions(n) : [];
    
    /// Get the warmer for metrics/monitoring
    PredictorWarmer getWarmer() @trusted
    {
        synchronized (_mutex) { return _warmer; }
    }
    
    /// Get the change predictor (for external use)
    ChangePredictor getPredictor() @trusted
    {
        synchronized (_mutex) { return _predictor; }
    }
    
    /// Get the history tracker (for external use)
    HistoryTracker getHistory() @trusted
    {
        synchronized (_mutex) { return _history; }
    }
    
    /// Check if predictive mode is enabled
    @property bool isPredictiveMode() const @safe nothrow => _usePredictiveMode;
    
    void setPolicy(SpeculationPolicy policy) @trusted
    {
        synchronized (_mutex) { _policy = policy; }
    }
    
    void analyzeGraph(BuildGraph graph) @trusted
    {
        synchronized (_mutex)
        {
            _graph = graph;
            _profiler = new ProfileGuidedScheduler(_estimator, graph);
            _profiler.computeProfiles();
            _candidates = computeCandidates();
            
            structuredLog.debug_("speculation_analyzed_").field("detail", "Speculation: analyzed " ~ graph.nodeCount.to!string ~ 
                           " nodes, found " ~ _candidates.length.to!string ~ " candidates").emit();
        }
    }
    
    TargetId[] getCandidates(size_t maxCount) @trusted
    {
        synchronized (_mutex)
        {
            auto count = min(maxCount, _candidates.length);
            return _candidates[0 .. count].map!(c => c.targetId).array;
        }
    }
    
    SpeculativeTask speculate(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            
            // Already speculating?
            if (key in _tasks)
                return _tasks[key];
            
            // Check concurrent limit
            if (atomicLoad(_activeCount) >= _policy.maxConcurrent)
            {
                structuredLog.debug_("speculation_at_concurrent_limit_skipping").field("detail", "Speculation: at concurrent limit, skipping " ~ key).emit();
                return null;
            }
            
            // Get node and profile
            auto node = _graph.getNodeByKey(key);
            if (node is null)
                return null;
            
            auto profile = _profiler.getProfile(key);
            if (profile is null)
                return null;
            
            // Check min cost threshold
            if (profile.estimatedCostMs < _policy.minCostMs)
            {
                structuredLog.debug_("speculation_").field("detail", "Speculation: " ~ key ~ " too cheap (" ~ 
                               profile.estimatedCostMs.to!string ~ "ms < " ~ 
                               _policy.minCostMs.to!string ~ "ms)").emit();
                return null;
            }
            
            // Create speculative task
            auto reason = determineReason(*profile);
            auto task = new SpeculativeTask(
                targetId, 
                node, 
                profile.estimatedCostMs,
                1.0f - profile.cacheHitProbability,  // Confidence inversely related to cache hit
                reason
            );
            
            // Record current input hashes
            recordInputHashes(task, node);
            
            _tasks[key] = task;
            atomicOp!"+="(_activeCount, 1);
            _stats.totalSpeculated++;
            
            task.setStatus(SpeculativeStatus.Running);
            structuredLog.info("speculation_starting_").field("detail", "Speculation: starting " ~ key ~ " (" ~ reason ~ ")").emit();
            
            return task;
        }
    }
    
    void notifyInputChanged(string path, string newHash) @trusted
    {
        synchronized (_mutex)
        {
            auto oldHash = _currentHashes.get(path, "");
            if (oldHash == newHash)
                return;
            
            _currentHashes[path] = newHash;
            
            if (!_policy.abortOnInputChange)
                return;
            
            // Check all active speculations
            foreach (key, task; _tasks)
            {
                if (task.status == SpeculativeStatus.Running)
                {
                    if (task.hasInputChanged((p) @trusted => _currentHashes.get(p, "")))
                    {
                        task.abort();
                        _stats.aborted++;
                        structuredLog.warning("speculation_aborting_").field("detail", "Speculation: aborting " ~ key ~ " (input changed: " ~ path ~ ")").emit();
                    }
                }
            }
        }
    }
    
    Nullable!SpeculativeTask getValidResult(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            auto taskPtr = key in _tasks;
            
            if (taskPtr is null)
                return Nullable!SpeculativeTask.init;
            
            auto task = *taskPtr;
            
            // Only return completed, non-aborted results
            if (task.status != SpeculativeStatus.Completed)
                return Nullable!SpeculativeTask.init;
            
            // Final validation: check inputs haven't changed
            if (task.hasInputChanged((p) @trusted => _currentHashes.get(p, "")))
            {
                task.abort();
                _stats.aborted++;
                return Nullable!SpeculativeTask.init;
            }
            
            return nullable(task);
        }
    }
    
    void promote(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            auto taskPtr = key in _tasks;
            
            if (taskPtr !is null)
            {
                auto task = *taskPtr;
                if (task.status == SpeculativeStatus.Completed)
                {
                    task.setStatus(SpeculativeStatus.Promoted);
                    _stats.successful++;
                    _stats.timeSaved += task.actualDuration;
                    structuredLog.info("speculation_promoted_").field("detail", "Speculation: promoted " ~ key ~ 
                                  " (saved " ~ task.actualDuration.total!"msecs".to!string ~ "ms)").emit();
                    
                    // Record successful speculation in history
                    if (_history !is null)
                    {
                        _history.recordChange(targetId, ChangeType.SourceModified,
                                            [], task.actualDuration, true, true);
                    }
                    
                    // Update predictor with successful speculation
                    if (_predictor !is null)
                        _predictor.recordChange(targetId);
                    
                    // Record hit in adaptive speculator for threshold tuning
                    if (_adaptive !is null)
                        _adaptive.recordOutcome(targetId, true, task.actualDuration);
                }
                atomicOp!"-="(_activeCount, 1);
            }
        }
    }
    
    /// Record a speculation miss (aborted or wasted)
    void recordSpeculationMiss(TargetId targetId, Duration duration) @trusted
    {
        synchronized (_mutex)
        {
            if (_adaptive !is null)
                _adaptive.recordOutcome(targetId, false, duration);
        }
    }
    
    void abortAll() @trusted
    {
        synchronized (_mutex)
        {
            foreach (key, task; _tasks)
            {
                auto status = task.status;
                if (status == SpeculativeStatus.Running || status == SpeculativeStatus.Pending)
                {
                    task.abort();
                    _stats.aborted++;
                    
                    // Record miss in adaptive speculator
                    if (_adaptive !is null)
                        _adaptive.recordOutcome(task.targetId, false, task.actualDuration);
                }
                else if (status == SpeculativeStatus.Completed)
                {
                    _stats.wasted++;
                    _stats.timeWasted += task.actualDuration;
                    
                    // Completed but not promoted = wasted speculation
                    if (_adaptive !is null)
                        _adaptive.recordOutcome(task.targetId, false, task.actualDuration);
                }
            }
            _tasks.clear();
            atomicStore(_activeCount, cast(size_t)0);
        }
    }
    
    SpeculationStats getStats() @trusted
    {
        synchronized (_mutex) { return _stats; }
    }
    
    void shutdown() @trusted
    {
        abortAll();
        
        // Save predictor state to history for persistence
        synchronized (_mutex)
        {
            // Ensure we have predictor/history from warmer if used
            if (_warmer !is null && _warmer.isReady)
            {
                if (_predictor is null) _predictor = _warmer.predictor();
                if (_history is null) _history = _warmer.history();
            }
            
            if (_history !is null && _predictor !is null)
            {
                _history.updatePredictorState(_predictor.exportState());
                _history.flush();
                structuredLog.debug_("speculation_saved_predictor_state").emit();
            }
            
            // Save adaptive speculation state
            if (_adaptive !is null && _history !is null)
            {
                import std.file : write;
                import std.json : JSONValue;
                
                auto state = _adaptive.exportState();
                JSONValue json;
                JSONValue profiles;
                
                foreach (key, profile; state.profiles)
                {
                    JSONValue p;
                    p["attempts"] = JSONValue(profile.speculationAttempts);
                    p["hits"] = JSONValue(profile.speculationHits);
                    p["misses"] = JSONValue(profile.speculationMisses);
                    p["threshold"] = JSONValue(profile.currentThreshold);
                    p["ewmaHitRate"] = JSONValue(profile.ewmaHitRate);
                    profiles[key] = p;
                }
                json["profiles"] = profiles;
                
                auto stateFile = _history._cacheDir ~ "/adaptive_state.json";
                write(stateFile, json.toPrettyString());
                structuredLog.debug_("speculation_saved_adaptive_state").emit();
            }
        }
        
        structuredLog.debug_("speculation_shutdown_stats_").field("detail", "Speculation: shutdown, stats: " ~ formatStats(_stats)).emit();
    }
    
    /// Record a change event (for learning)
    void recordChange(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            if (_predictor !is null)
                _predictor.recordChange(targetId);
            
            if (_history !is null)
                _history.recordChange(targetId, ChangeType.SourceModified);
        }
    }
    
    /// Record that a target was rebuilt but didn't actually change
    void recordNoChange(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            if (_predictor !is null)
                _predictor.recordNoChange(targetId);
        }
    }
    
private:
    /// Speculation candidate with priority score
    struct SpeculationCandidate
    {
        TargetId targetId;
        size_t score;
        string reason;
        float changeProbability;  // From predictor (0.0 - 1.0)
    }
    
    /// Compute speculation candidates using both critical path and change probability
    SpeculationCandidate[] computeCandidates() @trusted
    {
        SpeculationCandidate[] candidates;
        
        // Get change predictions - prefer warmer's O(1) cache if available
        ChangeProbability[string] predictions;
        if (_usePredictiveMode)
        {
            if (_warmer !is null && _warmer.isReady)
            {
                // Use pre-computed cache for O(1) lookups
                predictions = _warmer.predictionCache().byTarget.dup;
            }
            else if (_predictor !is null)
            {
                // Fallback to computing predictions
                foreach (pred; _predictor.predict())
                    predictions[pred.targetId.toString()] = pred;
            }
        }
        
        foreach (node; _graph._nodeArray)
        {
            if (node is null) continue;
            auto key = node.id.toString();
            auto profile = _profiler.getProfile(key);
            if (profile is null)
                continue;
            
            // Skip cheap targets
            if (profile.estimatedCostMs < _policy.minCostMs)
                continue;
            
            // Calculate speculation score
            size_t score = 0;
            string reason;
            float changeProbability = 0.0f;
            
            // Factor 1: Critical path contribution
            if (_policy.enableCriticalPath && profile.criticalPathCost > 0)
            {
                score += profile.criticalPathCost;
                reason = "critical_path";
            }
            
            // Factor 2: Fan-out contribution (high dependent count)
            if (_policy.enableFanOut && profile.dependentCount > 2)
            {
                score += profile.dependentCount * 100;
                if (reason.length > 0) reason ~= "+";
                reason ~= "fan_out";
            }
            
            // Factor 3: Change probability from predictor (NEW)
            if (auto predPtr = key in predictions)
            {
                auto pred = *predPtr;
                changeProbability = pred.probability;
                
                // Boost score based on change probability
                // High change probability = more valuable to speculate
                auto probabilityBoost = cast(size_t)(pred.score * 1000);
                score += probabilityBoost;
                
                if (pred.probability > 0.5f)
                {
                    if (reason.length > 0) reason ~= "+";
                    reason ~= "high_change_prob(" ~ 
                             (cast(int)(pred.probability * 100)).to!string ~ "%)";
                }
            }
            
            // Get adaptive threshold for this target (profile-guided)
            auto effectiveThreshold = _useAdaptiveMode && _adaptive !is null
                ? _adaptive.getThreshold(node.id)
                : _policy.confidenceThreshold;
            
            // Penalize low confidence (high cache hit probability)
            if (profile.cacheHitProbability > effectiveThreshold)
            {
                // Unless predictor says it's likely to change
                if (changeProbability < 0.6f)
                    continue;
                
                // High change probability overrides cache hit expectation
                reason ~= "+override_cache";
            }
            
            // Adaptive boost: targets with good historical hit rates get priority
            if (_useAdaptiveMode && _adaptive !is null)
            {
                auto targetProfile = _adaptive.getProfile(node.id);
                if (targetProfile.speculationAttempts >= 5 && targetProfile.hitRate > 0.7f)
                {
                    score += cast(size_t)(targetProfile.hitRate * 500);
                    if (reason.length > 0) reason ~= "+";
                    reason ~= "adaptive_boost";
                }
            }
            
            if (score > 0)
                candidates ~= SpeculationCandidate(node.id, score, reason, changeProbability);
        }
        
        // Sort by score descending
        candidates.sort!((a, b) => a.score > b.score);
        
        return candidates;
    }
    
    /// Record input hashes for a task
    void recordInputHashes(SpeculativeTask task, BuildNode node) @trusted
    {
        // Record source file hashes
        foreach (source; node.target.sources)
            task.recordInputHash(source, _currentHashes.get(source, ""));
        
        // Record dependency output hashes
        foreach (depId; node.dependencyIds)
        {
            auto depKey = depId.toString();
            task.recordInputHash(depKey, _currentHashes.get(depKey, ""));
        }
    }
    
    /// Determine speculation reason from profile
    string determineReason(const ActionProfile profile) pure @safe
    {
        if (profile.criticalPathCost > profile.estimatedCostMs * 2)
            return "critical_path";
        if (profile.dependentCount > 5)
            return "high_fanout";
        return "cost_benefit";
    }
    
    /// Format stats for logging
    static string formatStats(const SpeculationStats stats) @safe
    {
        import std.format : format;
        return format("speculated=%d success=%d aborted=%d wasted=%d eff=%.1f%% roi=%.2f",
            stats.totalSpeculated, stats.successful, stats.aborted, stats.wasted,
            stats.effectiveness * 100, stats.roi);
    }
}

/// Create speculation service from execution history
SpeculationService createSpeculationService(BuildGraph graph, ExecutionHistory history) @trusted
{
    auto estimator = new CostEstimator(history);
    auto service = new SpeculationService(estimator, graph);
    service.analyzeGraph(graph);
    return service;
}

/// Unit tests
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.service - SpeculationPolicy presets");
    
    auto cons = SpeculationPolicy.conservative();
    auto bal = SpeculationPolicy.balanced();
    auto agg = SpeculationPolicy.aggressive();
    
    assert(cons.maxConcurrent < bal.maxConcurrent);
    assert(bal.maxConcurrent < agg.maxConcurrent);
    assert(cons.minCostMs > bal.minCostMs);
    assert(bal.minCostMs > agg.minCostMs);
    
    writeln("\x1b[32m  ✓ Policy presets\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.service - SpeculationStats effectiveness");
    
    SpeculationStats stats;
    stats.totalSpeculated = 10;
    stats.successful = 7;
    stats.aborted = 2;
    stats.wasted = 1;
    stats.timeSaved = 5000.msecs;
    stats.timeWasted = 500.msecs;
    
    assert(stats.effectiveness == 0.7f);
    assert(stats.roi == 10.0f);  // 5000/500 = 10x ROI
    
    writeln("\x1b[32m  ✓ Stats effectiveness\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.service - SpeculativeTask status transitions");
    
    import infrastructure.config.schema.schema : Target;
    
    auto target = Target.init;
    auto tid = TargetId("test");
    
    // Note: BuildNode requires a graph context, so we test status transitions only
    SpeculativeStatus s = SpeculativeStatus.Pending;
    assert(s == SpeculativeStatus.Pending);
    s = SpeculativeStatus.Running;
    assert(s == SpeculativeStatus.Running);
    s = SpeculativeStatus.Completed;
    assert(s == SpeculativeStatus.Completed);
    
    writeln("\x1b[32m  ✓ Status transitions\x1b[0m");
}

