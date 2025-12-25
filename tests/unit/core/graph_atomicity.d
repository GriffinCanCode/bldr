module tests.unit.core.graph_atomicity;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs, MonoTime;
import std.conv : to;
import std.algorithm : map, filter, sort, canFind, sum, countUntil;
import std.array : array;
import std.range : iota;
import std.parallelism : parallel;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;

import tests.harness : Assert;
import tests.fixtures : TargetBuilder;
import engine.graph.core.graph : BuildGraph, BuildNode, BuildStatus, ValidationMode;
import infrastructure.config.schema.schema : Target, TargetType, TargetId;
import infrastructure.errors;

// ============================================================================
// GRAPH TRANSACTION ATOMICITY TESTS
// ============================================================================

/// Test: Atomic status transitions
@("graph_atomicity.status_transitions")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Atomic Status Transitions");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    auto target = TargetBuilder.create("atomic-status").withType(TargetType.Library).build();
    graph.addTarget(target);
    
    auto node = graph.nodes["atomic-status"];
    
    // Track all observed statuses
    shared size_t[5] statusCounts;
    shared size_t invalidStatuses = 0;
    
    enum numReaders = 4;
    enum readsPerThread = 10000;
    
    // Writer thread cycles through statuses
    auto writerThread = new Thread({
        foreach (i; 0 .. 5000)
        {
            auto status = cast(BuildStatus)(i % 5);
            node.status = status;
        }
    });
    
    // Reader threads observe statuses
    Thread[] readers;
    foreach (r; 0 .. numReaders)
    {
        readers ~= new Thread({
            foreach (i; 0 .. readsPerThread)
            {
                auto status = node.status;
                
                // Status must be valid enum value
                if (status >= BuildStatus.Pending && status <= BuildStatus.Cached)
                {
                    atomicOp!"+="(statusCounts[status], 1);
                }
                else
                {
                    atomicOp!"+="(invalidStatuses, 1);
                }
            }
        });
    }
    
    writerThread.start();
    foreach (reader; readers) reader.start();
    
    writerThread.join();
    foreach (reader; readers) reader.join();
    
    // No invalid statuses should be observed (torn reads)
    Assert.equal(atomicLoad(invalidStatuses), 0, "No invalid statuses should be observed");
    
    // Total reads should match expected
    size_t totalReads = 0;
    foreach (i; 0 .. 5)
    {
        totalReads += atomicLoad(statusCounts[i]);
    }
    Assert.equal(totalReads, numReaders * readsPerThread, "All reads should be valid");
    
    writeln("  \x1b[32m✓ Atomic status transitions passed\x1b[0m");
}

/// Test: Retry counter atomicity
@("graph_atomicity.retry_counter")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Retry Counter Atomicity");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    auto target = TargetBuilder.create("retry-atomic").withType(TargetType.Library).build();
    graph.addTarget(target);
    
    auto node = graph.nodes["retry-atomic"];
    
    enum numThreads = 8;
    enum incrementsPerThread = 10000;
    
    // All threads increment retry counter
    foreach (t; parallel(iota(numThreads)))
    {
        foreach (i; 0 .. incrementsPerThread)
        {
            node.incrementRetries();
        }
    }
    
    // Final count must be exact (no lost updates)
    immutable expected = numThreads * incrementsPerThread;
    immutable actual = node.retryAttempts;
    
    Assert.equal(actual, expected, "Retry counter must be exact (no lost updates)");
    
    writeln("  \x1b[32m✓ Retry counter atomicity passed (" ~ actual.to!string ~ " increments)\x1b[0m");
}

/// Test: Pending deps counter atomicity
@("graph_atomicity.pending_deps")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Pending Deps Counter Atomicity");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    
    // Create node with many dependencies
    auto mainTarget = TargetBuilder.create("main-atomic").withType(TargetType.Executable).build();
    graph.addTarget(mainTarget);
    
    enum depCount = 100;
    foreach (i; 0 .. depCount)
    {
        auto depTarget = TargetBuilder.create("dep" ~ i.to!string).withType(TargetType.Library).build();
        graph.addTarget(depTarget);
        graph.addDependency("main-atomic", "dep" ~ i.to!string);
    }
    
    auto mainNode = graph.nodes["main-atomic"];
    mainNode.initPendingDeps();
    
    Assert.equal(mainNode.pendingDeps, depCount, "Initial pending deps should match");
    
    shared size_t zeroCrossings = 0;
    
    // All threads decrement
    foreach (t; parallel(iota(depCount)))
    {
        auto remaining = mainNode.decrementPendingDeps();
        
        if (remaining == 0)
            atomicOp!"+="(zeroCrossings, 1);
    }
    
    // Exactly one thread should see zero (the one that completes all deps)
    Assert.equal(atomicLoad(zeroCrossings), 1, "Exactly one thread should observe zero");
    Assert.equal(mainNode.pendingDeps, 0, "Final pending deps should be zero");
    
    writeln("  \x1b[32m✓ Pending deps atomicity passed\x1b[0m");
}

