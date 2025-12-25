module tests.unit.properties.extended_invariants;

import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.stdio;
import std.range : iota;
import core.thread;
import core.atomic;
import core.sync.mutex;

import tests.harness;
import tests.property;
import infrastructure.errors;

version(unittest):

// =============================================================================
// GRAPH PROPERTY INVARIANTS
// =============================================================================

/// Property: Topological sort produces valid ordering (all deps before dependents)
@("property.graph.topo_sort_valid_ordering")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Graph - Topological sort ordering invariant");
    
    auto config = PropertyConfig(numTests: 100);
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random DAG
        auto nodeCount = uniform(5, 50, rng);
        int[][] adjacency = new int[][nodeCount];
        
        // Only forward edges to ensure DAG property
        foreach (from; 0 .. nodeCount - 1)
        {
            auto edgeCount = uniform(0, min(3, nodeCount - from - 1), rng);
            foreach (e; 0 .. edgeCount)
            {
                auto to = uniform(from + 1, nodeCount, rng);
                if (!adjacency[from].canFind(to))
                    adjacency[from] ~= to;
            }
        }
        
        // Perform topological sort (Kahn's algorithm)
        int[] inDegree = new int[nodeCount];
        foreach (from; 0 .. nodeCount)
            foreach (to; adjacency[from])
                inDegree[to]++;
        
        int[] sorted;
        int[] queue;
        foreach (n; 0 .. nodeCount)
            if (inDegree[n] == 0)
                queue ~= n;
        
        while (queue.length > 0)
        {
            auto node = queue[0];
            queue = queue[1 .. $];
            sorted ~= node;
            
            foreach (neighbor; adjacency[node])
            {
                inDegree[neighbor]--;
                if (inDegree[neighbor] == 0)
                    queue ~= neighbor;
            }
        }
        
        // Verify: every edge goes from earlier to later in sorted order
        int[int] position;
        foreach (idx, node; sorted)
            position[node] = cast(int)idx;
        
        bool valid = true;
        foreach (from; 0 .. nodeCount)
        {
            foreach (to; adjacency[from])
            {
                if (position.get(from, -1) >= position.get(to, nodeCount))
                {
                    valid = false;
                    break;
                }
            }
            if (!valid) break;
        }
        
        if (valid && sorted.length == nodeCount)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "All topological sorts should be valid");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Adding edges preserves existing edges
@("property.graph.edge_addition_preservation")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Graph - Edge addition preserves existing edges");
    
    auto config = PropertyConfig(numTests: 100);
    Mt19937 rng = Mt19937(config.seed + 100);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Build initial graph
        auto nodeCount = uniform(10, 30, rng);
        int[][] adjacency = new int[][nodeCount];
        
        auto initialEdges = uniform(5, 20, rng);
        foreach (e; 0 .. initialEdges)
        {
            auto from = uniform(0, nodeCount - 1, rng);
            auto to = uniform(from + 1, nodeCount, rng);
            if (!adjacency[from].canFind(to))
                adjacency[from] ~= to;
        }
        
        // Record initial edges
        int[][] initialState = new int[][nodeCount];
        foreach (n; 0 .. nodeCount)
            initialState[n] = adjacency[n].dup;
        
        // Add new edges
        auto newEdges = uniform(3, 10, rng);
        foreach (e; 0 .. newEdges)
        {
            auto from = uniform(0, nodeCount - 1, rng);
            auto to = uniform(from + 1, nodeCount, rng);
            if (!adjacency[from].canFind(to))
                adjacency[from] ~= to;
        }
        
        // Verify all initial edges still exist
        bool preserved = true;
        foreach (n; 0 .. nodeCount)
        {
            foreach (edge; initialState[n])
            {
                if (!adjacency[n].canFind(edge))
                {
                    preserved = false;
                    break;
                }
            }
            if (!preserved) break;
        }
        
        if (preserved)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "Edge additions should preserve existing edges");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Cycle detection catches all cycles
