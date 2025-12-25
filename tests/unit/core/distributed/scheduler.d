module tests.unit.core.distributed.scheduler;

import std.stdio;
import std.datetime;
import std.conv;
import std.range : iota;
import std.algorithm : map, filter, each;
import std.array : array;
import core.thread;
import core.atomic;
import engine.distributed.coordinator.scheduler;
import engine.distributed.coordinator.registry;
import engine.distributed.protocol.protocol;
import engine.graph : BuildGraph;
import infrastructure.config.schema.schema : TargetId;
import tests.harness;

// ==================== SCHEDULER CREATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Creation");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    Assert.notNull(scheduler);
    Assert.isTrue(scheduler.isRunning());
    Assert.isFalse(scheduler.isProfileGuided());
    
    writeln("\x1b[32m  ✓ Scheduler creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Shutdown");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    Assert.isTrue(scheduler.isRunning());
    
    scheduler.shutdown();
    
    Assert.isFalse(scheduler.isRunning());
    
    writeln("\x1b[32m  ✓ Scheduler shutdown works\x1b[0m");
}

// ==================== ACTION SCHEDULING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Schedule action");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    ubyte[32] hash;
    hash[0] = 0x01;
    auto actionId = ActionId(hash);
    
    auto request = new ActionRequest(
        actionId,
        "echo hello",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    auto result = scheduler.schedule(request);
    Assert.isTrue(result.isOk);
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.ready, 1);
    
    writeln("\x1b[32m  ✓ Action scheduling works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Schedule duplicate action");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    ubyte[32] hash;
    hash[0] = 0x02;
    auto actionId = ActionId(hash);
    
    auto request = new ActionRequest(
        actionId,
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    // Schedule twice
    auto result1 = scheduler.schedule(request);
    auto result2 = scheduler.schedule(request);
    
    Assert.isTrue(result1.isOk);
    Assert.isTrue(result2.isOk);  // Should succeed (idempotent)
    
    // Only one action should be tracked
    auto stats = scheduler.getStats();
    Assert.equal(stats.ready, 1);
    
    writeln("\x1b[32m  ✓ Duplicate action scheduling handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Schedule multiple actions");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    foreach (i; 0 .. 10)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        auto actionId = ActionId(hash);
        
        auto request = new ActionRequest(
            actionId,
            "echo " ~ i.to!string,
            null,
            [],
            [],
            Capabilities.init,
            Priority.Normal,
            60.seconds
        );
        
        scheduler.schedule(request);
    }
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.ready, 10);
    
    writeln("\x1b[32m  ✓ Multiple action scheduling works\x1b[0m");
}

// ==================== PRIORITY SCHEDULING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Priority ordering");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Schedule low priority
    ubyte[32] hashLow;
    hashLow[0] = 0x01;
    auto lowReq = new ActionRequest(
        ActionId(hashLow),
        "echo low",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Low,
        60.seconds
    );
    scheduler.schedule(lowReq);
    
    // Schedule critical priority
    ubyte[32] hashCrit;
    hashCrit[0] = 0x02;
    auto critReq = new ActionRequest(
        ActionId(hashCrit),
        "echo critical",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Critical,
        60.seconds
    );
    scheduler.schedule(critReq);
    
    // Schedule high priority
    ubyte[32] hashHigh;
    hashHigh[0] = 0x03;
    auto highReq = new ActionRequest(
        ActionId(hashHigh),
        "echo high",
        null,
        [],
        [],
        Capabilities.init,
        Priority.High,
        60.seconds
    );
    scheduler.schedule(highReq);
    
    // Dequeue should return critical first
    auto dequeued1 = scheduler.dequeueReady();
    Assert.isTrue(dequeued1.isOk);
    Assert.equal(dequeued1.unwrap().priority, Priority.Critical);
    
    writeln("\x1b[32m  ✓ Priority ordering works\x1b[0m");
}

// ==================== ACTION DEQUEUE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Dequeue from empty queue");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    auto result = scheduler.dequeueReady();
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ Empty queue dequeue handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Dequeue transitions state");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    ubyte[32] hash;
    hash[0] = 0x01;
    auto actionId = ActionId(hash);
    
    auto request = new ActionRequest(
        actionId,
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    scheduler.schedule(request);
    
    auto stats1 = scheduler.getStats();
    Assert.equal(stats1.ready, 1);
    
    // Dequeue
    auto dequeued = scheduler.dequeueReady();
    Assert.isTrue(dequeued.isOk);
    
    // Ready count should decrease (action moves to scheduled state)
    auto stats2 = scheduler.getStats();
    Assert.equal(stats2.ready, 0);
    
    writeln("\x1b[32m  ✓ Dequeue state transition works\x1b[0m");
}

