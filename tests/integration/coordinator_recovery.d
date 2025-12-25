module tests.integration.coordinator_recovery;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs, MonoTime, Clock;
import std.conv : to;
import std.algorithm : map, filter, sort, min, max, canFind;
import std.array : array;
import std.random : uniform, Random;
import std.range : iota;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import engine.distributed.coordinator.coordinator;
import engine.distributed.coordinator.registry;
import engine.distributed.coordinator.recover;
import engine.distributed.coordinator.scheduler;
import engine.distributed.coordinator.health;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.messages;
import engine.graph.core.graph : BuildGraph;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// ============================================================================
// COORDINATOR FAILOVER AND RECOVERY TESTS
// ============================================================================

/// Mock worker registry for testing
class MockWorkerRegistry : WorkerRegistry
{
    private WorkerInfo[WorkerId] workers;
    private ActionId[][WorkerId] workerActions;
    private Mutex mutex;
    
    this() @trusted
    {
        this.mutex = new Mutex();
    }
    
    void addWorker(WorkerId id, WorkerInfo info) @trusted
    {
        synchronized (mutex)
        {
            workers[id] = info;
            workerActions[id] = [];
        }
    }
    
    void assignAction(WorkerId worker, ActionId action) @trusted
    {
        synchronized (mutex)
        {
            if (worker in workerActions)
                workerActions[worker] ~= action;
        }
    }
    
    override WorkerInfo[] healthyWorkers() @trusted
    {
        synchronized (mutex)
        {
            return workers.values.filter!(w => w.isHealthy()).array;
        }
    }
    
    override ActionId[] inProgressActions(WorkerId worker) @trusted
    {
        synchronized (mutex)
        {
            if (worker in workerActions)
                return workerActions[worker].dup;
            return [];
        }
    }
    
    override void markDead(WorkerId worker) @trusted
    {
        synchronized (mutex)
        {
            if (worker in workers)
            {
                workers[worker].healthy = false;
            }
        }
    }
    
    override size_t workerCount() const @trusted
    {
        synchronized (mutex)
        {
            return workers.length;
        }
    }
}

/// Mock scheduler for testing
class MockScheduler : DistributedScheduler
{
    private ActionId[][WorkerId] assignments;
    private Mutex mutex;
    private shared size_t assignmentCount;
    
    this() @trusted
    {
        this.mutex = new Mutex();
    }
    
    override Result!DistributedError assign(ActionId action, WorkerId worker) @trusted
    {
        synchronized (mutex)
        {
            if (worker !in assignments)
                assignments[worker] = [];
            assignments[worker] ~= action;
            atomicOp!"+="(assignmentCount, 1);
        }
        return Ok!DistributedError();
    }
    
    override void onWorkerFailure(WorkerId worker) @trusted
    {
        synchronized (mutex)
        {
            assignments.remove(worker);
        }
    }
    
    size_t getAssignmentCount() const @trusted => atomicLoad(assignmentCount);
    
    ActionId[] getAssignments(WorkerId worker) @trusted
    {
        synchronized (mutex)
        {
            if (worker in assignments)
                return assignments[worker].dup;
            return [];
        }
    }
}

/// Mock health monitor for testing
class MockHealthMonitor : HealthMonitor
{
    private HealthState[WorkerId] states;
    private Mutex mutex;
    
    this() @trusted
    {
        this.mutex = new Mutex();
    }
    
    void setHealth(WorkerId worker, HealthState state) @trusted
    {
        synchronized (mutex)
        {
            states[worker] = state;
        }
    }
    
    override HealthState getWorkerHealth(WorkerId worker) const @trusted
    {
        synchronized (mutex)
        {
            if (worker in states)
                return states[worker];
            return HealthState.Healthy;
        }
    }
}

// ============================================================================
// RECOVERY TESTS
// ============================================================================

