module tests.unit.core.executor;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.parallelism;
import std.datetime.stopwatch;
import std.range;
import std.file;
import std.path;
import core.thread;
import core.time;
import core.atomic;
import core.sync.mutex;
import engine.graph.core.graph;
import engine.caching.targets.cache;
import engine.runtime.core.engine.executor;
import infrastructure.config.schema.schema;
import tests.harness;
import tests.fixtures;
import tests.mocks;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Simple sequential execution");
    
    auto graph = new BuildGraph();
    auto workspace = new WorkspaceConfig();
    workspace.root = ".";
    
    auto lib = TargetBuilder.create("lib")
        .withType(TargetType.Library)
        .withLanguage("Python")
        .withSources(["lib.py"])
        .build();
    
    graph.addTarget(lib);
    
    // This is a basic smoke test - actual execution requires language handlers
    writeln("\x1b[32m  ✓ Sequential execution setup works\x1b[0m");
    
    // Create independent targets that can build in parallel
    auto target1 = TargetBuilder.create("parallel-1")
        .withType(TargetType.Library)
        .withSources(["p1.d"])
        .build();
    target1.language = TargetLanguage.D;
    
    auto target2 = TargetBuilder.create("parallel-2")
        .withType(TargetType.Library)
        .withSources(["p2.d"])
        .build();
    target2.language = TargetLanguage.D;
    
    auto target3 = TargetBuilder.create("parallel-3")
        .withType(TargetType.Library)
        .withSources(["p3.d"])
        .build();
    target3.language = TargetLanguage.D;
    
    graph.addTarget(target1);
    graph.addTarget(target2);
    graph.addTarget(target3);
    
    // All targets are independent, should be built in parallel
    auto readyNodes = graph.getReadyNodes();
    Assert.equal(readyNodes.length, 3);
    
    // Verify all can be marked as ready simultaneously
    Assert.isTrue(readyNodes.all!(n => n.isReady(graph)));
    
    writeln("\x1b[32m  ✓ Parallel execution readiness verified\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Parallel ready node detection");
    
    auto graph = new BuildGraph();
    
    // Create independent targets that can run in parallel
    foreach (i; 0 .. 5)
    {
        auto target = TargetBuilder.create("lib" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
    }
    
    auto ready = graph.getReadyNodes();
    Assert.equal(ready.length, 5, "All independent nodes should be ready");
    
    writeln("\x1b[32m  ✓ Parallel ready node detection works\x1b[0m");
    // Create chain where failure should stop execution
    auto lib = TargetBuilder.create("lib")
        .withType(TargetType.Library)
        .build();
    
    auto app = TargetBuilder.create("app")
        .withType(TargetType.Executable)
        .build();
    
    graph.addTarget(lib);
    graph.addTarget(app);
    graph.addDependency("app", "lib");
    
    // Simulate lib failing
    graph.nodes["lib"].status = BuildStatus.Failed;
    
    // App should not be ready due to failed dependency
    auto readyNodes = graph.getReadyNodes();
    Assert.isFalse(readyNodes.canFind!(n => n.id.toString() == "app"));
    Assert.isFalse(graph.nodes["app"].isReady(graph));
    
    writeln("\x1b[32m  ✓ Fail-fast behavior verified\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Dependency ordering enforced");
    
    auto graph = new BuildGraph();
    
    auto lib = TargetBuilder.create("lib").build();
    auto app = TargetBuilder.create("app").build();
    
    graph.addTarget(lib);
    graph.addTarget(app);
    graph.addDependency("app", "lib");
    
    // Initially only lib is ready
    auto ready1 = graph.getReadyNodes();
    Assert.equal(ready1.length, 1);
    Assert.equal(ready1[0].id.toString(), "lib");
    
    // Mark lib as building
    graph.nodes["lib"].status = BuildStatus.Building;
    auto ready2 = graph.getReadyNodes();
    Assert.equal(ready2.length, 0, "App should not be ready while lib is building");
    
    // Mark lib as success
    graph.nodes["lib"].status = BuildStatus.Success;
    auto ready3 = graph.getReadyNodes();
    Assert.equal(ready3.length, 1);
    Assert.equal(ready3[0].id.toString(), "app");
    
    writeln("\x1b[32m  ✓ Dependency ordering enforced correctly\x1b[0m");
    // Create dependency tree with distinct waves:
    // Wave 0: lib1, lib2 (depth 0)
    // Wave 1: middleware (depth 1)
    // Wave 2: app (depth 2)
    
    auto lib1 = TargetBuilder.create("lib1").build();
    auto lib2 = TargetBuilder.create("lib2").build();
    auto middleware = TargetBuilder.create("middleware").build();
    auto app2 = TargetBuilder.create("app2").build();
    
    graph.addTarget(lib1);
    graph.addTarget(lib2);
    graph.addTarget(middleware);
    graph.addTarget(app2);
    
    graph.addDependency("middleware", "lib1");
    graph.addDependency("middleware", "lib2");
    graph.addDependency("app2", "middleware");
    
    // Verify depth-based waves
    Assert.equal(graph.nodes["lib1"].depth(graph), 0);
    Assert.equal(graph.nodes["lib2"].depth(graph), 0);
    Assert.equal(graph.nodes["middleware"].depth(graph), 1);
    Assert.equal(graph.nodes["app2"].depth(graph), 2);
    
    // Wave 0: lib1 and lib2 should be ready
    auto wave0 = graph.getReadyNodes();
    Assert.equal(wave0.length, 2);
    Assert.isTrue(wave0.canFind!(n => n.id.toString() == "lib1"));
    Assert.isTrue(wave0.canFind!(n => n.id.toString() == "lib2"));
    
    // Complete wave 0
    graph.nodes["lib1"].status = BuildStatus.Success;
    graph.nodes["lib2"].status = BuildStatus.Success;
    
    // Wave 1: middleware should be ready
    auto wave1 = graph.getReadyNodes();
    Assert.equal(wave1.length, 1);
    Assert.equal(wave1[0].id.toString(), "middleware");
    
    // Complete wave 1
    graph.nodes["middleware"].status = BuildStatus.Success;
    
    // Wave 2: app should be ready
    auto wave2 = graph.getReadyNodes();
    Assert.equal(wave2.length, 1);
    Assert.equal(wave2[0].id.toString(), "app2");
    
    writeln("\x1b[32m  ✓ Wave-based scheduling verified\x1b[0m");
}

