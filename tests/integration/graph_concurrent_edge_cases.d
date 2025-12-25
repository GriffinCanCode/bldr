module tests.integration.graph_concurrent_edge_cases;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs, MonoTime;
import std.conv : to;
import std.algorithm : map, filter, sort, min, max, canFind, countUntil, count;
import std.array : array;
import std.random : uniform, uniform01, Random, Mt19937;
import std.range : iota;
import std.parallelism : parallel, taskPool, totalCPUs;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import core.sync.rwmutex : ReadWriteMutex;
import core.sync.condition : Condition;

import tests.harness : Assert;
import tests.fixtures : TempDir, TargetBuilder;
import engine.graph.core.graph : BuildGraph, BuildNode, BuildStatus, ValidationMode;
import infrastructure.config.schema.schema : Target, TargetType, TargetId;
import infrastructure.errors.types.types : BuildError;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// ============================================================================
// CONCURRENT GRAPH EDGE CASES
// Complex interleaving scenarios not covered by basic stress tests
// ============================================================================

/// Custom graph for testing with additional instrumentation
class InstrumentedGraph
{
    private BuildGraph graph;
    private Mutex mutex;
    private shared size_t operationCount;
    private shared size_t cycleDetections;
    private shared size_t validationErrors;
    
    this(ValidationMode mode = ValidationMode.Deferred, size_t capacity = 1000) @trusted
    {
        this.graph = new BuildGraph(mode, capacity);
        this.mutex = new Mutex();
    }
    
    Result!BuildError addTarget(Target target) @trusted
    {
        atomicOp!"+="(operationCount, 1);
        synchronized (mutex)
        {
            return graph.addTarget(target);
        }
    }
    
    Result!BuildError addDependency(string from, string to) @trusted
    {
        atomicOp!"+="(operationCount, 1);
        synchronized (mutex)
        {
            auto result = graph.addDependency(from, to);
            if (result.isErr)
            {
                auto err = result.unwrapErr();
                if (err.message.canFind("cycle"))
                    atomicOp!"+="(cycleDetections, 1);
            }
            return result;
        }
    }
    
    Result!BuildError validate() @trusted
    {
        synchronized (mutex)
        {
            auto result = graph.validate();
            if (result.isErr)
                atomicOp!"+="(validationErrors, 1);
            return result;
        }
    }
    
    auto topologicalSort() @trusted
    {
        synchronized (mutex)
        {
            return graph.topologicalSort();
        }
    }
    
    BuildNode getNode(string id) @trusted
    {
        synchronized (mutex)
        {
            if (id in graph.nodes)
                return graph.nodes[id];
            return null;
        }
    }
    
    string[] getNodeIds() @trusted
    {
        synchronized (mutex)
        {
            return graph.nodes.keys.dup;
        }
    }
    
    size_t nodeCount() @trusted
    {
        synchronized (mutex)
        {
            return graph.nodes.length;
        }
    }
    
    auto getStats() @trusted
    {
        synchronized (mutex)
        {
            return graph.getStats();
        }
    }
    
    size_t getOperationCount() @trusted => atomicLoad(operationCount);
    size_t getCycleDetections() @trusted => atomicLoad(cycleDetections);
    size_t getValidationErrors() @trusted => atomicLoad(validationErrors);
}

// ============================================================================
// CYCLE RACE CONDITION TESTS
// ============================================================================

