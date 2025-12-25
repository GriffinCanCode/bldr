module engine.runtime.services.speculation.engine;

import std.algorithm : map, filter, sort, sum, min, max, canFind;
import std.array : array;
import std.datetime : Duration, msecs, seconds;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.conv : to;
import std.typecons : Nullable, nullable, Tuple, tuple;
import core.atomic;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import infrastructure.utils.concurrency.structured : TaskScope, VoidTask;
import engine.graph : BuildGraph, BuildNode, BuildStatus;
import infrastructure.config.schema.schema : TargetId, Target;
import infrastructure.utils.logging.logger;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;

import engine.runtime.services.speculation.service : 
    SpeculativeTask, SpeculativeStatus, SpeculationPolicy, ISpeculationService;
import engine.runtime.services.speculation.predictor : ChangePredictor, ChangeProbability;
import engine.runtime.services.speculation.history : HistoryTracker, ChangeType;

/// Result of speculative execution
struct SpeculativeResult
{
    TargetId targetId;
    string outputHash;
    Duration executionTime;
    string[] producedArtifacts;
    bool isValid;            // Inputs haven't changed
    string invalidReason;    // Why it was invalidated
}

/// Worker task for speculative execution
private struct WorkerTask
{
    TargetId targetId;
    BuildNode node;
    string[] inputHashes;
    size_t priority;
}

/// Speculative execution engine
/// Runs tasks speculatively on background workers, validates results before use
final class SpeculativeEngine
{
    private ISpeculationService _service;
    private ChangePredictor _predictor;
    private HistoryTracker _history;
    private BuildGraph _graph;
    private Mutex _mutex;
    private Condition _workAvailable;
    
    // Structured concurrency: TaskScope manages worker threads
    private TaskScope _taskScope;
    private VoidTask[] _workerTasks;
    private shared bool _shutdown;
    private shared size_t _activeWorkers;
    
    // Task management
    private WorkerTask[] _taskQueue;
    private SpeculativeResult[string] _results;
    private string[string] _inputSnapshots;  // path -> hash at speculation start
    
    // Configuration
    private EngineConfig _config;
    
    // Statistics
    private shared size_t _tasksCompleted;
    private shared size_t _tasksAborted;
    private shared size_t _tasksCacheHit;
    private shared long _totalExecutionTimeMs;
    
    // External executor delegate
    alias ExecutorDelegate = string delegate(BuildNode node) @system;
    private ExecutorDelegate _executor;
    
    this(
        ISpeculationService service,
        ChangePredictor predictor,
        HistoryTracker history,
        BuildGraph graph,
        EngineConfig config = EngineConfig.init
    ) @trusted
    {
        _service = service;
        _predictor = predictor;
        _history = history;
        _graph = graph;
        _config = config;
        _mutex = new Mutex();
        _workAvailable = new Condition(_mutex);
        
        atomicStore(_shutdown, false);
        atomicStore(_activeWorkers, cast(size_t)0);
        atomicStore(_tasksCompleted, cast(size_t)0);
        atomicStore(_tasksAborted, cast(size_t)0);
        atomicStore(_tasksCacheHit, cast(size_t)0);
        atomicStore(_totalExecutionTimeMs, cast(long)0);
    }
    
    /// Set the executor delegate for building nodes
    void setExecutor(ExecutorDelegate executor) @safe nothrow
    {
        _executor = executor;
    }
    
    /// Start the speculative engine using structured concurrency
    void start() @trusted
    {
        synchronized (_mutex)
        {
            if (_taskScope !is null)
                return; // Already started
            
            // Create TaskScope for hierarchical worker management
            _taskScope = new TaskScope("speculation-engine");
            _workerTasks = new VoidTask[_config.workerCount];
            
            foreach (i; 0 .. _config.workerCount)
            {
                _workerTasks[i] = _taskScope.launchBackground("worker-" ~ i.to!string, 
                    () @trusted => workerLoopBody());
            }
            
            Logger.info("Speculation engine started with " ~ 
                       _config.workerCount.to!string ~ " workers");
        }
    }
    
    /// Stop the engine - TaskScope guarantees all workers complete
    void stop() @trusted
    {
        atomicStore(_shutdown, true);
        
        // Wake up all workers
        synchronized (_mutex)
        {
            _workAvailable.notifyAll();
        }
        
        // TaskScope ensures all workers complete before continuing
        if (_taskScope !is null)
        {
            _taskScope.cancelAndJoin();
            synchronized (_mutex)
            {
                _taskScope = null;
                _workerTasks = [];
            }
        }
        
        Logger.info("Speculation engine stopped");
    }
    