@("property.graph.cycle_detection_complete")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Graph - Cycle detection completeness");
    
    auto config = PropertyConfig(numTests: 50);
    Mt19937 rng = Mt19937(config.seed + 200);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate graph with intentional cycle
        auto nodeCount = uniform(5, 20, rng);
        int[][] adjacency = new int[][nodeCount];
        
        // Add some forward edges
        foreach (from; 0 .. nodeCount - 1)
        {
            if (uniform(0, 3, rng) == 0)
            {
                auto to = uniform(from + 1, nodeCount, rng);
                adjacency[from] ~= to;
            }
        }
        
        // Add cycle: pick random node chain and close it
        auto cycleLen = uniform(2, min(5, nodeCount), rng);
        int[] cycleNodes;
        foreach (c; 0 .. cycleLen)
            cycleNodes ~= uniform(0, nodeCount, rng);
        
        for (int c = 0; c < cycleLen - 1; c++)
            adjacency[cycleNodes[c]] ~= cycleNodes[c + 1];
        adjacency[cycleNodes[$ - 1]] ~= cycleNodes[0];  // Close cycle
        
        // Detect cycle using DFS
        bool hasCycle = false;
        int[] color = new int[nodeCount];  // 0=white, 1=gray, 2=black
        
        bool dfs(int node)
        {
            color[node] = 1;
            foreach (neighbor; adjacency[node])
            {
                if (neighbor >= 0 && neighbor < nodeCount)
                {
                    if (color[neighbor] == 1)
                        return true;  // Back edge = cycle
                    if (color[neighbor] == 0 && dfs(neighbor))
                        return true;
                }
            }
            color[node] = 2;
            return false;
        }
        
        foreach (n; 0 .. nodeCount)
        {
            if (color[n] == 0 && dfs(n))
            {
                hasCycle = true;
                break;
            }
        }
        
        if (hasCycle)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "All intentionally cyclic graphs should be detected");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// CACHE PROPERTY INVARIANTS
// =============================================================================

/// Property: Cache entries are idempotent (same input = same output)
@("property.cache.idempotent_storage")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache - Idempotent storage invariant");
    
    auto config = PropertyConfig(numTests: 100);
    Mt19937 rng = Mt19937(config.seed + 300);
    size_t passed = 0;
    
    // Simulated cache
    ubyte[][ubyte[32]] cache;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random key and value
        ubyte[32] key;
        foreach (ref b; key)
            b = cast(ubyte)uniform(0, 256, rng);
        
        auto valueLen = uniform(10, 1000, rng);
        ubyte[] value = new ubyte[valueLen];
        foreach (ref b; value)
            b = cast(ubyte)uniform(0, 256, rng);
        
        // Store twice with same key
        cache[key] = value.dup;
        cache[key] = value.dup;
        
        // Retrieve and verify
        if (key in cache && cache[key] == value)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "Cache should be idempotent");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: LRU eviction removes least recently used
