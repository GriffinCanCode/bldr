module engine.runtime.services.speculation.executor;

import std.algorithm : map, filter, sort, min, max;
import std.array : array;
import std.datetime : Duration, msecs;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.conv : to;
import std.typecons : Nullable;
import core.atomic;
import core.thread : Thread;
import engine.graph : BuildGraph, BuildNode, BuildStatus;
import infrastructure.config.schema.schema : TargetId;
import engine.runtime.services.speculation.service;
import engine.runtime.services.speculation.engine : SpeculativeEngine, EngineConfig, EngineStats, SpeculativeResult;
import engine.runtime.services.scheduling : ISchedulingService, NodeBuildResult;
import infrastructure.utils.logging.logger;

/// Speculation executor - coordinates speculative execution during builds
/// Wraps the regular execution flow and adds speculation capabilities
/// Integrates with SpeculativeEngine for background async execution
final class SpeculationExecutor
{
    private ISpeculationService _speculation;
    private ISchedulingService _scheduling;
    private BuildGraph _graph;
    private bool _enabled;
    
    // Speculative engine for background execution
    private SpeculativeEngine _engine;
    private bool _engineStarted;
    
    // Statistics
    private shared size_t _speculativeHits;     // Speculation validated and used
    private shared size_t _speculativeMisses;   // Speculation attempted but not useful
    private shared Duration _totalTimeSaved;
    
    // Executor delegate for building nodes
    alias NodeExecutor = string delegate(BuildNode node) @system;
    private NodeExecutor _nodeExecutor;
    
    this(ISpeculationService speculation, ISchedulingService scheduling, BuildGraph graph) @trusted
    {
        _speculation = speculation;
        _scheduling = scheduling;
        _graph = graph;
        _enabled = speculation !is null;
        atomicStore(_speculativeHits, cast(size_t)0);
        atomicStore(_speculativeMisses, cast(size_t)0);
    }
    
    /// Enable/disable speculation
    @property void enabled(bool value) @safe nothrow @nogc { _enabled = value; }
    @property bool enabled() const @safe nothrow @nogc => _enabled;
    
    /// Set the node executor for speculative builds
    void setNodeExecutor(NodeExecutor executor) @safe nothrow
    {
        _nodeExecutor = executor;
    }
    
    /// Initialize the speculative engine with background workers
    void initializeEngine(EngineConfig config = EngineConfig.init) @trusted
    {
        if (_engine !is null)
            return;
        
        import engine.runtime.services.speculation.engine : createSpeculativeEngine;
        _engine = createSpeculativeEngine(_graph, ".builder-cache/speculation", config);
        
        if (_nodeExecutor !is null)
            _engine.setExecutor(_nodeExecutor);
        
        Logger.debugLog("Speculation: initialized engine with " ~ 
                       config.workerCount.to!string ~ " workers");
    }
    
    /// Start the speculative engine workers
    void startEngine() @trusted
    {
        if (_engine is null)
            initializeEngine();
        
        if (!_engineStarted)
        {
            _engine.start();
            _engineStarted = true;
        }
    }
    
    /// Stop the speculative engine
    void stopEngine() @trusted
    {
        if (_engine !is null && _engineStarted)
        {
            _engine.stop();
            _engineStarted = false;
        }
    }
    
    /// Start speculative execution for critical path targets
    /// Call once after analyzing the graph
    void beginSpeculation() @trusted
    {
        if (!_enabled || _speculation is null)
            return;
        
        _speculation.analyzeGraph(_graph);
        
        // Get top candidates based on policy
        auto candidates = _speculation.getCandidates(8);
        
        if (candidates.length > 0)
        {
            Logger.info("Speculation: starting " ~ candidates.length.to!string ~ " candidates");
            
            // Start engine if available
            if (_engine !is null && !_engineStarted)
                startEngine();
            
            foreach (candidate; candidates)
            {
                auto task = _speculation.speculate(candidate);
                if (task !is null)
                {
                    startSpeculativeExecution(task);
                    
                    // Also queue in engine for background execution
                    if (_engine !is null)
                        _engine.queueSpeculation(candidate);
                }
            }
            
            // Start engine-based prediction speculation
            if (_engine !is null)
                _engine.beginSpeculation();
        }
    }
    
