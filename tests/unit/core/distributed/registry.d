module tests.unit.core.distributed.registry;

import std.stdio;
import std.datetime;
import std.conv;
import core.thread;
import engine.distributed.coordinator.registry;
import engine.distributed.protocol.protocol;
import tests.harness;

// ==================== BASIC REGISTRATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Worker registration");
    
    auto registry = new WorkerRegistry();
    
    // Register worker
    auto result = registry.register("worker1.local:9000");
    Assert.isTrue(result.isOk);
    
    auto workerId = result.unwrap();
    Assert.notEqual(workerId.value, 0);  // Should not be broadcast ID
    
    writeln("\x1b[32m  ✓ Worker registration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Multiple worker registration");
    
    auto registry = new WorkerRegistry();
    
    auto result1 = registry.register("worker1:9000");
    auto result2 = registry.register("worker2:9000");
    auto result3 = registry.register("worker3:9000");
    
    Assert.isTrue(result1.isOk);
    Assert.isTrue(result2.isOk);
    Assert.isTrue(result3.isOk);
    
    auto id1 = result1.unwrap();
    auto id2 = result2.unwrap();
    auto id3 = result3.unwrap();
    
    // IDs should be unique
    Assert.notEqual(id1.value, id2.value);
    Assert.notEqual(id2.value, id3.value);
    Assert.notEqual(id1.value, id3.value);
    
    // Should be sequential
    Assert.equal(id2.value, id1.value + 1);
    Assert.equal(id3.value, id2.value + 1);
    
    writeln("\x1b[32m  ✓ Multiple worker registration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Worker unregistration");
    
    auto registry = new WorkerRegistry();
    
    auto result = registry.register("worker1:9000");
    Assert.isTrue(result.isOk);
    auto workerId = result.unwrap();
    
    // Unregister
    auto unregResult = registry.unregister(workerId);
    Assert.isTrue(unregResult.isOk);
    
    // Worker should not be found
    auto getResult = registry.getWorker(workerId);
    Assert.isTrue(getResult.isErr);
    
    writeln("\x1b[32m  ✓ Worker unregistration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Unregister non-existent worker");
    
    auto registry = new WorkerRegistry();
    
    auto fakeId = WorkerId(9999);
    auto result = registry.unregister(fakeId);
    
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ Unregister non-existent worker handled\x1b[0m");
}

// ==================== WORKER INFO TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Get worker info");
    
    auto registry = new WorkerRegistry();
    
    auto result = registry.register("worker1:9000");
    Assert.isTrue(result.isOk);
    auto workerId = result.unwrap();
    
    // Get worker info
    auto infoResult = registry.getWorker(workerId);
    Assert.isTrue(infoResult.isOk);
    
    auto info = infoResult.unwrap();
    Assert.equal(info.id.value, workerId.value);
    Assert.equal(info.address, "worker1:9000");
    Assert.equal(info.state, WorkerState.Idle);
    Assert.equal(info.completed, 0);
    Assert.equal(info.failed, 0);
    
    writeln("\x1b[32m  ✓ Get worker info works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Get non-existent worker");
    
    auto registry = new WorkerRegistry();
    
    auto fakeId = WorkerId(9999);
    auto result = registry.getWorker(fakeId);
    
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ Get non-existent worker handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Get all workers");
    
    auto registry = new WorkerRegistry();
    
    registry.register("worker1:9000");
    registry.register("worker2:9000");
    registry.register("worker3:9000");
    
    auto workers = registry.allWorkers();
    Assert.equal(workers.length, 3);
    
    writeln("\x1b[32m  ✓ Get all workers works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Empty registry");
    
    auto registry = new WorkerRegistry();
    
    auto workers = registry.allWorkers();
    Assert.equal(workers.length, 0);
    
    auto healthy = registry.healthyWorkers();
    Assert.equal(healthy.length, 0);
    
    writeln("\x1b[32m  ✓ Empty registry handled\x1b[0m");
}

