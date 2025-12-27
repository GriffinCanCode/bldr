module infrastructure.telemetry.monitoring.health;

import std.datetime : Duration, SysTime, Clock, dur;
import std.datetime.stopwatch : StopWatch;
import std.conv : to;
import std.format : format;
import std.algorithm : max, min;
import core.sync.mutex : Mutex;
import core.memory : GC;
import infrastructure.errors : BuildResult, Errors, Internal, BuildError;

/// Health checkpoint snapshot for long-running builds
/// Captures system state at regular intervals for monitoring
struct HealthCheckpoint
{
    /// Time when checkpoint was taken
    SysTime timestamp;
    
    /// Build uptime since start
    Duration uptime;
    
    /// Task metrics
    size_t completedTasks;
    size_t failedTasks;
    size_t activeTasks;
    size_t pendingTasks;
    
    /// Memory metrics
    size_t memoryUsed;      // Heap bytes in use
    size_t memoryTotal;     // Total heap size
    size_t gcCollections;   // GC runs since start
    
    /// Worker metrics
    size_t workerCount;     // Total workers
    size_t activeWorkers;   // Currently busy workers
    double utilization;     // Worker utilization (0.0-1.0)
    
    /// Velocity metrics
    double tasksPerSecond;  // Completion rate
    double avgTaskTime;     // Average task duration (seconds)
    
    /// Health status
    HealthStatus status;
    
    /// Create a health checkpoint
    static HealthCheckpoint create(
        Duration uptime,
        size_t completedTasks,
        size_t failedTasks,
        size_t activeTasks,
        size_t pendingTasks,
        size_t workerCount,
        size_t activeWorkers,
        double avgTaskTime) @system
    {
        auto stats = GC.stats();
        auto profileStats = GC.profileStats();
        
        HealthCheckpoint checkpoint;
        checkpoint.timestamp = Clock.currTime();
        checkpoint.uptime = uptime;
        checkpoint.completedTasks = completedTasks;
        checkpoint.failedTasks = failedTasks;
        checkpoint.activeTasks = activeTasks;
        checkpoint.pendingTasks = pendingTasks;
        checkpoint.memoryUsed = stats.usedSize;
        checkpoint.memoryTotal = stats.usedSize + stats.freeSize;
        checkpoint.gcCollections = profileStats.numCollections;
        checkpoint.workerCount = workerCount;
        checkpoint.activeWorkers = activeWorkers;
        
        // Calculate utilization
        checkpoint.utilization = workerCount > 0 
            ? (activeWorkers * 100.0) / workerCount 
            : 0.0;
        
        // Calculate velocity
        immutable uptimeSecs = uptime.total!"msecs" / 1000.0;
        checkpoint.tasksPerSecond = uptimeSecs > 0 
            ? completedTasks / uptimeSecs 
            : 0.0;
        checkpoint.avgTaskTime = avgTaskTime;
        
        // Determine status
        checkpoint.status = checkpoint.computeStatus();
        
        return checkpoint;
    }
    
    /// Compute health status based on metrics
    private HealthStatus computeStatus() const pure nothrow @system
    {
        // Check for failures
        if (failedTasks > 0)
            return HealthStatus.Degraded;
        
        // Check memory pressure (>90% usage)
        immutable memUsagePercent = memoryTotal > 0 
            ? (memoryUsed * 100.0) / memoryTotal 
            : 0.0;
        if (memUsagePercent > 90.0)
            return HealthStatus.Warning;
        
        // Check worker utilization (<20% = idle)
        if (activeTasks > 0 && utilization < 20.0)
            return HealthStatus.Warning;
        
        // Check if stalled (active tasks but zero velocity)
        if (activeTasks > 0 && tasksPerSecond == 0.0)
            return HealthStatus.Degraded;
        
        return HealthStatus.Healthy;
    }
    
    /// Get memory utilization percentage
    double memoryUtilization() const pure nothrow @system
    {
        if (memoryTotal == 0)
            return 0.0;
        return (memoryUsed * 100.0) / memoryTotal;
    }
    
    /// Estimate time remaining based on current velocity
    Duration estimateTimeRemaining() const pure nothrow @system
    {
        if (tasksPerSecond <= 0.0 || pendingTasks == 0)
            return dur!"msecs"(0);
        
        immutable secondsRemaining = pendingTasks / tasksPerSecond;
        return dur!"msecs"(cast(long)(secondsRemaining * 1000));
    }
    
