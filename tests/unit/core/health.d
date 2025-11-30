module tests.unit.core.health;

import std.stdio;
import std.datetime : dur;
import infrastructure.telemetry.monitoring.health;

/// Test suite for health checkpoint system
void runHealthTests()
{
    writeln("Running Health Checkpoint Tests...");
    
    testHealthCheckpointCreation();
    testHealthStatusComputation();
    testHealthMonitorBasic();
    testHealthMonitorTrends();
    testHealthSummary();
    testTimeEstimation();
    testMemoryMetrics();
    testWorkerUtilization();
    testCheckpointInterval();
    testConcurrentAccess();
    
    writeln("✓ All Health Checkpoint Tests Passed!");
}

void testHealthCheckpointCreation()
{
    // Basic checkpoint creation
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
    assert(cp.uptime == dur!"seconds"(10));
    assert(cp.avgTaskTime == 0.5);
    
    // Verify computed metrics
    assert(cp.utilization > 0.0);
    assert(cp.tasksPerSecond > 0.0);
    assert(cp.memoryUsed > 0);
    assert(cp.memoryTotal > 0);
    
    writeln("  ✓ Health checkpoint creation");
}

void testHealthStatusComputation()
{
    // Healthy status
    auto healthy = HealthCheckpoint.create(
        dur!"seconds"(5), 10, 0, 2, 5, 4, 4, 0.1
    );
    assert(healthy.status == HealthStatus.Healthy);
    
    // Degraded status (has failures)
    auto degraded = HealthCheckpoint.create(
        dur!"seconds"(5), 10, 3, 2, 5, 4, 4, 0.1
    );
    assert(degraded.status == HealthStatus.Degraded);
    
    // Warning status (low utilization)
    auto warning = HealthCheckpoint.create(
        dur!"seconds"(5), 10, 0, 1, 5, 10, 1, 0.1
    );
    // Utilization is 10% which is < 20%
    assert(warning.status == HealthStatus.Warning);
    
    writeln("  ✓ Health status computation");
}

void testHealthMonitorBasic()
{
    auto monitor = new HealthMonitor(1000);
    
    // Start monitoring
    monitor.start();
    
    // Take multiple checkpoints
    monitor.checkpoint(10, 0, 2, 20, 4, 2, 0.1);
    monitor.checkpoint(25, 0, 3, 15, 4, 3, 0.2);
    monitor.checkpoint(40, 0, 2, 10, 4, 2, 0.15);
    
    // Verify checkpoints recorded
    auto checkpoints = monitor.getCheckpoints();
    assert(checkpoints.length == 3);
    assert(checkpoints[0].completedTasks == 10);
    assert(checkpoints[1].completedTasks == 25);
    assert(checkpoints[2].completedTasks == 40);
    
    // Verify monotonically increasing timestamps
    assert(checkpoints[0].timestamp <= checkpoints[1].timestamp);
    assert(checkpoints[1].timestamp <= checkpoints[2].timestamp);
    
    // Get latest
    auto latestResult = monitor.getLatest();
    assert(latestResult.isOk);
    auto latest = latestResult.unwrap();
    assert(latest.completedTasks == 40);
    
    // Stop monitoring
    auto finalCheckpoint = monitor.stop();
    assert(finalCheckpoint.completedTasks == 40);
    
    writeln("  ✓ Health monitor basic operations");
}

void testHealthMonitorTrends()
{
    auto monitor = new HealthMonitor(1000);
    monitor.start();
    
    // Improving trend (increasing velocity)
    monitor.checkpoint(10, 0, 2, 20, 4, 2, 0.1);
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(10.msecs); // Small delay to ensure different velocity
    monitor.checkpoint(30, 0, 3, 10, 4, 3, 0.2);
    
    auto trend = monitor.getTrend();
    assert(trend == HealthTrend.Improving || trend == HealthTrend.Stable);
    
    // Degrading trend (add failures)
    monitor.checkpoint(45, 5, 2, 5, 4, 2, 0.15);
    trend = monitor.getTrend();
    assert(trend == HealthTrend.Degrading);
    
    monitor.stop();
    
    writeln("  ✓ Health monitor trends");
}

void testHealthSummary()
{
    auto monitor = new HealthMonitor(1000);
    monitor.start();
    
    // Simulate build progression
    monitor.checkpoint(10, 0, 2, 30, 4, 2, 0.1);
    monitor.checkpoint(25, 0, 3, 15, 4, 3, 0.2);
    monitor.checkpoint(40, 1, 2, 10, 4, 2, 0.15);
    
    auto summary = monitor.getSummary();
    
    assert(summary.totalCheckpoints == 3);
    assert(summary.totalCompleted == 40);
    assert(summary.totalFailed == 1);
    assert(summary.avgVelocity > 0.0);
    assert(summary.peakMemory > 0);
    assert(summary.peakUtilization > 0.0);
    assert(summary.finalStatus == HealthStatus.Degraded); // Has failure
    
    monitor.stop();
    
    writeln("  ✓ Health summary statistics");
}

