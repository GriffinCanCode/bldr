module engine.workers.health;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import core.time : Duration, MonoTime, seconds, minutes, msecs;
import core.thread : Thread;
import core.atomic;
import engine.workers.protocol;
import engine.workers.pool;
import engine.workers.pool.memory : MemoryPressure, WorkerMemory;
import engine.workers.pool.recycler : WarmthLevel;
import infrastructure.utils.logging.logger;

/// Worker Health Monitor
/// 
/// Monitors persistent worker health and handles recovery:
/// - Detects dead/unresponsive workers
/// - Memory pressure monitoring (via WorkerMemoryMonitor - SOC)
/// - Warmth-aware health assessment (via WorkerRecycler - SOC)
/// - Automatic restart on failures or OOM risk
/// - Performance degradation detection
/// - Alerting and metrics collection

/// Health status of a worker
enum WorkerHealthStatus
{
    Healthy,      /// Worker responding normally
    Degraded,     /// Worker slow but functioning
    MemoryHigh,   /// Memory pressure detected
    Unresponsive, /// Worker not responding to pings
    Dead,         /// Worker process died
    Recovered     /// Worker was restarted successfully
}

/// Health check result
struct HealthCheckResult
{
    WorkerId workerId;
    WorkerHealthStatus status;
    Duration responseTime;
    size_t memoryUsageBytes;
    MemoryPressure memoryPressure;
    WarmthLevel warmth;
    uint consecutiveFailures;
    string lastError;
    MonoTime checkTime;
    
    bool isHealthy() const pure nothrow @safe @nogc
    {
        return status == WorkerHealthStatus.Healthy || status == WorkerHealthStatus.Recovered;
    }
    
    bool isMemoryHealthy() const pure nothrow @safe @nogc
    {
        return memoryPressure <= MemoryPressure.Elevated;
    }
}

/// Health monitor configuration
struct HealthMonitorConfig
{
    Duration checkInterval = seconds(10);
    Duration pingTimeout = seconds(5);
    uint maxConsecutiveFailures = 3;
    Duration slowResponseThreshold = seconds(2);
    size_t maxMemoryBytes = 4UL * 1024 * 1024 * 1024;  // 4GB
    bool autoRestart = true;
    bool autoRestartOnOOM = true;  /// Restart workers at OOM risk
    bool enableAlerts = true;
    bool preferWarmRestart = true; /// Try to keep warm workers alive
}

/// Alert for worker health issues
struct HealthAlert
{
    WorkerId workerId;
    WorkerHealthStatus status;
    string message;
    MonoTime timestamp;
    AlertSeverity severity;
}

enum AlertSeverity
{
    Info,
    Warning,
    Error,
    Critical
}

/// Health alert callback
alias HealthAlertHandler = void delegate(HealthAlert) @safe;

/// Worker Health Monitor
final class WorkerHealthMonitor
{
    private HealthMonitorConfig config;
    private WorkerPool pool;
    private Thread monitorThread;
    private shared bool running;
    private HealthCheckResult[string] lastResults;
    private uint[string] consecutiveFailures;
    private HealthAlertHandler alertHandler;
    private shared size_t _totalHealthChecks;
    private shared size_t _totalFailures;
    private shared size_t _totalRestarts;
    
    this(WorkerPool pool, HealthMonitorConfig config = HealthMonitorConfig.init) @trusted
    {
        this.pool = pool;
        this.config = config;
    }
    
    /// Set alert handler for notifications
    void setAlertHandler(HealthAlertHandler handler) @safe
    {
        this.alertHandler = handler;
    }
    
    /// Start health monitoring
    void start() @trusted
    {
        atomicStore(running, true);
        monitorThread = new Thread(&monitorLoop);
        monitorThread.start();
        Logger.info("Worker health monitor started (interval: " ~ config.checkInterval.total!"seconds".to!string ~ "s)");
    }
    