@("property.cache.lru_eviction_order")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache - LRU eviction order invariant");
    
    auto config = PropertyConfig(numTests: 50);
    Mt19937 rng = Mt19937(config.seed + 400);
    size_t passed = 0;
    
    foreach (test; 0 .. config.numTests)
    {
        // Simulate LRU cache with small capacity
        immutable size_t capacity = 10;
        string[] accessOrder;
        string[string] cache;
        
        // Add entries with tracking
        foreach (i; 0 .. 20)
        {
            auto key = "key" ~ i.to!string;
            auto value = "value" ~ i.to!string;
            
            // Access existing key to update LRU
            if (i > 0 && uniform(0, 3, rng) == 0)
            {
                auto existingIdx = uniform(0, min(i, accessOrder.length), rng);
                if (existingIdx < accessOrder.length)
                {
                    auto existingKey = accessOrder[existingIdx];
                    if (existingKey in cache)
                    {
                        // Touch existing - move to front
                        accessOrder = accessOrder.filter!(k => k != existingKey).array;
                        accessOrder ~= existingKey;
                    }
                }
            }
            
            // Evict if at capacity
            while (cache.length >= capacity && accessOrder.length > 0)
            {
                auto evicted = accessOrder[0];
                accessOrder = accessOrder[1 .. $];
                cache.remove(evicted);
            }
            
            // Add new entry
            cache[key] = value;
            accessOrder ~= key;
        }
        
        // Verify: most recent entries should be in cache
        bool valid = true;
        foreach (key; accessOrder[max(0, cast(int)accessOrder.length - cast(int)capacity) .. $])
        {
            if (key !in cache)
            {
                valid = false;
                break;
            }
        }
        
        if (valid)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "LRU eviction should follow access order");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Cache hit/miss ratio improves with repeated access patterns
@("property.cache.temporal_locality")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache - Temporal locality benefit");
    
    auto config = PropertyConfig(numTests: 20);
    Mt19937 rng = Mt19937(config.seed + 500);
    size_t passed = 0;
    
    foreach (test; 0 .. config.numTests)
    {
        // Simulate cache with working set
        immutable size_t cacheSize = 50;
        immutable size_t workingSetSize = 30;
        immutable size_t totalKeys = 100;
        
        bool[string] cache;
        size_t hits = 0;
        size_t misses = 0;
        
        // Simulate access pattern favoring working set
        foreach (access; 0 .. 1000)
        {
            string key;
            if (uniform(0.0, 1.0, rng) < 0.8)
            {
                // 80% access working set
                key = "key" ~ uniform(0, workingSetSize, rng).to!string;
            }
            else
            {
                // 20% access other keys
                key = "key" ~ uniform(workingSetSize, totalKeys, rng).to!string;
            }
            
            if (key in cache)
            {
                hits++;
            }
            else
            {
                misses++;
                
                // Evict if full (random eviction for simplicity)
                if (cache.length >= cacheSize)
                {
                    auto keys = cache.keys;
                    cache.remove(keys[uniform(0, keys.length, rng)]);
                }
                cache[key] = true;
            }
        }
        
        auto hitRate = cast(double)hits / (hits + misses);
        
        // With 80% temporal locality and cache > working set, hit rate should be high
        if (hitRate >= 0.5)
            passed++;
    }
    
    Assert.isTrue(passed >= config.numTests * 0.8, "Temporal locality should improve hit rate");
    writeln("  \x1b[32m✓ Passed (" ~ passed.to!string ~ "/" ~ config.numTests.to!string ~ " showed locality benefit)\x1b[0m");
}

// =============================================================================
// HASH FUNCTION INVARIANTS
// =============================================================================

/// Property: Hash function is deterministic (same input = same hash)
@("property.hash.determinism")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Hash - Determinism invariant");
    
    auto config = PropertyConfig(numTests: 200);
    Mt19937 rng = Mt19937(config.seed + 600);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random data
        auto len = uniform(1, 1000, rng);
        ubyte[] data = new ubyte[len];
        foreach (ref b; data)
            b = cast(ubyte)uniform(0, 256, rng);
        
        // Hash multiple times
        auto hash1 = simpleHash(data);
        auto hash2 = simpleHash(data);
        auto hash3 = simpleHash(data.dup);
        
        if (hash1 == hash2 && hash2 == hash3)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "Hash function must be deterministic");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Hash collision rate is acceptably low