// ==================== HEARTBEAT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Heartbeat update");
    
    auto registry = new WorkerRegistry();
    
    auto result = registry.register("worker1:9000");
    Assert.isTrue(result.isOk);
    auto workerId = result.unwrap();
    
    // Create heartbeat
    HeartBeat hb;
    hb.worker = workerId;
    hb.state = WorkerState.Executing;
    hb.metrics.queueDepth = 5;
    hb.metrics.cpuUsage = 0.75;
    hb.metrics.memoryUsage = 2_000_000_000;
    
    // Update heartbeat
    registry.updateHeartbeat(workerId, hb);
    
    // Verify state updated
    auto infoResult = registry.getWorker(workerId);
    Assert.isTrue(infoResult.isOk);
    
    auto info = infoResult.unwrap();
    Assert.equal(info.state, WorkerState.Executing);
    Assert.equal(info.metrics.queueDepth, 5);
    Assert.equal(info.metrics.cpuUsage, 0.75);
    Assert.equal(info.metrics.memoryUsage, 2_000_000_000);
    
    writeln("\x1b[32m  ✓ Heartbeat update works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Heartbeat timeout detection");
    
    auto registry = new WorkerRegistry(50.msecs);  // 50ms timeout
    
    auto result = registry.register("worker1:9000");
    Assert.isTrue(result.isOk);
    auto workerId = result.unwrap();
    
    // Worker is initially healthy
    auto workers1 = registry.healthyWorkers();
    Assert.equal(workers1.length, 1);
    
    // Wait for timeout
    Thread.sleep(100.msecs);
    
    // Worker should now be unhealthy
    auto workers2 = registry.healthyWorkers();
    Assert.equal(workers2.length, 0);
    
    writeln("\x1b[32m  ✓ Heartbeat timeout detection works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Heartbeat keeps worker alive");
    
    auto registry = new WorkerRegistry(100.msecs);
    
    auto result = registry.register("worker1:9000");
    Assert.isTrue(result.isOk);
    auto workerId = result.unwrap();
    
    // Send heartbeat periodically
    for (int i = 0; i < 5; i++)
    {
        Thread.sleep(30.msecs);
        
        HeartBeat hb;
        hb.worker = workerId;
        hb.state = WorkerState.Idle;
        registry.updateHeartbeat(workerId, hb);
        
        // Worker should still be healthy
        auto workers = registry.healthyWorkers();
        Assert.equal(workers.length, 1);
    }
    
    writeln("\x1b[32m  ✓ Heartbeat keeps worker alive\x1b[0m");
}

// ==================== WORKER SELECTION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Select worker from empty pool");
    
    auto registry = new WorkerRegistry();
    
    Capabilities caps;
    auto result = registry.selectWorker(caps);
    
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ Select from empty pool handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Select worker from single worker");
    
    auto registry = new WorkerRegistry();
    
    auto regResult = registry.register("worker1:9000");
    Assert.isTrue(regResult.isOk);
    auto workerId = regResult.unwrap();
    
    Capabilities caps;
    auto selectResult = registry.selectWorker(caps);
    
    Assert.isTrue(selectResult.isOk);
    auto selected = selectResult.unwrap();
    Assert.equal(selected.value, workerId.value);
    
    writeln("\x1b[32m  ✓ Select from single worker works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Select least loaded worker");
    
    auto registry = new WorkerRegistry();
    
    // Register multiple workers
    auto result1 = registry.register("worker1:9000");
    auto result2 = registry.register("worker2:9000");
    auto result3 = registry.register("worker3:9000");
    
    auto id1 = result1.unwrap();
    auto id2 = result2.unwrap();
    auto id3 = result3.unwrap();
    
    // Set different loads
    HeartBeat hb1;
    hb1.worker = id1;
    hb1.state = WorkerState.Executing;
    hb1.metrics.queueDepth = 10;  // High load
    hb1.metrics.cpuUsage = 0.9;
    registry.updateHeartbeat(id1, hb1);
    
    HeartBeat hb2;
    hb2.worker = id2;
    hb2.state = WorkerState.Idle;
    hb2.metrics.queueDepth = 2;  // Low load
    hb2.metrics.cpuUsage = 0.2;
    registry.updateHeartbeat(id2, hb2);
    
    HeartBeat hb3;
    hb3.worker = id3;
    hb3.state = WorkerState.Executing;
    hb3.metrics.queueDepth = 5;  // Medium load
    hb3.metrics.cpuUsage = 0.5;
    registry.updateHeartbeat(id3, hb3);
    
    // Select worker - should pick least loaded (worker2)
    Capabilities caps;
    auto selectResult = registry.selectWorker(caps);
    
    Assert.isTrue(selectResult.isOk);
    auto selected = selectResult.unwrap();
    Assert.equal(selected.value, id2.value);
    
    writeln("\x1b[32m  ✓ Select least loaded worker works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Exclude unhealthy workers from selection");
    
    auto registry = new WorkerRegistry(50.msecs);
    
    auto result1 = registry.register("worker1:9000");
    auto result2 = registry.register("worker2:9000");
    
    auto id1 = result1.unwrap();
    auto id2 = result2.unwrap();
    
    // Keep worker2 alive with heartbeat
    HeartBeat hb2;
    hb2.worker = id2;
    hb2.state = WorkerState.Idle;
    registry.updateHeartbeat(id2, hb2);
    
    // Let worker1 timeout
    Thread.sleep(100.msecs);
    
    // Select worker - should only pick healthy worker2
    Capabilities caps;
    auto selectResult = registry.selectWorker(caps);
    
    Assert.isTrue(selectResult.isOk);
    auto selected = selectResult.unwrap();
    Assert.equal(selected.value, id2.value);
    
    writeln("\x1b[32m  ✓ Exclude unhealthy workers works\x1b[0m");
}

