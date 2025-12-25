# Health Checkpoints

Health checkpoints provide real-time diagnostics for long-running builds, enabling monitoring of system resources, worker utilization, and build velocity.

## Features

- **Real-time Monitoring**: Track build health during execution
- **Resource Metrics**: Memory, GC activity, worker utilization
- **Velocity Tracking**: Tasks per second, completion rate
- **Time Estimation**: Predict remaining build time
- **Trend Analysis**: Detect improving/degrading performance
- **Thread-Safe**: Concurrent checkpoint recording

---

## Quick Start

### Basic Usage

```d
import core.telemetry.health;

// Create health monitor
auto monitor = new HealthMonitor(5000); // Checkpoint every 5 seconds
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
    writeln(checkpoint); // Display health info
}

// Stop monitoring and get final checkpoint
auto final = monitor.stop();
```

### Health Status

```d
// Health status is automatically computed
enum HealthStatus {
    Healthy,   // All systems operational
    Warning,   // Performance degraded but functional
    Degraded,  // Failures present or critical issues
    Critical   // System failing
}

// Access status
writeln("Build status: ", checkpoint.status);
```

---

## Architecture

### HealthCheckpoint

Immutable snapshot of build health at a specific point in time.

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
    size_t memoryUsed;
    size_t memoryTotal;
    size_t gcCollections;
    
    // Worker metrics
    size_t workerCount;
    size_t activeWorkers;
    double utilization;      // Percentage (0-100)
    
    // Velocity metrics
    double tasksPerSecond;
    double avgTaskTime;
    
    HealthStatus status;
}
```

#### Key Methods

```d
// Memory utilization percentage
double memoryUtilization() const;

// Estimate time remaining based on velocity
Duration estimateTimeRemaining() const;

// Human-readable output
string toString() const;
```

### HealthMonitor

Thread-safe monitor that tracks health over time.

```d
final class HealthMonitor
{
    // Start monitoring
    void start();
    
    // Take checkpoint
    void checkpoint(...);
    
    // Stop and get final checkpoint
    HealthCheckpoint stop();
    
    // Get all checkpoints
    const(HealthCheckpoint)[] getCheckpoints() const;
    
    // Get latest checkpoint
    Result!(HealthCheckpoint, TelemetryError) getLatest() const;
    
    // Analyze trend
    HealthTrend getTrend() const;
    
    // Get summary
    HealthSummary getSummary() const;
    
    // Generate report
    string report() const;
}
```

---

## Integration with Executor

### Automatic Checkpointing

```d
// In BuildExecutor.execute()
auto healthMonitor = new HealthMonitor(5000);
healthMonitor.start();

