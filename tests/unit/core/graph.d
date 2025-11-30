module tests.unit.core.graph;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv : to, text;
import engine.graph.core.graph;
import infrastructure.config.schema.schema;
import tests.harness;
import tests.fixtures;
import infrastructure.errors;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Node creation and basic properties");
    
    auto target = TargetBuilder.create("test-target")
        .withType(TargetType.Executable)
        .withSources(["main.d"])
        .build();
    
    // Use TargetId constructor
    auto node = new BuildNode(TargetId("test-target"), target);
    
    Assert.equal(node.id.toString(), "test-target");
    Assert.equal(node.status, BuildStatus.Pending);
    Assert.isEmpty(node.dependencyIds);
    // Need a graph for depth calculation, even if empty
    Assert.equal(node.depth(new BuildGraph()), 0);
    
    writeln("\x1b[32m  ✓ Node creation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Dependency relationships");
    
    auto graph = new BuildGraph();
    
    auto target1 = TargetBuilder.create("lib").withType(TargetType.Library).build();
    auto target2 = TargetBuilder.create("app").withType(TargetType.Executable).build();
    
    graph.addTarget(target1);
    graph.addTarget(target2);
    auto result = graph.addDependency("app", "lib");
    Assert.isTrue(result.isOk);
    
    auto appNode = graph.nodes["app"];
    auto libNode = graph.nodes["lib"];
    
    Assert.equal(appNode.dependencyIds.length, 1);
    Assert.equal(appNode.dependencyIds[0].toString(), "lib");
    Assert.equal(libNode.dependentIds.length, 1);
    Assert.equal(libNode.dependentIds[0].toString(), "app");
    
    writeln("\x1b[32m  ✓ Dependencies link correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Topological sort");
    
    auto graph = new BuildGraph();
    
    // Create: lib1 <- app <- exe
    auto lib1 = TargetBuilder.create("lib1").build();
    auto app = TargetBuilder.create("app").build();
    auto exe = TargetBuilder.create("exe").build();
    
    graph.addTarget(lib1);
    graph.addTarget(app);
    graph.addTarget(exe);
    auto r1 = graph.addDependency("app", "lib1");
    auto r2 = graph.addDependency("exe", "app");
    Assert.isTrue(r1.isOk && r2.isOk);
    
    auto sortResult = graph.topologicalSort();
    Assert.isTrue(sortResult.isOk);
    auto sorted = sortResult.unwrap();
    
    Assert.equal(sorted.length, 3);
    
    // lib1 should come before app, app before exe
    auto lib1Idx = sorted.countUntil!(n => n.id.toString() == "lib1");
    auto appIdx = sorted.countUntil!(n => n.id.toString() == "app");
    auto exeIdx = sorted.countUntil!(n => n.id.toString() == "exe");
    
    Assert.isTrue(lib1Idx < appIdx);
    Assert.isTrue(appIdx < exeIdx);
    
    writeln("\x1b[32m  ✓ Topological sort produces correct order\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Cycle detection");
    
    auto graph = new BuildGraph();
    
    auto target1 = TargetBuilder.create("a").build();
    auto target2 = TargetBuilder.create("b").build();
    
    graph.addTarget(target1);
    graph.addTarget(target2);
    
    // Create cycle: a -> b -> a
    auto r1 = graph.addDependency("a", "b");
    Assert.isTrue(r1.isOk);
    
    // Cycle detection should return error
    auto cycleResult = graph.addDependency("b", "a");
    Assert.isTrue(cycleResult.isErr);
    
    writeln("\x1b[32m  ✓ Cycle detection prevents circular dependencies\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Node depth calculation");
    
    auto graph = new BuildGraph();
    
    // Create chain: a -> b -> c
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    auto r1 = graph.addDependency("b", "a");
    auto r2 = graph.addDependency("c", "b");
    Assert.isTrue(r1.isOk && r2.isOk);
    
    Assert.equal(graph.nodes["a"].depth(graph), 0);
    Assert.equal(graph.nodes["b"].depth(graph), 1);
    Assert.equal(graph.nodes["c"].depth(graph), 2);
    
    writeln("\x1b[32m  ✓ Node depth calculated correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Ready nodes detection");
    
    auto graph = new BuildGraph();
    
    auto lib = TargetBuilder.create("lib").build();
    auto app = TargetBuilder.create("app").build();
    
    graph.addTarget(lib);
    graph.addTarget(app);
    auto result = graph.addDependency("app", "lib");
    Assert.isTrue(result.isOk);
    
    // Initially only lib is ready
    auto ready1 = graph.getReadyNodes();
    Assert.equal(ready1.length, 1);
    Assert.equal(ready1[0].id.toString(), "lib");
    
    // After lib succeeds, app becomes ready
    graph.nodes["lib"].status = BuildStatus.Success;
    auto ready2 = graph.getReadyNodes();
    Assert.equal(ready2.length, 1);
    Assert.equal(ready2[0].id.toString(), "app");
    
    writeln("\x1b[32m  ✓ Ready nodes detected correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Graph statistics");
    
    auto graph = new BuildGraph();
    
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    auto r1 = graph.addDependency("b", "a");
    auto r2 = graph.addDependency("c", "a");
    Assert.isTrue(r1.isOk && r2.isOk);
    
    auto stats = graph.getStats();
    
    Assert.equal(stats.totalNodes, 3);
    Assert.equal(stats.totalEdges, 2);
    Assert.equal(stats.maxDepth, 1);
    Assert.equal(stats.parallelism, 2); // b and c can build in parallel
    
    writeln("\x1b[32m  ✓ Graph statistics calculated correctly\x1b[0m");
}