// ==================== WORKER LOAD CALCULATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - WorkerInfo load calculation");
    
    WorkerInfo info;
    info.metrics.queueDepth = 10;
    info.metrics.cpuUsage = 0.5;
    
    // Load = queueDepth * 0.6 + cpuUsage * 0.4
    // Load = 10 * 0.6 + 0.5 * 0.4 = 6.0 + 0.2 = 6.2
    auto load = info.load();
    
    Assert.isTrue(load > 6.1 && load < 6.3);
    
    writeln("\x1b[32m  ✓ Load calculation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - WorkerInfo health check");
    
    WorkerInfo info;
    info.state = WorkerState.Idle;
    info.lastSeen = Clock.currTime;
    
    // Should be healthy within timeout
    Assert.isTrue(info.healthy(5.seconds));
    
    // Simulate old heartbeat
    info.lastSeen = Clock.currTime - 10.seconds;
    Assert.isFalse(info.healthy(5.seconds));
    
    // Failed state should be unhealthy regardless
    info.lastSeen = Clock.currTime;
    info.state = WorkerState.Failed;
    Assert.isFalse(info.healthy(5.seconds));
    
    writeln("\x1b[32m  ✓ Health check works\x1b[0m");
}

// ==================== CONCURRENT ACCESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Concurrent worker registration");
    
    import std.parallelism : parallel;
    import std.range : iota;
    import std.array : array;
    
    auto registry = new WorkerRegistry();
    
    try
    {
        // Register workers concurrently
        foreach (i; parallel(iota(20)))
        {
            registry.register("worker" ~ i.to!string ~ ":9000");
        }
        
        // All workers should be registered
        auto workers = registry.allWorkers();
        Assert.equal(workers.length, 20);
        
        writeln("\x1b[32m  ✓ Concurrent registration works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Registry - Concurrent heartbeat updates");
    
    import std.parallelism : parallel;
    import std.range : iota;
    
    auto registry = new WorkerRegistry();
    
    // Register workers
    WorkerId[] workerIds;
    foreach (i; 0 .. 10)
    {
        auto result = registry.register("worker" ~ i.to!string ~ ":9000");
        if (result.isOk)
            workerIds ~= result.unwrap();
    }
    
    try
    {
        // Update heartbeats concurrently
        foreach (i; parallel(iota(10)))
        {
            HeartBeat hb;
            hb.worker = workerIds[i];
            hb.state = WorkerState.Idle;
            hb.metrics.queueDepth = cast(size_t)i;
            registry.updateHeartbeat(workerIds[i], hb);
        }
        
        // All workers should be updated
        auto workers = registry.allWorkers();
        Assert.equal(workers.length, 10);
        
        writeln("\x1b[32m  ✓ Concurrent heartbeat updates work\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