/// Test: Graph construction consistency
@("graph_atomicity.construction_consistency")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Construction Consistency");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 500);
    auto mutex = new Mutex();
    
    shared size_t addedNodes = 0;
    shared size_t addedEdges = 0;
    
    // Threads add nodes
    foreach (t; parallel(iota(4)))
    {
        foreach (i; 0 .. 50)
        {
            auto name = "thread" ~ t.to!string ~ "_node" ~ i.to!string;
            auto target = TargetBuilder.create(name).withType(TargetType.Library).build();
            
            synchronized (mutex)
            {
                auto result = graph.addTarget(target);
                if (result.isOk)
                    atomicOp!"+="(addedNodes, 1);
            }
        }
    }
    
    // Add edges (sequential to avoid complexity)
    foreach (t; 0 .. 4)
    {
        foreach (i; 1 .. 50)
        {
            auto from = "thread" ~ t.to!string ~ "_node" ~ i.to!string;
            auto to = "thread" ~ t.to!string ~ "_node" ~ (i - 1).to!string;
            
            auto result = graph.addDependency(from, to);
            if (result.isOk)
                atomicOp!"+="(addedEdges, 1);
        }
    }
    
    // Validate final state
    auto validateResult = graph.validate();
    Assert.isTrue(validateResult.isOk, "Graph should be valid");
    
    auto stats = graph.getStats();
    Assert.equal(stats.totalNodes, atomicLoad(addedNodes), "Node count should match");
    Assert.equal(stats.totalEdges, atomicLoad(addedEdges), "Edge count should match");
    
    writeln("  \x1b[32m✓ Construction consistency passed (" ~ stats.totalNodes.to!string ~ " nodes)\x1b[0m");
}

/// Test: Depth cache consistency under concurrent access
@("graph_atomicity.depth_cache_consistency")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Depth Cache Consistency");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    
    // Create chain: node0 <- node1 <- ... <- node49
    enum chainLength = 50;
    foreach (i; 0 .. chainLength)
    {
        auto target = TargetBuilder.create("chain" ~ i.to!string).withType(TargetType.Library).build();
        graph.addTarget(target);
        
        if (i > 0)
            graph.addDependency("chain" ~ i.to!string, "chain" ~ (i - 1).to!string);
    }
    
    shared size_t inconsistencies = 0;
    
    // Multiple threads compute depths concurrently
    foreach (t; parallel(iota(8)))
    {
        foreach (nodeIdx; 0 .. chainLength)
        {
            auto node = graph.nodes["chain" ~ nodeIdx.to!string];
            auto depth = node.depth(graph);
            
            // Depth must equal node index in chain
            if (depth != nodeIdx)
            {
                atomicOp!"+="(inconsistencies, 1);
            }
        }
    }
    
    Assert.equal(atomicLoad(inconsistencies), 0, "All depth calculations should be consistent");
    
    writeln("  \x1b[32m✓ Depth cache consistency passed\x1b[0m");
}

/// Test: isReady atomicity during status changes
@("graph_atomicity.is_ready_consistency")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - isReady Consistency");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    auto mutex = new Mutex();
    
    // Create: dep1, dep2, dep3 -> main
    foreach (i; 1 .. 4)
    {
        auto depTarget = TargetBuilder.create("dep" ~ i.to!string).withType(TargetType.Library).build();
        graph.addTarget(depTarget);
    }
    
    auto mainTarget = TargetBuilder.create("main").withType(TargetType.Executable).build();
    graph.addTarget(mainTarget);
    
    foreach (i; 1 .. 4)
    {
        graph.addDependency("main", "dep" ~ i.to!string);
    }
    
    auto mainNode = graph.nodes["main"];
    
    shared bool running = true;
    shared size_t readyChecks = 0;
    shared size_t falsePositives = 0;  // isReady=true when deps not satisfied
    
    // Writer thread completes dependencies one by one
    auto writerThread = new Thread({
        Thread.sleep(10.msecs);  // Let readers start
        
        foreach (i; 1 .. 4)
        {
            synchronized (mutex)
            {
                graph.nodes["dep" ~ i.to!string].status = BuildStatus.Success;
            }
            Thread.sleep(20.msecs);
        }
        
        Thread.sleep(50.msecs);
        atomicStore(running, false);
    });
    
    // Reader threads check isReady
    Thread[] readers;
    foreach (r; 0 .. 4)
    {
        readers ~= new Thread({
            while (atomicLoad(running))
            {
                bool ready;
                bool allDepsSatisfied;
                
                synchronized (mutex)
                {
                    ready = mainNode.isReady(graph);
                    
                    // Manually check deps
                    allDepsSatisfied = true;
                    foreach (depId; mainNode.dependencyIds)
                    {
                        auto dep = graph.nodes[depId.toString()];
                        if (dep.status != BuildStatus.Success && dep.status != BuildStatus.Cached)
                        {
                            allDepsSatisfied = false;
                            break;
                        }
                    }
                }
                
                atomicOp!"+="(readyChecks, 1);
                
                // isReady should never return true when deps aren't satisfied
                if (ready && !allDepsSatisfied)
                {
                    atomicOp!"+="(falsePositives, 1);
                }
            }
        });
    }
    
    writerThread.start();
    foreach (reader; readers) reader.start();
    
    writerThread.join();
    foreach (reader; readers) reader.join();
    
    Assert.equal(atomicLoad(falsePositives), 0, "No false positives in isReady");
    Assert.isTrue(atomicLoad(readyChecks) > 100, "Should have many ready checks");
    
    writeln("  \x1b[32m✓ isReady consistency passed (" ~ atomicLoad(readyChecks).to!string ~ " checks)\x1b[0m");
}