    /// Check if we have a valid speculative result for a target
    /// If so, use it instead of executing again
    /// Returns: NodeBuildResult if speculation valid, null otherwise
    Nullable!NodeBuildResult tryGetSpeculativeResult(TargetId targetId) @trusted
    {
        if (!_enabled)
            return Nullable!NodeBuildResult.init;
        
        // First, try engine results (newer, more sophisticated)
        if (_engine !is null)
        {
            auto engineResult = _engine.tryGetResult(targetId);
            if (!engineResult.isNull)
            {
                auto result = engineResult.get();
                if (result.isValid)
                {
                    atomicOp!"+="(_speculativeHits, 1);
                    
                    NodeBuildResult buildResult;
                    buildResult.targetId = targetId.toString();
                    buildResult.success = true;
                    buildResult.cached = true;
                    
                    Logger.debugLog("Speculation: engine hit for " ~ targetId.toString() ~ 
                                   " (saved " ~ result.executionTime.total!"msecs".to!string ~ "ms)");
                    
                    return Nullable!NodeBuildResult(buildResult);
                }
            }
        }
        
        // Fall back to service-based results
        if (_speculation is null)
            return Nullable!NodeBuildResult.init;
        
        auto result = _speculation.getValidResult(targetId);
        if (result.isNull)
        {
            atomicOp!"+="(_speculativeMisses, 1);
            return Nullable!NodeBuildResult.init;
        }
        
        auto task = result.get();
        
        // Verify the result is still valid (inputs haven't changed)
        if (task.status != SpeculativeStatus.Completed)
        {
            atomicOp!"+="(_speculativeMisses, 1);
            return Nullable!NodeBuildResult.init;
        }
        
        // Promote speculation to real result
        _speculation.promote(targetId);
        atomicOp!"+="(_speculativeHits, 1);
        
        NodeBuildResult buildResult;
        buildResult.targetId = targetId.toString();
        buildResult.success = true;
        buildResult.cached = true;  // Treat speculation hit like cache hit
        
        Logger.debugLog("Speculation: hit for " ~ targetId.toString() ~ 
                       " (saved " ~ task.actualDuration.total!"msecs".to!string ~ "ms)");
        
        return Nullable!NodeBuildResult(buildResult);
    }
    
    /// Notify that a build is starting for a target
    /// May trigger new speculations for dependents on critical path
    void notifyBuildStarting(TargetId targetId) @trusted
    {
        if (!_enabled || _speculation is null)
            return;
        
        // When a target starts building, we can speculate on its dependents
        // if they're on the critical path and likely to be needed
        auto nodePtr = targetId.toString() in _graph.nodes;
        if (nodePtr is null)
            return;
        
        auto node = *nodePtr;
        
        // Consider speculating on dependents that have only this one remaining dep
        foreach (dependentId; node.dependentIds)
        {
            auto depPtr = dependentId.toString() in _graph.nodes;
            if (depPtr is null)
                continue;
            
            auto dependent = *depPtr;
            if (dependent.pendingDeps == 1)  // This node is the only remaining dep
            {
                auto task = _speculation.speculate(dependentId);
                if (task !is null)
                    startSpeculativeExecution(task);
            }
        }
    }
    
    /// Notify that an input file has changed
    /// This will abort any affected speculation
    void notifyInputChanged(string path, string newHash) @trusted
    {
        if (_speculation !is null)
            _speculation.notifyInputChanged(path, newHash);
        
        if (_engine !is null)
            _engine.notifyInputChanged(path, newHash);
    }
    
    /// Abort all speculation (e.g., on build failure)
    void abortAllSpeculation() @trusted
    {
        if (_speculation !is null)
            _speculation.abortAll();
        
        if (_engine !is null)
            _engine.clearResults();
    }
    
