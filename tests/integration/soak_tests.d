module tests.integration.soak_tests;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.string;
import std.range : iota;
import std.datetime : Duration, seconds, msecs, minutes, MonoTime, Clock;
import std.parallelism : parallel, taskPool, totalCPUs;
import core.thread;
import core.atomic;
import core.sync.mutex;
import core.memory : GC;

import tests.harness;
import tests.fixtures;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// =============================================================================
// SOAK TEST INFRASTRUCTURE
// =============================================================================

/// Memory usage tracker for detecting leaks
struct MemoryTracker
{
    private size_t[] samples;
    private size_t baselineUsage;
    private MonoTime startTime;
    
    void initialize()
    {
        GC.collect();
        GC.minimize();
        Thread.sleep(100.msecs);  // Let GC settle
        
        auto stats = GC.stats();
        baselineUsage = stats.usedSize;
        startTime = MonoTime.currTime;
        samples = [];
    }
    
    void sample()
    {
        auto stats = GC.stats();
        samples ~= stats.usedSize;
    }
    
    void forceCollect()
    {
        GC.collect();
        GC.minimize();
    }
    
    /// Check if memory is growing linearly (leak indicator)
    bool hasMemoryLeak() const
    {
        if (samples.length < 10)
            return false;
        
        // Calculate linear regression
        double sumX = 0, sumY = 0, sumXY = 0, sumXX = 0;
        immutable n = samples.length;
        
        foreach (i, sample; samples)
        {
            double x = cast(double)i;
            double y = cast(double)sample;
            sumX += x;
            sumY += y;
            sumXY += x * y;
            sumXX += x * x;
        }
        
        double slope = (n * sumXY - sumX * sumY) / (n * sumXX - sumX * sumX);
        
        // If slope is significantly positive and consistent, likely a leak
        // Threshold: growing more than 10KB per sample on average (more lenient for GC variance)
        return slope > 10_240;
    }
    
    size_t peakUsage() const => samples.length > 0 ? samples.maxElement : 0;
    size_t currentUsage() const => samples.length > 0 ? samples[$ - 1] : 0;
    size_t baseline() const => baselineUsage;
    
    double growthRateMBperSecond() const
    {
        if (samples.length < 2)
            return 0;
        
        auto duration = (MonoTime.currTime - startTime).total!"seconds";
        if (duration == 0)
            return 0;
        
        auto growth = cast(long)samples[$ - 1] - cast(long)samples[0];
        return (cast(double)growth / (1024 * 1024)) / duration;
    }
    
    string report() const
    {
        return "Memory Report:\n" ~
               "  Baseline: " ~ (baselineUsage / (1024 * 1024)).to!string ~ " MB\n" ~
               "  Current:  " ~ (currentUsage / (1024 * 1024)).to!string ~ " MB\n" ~
               "  Peak:     " ~ (peakUsage / (1024 * 1024)).to!string ~ " MB\n" ~
               "  Samples:  " ~ samples.length.to!string ~ "\n" ~
               "  Growth:   " ~ growthRateMBperSecond().to!string ~ " MB/sec\n" ~
               "  Leak detected: " ~ (hasMemoryLeak() ? "YES" : "no");
    }
}

/// Performance tracker for detecting degradation
struct PerformanceTracker
{
    private Duration[] operationTimes;
    private size_t[] operationsPerWindow;
    private MonoTime lastWindowStart;
    private size_t windowOperations;
    private Duration windowDuration = 1.seconds;
    
    void initialize()
    {
        operationTimes = [];
        operationsPerWindow = [];
        lastWindowStart = MonoTime.currTime;
        windowOperations = 0;
    }
    
    void recordOperation(Duration time)
    {
        operationTimes ~= time;
        windowOperations++;
        
        auto now = MonoTime.currTime;
        if (now - lastWindowStart >= windowDuration)
        {
            operationsPerWindow ~= windowOperations;
            windowOperations = 0;
            lastWindowStart = now;
        }
    }
    