// ==================== ADVANCED GRAPH TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Complex cycle detection (indirect)");
    
    auto graph = new BuildGraph();
    
    // Create chain: a -> b -> c -> a (indirect cycle)
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    
    auto r1 = graph.addDependency("a", "b");
    auto r2 = graph.addDependency("b", "c");
    Assert.isTrue(r1.isOk && r2.isOk);
    
    // This should detect the cycle through the chain
    auto cycleResult = graph.addDependency("c", "a");
    Assert.isTrue(cycleResult.isErr);
    
    writeln("\x1b[32m  ✓ Indirect cycle detection works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Self-dependency detection");
    
    auto graph = new BuildGraph();
    auto target = TargetBuilder.create("self").build();
    graph.addTarget(target);
    
    // Self-dependency should be detected
    auto selfDepResult = graph.addDependency("self", "self");
    Assert.isTrue(selfDepResult.isErr);
    
    writeln("\x1b[32m  ✓ Self-dependency prevented\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Diamond dependency pattern");
    
    auto graph = new BuildGraph();
    
    //     top
    //    /   \
    //   left right
    //    \   /
    //    bottom
    auto top = TargetBuilder.create("top").build();
    auto left = TargetBuilder.create("left").build();
    auto right = TargetBuilder.create("right").build();
    auto bottom = TargetBuilder.create("bottom").build();
    
    graph.addTarget(top);
    graph.addTarget(left);
    graph.addTarget(right);
    graph.addTarget(bottom);
    
    graph.addDependency("top", "left").unwrap();
    graph.addDependency("top", "right").unwrap();
    graph.addDependency("left", "bottom").unwrap();
    graph.addDependency("right", "bottom").unwrap();
    
    auto sorted = graph.topologicalSort().unwrap();
    
    // bottom must come before both left and right
    // left and right must come before top
    auto bottomIdx = sorted.countUntil!(n => n.id.toString() == "bottom");
    auto leftIdx = sorted.countUntil!(n => n.id.toString() == "left");
    auto rightIdx = sorted.countUntil!(n => n.id.toString() == "right");
    auto topIdx = sorted.countUntil!(n => n.id.toString() == "top");
    
    Assert.isTrue(bottomIdx < leftIdx);
    Assert.isTrue(bottomIdx < rightIdx);
    Assert.isTrue(leftIdx < topIdx);
    Assert.isTrue(rightIdx < topIdx);
    
    writeln("\x1b[32m  ✓ Diamond dependency pattern handled correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Disconnected components");
    
    auto graph = new BuildGraph();
    
    // Create two disconnected chains
    auto a1 = TargetBuilder.create("a1").build();
    auto a2 = TargetBuilder.create("a2").build();
    auto b1 = TargetBuilder.create("b1").build();
    auto b2 = TargetBuilder.create("b2").build();
    
    graph.addTarget(a1);
    graph.addTarget(a2);
    graph.addTarget(b1);
    graph.addTarget(b2);
    
    graph.addDependency("a2", "a1").unwrap();
    graph.addDependency("b2", "b1").unwrap();
    
    auto sorted = graph.topologicalSort().unwrap();
    Assert.equal(sorted.length, 4);
    
    // Within each chain, order must be preserved
    auto a1Idx = sorted.countUntil!(n => n.id.toString() == "a1");
    auto a2Idx = sorted.countUntil!(n => n.id.toString() == "a2");
    auto b1Idx = sorted.countUntil!(n => n.id.toString() == "b1");
    auto b2Idx = sorted.countUntil!(n => n.id.toString() == "b2");
    
    Assert.isTrue(a1Idx < a2Idx);
    Assert.isTrue(b1Idx < b2Idx);
    
    writeln("\x1b[32m  ✓ Disconnected components sorted correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Deep dependency chain");
    
    auto graph = new BuildGraph();
    
    // Create chain of depth 10
    enum depth = 10;
    foreach (i; 0 .. depth)
    {
        auto target = TargetBuilder.create("level" ~ i.to!string).build();
        graph.addTarget(target);
        
        if (i > 0)
        {
            graph.addDependency("level" ~ i.to!string, "level" ~ (i-1).to!string).unwrap();
        }
    }
    
    auto sorted = graph.topologicalSort().unwrap();
    Assert.equal(sorted.length, depth);
    
    // Verify each level comes after the previous
    foreach (i; 1 .. depth)
    {
        auto prevIdx = sorted.countUntil!(n => n.id.toString() == "level" ~ (i-1).to!string);
        auto currIdx = sorted.countUntil!(n => n.id.toString() == "level" ~ i.to!string);
        Assert.isTrue(prevIdx < currIdx);
    }
    
    // Verify depth calculation
    Assert.equal(graph.nodes["level0"].depth(graph), 0);
    Assert.equal(graph.nodes["level9"].depth(graph), 9);
    
    writeln("\x1b[32m  ✓ Deep dependency chain handled correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Wide parallelism detection");
    
    auto graph = new BuildGraph();
    
    // Create 10 independent targets (max parallelism = 10)
    foreach (i; 0 .. 10)
    {
        auto target = TargetBuilder.create("parallel" ~ i.to!string).build();
        graph.addTarget(target);
    }
    
    auto stats = graph.getStats();
    Assert.equal(stats.totalNodes, 10);
    Assert.equal(stats.totalEdges, 0);
    Assert.equal(stats.maxDepth, 0);
    Assert.equal(stats.parallelism, 10); // All can build in parallel
    
    writeln("\x1b[32m  ✓ Wide parallelism detected correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Multiple dependency paths");
    
    auto graph = new BuildGraph();
    
    // Create: a -> b -> c
    //         a -----> c (direct dependency too)
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    
    graph.addDependency("a", "b").unwrap();
    graph.addDependency("b", "c").unwrap();
    graph.addDependency("a", "c").unwrap(); // Redundant but valid
    
    auto sorted = graph.topologicalSort().unwrap();
    
    // Should still produce valid order
    auto cIdx = sorted.countUntil!(n => n.id.toString() == "c");
    auto bIdx = sorted.countUntil!(n => n.id.toString() == "b");
    auto aIdx = sorted.countUntil!(n => n.id.toString() == "a");
    
    Assert.isTrue(cIdx < bIdx);
    Assert.isTrue(bIdx < aIdx);
    
    writeln("\x1b[32m  ✓ Multiple dependency paths handled correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Get roots with dependencies");
    
    auto graph = new BuildGraph();
    
    auto lib1 = TargetBuilder.create("lib1").build();
    auto lib2 = TargetBuilder.create("lib2").build();
    auto app = TargetBuilder.create("app").build();
    
    graph.addTarget(lib1);
    graph.addTarget(lib2);
    graph.addTarget(app);
    
    graph.addDependency("app", "lib1").unwrap();
    graph.addDependency("app", "lib2").unwrap();
    
    auto roots = graph.getRoots();
    Assert.equal(roots.length, 2);
    
    auto rootIds = roots.map!(n => n.id.toString()).array.sort.array;
    Assert.equal(rootIds, ["lib1", "lib2"]);
    
    writeln("\x1b[32m  ✓ Root node identification works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Ready nodes after partial build");
    
    auto graph = new BuildGraph();
    
    // Create: lib1 -> app -> exe
    //         lib2 /
    auto lib1 = TargetBuilder.create("lib1").build();
    auto lib2 = TargetBuilder.create("lib2").build();
    auto app = TargetBuilder.create("app").build();
    auto exe = TargetBuilder.create("exe").build();
    
    graph.addTarget(lib1);
    graph.addTarget(lib2);
    graph.addTarget(app);
    graph.addTarget(exe);
    
    graph.addDependency("app", "lib1").unwrap();
    graph.addDependency("app", "lib2").unwrap();
    graph.addDependency("exe", "app").unwrap();
    
    // Initially, both libs are ready
    auto ready1 = graph.getReadyNodes();
    Assert.equal(ready1.length, 2);
    
    // After lib1 succeeds, app still not ready (needs lib2)
    graph.nodes["lib1"].status = BuildStatus.Success;
    auto ready2 = graph.getReadyNodes();
    Assert.equal(ready2.length, 1);
    Assert.equal(ready2[0].id.toString(), "lib2");
    
    // After lib2 succeeds, app becomes ready
    graph.nodes["lib2"].status = BuildStatus.Success;
    auto ready3 = graph.getReadyNodes();
    Assert.equal(ready3.length, 1);
    Assert.equal(ready3[0].id.toString(), "app");
    
    // After app succeeds, exe becomes ready
    graph.nodes["app"].status = BuildStatus.Success;
    auto ready4 = graph.getReadyNodes();
    Assert.equal(ready4.length, 1);
    Assert.equal(ready4[0].id.toString(), "exe");
    
    writeln("\x1b[32m  ✓ Ready nodes tracking through build process works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Cached status satisfies dependencies");
    
    auto graph = new BuildGraph();
    
    auto lib = TargetBuilder.create("lib").build();
    auto app = TargetBuilder.create("app").build();
    
    graph.addTarget(lib);
    graph.addTarget(app);
    graph.addDependency("app", "lib").unwrap();
    
    // Set lib as cached (not built, but valid)
    graph.nodes["lib"].status = BuildStatus.Cached;
    
    // App should be ready since cached satisfies dependencies
    auto ready = graph.getReadyNodes();
    Assert.equal(ready.length, 1);
    Assert.equal(ready[0].id.toString(), "app");
    
    writeln("\x1b[32m  ✓ Cached status correctly satisfies dependencies\x1b[0m");
}