    /// Stop health monitoring
    void stop() @trusted
    {
        atomicStore(running, false);
        if (monitorThread !is null)
        {
            monitorThread.join();
            monitorThread = null;
        }
        Logger.info("Worker health monitor stopped");
    }
    
    /// Get health status summary (includes memory and warmth stats)
    HealthSummary getSummary() @trusted
    {
        HealthSummary summary;
        
        foreach (id, result; lastResults)
        {
            summary.totalWorkers++;
            
            final switch (result.status)
            {
                case WorkerHealthStatus.Healthy:
                case WorkerHealthStatus.Recovered:
                    summary.healthyWorkers++;
                    break;
                case WorkerHealthStatus.Degraded:
                    summary.degradedWorkers++;
                    break;
                case WorkerHealthStatus.MemoryHigh:
                    summary.memoryHighWorkers++;
                    break;
                case WorkerHealthStatus.Unresponsive:
                case WorkerHealthStatus.Dead:
                    summary.unhealthyWorkers++;
                    break;
            }
            
            // Track warmth distribution
            final switch (result.warmth)
            {
                case WarmthLevel.Cold:
                case WarmthLevel.Warming:
                    summary.coldWorkers++;
                    break;
                case WarmthLevel.Warm:
                    summary.warmWorkers++;
                    break;
                case WarmthLevel.Hot:
                    summary.hotWorkers++;
                    break;
            }
            
            summary.totalResponseTimeMs += result.responseTime.total!"msecs";
        }
        
        if (summary.totalWorkers > 0)
            summary.avgResponseTimeMs = summary.totalResponseTimeMs / summary.totalWorkers;
        
        summary.totalHealthChecks = atomicLoad(_totalHealthChecks);
        summary.totalFailures = atomicLoad(_totalFailures);
        summary.totalRestarts = atomicLoad(_totalRestarts);
        
        return summary;
    }
    
    /// Get last health check result for a worker
    HealthCheckResult getLastResult(string workerId) @trusted
    {
        if (auto p = workerId in lastResults)
            return *p;
        return HealthCheckResult.init;
    }
    
    /// Main monitoring loop
    private void monitorLoop() @trusted
    {
        while (atomicLoad(running))
        {
            Thread.sleep(config.checkInterval);
            
            if (!atomicLoad(running))
                break;
            
            performHealthChecks();
        }
    }
    
    /// Perform health checks on all workers
    private void performHealthChecks() @trusted
    {
        auto poolStats = pool.getStats();
        
        // Check each active worker type
        foreach (workerType, count; poolStats.activeWorkers)
        {
            for (size_t i = 0; i < count; i++)
            {
                auto workerId = WorkerId(workerType, cast(uint)(i + 1));
                auto result = checkWorkerHealth(workerId);
                
                lastResults[workerId.toString()] = result;
                atomicOp!"+="(_totalHealthChecks, 1);
                
                // Handle unhealthy workers
                if (!result.isHealthy())
                {
                    handleUnhealthyWorker(workerId, result);
                }
                else
                {
                    // Reset consecutive failures on success
                    consecutiveFailures[workerId.toString()] = 0;
                }
            }
        }
    }
    