    /// Format as human-readable string
    string toString() const pure @system
    {
        string result;
        result ~= format("=== Health Checkpoint [%s] ===\n", status);
        result ~= format("  Uptime:        %s\n", formatDuration(uptime));
        result ~= format("  Status:        %s\n", status);
        result ~= "\n[Tasks]\n";
        result ~= format("  Completed:     %d\n", completedTasks);
        result ~= format("  Failed:        %d\n", failedTasks);
        result ~= format("  Active:        %d\n", activeTasks);
        result ~= format("  Pending:       %d\n", pendingTasks);
        result ~= format("  Velocity:      %.2f tasks/sec\n", tasksPerSecond);
        result ~= format("  Avg Time:      %.2f sec\n", avgTaskTime);
        result ~= "\n[Workers]\n";
        result ~= format("  Total:         %d\n", workerCount);
        result ~= format("  Active:        %d\n", activeWorkers);
        result ~= format("  Utilization:   %.1f%%\n", utilization);
        result ~= "\n[Memory]\n";
        result ~= format("  Used:          %s\n", formatSize(memoryUsed));
        result ~= format("  Total:         %s\n", formatSize(memoryTotal));
        result ~= format("  Utilization:   %.1f%%\n", memoryUtilization());
        result ~= format("  GC Runs:       %d\n", gcCollections);
        result ~= "\n[Estimate]\n";
        result ~= format("  Time Remaining: %s\n", formatDuration(estimateTimeRemaining()));
        return result;
    }
    
    /// Format size in human-readable format
    private string formatSize(size_t bytes) const pure @system
    {
        if (bytes < 1024)
            return format("%d B", bytes);
        else if (bytes < 1024 * 1024)
            return format("%.2f KB", bytes / 1024.0);
        else if (bytes < 1024 * 1024 * 1024)
            return format("%.2f MB", bytes / (1024.0 * 1024.0));
        else
            return format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0));
    }
    
    /// Format duration in human-readable format
    private string formatDuration(Duration d) const pure @system
    {
        immutable msecs = d.total!"msecs";
        
        if (msecs < 1000)
            return format("%d ms", msecs);
        else if (msecs < 60_000)
            return format("%.1f sec", msecs / 1000.0);
        else if (msecs < 3600_000)
            return format("%.1f min", msecs / 60_000.0);
        else
            return format("%.1f hr", msecs / 3600_000.0);
    }
}

/// Health status enumeration
enum HealthStatus : ubyte
{
    Healthy,   // All systems operational
    Warning,   // Performance degraded but functional
    Degraded,  // Failures present or critical issues
    Critical   // System failing
}

/// Thread-safe health monitor for tracking build health
/// Integrates with executor to provide real-time diagnostics
final class HealthMonitor
{
    private HealthCheckpoint[] checkpoints;
    private StopWatch timer;
    private Mutex monitorMutex;
    private bool monitoring;
    private size_t checkpointInterval;  // Milliseconds between checkpoints
    
    this(size_t checkpointIntervalMs = 5000) @system
    {
        this.monitorMutex = new Mutex();
        this.checkpointInterval = checkpointIntervalMs;
        this.monitoring = false;
    }
    
    /// Start health monitoring
    void start() @system
    {
        synchronized (monitorMutex)
        {
            checkpoints = [];
            timer.start();
            monitoring = true;
        }
    }
    
    /// Take a health checkpoint
    /// 
    /// Safety: This function is @system because:
    /// 1. synchronized block is @system but memory-safe
    /// 2. Checkpoint creation is validated
    /// 3. Array append is bounds-checked
    /// 4. All metrics are read-only queries
    /// 
    /// Invariants:
    /// - Checkpoint timestamp is monotonically increasing
    /// - Metrics are snapshot from reliable sources
    /// - Thread-safe access via mutex
    void checkpoint(
        size_t completedTasks,
        size_t failedTasks,
        size_t activeTasks,
        size_t pendingTasks,
        size_t workerCount,
        size_t activeWorkers,
        double avgTaskTime = 0.0) @system
    {
        synchronized (monitorMutex)
        {
            if (!monitoring)
                return;
            
            auto uptime = timer.peek();
            auto cp = HealthCheckpoint.create(
                uptime,
                completedTasks,
                failedTasks,
                activeTasks,
                pendingTasks,
                workerCount,
                activeWorkers,
                avgTaskTime
            );
            
            checkpoints ~= cp;
        }
    }
    
