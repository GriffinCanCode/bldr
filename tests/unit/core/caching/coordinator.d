module tests.unit.core.caching.coordinator;

import std.stdio;
import std.path;
import std.file;
import engine.caching.coordinator;
import engine.caching.events;
import engine.caching.metrics;
import frontend.cli.events.events;
import tests.harness;
import tests.fixtures;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheCoordinator - Basic target cache hit/miss");
    
    auto tempDir = scoped(new TempDir("coordinator-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Create test file
    tempDir.createFile("main.d", "void main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "main.d");
    
    string[] sources = [sourcePath];
    string[] deps = [];
    
    // Initial check - miss
    Assert.isFalse(coordinator.isCached("test-target", sources, deps));
    
    // Update cache
    coordinator.update("test-target", sources, deps, "hash123");
    
    // Second check - hit
    Assert.isTrue(coordinator.isCached("test-target", sources, deps));
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Coordinator cache operations work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheCoordinator - Action cache integration");
    
    auto tempDir = scoped(new TempDir("coordinator-action-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Create source file
    tempDir.createFile("source.cpp", "int main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.cpp");
    
    // Create action
    import engine.caching.actions.action : ActionId, ActionType;
    auto actionId = ActionId("my-target", ActionType.Compile, "hash123", "source.cpp");
    
    string[] inputs = [sourcePath];
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    // Check cache - miss
    Assert.isFalse(coordinator.isActionCached(actionId, inputs, metadata));
    
    // Record action
    tempDir.createFile("source.o", "binary");
    auto outputPath = buildPath(tempDir.getPath(), "source.o");
    string[] outputs = [outputPath];
    
    coordinator.recordAction(actionId, inputs, outputs, metadata, true);
    
    // Check cache - hit
    Assert.isTrue(coordinator.isActionCached(actionId, inputs, metadata));
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Action cache integration works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheCoordinator - Event emission");
    
    auto tempDir = scoped(new TempDir("coordinator-events-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Create event publisher
    auto publisher = new SimpleEventPublisher();
    
    // Subscribe metrics collector
    auto metricsCollector = new CacheMetricsCollector();
    publisher.subscribe(metricsCollector);
    
    // Create coordinator with publisher
    auto coordinator = new CacheCoordinator(cacheDir, publisher);
    
    // Create test file
    tempDir.createFile("test.d", "void test() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "test.d");
    
    string[] sources = [sourcePath];
    string[] deps = [];
    
    // Trigger cache miss (emits event)
    coordinator.isCached("test-target", sources, deps);
    
    // Update (emits event)
    coordinator.update("test-target", sources, deps, "hash456");
    
    // Hit (emits event)
    coordinator.isCached("test-target", sources, deps);
    
    // Get metrics
    auto metrics = metricsCollector.getMetrics();
    Assert.isTrue(metrics.targetHits > 0, "Should have target hits");
    Assert.isTrue(metrics.targetMisses > 0, "Should have target misses");
    Assert.isTrue(metrics.updates > 0, "Should have updates");
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Event emission and metrics collection work\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheCoordinator - Statistics");
    
    auto tempDir = scoped(new TempDir("coordinator-stats-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Get initial stats
    auto stats = coordinator.getStats();
    Assert.equal(stats.targetCacheEntries, 0);
    
    // Add some cache entries
    tempDir.createFile("file1.d", "content1");
    tempDir.createFile("file2.d", "content2");
    
    auto file1 = buildPath(tempDir.getPath(), "file1.d");
    auto file2 = buildPath(tempDir.getPath(), "file2.d");
    
    coordinator.update("target1", [file1], [], "hash1");
    coordinator.update("target2", [file2], [], "hash2");
    
    // Get updated stats
    stats = coordinator.getStats();
    Assert.equal(stats.targetCacheEntries, 2);
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Statistics reporting works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheCoordinator - Batch validation");
    
    auto tempDir = scoped(new TempDir("coordinator-batch-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Create test files
    tempDir.createFile("file1.d", "content1");
    tempDir.createFile("file2.d", "content2");
    tempDir.createFile("file3.d", "content3");
    tempDir.createFile("file4.d", "content4");
    
    auto file1 = buildPath(tempDir.getPath(), "file1.d");
    auto file2 = buildPath(tempDir.getPath(), "file2.d");
    auto file3 = buildPath(tempDir.getPath(), "file3.d");
    auto file4 = buildPath(tempDir.getPath(), "file4.d");
    
    // Update cache for some targets
    coordinator.update("target1", [file1], [], "hash1");
    coordinator.update("target2", [file2], [], "hash2");
    // target3 and target4 not cached
    
    // Build batch validation requests
    TargetValidationRequest[] requests = [
        TargetValidationRequest("target1", [file1], []),
        TargetValidationRequest("target2", [file2], []),
        TargetValidationRequest("target3", [file3], []),
        TargetValidationRequest("target4", [file4], []),
    ];
    
    // Batch validate
    auto results = coordinator.batchValidate(requests);
    
    // Verify results
    Assert.equal(results.totalTargets, 4);
    Assert.equal(results.cachedTargets, 2);
    Assert.isTrue(results.results["target1"].cached, "target1 should be cached");
    Assert.isTrue(results.results["target2"].cached, "target2 should be cached");
    Assert.isFalse(results.results["target3"].cached, "target3 should not be cached");
    Assert.isFalse(results.results["target4"].cached, "target4 should not be cached");
    
    // Check hit rate
    Assert.equal(results.hitRate(), 50.0, "Hit rate should be 50%");
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Batch validation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheCoordinator - Batch action validation");
    
    auto tempDir = scoped(new TempDir("coordinator-batch-action-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Create source files
    tempDir.createFile("src1.cpp", "code1");
    tempDir.createFile("src2.cpp", "code2");
    tempDir.createFile("src3.cpp", "code3");
    
    auto src1 = buildPath(tempDir.getPath(), "src1.cpp");
    auto src2 = buildPath(tempDir.getPath(), "src2.cpp");
    auto src3 = buildPath(tempDir.getPath(), "src3.cpp");
    
    // Create actions
    import engine.caching.actions.action : ActionId, ActionType;
    auto action1 = ActionId("target", ActionType.Compile, "hash1", "src1.cpp");
    auto action2 = ActionId("target", ActionType.Compile, "hash2", "src2.cpp");
    auto action3 = ActionId("target", ActionType.Compile, "hash3", "src3.cpp");
    
    // Record some actions
    tempDir.createFile("src1.o", "binary1");
    tempDir.createFile("src2.o", "binary2");
    
    auto out1 = buildPath(tempDir.getPath(), "src1.o");
    auto out2 = buildPath(tempDir.getPath(), "src2.o");
    
    string[string] metadata;
    metadata["compiler"] = "g++";
    
    coordinator.recordAction(action1, [src1], [out1], metadata, true);
    coordinator.recordAction(action2, [src2], [out2], metadata, true);
    // action3 not recorded
    
    // Build batch validation requests
    ActionValidationRequest[] requests = [
        ActionValidationRequest(action1, [src1], metadata),
        ActionValidationRequest(action2, [src2], metadata),
        ActionValidationRequest(action3, [src3], metadata),
    ];
    
    // Batch validate
    auto results = coordinator.batchValidateActions(requests);
    
    // Verify results
    Assert.equal(results.totalActions, 3);
    Assert.equal(results.cachedActions, 2);
    Assert.isTrue(results.results[action1.toString()].cached, "action1 should be cached");
    Assert.isTrue(results.results[action2.toString()].cached, "action2 should be cached");
    Assert.isFalse(results.results[action3.toString()].cached, "action3 should not be cached");
    
    // Check hit rate
    Assert.equal(results.hitRate(), 66.666664, "Hit rate should be ~66.67%");
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Batch action validation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m CacheCoordinator - Batch validation performance");
    
    auto tempDir = scoped(new TempDir("coordinator-batch-perf-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Create many test files
    enum numTargets = 100;
    TargetValidationRequest[] requests;
    
    foreach (i; 0 .. numTargets)
    {
        import std.format : format;
        auto filename = format("file%d.d", i);
        tempDir.createFile(filename, format("content%d", i));
        auto filepath = buildPath(tempDir.getPath(), filename);
        
        // Cache half of them
        auto targetId = format("target%d", i);
        if (i % 2 == 0)
            coordinator.update(targetId, [filepath], [], format("hash%d", i));
        
        requests ~= TargetValidationRequest(targetId, [filepath], []);
    }
    
    import std.datetime.stopwatch : StopWatch, AutoStart;
    
    // Benchmark batch validation
    auto batchTimer = StopWatch(AutoStart.yes);
    auto batchResults = coordinator.batchValidate(requests);
    batchTimer.stop();
    
    // Verify correctness
    Assert.equal(batchResults.totalTargets, numTargets);
    Assert.equal(batchResults.cachedTargets, numTargets / 2);
    Assert.equal(batchResults.hitRate(), 50.0, "Hit rate should be 50%");
    
    // Benchmark sequential validation
    auto seqTimer = StopWatch(AutoStart.yes);
    size_t seqHits = 0;
    foreach (req; requests)
    {
        if (coordinator.isCached(req.targetId, req.sources, req.deps))
            seqHits++;
    }
    seqTimer.stop();
    
    Assert.equal(seqHits, numTargets / 2, "Sequential should find same results");
    
    // Report performance
    auto batchMs = batchTimer.peek().total!"msecs";
    auto seqMs = seqTimer.peek().total!"msecs";
    
    writefln("  Batch: %d ms, Sequential: %d ms", batchMs, seqMs);
    
    // Note: Speedup may vary, but batch should not be slower
    // On single-core CI, speedup may be minimal due to overhead
    if (batchMs < seqMs)
        writefln("  \x1b[32m✓ Batch is %.2fx faster\x1b[0m", cast(float)seqMs / batchMs);
    else
        writeln("  \x1b[33m⚠ No speedup (expected on single-core)\x1b[0m");
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Batch validation performance test complete\x1b[0m");
}

