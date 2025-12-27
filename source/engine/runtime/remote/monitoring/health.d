module engine.runtime.remote.monitoring.health;

import std.datetime : Duration, Clock, seconds, msecs;
import std.conv : to;
import core.atomic;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import engine.distributed.coordinator.coordinator;
import engine.runtime.remote.pool;
import infrastructure.errors;
import infrastructure.utils.logging;

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
                auto error = Errors.generic("Health monitor already running", Internal.InitializationFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build();
                return VoidBuildResult.err(error);
            }
            
            atomicStore(running, true);
            monitorThread = new Thread(&healthLoop);
            monitorThread.start();
            
            structuredLog.info("remote_service_health_monitor_started").emit();
            return Ok!BuildError();
        }
    }
    
    /// Stop health monitoring
    void stop() @trusted
    {
        atomicStore(running, false);
        
        if (monitorThread !is null)
            monitorThread.join();
        
        structuredLog.info("remote_service_health_monitor_stopped").emit();
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
                    structuredLog.debug_("health_check_").field("detail", "Health check: " ~ 
                                   "workers=" ~ poolStats.totalWorkers.to!string ~
                                   ", busy=" ~ poolStats.busyWorkers.to!string ~
                                   ", queue=" ~ coordStats.pendingActions.to!string ~
                                   ", util=" ~ (poolStats.avgUtilization * 100).to!size_t.to!string ~ "%").emit();
                }
                
                // Detect issues
                if (poolStats.totalWorkers == 0)
                {
                    structuredLog.warning("no_workers_available").emit();
                }
                
                if (coordStats.pendingActions > poolStats.totalWorkers * 10)
                {
                    structuredLog.warning("high_queue_depth_").field("detail", "High queue depth: " ~ 
                                  coordStats.pendingActions.to!string ~ " pending").emit();
                }
            }
            catch (Exception e)
            {
                structuredLog.error("health_check_failed_").field("detail", "Health check failed: " ~ e.msg).emit();
            }
            
            // Sleep in short intervals to allow fast shutdown
            auto remaining = checkInterval;
            while (remaining > Duration.zero && atomicLoad(running))
            {
                auto sleepTime = remaining > msecs(100) ? msecs(100) : remaining;
                Thread.sleep(sleepTime);
                remaining -= sleepTime;
            }
        }
    }
}

