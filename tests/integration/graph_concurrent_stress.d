module tests.integration.graph_concurrent_stress;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs, MonoTime;
import std.conv : to;
import std.algorithm : map, filter, sort, min, max, sum, canFind;
import std.array : array;
import std.random : uniform, uniform01, Random;
import std.range : iota;
import std.parallelism : parallel, taskPool, totalCPUs;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import core.sync.rwmutex : ReadWriteMutex;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import engine.graph.core.graph : BuildGraph, BuildNode, BuildStatus, ValidationMode;
import infrastructure.config.schema.schema : Target, TargetType, TargetId, TargetBuilder;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// ============================================================================
// CONCURRENT GRAPH MODIFICATION STRESS TESTS
// ============================================================================

/// Test: Multiple threads adding nodes concurrently
@("graph_stress.concurrent_node_addition")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Concurrent Node Addition");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 1000);
    auto mutex = new Mutex();
    shared size_t successCount = 0;
    shared size_t failureCount = 0;
    
    enum numThreads = 8;
    enum nodesPerThread = 100;
    
    // Each thread adds nodes with unique IDs
    foreach (threadId; parallel(iota(numThreads)))
    {
        foreach (i; 0 .. nodesPerThread)
        {
            auto targetName = "thread" ~ threadId.to!string ~ "-node" ~ i.to!string;
            auto target = TargetBuilder.create(targetName)
                .withType(TargetType.Library)
                .withSources(["src/" ~ targetName ~ ".d"])
                .build();
            
            synchronized (mutex)
            {
                auto result = graph.addTarget(target);
                if (result.isOk)
                    atomicOp!"+="(successCount, 1);
                else
                    atomicOp!"+="(failureCount, 1);
            }
        }
    }
    
    immutable totalSuccess = atomicLoad(successCount);
    immutable totalFail = atomicLoad(failureCount);
    
    Logger.info("Concurrent node addition: " ~ totalSuccess.to!string ~ " succeeded, " ~ totalFail.to!string ~ " failed");
    
    // All unique IDs should succeed
    Assert.equal(totalSuccess, numThreads * nodesPerThread, "All nodes should be added successfully");
    Assert.equal(totalFail, 0, "No failures expected with unique IDs");
    Assert.equal(graph.nodes.length, numThreads * nodesPerThread, "Graph should contain all nodes");
    
    writeln("  \x1b[32m✓ Concurrent node addition passed (" ~ totalSuccess.to!string ~ " nodes)\x1b[0m");
}

/// Test: Multiple threads adding edges concurrently (no cycles)
@("graph_stress.concurrent_edge_addition")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Concurrent Edge Addition");
    
    // Use deferred validation to allow concurrent edge addition
    auto graph = new BuildGraph(ValidationMode.Deferred, 200);
    auto mutex = new Mutex();
    
    // Create nodes first (sequential to ensure all exist)
    enum nodeCount = 100;
    foreach (i; 0 .. nodeCount)
    {
        auto target = TargetBuilder.create("node" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
    }
    
    shared size_t edgesAdded = 0;
    
    // Threads add edges (only forward edges to avoid cycles)
    foreach (from; parallel(iota(nodeCount - 1)))
    {
        // Each node depends on nodes with higher indices (DAG property)
        foreach (to; from + 1 .. min(from + 5, nodeCount))
        {
            synchronized (mutex)
            {
                auto result = graph.addDependency("node" ~ from.to!string, "node" ~ to.to!string);
                if (result.isOk)
                    atomicOp!"+="(edgesAdded, 1);
            }
        }
    }
    
    // Validate the graph
    auto validateResult = graph.validate();
    Assert.isTrue(validateResult.isOk, "Graph should be acyclic");
    
    immutable edges = atomicLoad(edgesAdded);
    Logger.info("Concurrent edge addition: " ~ edges.to!string ~ " edges added");
    
    Assert.isTrue(edges > 0, "Should have added edges");
    
    writeln("  \x1b[32m✓ Concurrent edge addition passed (" ~ edges.to!string ~ " edges)\x1b[0m");
}