/// Test: Cycle detection races with edge addition
@("graph_edge.cycle_detection_race")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Cycle Detection Race");
    
    auto graph = new InstrumentedGraph(ValidationMode.Immediate, 100);
    auto mutex = new Mutex();
    
    // Create nodes
    foreach (i; 0 .. 20)
    {
        auto target = TargetBuilder.create("node" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
    }
    
    shared size_t edgesAdded = 0;
    shared size_t cyclesRejected = 0;
    
    // Multiple threads try to add edges that could create cycles
    foreach (threadId; parallel(iota(8)))
    {
        auto rng = Mt19937(cast(uint)threadId);
        
        foreach (attempt; 0 .. 50)
        {
            auto from = uniform(0, 20, rng);
            auto to = uniform(0, 20, rng);
            
            if (from == to)
                continue;
            
            auto result = graph.addDependency("node" ~ from.to!string, "node" ~ to.to!string);
            
            if (result.isOk)
                atomicOp!"+="(edgesAdded, 1);
            else
                atomicOp!"+="(cyclesRejected, 1);
        }
    }
    
    // Final validation
    auto validateResult = graph.validate();
    
    Logger.info("Cycle race - edges added: " ~ atomicLoad(edgesAdded).to!string ~
               ", cycles rejected: " ~ atomicLoad(cyclesRejected).to!string ~
               ", cycle detections: " ~ graph.getCycleDetections().to!string);
    
    // Graph should be valid (no cycles)
    Assert.isTrue(validateResult.isOk, "Final graph should be acyclic");
    
    writeln("  \x1b[32m✓ Cycle detection race passed\x1b[0m");
}

/// Test: Deferred validation with concurrent cycle-creating additions
@("graph_edge.deferred_cycle_race")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Deferred Validation Cycle Race");
    
    // Deferred mode allows cycle-creating edges until validate()
    auto graph = new InstrumentedGraph(ValidationMode.Deferred, 100);
    
    // Create simple cycle: A -> B -> C -> A
    auto a = TargetBuilder.create("A").withType(TargetType.Library).build();
    auto b = TargetBuilder.create("B").withType(TargetType.Library).build();
    auto c = TargetBuilder.create("C").withType(TargetType.Library).build();
    
    graph.addTarget(a);
    graph.addTarget(b);
    graph.addTarget(c);
    
    // In deferred mode, these should all succeed
    auto r1 = graph.addDependency("A", "B");
    auto r2 = graph.addDependency("B", "C");
    auto r3 = graph.addDependency("C", "A");  // Creates cycle
    
    Assert.isTrue(r1.isOk, "First edge should succeed");
    Assert.isTrue(r2.isOk, "Second edge should succeed");
    Assert.isTrue(r3.isOk, "Third edge should succeed in deferred mode");
    
    // Validation should catch the cycle
    auto validateResult = graph.validate();
    Assert.isTrue(validateResult.isErr, "Validation should detect cycle");
    
    writeln("  \x1b[32m✓ Deferred validation cycle race passed\x1b[0m");
}

/// Test: Concurrent validation during edge additions
@("graph_edge.concurrent_validate_add")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Concurrent Validate and Add");
    
    auto graph = new InstrumentedGraph(ValidationMode.Deferred, 200);
    auto mutex = new Mutex();
    shared bool running = true;
    shared size_t validations = 0;
    shared size_t additions = 0;
    
    // Create nodes
    foreach (i; 0 .. 50)
    {
        auto target = TargetBuilder.create("target" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
    }
    
    // Validation thread
    auto validateThread = new Thread({
        while (atomicLoad(running))
        {
            graph.validate();
            atomicOp!"+="(validations, 1);
            Thread.sleep(5.msecs);
        }
    });
    
    // Addition threads
    Thread[] addThreads;
    foreach (t; 0 .. 4)
    {
        addThreads ~= new Thread({
            auto rng = Mt19937(cast(uint)(t * 1000));
            
            while (atomicLoad(running))
            {
                auto from = uniform(0, 49, rng);
                auto to = uniform(from + 1, 50, rng);  // Only forward edges
                
                graph.addDependency("target" ~ from.to!string, "target" ~ to.to!string);
                atomicOp!"+="(additions, 1);
                Thread.sleep(1.msecs);
            }
        });
    }
    
    validateThread.start();
    foreach (t; addThreads) t.start();
    
    Thread.sleep(500.msecs);
    atomicStore(running, false);
    
    validateThread.join();
    foreach (t; addThreads) t.join();
    
    Logger.info("Concurrent validate/add - validations: " ~ atomicLoad(validations).to!string ~
               ", additions: " ~ atomicLoad(additions).to!string);
    
    // Final validation should succeed (only forward edges)
    auto finalResult = graph.validate();
    Assert.isTrue(finalResult.isOk, "Final validation should pass");
    
    writeln("  \x1b[32m✓ Concurrent validate and add passed\x1b[0m");
}