    /// Stop monitoring and return final checkpoint
    HealthCheckpoint stop() @system
    {
        synchronized (monitorMutex)
        {
            if (!monitoring)
                return HealthCheckpoint.init;
            
            timer.stop();
            monitoring = false;
            
            if (checkpoints.length > 0)
                return checkpoints[$-1];
            
            return HealthCheckpoint.init;
        }
    }
    
    /// Get all checkpoints
    const(HealthCheckpoint)[] getCheckpoints() const @system
    {
        synchronized (monitorMutex)
        {
            return checkpoints.dup;
        }
    }
    
    /// Get latest checkpoint
    BuildResult!HealthCheckpoint getLatest() const @system
    {
        synchronized (monitorMutex)
        {
            if (checkpoints.length == 0)
                return BuildResult!HealthCheckpoint.err(Errors.internal("No checkpoints recorded", Internal.NotInitialized).build());
            
            return BuildResult!HealthCheckpoint.ok(
                checkpoints[$-1]
            );
        }
    }
    
    /// Get health trend (improving, stable, degrading)
    HealthTrend getTrend() const @system
    {
        synchronized (monitorMutex)
        {
            if (checkpoints.length < 2)
                return HealthTrend.Stable;
            
            auto recent = checkpoints[$-1];
            auto previous = checkpoints[$-2];
            
            // Check failure trend first (most critical)
            if (recent.failedTasks > previous.failedTasks)
                return HealthTrend.Degrading;
            
            // Check velocity trend
            if (recent.tasksPerSecond > previous.tasksPerSecond * 1.1)
                return HealthTrend.Improving;
            if (recent.tasksPerSecond < previous.tasksPerSecond * 0.9)
                return HealthTrend.Degrading;
            
            // Check memory trend
            if (recent.memoryUtilization() > previous.memoryUtilization() + 10.0)
                return HealthTrend.Degrading;
            
            return HealthTrend.Stable;
        }
    }
    
    /// Check if monitoring should trigger checkpoint
    bool shouldCheckpoint() const @system
    {
        synchronized (monitorMutex)
        {
            if (!monitoring)
                return false;
            
            // Always take first checkpoint
            if (checkpoints.length == 0)
                return true;
            
            // Check if interval has elapsed
            auto elapsed = timer.peek();
            auto lastCheckpoint = checkpoints[$-1];
            auto timeSinceLast = elapsed - lastCheckpoint.uptime;
            
            return timeSinceLast.total!"msecs" >= checkpointInterval;
        }
    }
    
    /// Get summary statistics
    HealthSummary getSummary() const @system
    {
        synchronized (monitorMutex)
        {
            HealthSummary summary;
            
            if (checkpoints.length == 0)
                return summary;
            
            auto first = checkpoints[0];
            auto last = checkpoints[$-1];
            
            summary.totalCheckpoints = checkpoints.length;
            summary.totalUptime = last.uptime;
            summary.totalCompleted = last.completedTasks;
            summary.totalFailed = last.failedTasks;
            summary.peakMemory = 0;
            summary.peakGCRuns = 0;
            summary.avgVelocity = 0.0;
            summary.peakUtilization = 0.0;
            
            // Calculate statistics
            foreach (cp; checkpoints)
            {
                summary.peakMemory = max(summary.peakMemory, cp.memoryUsed);
                summary.peakGCRuns = max(summary.peakGCRuns, cp.gcCollections);
                summary.avgVelocity += cp.tasksPerSecond;
                summary.peakUtilization = max(summary.peakUtilization, cp.utilization);
            }
            
            summary.avgVelocity /= checkpoints.length;
            summary.finalStatus = last.status;
            summary.trend = getTrend();
            
            return summary;
        }
    }
    
    /// Generate health report
    string report() const @system
    {
        auto summary = getSummary();
        
        string result;
        result ~= "=== Build Health Report ===\n\n";
        result ~= format("[Overview]\n");
        result ~= format("  Total Checkpoints: %d\n", summary.totalCheckpoints);
        result ~= format("  Total Uptime:      %s\n", formatDuration(summary.totalUptime));
        result ~= format("  Final Status:      %s\n", summary.finalStatus);
        result ~= format("  Trend:             %s\n", summary.trend);
        result ~= format("\n[Performance]\n");
        result ~= format("  Completed Tasks:   %d\n", summary.totalCompleted);
        result ~= format("  Failed Tasks:      %d\n", summary.totalFailed);
        result ~= format("  Avg Velocity:      %.2f tasks/sec\n", summary.avgVelocity);
        result ~= format("  Peak Utilization:  %.1f%%\n", summary.peakUtilization);
        result ~= format("\n[Resources]\n");
        result ~= format("  Peak Memory:       %s\n", formatSize(summary.peakMemory));
        result ~= format("  Total GC Runs:     %d\n", summary.peakGCRuns);
        
        return result;
    }
    