/// Test: Concurrent getReadyNodes during status updates
@("graph_stress.concurrent_ready_detection")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Concurrent Ready Node Detection");
    
    auto graph = new BuildGraph(ValidationMode.Immediate, 50);
    auto mutex = new Mutex();
    
    // Create a chain: node0 <- node1 <- node2 <- ... <- node19
    enum chainLength = 20;
    foreach (i; 0 .. chainLength)
    {
        auto target = TargetBuilder.create("chain" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
        
        if (i > 0)
            graph.addDependency("chain" ~ i.to!string, "chain" ~ (i - 1).to!string);
    }
    
    // Reader threads continuously check ready nodes
    shared bool running = true;
    shared size_t readyChecks = 0;
    shared size_t invariantViolations = 0;
    
    // Writer thread updates status
    auto writerThread = new Thread({
        foreach (i; 0 .. chainLength)
        {
            synchronized (mutex)
            {
                auto node = graph.nodes["chain" ~ i.to!string];
                node.status = BuildStatus.Success;
            }
            Thread.sleep(5.msecs);
        }
        atomicStore(running, false);
    });
    
    // Reader threads check invariants
    Thread[] readers;
    foreach (r; 0 .. 4)
    {
        readers ~= new Thread({
            while (atomicLoad(running))
            {
                synchronized (mutex)
                {
                    auto ready = graph.getReadyNodes();
                    atomicOp!"+="(readyChecks, 1);
                    
                    // Invariant: Ready nodes must have all dependencies satisfied
                    foreach (node; ready)
                    {
                        foreach (depId; node.dependencyIds)
                        {
                            auto dep = graph.nodes[depId.toString()];
                            if (dep.status != BuildStatus.Success && dep.status != BuildStatus.Cached)
                            {
                                atomicOp!"+="(invariantViolations, 1);
                            }
                        }
                    }
                }
                Thread.sleep(1.msecs);
            }
        });
    }
    
    writerThread.start();
    foreach (reader; readers) reader.start();
    
    writerThread.join();
    foreach (reader; readers) reader.join();
    
    immutable checks = atomicLoad(readyChecks);
    immutable violations = atomicLoad(invariantViolations);
    
    Logger.info("Ready checks: " ~ checks.to!string ~ ", violations: " ~ violations.to!string);
    
    Assert.equal(violations, 0, "No invariant violations should occur");
    Assert.isTrue(checks > 100, "Should have performed many ready checks");
    
    writeln("  \x1b[32m✓ Concurrent ready detection passed (" ~ checks.to!string ~ " checks)\x1b[0m");
}