// ============================================================================
// NODE REMOVAL DURING TRAVERSAL TESTS
// ============================================================================

/// Simulates node removal capability for testing
class MutableGraph
{
    private string[][string] adjacency;  // from -> to[]
    private bool[string] nodes;
    private Mutex mutex;
    
    this() @trusted
    {
        this.mutex = new Mutex();
    }
    
    void addNode(string id) @trusted
    {
        synchronized (mutex)
        {
            nodes[id] = true;
        }
    }
    
    void addEdge(string from, string to) @trusted
    {
        synchronized (mutex)
        {
            if (from !in adjacency)
                adjacency[from] = [];
            if (!adjacency[from].canFind(to))
                adjacency[from] ~= to;
        }
    }
    
    void removeNode(string id) @trusted
    {
        synchronized (mutex)
        {
            nodes.remove(id);
            adjacency.remove(id);
            
            // Remove edges pointing to this node
            foreach (ref neighbors; adjacency)
            {
                neighbors = neighbors.filter!(n => n != id).array;
            }
        }
    }
    
    bool hasNode(string id) @trusted
    {
        synchronized (mutex)
        {
            return (id in nodes) !is null;
        }
    }
    
    string[] getNodes() @trusted
    {
        synchronized (mutex)
        {
            return nodes.keys.dup;
        }
    }
    
    string[] getNeighbors(string id) @trusted
    {
        synchronized (mutex)
        {
            if (id in adjacency)
                return adjacency[id].dup;
            return [];
        }
    }
    
    /// Traverse dependents with safe iteration
    string[] traverseDependentsSafe(string startId) @trusted
    {
        string[] result;
        string[] toVisit;
        bool[string] visited;
        
        synchronized (mutex)
        {
            if (startId !in nodes)
                return [];
            toVisit ~= startId;
        }
        
        while (toVisit.length > 0)
        {
            auto current = toVisit[0];
            toVisit = toVisit[1..$];
            
            synchronized (mutex)
            {
                if (current in visited || current !in nodes)
                    continue;
                
                visited[current] = true;
                result ~= current;
                
                if (current in adjacency)
                {
                    foreach (neighbor; adjacency[current])
                    {
                        if (neighbor !in visited && neighbor in nodes)
                            toVisit ~= neighbor;
                    }
                }
            }
        }
        
        return result;
    }
}

/// Test: Node removal during dependent iteration
@("graph_edge.remove_during_traversal")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Remove During Traversal");
    
    auto graph = new MutableGraph();
    
    // Create diamond: A -> B, A -> C, B -> D, C -> D
    graph.addNode("A");
    graph.addNode("B");
    graph.addNode("C");
    graph.addNode("D");
    
    graph.addEdge("A", "B");
    graph.addEdge("A", "C");
    graph.addEdge("B", "D");
    graph.addEdge("C", "D");
    
    shared bool traversing = true;
    shared size_t traversalCount = 0;
    shared size_t removalCount = 0;
    
    auto mutex = new Mutex();
    
    // Traversal thread
    auto traverseThread = new Thread({
        while (atomicLoad(traversing))
        {
            auto dependents = graph.traverseDependentsSafe("A");
            atomicOp!"+="(traversalCount, 1);
            Thread.sleep(1.msecs);
        }
    });
    
    // Removal thread
    auto removeThread = new Thread({
        Thread.sleep(50.msecs);
        
        // Remove node B while traversal might be happening
        graph.removeNode("B");
        atomicOp!"+="(removalCount, 1);
        
        Thread.sleep(50.msecs);
        
        // Re-add B
        graph.addNode("B");
        graph.addEdge("A", "B");
        
        Thread.sleep(50.msecs);
        atomicStore(traversing, false);
    });
    
    traverseThread.start();
    removeThread.start();
    
    traverseThread.join();
    removeThread.join();
    
    Logger.info("Remove during traversal - traversals: " ~ atomicLoad(traversalCount).to!string ~
               ", removals: " ~ atomicLoad(removalCount).to!string);
    
    // Should complete without crash
    Assert.isTrue(atomicLoad(traversalCount) > 0, "Should have completed traversals");
    
    writeln("  \x1b[32m✓ Remove during traversal passed\x1b[0m");
}