// ==================== PERFORMANCE OPTIMIZATION TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Deferred validation mode");
    
    // Create graph with deferred validation
    auto graph = new BuildGraph(ValidationMode.Deferred);
    
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    
    // Add dependencies without cycle checks
    auto r1 = graph.addDependency("a", "b");
    auto r2 = graph.addDependency("b", "c");
    Assert.isTrue(r1.isOk && r2.isOk);
    
    // Graph not validated yet
    Assert.isFalse(graph.isValidated());
    
    // Adding cycle doesn't fail immediately in deferred mode
    auto r3 = graph.addDependency("c", "a");
    Assert.isTrue(r3.isOk); // No immediate cycle detection
    
    // But validation catches it
    auto validateResult = graph.validate();
    Assert.isTrue(validateResult.isErr);
    
    writeln("\x1b[32m  ✓ Deferred validation detects cycles at validation time\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Deferred validation with valid graph");
    
    auto graph = new BuildGraph(ValidationMode.Deferred);
    
    // Create: a -> b -> c (valid chain)
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    
    graph.addDependency("a", "b").unwrap();
    graph.addDependency("b", "c").unwrap();
    
    // Validate should succeed
    auto validateResult = graph.validate();
    Assert.isTrue(validateResult.isOk);
    Assert.isTrue(graph.isValidated());
    
    // Topological sort should work
    auto sorted = graph.topologicalSort().unwrap();
    Assert.equal(sorted.length, 3);
    
    writeln("\x1b[32m  ✓ Deferred validation succeeds for valid graph\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Immediate mode backward compatibility");
    
    // Default mode is Immediate for backward compatibility
    auto graph = new BuildGraph();
    
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    
    // Create cycle: a -> b -> a
    auto r1 = graph.addDependency("a", "b");
    Assert.isTrue(r1.isOk);
    
    // Immediate mode detects cycle right away
    auto cycleResult = graph.addDependency("b", "a");
    Assert.isTrue(cycleResult.isErr);
    
    // Graph is always considered validated in immediate mode
    Assert.isTrue(graph.isValidated());
    
    writeln("\x1b[32m  ✓ Immediate mode maintains backward compatibility\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Depth memoization correctness");
    
    auto graph = new BuildGraph();
    
    // Create chain: a -> b -> c -> d -> e (depth 4)
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    auto d = TargetBuilder.create("d").build();
    auto e = TargetBuilder.create("e").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    graph.addTarget(d);
    graph.addTarget(e);
    
    graph.addDependency("a", "b").unwrap();
    graph.addDependency("b", "c").unwrap();
    graph.addDependency("c", "d").unwrap();
    graph.addDependency("d", "e").unwrap();
    
    // First call computes depth
    auto depth1 = graph.nodes["a"].depth(graph);
    Assert.equal(depth1, 4);
    
    // Second call uses cached value (should be instant)
    auto depth2 = graph.nodes["a"].depth(graph);
    Assert.equal(depth2, 4);
    
    // All nodes should have correct depth
    Assert.equal(graph.nodes["e"].depth(graph), 0);
    Assert.equal(graph.nodes["d"].depth(graph), 1);
    Assert.equal(graph.nodes["c"].depth(graph), 2);
    Assert.equal(graph.nodes["b"].depth(graph), 3);
    Assert.equal(graph.nodes["a"].depth(graph), 4);
    
    writeln("\x1b[32m  ✓ Depth memoization produces correct results\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Depth cache invalidation");
    
    auto graph = new BuildGraph();
    
    // Create: a -> b, b -> c
    auto a = TargetBuilder.create("a").build();
    auto b = TargetBuilder.create("b").build();
    auto c = TargetBuilder.create("c").build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    
    graph.addDependency("a", "b").unwrap();
    graph.addDependency("b", "c").unwrap();
    
    // Cache depths
    Assert.equal(graph.nodes["a"].depth(graph), 2);
    Assert.equal(graph.nodes["b"].depth(graph), 1);
    
    // Add new dependency: a -> c (shortcut)
    graph.addDependency("a", "c").unwrap();
    
    // Depth should still be correct (cached or recomputed)
    Assert.equal(graph.nodes["a"].depth(graph), 2); // max(b.depth, c.depth) + 1
    
    writeln("\x1b[32m  ✓ Depth cache invalidation maintains correctness\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Large graph performance (deferred)");
    
    import std.datetime.stopwatch;
    
    auto graph = new BuildGraph(ValidationMode.Deferred);
    
    // Create a large chain: 0 -> 1 -> 2 -> ... -> 99
    enum size = 100;
    foreach (i; 0 .. size)
    {
        auto target = TargetBuilder.create("node" ~ i.to!string).build();
        graph.addTarget(target);
    }
    
    auto sw = StopWatch(AutoStart.yes);
    
    // Add all dependencies (O(E) with deferred validation)
    foreach (i; 1 .. size)
    {
        graph.addDependency("node" ~ i.to!string, "node" ~ (i-1).to!string).unwrap();
    }
    
    sw.stop();
    auto buildTime = sw.peek().total!"msecs";
    
    // Validate once (O(V+E))
    sw.reset();
    sw.start();
    auto validateResult = graph.validate();
    sw.stop();
    auto validateTime = sw.peek().total!"msecs";
    
    Assert.isTrue(validateResult.isOk);
    
    // With deferred mode, building should be very fast
    // Validation time should also be reasonable (single pass)
    writeln("    Build time: ", buildTime, "ms, Validation time: ", validateTime, "ms");
    Assert.isTrue(buildTime < 100); // Should be < 100ms even on slow machines
    
    // Verify depth calculation is also fast with memoization
    sw.reset();
    sw.start();
    auto maxDepth = graph.nodes["node99"].depth(graph);
    sw.stop();
    auto depthTime = sw.peek().total!"msecs";
    
    Assert.equal(maxDepth, 99);
    writeln("    Depth calculation time: ", depthTime, "ms");
    
    writeln("\x1b[32m  ✓ Large graph performance with deferred validation is optimal\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m core.graph - Diamond with memoization");
    
    auto graph = new BuildGraph();
    
    //     top
    //    /   \
    //   left right
    //    \   /
    //    bottom
    auto top = TargetBuilder.create("top").build();
    auto left = TargetBuilder.create("left").build();
    auto right = TargetBuilder.create("right").build();
    auto bottom = TargetBuilder.create("bottom").build();
    
    graph.addTarget(top);
    graph.addTarget(left);
    graph.addTarget(right);
    graph.addTarget(bottom);
    
    graph.addDependency("top", "left").unwrap();
    graph.addDependency("top", "right").unwrap();
    graph.addDependency("left", "bottom").unwrap();
    graph.addDependency("right", "bottom").unwrap();
    
    // Depth should be computed efficiently with memoization
    // bottom is shared, so its depth should only be computed once
    Assert.equal(graph.nodes["bottom"].depth(graph), 0);
    Assert.equal(graph.nodes["left"].depth(graph), 1);
    Assert.equal(graph.nodes["right"].depth(graph), 1);
    Assert.equal(graph.nodes["top"].depth(graph), 2);
    
    writeln("\x1b[32m  ✓ Diamond dependencies with memoization work correctly\x1b[0m");
}