/// Test: Node addition idempotency
@("graph_atomicity.add_node_idempotent")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Add Node Idempotency");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    auto mutex = new Mutex();
    
    shared size_t successes = 0;
    shared size_t duplicates = 0;
    
    // All threads try to add same node
    foreach (t; parallel(iota(8)))
    {
        auto target = TargetBuilder.create("same-node").withType(TargetType.Library).build();
        
        synchronized (mutex)
        {
            auto result = graph.addTarget(target);
            if (result.isOk)
                atomicOp!"+="(successes, 1);
            else
                atomicOp!"+="(duplicates, 1);
        }
    }
    
    // Exactly one should succeed, rest should fail as duplicates
    Assert.equal(atomicLoad(successes), 1, "Exactly one add should succeed");
    Assert.equal(atomicLoad(duplicates), 7, "Rest should be duplicates");
    Assert.equal(graph.nodes.length, 1, "Graph should have exactly one node");
    
    writeln("  \x1b[32m✓ Add node idempotency passed\x1b[0m");
}

/// Test: Edge addition consistency
@("graph_atomicity.edge_consistency")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Edge Addition Consistency");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 100);
    auto mutex = new Mutex();
    
    // Create nodes first
    foreach (i; 0 .. 50)
    {
        auto target = TargetBuilder.create("edge" ~ i.to!string).withType(TargetType.Library).build();
        graph.addTarget(target);
    }
    
    shared size_t edgesAdded = 0;
    
    // Threads add edges (carefully avoiding cycles)
    foreach (t; parallel(iota(4)))
    {
        foreach (i; 0 .. 10)
        {
            auto fromIdx = t * 10 + i;
            auto toIdx = (fromIdx + 25) % 50;  // Different pattern per thread
            
            if (fromIdx < toIdx)  // Ensure DAG property
            {
                synchronized (mutex)
                {
                    auto result = graph.addDependency("edge" ~ fromIdx.to!string, "edge" ~ toIdx.to!string);
                    if (result.isOk)
                        atomicOp!"+="(edgesAdded, 1);
                }
            }
        }
    }
    
    // Validate graph
    auto validateResult = graph.validate();
    Assert.isTrue(validateResult.isOk, "Graph should be valid after concurrent edge adds");
    
    auto stats = graph.getStats();
    Assert.equal(stats.totalEdges, atomicLoad(edgesAdded), "Edge count should match");
    
    writeln("  \x1b[32m✓ Edge consistency passed (" ~ stats.totalEdges.to!string ~ " edges)\x1b[0m");
}

/// Test: Topological sort stability
@("graph_atomicity.topo_sort_stability")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Topological Sort Stability");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    
    // Create simple DAG: a -> b -> c, a -> c
    auto a = TargetBuilder.create("a").withType(TargetType.Library).build();
    auto b = TargetBuilder.create("b").withType(TargetType.Library).build();
    auto c = TargetBuilder.create("c").withType(TargetType.Library).build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    
    graph.addDependency("a", "b");
    graph.addDependency("b", "c");
    graph.addDependency("a", "c");
    
    // Multiple sorts should produce consistent results
    string[][] sortResults;
    
    foreach (i; 0 .. 100)
    {
        auto result = graph.topologicalSort();
        Assert.isTrue(result.isOk, "Sort should succeed");
        
        auto sorted = result.unwrap();
        string[] order = sorted.map!(n => n.id.toString()).array;
        sortResults ~= order;
    }
    
    // All results should satisfy topological order (c before b before a)
    foreach (order; sortResults)
    {
        auto cIdx = order.countUntil("c");
        auto bIdx = order.countUntil("b");
        auto aIdx = order.countUntil("a");
        
        Assert.isTrue(cIdx < bIdx, "c must come before b");
        Assert.isTrue(bIdx < aIdx, "b must come before a");
        Assert.isTrue(cIdx < aIdx, "c must come before a");
    }
    
    writeln("  \x1b[32m✓ Topological sort stability passed\x1b[0m");
}

