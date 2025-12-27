module infrastructure.utils.concurrency.parallel;

import std.parallelism : totalCPUs;
import std.algorithm;
import std.array;
import std.range;
import std.conv;
import core.atomic;
import infrastructure.utils.concurrency.scheduler;
import infrastructure.utils.concurrency.balancer;
import infrastructure.utils.concurrency.priority;
import infrastructure.utils.concurrency.pool;

/// Singleton thread pool for amortized parallel execution
/// Lazily initialized, thread-safe via D's shared static initialization
private __gshared ThreadPool sharedPool;
private shared bool poolInitialized;

/// Get singleton pool (lazy initialization)
@system private ThreadPool getSharedPool(size_t workerCount)
{
    // Double-checked locking with atomic
    if (!atomicLoad(poolInitialized))
    {
        synchronized
        {
            if (!atomicLoad(poolInitialized))
            {
                immutable workers = workerCount == 0 ? totalCPUs : workerCount;
                sharedPool = new ThreadPool(workers);
                atomicStore(poolInitialized, true);
            }
        }
    }
    return sharedPool;
}

/// Shutdown the shared pool (call on application exit)
@system void shutdownSharedPool() nothrow
{
    if (atomicLoad(poolInitialized))
    {
        try
        {
            synchronized
            {
                if (atomicLoad(poolInitialized) && sharedPool !is null)
                {
                    sharedPool.shutdown();
                    atomicStore(poolInitialized, false);
                    sharedPool = null;
                }
            }
        }
        catch (Exception) {}
    }
}


/// Execution mode for parallel operations
enum ExecutionMode
{
    Simple,          // Basic std.parallelism (backward compatible)
    WorkStealing,    // Work-stealing scheduler
    LoadBalanced,    // Dynamic load balancing
    Priority         // Priority-based scheduling
}

/// Configuration for parallel execution
struct ParallelConfig
{
    ExecutionMode mode = ExecutionMode.Simple;
    Priority basePriority = Priority.Normal;
    BalanceStrategy balanceStrategy = BalanceStrategy.Adaptive;
    size_t maxParallelism = 0;  // 0 = auto-detect
    bool enableStatistics = false;
}

/// Statistics from parallel execution
struct ExecutionStats
{
    size_t totalTasks;
    size_t totalExecuted;
    size_t totalStolen;
    float stealSuccessRate;
    float loadImbalance;
    size_t[] workerLoads;
}

/// Enhanced parallel execution utilities with work-stealing and load balancing
/// Maintains backward compatibility while adding sophisticated scheduling
struct ParallelExecutor
{
    /// Execute a function on items in parallel (simple mode - backward compatible)
    /// Uses singleton pool for amortized thread creation overhead
    @system
    static R[] execute(T, R)(T[] items, R delegate(T) @system func, size_t maxParallelism)
    {
        if (items.empty)
            return [];
        
        if (items.length == 1 || maxParallelism == 1)
        {
            R[] results;
            foreach (item; items)
                results ~= func(item);
            return results;
        }
        
        return getSharedPool(maxParallelism).map(items, func);
    }
    
    /// Execute with automatic parallelism based on CPU count (backward compatible)
    static R[] executeAuto(T, R)(T[] items, R delegate(T) @system func)
    {
        return execute(items, func, totalCPUs);
    }
    
    /// Execute with advanced configuration (work-stealing, load balancing, priorities)
    @system
    static R[] executeAdvanced(T, R)(T[] items, R delegate(T) @system func, ParallelConfig config)
    {
        if (items.empty)
            return [];
        
        if (items.length == 1)
            return [func(items[0])];
        
        immutable workerCount = config.maxParallelism == 0 ? totalCPUs : config.maxParallelism;
        
        // Dispatch to appropriate execution mode
        final switch (config.mode)
        {
            case ExecutionMode.Simple:
                return execute(items, func, workerCount);
            
            case ExecutionMode.WorkStealing:
                return executeWorkStealing(items, func, workerCount, config);
            
            case ExecutionMode.LoadBalanced:
                return executeLoadBalanced(items, func, workerCount, config);
            
            case ExecutionMode.Priority:
                return executePriority(items, func, workerCount, config);
        }
    }
    
    /// Execute with work-stealing scheduler
    @system
    private static R[] executeWorkStealing(T, R)(T[] items, R delegate(T) @system func, 
                                                  size_t workerCount, ParallelConfig config)
    {
        R[] results;
        results.length = items.length;
        shared size_t[] indices;
        indices.length = items.length;
        
        auto scheduler = new WorkStealingScheduler!size_t(
            workerCount,
            (size_t idx) @system {
                results[idx] = func(items[idx]);
            }
        );
        
        // Submit all tasks
        foreach (i; 0 .. items.length)
            scheduler.submit(i, config.basePriority);
        
        scheduler.waitAll();
        scheduler.shutdown();
        
        return results;
    }
    
