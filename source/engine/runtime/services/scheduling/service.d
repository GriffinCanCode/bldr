module engine.runtime.services.scheduling.service;

import std.parallelism : totalCPUs;
import core.atomic;
import engine.graph : BuildNode;
import infrastructure.utils.concurrency.pool : ThreadPool;
import infrastructure.utils.concurrency.scheduler : WorkStealingScheduler;
import infrastructure.utils.concurrency.lockfree : LockFreeQueue;
import infrastructure.utils.concurrency.priority : Priority;
import infrastructure.errors;

/// Scheduling statistics
struct SchedulingStats
{
    size_t totalSubmitted;
    size_t totalExecuted;
    size_t totalStolen;
    size_t workerCount;
    float stealSuccessRate;
    size_t[] workerLoads;
}

/// Scheduling mode strategy
enum SchedulingMode
{
    ThreadPool,        // Simple thread pool parallelism
    WorkStealing,      // Work-stealing scheduler
    Adaptive           // Adaptive based on workload
}

/// Scheduling service interface
interface ISchedulingService
{
    /// Initialize scheduler with max parallelism (0 = auto-detect)
    void initialize(size_t maxParallelism);
    
    /// Submit a task for execution
    void submit(BuildNode node, Priority priority = Priority.Normal);
    
    /// Dequeue ready nodes (up to maxCount)
    BuildNode[] dequeueReady(size_t maxCount);
    
    /// Execute a batch of nodes in parallel
    NodeBuildResult[] executeBatch(BuildNode[] nodes, NodeBuildResult delegate(BuildNode) @system executor);
    
    /// Wait for all submitted tasks to complete
    void waitForCompletion();
    
    /// Shutdown scheduler and cleanup resources
    void shutdown();
    
    /// Get scheduling statistics
    SchedulingStats getStats();
    
    /// Check if scheduler is active
    bool isActive();
    
    /// Get worker count
    size_t workerCount();
}

/// Build result for a single node execution
struct NodeBuildResult
{
    string targetId;
    bool success = false;
    bool cached = false;
    string error;
}

/// Concrete scheduling service implementation
final class SchedulingService : ISchedulingService
{
    private ThreadPool threadPool;
    private WorkStealingScheduler!BuildNode workStealingScheduler;
    private LockFreeQueue!BuildNode* readyQueue;
    private SchedulingMode mode;
    private size_t _workerCount;
    private bool _isActive;
    private shared size_t _totalSubmitted;
    private shared size_t _totalExecuted;
    
    private enum size_t READY_QUEUE_SIZE = 1024;
    
    this(SchedulingMode mode = SchedulingMode.WorkStealing)
    {
        this.mode = mode;
        this._isActive = false;
        atomicStore(_totalSubmitted, cast(size_t)0);
        atomicStore(_totalExecuted, cast(size_t)0);
    }
    
    void initialize(size_t maxParallelism) @trusted
    {
        if (_isActive)
            return;
        
        _workerCount = maxParallelism == 0 ? totalCPUs : maxParallelism;
        
        final switch (mode)
        {
            case SchedulingMode.ThreadPool:
                threadPool = new ThreadPool(_workerCount);
                if (readyQueue is null)
                    readyQueue = new LockFreeQueue!BuildNode(READY_QUEUE_SIZE);
                break;
                
            case SchedulingMode.WorkStealing:
                workStealingScheduler = new WorkStealingScheduler!BuildNode(
                    _workerCount,
                    (BuildNode node) @system { /* handled by executeBatch */ }
                );
                break;
                
            case SchedulingMode.Adaptive:
                // Start with thread pool, can switch to work-stealing later
                threadPool = new ThreadPool(_workerCount);
                if (readyQueue is null)
                    readyQueue = new LockFreeQueue!BuildNode(READY_QUEUE_SIZE);
                break;
        }
        
        _isActive = true;
    }
    
    void submit(BuildNode node, Priority priority = Priority.Normal) @trusted
    {
        if (!_isActive)
            assert(false, "Scheduler not initialized");
        
        atomicOp!"+="(_totalSubmitted, 1);
        
        final switch (mode)
        {
            case SchedulingMode.ThreadPool:
            case SchedulingMode.Adaptive:
                if (readyQueue is null || !readyQueue.enqueue(node))
                    assert(false, "Failed to enqueue node: " ~ node.idString);
                break;
                
            case SchedulingMode.WorkStealing:
                workStealingScheduler.submit(node, priority);
                break;
        }
    }
    
    BuildNode[] dequeueReady(size_t maxCount) @trusted
    {
        if (!_isActive || mode == SchedulingMode.WorkStealing || readyQueue is null)
            return [];
        
        // Use batch dequeue for single CAS vs N CAS operations
        BuildNode[] batch;
        immutable count = readyQueue.tryDequeueBatch(maxCount, batch);
        
        return count > 0 ? batch[0 .. count] : [];
    }
    
    NodeBuildResult[] executeBatch(BuildNode[] nodes, NodeBuildResult delegate(BuildNode) @system executor) @trusted
    {
        if (!_isActive)
            assert(false, "Scheduler not initialized");
        
        if (nodes.length == 0)
            return [];
        
        NodeBuildResult[] results;
        
        final switch (mode)
        {
            case SchedulingMode.ThreadPool:
            case SchedulingMode.Adaptive:
                results = threadPool.map(nodes, executor);
                break;
                
            case SchedulingMode.WorkStealing:
                // Work-stealing handles execution internally
                results.length = nodes.length;
                foreach (i, node; nodes)
                    results[i] = executor(node);
                break;
        }
        
        atomicOp!"+="(_totalExecuted, results.length);
        return results;
    }
    
    void waitForCompletion() @trusted
    {
        if (!_isActive)
            return;
        
        if (mode == SchedulingMode.WorkStealing && workStealingScheduler !is null)
        {
            workStealingScheduler.waitAll();
        }
    }
    
    void shutdown() @trusted
    {
        if (!_isActive)
            return;
        
        _isActive = false;
        
        if (threadPool !is null)
        {
            threadPool.shutdown();
            threadPool = null;
        }
        
        if (workStealingScheduler !is null)
        {
            workStealingScheduler.shutdown();
            workStealingScheduler = null;
        }
    }
    
    SchedulingStats getStats() @trusted
    {
        SchedulingStats stats;
        stats.totalSubmitted = atomicLoad(_totalSubmitted);
        stats.totalExecuted = atomicLoad(_totalExecuted);
        stats.workerCount = _workerCount;
        
        if (mode == SchedulingMode.WorkStealing && workStealingScheduler !is null)
        {
            auto wsStats = workStealingScheduler.getStats();
            stats.totalStolen = wsStats.totalStolen;
            stats.stealSuccessRate = wsStats.stealSuccessRate;
            stats.workerLoads = wsStats.workerLoads.dup;
        }
        
        return stats;
    }
    
    bool isActive() @safe
    {
        return _isActive;
    }
    
    size_t workerCount() @safe
    {
        return _workerCount;
    }
}