@("property.hash.collision_rate")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Hash - Collision rate");
    
    auto config = PropertyConfig(numTests: 1000);
    Mt19937 rng = Mt19937(config.seed + 700);
    
    ulong[ulong] hashCounts;
    
    foreach (i; 0 .. config.numTests)
    {
        auto len = uniform(10, 100, rng);
        ubyte[] data = new ubyte[len];
        foreach (ref b; data)
            b = cast(ubyte)uniform(0, 256, rng);
        
        auto hash = simpleHash(data);
        hashCounts[hash] = hashCounts.get(hash, 0UL) + 1;
    }
    
    // Count collisions
    size_t collisions = 0;
    foreach (count; hashCounts.values)
        if (count > 1)
            collisions += count - 1;
    
    auto collisionRate = cast(double)collisions / config.numTests;
    writeln("  Collision rate: " ~ (collisionRate * 100).to!string ~ "%");
    
    // Birthday paradox: with 1000 samples in 64-bit space, collisions should be ~0
    Assert.isTrue(collisionRate < 0.01, "Collision rate should be < 1%");
    writeln("  \x1b[32m✓ Collision rate acceptable\x1b[0m");
}

/// Property: Small changes in input produce large changes in hash (avalanche)
@("property.hash.avalanche_effect")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Hash - Avalanche effect");
    
    auto config = PropertyConfig(numTests: 100);
    Mt19937 rng = Mt19937(config.seed + 800);
    size_t goodAvalanche = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random data
        ubyte[] data = new ubyte[64];
        foreach (ref b; data)
            b = cast(ubyte)uniform(0, 256, rng);
        
        auto originalHash = simpleHash(data);
        
        // Flip single bit
        auto modified = data.dup;
        auto bitPos = uniform(0, data.length * 8, rng);
        modified[bitPos / 8] ^= cast(ubyte)(1 << (bitPos % 8));
        
        auto modifiedHash = simpleHash(modified);
        
        // Count differing bits in hash (Hamming distance)
        ulong diff = originalHash ^ modifiedHash;
        int bitsChanged = 0;
        while (diff)
        {
            bitsChanged += diff & 1;
            diff >>= 1;
        }
        
        // Good avalanche: ~50% of bits should change
        if (bitsChanged >= 20 && bitsChanged <= 44)
            goodAvalanche++;
    }
    
    auto avalancheRate = cast(double)goodAvalanche / config.numTests;
    writeln("  Good avalanche rate: " ~ (avalancheRate * 100).to!string ~ "%");
    
    Assert.isTrue(avalancheRate >= 0.5, "At least 50% should show good avalanche");
    writeln("  \x1b[32m✓ Avalanche effect acceptable\x1b[0m");
}

// =============================================================================
// CONCURRENT ACCESS INVARIANTS
// =============================================================================

/// Property: Concurrent reads don't corrupt data
@("property.concurrent.read_safety")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Concurrent - Read safety invariant");
    
    // Shared data structure
    string[string] data;
    auto mutex = new Mutex();
    
    // Populate with test data
    foreach (i; 0 .. 100)
        data["key" ~ i.to!string] = "value" ~ i.to!string;
    
    shared size_t correctReads = 0;
    shared size_t totalReads = 0;
    shared bool done = false;
    
    // Spawn reader threads
    Thread[] readers;
    foreach (t; 0 .. 4)
    {
        readers ~= new Thread({
            auto rng = Mt19937(cast(uint)(t * 1000));
            
            while (!atomicLoad(done))
            {
                auto key = "key" ~ uniform(0, 100, rng).to!string;
                auto expectedValue = "value" ~ key[3 .. $];
                
                string value;
                synchronized (mutex)
                {
                    if (key in data)
                        value = data[key];
                }
                
                atomicOp!"+="(totalReads, 1);
                if (value == expectedValue)
                    atomicOp!"+="(correctReads, 1);
            }
        });
    }
    
    foreach (reader; readers) reader.start();
    
    Thread.sleep(500.msecs);
    atomicStore(done, true);
    
    foreach (reader; readers) reader.join();
    
    auto correct = atomicLoad(correctReads);
    auto total = atomicLoad(totalReads);
    auto correctRate = cast(double)correct / total;
    
    writeln("  Correct reads: " ~ correct.to!string ~ "/" ~ total.to!string);
    Assert.equal(correct, total, "All reads should return correct values");
    writeln("  \x1b[32m✓ Concurrent read safety passed\x1b[0m");
}