    /// Check health of a single worker (integrates memory monitor)
    private HealthCheckResult checkWorkerHealth(WorkerId workerId) @trusted
    {
        HealthCheckResult result;
        result.workerId = workerId;
        result.checkTime = MonoTime.currTime;
        
        // Get memory metrics from pool's memory monitor (SOC)
        auto memMonitor = pool.getMemoryMonitor();
        if (memMonitor !is null)
        {
            auto memMetrics = memMonitor.getMetrics(workerId);
            result.memoryUsageBytes = memMetrics.heapUsedBytes;
            result.memoryPressure = memMetrics.pressure;
        }
        
        // Get warmth from pool's recycler (SOC)
        auto recycler = pool.getRecycler();
        if (recycler !is null)
            result.warmth = recycler.getWarmth(workerId);
        
        auto startTime = MonoTime.currTime;
        
        // Try to execute a simple ping request
        auto pingResult = pool.execute(workerId.type, ["--version"]);
        
        result.responseTime = MonoTime.currTime - startTime;
        
        if (pingResult.isErr)
        {
            auto err = pingResult.unwrapErr();
            result.lastError = err.message();
            
            if (err.workerCode == WorkerErrorCode.ProcessDied)
                result.status = WorkerHealthStatus.Dead;
            else if (err.workerCode == WorkerErrorCode.Timeout)
                result.status = WorkerHealthStatus.Unresponsive;
            else
                result.status = WorkerHealthStatus.Degraded;
            
            return result;
        }
        
        auto response = pingResult.unwrap();
        
        // Check memory pressure first (highest priority health concern)
        if (result.memoryPressure >= MemoryPressure.High)
        {
            result.status = WorkerHealthStatus.MemoryHigh;
            result.lastError = "Memory pressure: " ~ result.memoryPressure.to!string ~ 
                              " (" ~ (result.memoryUsageBytes / 1024 / 1024).to!string ~ "MB)";
        }
        // Check response time
        else if (result.responseTime > config.slowResponseThreshold)
        {
            result.status = WorkerHealthStatus.Degraded;
            result.lastError = "Slow response: " ~ result.responseTime.total!"msecs".to!string ~ "ms";
        }
        else if (response.exitCode != 0)
        {
            result.status = WorkerHealthStatus.Degraded;
            result.lastError = "Non-zero exit: " ~ response.exitCode.to!string;
        }
        else
        {
            result.status = WorkerHealthStatus.Healthy;
        }
        
        return result;
    }
    
    /// Handle an unhealthy worker (memory-aware)
    private void handleUnhealthyWorker(WorkerId workerId, HealthCheckResult result) @trusted
    {
        auto idStr = workerId.toString();
        
        // Memory issues are handled specially - immediate restart if critical
        if (result.status == WorkerHealthStatus.MemoryHigh && config.autoRestartOnOOM)
        {
            // For warm/hot workers, try to be less aggressive
            if (config.preferWarmRestart && result.warmth >= WarmthLevel.Warm &&
                result.memoryPressure != MemoryPressure.Critical)
            {
                Logger.warning("Worker " ~ idStr ~ " has high memory but is " ~ 
                              result.warmth.to!string ~ ", deferring restart");
                sendAlert(workerId, result.status, AlertSeverity.Warning,
                         "Memory high on " ~ result.warmth.to!string ~ " worker: " ~ result.lastError);
                return;
            }
            
            Logger.warning("Worker " ~ idStr ~ " OOM risk, triggering immediate restart");
            atomicOp!"+="(_totalFailures, 1);
            sendAlert(workerId, result.status, AlertSeverity.Critical,
                     "OOM restart triggered: " ~ result.lastError);
            restartWorker(workerId);
            return;
        }
        
        // Standard failure handling
        if (idStr !in consecutiveFailures)
            consecutiveFailures[idStr] = 0;
        consecutiveFailures[idStr]++;
        
        result.consecutiveFailures = consecutiveFailures[idStr];
        atomicOp!"+="(_totalFailures, 1);
        
        // Determine alert severity
        AlertSeverity severity;
        if (result.consecutiveFailures >= config.maxConsecutiveFailures)
            severity = AlertSeverity.Critical;
        else if (result.status == WorkerHealthStatus.Dead)
            severity = AlertSeverity.Error;
        else
            severity = AlertSeverity.Warning;
        
        string msg = "Worker " ~ idStr ~ 
                    (result.consecutiveFailures > 1 ? " failed " ~ result.consecutiveFailures.to!string ~ "x: " : ": ") ~
                    result.lastError;
        
        sendAlert(workerId, result.status, severity, msg);
        
        // Auto-restart if configured and threshold exceeded
        if (config.autoRestart && result.consecutiveFailures >= config.maxConsecutiveFailures)
        {
            Logger.warning("Worker " ~ idStr ~ " exceeded failure threshold, triggering restart");
            restartWorker(workerId);
        }
    }
    