    /// Begin speculative execution based on predictions
    /// Returns number of tasks queued
    size_t beginSpeculation() @trusted
    {
        if (_executor is null)
        {
            Logger.warning("Speculation: no executor set, skipping");
            return 0;
        }
        
        synchronized (_mutex)
        {
            // Get predictions from the predictor
            auto predictions = _predictor.predict();
            
            // Filter by policy thresholds
            auto policy = getPolicy();
            auto candidates = predictions
                .filter!(p => p.score >= policy.confidenceThreshold)
                .array;
            
            if (candidates.length == 0)
            {
                Logger.debugLog("Speculation: no candidates above threshold");
                return 0;
            }
            
            // Limit to max concurrent
            auto toSpeculate = min(candidates.length, policy.maxConcurrent);
            
            size_t queued = 0;
            foreach (pred; candidates[0 .. toSpeculate])
            {
                if (queueSpeculation(pred.targetId))
                    queued++;
            }
            
            if (queued > 0)
            {
                Logger.info("Speculation: queued " ~ queued.to!string ~ 
                           " tasks based on predictions");
                _workAvailable.notifyAll();
            }
            
            return queued;
        }
    }
    
    /// Queue a specific target for speculative execution
    bool queueSpeculation(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            
            // Already have result or in queue?
            if (key in _results)
                return false;
            
            foreach (task; _taskQueue)
            {
                if (task.targetId == targetId)
                    return false;
            }
            
            // Get node from graph
            auto nodePtr = key in _graph.nodes;
            if (nodePtr is null)
                return false;
            
            auto node = *nodePtr;
            
            // Skip if already building or built
            if (node.status != BuildStatus.Pending)
                return false;
            
            // Snapshot current input hashes
            auto inputHashes = snapshotInputs(node);
            
            // Get priority from predictor
            auto prediction = _predictor.predictOne(targetId);
            auto priority = prediction.isNull ? 50 : cast(size_t)(prediction.get.score * 100);
            
            _taskQueue ~= WorkerTask(targetId, node, inputHashes, priority);
            
            // Sort by priority (highest first)
            _taskQueue.sort!((a, b) => a.priority > b.priority);
            
            Logger.debugLog("Speculation: queued " ~ key ~ " (priority=" ~ priority.to!string ~ ")");
            
            return true;
        }
    }
    
    /// Notify that an input file has changed
    /// Invalidates any affected speculative results
    void notifyInputChanged(string path, string newHash) @trusted
    {
        synchronized (_mutex)
        {
            auto oldHash = _inputSnapshots.get(path, "");
            if (oldHash == newHash)
                return;
            
            _inputSnapshots[path] = newHash;
            
            // Invalidate affected results
            string[] toInvalidate;
            foreach (key, result; _results)
            {
                if (!result.isValid)
                    continue;
                
                // Check if this result depends on the changed file
                auto nodePtr = key in _graph.nodes;
                if (nodePtr is null)
                    continue;
                
                auto node = *nodePtr;
                if (dependsOnPath(node, path))
                {
                    toInvalidate ~= key;
                    atomicOp!"+="(_tasksAborted, 1);
                    Logger.debugLog("Speculation: invalidated " ~ key ~ " (input changed: " ~ path ~ ")");
                }
            }
            
            foreach (key; toInvalidate)
            {
                _results[key].isValid = false;
                _results[key].invalidReason = "input_changed:" ~ path;
            }
            
            // Also notify the service for abort semantics
            if (_service !is null)
                _service.notifyInputChanged(path, newHash);
        }
    }
    
    /// Try to get a valid speculative result
    Nullable!SpeculativeResult tryGetResult(TargetId targetId) @trusted
    {
        synchronized (_mutex)
        {
            auto key = targetId.toString();
            auto resultPtr = key in _results;
            
            if (resultPtr is null)
                return Nullable!SpeculativeResult.init;
            
            auto result = *resultPtr;
            
            // Final validation before returning
            if (!result.isValid)
            {
                _history.recordChange(targetId, ChangeType.SourceModified, [], 
                                     Duration.zero, true, false);
                return Nullable!SpeculativeResult.init;
            }
            
            // Verify inputs haven't changed since speculation
            auto nodePtr = key in _graph.nodes;
            if (nodePtr !is null)
            {
                auto node = *nodePtr;
                if (inputsChanged(node))
                {
                    result.isValid = false;
                    result.invalidReason = "inputs_changed_since_completion";
                    _results[key] = result;
                    atomicOp!"+="(_tasksAborted, 1);
                    _history.recordChange(targetId, ChangeType.SourceModified,
                                         [], Duration.zero, true, false);
                    return Nullable!SpeculativeResult.init;
                }
            }
            
            // Valid result!
            _history.recordChange(targetId, ChangeType.SourceModified,
                                 result.producedArtifacts, result.executionTime, true, true);
            
            Logger.success("Speculation: hit for " ~ key ~ 
                          " (saved " ~ result.executionTime.total!"msecs".to!string ~ "ms)");
            
            return nullable(result);
        }
    }
    
    /// Clear all speculative results (e.g., on build failure)
    void clearResults() @trusted
    {
        synchronized (_mutex)
        {
            _results.clear();
            _taskQueue = [];
        }
    }
    
    /// Get engine statistics
    EngineStats getStats() @trusted
    {
        synchronized (_mutex)
        {
            EngineStats stats;
            stats.tasksCompleted = atomicLoad(_tasksCompleted);
            stats.tasksAborted = atomicLoad(_tasksAborted);
            stats.tasksCacheHit = atomicLoad(_tasksCacheHit);
            stats.totalExecutionTimeMs = atomicLoad(_totalExecutionTimeMs);
            stats.pendingTasks = _taskQueue.length;
            stats.activeWorkers = atomicLoad(_activeWorkers);
            stats.cachedResults = _results.length;
            return stats;
        }
    }
    
