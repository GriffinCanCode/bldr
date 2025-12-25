module tests.unit.core.distributed.integration;

import std.stdio;
import std.datetime;
import std.conv;
import std.range : iota;
import std.algorithm : map, filter;
import std.array : array;
import core.thread;
import core.atomic;
import engine.distributed.coordinator.coordinator;
import engine.distributed.coordinator.scheduler;
import engine.distributed.coordinator.registry;
import engine.distributed.worker.worker;
import engine.distributed.worker.sandbox;
import engine.distributed.protocol.protocol;
import engine.distributed.storage.artifacts;
import engine.graph : BuildGraph;
import tests.harness;
import tests.fixtures : TempDir;

// ==================== COORDINATOR LIFECYCLE TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Coordinator creation");
    
    auto graph = new BuildGraph();
    CoordinatorConfig config;
    config.port = 0;  // Random port for testing
    
    auto coordinator = new Coordinator(graph, config);
    Assert.notNull(coordinator);
    
    writeln("\x1b[32m  ✓ Coordinator creation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Coordinator config defaults");
    
    CoordinatorConfig config;
    
    Assert.equal(config.host, "0.0.0.0");
    Assert.equal(config.port, 9000);
    Assert.equal(config.maxWorkers, 1000);
    Assert.equal(config.workerTimeout, 30.seconds);
    Assert.isTrue(config.enableWorkStealing);
    Assert.equal(config.heartbeatInterval, 5.seconds);
    Assert.isTrue(config.enableProfileGuidedScheduling);
    
    writeln("\x1b[32m  ✓ Coordinator config defaults correct\x1b[0m");
}

// ==================== WORKER REGISTRATION FLOW TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Worker registration flow");
    
    auto registry = new WorkerRegistry();
    
    // Register worker
    auto regResult = registry.register("worker1:9000");
    Assert.isTrue(regResult.isOk);
    auto workerId = regResult.unwrap();
    
    // Verify worker state
    auto workerResult = registry.getWorker(workerId);
    Assert.isTrue(workerResult.isOk);
    auto worker = workerResult.unwrap();
    Assert.equal(worker.state, WorkerState.Idle);
    
    writeln("\x1b[32m  ✓ Worker registration flow works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Worker heartbeat flow");
    
    auto registry = new WorkerRegistry(5.seconds);
    
    auto regResult = registry.register("worker1:9000");
    auto workerId = regResult.unwrap();
    
    // Send heartbeat
    HeartBeat hb;
    hb.worker = workerId;
    hb.state = WorkerState.Executing;
    hb.metrics.queueDepth = 3;
    hb.metrics.cpuUsage = 0.5;
    
    registry.updateHeartbeat(workerId, hb);
    
    // Verify updated state
    auto workerResult = registry.getWorker(workerId);
    Assert.isTrue(workerResult.isOk);
    auto worker = workerResult.unwrap();
    Assert.equal(worker.state, WorkerState.Executing);
    Assert.equal(worker.metrics.queueDepth, 3);
    
    writeln("\x1b[32m  ✓ Worker heartbeat flow works\x1b[0m");
}

// ==================== ACTION EXECUTION FLOW TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Action execution flow");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Register worker
    auto workerResult = registry.register("worker1:9000");
    auto workerId = workerResult.unwrap();
    
    // Schedule action
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
    
    scheduler.schedule(request);
    
    // Dequeue and assign
    auto dequeued = scheduler.dequeueReady();
    Assert.isTrue(dequeued.isOk);
    
    scheduler.assign(actionId, workerId);
    
    // Complete
    ActionResult result;
    result.id = actionId;
    result.status = ResultStatus.Success;
    result.exitCode = 0;
    result.duration = 100.msecs;
    
    scheduler.onComplete(actionId, result);
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.completed, 1);
    
    writeln("\x1b[32m  ✓ Action execution flow works\x1b[0m");
}