    /// Check if performance is degrading over time
    bool hasPerformanceDegradation() const
    {
        if (operationsPerWindow.length < 5)
            return false;
        
        // Compare first half to second half throughput
        auto midpoint = operationsPerWindow.length / 2;
        
        double firstHalfAvg = 0;
        foreach (ops; operationsPerWindow[0 .. midpoint])
            firstHalfAvg += ops;
        firstHalfAvg /= midpoint;
        
        double secondHalfAvg = 0;
        foreach (ops; operationsPerWindow[midpoint .. $])
            secondHalfAvg += ops;
        secondHalfAvg /= (operationsPerWindow.length - midpoint);
        
        // If throughput dropped by more than 30%, flag as degradation
        return secondHalfAvg < firstHalfAvg * 0.7;
    }
    
    Duration averageLatency() const
    {
        if (operationTimes.length == 0)
            return Duration.zero;
        
        long total = 0;
        foreach (t; operationTimes)
            total += t.total!"usecs";
        return (total / operationTimes.length).usecs;
    }
    
    Duration p99Latency() const
    {
        if (operationTimes.length == 0)
            return Duration.zero;
        
        auto sorted = operationTimes.dup.sort;
        auto idx = (operationTimes.length * 99) / 100;
        return sorted[idx];
    }
    
    size_t totalOperations() const => operationTimes.length;
    
    string report() const
    {
        return "Performance Report:\n" ~
               "  Total operations: " ~ totalOperations().to!string ~ "\n" ~
               "  Avg latency: " ~ averageLatency().total!"usecs".to!string ~ " µs\n" ~
               "  P99 latency: " ~ p99Latency().total!"msecs".to!string ~ " ms\n" ~
               "  Throughput windows: " ~ operationsPerWindow.length.to!string ~ "\n" ~
               "  Degradation detected: " ~ (hasPerformanceDegradation() ? "YES" : "no");
    }
}

/// Simulated cache for soak testing
class SoakTestCache
{
    private ubyte[][ubyte[32]] storage;
    private Mutex mutex;
    private size_t maxSize;
    private shared size_t hits;
    private shared size_t misses;
    
    this(size_t maxSize = 10_000)
    {
        this.maxSize = maxSize;
        this.mutex = new Mutex();
    }
    
    void put(ubyte[32] key, ubyte[] value) @trusted
    {
        synchronized (mutex)
        {
            // Evict if at capacity
            while (storage.length >= maxSize)
            {
                auto keys = storage.keys;
                if (keys.length > 0)
                    storage.remove(keys[0]);
            }
            storage[key] = value.dup;
        }
    }
    
    ubyte[] get(ubyte[32] key) @trusted
    {
        synchronized (mutex)
        {
            if (key in storage)
            {
                atomicOp!"+="(hits, 1);
                return storage[key].dup;
            }
            atomicOp!"+="(misses, 1);
            return null;
        }
    }
    
    void clear() @trusted
    {
        synchronized (mutex)
        {
            storage.clear();
        }
    }
    
    size_t size() @trusted
    {
        synchronized (mutex) return storage.length;
    }
    
    double hitRate() @trusted
    {
        auto h = atomicLoad(hits);
        auto m = atomicLoad(misses);
        if (h + m == 0) return 0;
        return cast(double)h / (h + m);
    }
}

/// Simulated build graph for soak testing
class SoakTestGraph
{
    private string[][string] adjacency;
    private Mutex mutex;
    private shared size_t nodeCount;
    private shared size_t edgeCount;
    
    this() { this.mutex = new Mutex(); }
    
    void addNode(string id) @trusted
    {
        synchronized (mutex)
        {
            if (id !in adjacency)
            {
                adjacency[id] = [];
                atomicOp!"+="(nodeCount, 1);
            }
        }
    }
    