private:
    /// Get policy from service
    SpeculationPolicy getPolicy() @trusted
    {
        // For now, return default. Could be made configurable.
        return SpeculationPolicy.init;
    }
    
    /// Worker loop body (called by TaskScope.launchBackground)
    void workerLoopBody() @trusted
    {
        if (atomicLoad(_shutdown) || (_taskScope !is null && _taskScope.isCancelled())) 
            return;
        
        WorkerTask task;
        bool hasTask = false;
        
        synchronized (_mutex)
        {
            // Wait for work or shutdown
            if (_taskQueue.length == 0 && !atomicLoad(_shutdown))
            {
                import core.time : msecs;
                _workAvailable.wait(100.msecs); // Short wait to allow cancellation checks
            }
            
            if (atomicLoad(_shutdown))
                return;
            
            if (_taskQueue.length > 0)
            {
                task = _taskQueue[0];
                _taskQueue = _taskQueue[1 .. $];
                hasTask = true;
                atomicOp!"+="(_activeWorkers, 1);
            }
        }
        
        if (hasTask)
        {
            scope(exit) atomicOp!"-="(_activeWorkers, 1);
            executeTask(task);
        }
    }
    
    /// Execute a speculative task
    void executeTask(WorkerTask task) @trusted
    {
        auto key = task.targetId.toString();
        auto sw = StopWatch(AutoStart.yes);
        
        try
        {
            // Check if still valid before executing
            if (inputsChanged(task.node))
            {
                Logger.debugLog("Speculation: skipping " ~ key ~ " (inputs changed)");
                atomicOp!"+="(_tasksAborted, 1);
                return;
            }
            
            // Execute the build
            Logger.debugLog("Speculation: executing " ~ key);
            
            string outputHash;
            if (_executor !is null)
            {
                outputHash = _executor(task.node);
            }
            else
            {
                outputHash = ""; // No executor, can't actually build
            }
            
            auto elapsed = sw.peek();
            
            // Store result
            synchronized (_mutex)
            {
                // Final validation
                bool isValid = !inputsChanged(task.node);
                
                SpeculativeResult result;
                result.targetId = task.targetId;
                result.outputHash = outputHash;
                result.executionTime = elapsed;
                result.producedArtifacts = task.node.target.outputPath.length > 0 
                    ? [task.node.target.outputPath] : [];
                result.isValid = isValid;
                
                if (!isValid)
                    result.invalidReason = "inputs_changed_during_execution";
                
                _results[key] = result;
                
                atomicOp!"+="(_tasksCompleted, 1);
                atomicOp!"+="(_totalExecutionTimeMs, elapsed.total!"msecs");
                
                if (isValid)
                {
                    Logger.debugLog("Speculation: completed " ~ key ~ 
                                   " in " ~ elapsed.total!"msecs".to!string ~ "ms");
                }
                else
                {
                    Logger.debugLog("Speculation: completed " ~ key ~ 
                                   " but invalidated during execution");
                    atomicOp!"+="(_tasksAborted, 1);
                }
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Speculation: failed " ~ key ~ ": " ~ e.msg);
            atomicOp!"+="(_tasksAborted, 1);
        }
    }
    
    /// Snapshot input hashes for a node
    string[] snapshotInputs(BuildNode node) @trusted
    {
        string[] hashes;
        
        // Hash sources
        foreach (source; node.target.sources)
        {
            auto hash = FastHash.hashFile(source);
            _inputSnapshots[source] = hash;
            hashes ~= hash;
        }
        
        // Hash dependency outputs
        foreach (depId; node.dependencyIds)
        {
            auto depKey = depId.toString();
            _inputSnapshots[depKey] = "dep:" ~ depKey;
            hashes ~= "dep:" ~ depKey;
        }
        
        return hashes;
    }
    
    /// Check if inputs have changed since snapshot
    bool inputsChanged(BuildNode node) @trusted
    {
        foreach (source; node.target.sources)
        {
            auto expected = _inputSnapshots.get(source, "");
            if (expected.length == 0)
                continue;
            
            auto current = FastHash.hashFile(source);
            if (current != expected)
                return true;
        }
        return false;
    }
    
    /// Check if a node depends on a path
    bool dependsOnPath(BuildNode node, string path) @trusted
    {
        // Check sources
        foreach (source; node.target.sources)
        {
            if (source == path)
                return true;
        }
        
        // Could expand to check transitive dependencies
        return false;
    }
}