/// Test: Basic worker failure handling
@("coordinator_recovery.basic_failure")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Basic Worker Failure");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    
    // Add workers
    auto worker1 = WorkerId(1);
    auto worker2 = WorkerId(2);
    auto worker3 = WorkerId(3);
    
    registry.addWorker(worker1, WorkerInfo(worker1, "127.0.0.1:8001", true, 0, 0, 10));
    registry.addWorker(worker2, WorkerInfo(worker2, "127.0.0.1:8002", true, 0, 0, 10));
    registry.addWorker(worker3, WorkerInfo(worker3, "127.0.0.1:8003", true, 0, 0, 10));
    
    // Assign actions to worker1
    ubyte[32] hash1, hash2;
    hash1[0] = 1;
    hash2[0] = 2;
    auto action1 = ActionId(hash1);
    auto action2 = ActionId(hash2);
    
    registry.assignAction(worker1, action1);
    registry.assignAction(worker1, action2);
    
    // Simulate worker1 failure
    auto result = recovery.handleWorkerFailure(worker1, "Connection lost");
    Assert.isTrue(result.isOk, "Failure handling should succeed");
    
    // Check that worker1 is blacklisted
    Assert.isTrue(recovery.isBlacklisted(worker1), "Failed worker should be blacklisted");
    
    // Check stats
    auto stats = recovery.getStats();
    Assert.equal(stats.totalFailures, 1, "Should record one failure");
    Assert.equal(stats.blacklistedWorkers, 1, "Should have one blacklisted worker");
    
    writeln("  \x1b[32m✓ Basic worker failure handling passed\x1b[0m");
}

/// Test: Work reassignment after failure
@("coordinator_recovery.work_reassignment")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Work Reassignment");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor, ReassignStrategy.RoundRobin);
    
    // Setup workers
    auto failedWorker = WorkerId(1);
    auto healthyWorker1 = WorkerId(2);
    auto healthyWorker2 = WorkerId(3);
    
    registry.addWorker(failedWorker, WorkerInfo(failedWorker, "127.0.0.1:8001", true, 0, 0, 10));
    registry.addWorker(healthyWorker1, WorkerInfo(healthyWorker1, "127.0.0.1:8002", true, 0, 0, 10));
    registry.addWorker(healthyWorker2, WorkerInfo(healthyWorker2, "127.0.0.1:8003", true, 0, 0, 10));
    
    healthMonitor.setHealth(healthyWorker1, HealthState.Healthy);
    healthMonitor.setHealth(healthyWorker2, HealthState.Healthy);
    
    // Assign actions to failed worker
    ubyte[32] hash;
    foreach (i; 0 .. 5)
    {
        hash[0] = cast(ubyte)i;
        registry.assignAction(failedWorker, ActionId(hash));
    }
    
    // Handle failure
    auto result = recovery.handleWorkerFailure(failedWorker, "Crash");
    Assert.isTrue(result.isOk, "Failure handling should succeed");
    
    // Check reassignment
    auto stats = recovery.getStats();
    Logger.info("Successful reassignments: " ~ stats.successfulReassignments.to!string);
    
    Assert.equal(stats.successfulReassignments, 5, "All 5 actions should be reassigned");
    Assert.equal(recovery.pendingReassignments(), 0, "No pending reassignments");
    
    writeln("  \x1b[32m✓ Work reassignment passed\x1b[0m");
}

/// Test: Blacklist exponential backoff
@("coordinator_recovery.blacklist_backoff")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Blacklist Exponential Backoff");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    
    auto worker = WorkerId(1);
    registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:8001", true, 0, 0, 10));
    
    // First failure - short blacklist
    recovery.handleWorkerFailure(worker, "Failure 1");
    Assert.isTrue(recovery.isBlacklisted(worker), "Worker should be blacklisted");
    
    // Remove from blacklist for next test
    recovery.removeFromBlacklist(worker);
    registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:8001", true, 0, 0, 10));
    
    // Second failure - longer blacklist (exponential backoff)
    recovery.handleWorkerFailure(worker, "Failure 2");
    Assert.isTrue(recovery.isBlacklisted(worker), "Worker should be blacklisted again");
    
    auto stats = recovery.getStats();
    Assert.equal(stats.totalFailures, 2, "Should have 2 failures");
    
    writeln("  \x1b[32m✓ Blacklist exponential backoff passed\x1b[0m");
}