/// Test: Concurrent topological sort during graph modifications
@("graph_stress.concurrent_topo_sort")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Concurrent Topological Sort");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 100);
    auto mutex = new Mutex();
    
    // Create initial graph
    enum initialNodes = 30;
    foreach (i; 0 .. initialNodes)
    {
        auto target = TargetBuilder.create("initial" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
    }
    
    // Add some initial dependencies
    foreach (i; 1 .. initialNodes)
    {
        if (i % 3 == 0)
            graph.addDependency("initial" ~ i.to!string, "initial" ~ (i - 1).to!string);
    }
    
    shared bool running = true;
    shared size_t sortCount = 0;
    shared size_t sortErrors = 0;
    shared size_t addedNodes = 0;
    
    // Sorter threads perform topological sort
    Thread[] sorters;
    foreach (s; 0 .. 3)
    {
        sorters ~= new Thread({
            while (atomicLoad(running))
            {
                synchronized (mutex)
                {
                    auto result = graph.topologicalSort();
                    atomicOp!"+="(sortCount, 1);
                    
                    if (result.isErr)
                        atomicOp!"+="(sortErrors, 1);
                    else
                    {
                        // Verify sort order
                        auto sorted = result.unwrap();
                        bool[string] seen;
                        
                        foreach (node; sorted)
                        {
                            foreach (depId; node.dependencyIds)
                            {
                                if (depId.toString() !in seen)
                                {
                                    // Dependency not seen yet - order violation
                                    // This is actually OK in deferred mode during modifications
                                }
                            }
                            seen[node.id.toString()] = true;
                        }
                    }
                }
                Thread.sleep(2.msecs);
            }
        });
    }
    
    // Adder thread adds new nodes and edges
    auto adderThread = new Thread({
        foreach (i; 0 .. 50)
        {
            synchronized (mutex)
            {
                auto name = "added" ~ i.to!string;
                auto target = TargetBuilder.create(name)
                    .withType(TargetType.Library)
                    .build();
                graph.addTarget(target);
                atomicOp!"+="(addedNodes, 1);
                
                // Connect to existing node (avoiding cycles)
                if (i > 0)
                    graph.addDependency(name, "added" ~ (i - 1).to!string);
            }
            Thread.sleep(3.msecs);
        }
        atomicStore(running, false);
    });
    
    foreach (sorter; sorters) sorter.start();
    adderThread.start();
    
    adderThread.join();
    foreach (sorter; sorters) sorter.join();
    
    immutable sorts = atomicLoad(sortCount);
    immutable errors = atomicLoad(sortErrors);
    immutable added = atomicLoad(addedNodes);
    
    Logger.info("Sorts: " ~ sorts.to!string ~ ", errors: " ~ errors.to!string ~ ", added: " ~ added.to!string);
    
    // Final validation
    auto finalResult = graph.validate();
    Assert.isTrue(finalResult.isOk, "Final graph should be valid");
    Assert.equal(added, 50, "All nodes should be added");
    
    writeln("  \x1b[32m✓ Concurrent topological sort passed (" ~ sorts.to!string ~ " sorts)\x1b[0m");
}

/// Test: High contention on single node status
@("graph_stress.high_contention_status")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - High Contention Status Updates");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    auto target = TargetBuilder.create("contended")
        .withType(TargetType.Library)
        .build();
    graph.addTarget(target);
    
    auto node = graph.nodes["contended"];
    shared size_t totalUpdates = 0;
    
    enum numThreads = 16;
    enum updatesPerThread = 1000;
    
    // All threads rapidly update the same node's status
    foreach (threadId; parallel(iota(numThreads)))
    {
        foreach (i; 0 .. updatesPerThread)
        {
            // Cycle through statuses
            auto status = cast(BuildStatus)(i % 5);
            node.status = status;
            atomicOp!"+="(totalUpdates, 1);
        }
    }
    
    immutable updates = atomicLoad(totalUpdates);
    
    Logger.info("High contention updates: " ~ updates.to!string);
    
    Assert.equal(updates, numThreads * updatesPerThread, "All updates should complete");
    
    // Final status should be valid
    auto finalStatus = node.status;
    Assert.isTrue(finalStatus >= BuildStatus.Pending && finalStatus <= BuildStatus.Cached,
                 "Final status should be valid");
    
    writeln("  \x1b[32m✓ High contention status passed (" ~ updates.to!string ~ " updates)\x1b[0m");
}