    bool addEdge(string from, string to) @trusted
    {
        synchronized (mutex)
        {
            if (from !in adjacency || to !in adjacency)
                return false;
            if (adjacency[from].canFind(to))
                return false;
            
            // Simple cycle check (for DAG property)
            if (hasPath(to, from))
                return false;
            
            adjacency[from] ~= to;
            atomicOp!"+="(edgeCount, 1);
            return true;
        }
    }
    
    void removeNode(string id) @trusted
    {
        synchronized (mutex)
        {
            if (id in adjacency)
            {
                atomicOp!"-="(nodeCount, 1);
                atomicOp!"-="(edgeCount, adjacency[id].length);
                adjacency.remove(id);
                
                // Remove edges pointing to this node
                foreach (ref edges; adjacency)
                {
                    auto oldLen = edges.length;
                    edges = edges.filter!(e => e != id).array;
                    atomicOp!"-="(edgeCount, oldLen - edges.length);
                }
            }
        }
    }
    
    size_t nodes() @trusted => atomicLoad(nodeCount);
    size_t edges() @trusted => atomicLoad(edgeCount);
    
    void clear() @trusted
    {
        synchronized (mutex)
        {
            adjacency.clear();
            atomicStore(nodeCount, cast(size_t)0);
            atomicStore(edgeCount, cast(size_t)0);
        }
    }

private:
    bool hasPath(string from, string to) const
    {
        if (from == to) return true;
        if (from !in adjacency) return false;
        
        bool[string] visited;
        string[] queue = [from];
        
        while (queue.length > 0)
        {
            auto current = queue[0];
            queue = queue[1 .. $];
            
            if (current in visited) continue;
            visited[current] = true;
            
            if (current == to) return true;
            
            if (current in adjacency)
                foreach (neighbor; adjacency[current])
                    if (neighbor !in visited)
                        queue ~= neighbor;
        }
        return false;
    }
}

// =============================================================================
// SOAK TESTS - MEMORY LEAK DETECTION
// =============================================================================

/// Soak test: Cache operations under sustained load
@("soak.cache.sustained_load")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Cache - Sustained Load (30 seconds)");
    
    auto memTracker = MemoryTracker();
    auto perfTracker = PerformanceTracker();
    memTracker.initialize();
    perfTracker.initialize();
    
    auto cache = new SoakTestCache(5000);
    auto rng = Mt19937(12345);
    
    auto startTime = MonoTime.currTime;
    immutable duration = 30.seconds;
    size_t operations = 0;
    
    while (MonoTime.currTime - startTime < duration)
    {
        auto opStart = MonoTime.currTime;
        
        // Generate key
        ubyte[32] key;
        foreach (ref b; key)
            b = cast(ubyte)uniform(0, 256, rng);
        
        // 70% writes, 30% reads
        if (uniform(0, 100, rng) < 70)
        {
            auto valueSize = uniform(100, 10_000, rng);
            ubyte[] value = new ubyte[valueSize];
            foreach (ref b; value)
                b = cast(ubyte)uniform(0, 256, rng);
            cache.put(key, value);
        }
        else
        {
            cache.get(key);
        }
        
        perfTracker.recordOperation(MonoTime.currTime - opStart);
        operations++;
        
        // Sample memory periodically
        if (operations % 1000 == 0)
        {
            memTracker.sample();
        }
        
        // Force GC periodically
        if (operations % 10_000 == 0)
        {
            memTracker.forceCollect();
        }
    }
    
    memTracker.forceCollect();
    memTracker.sample();
    
    writeln(memTracker.report());
    writeln(perfTracker.report());
    writeln("  Cache hit rate: " ~ (cache.hitRate() * 100).to!string ~ "%");
    writeln("  Cache size: " ~ cache.size().to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak should be detected");
    Assert.isFalse(perfTracker.hasPerformanceDegradation(), "No performance degradation");
    writeln("\x1b[32m  ✓ Cache sustained load soak test passed\x1b[0m");
}

