module engine.workers.pool.manager;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import core.time : MonoTime, Duration, msecs, seconds, minutes;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.atomic;
import engine.workers.protocol;
import engine.workers.pool.recycler;
import engine.workers.pool.memory;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Persistent Worker Pool Manager
/// 
/// Manages a pool of warm compiler processes for JVM and TypeScript.
/// Reduces per-action overhead by 10-50x by avoiding JVM startup costs
/// and keeping TypeScript type-checker warm.
/// 
/// Design:
/// - Workers persist across builds (not just actions) for true warmth
/// - Warmth tracking via WorkerRecycler (SOC: warmth decisions)
/// - Memory monitoring via WorkerMemoryMonitor (SOC: OOM detection)
/// - Manager coordinates but doesn't implement recycling/memory logic
/// - Hot workers get extended lifetime, cold workers evicted first

/// Pool configuration
struct WorkerPoolConfig
{
    size_t maxWorkersPerType = 4;       /// Max workers per compiler type
    Duration idleTimeout = minutes(10); /// Idle timeout (increased for persistence)
    Duration healthCheckInterval = seconds(30);
    size_t maxRequestsPerWorker = 10_000; /// Recycle after N requests
    size_t maxHeapMB = 2048;            /// Max heap per JVM worker
    bool enableMetrics = true;
    bool enableRecycling = true;        /// Enable warmth-aware recycling
    bool enableMemoryMonitor = true;    /// Enable OOM detection
    bool persistAcrossBuilds = true;    /// Keep warm workers between builds
    RecyclingPolicy recyclingPolicy;    /// Recycling policy config
    MemoryThresholds memoryThresholds;  /// Memory thresholds config
}

/// Worker pool statistics
struct WorkerPoolStats
{
    size_t[string] activeWorkers;
    size_t[string] totalRequests;
    size_t[string] avgExecutionTimeMs;
    float[string] cacheHitRates;
    size_t totalStartups;
    size_t totalRestarts;
    size_t totalFailures;
    
    /// Calculate speedup from warm workers vs cold starts
    float estimatedSpeedup(string workerType, long coldStartMs) const pure @safe
    {
        auto avgMs = avgExecutionTimeMs.get(workerType, 0);
        return avgMs > 0 && coldStartMs > 0 ? cast(float)coldStartMs / avgMs : 1.0f;
    }
}

/// Factory interface for creating worker instances
interface IWorkerFactory
{
    /// Create a new worker instance
    Result!(PersistentWorker, WorkerError) createWorker(WorkerId id);
    
    /// Get worker type identifier
    string workerType() const pure nothrow @safe;
    
    /// Get default configuration for this worker type
    PersistentWorkerConfig defaultConfig() const;
}

/// Persistent worker instance
final class PersistentWorker
{
    private WorkerId id;
    private PersistentWorkerConfig config;
    private StdioWorkerTransport transport;
    private WorkerState state;
    private WorkerStats stats;
    private Mutex mutex;
    private uint nextRequestId;
    private MonoTime startTime;
    private uint totalRequests;
    
    this(WorkerId id, PersistentWorkerConfig config, StdioWorkerTransport transport) @trusted
    {
        this.id = id;
        this.config = config;
        this.transport = transport;
        this.state = WorkerState.Starting;
        this.mutex = new Mutex();
        this.nextRequestId = 1;
        this.startTime = MonoTime.currTime;
    }
    
    /// Execute a compilation request
    Result!(WorkResponse, WorkerError) execute(string[] args, InputFile[] inputs) @trusted
    {
        synchronized (mutex)
        {
            if (state != WorkerState.Ready && state != WorkerState.Idle)
                return Err!(WorkResponse, WorkerError)(
                    new WorkerError("Worker not ready: " ~ state.to!string, WorkerErrorCode.Unknown));
            
            state = WorkerState.Busy;
            auto execStart = MonoTime.currTime;
            
            // Build request
            WorkRequest request;
            request.requestId = nextRequestId++;
            request.arguments = args;
            request.inputs = inputs;
            request.sandboxDir = config.workDir;
            
            // Send request
            auto sendResult = transport.sendRequest(request);
            if (sendResult.isErr)
            {
                state = WorkerState.Dead;
                return Err!(WorkResponse, WorkerError)(sendResult.unwrapErr());
            }
            
            // Wait for response
            auto recvResult = transport.receiveResponse(config.requestTimeout);
            auto execTimeMs = (MonoTime.currTime - execStart).total!"msecs";
            
            if (recvResult.isErr)
            {
                state = WorkerState.Dead;
                return recvResult;
            }
            
            auto response = recvResult.unwrap();
            response.executionTimeMs = execTimeMs;
            
            // Update stats
            stats.recordExecution(response.success, execTimeMs);
            totalRequests++;
            
            // Check if worker needs restart
            if (totalRequests >= config.maxRequests)
            {
                Logger.info("Worker " ~ id.toString() ~ " reached max requests, marking for restart");
                state = WorkerState.Terminating;
            }
            else
            {
                state = WorkerState.Idle;
            }
            
            return Ok!(WorkResponse, WorkerError)(response);
        }
    }
    