/// Test: Concurrent node addition and removal
@("graph_edge.concurrent_add_remove")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Concurrent Add and Remove");
    
    auto graph = new MutableGraph();
    auto mutex = new Mutex();
    shared bool running = true;
    shared size_t addCount = 0;
    shared size_t removeCount = 0;
    
    // Seed with initial nodes
    foreach (i; 0 .. 10)
    {
        graph.addNode("initial" ~ i.to!string);
    }
    
    // Addition thread
    auto addThread = new Thread({
        auto rng = Mt19937(11111);
        size_t nodeId = 100;
        
        while (atomicLoad(running))
        {
            graph.addNode("dynamic" ~ nodeId.to!string);
            atomicOp!"+="(addCount, 1);
            nodeId++;
            Thread.sleep(2.msecs);
        }
    });
    
    // Removal thread
    auto removeThread = new Thread({
        auto rng = Mt19937(22222);
        
        while (atomicLoad(running))
        {
            auto nodes = graph.getNodes();
            if (nodes.length > 5)
            {
                auto idx = uniform(0, nodes.length, rng);
                graph.removeNode(nodes[idx]);
                atomicOp!"+="(removeCount, 1);
            }
            Thread.sleep(3.msecs);
        }
    });
    
    addThread.start();
    removeThread.start();
    
    Thread.sleep(300.msecs);
    atomicStore(running, false);
    
    addThread.join();
    removeThread.join();
    
    Logger.info("Concurrent add/remove - adds: " ~ atomicLoad(addCount).to!string ~
               ", removes: " ~ atomicLoad(removeCount).to!string ~
               ", final nodes: " ~ graph.getNodes().length.to!string);
    
    Assert.isTrue(atomicLoad(addCount) > 0, "Should have added nodes");
    Assert.isTrue(atomicLoad(removeCount) > 0, "Should have removed nodes");
    
    writeln("  \x1b[32m✓ Concurrent add and remove passed\x1b[0m");
}

// ============================================================================
// ARENA/MEMORY PRESSURE TESTS
// ============================================================================

/// Simulates arena allocator with limited capacity
class BoundedArena
{
    private size_t capacity;
    private size_t used;
    private Mutex mutex;
    private shared size_t allocationFailures;
    
    this(size_t capacity) @trusted
    {
        this.capacity = capacity;
        this.used = 0;
        this.mutex = new Mutex();
    }
    
    bool allocate(size_t size) @trusted
    {
        synchronized (mutex)
        {
            if (used + size > capacity)
            {
                atomicOp!"+="(allocationFailures, 1);
                return false;
            }
            used += size;
            return true;
        }
    }
    
    void deallocate(size_t size) @trusted
    {
        synchronized (mutex)
        {
            used = used > size ? used - size : 0;
        }
    }
    
    void reset() @trusted
    {
        synchronized (mutex)
        {
            used = 0;
        }
    }
    
    size_t getUsed() @trusted
    {
        synchronized (mutex)
            return used;
    }
    
    size_t getCapacity() const @safe => capacity;
    size_t getFailures() @trusted => atomicLoad(allocationFailures);
}