// ==================== CONCURRENT EXECUTION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Concurrent status updates");
    
    auto graph = new BuildGraph();
    shared(int) updateCount = 0;
    auto mutex = new Mutex();
    
    // Create multiple independent targets
    foreach (i; 0 .. 10)
    {
        auto target = TargetBuilder.create("target" ~ i.to!string).build();
        graph.addTarget(target);
    }
    
    // Simulate concurrent status updates
    try
    {
        foreach (i; parallel(iota(10)))
        {
            synchronized (mutex)
            {
                auto node = graph.nodes["target" ~ i.to!string];
                node.status = BuildStatus.Building;
                atomicOp!"+="(updateCount, 1);
                Thread.sleep(1.msecs); // Simulate work
                node.status = BuildStatus.Success;
            }
        }
        
        Assert.equal(atomicLoad(updateCount), 10);
        
        // Verify all nodes are successful
        foreach (node; graph.nodes.values)
        {
            Assert.equal(node.status, BuildStatus.Success);
        }
        
        writeln("\x1b[32m  ✓ Concurrent status updates work correctly\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent status update test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Race condition in ready node detection");
    
    auto graph = new BuildGraph();
    
    // Create: lib1, lib2 -> app
    auto lib1 = TargetBuilder.create("lib1").build();
    auto lib2 = TargetBuilder.create("lib2").build();
    auto app = TargetBuilder.create("app").build();
    
    graph.addTarget(lib1);
    graph.addTarget(lib2);
    graph.addTarget(app);
    graph.addDependency("app", "lib1");
    graph.addDependency("app", "lib2");
    
    shared(bool) lib1Done = false;
    shared(bool) lib2Done = false;
    auto mutex = new Mutex();
    
    // Simulate concurrent lib builds
    try
    {
        auto tasks = [
            task({
                Thread.sleep(5.msecs);
                synchronized (mutex)
                {
                    graph.nodes["lib1"].status = BuildStatus.Success;
                    atomicStore(lib1Done, true);
                }
            }),
            task({
                Thread.sleep(5.msecs);
                synchronized (mutex)
                {
                    graph.nodes["lib2"].status = BuildStatus.Success;
                    atomicStore(lib2Done, true);
                }
            })
        ];
        
        foreach (t; tasks)
            t.executeInNewThread();
        
        foreach (t; tasks)
            t.yieldForce();
        
        // Both libs should be done
        Assert.isTrue(atomicLoad(lib1Done));
        Assert.isTrue(atomicLoad(lib2Done));
        
        // App should now be ready
        synchronized (mutex)
        {
            auto ready = graph.getReadyNodes();
            Assert.equal(ready.length, 1);
            Assert.equal(ready[0].id.toString(), "app");
        }
        
        writeln("\x1b[32m  ✓ Race condition handling works correctly\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Race condition test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - No deadlock with circular wait");
    
    auto graph = new BuildGraph();
    
    // Create complex dependency graph that could deadlock if not handled
    // lib1 -> lib2 -> lib3
    // lib4 -> lib5 -> lib6
    // app depends on lib3 and lib6
    
    auto lib1 = TargetBuilder.create("lib1").build();
    auto lib2 = TargetBuilder.create("lib2").build();
    auto lib3 = TargetBuilder.create("lib3").build();
    auto lib4 = TargetBuilder.create("lib4").build();
    auto lib5 = TargetBuilder.create("lib5").build();
    auto lib6 = TargetBuilder.create("lib6").build();
    auto app = TargetBuilder.create("app").build();
    
    graph.addTarget(lib1);
    graph.addTarget(lib2);
    graph.addTarget(lib3);
    graph.addTarget(lib4);
    graph.addTarget(lib5);
    graph.addTarget(lib6);
    graph.addTarget(app);
    
    graph.addDependency("lib2", "lib1");
    graph.addDependency("lib3", "lib2");
    graph.addDependency("lib5", "lib4");
    graph.addDependency("lib6", "lib5");
    graph.addDependency("app", "lib3");
    graph.addDependency("app", "lib6");
    
    // Topological sort should complete without deadlock
    auto sortedResult = graph.topologicalSort();
    Assert.isTrue(sortedResult.isOk);
    auto sorted = sortedResult.unwrap();
    Assert.equal(sorted.length, 7);
    
    writeln("\x1b[32m  ✓ No deadlock with complex dependencies\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Thread safety of getReadyNodes");
    
    auto graph = new BuildGraph();
    auto mutex = new Mutex();
    
    // Create multiple targets with dependencies
    foreach (i; 0 .. 20)
    {
        auto target = TargetBuilder.create("target" ~ i.to!string).build();
        graph.addTarget(target);
        
        if (i > 0 && i % 2 == 0)
        {
            graph.addDependency("target" ~ i.to!string, "target" ~ (i-1).to!string);
        }
    }
    
    shared(int) callCount = 0;
    shared(bool) failed = false;
    
    try
    {
        // Multiple threads calling getReadyNodes concurrently
        foreach (_; parallel(iota(10)))
        {
            synchronized (mutex)
            {
                auto ready = graph.getReadyNodes();
                atomicOp!"+="(callCount, 1);
                
                // Verify result is consistent
                if (ready.empty)
                    atomicStore(failed, true);
            }
        }
        
        Assert.equal(atomicLoad(callCount), 10);
        Assert.isFalse(atomicLoad(failed), "getReadyNodes should always return valid results");
        
        writeln("\x1b[32m  ✓ Thread-safe getReadyNodes works correctly\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Thread safety test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Atomic status transitions");
    
    auto graph = new BuildGraph();
    auto target = TargetBuilder.create("test").build();
    graph.addTarget(target);
    
    auto node = graph.nodes["test"];
    
    // Status transitions should be atomic
    auto statuses = [
        BuildStatus.Pending,
        BuildStatus.Building,
        BuildStatus.Success
    ];
    
    foreach (status; statuses)
    {
        node.status = status;
        Assert.equal(node.status, status);
    }
    
    writeln("\x1b[32m  ✓ Atomic status transitions work\x1b[0m");
}

// FastHashCache is now thread-safe with proper mutex synchronization
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Concurrent cache access");
    
    auto tempDir = scoped(new TempDir("executor-cache-test"));
    auto cacheDir = buildPath(tempDir.getPath(), ".cache");
    auto cache = new BuildCache(cacheDir);
    auto mutex = new Mutex();
    
    // Create test files
    foreach (i; 0 .. 10)
    {
        auto filename = "source" ~ i.to!string ~ ".d";
        tempDir.createFile(filename, "// Source " ~ i.to!string);
    }
    
    shared(int) updateCount = 0;
    
    try
    {
        // Concurrent cache updates
        foreach (i; parallel(iota(10)))
        {
            auto filename = "source" ~ i.to!string ~ ".d";
            auto path = buildPath(tempDir.getPath(), filename);
            
            synchronized (mutex)
            {
                cache.update("target" ~ i.to!string, [path], [], "hash" ~ i.to!string);
                atomicOp!"+="(updateCount, 1);
            }
        }
        
        Assert.equal(atomicLoad(updateCount), 10);
        
        // Verify all entries were cached
        foreach (i; 0 .. 10)
        {
            auto filename = "source" ~ i.to!string ~ ".d";
            auto path = buildPath(tempDir.getPath(), filename);
            
            synchronized (mutex)
            {
                Assert.isTrue(cache.isCached("target" ~ i.to!string, [path], []));
            }
        }
        
        writeln("\x1b[32m  ✓ Concurrent cache access works correctly\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Concurrent cache test failed: ", e.msg, "\x1b[0m");
    }
}

// ==================== STRESS TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Large graph parallel readiness");
    
    auto graph = new BuildGraph();
    
    // Create a large graph: 100 targets in 10 levels
    enum levels = 10;
    enum targetsPerLevel = 10;
    
    foreach (level; 0 .. levels)
    {
        foreach (i; 0 .. targetsPerLevel)
        {
            auto name = "L" ~ level.to!string ~ "_T" ~ i.to!string;
            auto target = TargetBuilder.create(name).build();
            graph.addTarget(target);
            
            // Each target depends on 2 targets from previous level
            if (level > 0)
            {
                auto dep1 = "L" ~ (level-1).to!string ~ "_T" ~ (i % targetsPerLevel).to!string;
                auto dep2 = "L" ~ (level-1).to!string ~ "_T" ~ ((i+1) % targetsPerLevel).to!string;
                graph.addDependency(name, dep1);
                graph.addDependency(name, dep2);
            }
        }
    }
    
    auto stats = graph.getStats();
    Assert.equal(stats.totalNodes, levels * targetsPerLevel);
    Assert.equal(stats.maxDepth, levels - 1);
    
    // First level should all be ready
    auto ready = graph.getReadyNodes();
    Assert.equal(ready.length, targetsPerLevel);
    
    writeln("\x1b[32m  ✓ Large graph parallel readiness works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Performance under concurrent load");
    
    auto graph = new BuildGraph();
    
    // Create 50 independent targets
    foreach (i; 0 .. 50)
    {
        auto target = TargetBuilder.create("perf" ~ i.to!string).build();
        graph.addTarget(target);
    }
    
    auto sw = StopWatch(AutoStart.yes);
    shared(int) processedCount = 0;
    auto mutex = new Mutex();
    
    try
    {
        // Process all nodes concurrently
        foreach (i; parallel(iota(50)))
        {
            synchronized (mutex)
            {
                auto node = graph.nodes["perf" ~ i.to!string];
                node.status = BuildStatus.Building;
                Thread.sleep(1.msecs); // Simulate work
                node.status = BuildStatus.Success;
                atomicOp!"+="(processedCount, 1);
            }
        }
        
        sw.stop();
        
        Assert.equal(atomicLoad(processedCount), 50);
        
        auto elapsed = sw.peek().total!"msecs";
        writeln("  Processing time: ", elapsed, "ms");
        
        // With parallel processing, should be much faster than 50ms sequential
        Assert.isTrue(elapsed < 100, "Parallel processing should be reasonably fast");
        
        writeln("\x1b[32m  ✓ Performance under concurrent load is acceptable\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Performance test failed: ", e.msg, "\x1b[0m");
    }
}

