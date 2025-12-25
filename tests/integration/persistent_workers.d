module tests.integration.persistent_workers;

import std.stdio : writeln;
import std.conv : to;
import std.datetime : seconds, minutes, Duration;
import std.file : exists, tempDir, mkdir, write, remove, rmdirRecurse;
import std.path : buildPath;
import std.algorithm : canFind;
import core.time : MonoTime;
import core.thread : Thread;

import engine.workers.service;
import engine.workers.pool.manager;
import engine.workers.pool.recycler;
import engine.workers.pool.memory;
import engine.workers.protocol.types;

// Language workers
import engine.workers.jvm;
import engine.workers.typescript;
import engine.workers.rust;
import engine.workers.go;
import engine.workers.python;

/// Test full service lifecycle with all languages enabled
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Full service lifecycle");
    
    WorkerServiceConfig cfg;
    cfg.poolConfig.maxWorkersPerType = 2;
    cfg.poolConfig.idleTimeout = seconds(30);
    cfg.enableJVMWorkers = true;
    cfg.enableTSWorkers = true;
    cfg.enableRustWorkers = true;
    cfg.enableGoWorkers = true;
    cfg.enablePythonWorkers = true;
    
    auto service = new PersistentWorkerService(cfg);
    
    // Start
    service.start();
    assert(service.getStatus() == WorkerServiceStatus.Running, "Service should be running");
    
    // Verify pool has factories registered
    auto pool = service.getPool();
    assert(pool !is null, "Pool should exist");
    
    // Get initial metrics
    auto metrics = service.getMetrics();
    assert(metrics.totalCompilations == 0, "No compilations yet");
    
    // Stop
    service.stop();
    assert(service.getStatus() == WorkerServiceStatus.Stopped, "Service should be stopped");
    
    writeln("\x1b[32m  ✓ Full service lifecycle works\x1b[0m");
}

/// Test worker pool factory registration
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Factory registration");
    
    auto pool = new WorkerPool(WorkerPoolConfig.init);
    
    // Register all factory types
    pool.registerFactory(new JVMWorkerFactory());
    pool.registerFactory(new TypeScriptWorkerFactory());
    pool.registerFactory(new RustWorkerFactory());
    pool.registerFactory(new GoWorkerFactory());
    pool.registerFactory(new PythonWorkerFactory());
    
    pool.start();
    scope(exit) pool.stop();
    
    auto stats = pool.getStats();
    assert(stats.totalStartups == 0, "No workers started yet");
    
    writeln("\x1b[32m  ✓ Factory registration works\x1b[0m");
}

/// Test recycler warmth tracking
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Warmth tracking");
    
    RecyclingPolicy policy;
    policy.preferWarmWorkers = true;
    policy.keepHotAcrossBuilds = true;
    
    auto recycler = new WorkerRecycler(policy);
    
    auto id = WorkerId("test", 1);
    recycler.register(id);
    
    // Initially cold
    assert(recycler.getWarmth(id) == WarmthLevel.Cold, "Initial warmth should be cold");
    
    // Record requests to warm up
    foreach (i; 0..5)
        recycler.recordRequest(id);
    
    // Should be warming/warm now
    auto warmth = recycler.getWarmth(id);
    assert(warmth >= WarmthLevel.Warming, "Should be at least warming after 5 requests");
    
    // Record more to get hot
    foreach (i; 0..50)
        recycler.recordRequest(id);
    
    warmth = recycler.getWarmth(id);
    assert(warmth == WarmthLevel.Hot, "Should be hot after 50+ requests");
    
    // Check estimated speedup
    auto speedup = recycler.estimatedSpeedup();
    assert(speedup > 1.0f, "Speedup should be > 1 with hot workers");
    
    recycler.unregister(id);
    
    writeln("\x1b[32m  ✓ Warmth tracking works\x1b[0m");
}

/// Test memory monitor
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Memory monitoring");
    
    MemoryThresholds thresholds;
    thresholds.normalMax = 0.70f;
    thresholds.elevatedMax = 0.85f;
    thresholds.highMax = 0.95f;
    
    auto monitor = new WorkerMemoryMonitor(thresholds, seconds(1));
    
    auto id = WorkerId("test", 1);
    size_t maxHeap = 2048 * 1024 * 1024; // 2GB
    
    monitor.register(id, maxHeap);
    
    // Initial state should be normal
    assert(!monitor.isOOMRisk(id), "Should not be at risk initially");
    
    // Update with low usage
    monitor.update(id, cast(size_t)(maxHeap * 0.5), 0);
    assert(!monitor.isOOMRisk(id), "50% usage should not be at risk");
    assert(monitor.getPressure(id) == MemoryPressure.Normal, "Should be normal pressure");
    
    // Update with high usage
    monitor.update(id, cast(size_t)(maxHeap * 0.90), 0);
    assert(monitor.isOOMRisk(id), "90% usage should be at risk");
    assert(monitor.getPressure(id) == MemoryPressure.High, "Should be high pressure");
    
    // Update with critical usage
    monitor.update(id, cast(size_t)(maxHeap * 0.98), 0);
    assert(monitor.isCritical(id), "98% usage should be critical");
    assert(monitor.getPressure(id) == MemoryPressure.Critical, "Should be critical pressure");
    
    // Check at-risk list
    auto atRisk = monitor.getAtRisk();
    assert(atRisk.canFind(id), "Worker should be in at-risk list");
    
    monitor.unregister(id);
    
    writeln("\x1b[32m  ✓ Memory monitoring works\x1b[0m");
}