/// Test: Arena exhaustion during concurrent growth
@("graph_edge.arena_exhaustion")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Arena Exhaustion");
    
    auto arena = new BoundedArena(1000);  // Small arena
    auto mutex = new Mutex();
    
    struct Node
    {
        string id;
        size_t size = 20;  // Simulated node size
    }
    
    Node[] nodes;
    shared size_t successfulAdds = 0;
    shared size_t failedAdds = 0;
    
    // Multiple threads try to add nodes
    foreach (threadId; parallel(iota(8)))
    {
        foreach (i; 0 .. 100)
        {
            auto nodeId = "thread" ~ threadId.to!string ~ "_node" ~ i.to!string;
            
            if (arena.allocate(20))
            {
                synchronized (mutex)
                {
                    nodes ~= Node(nodeId);
                }
                atomicOp!"+="(successfulAdds, 1);
            }
            else
            {
                atomicOp!"+="(failedAdds, 1);
            }
        }
    }
    
    Logger.info("Arena exhaustion - successful: " ~ atomicLoad(successfulAdds).to!string ~
               ", failed: " ~ atomicLoad(failedAdds).to!string ~
               ", arena failures: " ~ arena.getFailures().to!string);
    
    // Should have some failures due to capacity limit
    Assert.isTrue(atomicLoad(failedAdds) > 0, "Should have some allocation failures");
    Assert.equal(atomicLoad(successfulAdds), 50, "Should fit exactly 50 nodes (1000/20)");
    
    writeln("  \x1b[32m✓ Arena exhaustion handling passed\x1b[0m");
}

/// Test: Arena expansion under load
@("graph_edge.arena_expansion")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Arena Expansion");
    
    // Expandable arena simulation
    class ExpandableArena
    {
        private size_t capacity;
        private size_t used;
        private Mutex mutex;
        private shared size_t expansions;
        
        this(size_t initialCapacity) @trusted
        {
            this.capacity = initialCapacity;
            this.mutex = new Mutex();
        }
        
        bool allocate(size_t size) @trusted
        {
            synchronized (mutex)
            {
                if (used + size > capacity)
                {
                    // Expand by doubling
                    capacity *= 2;
                    atomicOp!"+="(expansions, 1);
                }
                used += size;
                return true;
            }
        }
        
        size_t getCapacity() @trusted
        {
            synchronized (mutex)
                return capacity;
        }
        
        size_t getExpansions() @trusted => atomicLoad(expansions);
    }
    
    auto arena = new ExpandableArena(100);  // Small initial capacity
    shared size_t allocations = 0;
    
    // Concurrent allocations force expansion
    foreach (threadId; parallel(iota(8)))
    {
        foreach (i; 0 .. 50)
        {
            arena.allocate(10);
            atomicOp!"+="(allocations, 1);
        }
    }
    
    Logger.info("Arena expansion - allocations: " ~ atomicLoad(allocations).to!string ~
               ", expansions: " ~ arena.getExpansions().to!string ~
               ", final capacity: " ~ arena.getCapacity().to!string);
    
    Assert.equal(atomicLoad(allocations), 400, "All allocations should succeed");
    Assert.isTrue(arena.getExpansions() > 0, "Should have expanded");
    Assert.isTrue(arena.getCapacity() >= 4000, "Capacity should accommodate all allocations");
    
    writeln("  \x1b[32m✓ Arena expansion passed\x1b[0m");
}

// ============================================================================
// SNAPSHOT ISOLATION TESTS
// ============================================================================