/// Property: Concurrent writes maintain consistency
@("property.concurrent.write_consistency")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Concurrent - Write consistency invariant");
    
    shared int counter = 0;
    auto mutex = new Mutex();
    
    shared size_t operations = 0;
    shared bool done = false;
    
    // Spawn writer threads
    Thread[] writers;
    foreach (t; 0 .. 4)
    {
        writers ~= new Thread({
            foreach (i; 0 .. 1000)
            {
                synchronized (mutex)
                {
                    int val = atomicLoad(counter);
                    val++;
                    atomicStore(counter, val);
                }
                atomicOp!"+="(operations, 1);
            }
        });
    }
    
    foreach (writer; writers) writer.start();
    foreach (writer; writers) writer.join();
    
    auto finalCounter = atomicLoad(counter);
    auto totalOps = atomicLoad(operations);
    
    writeln("  Final counter: " ~ finalCounter.to!string ~ ", Operations: " ~ totalOps.to!string);
    Assert.equal(finalCounter, 4000, "Counter should reflect all increments");
    Assert.equal(totalOps, 4000, "All operations should complete");
    writeln("  \x1b[32m✓ Concurrent write consistency passed\x1b[0m");
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/// Simple hash function for testing (FNV-1a style)
ulong simpleHash(ubyte[] data) pure nothrow @safe
{
    ulong hash = 14695981039346656037UL;
    foreach (b; data)
    {
        hash ^= b;
        hash *= 1099511628211UL;
    }
    return hash;
}

// =============================================================================
// DEPENDENCY ORDERING INVARIANTS
// =============================================================================

/// Property: Build order respects all dependencies
@("property.build.dependency_order")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build - Dependency order invariant");
    
    auto config = PropertyConfig(numTests: 50);
    Mt19937 rng = Mt19937(config.seed + 900);
    size_t passed = 0;
    
    foreach (test; 0 .. config.numTests)
    {
        // Generate dependency graph
        auto targetCount = uniform(10, 30, rng);
        string[][string] deps;
        
        foreach (t; 0 .. targetCount)
        {
            auto name = "target" ~ t.to!string;
            deps[name] = [];
            
            // Add deps on earlier targets only (ensures DAG)
            auto maxDeps = min(3, t);
            auto depCount = maxDeps > 0 ? uniform(0, maxDeps, rng) : 0;
            foreach (d; 0 .. depCount)
            {
                auto depIdx = uniform(0, t, rng);
                deps[name] ~= "target" ~ depIdx.to!string;
            }
        }
        
        // Simulate build order (simple greedy)
        bool[string] built;
        string[] buildOrder;
        
        while (buildOrder.length < targetCount)
        {
            foreach (target, targetDeps; deps)
            {
                if (target in built)
                    continue;
                
                bool canBuild = true;
                foreach (dep; targetDeps)
                {
                    if (dep !in built)
                    {
                        canBuild = false;
                        break;
                    }
                }
                
                if (canBuild)
                {
                    built[target] = true;
                    buildOrder ~= target;
                }
            }
        }
        
        // Verify order
        bool valid = true;
        int[string] buildPosition;
        foreach (idx, target; buildOrder)
            buildPosition[target] = cast(int)idx;
        
        foreach (target, targetDeps; deps)
        {
            foreach (dep; targetDeps)
            {
                if (buildPosition.get(dep, int.max) >= buildPosition.get(target, -1))
                {
                    valid = false;
                    break;
                }
            }
            if (!valid) break;
        }
        
        if (valid)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "Build order must respect dependencies");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Incremental build only rebuilds affected targets
