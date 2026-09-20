module engine.runtime.services.scheduling.service;

import std.parallelism : totalCPUs;
import core.atomic;
import core.sync.mutex : Mutex;
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

/// One node plus the result slot it must fill, as handed to a work-stealing worker
private final class BatchTask
{
    BuildNode node;
    size_t slot;
    
    this(BuildNode node, size_t slot) @safe nothrow @nogc
    {
        this.node = node;
        this.slot = slot;
    }
}

/// Concrete scheduling service implementation
///
/// The ready queue is the coordination channel in every mode: the engine
/// coordinator submits nodes whose dependencies are satisfied and drains them
/// in waves. The mode only decides how a wave is executed in parallel —
/// a fixed thread pool, or work-stealing workers that rebalance long targets.
final class SchedulingService : ISchedulingService
{
    private ThreadPool threadPool;
    private WorkStealingScheduler!BatchTask workStealingScheduler;
    private LockFreeQueue!BuildNode* readyQueue;
    private SchedulingMode mode;
    private size_t _workerCount;
    private bool _isActive;
    private shared size_t _totalSubmitted;
    private shared size_t _totalExecuted;
    
    // Spillover for submissions that arrive when the bounded ready queue is
    // full; drained back into the queue as workers consume it.
    private BuildNode[] _overflow;
    private Mutex _overflowMutex;
    
    // Per-wave state for work-stealing execution. Guarded by _batchMutex so
    // only one wave is in flight at a time.
    private Mutex _batchMutex;
    private NodeBuildResult delegate(BuildNode) @system _batchExecutor;
    private NodeBuildResult[] _batchResults;
    private shared size_t _batchRemaining;
    
    private enum size_t READY_QUEUE_SIZE = 1024;
    
    this(SchedulingMode mode = SchedulingMode.WorkStealing)
    {
        this.mode = mode;
        this._isActive = false;
        this._overflowMutex = new Mutex();
        this._batchMutex = new Mutex();
        atomicStore(_totalSubmitted, cast(size_t)0);
        atomicStore(_totalExecuted, cast(size_t)0);
    }
    
    void initialize(size_t maxParallelism) @trusted
    {
        if (_isActive)
            return;
        
        _workerCount = maxParallelism == 0 ? totalCPUs : maxParallelism;
        
        if (readyQueue is null)
            readyQueue = new LockFreeQueue!BuildNode(READY_QUEUE_SIZE);
        
        final switch (mode)
        {
            case SchedulingMode.ThreadPool:
            case SchedulingMode.Adaptive:
                threadPool = new ThreadPool(_workerCount);
                break;
                
            case SchedulingMode.WorkStealing:
                workStealingScheduler = new WorkStealingScheduler!BatchTask(
                    _workerCount, &runBatchTask);
                break;
        }
        
        _isActive = true;
    }
    
    void submit(BuildNode node, Priority priority = Priority.Normal) @trusted
    {
        if (!_isActive)
            assert(false, "Scheduler not initialized");
        
        atomicOp!"+="(_totalSubmitted, 1);
        
        // A wide graph can have more simultaneously-ready nodes than the queue
        // holds; spill rather than abort the build.
        if (!readyQueue.enqueue(node))
        {
            synchronized (_overflowMutex)
                _overflow ~= node;
        }
    }
    
    BuildNode[] dequeueReady(size_t maxCount) @trusted
    {
        if (!_isActive || readyQueue is null)
            return [];
        
        // Use batch dequeue for single CAS vs N CAS operations
        BuildNode[] batch;
        immutable count = readyQueue.tryDequeueBatch(maxCount, batch);
        
        drainOverflow();
        
        return count > 0 ? batch[0 .. count] : [];
    }
    
    /// Move spilled nodes back into the ready queue now that slots freed up
    private void drainOverflow() @trusted
    {
        synchronized (_overflowMutex)
        {
            size_t moved;
            while (moved < _overflow.length && readyQueue.enqueue(_overflow[moved]))
                moved++;
            
            if (moved > 0)
                _overflow = _overflow[moved .. $];
        }
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
                results = executeBatchWorkStealing(nodes, executor);
                break;
        }
        
        atomicOp!"+="(_totalExecuted, results.length);
        return results;
    }
    
    /// Run one wave across the work-stealing workers and collect results in order
    private NodeBuildResult[] executeBatchWorkStealing(
        BuildNode[] nodes,
        NodeBuildResult delegate(BuildNode) @system executor) @trusted
    {
        import core.thread : Thread;
        import core.time : usecs;
        
        synchronized (_batchMutex)
        {
            _batchExecutor = executor;
            _batchResults = new NodeBuildResult[nodes.length];
            atomicStore(_batchRemaining, nodes.length);
            
            foreach (i, node; nodes)
                workStealingScheduler.submit(new BatchTask(node, i));
            
            // Workers release _batchResults writes via the atomic decrement below,
            // so this acquire load makes the whole wave visible once it hits zero.
            while (atomicLoad(_batchRemaining) > 0)
                Thread.sleep(50.usecs);
            
            return _batchResults;
        }
    }
    
    /// Work-stealing worker entry point: run one node, record its result
    private void runBatchTask(BatchTask task) @system
    {
        // Unconditional: the wave's wait loop only ends when every slot reports,
        // so an unwind here must still count or the build hangs.
        scope(exit) atomicOp!"-="(_batchRemaining, 1);
        
        NodeBuildResult result;
        
        try
            result = _batchExecutor(task.node);
        catch (Exception e)
        {
            result.targetId = task.node.idString;
            result.success = false;
            result.error = e.msg;
        }
        
        _batchResults[task.slot] = result;
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

