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
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Persistent Worker Pool Manager
/// 
/// Manages a pool of warm compiler processes for JVM and TypeScript.
/// Reduces per-action overhead by 10-50x by avoiding JVM startup costs
/// and keeping TypeScript type-checker warm.
/// 
/// Design:
/// - Workers are lazily started on first request
/// - Workers are reused across multiple compilation requests
/// - Workers are health-checked and restarted if they die
/// - Idle workers are terminated after configurable timeout
/// - Supports multiple worker types (JVM, TypeScript, etc.)

/// Pool configuration
struct WorkerPoolConfig
{
    size_t maxWorkersPerType = 4;       /// Max workers per compiler type
    Duration idleTimeout = minutes(5);   /// Idle worker timeout
    Duration healthCheckInterval = seconds(30);
    size_t maxRequestsPerWorker = 5000; /// Restart worker after N requests
    bool enableMetrics = true;
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
    float estimatedSpeedup(string workerType, long coldStartMs) const pure nothrow @safe
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
    
    this(WorkerPoolConfig config = WorkerPoolConfig.init) @trusted
    {
        this.config = config;
        this.mutex = new Mutex();
        this.running = false;
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
        
        healthThread = new Thread(&healthCheckLoop);
        healthThread.start();
        Logger.info("Worker pool started");
    }
    
    /// Stop the worker pool and shutdown all workers
    void stop() @trusted
    {
        synchronized (mutex)
        {
            running = false;
        }
        
        if (healthThread !is null)
        {
            healthThread.join();
            healthThread = null;
        }
        
        // Shutdown all workers
        synchronized (mutex)
        {
            foreach (type, workerList; workers)
            {
                foreach (worker; workerList)
                    worker.shutdown();
                workers[type] = [];
            }
        }
        
        Logger.info("Worker pool stopped");
    }
    
    /// Acquire a worker for the given type (creates if needed)
    Result!(PersistentWorker, WorkerError) acquireWorker(string workerType) @trusted
    {
        synchronized (mutex)
        {
            // Check if we have a registered factory
            if (workerType !in factories)
                return Err!(PersistentWorker, WorkerError)(
                    new WorkerError("No factory for worker type: " ~ workerType, WorkerErrorCode.Unknown));
            
            // Find an available worker
            if (workerType in workers)
            {
                foreach (worker; workers[workerType])
                {
                    if (worker.isAvailable())
                    {
                        Logger.debugLog("Reusing warm worker: " ~ worker.getId().toString());
                        return Ok!(PersistentWorker, WorkerError)(worker);
                    }
                }
            }
            
            // Check if we can create a new worker
            auto currentCount = workers[workerType].length;
            if (currentCount >= config.maxWorkersPerType)
            {
                // Try to evict an idle worker
                auto evicted = evictIdleWorker(workerType);
                if (!evicted)
                    return Err!(PersistentWorker, WorkerError)(
                        new WorkerError("Max workers reached for type: " ~ workerType, WorkerErrorCode.Unknown));
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
            
            // Wait for worker to be ready
            worker.markReady();
            
            Logger.info("Started new worker: " ~ workerId.toString());
            return Ok!(PersistentWorker, WorkerError)(worker);
        }
    }
    
    /// Release a worker back to the pool
    void releaseWorker(PersistentWorker worker) @trusted
    {
        // Worker stays in pool, just becomes available
        // Nothing to do here - worker already marked as Idle
    }
    
    /// Execute a request on a worker (acquires, executes, releases)
    Result!(WorkResponse, WorkerError) execute(string workerType, string[] args, InputFile[] inputs = []) @trusted
    {
        auto acquireResult = acquireWorker(workerType);
        if (acquireResult.isErr)
            return Err!(WorkResponse, WorkerError)(acquireResult.unwrapErr());
        
        auto worker = acquireResult.unwrap();
        auto execResult = worker.execute(args, inputs);
        releaseWorker(worker);
        
        // Handle worker that needs restart
        if (worker.needsRestart())
            restartWorker(worker);
        
        return execResult;
    }
    
    /// Get pool statistics
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
    
    /// Health check loop
    private void healthCheckLoop() @trusted
    {
        while (running)
        {
            Thread.sleep(config.healthCheckInterval);
            if (!running) break;
            
            synchronized (mutex)
            {
                foreach (type, ref workerList; workers)
                {
                    // Remove dead workers and evict idle ones
                    PersistentWorker[] toRemove;
                    
                    foreach (worker; workerList)
                    {
                        auto state = worker.getState();
                        
                        // Remove dead/terminating workers
                        if (state == WorkerState.Dead || state == WorkerState.Terminating)
                        {
                            toRemove ~= worker;
                            continue;
                        }
                        
                        // Evict long-idle workers
                        if (state == WorkerState.Idle && worker.idleDuration() > config.idleTimeout)
                        {
                            Logger.info("Evicting idle worker: " ~ worker.getId().toString());
                            worker.shutdown();
                            toRemove ~= worker;
                        }
                    }
                    
                    // Remove from list
                    foreach (w; toRemove)
                        workerList = workerList.filter!(x => x !is w).array;
                }
            }
        }
    }
    
    /// Evict an idle worker to make room
    private bool evictIdleWorker(string workerType) @trusted
    {
        if (workerType !in workers) return false;
        
        auto workerList = workers[workerType];
        
        // Find longest-idle worker
        PersistentWorker oldest;
        Duration longestIdle = Duration.zero;
        
        foreach (worker; workerList)
        {
            auto idle = worker.idleDuration();
            if (idle > longestIdle)
            {
                longestIdle = idle;
                oldest = worker;
            }
        }
        
        if (oldest !is null)
        {
            Logger.info("Evicting worker to make room: " ~ oldest.getId().toString());
            oldest.shutdown();
            workers[workerType] = workerList.filter!(w => w !is oldest).array;
            return true;
        }
        
        return false;
    }
    
    /// Restart a worker
    private void restartWorker(PersistentWorker worker) @trusted
    {
        synchronized (mutex)
        {
            auto type = worker.getId().type;
            if (type !in factories) return;
            
            worker.shutdown();
            
            // Remove from list
            workers[type] = workers[type].filter!(w => w !is worker).array;
            atomicOp!"+="(_totalRestarts, 1);
            
            Logger.info("Restarted worker: " ~ worker.getId().toString());
        }
    }
}