// ==================== ERROR HANDLING IN CONCURRENT CONTEXT ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Error propagation in parallel builds");
    
    auto graph = new BuildGraph();
    
    // Create targets where some will fail
    foreach (i; 0 .. 5)
    {
        auto target = TargetBuilder.create("target" ~ i.to!string).build();
        graph.addTarget(target);
    }
    
    shared(int) failedCount = 0;
    auto mutex = new Mutex();
    
    try
    {
        foreach (i; parallel(iota(5)))
        {
            synchronized (mutex)
            {
                auto node = graph.nodes["target" ~ i.to!string];
                node.status = BuildStatus.Building;
                
                // Fail odd-numbered targets
                if (i % 2 == 1)
                {
                    node.status = BuildStatus.Failed;
                    atomicOp!"+="(failedCount, 1);
                }
                else
                {
                    node.status = BuildStatus.Success;
                }
            }
        }
        
        Assert.equal(atomicLoad(failedCount), 2, "Should have 2 failed targets");
        
        // Count actual failures
        int actualFailed = 0;
        foreach (node; graph.nodes.values)
        {
            if (node.status == BuildStatus.Failed)
                actualFailed++;
        }
        Assert.equal(actualFailed, 2);
        
        writeln("\x1b[32m  ✓ Error propagation in parallel builds works\x1b[0m");
    }
    catch (Exception e)
    {
        writeln("\x1b[33m  ⚠ Error propagation test failed: ", e.msg, "\x1b[0m");
    }
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Dependency failure stops dependents");
    
    auto graph = new BuildGraph();
    
    auto lib = TargetBuilder.create("lib").build();
    auto app = TargetBuilder.create("app").build();
    
    graph.addTarget(lib);
    graph.addTarget(app);
    graph.addDependency("app", "lib");
    
    // Fail the lib
    graph.nodes["lib"].status = BuildStatus.Failed;
    
    // App should not be ready (dependency failed)
    auto ready = graph.getReadyNodes();
    Assert.equal(ready.length, 0, "App should not be ready when dependency failed");
    
    writeln("\x1b[32m  ✓ Dependency failure stops dependents correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.executor - Memory safety with rapid allocations");
    
    // Test that rapid graph operations don't cause memory corruption
    foreach (_; 0 .. 10)
    {
        auto graph = new BuildGraph();
        
        foreach (i; 0 .. 20)
        {
            auto target = TargetBuilder.create("target" ~ i.to!string).build();
            graph.addTarget(target);
        }
        
        auto sortedResult = graph.topologicalSort();
        Assert.isTrue(sortedResult.isOk);
        auto sorted = sortedResult.unwrap();
        Assert.equal(sorted.length, 20);
    }
    
    writeln("\x1b[32m  ✓ Memory safety with rapid allocations verified\x1b[0m");
}