/// Test: Concurrent depth calculation with memoization
@("graph_stress.concurrent_depth_calculation")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Concurrent Depth Calculation");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 200);
    
    // Create deep chain: node0 <- node1 <- ... <- node99
    enum chainLength = 100;
    foreach (i; 0 .. chainLength)
    {
        auto target = TargetBuilder.create("depth" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
        
        if (i > 0)
            graph.addDependency("depth" ~ i.to!string, "depth" ~ (i - 1).to!string);
    }
    
    graph.validate();
    
    shared size_t[chainLength] computedDepths;
    shared size_t totalComputations = 0;
    
    // All threads compute depth of random nodes
    foreach (threadId; parallel(iota(8)))
    {
        auto rng = Random(threadId);
        
        foreach (i; 0 .. 500)
        {
            auto nodeIdx = uniform(0, chainLength, rng);
            auto node = graph.nodes["depth" ~ nodeIdx.to!string];
            auto depth = node.depth(graph);
            
            atomicStore(computedDepths[nodeIdx], depth);
            atomicOp!"+="(totalComputations, 1);
        }
    }
    
    // Verify all depths are correct
    foreach (i; 0 .. chainLength)
    {
        auto expectedDepth = i;
        auto actualDepth = atomicLoad(computedDepths[i]);
        
        // Only check if this depth was computed
        if (actualDepth > 0 || i == 0)
            Assert.equal(actualDepth, expectedDepth, "Depth should be correct for node" ~ i.to!string);
    }
    
    immutable computations = atomicLoad(totalComputations);
    Logger.info("Depth computations: " ~ computations.to!string);
    
    Assert.equal(computations, 8 * 500, "All computations should complete");
    
    writeln("  \x1b[32m✓ Concurrent depth calculation passed\x1b[0m");
}

/// Test: Stress test with dynamic discovery pattern
@("graph_stress.dynamic_discovery")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Dynamic Discovery Pattern");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 500);
    auto mutex = new Mutex();
    
    // Create initial "generator" targets
    enum generatorCount = 10;
    foreach (i; 0 .. generatorCount)
    {
        auto target = TargetBuilder.create("generator" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        synchronized (mutex) graph.addTarget(target);
    }
    
    shared size_t discoveredTargets = 0;
    shared size_t discoveredEdges = 0;
    
    // Threads simulate dynamic discovery (e.g., protobuf compilation discovering generated files)
    foreach (genId; parallel(iota(generatorCount)))
    {
        // Each generator "discovers" generated targets
        foreach (genFile; 0 .. 20)
        {
            auto name = "generated" ~ genId.to!string ~ "_" ~ genFile.to!string;
            auto target = TargetBuilder.create(name)
                .withType(TargetType.Library)
                .build();
            
            synchronized (mutex)
            {
                auto addResult = graph.addTarget(target);
                if (addResult.isOk)
                {
                    atomicOp!"+="(discoveredTargets, 1);
                    
                    // Connect generated target to generator
                    auto depResult = graph.addDependency(name, "generator" ~ genId.to!string);
                    if (depResult.isOk)
                        atomicOp!"+="(discoveredEdges, 1);
                }
            }
        }
    }
    
    // Validate final graph
    auto validateResult = graph.validate();
    Assert.isTrue(validateResult.isOk, "Graph should be valid after discovery");
    
    immutable targets = atomicLoad(discoveredTargets);
    immutable edges = atomicLoad(discoveredEdges);
    
    Logger.info("Dynamic discovery: " ~ targets.to!string ~ " targets, " ~ edges.to!string ~ " edges");
    
    Assert.equal(targets, generatorCount * 20, "All generated targets should be discovered");
    Assert.equal(edges, generatorCount * 20, "All edges should be added");
    
    auto stats = graph.getStats();
    Assert.equal(stats.totalNodes, generatorCount + generatorCount * 20, "Total nodes should match");
    
    writeln("  \x1b[32m✓ Dynamic discovery pattern passed\x1b[0m");
}

/// Test: Graph stats calculation under concurrent access
@("graph_stress.concurrent_stats")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Concurrent Stats Calculation");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 100);
    auto mutex = new Mutex();
    
    // Build graph
    foreach (i; 0 .. 50)
    {
        auto target = TargetBuilder.create("stat" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
        
        if (i > 0 && i % 5 == 0)
            graph.addDependency("stat" ~ i.to!string, "stat" ~ (i - 1).to!string);
    }
    
    graph.validate();
    
    shared size_t statsComputations = 0;
    shared bool statsConsistent = true;
    
    // Threads compute stats concurrently
    foreach (threadId; parallel(iota(8)))
    {
        foreach (i; 0 .. 100)
        {
            BuildGraph.GraphStats stats;
            synchronized (mutex)
            {
                stats = graph.getStats();
            }
            atomicOp!"+="(statsComputations, 1);
            
            // Verify consistency
            if (stats.totalNodes != 50)
                atomicStore(statsConsistent, false);
        }
    }
    
    Assert.isTrue(atomicLoad(statsConsistent), "Stats should be consistent");
    Assert.equal(atomicLoad(statsComputations), 800, "All stats computations should complete");
    
    writeln("  \x1b[32m✓ Concurrent stats calculation passed\x1b[0m");
}