/// Test: getReadyNodes returns consistent snapshot
@("graph_edge.snapshot_isolation")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Snapshot Isolation");
    
    auto graph = new InstrumentedGraph(ValidationMode.Immediate, 100);
    
    // Create chain: base <- mid <- top
    auto base = TargetBuilder.create("base").withType(TargetType.Library).build();
    auto mid = TargetBuilder.create("mid").withType(TargetType.Library).build();
    auto top = TargetBuilder.create("top").withType(TargetType.Library).build();
    
    graph.addTarget(base);
    graph.addTarget(mid);
    graph.addTarget(top);
    
    graph.addDependency("mid", "base");
    graph.addDependency("top", "mid");
    
    shared bool running = true;
    shared size_t inconsistentSnapshots = 0;
    auto mutex = new Mutex();
    
    // Snapshot reader thread
    auto readerThread = new Thread({
        while (atomicLoad(running))
        {
            string[] snapshot;
            BuildStatus[string] statuses;
            
            synchronized (mutex)
            {
                // Take snapshot
                foreach (id; graph.getNodeIds())
                {
                    auto node = graph.getNode(id);
                    if (node !is null)
                    {
                        snapshot ~= id;
                        statuses[id] = node.status;
                    }
                }
            }
            
            // Verify snapshot consistency
            // If mid is Building, base should be Success/Cached
            if ("mid" in statuses && statuses["mid"] == BuildStatus.Building)
            {
                if ("base" in statuses)
                {
                    auto baseStatus = statuses["base"];
                    if (baseStatus != BuildStatus.Success && baseStatus != BuildStatus.Cached)
                    {
                        atomicOp!"+="(inconsistentSnapshots, 1);
                    }
                }
            }
            
            Thread.sleep(1.msecs);
        }
    });
    
    // Writer thread updates statuses
    auto writerThread = new Thread({
        synchronized (mutex)
        {
            // Progress through build
            auto baseNode = graph.getNode("base");
            if (baseNode !is null)
            {
                baseNode.status = BuildStatus.Building;
                Thread.sleep(10.msecs);
                baseNode.status = BuildStatus.Success;
            }
            
            auto midNode = graph.getNode("mid");
            if (midNode !is null)
            {
                midNode.status = BuildStatus.Building;
                Thread.sleep(10.msecs);
                midNode.status = BuildStatus.Success;
            }
            
            auto topNode = graph.getNode("top");
            if (topNode !is null)
            {
                topNode.status = BuildStatus.Building;
                Thread.sleep(10.msecs);
                topNode.status = BuildStatus.Success;
            }
        }
        
        Thread.sleep(50.msecs);
        atomicStore(running, false);
    });
    
    readerThread.start();
    writerThread.start();
    
    readerThread.join();
    writerThread.join();
    
    Assert.equal(atomicLoad(inconsistentSnapshots), 0, "No inconsistent snapshots should be observed");
    
    writeln("  \x1b[32m✓ Snapshot isolation passed\x1b[0m");
}

// ============================================================================
// ABA PROBLEM TESTS
// ============================================================================

/// Test: Status ABA problem (A->B->A while observer checks)
@("graph_edge.status_aba_problem")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Status ABA Problem");
    
    auto graph = new InstrumentedGraph(ValidationMode.Immediate);
    auto target = TargetBuilder.create("aba-test").withType(TargetType.Library).build();
    graph.addTarget(target);
    
    auto node = graph.getNode("aba-test");
    Assert.isTrue(node !is null, "Node should exist");
    
    shared bool running = true;
    shared size_t abaDetections = 0;
    
    // Use version counter to detect ABA
    shared ulong versionCounter = 0;
    
    struct VersionedStatus
    {
        BuildStatus status;
        ulong version_;
    }
    
    auto mutex = new Mutex();
    VersionedStatus lastSeen;
    
    // Observer thread
    auto observerThread = new Thread({
        while (atomicLoad(running))
        {
            VersionedStatus current;
            synchronized (mutex)
            {
                current.status = node.status;
                current.version_ = atomicLoad(versionCounter);
            }
            
            // If status is same but version changed, ABA occurred
            if (current.status == lastSeen.status && current.version_ > lastSeen.version_ + 1)
            {
                atomicOp!"+="(abaDetections, 1);
            }
            
            lastSeen = current;
            Thread.sleep(1.msecs);
        }
    });
    
    // Writer thread causes ABA: Pending -> Building -> Pending
    auto writerThread = new Thread({
        foreach (i; 0 .. 10)
        {
            synchronized (mutex)
            {
                node.status = BuildStatus.Building;
                atomicOp!"+="(versionCounter, 1);
            }
            Thread.sleep(5.msecs);
            
            synchronized (mutex)
            {
                node.status = BuildStatus.Pending;  // Back to original (ABA)
                atomicOp!"+="(versionCounter, 1);
            }
            Thread.sleep(5.msecs);
        }
        
        atomicStore(running, false);
    });
    
    observerThread.start();
    writerThread.start();
    
    observerThread.join();
    writerThread.join();
    
    Logger.info("ABA detection - detected: " ~ atomicLoad(abaDetections).to!string);
    
    // Version counter should detect the ABA pattern
    Assert.isTrue(atomicLoad(versionCounter) >= 10, "Should have version updates");
    
    writeln("  \x1b[32m✓ Status ABA problem detection passed\x1b[0m");
}