/// Test: Graph stats consistency
@("graph_atomicity.stats_consistency")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Stats Consistency");
    
    auto graph = new BuildGraph(ValidationMode.Deferred, 100);
    auto mutex = new Mutex();
    
    // Build graph
    foreach (i; 0 .. 50)
    {
        auto target = TargetBuilder.create("stat" ~ i.to!string).withType(TargetType.Library).build();
        graph.addTarget(target);
        
        if (i > 0)
            graph.addDependency("stat" ~ i.to!string, "stat" ~ (i - 1).to!string);
    }
    
    graph.validate();
    
    shared size_t inconsistentStats = 0;
    
    // Concurrent stats reads should be consistent
    foreach (t; parallel(iota(8)))
    {
        foreach (i; 0 .. 100)
        {
            BuildGraph.GraphStats stats;
            synchronized (mutex)
            {
                stats = graph.getStats();
            }
            
            // Consistency checks
            if (stats.totalNodes != 50)
                atomicOp!"+="(inconsistentStats, 1);
            if (stats.totalEdges != 49)
                atomicOp!"+="(inconsistentStats, 1);
            if (stats.maxDepth != 49)
                atomicOp!"+="(inconsistentStats, 1);
        }
    }
    
    Assert.equal(atomicLoad(inconsistentStats), 0, "All stats should be consistent");
    
    writeln("  \x1b[32m✓ Stats consistency passed\x1b[0m");
}

/// Test: Validation mode switching
@("graph_atomicity.validation_mode")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Validation Mode Behavior");
    
    // Test immediate mode - cycle detected on add
    auto immediateGraph = new BuildGraph(ValidationMode.Immediate);
    auto a1 = TargetBuilder.create("a1").withType(TargetType.Library).build();
    auto b1 = TargetBuilder.create("b1").withType(TargetType.Library).build();
    
    immediateGraph.addTarget(a1);
    immediateGraph.addTarget(b1);
    
    immediateGraph.addDependency("a1", "b1");
    auto cycleResult1 = immediateGraph.addDependency("b1", "a1");
    
    Assert.isTrue(cycleResult1.isErr, "Immediate mode should detect cycle on add");
    Assert.isTrue(immediateGraph.isValidated, "Immediate mode is always validated");
    
    // Test deferred mode - cycle detected on validate
    auto deferredGraph = new BuildGraph(ValidationMode.Deferred);
    auto a2 = TargetBuilder.create("a2").withType(TargetType.Library).build();
    auto b2 = TargetBuilder.create("b2").withType(TargetType.Library).build();
    
    deferredGraph.addTarget(a2);
    deferredGraph.addTarget(b2);
    
    deferredGraph.addDependency("a2", "b2");
    auto addResult = deferredGraph.addDependency("b2", "a2");
    
    Assert.isTrue(addResult.isOk, "Deferred mode should not detect cycle on add");
    Assert.isFalse(deferredGraph.isValidated, "Deferred mode needs explicit validation");
    
    auto validateResult = deferredGraph.validate();
    Assert.isTrue(validateResult.isErr, "Deferred mode should detect cycle on validate");
    
    writeln("  \x1b[32m✓ Validation mode behavior passed\x1b[0m");
}

/// Test: Node reference stability
@("graph_atomicity.node_reference_stability")
@system unittest
{
    writeln("\x1b[36m[ATOMICITY]\x1b[0m Graph - Node Reference Stability");
    
    auto graph = new BuildGraph(ValidationMode.Immediate);
    
    auto target = TargetBuilder.create("stable").withType(TargetType.Library).build();
    graph.addTarget(target);
    
    // Get reference to node
    auto node = graph.nodes["stable"];
    
    // Reference should remain valid through multiple operations
    node.status = BuildStatus.Building;
    Assert.equal(graph.nodes["stable"].status, BuildStatus.Building, "Status change should be visible");
    
    node.incrementRetries();
    Assert.equal(graph.nodes["stable"].retryAttempts, 1, "Retry change should be visible");
    
    // Add more nodes - original reference should still be valid
    foreach (i; 0 .. 100)
    {
        auto newTarget = TargetBuilder.create("new" ~ i.to!string).withType(TargetType.Library).build();
        graph.addTarget(newTarget);
    }
    
    // Original node reference still valid
    Assert.equal(node.status, BuildStatus.Building, "Original reference should be stable");
    Assert.equal(node.retryAttempts, 1, "Original reference data should be preserved");
    
    writeln("  \x1b[32m✓ Node reference stability passed\x1b[0m");
}