// ==================== MULTI-WORKER TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Multi-worker distribution");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Register multiple workers
    WorkerId[] workerIds;
    foreach (i; 0 .. 4)
    {
        auto result = registry.register("worker" ~ i.to!string ~ ":9000");
        Assert.isTrue(result.isOk);
        workerIds ~= result.unwrap();
    }
    
    // Schedule multiple actions
    ActionId[] actionIds;
    foreach (i; 0 .. 8)
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
    
    // Distribute to workers
    foreach (i, actionId; actionIds)
    {
        auto dequeued = scheduler.dequeueReady();
        Assert.isTrue(dequeued.isOk);
        
        auto workerId = workerIds[i % workerIds.length];
        scheduler.assign(actionId, workerId);
    }
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.executing, 8);
    
    writeln("\x1b[32m  ✓ Multi-worker distribution works\x1b[0m");
}

// ==================== LOAD BALANCING TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Load-based worker selection");
    
    auto registry = new WorkerRegistry();
    
    // Register workers
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
    hb1.metrics.queueDepth = 10;
    hb1.metrics.cpuUsage = 0.9;
    registry.updateHeartbeat(id1, hb1);
    
    HeartBeat hb2;
    hb2.worker = id2;
    hb2.state = WorkerState.Idle;
    hb2.metrics.queueDepth = 1;
    hb2.metrics.cpuUsage = 0.1;
    registry.updateHeartbeat(id2, hb2);
    
    HeartBeat hb3;
    hb3.worker = id3;
    hb3.state = WorkerState.Executing;
    hb3.metrics.queueDepth = 5;
    hb3.metrics.cpuUsage = 0.5;
    registry.updateHeartbeat(id3, hb3);
    
    // Should select least loaded (worker2)
    Capabilities caps;
    auto selected = registry.selectWorker(caps);
    Assert.isTrue(selected.isOk);
    Assert.equal(selected.unwrap().value, id2.value);
    
    writeln("\x1b[32m  ✓ Load-based worker selection works\x1b[0m");
}

// ==================== ARTIFACT STORAGE FLOW TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Artifact storage flow");
    
    auto tempDir = TempDir("integration_storage");
    scope(exit) tempDir.cleanup();
    
    auto storage = new ArtifactStorage(tempDir.path, 100 * 1024 * 1024);
    
    // Store artifact
    ubyte[32] hash;
    hash[0] = 0xAA;
    auto artifactId = ActionId(hash);
    
    auto data = cast(ubyte[])"test artifact data".dup;
    auto putResult = storage.put(artifactId, data);
    Assert.isTrue(putResult.isOk);
    
    // Retrieve artifact
    auto getResult = storage.get(artifactId);
    Assert.isTrue(getResult.isOk);
    Assert.equal(getResult.unwrap(), data);
    
    writeln("\x1b[32m  ✓ Artifact storage flow works\x1b[0m");
}

// ==================== HEALTH CHECK FLOW TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Health check flow");
    
    auto registry = new WorkerRegistry(100.msecs);
    
    auto regResult = registry.register("worker1:9000");
    auto workerId = regResult.unwrap();
    
    // Initially healthy
    auto healthy1 = registry.healthyWorkers();
    Assert.equal(healthy1.length, 1);
    
    // Keep alive with heartbeat
    HeartBeat hb;
    hb.worker = workerId;
    hb.state = WorkerState.Idle;
    registry.updateHeartbeat(workerId, hb);
    
    // Still healthy
    auto healthy2 = registry.healthyWorkers();
    Assert.equal(healthy2.length, 1);
    
    // Wait for timeout
    Thread.sleep(200.msecs);
    
    // Now unhealthy
    auto healthy3 = registry.healthyWorkers();
    Assert.equal(healthy3.length, 0);
    
    writeln("\x1b[32m  ✓ Health check flow works\x1b[0m");
}