/// Soak test: Graph operations under sustained load
@("soak.graph.sustained_load")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Graph - Sustained Load (30 seconds)");
    
    auto memTracker = MemoryTracker();
    auto perfTracker = PerformanceTracker();
    memTracker.initialize();
    perfTracker.initialize();
    
    auto graph = new SoakTestGraph();
    auto rng = Mt19937(54321);
    
    auto startTime = MonoTime.currTime;
    immutable duration = 30.seconds;
    size_t operations = 0;
    
    while (MonoTime.currTime - startTime < duration)
    {
        auto opStart = MonoTime.currTime;
        
        auto op = uniform(0, 100, rng);
        
        if (op < 40)
        {
            // Add node
            auto id = "node" ~ uniform(0, 10000, rng).to!string;
            graph.addNode(id);
        }
        else if (op < 70)
        {
            // Add edge
            auto from = "node" ~ uniform(0, 10000, rng).to!string;
            auto to = "node" ~ uniform(0, 10000, rng).to!string;
            graph.addEdge(from, to);
        }
        else if (op < 90)
        {
            // Remove node (occasionally)
            auto id = "node" ~ uniform(0, 10000, rng).to!string;
            graph.removeNode(id);
        }
        else
        {
            // Clear and rebuild (stress GC)
            if (graph.nodes() > 5000)
            {
                graph.clear();
            }
        }
        
        perfTracker.recordOperation(MonoTime.currTime - opStart);
        operations++;
        
        if (operations % 1000 == 0)
            memTracker.sample();
        
        if (operations % 10_000 == 0)
            memTracker.forceCollect();
    }
    
    memTracker.forceCollect();
    memTracker.sample();
    
    writeln(memTracker.report());
    writeln(perfTracker.report());
    writeln("  Final graph: " ~ graph.nodes().to!string ~ " nodes, " ~ graph.edges().to!string ~ " edges");
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak in graph operations");
    Assert.isFalse(perfTracker.hasPerformanceDegradation(), "No performance degradation");
    writeln("\x1b[32m  ✓ Graph sustained load soak test passed\x1b[0m");
}

/// Soak test: Concurrent cache and graph operations
@("soak.concurrent.mixed_workload")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Concurrent - Mixed Workload (30 seconds)");
    
    auto memTracker = MemoryTracker();
    memTracker.initialize();
    
    auto cache = new SoakTestCache(5000);
    auto graph = new SoakTestGraph();
    
    shared bool done = false;
    shared size_t totalOps = 0;
    shared size_t errors = 0;
    
    Thread[] workers;
    
    // Cache workers
    foreach (t; 0 .. 2)
    {
        workers ~= new Thread({
            auto rng = Mt19937(cast(uint)(t * 1000));
            
            while (!atomicLoad(done))
            {
                try
                {
                    ubyte[32] key;
                    foreach (ref b; key)
                        b = cast(ubyte)uniform(0, 256, rng);
                    
                    if (uniform(0, 2, rng) == 0)
                    {
                        ubyte[] value = new ubyte[uniform(100, 5000, rng)];
                        foreach (ref b; value)
                            b = cast(ubyte)uniform(0, 256, rng);
                        cache.put(key, value);
                    }
                    else
                    {
                        cache.get(key);
                    }
                    atomicOp!"+="(totalOps, 1);
                }
                catch (Exception e)
                {
                    atomicOp!"+="(errors, 1);
                }
            }
        });
    }
    
    // Graph workers
    foreach (t; 0 .. 2)
    {
        workers ~= new Thread({
            auto rng = Mt19937(cast(uint)((t + 10) * 1000));
            
            while (!atomicLoad(done))
            {
                try
                {
                    auto op = uniform(0, 3, rng);
                    
                    if (op == 0)
                    {
                        graph.addNode("node" ~ uniform(0, 5000, rng).to!string);
                    }
                    else if (op == 1)
                    {
                        graph.addEdge(
                            "node" ~ uniform(0, 5000, rng).to!string,
                            "node" ~ uniform(0, 5000, rng).to!string
                        );
                    }
                    else
                    {
                        graph.removeNode("node" ~ uniform(0, 5000, rng).to!string);
                    }
                    atomicOp!"+="(totalOps, 1);
                }
                catch (Exception e)
                {
                    atomicOp!"+="(errors, 1);
                }
            }
        });
    }
    
    foreach (worker; workers) worker.start();
    
    // Sample memory during test
    auto startTime = MonoTime.currTime;
    while (MonoTime.currTime - startTime < 30.seconds)
    {
        Thread.sleep(1.seconds);
        memTracker.sample();
        
        if ((MonoTime.currTime - startTime).total!"seconds" % 10 == 0)
            memTracker.forceCollect();
    }
    
    atomicStore(done, true);
    foreach (worker; workers) worker.join();
    
    memTracker.forceCollect();
    memTracker.sample();
    
    auto ops = atomicLoad(totalOps);
    auto errs = atomicLoad(errors);
    
    writeln(memTracker.report());
    writeln("  Total operations: " ~ ops.to!string);
    writeln("  Errors: " ~ errs.to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak in concurrent workload");
    Assert.equal(errs, 0, "No errors should occur");
    Assert.isTrue(ops > 10000, "Should complete significant work");
    writeln("\x1b[32m  ✓ Concurrent mixed workload soak test passed\x1b[0m");
}