/// Test worker selection with warmth preference
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Warmth-aware selection");
    
    RecyclingPolicy policy;
    policy.preferWarmWorkers = true;
    
    auto recycler = new WorkerRecycler(policy);
    
    // Register workers at different warmth levels
    auto cold = WorkerId("test", 1);
    auto warm = WorkerId("test", 2);
    auto hot = WorkerId("test", 3);
    
    recycler.register(cold);
    recycler.register(warm);
    recycler.register(hot);
    
    // Warm up workers to different levels
    foreach (i; 0..5)
        recycler.recordRequest(warm);
    
    foreach (i; 0..55)
        recycler.recordRequest(hot);
    
    // Select best should prefer hot
    auto selected = recycler.selectBest([cold, warm, hot]);
    assert(selected == hot, "Should select hottest worker");
    
    // Without hot, should prefer warm
    selected = recycler.selectBest([cold, warm]);
    assert(selected == warm, "Should select warm over cold");
    
    recycler.unregister(cold);
    recycler.unregister(warm);
    recycler.unregister(hot);
    
    writeln("\x1b[32m  ✓ Warmth-aware selection works\x1b[0m");
}

/// Test eviction policy
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Eviction policy");
    
    RecyclingPolicy policy;
    policy.maxIdleTime = seconds(1);
    policy.minKeepWarmTime = seconds(0);
    policy.hotWorkerBonus = seconds(0);
    
    auto recycler = new WorkerRecycler(policy);
    
    auto id = WorkerId("test", 1);
    recycler.register(id);
    
    // Should not evict immediately
    assert(!recycler.shouldEvict(id), "Should not evict immediately");
    
    // Wait for idle timeout
    Thread.sleep(seconds(2));
    
    // Should evict now
    assert(recycler.shouldEvict(id), "Should evict after idle timeout");
    
    recycler.unregister(id);
    
    writeln("\x1b[32m  ✓ Eviction policy works\x1b[0m");
}

/// Test recycle policy
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Recycle policy");
    
    RecyclingPolicy policy;
    policy.maxRequestsBeforeRecycle = 10;
    
    auto recycler = new WorkerRecycler(policy);
    
    auto id = WorkerId("test", 1);
    recycler.register(id);
    
    // Should not recycle initially
    assert(!recycler.shouldRecycle(id), "Should not recycle initially");
    
    // Record requests up to limit
    foreach (i; 0..10)
        recycler.recordRequest(id);
    
    // Should recycle now
    assert(recycler.shouldRecycle(id), "Should recycle after max requests");
    
    recycler.unregister(id);
    
    writeln("\x1b[32m  ✓ Recycle policy works\x1b[0m");
}

/// Test statistics tracking
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Statistics tracking");
    
    auto recycler = new WorkerRecycler();
    
    auto id1 = WorkerId("test", 1);
    auto id2 = WorkerId("test", 2);
    
    recycler.register(id1);
    recycler.register(id2);
    
    foreach (i; 0..10)
        recycler.recordRequest(id1);
    
    foreach (i; 0..50)
        recycler.recordRequest(id2);
    
    auto stats = recycler.getStats();
    assert(stats.tracked == 2, "Should track 2 workers");
    
    // Check warmth distribution
    assert(id1.type in stats.byLevel || stats.byLevel.length > 0, "Should have warmth levels");
    
    recycler.unregister(id1);
    recycler.unregister(id2);
    
    writeln("\x1b[32m  ✓ Statistics tracking works\x1b[0m");
}

/// Test memory statistics
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Memory statistics");
    
    auto monitor = new WorkerMemoryMonitor();
    
    auto id1 = WorkerId("test", 1);
    auto id2 = WorkerId("test", 2);
    
    monitor.register(id1, 2048 * 1024 * 1024);
    monitor.register(id2, 4096 * 1024 * 1024);
    
    monitor.update(id1, 1024 * 1024 * 1024, 1500 * 1024 * 1024);
    monitor.update(id2, 500 * 1024 * 1024, 800 * 1024 * 1024);
    
    auto stats = monitor.getStats();
    assert(stats.monitored == 2, "Should monitor 2 workers");
    assert(stats.totalSamples >= 2, "Should have samples");
    
    monitor.unregister(id1);
    monitor.unregister(id2);
    
    writeln("\x1b[32m  ✓ Memory statistics work\x1b[0m");
}