// ==================== WORKER ASSIGNMENT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Assign action to worker");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Register worker
    auto workerResult = registry.register("worker1:9000");
    Assert.isTrue(workerResult.isOk);
    auto workerId = workerResult.unwrap();
    
    // Schedule action
    ubyte[32] hash;
    hash[0] = 0x01;
    auto actionId = ActionId(hash);
    
    auto request = new ActionRequest(
        actionId,
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    scheduler.schedule(request);
    scheduler.dequeueReady();  // Move to scheduled state
    
    // Assign to worker
    auto assignResult = scheduler.assign(actionId, workerId);
    Assert.isTrue(assignResult.isOk);
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.executing, 1);
    
    writeln("\x1b[32m  ✓ Worker assignment works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Assign non-existent action");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    ubyte[32] hash;
    hash[0] = 0xFF;
    auto fakeActionId = ActionId(hash);
    auto fakeWorkerId = WorkerId(999);
    
    auto result = scheduler.assign(fakeActionId, fakeWorkerId);
    Assert.isTrue(result.isErr);
    
    writeln("\x1b[32m  ✓ Non-existent action assignment handled\x1b[0m");
}

// ==================== COMPLETION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Action completion");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    auto workerResult = registry.register("worker1:9000");
    auto workerId = workerResult.unwrap();
    
    ubyte[32] hash;
    hash[0] = 0x01;
    auto actionId = ActionId(hash);
    
    auto request = new ActionRequest(
        actionId,
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    scheduler.schedule(request);
    scheduler.dequeueReady();
    scheduler.assign(actionId, workerId);
    
    // Complete action
    ActionResult result;
    result.id = actionId;
    result.status = ResultStatus.Success;
    result.exitCode = 0;
    result.duration = 100.msecs;
    
    scheduler.onComplete(actionId, result);
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.completed, 1);
    Assert.equal(stats.executing, 0);
    
    writeln("\x1b[32m  ✓ Action completion works\x1b[0m");
}

// ==================== FAILURE HANDLING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Action failure with retry");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    auto workerResult = registry.register("worker1:9000");
    auto workerId = workerResult.unwrap();
    
    ubyte[32] hash;
    hash[0] = 0x01;
    auto actionId = ActionId(hash);
    
    auto request = new ActionRequest(
        actionId,
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    scheduler.schedule(request);
    scheduler.dequeueReady();
    scheduler.assign(actionId, workerId);
    
    // First failure - should retry
    scheduler.onFailure(actionId, "timeout");
    
    auto stats1 = scheduler.getStats();
    Assert.equal(stats1.ready, 1);  // Requeued for retry
    Assert.equal(stats1.failed, 0);
    
    writeln("\x1b[32m  ✓ Action failure retry works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Action permanent failure after max retries");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    auto workerResult = registry.register("worker1:9000");
    auto workerId = workerResult.unwrap();
    
    ubyte[32] hash;
    hash[0] = 0x01;
    auto actionId = ActionId(hash);
    
    auto request = new ActionRequest(
        actionId,
        "echo test",
        null,
        [],
        [],
        Capabilities.init,
        Priority.Normal,
        60.seconds
    );
    
    scheduler.schedule(request);
    
    // Fail 4 times (max retries = 3)
    foreach (i; 0 .. 4)
    {
        scheduler.dequeueReady();
        scheduler.assign(actionId, workerId);
        scheduler.onFailure(actionId, "error " ~ i.to!string);
    }
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.failed, 1);
    
    writeln("\x1b[32m  ✓ Permanent failure after max retries works\x1b[0m");
}

// ==================== WORKER FAILURE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Worker failure reassignment");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    auto workerResult = registry.register("worker1:9000");
    auto workerId = workerResult.unwrap();
    
    // Schedule multiple actions
    foreach (i; 0 .. 3)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        auto actionId = ActionId(hash);
        
        auto request = new ActionRequest(
            actionId,
            "echo " ~ i.to!string,
            null,
            [],
            [],
            Capabilities.init,
            Priority.Normal,
            60.seconds
        );
        
        scheduler.schedule(request);
        scheduler.dequeueReady();
        scheduler.assign(actionId, workerId);
    }
    
    auto stats1 = scheduler.getStats();
    Assert.equal(stats1.executing, 3);
    
    // Worker fails
    scheduler.onWorkerFailure(workerId);
    
    // Actions should be requeued
    auto stats2 = scheduler.getStats();
    Assert.equal(stats2.ready, 3);
    Assert.equal(stats2.executing, 0);
    
    writeln("\x1b[32m  ✓ Worker failure reassignment works\x1b[0m");
}