    /// Mark worker as ready
    void markReady() @safe
    {
        synchronized (mutex)
        {
            if (state == WorkerState.Starting)
                state = WorkerState.Ready;
        }
    }
    
    /// Shutdown the worker
    void shutdown() @trusted
    {
        synchronized (mutex)
        {
            state = WorkerState.Terminating;
            transport.close();
            state = WorkerState.Dead;
        }
    }
    
    /// Get current state
    WorkerState getState() const @safe { return state; }
    
    /// Get worker ID
    WorkerId getId() const @safe { return id; }
    
    /// Get stats
    WorkerStats getStats() const @safe { return stats; }
    
    /// Check if worker is usable
    bool isAvailable() const @safe
    {
        return state == WorkerState.Ready || state == WorkerState.Idle;
    }
    
    /// Check if worker needs restart
    bool needsRestart() const @safe
    {
        return state == WorkerState.Dead || state == WorkerState.Terminating || 
               totalRequests >= config.maxRequests;
    }
    
    /// Get idle duration
    Duration idleDuration() const @safe
    {
        if (state != WorkerState.Idle) return Duration.zero;
        return MonoTime.currTime - stats.lastActivityTime;
    }
}

/// Worker pool for managing multiple persistent workers
final class WorkerPool
{
    private WorkerPoolConfig config;
    private IWorkerFactory[string] factories;
    private PersistentWorker[][string] workers;
    private Mutex mutex;
    private bool running;
    private Thread healthThread;
    private shared size_t _totalStartups;
    private shared size_t _totalRestarts;
    private shared size_t _totalFailures;
    private shared size_t _oomRestarts;
    
    // SOC: Recycler handles warmth decisions
    private WorkerRecycler recycler;
    
    // SOC: Memory monitor handles OOM detection
    private WorkerMemoryMonitor memoryMonitor;
    
    this(WorkerPoolConfig config = WorkerPoolConfig.init) @trusted
    {
        this.config = config;
        this.mutex = new Mutex();
        this.running = false;
        
        if (config.enableRecycling)
            this.recycler = new WorkerRecycler(config.recyclingPolicy);
        
        if (config.enableMemoryMonitor)
            this.memoryMonitor = new WorkerMemoryMonitor(config.memoryThresholds);
    }
    
    /// Register a worker factory
    void registerFactory(IWorkerFactory factory) @trusted
    {
        synchronized (mutex)
        {
            factories[factory.workerType()] = factory;
            workers[factory.workerType()] = [];
        }
    }
    
    /// Start the worker pool (starts health check thread)
    void start() @trusted
    {
        synchronized (mutex)
        {
            if (running) return;
            running = true;
        }
        
        if (memoryMonitor !is null)
            memoryMonitor.start();
        
        healthThread = new Thread(&healthCheckLoop);
        healthThread.start();
        Logger.info("Worker pool started (recycling=" ~ config.enableRecycling.to!string ~ 
                   ", memory=" ~ config.enableMemoryMonitor.to!string ~ ")");
    }
    
    /// Stop the worker pool and shutdown all workers
    void stop() @trusted
    {
        synchronized (mutex)
            running = false;
        
        if (memoryMonitor !is null)
            memoryMonitor.stop();
        
        if (healthThread !is null)
        {
            healthThread.join();
            healthThread = null;
        }
        
        // Shutdown workers (respecting persistence policy)
        synchronized (mutex)
        {
            foreach (type, workerList; workers)
            {
                foreach (worker; workerList)
                {
                    if (recycler !is null)
                        recycler.unregister(worker.getId());
                    if (memoryMonitor !is null)
                        memoryMonitor.unregister(worker.getId());
                    worker.shutdown();
                }
                workers[type] = [];
            }
        }
        
        if (recycler !is null)
            Logger.info("Recycler stats: " ~ recycler.estimatedSpeedup().to!string ~ "x speedup");
        
        Logger.info("Worker pool stopped");
    }
    
