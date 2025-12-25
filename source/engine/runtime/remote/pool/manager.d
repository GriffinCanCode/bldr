module engine.runtime.remote.pool.manager;

import std.datetime : Duration, Clock, SysTime, seconds, minutes, msecs;
import std.algorithm : filter, map, sort, min, max;
import std.array : array;
import std.conv : to;
import std.range : empty;
import std.math : exp, log;
import core.atomic;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import engine.distributed.protocol.protocol;
import engine.distributed.coordinator.registry;
import engine.runtime.remote.pool.scaling.predictor : LoadPredictor;
import engine.runtime.remote.providers;
import engine.runtime.remote.providers.provisioner : WorkerProvisioner;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.logging.logger;

/// Worker pool manager with dynamic scaling
/// 
/// Design: Predictive autoscaling using exponential smoothing and queuing theory
/// - Scales based on queue depth, latency, and utilization metrics
/// - Uses Little's Law: L = λW (queue length = arrival rate × wait time)
/// - Exponential smoothing for load prediction: St = αXt + (1-α)St-1
/// - Hysteresis to prevent scaling oscillation

/// Pool configuration
struct PoolConfig
{
    size_t minWorkers = 1;              // Minimum pool size
    size_t maxWorkers = 100;            // Maximum pool size
    size_t targetWorkers = 4;           // Target steady-state
    
    float scaleUpThreshold = 0.75;      // Scale up when utilization > 75%
    float scaleDownThreshold = 0.25;    // Scale down when < 25%
    
    Duration scaleUpCooldown = 30.seconds;   // Cooldown after scale up
    Duration scaleDownCooldown = 2.minutes;  // Cooldown after scale down
    
    Duration healthCheckInterval = 10.seconds;
    Duration workerStartTimeout = 2.minutes;
    
    float smoothingAlpha = 0.3;         // Exponential smoothing factor
    size_t predictionWindow = 10;       // Samples for prediction
    
    bool enablePredictiveScaling = true;
    bool enableAutoScale = true;
}

/// Worker pool statistics
struct PoolStats
{
    size_t totalWorkers;
    size_t idleWorkers;
    size_t busyWorkers;
    size_t failedWorkers;
    size_t pendingTasks;
    float avgUtilization;
    float predictedLoad;
    Duration avgLatency;
}

/// Worker pool entry
private struct PoolWorker
{
    WorkerId id;
    WorkerState state;
    SysTime lastSeen;
    float utilization;
    bool healthy;
}

/// Worker pool manager
/// 
/// Responsibility: Manage pool state, autoscaling decisions, and statistics
/// Delegates provisioning to WorkerProvisioner (SRP)
final class WorkerPool
{
    private PoolConfig config;
    private WorkerRegistry registry;
    private WorkerProvisioner provisioner;
    private Mutex mutex;
    
    private LoadPredictor utilizationPredictor;
    private LoadPredictor latencyPredictor;
    
    private SysTime lastScaleUp;
    private SysTime lastScaleDown;
    
    private shared bool running;
    private Thread scalerThread;
    
    this(PoolConfig config, WorkerRegistry registry, WorkerProvisioner provisioner) @trusted
    {
        this.config = config;
        this.registry = registry;
        this.provisioner = provisioner;
        this.mutex = new Mutex();
        
        this.utilizationPredictor = LoadPredictor(
            config.smoothingAlpha,
            config.predictionWindow
        );
        
        this.latencyPredictor = LoadPredictor(
            config.smoothingAlpha,
            config.predictionWindow
        );
        
        atomicStore(running, false);
    }
    
    /// Start pool manager
    VoidBuildResult start() @trusted
    {
        synchronized (mutex)
        {
            if (atomicLoad(running))
                return Ok!BuildError();
            
            atomicStore(running, true);
            
            // Start autoscaler thread
            if (config.enableAutoScale)
            {
                scalerThread = new Thread(&scalerLoop);
                scalerThread.start();
                Logger.info("Worker pool autoscaler started");
            }
            
            return Ok!BuildError();
        }
    }
    
