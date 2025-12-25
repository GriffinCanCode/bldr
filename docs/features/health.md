# Health Checkpoints

Health checkpoints provide diagnostics for long-running builds, tracking system resources, worker utilization, and build velocity.

## Overview

**Location**: `source/infrastructure/telemetry/monitoring/health.d`

Features:
- Real-time monitoring during build execution
- Resource metrics: memory, GC activity, worker utilization
- Velocity tracking: tasks per second, completion rate
- Time estimation: predict remaining build time
- Trend analysis: detect improving/degrading performance
- Thread-safe: concurrent checkpoint recording

## Quick Start

```d
import infrastructure.telemetry.monitoring.health;

// Create health monitor (checkpoint every 5 seconds)
auto monitor = new HealthMonitor(5000);
monitor.start();

// During build execution, take checkpoints
monitor.checkpoint(
    completedTasks: 50,
    failedTasks: 2,
    activeTasks: 3,
    pendingTasks: 10,
    workerCount: 8,
    activeWorkers: 3,
    avgTaskTime: 0.5
);

// Get latest health status
auto latestResult = monitor.getLatest();
if (latestResult.isOk) {
    auto checkpoint = latestResult.unwrap();
    writeln(checkpoint.toString());
}

// Stop monitoring
auto finalCheckpoint = monitor.stop();
```

## Architecture

### HealthCheckpoint

Immutable snapshot of build health at a point in time.

```d
struct HealthCheckpoint
{
    SysTime timestamp;
    Duration uptime;
    
    // Task metrics
    size_t completedTasks;
    size_t failedTasks;
    size_t activeTasks;
    size_t pendingTasks;
    
    // Memory metrics
    size_t memoryUsed;      // Heap bytes in use
    size_t memoryTotal;     // Total heap size
    size_t gcCollections;   // GC runs since start
    
    // Worker metrics
    size_t workerCount;     // Total workers
    size_t activeWorkers;   // Currently busy workers
    double utilization;     // Worker utilization (0-100%)
    
    // Velocity metrics
    double tasksPerSecond;  // Completion rate
    double avgTaskTime;     // Average task duration (seconds)
    
    HealthStatus status;
    
    // Methods
    double memoryUtilization() const;
    Duration estimateTimeRemaining() const;
    string toString() const;
}
```

### HealthStatus

```d
enum HealthStatus : ubyte
{
    Healthy,   // All systems operational
    Warning,   // Performance degraded but functional
    Degraded,  // Failures present or critical issues
    Critical   // System failing
}
```

Status is computed based on:
- Failures present → Degraded
- Memory >90% → Warning
- Worker utilization <20% with active tasks → Warning
- Zero velocity with active tasks → Degraded (stalled)

### HealthMonitor

Thread-safe monitor tracking health over time.

```d
final class HealthMonitor
{
    this(size_t checkpointIntervalMs = 5000) @system;
    
    void start() @system;
    void checkpoint(...) @system;
    HealthCheckpoint stop() @system;
    
    const(HealthCheckpoint)[] getCheckpoints() const @system;
    Result!(HealthCheckpoint, string) getLatest() const @system;
    HealthTrend getTrend() const @system;
    HealthSummary getSummary() const @system;
    bool shouldCheckpoint() const @system;
    string report() const @system;
}
```

### HealthTrend

```d
enum HealthTrend : ubyte
{
    Improving,  // Performance improving
    Stable,     // Consistent performance
    Degrading   // Performance declining
}
```

Trend is computed by comparing recent checkpoints:
- More failures → Degrading
- Velocity increasing >10% → Improving
- Velocity decreasing >10% → Degrading
- Memory utilization increasing >10% → Degrading

### HealthSummary

```d
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
```

## Integration with Build Executor

```d
// In BuildExecutor.execute()
auto healthMonitor = new HealthMonitor(5000);
healthMonitor.start();

// Main build loop
while (building) {
    // ... build logic ...
    
    // Checkpoint if interval elapsed
    if (healthMonitor.shouldCheckpoint()) {
        healthMonitor.checkpoint(
            built + cached,
            failed,
            atomicLoad(activeTasks),
            pendingTasks(),
            workerCount,
            activeWorkers(),
            avgTaskDuration()
        );
    }
}

auto finalHealth = healthMonitor.stop();
```

## Use Cases

### CI/CD Monitoring

```d
auto healthMonitor = new HealthMonitor(3000);
healthMonitor.start();

// Log health periodically for CI systems
auto lastLog = Clock.currTime();

while (building) {
    if (Clock.currTime() - lastLog > dur!"seconds"(30)) {
        auto latest = healthMonitor.getLatest();
        if (latest.isOk)
            Logger.info("Health: " ~ latest.unwrap().toString());
        lastLog = Clock.currTime();
    }
}
```

### Resource Exhaustion Detection

```d
auto checkpoint = monitor.getLatest().unwrap();

if (checkpoint.memoryUtilization() > 90.0) {
    Logger.warning("High memory pressure");
    GC.collect();
}

if (checkpoint.utilization < 20.0 && checkpoint.activeTasks > 0) {
    Logger.warning("Low worker utilization - possible bottleneck");
}
```

### Time Estimation

```d
auto checkpoint = monitor.getLatest().unwrap();
auto remaining = checkpoint.estimateTimeRemaining();
Logger.info(format("Estimated time remaining: %s", remaining));
```

### Performance Regression Detection

```d
auto trend = monitor.getTrend();
auto summary = monitor.getSummary();

if (trend == HealthTrend.Degrading) {
    Logger.warning("Performance regression detected");
    Logger.info(format("Average velocity: %.2f tasks/sec", summary.avgVelocity));
}
```

## Configuration

### Checkpoint Intervals

Choose based on build size:

| Build Size | Recommended Interval |
|------------|---------------------|
| Small (<100 targets) | 10-15 seconds |
| Medium (100-1000) | 5-10 seconds |
| Large (>1000) | 3-5 seconds |
| CI/CD | 5 seconds |
| Interactive | 1 second |

```d
// Adaptive intervals
size_t interval = buildSize < 100 ? 10_000 : 5_000;
auto monitor = new HealthMonitor(interval);

// Disable automatic checkpoints
auto monitor = new HealthMonitor(0);
```

## Best Practices

### Handle Checkpoint Failures

```d
auto latestResult = monitor.getLatest();
if (latestResult.isErr) {
    Logger.debugLog("No health checkpoints yet");
    return;
}
auto checkpoint = latestResult.unwrap();
```

### Monitor Critical Thresholds

```d
auto checkpoint = monitor.getLatest().unwrap();

// Memory threshold
if (checkpoint.memoryUtilization() > 85.0)
    Logger.warning("Approaching memory limit");

// Failure threshold
if (checkpoint.failedTasks > checkpoint.completedTasks * 0.1)
    Logger.error("High failure rate detected");

// Stall detection
if (checkpoint.tasksPerSecond == 0.0 && checkpoint.activeTasks > 0)
    Logger.error("Build appears stalled");
```

### Generate Reports

```d
// Full health report
writeln(monitor.report());

// Export checkpoints for analysis
auto checkpoints = monitor.getCheckpoints();
foreach (cp; checkpoints) {
    // Export to JSON, CSV, or telemetry system
}
```

## Performance Impact

- Memory overhead: ~200 bytes per checkpoint
- CPU overhead: <0.1% for checkpoint creation
- Thread safety: Lock-based with minimal contention

## Related Documentation

- [Telemetry](./telemetry.md) - Build telemetry system
- [Observability](./observability.md) - Complete observability guide
- [Performance](./performance.md) - Performance optimization