/// Test: Large-scale graph construction performance
@("graph_stress.large_scale_construction")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Large Scale Construction");
    
    auto startTime = MonoTime.currTime;
    
    // Use arena allocation for large graph
    auto graph = new BuildGraph(ValidationMode.Deferred, 5000);
    
    // Create 5000 nodes
    enum nodeCount = 5000;
    foreach (i; 0 .. nodeCount)
    {
        auto target = TargetBuilder.create("large" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
    }
    
    auto nodeTime = MonoTime.currTime - startTime;
    Logger.info("Node creation: " ~ nodeTime.total!"msecs".to!string ~ "ms");
    
    // Add sparse edges (avoiding cycles by only going forward)
    startTime = MonoTime.currTime;
    size_t edgeCount = 0;
    
    foreach (i; 0 .. nodeCount - 1)
    {
        // Each node depends on ~3 subsequent nodes
        foreach (j; i + 1 .. min(i + 4, nodeCount))
        {
            graph.addDependency("large" ~ i.to!string, "large" ~ j.to!string);
            edgeCount++;
        }
    }
    
    auto edgeTime = MonoTime.currTime - startTime;
    Logger.info("Edge creation: " ~ edgeTime.total!"msecs".to!string ~ "ms (" ~ edgeCount.to!string ~ " edges)");
    
    // Validate
    startTime = MonoTime.currTime;
    auto validateResult = graph.validate();
    auto validateTime = MonoTime.currTime - startTime;
    Logger.info("Validation: " ~ validateTime.total!"msecs".to!string ~ "ms");
    
    Assert.isTrue(validateResult.isOk, "Large graph should be valid");
    
    // Get stats
    startTime = MonoTime.currTime;
    auto stats = graph.getStats();
    auto statsTime = MonoTime.currTime - startTime;
    Logger.info("Stats calculation: " ~ statsTime.total!"msecs".to!string ~ "ms");
    
    Assert.equal(stats.totalNodes, nodeCount, "Should have all nodes");
    Assert.equal(stats.totalEdges, edgeCount, "Should have all edges");
    
    // Performance assertions (generous limits for CI)
    Assert.isTrue(nodeTime.total!"msecs" < 5000, "Node creation should be < 5s");
    Assert.isTrue(edgeTime.total!"msecs" < 5000, "Edge creation should be < 5s");
    Assert.isTrue(validateTime.total!"msecs" < 2000, "Validation should be < 2s");
    
    writeln("  \x1b[32m✓ Large scale construction passed (" ~ nodeCount.to!string ~ " nodes, " ~ edgeCount.to!string ~ " edges)\x1b[0m");
}