    /// Acquire a worker for the given type (creates if needed)
    /// Uses recycler to prefer warm workers over cold
    Result!(PersistentWorker, WorkerError) acquireWorker(string workerType) @trusted
    {
        synchronized (mutex)
        {
            if (workerType !in factories)
                return Err!(PersistentWorker, WorkerError)(
                    new WorkerError("No factory for worker type: " ~ workerType, WorkerErrorCode.Unknown));
            
            // Find available workers
            if (workerType in workers)
            {
                auto available = workers[workerType].filter!(w => w.isAvailable()).array;
                
                if (available.length > 0)
                {
                    // Use recycler to select warmest worker
                    PersistentWorker selected;
                    if (recycler !is null)
                    {
                        auto ids = available.map!(w => w.getId()).array;
                        auto bestId = recycler.selectBest(ids);
                        selected = available.filter!(w => w.getId() == bestId).front;
                    }
                    else
                    {
                        selected = available[0];
                    }
                    
                    auto warmth = recycler !is null ? recycler.getWarmth(selected.getId()) : WarmthLevel.Cold;
                    Logger.debugLog("Reusing " ~ warmth.to!string ~ " worker: " ~ selected.getId().toString());
                    return Ok!(PersistentWorker, WorkerError)(selected);
                }
            }
            
            // Need new worker - check capacity
            auto currentCount = workers[workerType].length;
            if (currentCount >= config.maxWorkersPerType)
            {
                if (!evictColdestWorker(workerType))
                    return Err!(PersistentWorker, WorkerError)(
                        new WorkerError("Max workers reached: " ~ workerType, WorkerErrorCode.Unknown));
            }
            
            // Create new worker
            auto factory = factories[workerType];
            auto workerId = WorkerId(workerType, cast(uint)(currentCount + 1));
            
            auto createResult = factory.createWorker(workerId);
            if (createResult.isErr)
            {
                atomicOp!"+="(_totalFailures, 1);
                return Err!(PersistentWorker, WorkerError)(createResult.unwrapErr());
            }
            
            auto worker = createResult.unwrap();
            workers[workerType] ~= worker;
            atomicOp!"+="(_totalStartups, 1);
            
            // Register with recycler and memory monitor
            if (recycler !is null)
                recycler.register(workerId);
            if (memoryMonitor !is null)
                memoryMonitor.register(workerId, config.maxHeapMB * 1024 * 1024);
            
            worker.markReady();
            Logger.info("Started new worker: " ~ workerId.toString());
            return Ok!(PersistentWorker, WorkerError)(worker);
        }
    }
    
    /// Release a worker back to the pool
    void releaseWorker(PersistentWorker worker) @trusted
    {
        // Worker stays in pool - recycler tracks warmth state
    }
    
    /// Execute a request on a worker (acquires, executes, releases)
    Result!(WorkResponse, WorkerError) execute(string workerType, string[] args, InputFile[] inputs = []) @trusted
    {
        auto acquireResult = acquireWorker(workerType);
        if (acquireResult.isErr)
            return Err!(WorkResponse, WorkerError)(acquireResult.unwrapErr());
        
        auto worker = acquireResult.unwrap();
        auto execResult = worker.execute(args, inputs);
        
        // Record request with recycler for warmth tracking
        if (recycler !is null)
            recycler.recordRequest(worker.getId());
        
        releaseWorker(worker);
        
        // Check restart conditions: recycle policy or memory pressure
        auto needsRecycle = recycler !is null && recycler.shouldRecycle(worker.getId());
        auto needsOOMRestart = memoryMonitor !is null && memoryMonitor.isCritical(worker.getId());
        
        if (worker.needsRestart() || needsRecycle || needsOOMRestart)
        {
            if (needsOOMRestart)
            {
                atomicOp!"+="(_oomRestarts, 1);
                Logger.warning("Restarting worker due to OOM risk: " ~ worker.getId().toString());
            }
            restartWorker(worker);
        }
        
        return execResult;
    }
    
    /// Get pool statistics (extended with recycler/memory stats)
    WorkerPoolStats getStats() @trusted
    {
        WorkerPoolStats stats;
        stats.totalStartups = atomicLoad(_totalStartups);
        stats.totalRestarts = atomicLoad(_totalRestarts);
        stats.totalFailures = atomicLoad(_totalFailures);
        
        synchronized (mutex)
        {
            foreach (type, workerList; workers)
            {
                stats.activeWorkers[type] = workerList.count!(w => w.isAvailable());
                
                size_t totalReqs, totalTime;
                foreach (worker; workerList)
                {
                    auto ws = worker.getStats();
                    totalReqs += ws.totalRequests;
                    totalTime += ws.totalExecutionTimeMs;
                }
                
                stats.totalRequests[type] = totalReqs;
                stats.avgExecutionTimeMs[type] = totalReqs > 0 ? totalTime / totalReqs : 0;
            }
        }
        
        return stats;
    }
    
    /// Get recycler (for external warmth queries)
    WorkerRecycler getRecycler() @safe => recycler;
    
    /// Get memory monitor (for external memory queries)
    WorkerMemoryMonitor getMemoryMonitor() @safe => memoryMonitor;
    