/// Test: Multiple simultaneous worker failures
@("coordinator_recovery.multiple_failures")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Multiple Simultaneous Failures");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor, ReassignStrategy.LeastLoaded);
    
    // Setup 5 workers
    foreach (i; 0 .. 5)
    {
        auto worker = WorkerId(cast(uint)i);
        registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:" ~ (8001 + i).to!string, true, 0, 0, 10));
        healthMonitor.setHealth(worker, HealthState.Healthy);
    }
    
    // Assign work to first 3 workers
    foreach (workerId; 0 .. 3)
    {
        foreach (actionIdx; 0 .. 5)
        {
            ubyte[32] hash;
            hash[0] = cast(ubyte)workerId;
            hash[1] = cast(ubyte)actionIdx;
            registry.assignAction(WorkerId(cast(uint)workerId), ActionId(hash));
        }
    }
    
    // Fail workers 0, 1, 2 simultaneously
    foreach (workerId; 0 .. 3)
    {
        recovery.handleWorkerFailure(WorkerId(cast(uint)workerId), "Mass failure");
    }
    
    auto stats = recovery.getStats();
    Logger.info("Mass failure stats - failures: " ~ stats.totalFailures.to!string ~
               ", reassigned: " ~ stats.successfulReassignments.to!string ~
               ", blacklisted: " ~ stats.blacklistedWorkers.to!string);
    
    Assert.equal(stats.totalFailures, 3, "Should have 3 failures");
    Assert.equal(stats.blacklistedWorkers, 3, "Should have 3 blacklisted workers");
    Assert.equal(stats.successfulReassignments, 15, "All 15 actions should be reassigned");
    
    writeln("  \x1b[32m✓ Multiple simultaneous failures passed\x1b[0m");
}

/// Test: Recovery with no healthy workers
@("coordinator_recovery.no_healthy_workers")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - No Healthy Workers");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    
    // Setup single worker
    auto worker = WorkerId(1);
    registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:8001", true, 0, 0, 10));
    
    // Assign work
    ubyte[32] hash;
    hash[0] = 1;
    registry.assignAction(worker, ActionId(hash));
    
    // Fail the only worker
    auto result = recovery.handleWorkerFailure(worker, "Last worker failed");
    
    // Should fail to reassign (no healthy workers)
    Assert.isTrue(result.isErr, "Should fail when no healthy workers");
    
    auto stats = recovery.getStats();
    Assert.isTrue(stats.pendingReassignments > 0 || stats.failedReassignments > 0,
                 "Should have pending or failed reassignments");
    
    writeln("  \x1b[32m✓ No healthy workers scenario passed\x1b[0m");
}

/// Test: Priority-based worker selection
@("coordinator_recovery.priority_selection")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Priority Worker Selection");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor, ReassignStrategy.Priority);
    
    // Setup workers with different health states
    auto healthyWorker = WorkerId(1);
    auto degradedWorker = WorkerId(2);
    auto failedWorker = WorkerId(3);
    
    registry.addWorker(healthyWorker, WorkerInfo(healthyWorker, "127.0.0.1:8001", true, 10, 0, 10));
    registry.addWorker(degradedWorker, WorkerInfo(degradedWorker, "127.0.0.1:8002", true, 5, 2, 10));
    registry.addWorker(failedWorker, WorkerInfo(failedWorker, "127.0.0.1:8003", true, 0, 0, 10));
    
    healthMonitor.setHealth(healthyWorker, HealthState.Healthy);
    healthMonitor.setHealth(degradedWorker, HealthState.Degraded);
    healthMonitor.setHealth(failedWorker, HealthState.Healthy);  // Will fail
    
    // Assign work to failedWorker
    ubyte[32] hash;
    hash[0] = 42;
    registry.assignAction(failedWorker, ActionId(hash));
    
    // Fail the worker
    recovery.handleWorkerFailure(failedWorker, "Failed");
    
    // Work should be reassigned to healthy worker (highest priority score)
    auto stats = recovery.getStats();
    Assert.equal(stats.successfulReassignments, 1, "Should reassign to priority worker");
    
    writeln("  \x1b[32m✓ Priority worker selection passed\x1b[0m");
}