// Main build loop
while (building) {
    // ... build logic ...
    
    // Automatic checkpoint if interval elapsed
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

### Event-Driven Checkpoints

```d
class HealthEventSubscriber : EventSubscriber {
    private HealthMonitor monitor;
    
    void onEvent(BuildEvent event) {
        final switch (event.type) {
            case EventType.BuildStarted:
                monitor.start();
                break;
                
            case EventType.TargetCompleted:
                // Checkpoint on significant events
                if (monitor.shouldCheckpoint()) {
                    monitor.checkpoint(...);
                }
                break;
                
            case EventType.BuildCompleted:
                auto final = monitor.stop();
                writeln(final);
                break;
        }
    }
}
```

---

## Advanced Features

### Trend Analysis

```d
enum HealthTrend {
    Improving,  // Performance improving
    Stable,     // Consistent performance
    Degrading   // Performance declining
}

auto trend = monitor.getTrend();

if (trend == HealthTrend.Degrading) {
    Logger.warning("Build performance degrading");
    // Take action: increase parallelism, check system resources
}
```

### Health Summary

```d
struct HealthSummary {
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

auto summary = monitor.getSummary();
writeln("Peak memory: ", formatSize(summary.peakMemory));
writeln("Avg velocity: ", summary.avgVelocity, " tasks/sec");
```

### Custom Checkpoint Intervals

```d
// Adaptive intervals based on build size
size_t interval = buildSize < 100 ? 10_000 : 5_000; // 10s or 5s
auto monitor = new HealthMonitor(interval);
```

---

## Use Cases

### 1. CI/CD Monitoring

```d
// Expose health endpoint for CI monitoring
auto healthMonitor = new HealthMonitor(3000);
healthMonitor.start();

// Periodically log health for CI systems
import std.datetime : Clock;
auto lastLog = Clock.currTime();

while (building) {
    if (Clock.currTime() - lastLog > dur!"seconds"(30)) {
        auto latest = healthMonitor.getLatest();
        if (latest.isOk) {
            Logger.info("Health: " ~ latest.unwrap().toString());
        }
        lastLog = Clock.currTime();
    }
}
```

### 2. Resource Exhaustion Detection

```d
auto checkpoint = monitor.getLatest().unwrap();

if (checkpoint.memoryUtilization() > 90.0) {
    Logger.warning("High memory pressure detected");
    GC.collect(); // Force collection
}

if (checkpoint.utilization < 20.0 && checkpoint.activeTasks > 0) {
    Logger.warning("Low worker utilization - possible bottleneck");
}
```

### 3. Time Estimation

```d
auto checkpoint = monitor.getLatest().unwrap();
auto remaining = checkpoint.estimateTimeRemaining();

Logger.info(format("Estimated time remaining: %s", remaining));
```

### 4. Performance Regression Detection

```d
auto trend = monitor.getTrend();
auto summary = monitor.getSummary();

if (trend == HealthTrend.Degrading) {
    Logger.warning("Performance regression detected");
    Logger.info(format("Average velocity: %.2f tasks/sec", summary.avgVelocity));
    
    // Investigate: check latest checkpoint
    auto latest = monitor.getLatest().unwrap();
    Logger.info(format("Current velocity: %.2f tasks/sec", latest.tasksPerSecond));
    Logger.info(format("Memory usage: %.1f%%", latest.memoryUtilization()));
}
```

---

## Configuration

### Environment Variables

```bash
# Health checkpoint interval (milliseconds)
export BUILDER_HEALTH_INTERVAL=5000

# Enable health monitoring
export BUILDER_HEALTH_ENABLED=1

# Health checkpoint directory
export BUILDER_HEALTH_DIR=.builder-cache/health
```

### Programmatic Configuration

```d
// Create with custom interval
auto monitor = new HealthMonitor(10_000); // 10 seconds

// Disable monitoring
auto monitor = new HealthMonitor(0); // No automatic checkpoints
```

---

## Best Practices

### 1. Choose Appropriate Intervals

```d
// Small builds (<100 targets): Less frequent
auto smallBuildMonitor = new HealthMonitor(10_000); // 10s

// Large builds (>1000 targets): More frequent
auto largeBuildMonitor = new HealthMonitor(3_000); // 3s

// Interactive builds: Very frequent
auto interactiveMonitor = new HealthMonitor(1_000); // 1s
```

### 2. Handle Checkpoint Failures Gracefully

```d
auto latestResult = monitor.getLatest();
if (latestResult.isErr) {
    Logger.debugLog("No health checkpoints yet");
    return;
}

auto checkpoint = latestResult.unwrap();
// Use checkpoint safely
```

### 3. Export Health Data

```d
// Save checkpoints for analysis
auto checkpoints = monitor.getCheckpoints();
foreach (cp; checkpoints) {
    // Export to JSON, CSV, or telemetry system
}
```

### 4. Monitor Critical Thresholds

```d
auto checkpoint = monitor.getLatest().unwrap();

// Memory threshold
if (checkpoint.memoryUtilization() > 85.0) {
    Logger.warning("Approaching memory limit");
}

// Failure threshold
if (checkpoint.failedTasks > checkpoint.completedTasks * 0.1) {
    Logger.error("High failure rate detected");
}

// Stall detection
if (checkpoint.tasksPerSecond == 0.0 && checkpoint.activeTasks > 0) {
    Logger.error("Build appears stalled");
}
```

---

## Performance Impact

- **Memory Overhead**: ~200 bytes per checkpoint
- **CPU Overhead**: <0.1% (checkpoint creation)
- **Thread Safety**: Lock-based (minimal contention)

Recommended checkpoint intervals:
- **Small builds**: 10-15 seconds
- **Medium builds**: 5-10 seconds
- **Large builds**: 3-5 seconds
- **CI/CD**: 5 seconds

---

## Testing

```d
import tests.unit.core.health;

// Run test suite
runHealthTests();
```

Test coverage includes:
- Checkpoint creation and metrics
- Health status computation
- Trend analysis
- Concurrent access
- Time estimation
- Memory tracking

---

## Examples

### Complete Example

```d
import core.telemetry.health;
import std.stdio : writeln;

void buildWithHealth()
{
    auto monitor = new HealthMonitor(5000);
    monitor.start();
    
    // Simulate build
    foreach (i; 0 .. 100)
    {
        // Build task...
        
        // Take checkpoint every 10 tasks
        if (i % 10 == 0)
        {
            monitor.checkpoint(
                i,                    // completed
                0,                    // failed
                4,                    // active
                100 - i,              // pending
                8,                    // workers
                4,                    // active workers
                0.1                   // avg time
            );
            
            // Check health
            auto latest = monitor.getLatest();
            if (latest.isOk)
            {
                auto cp = latest.unwrap();
                writeln("Status: ", cp.status);
                writeln("Progress: ", i, "/100");
                writeln("ETA: ", cp.estimateTimeRemaining());
            }
        }
    }
    
    // Final report
    writeln("\n", monitor.report());
    monitor.stop();
}
```

---

## See Also

- [Telemetry](./telemetry.md) - Build telemetry system
- [Observability](./observability.md) - Complete observability guide
- [Performance](./performance.md) - Performance optimization

---

## Future Enhancements

Potential improvements:
1. **Persistent Checkpoints**: Save to disk for cross-session analysis
2. **Anomaly Detection**: ML-based anomaly detection
3. **Health Alerts**: Webhook notifications for critical issues
4. **Dashboard Integration**: Real-time web dashboard
5. **Historical Analysis**: Compare against previous builds