/// Soak test: String allocation/deallocation cycles
@("soak.memory.string_cycles")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Memory - String Allocation Cycles (20 seconds)");
    
    auto memTracker = MemoryTracker();
    memTracker.initialize();
    
    auto rng = Mt19937(99999);
    auto startTime = MonoTime.currTime;
    size_t cycles = 0;
    
    while (MonoTime.currTime - startTime < 20.seconds)
    {
        // Create many strings
        string[] strings;
        foreach (i; 0 .. 1000)
        {
            auto len = uniform(10, 1000, rng);
            char[] buf = new char[len];
            foreach (ref c; buf)
                c = cast(char)uniform('a', 'z' + 1, rng);
            strings ~= buf.idup;
        }
        
        // Process strings
        foreach (s; strings)
        {
            auto upper = s.toUpper();
            auto lower = s.toLower();
            auto split = s.split("");
        }
        
        // Let them go out of scope
        strings = null;
        
        cycles++;
        
        if (cycles % 10 == 0)
        {
            memTracker.sample();
        }
        
        if (cycles % 50 == 0)
        {
            memTracker.forceCollect();
        }
    }
    
    memTracker.forceCollect();
    memTracker.sample();
    
    writeln(memTracker.report());
    writeln("  Cycles completed: " ~ cycles.to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak in string cycles");
    writeln("\x1b[32m  ✓ String allocation cycles soak test passed\x1b[0m");
}