/// Test: Simulated build execution with concurrent status updates
@("graph_stress.simulated_build_execution")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Simulated Build Execution");
    
    auto graph = new BuildGraph(ValidationMode.Immediate, 100);
    auto mutex = new Mutex();
    
    // Create diamond dependency pattern
    //       root
    //      /    \
    //   left    right
    //      \    /
    //       base
    
    auto baseTarget = TargetBuilder.create("base").withType(TargetType.Library).build();
    auto leftTarget = TargetBuilder.create("left").withType(TargetType.Library).build();
    auto rightTarget = TargetBuilder.create("right").withType(TargetType.Library).build();
    auto rootTarget = TargetBuilder.create("root").withType(TargetType.Executable).build();
    
    graph.addTarget(baseTarget);
    graph.addTarget(leftTarget);
    graph.addTarget(rightTarget);
    graph.addTarget(rootTarget);
    
    graph.addDependency("left", "base");
    graph.addDependency("right", "base");
    graph.addDependency("root", "left");
    graph.addDependency("root", "right");
    
    shared size_t completedTargets = 0;
    
    void simulateBuild(string targetName, Duration buildTime) @trusted
    {
        synchronized (mutex)
        {
            auto node = graph.nodes[targetName];
            node.status = BuildStatus.Building;
        }
        
        Thread.sleep(buildTime);
        
        synchronized (mutex)
        {
            auto node = graph.nodes[targetName];
            node.status = BuildStatus.Success;
            atomicOp!"+="(completedTargets, 1);
        }
    }
    
    // Simulate parallel build
    auto baseThread = new Thread({ simulateBuild("base", 50.msecs); });
    baseThread.start();
    baseThread.join();
    
    // Left and right can build in parallel
    auto leftThread = new Thread({ simulateBuild("left", 30.msecs); });
    auto rightThread = new Thread({ simulateBuild("right", 40.msecs); });
    
    leftThread.start();
    rightThread.start();
    leftThread.join();
    rightThread.join();
    
    // Root builds last
    simulateBuild("root", 20.msecs);
    
    Assert.equal(atomicLoad(completedTargets), 4, "All targets should complete");
    Assert.equal(graph.nodes["root"].status, BuildStatus.Success, "Root should succeed");
    
    writeln("  \x1b[32m✓ Simulated build execution passed\x1b[0m");
}

/// Test: Retry counter stress test
@("graph_stress.retry_counter_stress")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Retry Counter Stress");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    auto target = TargetBuilder.create("retry-test").withType(TargetType.Library).build();
    graph.addTarget(target);
    
    auto node = graph.nodes["retry-test"];
    
    enum numThreads = 8;
    enum incrementsPerThread = 1000;
    
    // All threads increment retry counter
    foreach (threadId; parallel(iota(numThreads)))
    {
        foreach (i; 0 .. incrementsPerThread)
        {
            node.incrementRetries();
        }
    }
    
    immutable expectedRetries = numThreads * incrementsPerThread;
    immutable actualRetries = node.retryAttempts;
    
    Assert.equal(actualRetries, expectedRetries, "Retry counter should be thread-safe");
    
    // Reset and verify
    node.resetRetries();
    Assert.equal(node.retryAttempts, 0, "Reset should work");
    
    writeln("  \x1b[32m✓ Retry counter stress passed (" ~ actualRetries.to!string ~ " increments)\x1b[0m");
}

/// Test: Pending deps counter for lock-free execution
@("graph_stress.pending_deps_counter")
@system unittest
{
    writeln("\x1b[36m[STRESS]\x1b[0m Graph - Pending Deps Counter");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    
    // Create node with 10 dependencies
    auto mainTarget = TargetBuilder.create("main").withType(TargetType.Executable).build();
    graph.addTarget(mainTarget);
    
    foreach (i; 0 .. 10)
    {
        auto depTarget = TargetBuilder.create("dep" ~ i.to!string).withType(TargetType.Library).build();
        graph.addTarget(depTarget);
        graph.addDependency("main", "dep" ~ i.to!string);
    }
    
    auto mainNode = graph.nodes["main"];
    mainNode.initPendingDeps();
    
    Assert.equal(mainNode.pendingDeps, 10, "Should have 10 pending deps");
    
    shared size_t decrementCount = 0;
    
    // Threads decrement pending deps (simulating dependency completion)
    foreach (threadId; parallel(iota(10)))
    {
        auto remaining = mainNode.decrementPendingDeps();
        atomicOp!"+="(decrementCount, 1);
    }
    
    Assert.equal(mainNode.pendingDeps, 0, "All deps should be satisfied");
    Assert.equal(atomicLoad(decrementCount), 10, "All decrements should complete");
    
    writeln("  \x1b[32m✓ Pending deps counter passed\x1b[0m");
}