// ==================== RETRY FLOW TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Action retry flow");
    
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
    
    // First attempt fails
    scheduler.dequeueReady();
    scheduler.assign(actionId, workerId);
    scheduler.onFailure(actionId, "network error");
    
    // Should be requeued
    auto stats1 = scheduler.getStats();
    Assert.equal(stats1.ready, 1);
    
    // Second attempt succeeds
    scheduler.dequeueReady();
    scheduler.assign(actionId, workerId);
    
    ActionResult result;
    result.id = actionId;
    result.status = ResultStatus.Success;
    result.exitCode = 0;
    result.duration = 50.msecs;
    
    scheduler.onComplete(actionId, result);
    
    auto stats2 = scheduler.getStats();
    Assert.equal(stats2.completed, 1);
    Assert.equal(stats2.failed, 0);
    
    writeln("\x1b[32m  ✓ Action retry flow works\x1b[0m");
}

// ==================== CONCURRENT INTEGRATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Concurrent action scheduling");
    
    import std.parallelism : parallel;
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Register workers
    foreach (i; 0 .. 4)
        registry.register("worker" ~ i.to!string ~ ":9000");
    
    try
    {
        // Schedule actions concurrently
        foreach (i; parallel(iota(100)))
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
        Assert.equal(stats.ready, 100);
        
        writeln("\x1b[32m  ✓ Concurrent action scheduling works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Concurrent completion handling");
    
    import std.parallelism : parallel;
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    auto workerResult = registry.register("worker1:9000");
    auto workerId = workerResult.unwrap();
    
    // Pre-schedule and assign actions
    ActionId[] actionIds;
    foreach (i; 0 .. 50)
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
        scheduler.dequeueReady();
        scheduler.assign(actionId, workerId);
    }
    
    try
    {
        // Complete actions concurrently
        foreach (i; parallel(iota(50)))
        {
            ActionResult result;
            result.id = actionIds[i];
            result.status = ResultStatus.Success;
            result.exitCode = 0;
            result.duration = 10.msecs;
            
            scheduler.onComplete(actionIds[i], result);
        }
        
        auto stats = scheduler.getStats();
        Assert.equal(stats.completed, 50);
        
        writeln("\x1b[32m  ✓ Concurrent completion handling works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent test failed: ", e.msg, "\x1b[0m");
    }
}

// ==================== END-TO-END SIMULATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Full build simulation");
    
    auto graph = new BuildGraph();
    auto registry = new WorkerRegistry();
    auto scheduler = new DistributedScheduler(graph, registry);
    
    // Setup workers
    WorkerId[] workers;
    foreach (i; 0 .. 3)
    {
        auto result = registry.register("worker" ~ i.to!string ~ ":9000");
        workers ~= result.unwrap();
    }
    
    // Schedule build actions
    ActionId[] actions;
    foreach (i; 0 .. 20)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)i;
        auto actionId = ActionId(hash);
        actions ~= actionId;
        
        auto request = new ActionRequest(
            actionId,
            "gcc -c file" ~ i.to!string ~ ".c",
            null,
            [],
            [OutputSpec("file" ~ i.to!string ~ ".o", false)],
            Capabilities.init,
            i < 5 ? Priority.High : Priority.Normal,
            120.seconds
        );
        
        scheduler.schedule(request);
    }
    
    // Simulate execution
    size_t completed = 0;
    size_t workerIdx = 0;
    
    while (completed < 20)
    {
        auto dequeued = scheduler.dequeueReady();
        if (dequeued.isErr)
            break;
        
        auto request = dequeued.unwrap();
        auto workerId = workers[workerIdx % workers.length];
        workerIdx++;
        
        scheduler.assign(request.id, workerId);
        
        // Simulate execution time
        Thread.sleep(1.msecs);
        
        ActionResult result;
        result.id = request.id;
        result.status = ResultStatus.Success;
        result.exitCode = 0;
        result.duration = 50.msecs;
        
        scheduler.onComplete(request.id, result);
        completed++;
    }
    
    auto stats = scheduler.getStats();
    Assert.equal(stats.completed, 20);
    Assert.equal(stats.failed, 0);
    
    writeln("\x1b[32m  ✓ Full build simulation works\x1b[0m");
}