/// Soak test: Array growth and shrinking
@("soak.memory.array_dynamics")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Memory - Array Dynamics (20 seconds)");
    
    auto memTracker = MemoryTracker();
    memTracker.initialize();
    
    auto rng = Mt19937(11111);
    auto startTime = MonoTime.currTime;
    size_t operations = 0;
    
    // Dynamic arrays that grow and shrink
    int[][] arrays;
    
    while (MonoTime.currTime - startTime < 20.seconds)
    {
        auto op = uniform(0, 4, rng);
        
        switch (op)
        {
            case 0: // Add new array
                if (arrays.length < 100)
                {
                    auto size = uniform(100, 10000, rng);
                    int[] arr = new int[size];
                    foreach (ref v; arr)
                        v = uniform(-1000, 1000, rng);
                    arrays ~= arr;
                }
                break;
            
            case 1: // Grow existing array
                if (arrays.length > 0)
                {
                    auto idx = uniform(0, arrays.length, rng);
                    auto growBy = uniform(100, 1000, rng);
                    foreach (i; 0 .. growBy)
                        arrays[idx] ~= uniform(-1000, 1000, rng);
                }
                break;
            
            case 2: // Shrink existing array
                if (arrays.length > 0)
                {
                    auto idx = uniform(0, arrays.length, rng);
                    if (arrays[idx].length > 100)
                    {
                        arrays[idx] = arrays[idx][0 .. arrays[idx].length / 2];
                    }
                }
                break;
            
            case 3: // Remove array
                if (arrays.length > 10)
                {
                    auto idx = uniform(0, arrays.length, rng);
                    arrays = arrays[0 .. idx] ~ arrays[min(idx + 1, arrays.length) .. $];
                }
                break;
            
            default: break;
        }
        
        operations++;
        
        if (operations % 1000 == 0)
            memTracker.sample();
        
        if (operations % 5000 == 0)
            memTracker.forceCollect();
    }
    
    arrays = null;
    memTracker.forceCollect();
    memTracker.sample();
    
    writeln(memTracker.report());
    writeln("  Operations: " ~ operations.to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak in array dynamics");
    writeln("\x1b[32m  ✓ Array dynamics soak test passed\x1b[0m");
}

/// Soak test: Hash table stress
@("soak.memory.hashtable_stress")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Memory - Hash Table Stress (20 seconds)");
    
    auto memTracker = MemoryTracker();
    memTracker.initialize();
    
    auto rng = Mt19937(22222);
    auto startTime = MonoTime.currTime;
    size_t operations = 0;
    
    string[string] map;
    
    while (MonoTime.currTime - startTime < 20.seconds)
    {
        auto op = uniform(0, 10, rng);
        
        if (op < 6)
        {
            // Insert
            auto keyLen = uniform(5, 50, rng);
            auto valLen = uniform(10, 200, rng);
            
            char[] key = new char[keyLen];
            foreach (ref c; key)
                c = cast(char)uniform('a', 'z' + 1, rng);
            
            char[] val = new char[valLen];
            foreach (ref c; val)
                c = cast(char)uniform('a', 'z' + 1, rng);
            
            map[key.idup] = val.idup;
        }
        else if (op < 8)
        {
            // Delete
            if (map.length > 0)
            {
                auto keys = map.keys;
                auto idx = uniform(0, keys.length, rng);
                map.remove(keys[idx]);
            }
        }
        else if (op == 8)
        {
            // Lookup
            auto keyLen = uniform(5, 50, rng);
            char[] key = new char[keyLen];
            foreach (ref c; key)
                c = cast(char)uniform('a', 'z' + 1, rng);
            auto val = key.idup in map;
        }
        else
        {
            // Clear if too large
            if (map.length > 50000)
            {
                map.clear();
            }
        }
        
        operations++;
        
        if (operations % 1000 == 0)
            memTracker.sample();
        
        if (operations % 10000 == 0)
            memTracker.forceCollect();
    }
    
    map.clear();
    memTracker.forceCollect();
    memTracker.sample();
    
    writeln(memTracker.report());
    writeln("  Operations: " ~ operations.to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak in hash table stress");
    writeln("\x1b[32m  ✓ Hash table stress soak test passed\x1b[0m");
}

// =============================================================================
// SOAK TESTS - PERFORMANCE STABILITY
// =============================================================================

