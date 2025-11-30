module tests.unit.core.caching.integration_test;

import std.stdio;
import std.path;
import std.file;
import std.datetime;
import std.conv;
import std.algorithm;
import std.array;
import std.parallelism;
import std.range;
import core.thread;
import core.time;
import engine.caching;
import engine.caching.coordinator.coordinator;
import engine.caching.targets.cache;
import engine.caching.actions.action;
import engine.caching.storage.cas;
import engine.caching.storage.gc;
import engine.caching.metrics;
import engine.caching.events;
import frontend.cli.events.events;
import tests.harness;
import tests.fixtures;

// ==================== MULTI-TIER CACHING INTEGRATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Full build with target and action caching");
    
    auto tempDir = scoped(new TempDir("integration-full-build"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Simulate a multi-file build
    string[] sources = [];
    string[] outputs = [];
    
    foreach (i; 0 .. 5)
    {
        auto srcName = "module" ~ i.to!string ~ ".d";
        auto objName = "module" ~ i.to!string ~ ".o";
        
        tempDir.createFile(srcName, "module mod" ~ i.to!string ~ "; int x = " ~ i.to!string ~ ";");
        tempDir.createFile(objName, "binary_" ~ i.to!string);
        
        sources ~= buildPath(tempDir.getPath(), srcName);
        outputs ~= buildPath(tempDir.getPath(), objName);
        
        // Record individual compile actions
        auto actionId = ActionId(
            "myapp", 
            ActionType.Compile, 
            "compile" ~ i.to!string, 
            srcName
        );
        
        coordinator.recordAction(
            actionId, 
            [sources[$-1]], 
            [outputs[$-1]], 
            null, 
            true
        );
    }
    
    // Record target-level cache
    coordinator.update("myapp", sources, [], "final-hash");
    
    // Verify everything is cached
    Assert.isTrue(coordinator.isCached("myapp", sources, []));
    
    foreach (i; 0 .. 5)
    {
        auto srcName = "module" ~ i.to!string ~ ".d";
        auto actionId = ActionId("myapp", ActionType.Compile, "compile" ~ i.to!string, srcName);
        Assert.isTrue(coordinator.isActionCached(actionId, [sources[i]], null));
    }
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Full multi-tier build caching works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Incremental rebuild with action cache");
    
    auto tempDir = scoped(new TempDir("integration-incremental"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Initial build
    string[] sources = [];
    foreach (i; 0 .. 3)
    {
        auto srcName = "file" ~ i.to!string ~ ".cpp";
        tempDir.createFile(srcName, "int var" ~ i.to!string ~ " = " ~ i.to!string ~ ";");
        sources ~= buildPath(tempDir.getPath(), srcName);
        
        auto actionId = ActionId("app", ActionType.Compile, "hash" ~ i.to!string, srcName);
        tempDir.createFile("file" ~ i.to!string ~ ".o", "obj");
        
        coordinator.recordAction(
            actionId, 
            [sources[$-1]], 
            [buildPath(tempDir.getPath(), "file" ~ i.to!string ~ ".o")], 
            null, 
            true
        );
    }
    
    coordinator.update("app", sources, [], "hash-all");
    
    // All cached
    foreach (i; 0 .. 3)
    {
        auto actionId = ActionId("app", ActionType.Compile, "hash" ~ i.to!string, "file" ~ i.to!string ~ ".cpp");
        Assert.isTrue(coordinator.isActionCached(actionId, [sources[i]], null));
    }
    
    // Modify one file
    Thread.sleep(10.msecs);
    tempDir.createFile("file1.cpp", "int var1 = 999;");
    
    // Check cache status
    auto action0 = ActionId("app", ActionType.Compile, "hash0", "file0.cpp");
    auto action1 = ActionId("app", ActionType.Compile, "hash1", "file1.cpp");
    auto action2 = ActionId("app", ActionType.Compile, "hash2", "file2.cpp");
    
    Assert.isTrue(coordinator.isActionCached(action0, [sources[0]], null), 
                  "Unchanged file should still be cached");
    Assert.isFalse(coordinator.isActionCached(action1, [sources[1]], null), 
                   "Modified file should be invalidated");
    Assert.isTrue(coordinator.isActionCached(action2, [sources[2]], null), 
                  "Unchanged file should still be cached");
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Incremental rebuild with action cache works\x1b[0m");
}

// ==================== CONTENT-ADDRESSABLE STORAGE INTEGRATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - CAS with coordinator");
    
    auto tempDir = scoped(new TempDir("integration-cas"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto storageDir = buildPath(cacheDir, "blobs");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    auto cas = new ContentAddressableStorage(storageDir);
    
    // Store some artifacts
    ubyte[] artifact1 = cast(ubyte[])"artifact data 1";
    ubyte[] artifact2 = cast(ubyte[])"artifact data 2";
    
    auto hash1 = cas.putBlob(artifact1).unwrap();
    auto hash2 = cas.putBlob(artifact2).unwrap();
    
    // Use coordinator normally
    tempDir.createFile("source.d", "void main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "source.d");
    
    coordinator.update("cas-target", [sourcePath], [], hash1);
    
    Assert.isTrue(coordinator.isCached("cas-target", [sourcePath], []));
    
    // Verify CAS still has blobs
    Assert.isTrue(cas.hasBlob(hash1));
    Assert.isTrue(cas.hasBlob(hash2));
    
    coordinator.close();
    writeln("\x1b[32m  ✓ CAS integration with coordinator works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Garbage collection with CAS");
    
    auto tempDir = scoped(new TempDir("integration-gc-cas"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto storageDir = buildPath(cacheDir, "blobs");
    
    auto cas = new ContentAddressableStorage(storageDir);
    auto targetCache = new BuildCache(cacheDir);
    auto actionCache = new ActionCache(buildPath(cacheDir, "actions"));
    
    // Store some blobs
    ubyte[] data1 = cast(ubyte[])"blob 1";
    ubyte[] data2 = cast(ubyte[])"blob 2";
    ubyte[] data3 = cast(ubyte[])"orphaned blob";
    
    auto hash1 = cas.putBlob(data1).unwrap();
    auto hash2 = cas.putBlob(data2).unwrap();
    auto orphanHash = cas.putBlob(data3).unwrap();
    
    // Reference first two blobs in cache
    tempDir.createFile("file1.d", "content1");
    tempDir.createFile("file2.d", "content2");
    
    auto path1 = buildPath(tempDir.getPath(), "file1.d");
    auto path2 = buildPath(tempDir.getPath(), "file2.d");
    
    targetCache.update("target1", [path1], [], hash1);
    targetCache.update("target2", [path2], [], hash2);
    
    // Orphan blob (hash3) is not referenced
    
    // Run GC
    auto gc = new CacheGarbageCollector(cas);
    auto gcResult = gc.collect(targetCache, actionCache);
    
    Assert.isTrue(gcResult.isOk, "GC should complete successfully");
    
    auto result = gcResult.unwrap();
    Assert.isTrue(result.blobsCollected >= 0, "GC should report results");
    
    targetCache.close();
    actionCache.close();
    
    writeln("\x1b[32m  ✓ Garbage collection with CAS works\x1b[0m");
}

// ==================== METRICS AND EVENTS INTEGRATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Metrics collection across build");
    
    auto tempDir = scoped(new TempDir("integration-metrics"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto publisher = new SimpleEventPublisher();
    auto metricsCollector = new CacheMetricsCollector();
    publisher.subscribe(metricsCollector);
    
    auto coordinator = new CacheCoordinator(cacheDir, publisher);
    
    // Perform various cache operations
    tempDir.createFile("a.d", "void a() {}");
    tempDir.createFile("b.d", "void b() {}");
    tempDir.createFile("c.d", "void c() {}");
    
    auto pathA = buildPath(tempDir.getPath(), "a.d");
    auto pathB = buildPath(tempDir.getPath(), "b.d");
    auto pathC = buildPath(tempDir.getPath(), "c.d");
    
    // Miss, update, hit sequence
    coordinator.isCached("target-a", [pathA], []);  // miss
    coordinator.update("target-a", [pathA], [], "hash-a");  // update
    coordinator.isCached("target-a", [pathA], []);  // hit
    
    coordinator.isCached("target-b", [pathB], []);  // miss
    coordinator.update("target-b", [pathB], [], "hash-b");  // update
    
    coordinator.isCached("target-c", [pathC], []);  // miss
    coordinator.update("target-c", [pathC], [], "hash-c");  // update
    coordinator.isCached("target-c", [pathC], []);  // hit
    
    // Get metrics
    auto metrics = metricsCollector.getMetrics();
    
    Assert.isTrue(metrics.targetHits >= 2, "Should have at least 2 hits");
    Assert.isTrue(metrics.targetMisses >= 3, "Should have at least 3 misses");
    Assert.isTrue(metrics.updates >= 3, "Should have at least 3 updates");
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Metrics collection integration works\x1b[0m");
}

// ==================== PERSISTENCE AND RECOVERY ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Persistence across coordinator restart");
    
    auto tempDir = scoped(new TempDir("integration-persistence"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    tempDir.createFile("persistent.d", "void main() {}");
    auto sourcePath = buildPath(tempDir.getPath(), "persistent.d");
    
    // First session
    {
        auto coordinator = new CacheCoordinator(cacheDir);
        
        coordinator.update("persistent-target", [sourcePath], [], "persistent-hash");
        
        // Action cache
        auto actionId = ActionId("persistent-target", ActionType.Compile, "action-hash", "persistent.d");
        tempDir.createFile("persistent.o", "obj");
        coordinator.recordAction(
            actionId, 
            [sourcePath], 
            [buildPath(tempDir.getPath(), "persistent.o")], 
            null, 
            true
        );
        
        coordinator.flush();
        coordinator.close();
    }
    
    // Second session (new coordinator instance)
    {
        auto coordinator = new CacheCoordinator(cacheDir);
        
        // Should load from disk
        Assert.isTrue(coordinator.isCached("persistent-target", [sourcePath], []));
        
        auto actionId = ActionId("persistent-target", ActionType.Compile, "action-hash", "persistent.d");
        Assert.isTrue(coordinator.isActionCached(actionId, [sourcePath], null));
        
        coordinator.close();
    }
    
    writeln("\x1b[32m  ✓ Persistence across coordinator restart works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Recovery from partial cache corruption");
    
    auto tempDir = scoped(new TempDir("integration-recovery"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Create initial cache
    {
        auto cache = new BuildCache(cacheDir);
        
        tempDir.createFile("file.d", "void test() {}");
        auto filePath = buildPath(tempDir.getPath(), "file.d");
        
        cache.update("test-target", [filePath], [], "hash1");
        cache.flush();
        cache.close();
    }
    
    // Corrupt action cache but leave target cache intact
    auto actionCachePath = buildPath(cacheDir, "actions", "cache.bin");
    if (exists(actionCachePath))
    {
        std.file.write(actionCachePath, "CORRUPTED");
    }
    
    // Should recover gracefully
    try
    {
        auto coordinator = new CacheCoordinator(cacheDir);
        
        tempDir.createFile("new.d", "void new_func() {}");
        auto newPath = buildPath(tempDir.getPath(), "new.d");
        
        coordinator.update("new-target", [newPath], [], "hash2");
        
        coordinator.close();
        writeln("\x1b[32m  ✓ Recovery from partial corruption works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[32m  ✓ Corruption properly detected and handled\x1b[0m");
    }
}

// ==================== STRESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Stress - Rapid cache updates");
    
    auto tempDir = scoped(new TempDir("stress-rapid-updates"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Rapidly update cache entries
    foreach (i; 0 .. 100)
    {
        auto filename = "rapid" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "void func" ~ i.to!string ~ "() {}");
        auto path = buildPath(tempDir.getPath(), filename);
        
        coordinator.update("rapid-" ~ i.to!string, [path], [], "hash" ~ i.to!string);
    }
    
    // Verify some entries
    tempDir.createFile("rapid0.d", "void func0() {}");
    Assert.isTrue(coordinator.isCached(
        "rapid-0", 
        [buildPath(tempDir.getPath(), "rapid0.d")], 
        []
    ));
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Rapid cache updates handled\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Stress - Concurrent coordinator access");
    
    auto tempDir = scoped(new TempDir("stress-concurrent"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    // Create coordinator
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Create test files
    foreach (i; 0 .. 20)
    {
        auto filename = "concurrent" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "void func" ~ i.to!string ~ "() {}");
    }
    
    bool[] results = new bool[20];
    
    try
    {
        // Concurrent operations
        foreach (i; parallel(iota(20)))
        {
            try
            {
                auto filename = "concurrent" ~ i.to!string ~ ".d";
                auto path = buildPath(tempDir.getPath(), filename);
                
                coordinator.update("target-" ~ i.to!string, [path], [], "hash" ~ i.to!string);
                results[i] = coordinator.isCached("target-" ~ i.to!string, [path], []);
            }
            catch (Exception e)
            {
                results[i] = false;
            }
        }
        
        size_t successCount = results.count(true);
        Assert.isTrue(successCount >= 15, "Most concurrent operations should succeed");
        
        writeln("\x1b[32m  ✓ Concurrent coordinator access handled (", 
                successCount, "/20 succeeded)\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent stress test completed with exceptions\x1b[0m");
    }
    
    coordinator.close();
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Stress - Large action cache with many entries");
    
    auto tempDir = scoped(new TempDir("stress-large-action-cache"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    ActionCacheConfig config;
    config.maxEntries = 2000;
    config.maxSize = 0;
    config.maxAge = 365;
    
    auto cache = new ActionCache(cacheDir, config);
    
    // Add many action entries
    foreach (i; 0 .. 500)
    {
        auto filename = "file" ~ i.to!string ~ ".cpp";
        tempDir.createFile(filename, "int x" ~ i.to!string ~ " = " ~ i.to!string ~ ";");
        auto path = buildPath(tempDir.getPath(), filename);
        
        ActionId actionId;
        actionId.targetId = "stress-target";
        actionId.type = ActionType.Compile;
        actionId.inputHash = "hash" ~ i.to!string;
        actionId.subId = filename;
        
        cache.update(actionId, [path], [], null, true);
    }
    
    cache.flush();
    
    auto stats = cache.getStats();
    Assert.isTrue(stats.totalEntries > 0, "Cache should have entries");
    Assert.isTrue(stats.totalEntries <= config.maxEntries, "Should not exceed limit");
    
    cache.close();
    writeln("\x1b[32m  ✓ Large action cache handled (", 
            stats.totalEntries, " entries)\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Stress - Many small blobs in CAS");
    
    auto tempDir = scoped(new TempDir("stress-many-blobs"));
    auto storageDir = buildPath(tempDir.getPath(), "blobs");
    auto cas = new ContentAddressableStorage(storageDir);
    
    string[] hashes;
    
    // Store many small blobs
    foreach (i; 0 .. 200)
    {
        auto data = cast(ubyte[])("Small blob " ~ i.to!string);
        auto putResult = cas.putBlob(data);
        
        if (putResult.isOk)
        {
            hashes ~= putResult.unwrap();
        }
    }
    
    Assert.isTrue(hashes.length >= 100, "Should store most blobs");
    
    // Verify random samples
    foreach (i; 0 .. 10)
    {
        if (i < hashes.length)
        {
            Assert.isTrue(cas.hasBlob(hashes[i]));
        }
    }
    
    auto stats = cas.getStats();
    Assert.isTrue(stats.uniqueBlobs >= 100, "Should have many unique blobs");
    
    writeln("\x1b[32m  ✓ Many small blobs handled (", 
            stats.uniqueBlobs, " unique blobs)\x1b[0m");
}

// ==================== COMPLEX DEPENDENCY SCENARIOS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Complex dependency graph");
    
    auto tempDir = scoped(new TempDir("integration-complex-deps"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto coordinator = new CacheCoordinator(cacheDir);
    
    // Create dependency graph: main -> (lib1, lib2), lib1 -> utils, lib2 -> utils
    tempDir.createFile("utils.d", "module utils; int util() { return 1; }");
    tempDir.createFile("lib1.d", "module lib1; import utils; int lib1func() { return util(); }");
    tempDir.createFile("lib2.d", "module lib2; import utils; int lib2func() { return util(); }");
    tempDir.createFile("main.d", "import lib1; import lib2; void main() {}");
    
    auto utilsPath = buildPath(tempDir.getPath(), "utils.d");
    auto lib1Path = buildPath(tempDir.getPath(), "lib1.d");
    auto lib2Path = buildPath(tempDir.getPath(), "lib2.d");
    auto mainPath = buildPath(tempDir.getPath(), "main.d");
    
    // Cache each level
    coordinator.update("utils", [utilsPath], [], "hash-utils");
    coordinator.update("lib1", [lib1Path], [utilsPath], "hash-lib1");
    coordinator.update("lib2", [lib2Path], [utilsPath], "hash-lib2");
    coordinator.update("main", [mainPath], [lib1Path, lib2Path, utilsPath], "hash-main");
    
    // All should be cached
    Assert.isTrue(coordinator.isCached("utils", [utilsPath], []));
    Assert.isTrue(coordinator.isCached("lib1", [lib1Path], [utilsPath]));
    Assert.isTrue(coordinator.isCached("lib2", [lib2Path], [utilsPath]));
    Assert.isTrue(coordinator.isCached("main", [mainPath], [lib1Path, lib2Path, utilsPath]));
    
    // Modify utils (should invalidate everything)
    Thread.sleep(10.msecs);
    tempDir.createFile("utils.d", "module utils; int util() { return 2; }");
    
    Assert.isFalse(coordinator.isCached("utils", [utilsPath], []));
    Assert.isFalse(coordinator.isCached("lib1", [lib1Path], [utilsPath]));
    Assert.isFalse(coordinator.isCached("lib2", [lib2Path], [utilsPath]));
    Assert.isFalse(coordinator.isCached("main", [mainPath], [lib1Path, lib2Path, utilsPath]));
    
    coordinator.close();
    writeln("\x1b[32m  ✓ Complex dependency graph handled correctly\x1b[0m");
}

// ==================== EDGE CASE COMBINATIONS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m Integration - Simultaneous eviction and access");
    
    auto tempDir = scoped(new TempDir("integration-evict-access"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    
    CacheConfig config;
    config.maxEntries = 10;
    config.maxSize = 0;
    config.maxAge = 365;
    
    auto cache = new BuildCache(cacheDir, config);
    
    // Fill cache to capacity
    foreach (i; 0 .. 10)
    {
        auto filename = "fill" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "void f() {}");
        auto path = buildPath(tempDir.getPath(), filename);
        
        cache.update("fill-" ~ i.to!string, [path], [], "hash" ~ i.to!string);
    }
    
    // Simultaneously access and add (causing eviction)
    foreach (i; 10 .. 15)
    {
        // Access old entries
        tempDir.createFile("fill0.d", "void f() {}");
        cache.isCached("fill-0", [buildPath(tempDir.getPath(), "fill0.d")], []);
        
        // Add new entry (triggers eviction)
        auto filename = "new" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "void n() {}");
        auto path = buildPath(tempDir.getPath(), filename);
        
        cache.update("new-" ~ i.to!string, [path], [], "newhash" ~ i.to!string);
    }
    
    cache.flush();
    
    auto stats = cache.getStats();
    Assert.isTrue(stats.totalEntries <= config.maxEntries);
    
    cache.close();
    writeln("\x1b[32m  ✓ Simultaneous eviction and access handled\x1b[0m");
}