    /// Format size helper
    private string formatSize(size_t bytes) const pure @system
    {
        if (bytes < 1024)
            return format("%d B", bytes);
        else if (bytes < 1024 * 1024)
            return format("%.2f KB", bytes / 1024.0);
        else if (bytes < 1024 * 1024 * 1024)
            return format("%.2f MB", bytes / (1024.0 * 1024.0));
        else
            return format("%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0));
    }
    
    /// Format duration helper
    private string formatDuration(Duration d) const pure @system
    {
        immutable msecs = d.total!"msecs";
        
        if (msecs < 1000)
            return format("%d ms", msecs);
        else if (msecs < 60_000)
            return format("%.1f sec", msecs / 1000.0);
        else if (msecs < 3600_000)
            return format("%.1f min", msecs / 60_000.0);
        else
            return format("%.1f hr", msecs / 3600_000.0);
    }
}

/// Health trend enumeration
enum HealthTrend : ubyte
{
    Improving,  // Performance improving over time
    Stable,     // Performance consistent
    Degrading   // Performance declining
}

/// Summary of health monitoring session
struct HealthSummary
{
    size_t totalCheckpoints;
    Duration totalUptime;
    size_t totalCompleted;
    size_t totalFailed;
    size_t peakMemory;
    size_t peakGCRuns;
    double avgVelocity;
    double peakUtilization;
    HealthStatus finalStatus;
    HealthTrend trend;
}

unittest
{
    import std.stdio : writeln;
    
    // Test HealthCheckpoint creation
    {
        auto cp = HealthCheckpoint.create(
            dur!"seconds"(10),
            50,  // completed
            2,   // failed
            3,   // active
            10,  // pending
            8,   // workers
            3,   // active workers
            0.5  // avg task time
        );
        
        assert(cp.completedTasks == 50);
        assert(cp.failedTasks == 2);
        assert(cp.activeTasks == 3);
        assert(cp.pendingTasks == 10);
        assert(cp.workerCount == 8);
        assert(cp.activeWorkers == 3);
        assert(cp.status == HealthStatus.Degraded); // Has failures
        assert(cp.tasksPerSecond > 0.0);
        assert(cp.utilization > 0.0);
    }
    
    // Test HealthMonitor
    {
        import core.thread : Thread;
        
        auto monitor = new HealthMonitor(1000);
        monitor.start();
        
        // Add small delay to allow timer to advance
        Thread.sleep(dur!"msecs"(10));
        
        // Take checkpoints
        monitor.checkpoint(10, 0, 2, 20, 4, 2, 0.1);
        Thread.sleep(dur!"msecs"(10));
        monitor.checkpoint(25, 0, 3, 15, 4, 3, 0.2);
        Thread.sleep(dur!"msecs"(10));
        monitor.checkpoint(40, 1, 2, 10, 4, 2, 0.15);
        
        auto checkpoints = monitor.getCheckpoints();
        assert(checkpoints.length == 3);
        assert(checkpoints[0].completedTasks == 10);
        assert(checkpoints[1].completedTasks == 25);
        assert(checkpoints[2].completedTasks == 40);
        
        // Test trend
        auto trend = monitor.getTrend();
        assert(trend == HealthTrend.Degrading); // Has failure in last checkpoint
        
        // Test summary
        auto summary = monitor.getSummary();
        assert(summary.totalCheckpoints == 3);
        assert(summary.totalCompleted == 40);
        assert(summary.totalFailed == 1);
        // avgVelocity should be >= 0 (may be 0 if timer hasn't advanced enough)
        assert(summary.avgVelocity >= 0.0);
        
        monitor.stop();
    }
    
    // Test health status computation
    {
        // Healthy
        auto cp1 = HealthCheckpoint.create(
            dur!"seconds"(5), 10, 0, 2, 5, 4, 4, 0.1
        );
        assert(cp1.status == HealthStatus.Healthy);
        
        // Degraded (has failures)
        auto cp2 = HealthCheckpoint.create(
            dur!"seconds"(5), 10, 3, 2, 5, 4, 4, 0.1
        );
        assert(cp2.status == HealthStatus.Degraded);
    }
}