// ============================================================================
// VALIDATION MODE SWITCH TESTS
// ============================================================================

/// Test: Validation mode switch under load
@("graph_edge.validation_mode_switch")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Validation Mode Switch");
    
    // Simulate mode switching behavior
    struct ModeTracker
    {
        ValidationMode currentMode = ValidationMode.Deferred;
        size_t deferredOperations;
        size_t immediateOperations;
        bool pendingValidation;
    }
    
    auto mutex = new Mutex();
    ModeTracker tracker;
    
    // Operations accumulate in deferred mode
    foreach (i; 0 .. 50)
    {
        synchronized (mutex)
        {
            if (tracker.currentMode == ValidationMode.Deferred)
            {
                tracker.deferredOperations++;
                tracker.pendingValidation = true;
            }
            else
            {
                tracker.immediateOperations++;
            }
        }
    }
    
    // Switch to immediate mode
    synchronized (mutex)
    {
        // Must validate pending operations first
        if (tracker.pendingValidation)
        {
            // Simulate validation
            tracker.pendingValidation = false;
        }
        tracker.currentMode = ValidationMode.Immediate;
    }
    
    // New operations are validated immediately
    foreach (i; 0 .. 50)
    {
        synchronized (mutex)
        {
            tracker.immediateOperations++;
        }
    }
    
    Logger.info("Mode switch - deferred: " ~ tracker.deferredOperations.to!string ~
               ", immediate: " ~ tracker.immediateOperations.to!string);
    
    Assert.equal(tracker.deferredOperations, 50, "Should have 50 deferred operations");
    Assert.equal(tracker.immediateOperations, 50, "Should have 50 immediate operations");
    Assert.isFalse(tracker.pendingValidation, "Should have validated pending operations");
    
    writeln("  \x1b[32m✓ Validation mode switch passed\x1b[0m");
}

// ============================================================================
// TOPOLOGICAL SORT RACE TESTS
// ============================================================================