/// Engine configuration
struct EngineConfig
{
    size_t workerCount = 2;           // Background workers for speculation
    size_t maxQueueSize = 100;        // Max pending speculative tasks
    Duration taskTimeout = 60.seconds; // Max time for single task
}

/// Engine statistics
struct EngineStats
{
    size_t tasksCompleted;
    size_t tasksAborted;
    size_t tasksCacheHit;
    long totalExecutionTimeMs;
    size_t pendingTasks;
    size_t activeWorkers;
    size_t cachedResults;
    
    @property float completionRate() const pure nothrow @nogc @safe
    {
        auto total = tasksCompleted + tasksAborted;
        return total == 0 ? 0.0f : cast(float)tasksCompleted / cast(float)total;
    }
    
    @property float hitRate() const pure nothrow @nogc @safe
    {
        return tasksCompleted == 0 ? 0.0f : 
            cast(float)tasksCacheHit / cast(float)tasksCompleted;
    }
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Engine: %d completed, %d aborted (%.1f%%), %d pending, %d active",
            tasksCompleted, tasksAborted, completionRate * 100,
            pendingTasks, activeWorkers
        );
    }
}

/// Create a speculative engine with all components
SpeculativeEngine createSpeculativeEngine(
    BuildGraph graph,
    string cacheDir = ".builder-cache/speculation",
    EngineConfig config = EngineConfig.init
) @trusted
{
    import engine.economics.estimator : CostEstimator, ExecutionHistory;
    import engine.runtime.services.speculation.service : SpeculationService;
    import engine.runtime.services.speculation.predictor : ChangePredictor, PredictorConfig;
    import engine.runtime.services.speculation.history : HistoryTracker, HistoryConfig;
    
    // Create components
    auto history = new HistoryTracker(cacheDir);
    auto predictor = new ChangePredictor();
    
    // Load historical state into predictor
    predictor.importState(history.getPredictorState());
    
    // Create speculation service
    auto historyObj = new ExecutionHistory();
    auto estimator = new CostEstimator(historyObj);
    auto service = new SpeculationService(estimator, graph);
    
    // Create engine
    auto engine = new SpeculativeEngine(service, predictor, history, graph, config);
    
    return engine;
}

/// Unit tests
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.engine - EngineStats formatting");
    
    EngineStats stats;
    stats.tasksCompleted = 10;
    stats.tasksAborted = 2;
    stats.pendingTasks = 5;
    stats.activeWorkers = 2;
    
    auto formatted = stats.format();
    assert(formatted.length > 0);
    assert(stats.completionRate > 0.8f && stats.completionRate < 0.9f);
    
    writeln("\x1b[32m  ✓ Stats formatting\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m speculation.engine - EngineConfig defaults");
    
    auto config = EngineConfig.init;
    assert(config.workerCount == 2);
    assert(config.maxQueueSize == 100);
    assert(config.taskTimeout == 60.seconds);
    
    writeln("\x1b[32m  ✓ Config defaults\x1b[0m");
}