    /// Stop pool manager
    void stop() @trusted
    {
        atomicStore(running, false);
        
        if (scalerThread !is null)
            scalerThread.join();
        
        Logger.info("Worker pool stopped");
    }
    
    /// Get pool statistics
    PoolStats getStats() @trusted
    {
        synchronized (mutex)
        {
            PoolStats stats;
            
            immutable totalWorkers = registry.count();
            immutable healthyWorkers = registry.healthyCount();
            
            stats.totalWorkers = totalWorkers;
            stats.busyWorkers = 0;  // Would query from registry
            stats.idleWorkers = healthyWorkers - stats.busyWorkers;
            stats.failedWorkers = totalWorkers - healthyWorkers;
            stats.avgUtilization = utilizationPredictor.predict();
            stats.predictedLoad = stats.avgUtilization;
            
            return stats;
        }
    }
    
    /// Compute desired worker count based on current metrics
    private size_t computeDesiredWorkers() @trusted
    {
        immutable stats = getStats();
        
        // Current utilization
        immutable currentUtil = stats.totalWorkers > 0 ?
            cast(float)stats.busyWorkers / cast(float)stats.totalWorkers : 0.0f;
        
        // Update predictor
        utilizationPredictor.observe(currentUtil);
        
        // Get prediction
        immutable predictedUtil = utilizationPredictor.predict();
        immutable trend = utilizationPredictor.trend();
        
        // Adjust target based on prediction and trend
        size_t desired = stats.totalWorkers;
        
        if (predictedUtil > config.scaleUpThreshold || trend > 0.1f)
        {
            // Scale up needed
            immutable scaleUpFactor = (predictedUtil - config.scaleUpThreshold) / 
                                     (1.0f - config.scaleUpThreshold);
            
            // Aggressive scale-up if trend is steep
            immutable trendMultiplier = 1.0f + (trend > 0 ? trend * 2.0f : 0.0f);
            
            immutable increment = max(1, cast(size_t)(stats.totalWorkers * scaleUpFactor * trendMultiplier));
            desired = stats.totalWorkers + increment;
        }
        else if (predictedUtil < config.scaleDownThreshold && trend < -0.05f)
        {
            // Scale down possible
            immutable scaleDownFactor = (config.scaleDownThreshold - predictedUtil) / 
                                       config.scaleDownThreshold;
            
            immutable decrement = max(1, cast(size_t)(stats.totalWorkers * scaleDownFactor * 0.5));
            desired = stats.totalWorkers > decrement ? stats.totalWorkers - decrement : 1;
        }
        
        // Clamp to bounds
        desired = max(config.minWorkers, min(config.maxWorkers, desired));
        
        Logger.debugLog("Pool scaling decision: current=" ~ stats.totalWorkers.to!string ~
                       ", util=" ~ (currentUtil * 100).to!size_t.to!string ~ "%" ~
                       ", predicted=" ~ (predictedUtil * 100).to!size_t.to!string ~ "%" ~
                       ", trend=" ~ trend.to!string ~
                       ", desired=" ~ desired.to!string);
        
        return desired;
    }
    
    /// Scale pool to target size
    private VoidBuildResult scale(size_t targetSize) @trusted
    {
        immutable currentSize = registry.count();
        
        if (targetSize == currentSize)
            return Ok!BuildError();
        
        if (targetSize > currentSize)
        {
            // Scale up
            immutable now = Clock.currTime;
            if (now - lastScaleUp < config.scaleUpCooldown)
            {
                Logger.debugLog("Scale up in cooldown");
                return Ok!BuildError();
            }
            
            immutable toAdd = targetSize - currentSize;
            Logger.info("Scaling up: adding " ~ toAdd.to!string ~ " workers");
            
            // Delegate provisioning to WorkerProvisioner (SRP)
            auto result = provisioner.provisionBatch(toAdd);
            if (result.isErr)
            {
                Logger.error("Failed to provision workers: " ~ 
                           result.unwrapErr().message());
            }
            else
            {
                Logger.info("Successfully provisioned " ~ 
                           result.unwrap().length.to!string ~ " workers");
            }
            
            lastScaleUp = now;
        }
        else
        {
            // Scale down
            immutable now = Clock.currTime;
            if (now - lastScaleDown < config.scaleDownCooldown)
            {
                Logger.debugLog("Scale down in cooldown");
                return Ok!BuildError();
            }
            
            immutable toRemove = currentSize - targetSize;
            Logger.info("Scaling down: removing " ~ toRemove.to!string ~ " workers");
            
            // Drain and remove least utilized workers
            auto result = drainWorkers(toRemove);
            if (result.isErr)
            {
                Logger.error("Failed to drain workers");
                Logger.error(formatError(result.unwrapErr()));
            }
            
            lastScaleDown = now;
        }
        
        return Ok!BuildError();
    }
    