    /// Get speculation statistics
    SpeculationExecutorStats getStats() @trusted
    {
        SpeculationExecutorStats stats;
        stats.hits = atomicLoad(_speculativeHits);
        stats.misses = atomicLoad(_speculativeMisses);
        
        if (_speculation !is null)
        {
            auto specStats = _speculation.getStats();
            stats.totalSpeculated = specStats.totalSpeculated;
            stats.aborted = specStats.aborted;
            stats.wasted = specStats.wasted;
            stats.timeSaved = specStats.timeSaved;
            stats.timeWasted = specStats.timeWasted;
        }
        
        // Merge engine stats
        if (_engine !is null)
        {
            auto engineStats = _engine.getStats();
            stats.totalSpeculated += engineStats.tasksCompleted;
            stats.aborted += engineStats.tasksAborted;
            stats.enginePendingTasks = engineStats.pendingTasks;
            stats.engineActiveWorkers = engineStats.activeWorkers;
        }
        
        return stats;
    }
    
    /// Shutdown and log final statistics
    void shutdown() @trusted
    {
        // Stop engine first
        stopEngine();
        
        if (_speculation !is null)
        {
            _speculation.shutdown();
            
            auto stats = getStats();
            if (stats.totalSpeculated > 0)
            {
                Logger.info("Speculation Summary:");
                Logger.info("  Speculated: " ~ stats.totalSpeculated.to!string);
                Logger.info("  Hits: " ~ stats.hits.to!string);
                Logger.info("  Aborted: " ~ stats.aborted.to!string);
                Logger.info("  Time saved: " ~ stats.timeSaved.total!"msecs".to!string ~ "ms");
                
                if (stats.enginePendingTasks > 0 || stats.engineActiveWorkers > 0)
                {
                    Logger.info("  Engine pending: " ~ stats.enginePendingTasks.to!string);
                }
            }
        }
    }
    
private:
    /// Start speculative execution of a task
    void startSpeculativeExecution(SpeculativeTask task) @trusted
    {
        // Speculation runs in parallel using available workers
        // The actual execution is deferred to when inputs become available
        task.setStatus(SpeculativeStatus.Running);
    }
}

/// Statistics for speculation executor
struct SpeculationExecutorStats
{
    size_t totalSpeculated;
    size_t hits;
    size_t misses;
    size_t aborted;
    size_t wasted;
    Duration timeSaved;
    Duration timeWasted;
    
    // Engine-specific stats
    size_t enginePendingTasks;
    size_t engineActiveWorkers;
    
    @property float hitRate() const pure nothrow @nogc
    {
        auto total = hits + misses;
        return total == 0 ? 0.0f : cast(float)hits / cast(float)total;
    }
    
    @property float successRate() const pure nothrow @nogc
    {
        auto total = totalSpeculated;
        return total == 0 ? 0.0f : cast(float)(hits) / cast(float)total;
    }
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Speculation: %d total, %d hits (%.1f%%), %d aborted, saved %dms",
            totalSpeculated, hits, hitRate * 100, aborted, 
            timeSaved.total!"msecs"
        );
    }
}

/// Create speculation executor with default configuration
SpeculationExecutor createSpeculationExecutor(
    BuildGraph graph,
    ISchedulingService scheduling,
    SpeculationPolicy policy = SpeculationPolicy.init) @trusted
{
    import engine.economics.estimator : ExecutionHistory, CostEstimator;
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto speculation = new SpeculationService(estimator, graph);
    speculation.setPolicy(policy);
    
    return new SpeculationExecutor(speculation, scheduling, graph);
}

/// Create speculation executor with predictive engine
SpeculationExecutor createPredictiveSpeculationExecutor(
    BuildGraph graph,
    ISchedulingService scheduling,
    SpeculationPolicy policy = SpeculationPolicy.init,
    string cacheDir = ".builder-cache/speculation") @trusted
{
    import engine.economics.estimator : ExecutionHistory, CostEstimator;
    
    auto history = new ExecutionHistory();
    auto estimator = new CostEstimator(history);
    auto speculation = new SpeculationService(estimator, graph);
    speculation.setPolicy(policy);
    speculation.initializePredictive(cacheDir);
    
    auto executor = new SpeculationExecutor(speculation, scheduling, graph);
    executor.initializeEngine(EngineConfig.init);
    
    return executor;
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.executor - SpeculationExecutorStats");
    
    SpeculationExecutorStats stats;
    stats.hits = 5;
    stats.misses = 3;
    
    assert(stats.hitRate > 0.6f && stats.hitRate < 0.7f);  // ~62.5%
    
    writeln("\x1b[32m  ✓ Stats hit rate\x1b[0m");
}