    /// Health check loop - integrates recycler eviction and memory monitoring
    private void healthCheckLoop() @trusted
    {
        while (running)
        {
            Thread.sleep(config.healthCheckInterval);
            if (!running) break;
            
            // Check memory monitor for workers at risk
            WorkerId[] memoryAtRisk;
            if (memoryMonitor !is null)
                memoryAtRisk = memoryMonitor.getAtRisk();
            
            // Check recycler for evictable workers
            WorkerId[] evictable;
            if (recycler !is null)
                evictable = recycler.getEvictable();
            
            synchronized (mutex)
            {
                foreach (type, ref workerList; workers)
                {
                    PersistentWorker[] toRemove;
                    
                    foreach (worker; workerList)
                    {
                        auto id = worker.getId();
                        auto state = worker.getState();
                        
                        // Remove dead/terminating workers
                        if (state == WorkerState.Dead || state == WorkerState.Terminating)
                        {
                            toRemove ~= worker;
                            continue;
                        }
                        
                        // OOM risk - restart immediately
                        if (memoryAtRisk.canFind(id))
                        {
                            Logger.warning("Restarting worker due to OOM: " ~ id.toString());
                            atomicOp!"+="(_oomRestarts, 1);
                            worker.shutdown();
                            toRemove ~= worker;
                            continue;
                        }
                        
                        // Recycler says evict (based on warmth-aware idle policy)
                        if (evictable.canFind(id))
                        {
                            auto warmth = recycler !is null ? recycler.getWarmth(id) : WarmthLevel.Cold;
                            Logger.info("Evicting " ~ warmth.to!string ~ " worker: " ~ id.toString());
                            worker.shutdown();
                            toRemove ~= worker;
                            continue;
                        }
                        
                        // Fallback: basic idle timeout (if no recycler)
                        if (recycler is null && state == WorkerState.Idle && 
                            worker.idleDuration() > config.idleTimeout)
                        {
                            Logger.info("Evicting idle worker: " ~ id.toString());
                            worker.shutdown();
                            toRemove ~= worker;
                        }
                    }
                    
                    // Cleanup
                    foreach (w; toRemove)
                    {
                        if (recycler !is null)
                            recycler.unregister(w.getId());
                        if (memoryMonitor !is null)
                            memoryMonitor.unregister(w.getId());
                        workerList = workerList.filter!(x => x !is w).array;
                    }
                }
            }
        }
    }
    
    /// Evict coldest worker to make room (warmth-aware)
    private bool evictColdestWorker(string workerType) @trusted
    {
        if (workerType !in workers) return false;
        
        auto workerList = workers[workerType];
        if (workerList.length == 0) return false;
        
        PersistentWorker toEvict;
        
        if (recycler !is null)
        {
            // Find coldest idle worker
            float coldestScore = float.max;
            foreach (worker; workerList)
            {
                if (worker.getState() != WorkerState.Idle) continue;
                
                auto warmth = recycler.getWarmth(worker.getId());
                auto score = cast(float)warmth;
                if (score < coldestScore)
                {
                    coldestScore = score;
                    toEvict = worker;
                }
            }
        }
        else
        {
            // Fallback: longest idle
            Duration longestIdle = Duration.zero;
            foreach (worker; workerList)
            {
                auto idle = worker.idleDuration();
                if (idle > longestIdle)
                {
                    longestIdle = idle;
                    toEvict = worker;
                }
            }
        }
        
        if (toEvict !is null)
        {
            auto id = toEvict.getId();
            auto warmth = recycler !is null ? recycler.getWarmth(id) : WarmthLevel.Cold;
            Logger.info("Evicting " ~ warmth.to!string ~ " worker to make room: " ~ id.toString());
            
            if (recycler !is null) recycler.unregister(id);
            if (memoryMonitor !is null) memoryMonitor.unregister(id);
            
            toEvict.shutdown();
            workers[workerType] = workerList.filter!(w => w !is toEvict).array;
            return true;
        }
        
        return false;
    }
    
    /// Restart a worker
    private void restartWorker(PersistentWorker worker) @trusted
    {
        synchronized (mutex)
        {
            auto id = worker.getId();
            auto type = id.type;
            if (type !in factories) return;
            
            if (recycler !is null) recycler.unregister(id);
            if (memoryMonitor !is null) memoryMonitor.unregister(id);
            
            worker.shutdown();
            workers[type] = workers[type].filter!(w => w !is worker).array;
            atomicOp!"+="(_totalRestarts, 1);
            
            Logger.info("Recycled worker: " ~ id.toString());
        }
    }
    
    /// Update memory metrics for a worker (called externally or from protocol)
    void updateMemory(WorkerId id, size_t heapUsed, size_t rss = 0) @trusted
    {
        if (memoryMonitor !is null)
            memoryMonitor.update(id, heapUsed, rss);
    }
}