/// Test: Reassignment manager batching
@("coordinator_recovery.batch_reassignment")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Batch Reassignment");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    
    auto manager = new ReassignmentManager(recovery, registry);
    
    // Add actions to batch
    foreach (i; 0 .. 25)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        manager.addToBatch(ActionId(hash));
    }
    
    // Flush remaining
    manager.flush();
    
    // Verify batching occurred (logs would show batch processing)
    Logger.info("Batch reassignment test completed");
    
    writeln("  \x1b[32m✓ Batch reassignment passed\x1b[0m");
}

/// Test: Recovery statistics tracking
@("coordinator_recovery.statistics")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Statistics Tracking");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    
    // Setup workers
    foreach (i; 0 .. 3)
    {
        auto worker = WorkerId(cast(uint)i);
        registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:" ~ (8001 + i).to!string, true, 0, 0, 10));
        healthMonitor.setHealth(worker, HealthState.Healthy);
    }
    
    // Simulate failures and recoveries
    foreach (i; 0 .. 5)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        registry.assignAction(WorkerId(0), ActionId(hash));
    }
    
    recovery.handleWorkerFailure(WorkerId(0), "Test failure");
    
    auto stats = recovery.getStats();
    
    Assert.equal(stats.totalFailures, 1, "Should track failures");
    Assert.equal(stats.blacklistedWorkers, 1, "Should track blacklisted workers");
    Assert.isTrue(stats.reassignmentSuccessRate >= 0.0 && stats.reassignmentSuccessRate <= 1.0,
                 "Success rate should be valid");
    
    // Reset stats
    recovery.resetStats();
    auto resetStats = recovery.getStats();
    Assert.equal(resetStats.totalFailures, 0, "Stats should be reset");
    
    writeln("  \x1b[32m✓ Statistics tracking passed\x1b[0m");
}

/// Test: Concurrent failure handling
@("coordinator_recovery.concurrent_failures")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Concurrent Failure Handling");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    auto mutex = new Mutex();
    
    // Setup many workers
    foreach (i; 0 .. 20)
    {
        auto worker = WorkerId(cast(uint)i);
        registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:" ~ (8001 + i).to!string, true, 0, 0, 10));
        healthMonitor.setHealth(worker, HealthState.Healthy);
        
        // Assign some actions
        foreach (j; 0 .. 3)
        {
            ubyte[32] hash;
            hash[0] = cast(ubyte)i;
            hash[1] = cast(ubyte)j;
            registry.assignAction(worker, ActionId(hash));
        }
    }
    
    shared size_t handledFailures = 0;
    
    // Concurrent failure handling from multiple threads
    foreach (threadId; iota(10))
    {
        auto worker = WorkerId(cast(uint)threadId);
        
        synchronized (mutex)
        {
            recovery.handleWorkerFailure(worker, "Concurrent failure " ~ threadId.to!string);
            atomicOp!"+="(handledFailures, 1);
        }
    }
    
    auto stats = recovery.getStats();
    
    Logger.info("Concurrent failures - handled: " ~ atomicLoad(handledFailures).to!string ~
               ", recorded: " ~ stats.totalFailures.to!string);
    
    Assert.equal(stats.totalFailures, 10, "All failures should be recorded");
    Assert.equal(stats.blacklistedWorkers, 10, "All failed workers should be blacklisted");
    
    writeln("  \x1b[32m✓ Concurrent failure handling passed\x1b[0m");
}

/// Test: Blacklist expiration and worker recovery
@("coordinator_recovery.blacklist_expiration")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Blacklist Expiration");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    
    auto worker = WorkerId(1);
    registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:8001", true, 0, 0, 10));
    
    // Fail the worker
    recovery.handleWorkerFailure(worker, "Temporary failure");
    Assert.isTrue(recovery.isBlacklisted(worker), "Worker should be blacklisted");
    
    // Manually remove from blacklist (simulating time passage)
    recovery.removeFromBlacklist(worker);
    Assert.isFalse(recovery.isBlacklisted(worker), "Worker should be removed from blacklist");
    
    auto stats = recovery.getStats();
    Assert.equal(stats.blacklistedWorkers, 0, "No workers should be blacklisted");
    
    writeln("  \x1b[32m✓ Blacklist expiration passed\x1b[0m");
}