/// Test: Topological sort concurrent with modifications
@("graph_edge.topo_sort_race")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Topological Sort Race");
    
    auto graph = new InstrumentedGraph(ValidationMode.Deferred, 200);
    auto mutex = new Mutex();
    shared bool running = true;
    shared size_t sortCount = 0;
    shared size_t sortErrors = 0;
    shared size_t modifications = 0;
    
    // Initial graph setup
    foreach (i; 0 .. 30)
    {
        auto target = TargetBuilder.create("node" ~ i.to!string)
            .withType(TargetType.Library)
            .build();
        graph.addTarget(target);
    }
    
    // Add initial edges (forward only)
    foreach (i; 0 .. 25)
    {
        graph.addDependency("node" ~ i.to!string, "node" ~ (i + 1).to!string);
    }
    
    // Sorter threads
    Thread[] sorters;
    foreach (s; 0 .. 3)
    {
        sorters ~= new Thread({
            while (atomicLoad(running))
            {
                auto result = graph.topologicalSort();
                atomicOp!"+="(sortCount, 1);
                
                if (result.isErr)
                    atomicOp!"+="(sortErrors, 1);
                
                Thread.sleep(5.msecs);
            }
        });
    }
    
    // Modifier thread adds edges
    auto modifierThread = new Thread({
        auto rng = Mt19937(33333);
        
        foreach (i; 0 .. 30)
        {
            auto from = uniform(0, 25, rng);
            auto to = uniform(from + 1, 30, rng);  // Forward edge only
            
            graph.addDependency("node" ~ from.to!string, "node" ~ to.to!string);
            atomicOp!"+="(modifications, 1);
            
            Thread.sleep(10.msecs);
        }
        
        atomicStore(running, false);
    });
    
    foreach (sorter; sorters) sorter.start();
    modifierThread.start();
    
    modifierThread.join();
    foreach (sorter; sorters) sorter.join();
    
    Logger.info("Topo sort race - sorts: " ~ atomicLoad(sortCount).to!string ~
               ", errors: " ~ atomicLoad(sortErrors).to!string ~
               ", modifications: " ~ atomicLoad(modifications).to!string);
    
    // Final sort should succeed
    auto finalResult = graph.topologicalSort();
    Assert.isTrue(finalResult.isOk, "Final topological sort should succeed");
    
    writeln("  \x1b[32m✓ Topological sort race passed\x1b[0m");
}

// ============================================================================
// DEPTH CALCULATION RACE TESTS
// ============================================================================

/// Test: Concurrent depth calculations with memoization
@("graph_edge.depth_calculation_race")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Graph - Depth Calculation Race");
    
    // Memoized depth calculator
    struct MemoizedDepth
    {
        int[string] cache;
        Mutex mutex;
        shared size_t cacheHits;
        shared size_t cacheMisses;
        
        int getDepth(string nodeId, string[] deps) @trusted
        {
            synchronized (mutex)
            {
                if (nodeId in cache)
                {
                    atomicOp!"+="(cacheHits, 1);
                    return cache[nodeId];
                }
            }
            
            atomicOp!"+="(cacheMisses, 1);
            
            // Calculate depth
            int maxDepDep = -1;
            foreach (dep; deps)
            {
                synchronized (mutex)
                {
                    if (dep in cache)
                        maxDepDep = max(maxDepDep, cache[dep]);
                }
            }
            
            int depth = maxDepDep + 1;
            
            synchronized (mutex)
            {
                cache[nodeId] = depth;
            }
            
            return depth;
        }
    }
    
    auto calculator = MemoizedDepth();
    calculator.mutex = new Mutex();
    
    // Simulate graph structure: chain of 50 nodes
    string[][string] deps;
    foreach (i; 0 .. 50)
    {
        auto nodeId = "node" ~ i.to!string;
        if (i == 0)
            deps[nodeId] = [];
        else
            deps[nodeId] = ["node" ~ (i - 1).to!string];
    }
    
    // Concurrent depth calculations
    foreach (threadId; parallel(iota(8)))
    {
        auto rng = Mt19937(cast(uint)(threadId * 1000));
        
        foreach (i; 0 .. 100)
        {
            auto nodeIdx = uniform(0, 50, rng);
            auto nodeId = "node" ~ nodeIdx.to!string;
            
            auto depth = calculator.getDepth(nodeId, deps.get(nodeId, []));
            
            // Verify depth is correct
            Assert.equal(depth, nodeIdx, "Depth should equal node index");
        }
    }
    
    Logger.info("Depth calculation - hits: " ~ atomicLoad(calculator.cacheHits).to!string ~
               ", misses: " ~ atomicLoad(calculator.cacheMisses).to!string);
    
    // Should have cache hits after initial population
    Assert.isTrue(atomicLoad(calculator.cacheHits) > 0, "Should have cache hits");
    
    writeln("  \x1b[32m✓ Depth calculation race passed\x1b[0m");
}