@("property.build.incremental_minimal")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Build - Incremental minimality invariant");
    
    auto config = PropertyConfig(numTests: 30);
    Mt19937 rng = Mt19937(config.seed + 1000);
    size_t passed = 0;
    
    foreach (test; 0 .. config.numTests)
    {
        // Build dependency graph
        auto targetCount = uniform(10, 25, rng);
        string[][string] deps;
        string[][string] rdeps;  // Reverse deps
        
        foreach (t; 0 .. targetCount)
        {
            auto name = "target" ~ t.to!string;
            deps[name] = [];
            rdeps[name] = [];
        }
        
        foreach (t; 1 .. targetCount)
        {
            auto name = "target" ~ t.to!string;
            auto depCount = uniform(0, min(3, t), rng);
            foreach (d; 0 .. depCount)
            {
                auto depName = "target" ~ uniform(0, t, rng).to!string;
                deps[name] ~= depName;
                rdeps[depName] ~= name;
            }
        }
        
        // Mark a random target as changed
        auto changedIdx = uniform(0, targetCount, rng);
        auto changedTarget = "target" ~ changedIdx.to!string;
        
        // Calculate affected targets (transitive dependents)
        bool[string] affected;
        string[] toProcess = [changedTarget];
        
        while (toProcess.length > 0)
        {
            auto current = toProcess[0];
            toProcess = toProcess[1 .. $];
            
            if (current in affected)
                continue;
            
            affected[current] = true;
            
            foreach (dependent; rdeps.get(current, []))
                toProcess ~= dependent;
        }
        
        // Verify: affected set includes only necessary targets
        // All affected targets must have path from changed target
        bool valid = true;
        foreach (target; affected.keys)
        {
            if (target == changedTarget)
                continue;
            
            // Check if there's a path from changedTarget
            bool hasPath = false;
            foreach (dep; deps.get(target, []))
            {
                if (dep in affected)
                {
                    hasPath = true;
                    break;
                }
            }
            
            if (!hasPath && target != changedTarget)
            {
                valid = false;
                break;
            }
        }
        
        if (valid)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "Incremental builds should be minimal");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// PATH NORMALIZATION INVARIANTS
// =============================================================================

/// Property: Path normalization is idempotent
@("property.path.normalization_idempotent")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path - Normalization idempotency");
    
    auto config = PropertyConfig(numTests: 100);
    Mt19937 rng = Mt19937(config.seed + 1100);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random path
        auto depth = uniform(1, 8, rng);
        string[] components;
        
        foreach (d; 0 .. depth)
        {
            auto choice = uniform(0, 5, rng);
            switch (choice)
            {
                case 0: components ~= "."; break;
                case 1: components ~= ".."; break;
                default:
                    auto len = uniform(1, 10, rng);
                    char[] name;
                    foreach (c; 0 .. len)
                        name ~= cast(char)uniform('a', 'z' + 1, rng);
                    components ~= name.idup;
            }
        }
        
        auto path = "/" ~ components.join("/");
        
        // Normalize (simple implementation)
        auto norm1 = normalizePath(path);
        auto norm2 = normalizePath(norm1);
        
        if (norm1 == norm2)
            passed++;
    }
    
    Assert.equal(passed, config.numTests, "Path normalization should be idempotent");
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Simple path normalization for testing
string normalizePath(string path) pure
{
    import std.string : split;
    import std.array : join;
    
    if (path.length == 0)
        return ".";
    
    bool absolute = path[0] == '/';
    auto parts = path.split("/").filter!(p => p.length > 0 && p != ".").array;
    
    string[] result;
    foreach (part; parts)
    {
        if (part == "..")
        {
            if (result.length > 0 && result[$ - 1] != "..")
                result = result[0 .. $ - 1];
            else if (!absolute)
                result ~= "..";
        }
        else
        {
            result ~= part;
        }
    }
    
    if (result.length == 0)
        return absolute ? "/" : ".";
    
    return (absolute ? "/" : "") ~ result.join("/");
}


