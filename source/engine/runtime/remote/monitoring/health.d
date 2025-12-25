module engine.runtime.remote.monitoring.health;

import std.datetime : Duration, Clock, seconds;
import std.conv : to;
import core.atomic;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import engine.distributed.coordinator.coordinator;
import engine.runtime.remote.pool;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Remote execution service health monitor
/// 
/// Responsibility: Monitor service health and worker pool status
/// Separate from service lifecycle for SRP
final class RemoteServiceHealthMonitor
{
    private Coordinator coordinator;
    private WorkerPool pool;
    private Mutex mutex;
    private Thread monitorThread;
    private shared bool running;
    private Duration checkInterval;
    private bool enableMetrics;
    
    this(
        Coordinator coordinator,
        WorkerPool pool,
        Duration checkInterval = 10.seconds,
        bool enableMetrics = true
    ) @trusted
    {
        this.coordinator = coordinator;
        this.pool = pool;
        this.mutex = new Mutex();
        this.checkInterval = checkInterval;
        this.enableMetrics = enableMetrics;
        atomicStore(running, false);
    }
    
    /// Start health monitoring
    VoidBuildResult start() @trusted
    {
        synchronized (mutex)
        {
            if (atomicLoad(running))
            {
                auto error = new GenericError(
                    "Health monitor already running",
                    ErrorCode.InitializationFailed
                );
                return VoidBuildResult.err(error);
            }
            
            atomicStore(running, true);
            monitorThread = new Thread(&healthLoop);
            monitorThread.start();
            
            Logger.info("Remote service health monitor started");
            return Ok!BuildError();
        }
    }
    
    /// Stop health monitoring
    void stop() @trusted
    {
        atomicStore(running, false);
        
        if (monitorThread !is null)
            monitorThread.join();
        
        Logger.info("Remote service health monitor stopped");
    }
    
    /// Health monitoring loop
    private void healthLoop() @trusted
    {
        while (atomicLoad(running))
        {
            try
            {
                // Check coordinator health
                auto coordStats = coordinator.getStats();
                
                // Check pool health
                auto poolStats = pool.getStats();
                
                // Log health status
                if (enableMetrics)
                {
                    Logger.debugLog("Health check: " ~ 
                                   "workers=" ~ poolStats.totalWorkers.to!string ~
                                   ", busy=" ~ poolStats.busyWorkers.to!string ~
                                   ", queue=" ~ coordStats.pendingActions.to!string ~
                                   ", util=" ~ (poolStats.avgUtilization * 100).to!size_t.to!string ~ "%");
                }
                
                // Detect issues
                if (poolStats.totalWorkers == 0)
                {
                    Logger.warning("No workers available!");
                }
                
                if (coordStats.pendingActions > poolStats.totalWorkers * 10)
                {
                    Logger.warning("High queue depth: " ~ 
                                  coordStats.pendingActions.to!string ~ " pending");
                }
                
                Thread.sleep(checkInterval);
            }
            catch (Exception e)
            {
                Logger.error("Health check failed: " ~ e.msg);
                Thread.sleep(checkInterval);
            }
        }
    }
}