void testTimeEstimation()
{
    auto cp = HealthCheckpoint.create(
        dur!"seconds"(10),
        50,   // completed
        0,    // failed
        5,    // active
        25,   // pending (25 tasks left)
        8,    // workers
        5,    // active workers
        0.2   // avg task time
    );
    
    // Velocity is 50 tasks / 10 seconds = 5 tasks/sec
    assert(cp.tasksPerSecond == 5.0);
    
    // Estimate: 25 pending / 5 tasks/sec = 5 seconds
    auto estimate = cp.estimateTimeRemaining();
    assert(estimate.total!"seconds" == 5);
    
    // Test zero velocity edge case
    auto cpZero = HealthCheckpoint.create(
        dur!"seconds"(1), 0, 0, 0, 10, 4, 0, 0.0
    );
    assert(cpZero.estimateTimeRemaining().total!"msecs" == 0);
    
    writeln("  ✓ Time estimation");
}

void testMemoryMetrics()
{
    auto cp = HealthCheckpoint.create(
        dur!"seconds"(5), 10, 0, 2, 5, 4, 2, 0.1
    );
    
    // Memory metrics should be captured
    assert(cp.memoryUsed > 0);
    assert(cp.memoryTotal > 0);
    assert(cp.memoryTotal >= cp.memoryUsed);
    assert(cp.gcCollections >= 0);
    
    // Utilization should be valid percentage
    auto util = cp.memoryUtilization();
    assert(util >= 0.0 && util <= 100.0);
    
    writeln("  ✓ Memory metrics");
}

void testWorkerUtilization()
{
    // Full utilization
    auto cpFull = HealthCheckpoint.create(
        dur!"seconds"(5), 10, 0, 4, 10, 4, 4, 0.1
    );
    assert(cpFull.utilization == 100.0);
    
    // Half utilization
    auto cpHalf = HealthCheckpoint.create(
        dur!"seconds"(5), 10, 0, 2, 10, 4, 2, 0.1
    );
    assert(cpHalf.utilization == 50.0);
    
    // Zero workers edge case
    auto cpZero = HealthCheckpoint.create(
        dur!"seconds"(5), 10, 0, 0, 10, 0, 0, 0.1
    );
    assert(cpZero.utilization == 0.0);
    
    writeln("  ✓ Worker utilization");
}

void testCheckpointInterval()
{
    auto monitor = new HealthMonitor(100); // 100ms interval
    monitor.start();
    
    // First checkpoint should always be allowed
    assert(monitor.shouldCheckpoint());
    
    monitor.checkpoint(5, 0, 2, 20, 4, 2, 0.1);
    
    // Immediately after, should not checkpoint
    assert(!monitor.shouldCheckpoint());
    
    // Wait for interval
    import core.thread : Thread;
    import core.time : msecs;
    Thread.sleep(150.msecs);
    
    // Now should checkpoint
    assert(monitor.shouldCheckpoint());
    
    monitor.stop();
    
    writeln("  ✓ Checkpoint interval");
}

void testConcurrentAccess()
{
    import core.thread : Thread;
    import core.time : msecs;
    
    auto monitor = new HealthMonitor(50);
    monitor.start();
    
    // Spawn multiple threads taking checkpoints
    Thread[] threads;
    
    foreach (i; 0 .. 5)
    {
        auto t = new Thread({
            foreach (j; 0 .. 10)
            {
                monitor.checkpoint(
                    cast(size_t)(i * 10 + j),
                    0,
                    cast(size_t)i,
                    20,
                    4,
                    cast(size_t)(i % 4),
                    0.1
                );
                Thread.sleep(10.msecs);
            }
        });
        threads ~= t;
        t.start();
    }
    
    // Wait for all threads
    foreach (t; threads)
        t.join();
    
    // Verify checkpoints recorded
    auto checkpoints = monitor.getCheckpoints();
    assert(checkpoints.length > 0);
    
    // Verify summary works
    auto summary = monitor.getSummary();
    assert(summary.totalCheckpoints > 0);
    
    monitor.stop();
    
    writeln("  ✓ Concurrent access");
}

void testHealthReport()
{
    auto monitor = new HealthMonitor(1000);
    monitor.start();
    
    monitor.checkpoint(10, 0, 2, 30, 4, 2, 0.1);
    monitor.checkpoint(25, 0, 3, 15, 4, 3, 0.2);
    monitor.checkpoint(40, 1, 2, 10, 4, 2, 0.15);
    
    auto report = monitor.report();
    
    // Verify report contains expected information
    assert(report.length > 0);
    import std.string : indexOf;
    assert(report.indexOf("Health Report") >= 0);
    assert(report.indexOf("Completed Tasks") >= 0);
    assert(report.indexOf("Failed Tasks") >= 0);
    
    monitor.stop();
    
    writeln("  ✓ Health report generation");
}