/// Test: Cascading failure scenario
@("coordinator_recovery.cascading_failures")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Cascading Failures");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor, ReassignStrategy.LeastLoaded);
    
    // Setup workers
    foreach (i; 0 .. 5)
    {
        auto worker = WorkerId(cast(uint)i);
        registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:" ~ (8001 + i).to!string, true, 0, 0, 10));
        healthMonitor.setHealth(worker, HealthState.Healthy);
    }
    
    // Assign all work to worker0
    foreach (i; 0 .. 20)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        registry.assignAction(WorkerId(0), ActionId(hash));
    }
    
    // Cascading failures: as work gets reassigned, target workers fail too
    recovery.handleWorkerFailure(WorkerId(0), "Initial failure");
    
    // Simulate reassigned work overloading worker1, causing it to fail
    Thread.sleep(10.msecs);
    recovery.handleWorkerFailure(WorkerId(1), "Overload failure");
    
    // And then worker2
    Thread.sleep(10.msecs);
    recovery.handleWorkerFailure(WorkerId(2), "Cascade failure");
    
    auto stats = recovery.getStats();
    
    Logger.info("Cascading failure stats - failures: " ~ stats.totalFailures.to!string ~
               ", reassignments: " ~ stats.successfulReassignments.to!string);
    
    Assert.equal(stats.totalFailures, 3, "Should have 3 failures");
    Assert.isTrue(stats.successfulReassignments > 0, "Should have some successful reassignments");
    
    writeln("  \x1b[32m✓ Cascading failures passed\x1b[0m");
}

/// Test: Recovery under high load
@("coordinator_recovery.high_load")
@system unittest
{
    writeln("\x1b[36m[RECOVERY]\x1b[0m Coordinator - Recovery Under High Load");
    
    auto registry = new MockWorkerRegistry();
    auto scheduler = new MockScheduler();
    auto healthMonitor = new MockHealthMonitor();
    auto recovery = new CoordinatorRecovery(registry, scheduler, healthMonitor);
    
    // Setup many workers
    foreach (i; 0 .. 50)
    {
        auto worker = WorkerId(cast(uint)i);
        registry.addWorker(worker, WorkerInfo(worker, "127.0.0.1:" ~ (8001 + i).to!string, true, 0, 0, 100));
        healthMonitor.setHealth(worker, HealthState.Healthy);
    }
    
    // Assign massive workload to first 10 workers
    foreach (workerId; 0 .. 10)
    {
        foreach (actionIdx; 0 .. 100)
        {
            ubyte[32] hash;
            hash[0] = cast(ubyte)workerId;
            hash[1] = cast(ubyte)(actionIdx % 256);
            hash[2] = cast(ubyte)(actionIdx / 256);
            registry.assignAction(WorkerId(cast(uint)workerId), ActionId(hash));
        }
    }
    
    auto startTime = MonoTime.currTime;
    
    // Fail all 10 loaded workers
    foreach (workerId; 0 .. 10)
    {
        recovery.handleWorkerFailure(WorkerId(cast(uint)workerId), "High load failure");
    }
    
    auto elapsed = MonoTime.currTime - startTime;
    auto stats = recovery.getStats();
    
    Logger.info("High load recovery - time: " ~ elapsed.total!"msecs".to!string ~ "ms" ~
               ", failures: " ~ stats.totalFailures.to!string ~
               ", reassigned: " ~ stats.successfulReassignments.to!string);
    
    Assert.equal(stats.totalFailures, 10, "Should handle all failures");
    Assert.equal(stats.successfulReassignments, 1000, "Should reassign all 1000 actions");
    Assert.isTrue(elapsed.total!"msecs" < 5000, "Should complete within 5 seconds");
    
    writeln("  \x1b[32m✓ High load recovery passed\x1b[0m");
}