    /// Execute with dynamic load balancing
    @system
    private static R[] executeLoadBalanced(T, R)(T[] items, R delegate(T) @system func,
                                                  size_t workerCount, ParallelConfig config)
    {
        R[] results;
        results.length = items.length;
        
        auto balancer = new LoadBalancer(workerCount, config.balanceStrategy);
        auto scheduler = new WorkStealingScheduler!size_t(
            workerCount,
            (size_t idx) @system {
                results[idx] = func(items[idx]);
            }
        );
        
        // Distribute tasks using load balancer
        foreach (i; 0 .. items.length)
        {
            immutable workerId = balancer.selectWorker();
            scheduler.submit(i, config.basePriority);
        }
        
        scheduler.waitAll();
        scheduler.shutdown();
        
        return results;
    }
    
    /// Execute with priority-based scheduling
    @system
    private static R[] executePriority(T, R)(T[] items, R delegate(T) @system func,
                                             size_t workerCount, ParallelConfig config)
    {
        R[] results;
        results.length = items.length;
        
        auto scheduler = new WorkStealingScheduler!size_t(
            workerCount,
            (size_t idx) @system {
                results[idx] = func(items[idx]);
            }
        );
        
        // Submit with priorities (could be customized per task)
        foreach (i; 0 .. items.length)
        {
            // Example: first 10% get high priority (critical path)
            immutable priority = i < items.length / 10 ? Priority.High : config.basePriority;
            scheduler.submit(i, priority);
        }
        
        scheduler.waitAll();
        scheduler.shutdown();
        
        return results;
    }
    
    /// Execute with detailed statistics collection
    @system
    static ExecutionStats executeWithStats(T, R)(T[] items, R delegate(T) @system func, 
                                                  out R[] results, ParallelConfig config)
    {
        ExecutionStats stats;
        stats.totalTasks = items.length;
        
        if (items.empty)
        {
            results = [];
            return stats;
        }
        
        results.length = items.length;
        immutable workerCount = config.maxParallelism == 0 ? totalCPUs : config.maxParallelism;
        
        auto scheduler = new WorkStealingScheduler!size_t(
            workerCount,
            (size_t idx) @system {
                results[idx] = func(items[idx]);
            }
        );
        
        // Submit tasks
        foreach (i; 0 .. items.length)
            scheduler.submit(i, config.basePriority);
        
        scheduler.waitAll();
        
        // Collect statistics
        auto schedulerStats = scheduler.getStats();
        stats.totalExecuted = schedulerStats.totalExecuted;
        stats.totalStolen = schedulerStats.totalStolen;
        stats.stealSuccessRate = schedulerStats.stealSuccessRate;
        stats.workerLoads = schedulerStats.workerLoads.dup;
        
        // Calculate load imbalance
        if (stats.workerLoads.length > 0)
        {
            import infrastructure.utils.concurrency.balancer : calculateImbalance;
            stats.loadImbalance = calculateImbalance(stats.workerLoads);
        }
        
        scheduler.shutdown();
        
        return stats;
    }
    
    /// Parallel map with work stealing (convenience function)
    static R[] mapWorkStealing(T, R)(T[] items, R delegate(T) @system func, 
                                     size_t maxParallelism = 0)
    {
        ParallelConfig config;
        config.mode = ExecutionMode.WorkStealing;
        config.maxParallelism = maxParallelism;
        return executeAdvanced(items, func, config);
    }
    
    /// Parallel map with load balancing (convenience function)
    static R[] mapLoadBalanced(T, R)(T[] items, R delegate(T) @system func,
                                     size_t maxParallelism = 0)
    {
        ParallelConfig config;
        config.mode = ExecutionMode.LoadBalanced;
        config.maxParallelism = maxParallelism;
        return executeAdvanced(items, func, config);
    }
    
    /// Parallel map with priority scheduling (convenience function)
    static R[] mapPriority(T, R)(T[] items, R delegate(T) @system func,
                                 Priority priority = Priority.Normal,
                                 size_t maxParallelism = 0)
    {
        ParallelConfig config;
        config.mode = ExecutionMode.Priority;
        config.basePriority = priority;
        config.maxParallelism = maxParallelism;
        return executeAdvanced(items, func, config);
    }
}