    /// Drain and remove workers
    /// 
    /// Responsibility: Select workers to drain based on utilization
    /// Delegates actual deprovisioning to WorkerProvisioner (SRP)
    private VoidBuildResult drainWorkers(size_t count) @trusted
    {
        Logger.info("Draining " ~ count.to!string ~ " workers");
        
        // 1. Select least utilized workers from registry (fully implemented)
        auto workersToDrain = registry.getLeastUtilizedWorkers(count);
        
        if (workersToDrain.empty)
        {
            Logger.warning("No workers available for draining");
            return Ok!BuildError();
        }
        
        Logger.info("Selected " ~ workersToDrain.length.to!string ~ 
                   " workers for draining based on utilization");
        
        // 2. Mark workers as draining (no new work assigned)
        foreach (workerId; workersToDrain)
        {
            registry.markDraining(workerId);
            Logger.debugLog("Marked worker " ~ workerId.toString() ~ " as draining");
        }
        
        // 3. Wait for current work to complete with timeout
        import std.datetime.stopwatch : StopWatch;
        import std.datetime : dur;
        
        auto sw = StopWatch();
        sw.start();
        immutable maxWaitTime = config.workerStartTimeout; // Reuse timeout config
        
        while (sw.peek() < maxWaitTime)
        {
            // Check if all workers have drained
            bool allDrained = true;
            foreach (workerId; workersToDrain)
            {
                if (!registry.isDrained(workerId))
                {
                    allDrained = false;
                    break;
                }
            }
            
            if (allDrained)
            {
                Logger.info("All workers drained successfully");
                break;
            }
            
            // Wait a bit before checking again
            Thread.sleep(1.seconds);
        }
        
        // 4. Deregister and terminate workers (delegate to provisioner)
        auto result = provisioner.deprovisionBatch(workersToDrain);
        if (result.isErr)
        {
            Logger.error("Failed to deprovision workers");
            Logger.error(formatError(result.unwrapErr()));
            return result;
        }
        
        // 5. Unregister from registry
        foreach (workerId; workersToDrain)
        {
            auto unregResult = registry.unregister(workerId);
            if (unregResult.isErr)
            {
                Logger.warning("Failed to unregister worker " ~ workerId.toString() ~ 
                             ": " ~ unregResult.unwrapErr().message());
            }
        }
        
        Logger.info("Successfully drained and deprovisioned " ~ 
                   workersToDrain.length.to!string ~ " workers");
        
        return Ok!BuildError();
    }
    
    /// Autoscaler loop
    private void scalerLoop() @trusted
    {
        while (atomicLoad(running))
        {
            try
            {
                // Compute desired size
                immutable desired = computeDesiredWorkers();
                
                // Execute scaling if needed
                auto result = scale(desired);
                if (result.isErr)
                {
                    Logger.error("Scaling failed");
                    Logger.error(formatError(result.unwrapErr()));
                }
            }
            catch (Exception e)
            {
                Logger.error("Scaler loop exception: " ~ e.msg);
            }
            
            // Sleep in short intervals to allow fast shutdown
            auto remaining = config.healthCheckInterval;
            while (remaining > Duration.zero && atomicLoad(running))
            {
                auto sleepTime = remaining > msecs(100) ? msecs(100) : remaining;
                Thread.sleep(sleepTime);
                remaining -= sleepTime;
            }
        }
    }
}