/// Test service with custom pool config
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Custom pool config");
    
    WorkerServiceConfig cfg;
    cfg.poolConfig.maxWorkersPerType = 8;
    cfg.poolConfig.idleTimeout = minutes(15);
    cfg.poolConfig.healthCheckInterval = seconds(10);
    cfg.poolConfig.maxRequestsPerWorker = 5000;
    cfg.poolConfig.enableRecycling = true;
    cfg.poolConfig.enableMemoryMonitor = true;
    cfg.poolConfig.persistAcrossBuilds = true;
    
    // Disable workers for fast test
    cfg.enableJVMWorkers = false;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = false;
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = false;
    
    auto service = new PersistentWorkerService(cfg);
    service.start();
    scope(exit) service.stop();
    
    auto pool = service.getPool();
    assert(pool !is null, "Pool should be configured");
    
    auto recycler = pool.getRecycler();
    assert(recycler !is null, "Recycler should be enabled");
    
    auto memMonitor = pool.getMemoryMonitor();
    assert(memMonitor !is null, "Memory monitor should be enabled");
    
    writeln("\x1b[32m  ✓ Custom pool config works\x1b[0m");
}

/// Test service metrics aggregation
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Metrics aggregation");
    
    WorkerServiceConfig cfg;
    cfg.enableJVMWorkers = false;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = false;
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = false;
    
    auto service = new PersistentWorkerService(cfg);
    service.start();
    scope(exit) service.stop();
    
    auto metrics = service.getMetrics();
    
    // Initial metrics
    assert(metrics.totalCompilations == 0, "Initial compilations");
    assert(metrics.averageSpeedupFactor >= 1.0f, "Initial speedup >= 1");
    assert(metrics.lastUpdated != MonoTime.init, "Last updated should be set");
    
    // Pool stats should be available
    assert(metrics.poolStats.totalStartups == 0, "Initial pool startups");
    
    writeln("\x1b[32m  ✓ Metrics aggregation works\x1b[0m");
}

/// Test disabled language workers
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Disabled languages");
    
    WorkerServiceConfig cfg;
    cfg.enableJVMWorkers = false;
    cfg.enableTSWorkers = false;
    cfg.enableRustWorkers = true;  // Only Rust enabled
    cfg.enableGoWorkers = false;
    cfg.enablePythonWorkers = false;
    
    auto service = new PersistentWorkerService(cfg);
    service.start();
    scope(exit) service.stop();
    
    assert(service.getStatus() == WorkerServiceStatus.Running, "Service should start");
    
    writeln("\x1b[32m  ✓ Disabled languages handled correctly\x1b[0m");
}

/// Test protocol types roundtrip
unittest
{
    writeln("\x1b[36m[INTEGRATION]\x1b[0m persistent_workers - Protocol roundtrip");
    
    // Create complex request
    WorkRequest req;
    req.requestId = 12345;
    req.arguments = ["cargo", "build", "--release", "--target", "x86_64-unknown-linux-gnu"];
    req.inputs = [
        InputFile("Cargo.toml", "tomlhash123"),
        InputFile("src/main.rs", "mainhash456"),
        InputFile("src/lib.rs", "libhash789")
    ];
    req.sandboxDir = "/tmp/build/sandbox";
    req.verbosity = 2;
    req.cancel = false;
    
    // Serialize and deserialize
    auto json = req.toJson();
    auto restored = WorkRequest.fromJson(json);
    
    assert(restored.requestId == req.requestId, "Request ID roundtrip");
    assert(restored.arguments == req.arguments, "Arguments roundtrip");
    assert(restored.inputs.length == req.inputs.length, "Inputs length roundtrip");
    assert(restored.sandboxDir == req.sandboxDir, "Sandbox roundtrip");
    
    // Create complex response
    WorkResponse resp;
    resp.requestId = 12345;
    resp.exitCode = 0;
    resp.output = "Compiling myproject v1.0.0\nFinished release [optimized] target(s) in 5.23s";
    resp.wasCached = false;
    resp.executionTimeMs = 5230;
    resp.outputs = [
        OutputFile("target/release/myproject", "binhash001")
    ];
    
    // Serialize and deserialize
    json = resp.toJson();
    auto restoredResp = WorkResponse.fromJson(json);
    
    assert(restoredResp.requestId == resp.requestId, "Response ID roundtrip");
    assert(restoredResp.exitCode == resp.exitCode, "Exit code roundtrip");
    assert(restoredResp.success == resp.success, "Success roundtrip");
    
    writeln("\x1b[32m  ✓ Protocol roundtrip works\x1b[0m");
}