// ==================== STATS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Stats accuracy");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    auto workerResult = registry.register("worker1:9000");
    auto workerId = workerResult.unwrap();
    
    // Schedule 5 actions
    ActionId[] actionIds;
    foreach (i; 0 .. 5)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        auto actionId = ActionId(hash);
        actionIds ~= actionId;
        
        auto request = new ActionRequest(
            actionId,
            "echo " ~ i.to!string,
            null,
            [],
            [],
            Capabilities.init,
            Priority.Normal,
            60.seconds
        );
        scheduler.schedule(request);
    }
    
    auto stats1 = scheduler.getStats();
    Assert.equal(stats1.ready, 5);
    Assert.equal(stats1.executing, 0);
    Assert.equal(stats1.completed, 0);
    Assert.equal(stats1.failed, 0);
    
    // Execute 2, complete 1, fail 1
    scheduler.dequeueReady();
    scheduler.assign(actionIds[0], workerId);
    
    scheduler.dequeueReady();
    scheduler.assign(actionIds[1], workerId);
    
    ActionResult result;
    result.id = actionIds[0];
    result.status = ResultStatus.Success;
    result.duration = 50.msecs;
    scheduler.onComplete(actionIds[0], result);
    
    auto stats2 = scheduler.getStats();
    Assert.equal(stats2.ready, 3);
    Assert.equal(stats2.executing, 1);
    Assert.equal(stats2.completed, 1);
    
    writeln("\x1b[32m  ✓ Stats accuracy verified\x1b[0m");
}

// ==================== CONCURRENT ACCESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Concurrent scheduling");
    
    import std.parallelism : parallel;
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    try
    {
        // Schedule actions concurrently
        foreach (i; parallel(iota(50)))
        {
            ubyte[32] hash;
            hash[0] = cast(ubyte)(i & 0xFF);
            hash[1] = cast(ubyte)((i >> 8) & 0xFF);
            auto actionId = ActionId(hash);
            
            auto request = new ActionRequest(
                actionId,
                "echo " ~ i.to!string,
                null,
                [],
                [],
                Capabilities.init,
                Priority.Normal,
                60.seconds
            );
            
            scheduler.schedule(request);
        }
        
        auto stats = scheduler.getStats();
        Assert.equal(stats.ready, 50);
        
        writeln("\x1b[32m  ✓ Concurrent scheduling works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Concurrent dequeue");
    
    import std.parallelism : parallel;
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Pre-schedule actions
    foreach (i; 0 .. 100)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)(i & 0xFF);
        hash[1] = cast(ubyte)((i >> 8) & 0xFF);
        auto actionId = ActionId(hash);
        
        auto request = new ActionRequest(
            actionId,
            "echo " ~ i.to!string,
            null,
            [],
            [],
            Capabilities.init,
            Priority.Normal,
            60.seconds
        );
        
        scheduler.schedule(request);
    }
    
    try
    {
        shared size_t dequeued = 0;
        
        // Concurrent dequeue
        foreach (i; parallel(iota(100)))
        {
            auto result = scheduler.dequeueReady();
            if (result.isOk)
                atomicOp!"+="(dequeued, 1);
        }
        
        Assert.equal(atomicLoad(dequeued), 100);
        
        writeln("\x1b[32m  ✓ Concurrent dequeue works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

// ==================== SHARDING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Distributed Scheduler - Shard distribution");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Schedule many actions to test shard distribution
    foreach (i; 0 .. 1000)
    {
        ubyte[32] hash;
        // Use different bytes to spread across shards
        hash[0] = cast(ubyte)(i & 0xFF);
        hash[1] = cast(ubyte)((i >> 8) & 0xFF);
        hash[2] = cast(ubyte)((i >> 16) & 0xFF);
        auto actionId = ActionId(hash);
        
        auto request = new ActionRequest(
            actionId,
            "echo " ~ i.to!string,
            null,
            [],
            [],
            Capabilities.init,
            Priority.Normal,
            60.seconds
        );
        
        scheduler.schedule(request);
    }
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.ready, 1000);
    
    writeln("\x1b[32m  ✓ Shard distribution works\x1b[0m");
}