/// Soak test: Throughput stability under constant load
@("soak.performance.throughput_stability")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Performance - Throughput Stability (30 seconds)");
    
    auto perfTracker = PerformanceTracker();
    perfTracker.initialize();
    
    auto cache = new SoakTestCache(1000);
    auto rng = Mt19937(33333);
    
    auto startTime = MonoTime.currTime;
    size_t operations = 0;
    
    while (MonoTime.currTime - startTime < 30.seconds)
    {
        auto opStart = MonoTime.currTime;
        
        // Consistent workload
        ubyte[32] key;
        foreach (ref b; key)
            b = cast(ubyte)uniform(0, 256, rng);
        
        ubyte[] value = new ubyte[1000];
        foreach (ref b; value)
            b = cast(ubyte)uniform(0, 256, rng);
        
        cache.put(key, value);
        cache.get(key);
        
        perfTracker.recordOperation(MonoTime.currTime - opStart);
        operations++;
    }
    
    writeln(perfTracker.report());
    writeln("  Total operations: " ~ operations.to!string);
    
    Assert.isFalse(perfTracker.hasPerformanceDegradation(), "Throughput should remain stable");
    Assert.isTrue(operations > 100000, "Should complete many operations");
    writeln("\x1b[32m  ✓ Throughput stability soak test passed\x1b[0m");
}

/// Soak test: Latency stability under varying load
@("soak.performance.latency_stability")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Performance - Latency Stability (30 seconds)");
    
    Duration[] latencies;
    auto cache = new SoakTestCache(5000);
    auto rng = Mt19937(44444);
    
    auto startTime = MonoTime.currTime;
    
    while (MonoTime.currTime - startTime < 30.seconds)
    {
        // Varying workload intensity
        auto intensity = 1 + ((MonoTime.currTime - startTime).total!"seconds" % 5);
        
        foreach (i; 0 .. intensity * 100)
        {
            auto opStart = MonoTime.currTime;
            
            ubyte[32] key;
            foreach (ref b; key)
                b = cast(ubyte)uniform(0, 256, rng);
            
            if (uniform(0, 2, rng) == 0)
            {
                ubyte[] value = new ubyte[uniform(500, 5000, rng)];
                cache.put(key, value);
            }
            else
            {
                cache.get(key);
            }
            
            latencies ~= MonoTime.currTime - opStart;
        }
        
        Thread.sleep(10.msecs);
    }
    
    // Analyze latencies
    auto sorted = latencies.dup.sort;
    auto p50 = sorted[latencies.length / 2];
    auto p99 = sorted[(latencies.length * 99) / 100];
    auto pMax = sorted[$ - 1];
    
    writeln("  Total samples: " ~ latencies.length.to!string);
    writeln("  P50 latency: " ~ p50.total!"usecs".to!string ~ " µs");
    writeln("  P99 latency: " ~ p99.total!"usecs".to!string ~ " µs");
    writeln("  Max latency: " ~ pMax.total!"msecs".to!string ~ " ms");
    
    // P99 should not be more than 100x P50 (reasonable jitter)
    Assert.isTrue(p99 < p50 * 100, "Latency should be reasonably stable");
    writeln("\x1b[32m  ✓ Latency stability soak test passed\x1b[0m");
}

// =============================================================================
// SOAK TESTS - ERROR RECOVERY
// =============================================================================

/// Soak test: Recovery from repeated errors
@("soak.recovery.repeated_errors")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Recovery - Repeated Errors (20 seconds)");
    
    auto memTracker = MemoryTracker();
    memTracker.initialize();
    
    auto cache = new SoakTestCache(1000);
    auto rng = Mt19937(55555);
    
    auto startTime = MonoTime.currTime;
    size_t recoveries = 0;
    size_t successes = 0;
    
    while (MonoTime.currTime - startTime < 20.seconds)
    {
        try
        {
            // Simulate operation that might fail
            if (uniform(0, 10, rng) == 0)
            {
                throw new Exception("Simulated error");
            }
            
            ubyte[32] key;
            foreach (ref b; key)
                b = cast(ubyte)uniform(0, 256, rng);
            
            ubyte[] value = new ubyte[1000];
            cache.put(key, value);
            successes++;
        }
        catch (Exception e)
        {
            // Recovery logic
            recoveries++;
            GC.collect();  // Clean up any partial allocations
        }
        
        if ((successes + recoveries) % 1000 == 0)
            memTracker.sample();
    }
    
    memTracker.forceCollect();
    memTracker.sample();
    
    writeln(memTracker.report());
    writeln("  Successes: " ~ successes.to!string);
    writeln("  Recoveries: " ~ recoveries.to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak after repeated recovery");
    Assert.isTrue(recoveries > 0, "Should have recovered from errors");
    Assert.isTrue(successes > recoveries * 5, "Most operations should succeed");
    writeln("\x1b[32m  ✓ Repeated error recovery soak test passed\x1b[0m");
}