    /// Send health alert
    private void sendAlert(WorkerId workerId, WorkerHealthStatus status, 
                          AlertSeverity severity, string message) @trusted
    {
        if (!config.enableAlerts || alertHandler is null)
            return;
        
        HealthAlert alert;
        alert.workerId = workerId;
        alert.status = status;
        alert.severity = severity;
        alert.message = message;
        alert.timestamp = MonoTime.currTime;
        
        try { alertHandler(alert); }
        catch (Exception e) { Logger.error("Alert handler failed: " ~ e.msg); }
    }
    
    /// Restart a worker
    private void restartWorker(WorkerId workerId) @trusted
    {
        // Request new worker from pool (pool will handle cleanup and restart)
        auto result = pool.acquireWorker(workerId.type);
        
        if (result.isOk)
        {
            Logger.info("Successfully restarted worker: " ~ workerId.toString());
            atomicOp!"+="(_totalRestarts, 1);
            
            // Update last result
            auto idStr = workerId.toString();
            if (auto p = idStr in lastResults)
            {
                p.status = WorkerHealthStatus.Recovered;
                p.lastError = "";
            }
            
            consecutiveFailures[idStr] = 0;
            
            // Send recovery alert
            if (config.enableAlerts && alertHandler !is null)
            {
                HealthAlert alert;
                alert.workerId = workerId;
                alert.status = WorkerHealthStatus.Recovered;
                alert.severity = AlertSeverity.Info;
                alert.message = "Worker " ~ idStr ~ " successfully recovered";
                alert.timestamp = MonoTime.currTime;
                
                try { alertHandler(alert); }
                catch (Exception) {}
            }
        }
        else
        {
            Logger.error("Failed to restart worker: " ~ workerId.toString() ~ 
                        " - " ~ result.unwrapErr().message());
        }
    }
}

/// Health summary statistics
struct HealthSummary
{
    size_t totalWorkers;
    size_t healthyWorkers;
    size_t degradedWorkers;
    size_t memoryHighWorkers;
    size_t unhealthyWorkers;
    long totalResponseTimeMs;
    long avgResponseTimeMs;
    size_t totalHealthChecks;
    size_t totalFailures;
    size_t totalRestarts;
    size_t oomRestarts;
    
    // Warmth distribution
    size_t coldWorkers;
    size_t warmWorkers;
    size_t hotWorkers;
    
    /// Calculate health percentage
    float healthPercentage() const pure nothrow @safe
    {
        return totalWorkers > 0 
            ? cast(float)healthyWorkers / totalWorkers * 100 
            : 100.0f;
    }
    
    /// Check if system is healthy overall
    bool isSystemHealthy() const pure nothrow @safe
    {
        return unhealthyWorkers == 0 && memoryHighWorkers == 0 && 
               degradedWorkers <= totalWorkers / 4;
    }
    
    /// Estimated warmth benefit (higher = more JIT optimization)
    float warmthFactor() const pure nothrow @safe
    {
        if (totalWorkers == 0) return 1.0f;
        return (coldWorkers * 1.0f + warmWorkers * 10.0f + hotWorkers * 20.0f) / totalWorkers;
    }
}

/// Recovery strategy for worker failures
enum RecoveryStrategy
{
    None,           /// No automatic recovery
    Restart,        /// Restart the worker
    Failover,       /// Fail over to cold compilation
    ScaleOut        /// Start additional workers
}

/// Recovery policy configuration
struct RecoveryPolicy
{
    RecoveryStrategy primaryStrategy = RecoveryStrategy.Restart;
    RecoveryStrategy fallbackStrategy = RecoveryStrategy.Failover;
    uint maxRestartAttempts = 3;
    Duration restartBackoff = seconds(5);
    bool enableCircuitBreaker = true;
    uint circuitBreakerThreshold = 5;
    Duration circuitBreakerCooldown = minutes(1);
}