/// Soak test: Resource cleanup under pressure
@("soak.recovery.resource_cleanup")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Recovery - Resource Cleanup Under Pressure (20 seconds)");
    
    auto memTracker = MemoryTracker();
    memTracker.initialize();
    
    auto rng = Mt19937(66666);
    auto startTime = MonoTime.currTime;
    size_t cleanups = 0;
    
    // Resource pool
    ubyte[][] resources;
    
    while (MonoTime.currTime - startTime < 20.seconds)
    {
        // Allocate resources aggressively
        foreach (i; 0 .. 100)
        {
            auto size = uniform(1000, 100000, rng);
            resources ~= new ubyte[size];
        }
        
        // Pressure threshold - cleanup required
        if (resources.length > 500)
        {
            // Simulate resource cleanup
            resources = resources[resources.length / 2 .. $];
            cleanups++;
            GC.collect();
        }
        
        if (cleanups % 10 == 0)
            memTracker.sample();
    }
    
    resources = null;
    memTracker.forceCollect();
    memTracker.sample();
    
    writeln(memTracker.report());
    writeln("  Cleanups performed: " ~ cleanups.to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak with resource cleanup");
    Assert.isTrue(cleanups > 0, "Should have performed cleanups");
    writeln("\x1b[32m  ✓ Resource cleanup under pressure soak test passed\x1b[0m");
}

// =============================================================================
// SOAK TESTS - CONCURRENT STRESS
// =============================================================================

/// Soak test: High contention concurrent access
@("soak.concurrent.high_contention")
@system unittest
{
    writeln("\x1b[36m[SOAK]\x1b[0m Concurrent - High Contention (30 seconds)");
    
    auto memTracker = MemoryTracker();
    memTracker.initialize();
    
    // Single shared resource with high contention
    shared int sharedCounter = 0;
    auto mutex = new Mutex();
    
    shared bool done = false;
    shared size_t totalIncrements = 0;
    
    Thread[] workers;
    
    foreach (t; 0 .. 8)
    {
        workers ~= new Thread({
            while (!atomicLoad(done))
            {
                synchronized (mutex)
                {
                    auto val = atomicLoad(sharedCounter);
                    // Simulate some work while holding lock
                    foreach (i; 0 .. 10)
                        val += 1;
                    atomicStore(sharedCounter, val);
                }
                atomicOp!"+="(totalIncrements, 1);
            }
        });
    }
    
    foreach (worker; workers) worker.start();
    
    auto startTime = MonoTime.currTime;
    while (MonoTime.currTime - startTime < 30.seconds)
    {
        Thread.sleep(1.seconds);
        memTracker.sample();
        
        if ((MonoTime.currTime - startTime).total!"seconds" % 10 == 0)
            memTracker.forceCollect();
    }
    
    atomicStore(done, true);
    foreach (worker; workers) worker.join();
    
    memTracker.forceCollect();
    memTracker.sample();
    
    auto finalCounter = atomicLoad(sharedCounter);
    auto ops = atomicLoad(totalIncrements);
    
    writeln(memTracker.report());
    writeln("  Final counter: " ~ finalCounter.to!string);
    writeln("  Total increments: " ~ ops.to!string);
    writeln("  Expected: " ~ (ops * 10).to!string);
    
    Assert.isFalse(memTracker.hasMemoryLeak(), "No memory leak under high contention");
    Assert.equal(finalCounter, cast(int)(ops * 10), "Counter should match increments");
    writeln("\x1b[32m  ✓ High contention soak test passed\x1b[0m");
}


