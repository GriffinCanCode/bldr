module infrastructure.utils.memory.numa;

import core.memory : GC;
import core.atomic;
import std.algorithm : max, min;

/// NUMA Topology Detection and NUMA-Local Allocation
/// 
/// Provides NUMA awareness for multi-socket systems:
///   - Runtime NUMA topology detection
///   - NUMA-local memory allocation
///   - Thread-to-node affinity helpers
///   - NUMA-aware arena allocators
/// 
/// Performance Impact:
///   - Local memory access: ~100 cycles
///   - Remote memory access: ~300+ cycles (3x slower)
///   - Cross-socket bandwidth: 50% of local
/// 
/// Usage:
///   auto numa = NUMATopology.global;
///   auto nodeId = numa.currentNode();
///   auto arena = NUMAArena.forCurrentNode(size);

// ═══════════════════════════════════════════════════════════════════════
// NUMA Topology Detection
// ═══════════════════════════════════════════════════════════════════════

/// NUMA node information
struct NUMANode
{
    uint id;                /// Node ID (0-based)
    ulong totalMemory;      /// Total memory in bytes
    ulong freeMemory;       /// Free memory in bytes
    uint[] cpus;            /// CPUs belonging to this node
    uint[] distances;       /// Distance to other nodes (self = 10)
}

/// NUMA topology information
struct NUMATopology
{
    private __gshared NUMANode[] _nodes;
    private __gshared uint _nodeCount = 0;
    private __gshared bool _initialized = false;
    private __gshared bool _numaAvailable = false;
    
    /// Get global topology instance (lazy initialization)
    static ref const(NUMATopology) global() nothrow
    {
        if (!_initialized) initialize();
        return _topology;
    }
    
    private static __gshared NUMATopology _topology;
    
    /// Check if NUMA is available on this system
    static bool available() nothrow => global()._numaAvailable;
    
    /// Number of NUMA nodes
    static uint nodeCount() nothrow => global()._nodeCount;
    
    /// Get all nodes
    static const(NUMANode)[] nodes() nothrow => global()._nodes;
    
    /// Get NUMA node for current thread
    static uint currentNode() nothrow @nogc
    {
        version (linux)
        {
            int node = numa_node_of_cpu(sched_getcpu());
            return node >= 0 ? cast(uint)node : 0;
        }
        else version (OSX)
        {
            // macOS doesn't expose NUMA topology directly
            // Apple Silicon is UMA, Intel Macs typically single-socket
            return 0;
        }
        else
            return 0;
    }
    
    /// Get optimal node for a given CPU
    static uint nodeForCPU(uint cpu) nothrow @nogc
    {
        if (!_numaAvailable) return 0;
        foreach (ref node; _nodes)
        {
            foreach (c; node.cpus)
                if (c == cpu) return node.id;
        }
        return 0;
    }
    
    /// Get distance between two nodes (10 = same node)
    static uint distance(uint from, uint to) nothrow @nogc
    {
        if (!_numaAvailable || from >= _nodeCount) return 10;
        if (to >= _nodes[from].distances.length) return 20;
        return _nodes[from].distances[to];
    }
    
    /// Find nearest node with sufficient free memory
    static uint nearestNodeWithMemory(ulong required, uint preferNode = uint.max) nothrow
    {
        if (!_numaAvailable) return 0;
        
        immutable startNode = preferNode < _nodeCount ? preferNode : currentNode();
        
        // Check preferred node first
        if (startNode < _nodeCount && _nodes[startNode].freeMemory >= required)
            return startNode;
        
        // Find nearest alternative
        uint bestNode = startNode;
        uint bestDist = uint.max;
        
        foreach (ref node; _nodes)
        {
            if (node.freeMemory >= required)
            {
                immutable dist = distance(startNode, node.id);
                if (dist < bestDist)
                {
                    bestDist = dist;
                    bestNode = node.id;
                }
            }
        }
        return bestNode;
    }
    
private:
    static void initialize() nothrow
    {
        if (_initialized) return;
        
        version (linux)
            initializeLinux();
        else version (OSX)
            initializeMacOS();
        else
            initializeFallback();
        
        _initialized = true;
    }
    
    version (linux)
    static void initializeLinux() nothrow
    {
        // Check if NUMA is available
        if (numa_available() < 0)
        {
            initializeFallback();
            return;
        }
        
        _numaAvailable = true;
        _nodeCount = cast(uint)numa_max_node() + 1;
        
        try
        {
            _nodes = new NUMANode[_nodeCount];
            
            foreach (uint nodeId; 0 .. _nodeCount)
            {
                _nodes[nodeId].id = nodeId;
                
                // Get memory info
                long free;
                _nodes[nodeId].totalMemory = numa_node_size64(nodeId, &free);
                _nodes[nodeId].freeMemory = free > 0 ? cast(ulong)free : 0;
                
                // Get CPUs for this node
                auto mask = numa_allocate_cpumask();
                if (mask !is null)
                {
                    scope(exit) numa_free_cpumask(mask);
                    if (numa_node_to_cpus(nodeId, mask) == 0)
                    {
                        uint[] cpus;
                        foreach (cpu; 0 .. numa_num_configured_cpus())
                        {
                            if (numa_bitmask_isbitset(mask, cpu))
                                cpus ~= cpu;
                        }
                        _nodes[nodeId].cpus = cpus;
                    }
                }
                
                // Get distances
                uint[] dists;
                foreach (other; 0 .. _nodeCount)
                    dists ~= cast(uint)numa_distance(nodeId, other);
                _nodes[nodeId].distances = dists;
            }
        }
        catch (Exception)
        {
            initializeFallback();
        }
    }
    
    version (OSX)
    static void initializeMacOS() nothrow
    {
        // macOS: Assume single NUMA node (UMA)
        _numaAvailable = false;
        initializeFallback();
    }
    
    static void initializeFallback() nothrow
    {
        _numaAvailable = false;
        _nodeCount = 1;
        
        try
        {
            _nodes = new NUMANode[1];
            _nodes[0] = NUMANode(0, 0, 0, [], [10]);
        }
        catch (Exception) {}
    }
}

// ═══════════════════════════════════════════════════════════════════════
// NUMA-Aware Allocation
// ═══════════════════════════════════════════════════════════════════════

/// Allocate memory on a specific NUMA node
ubyte[] numaAlloc(size_t size, uint node = uint.max) @system
{
    if (size == 0) return null;
    
    version (linux)
    {
        if (NUMATopology.available())
        {
            immutable targetNode = node < NUMATopology.nodeCount() ? node : NUMATopology.currentNode();
            void* ptr = numa_alloc_onnode(size, targetNode);
            if (ptr !is null)
                return (cast(ubyte*)ptr)[0 .. size];
        }
    }
    
    // Fallback to regular allocation
    auto buf = new ubyte[size];
    GC.setAttr(buf.ptr, GC.BlkAttr.NO_SCAN);
    return buf;
}

/// Free NUMA-allocated memory
void numaFree(ubyte[] mem) @system nothrow @nogc
{
    if (mem.ptr is null) return;
    
    version (linux)
    {
        if (NUMATopology.available())
        {
            numa_free(mem.ptr, mem.length);
            return;
        }
    }
    // GC-allocated memory is freed automatically
}

/// NUMA-aware arena allocator
/// Allocates memory local to a specific NUMA node
struct NUMAArena
{
    private ubyte[] buffer;
    private size_t offset;
    private uint nodeId;
    private bool ownsMemory;
    
    @disable this(this);
    
    /// Create arena on specific NUMA node
    static NUMAArena* create(size_t capacity, uint node = uint.max) @system
    {
        auto arena = new NUMAArena();
        arena.nodeId = node < NUMATopology.nodeCount() ? node : NUMATopology.currentNode();
        arena.buffer = numaAlloc(capacity, arena.nodeId);
        arena.offset = 0;
        arena.ownsMemory = true;
        return arena;
    }
    
    /// Create arena for current thread's NUMA node
    static NUMAArena* forCurrentNode(size_t capacity) @system =>
        create(capacity, NUMATopology.currentNode());
    
    ~this() @system
    {
        if (ownsMemory && buffer.ptr !is null)
            numaFree(buffer);
    }
    
    /// Allocate bytes from arena
    ubyte[] allocate(size_t size, size_t alignment = size_t.sizeof) @system nothrow @nogc
    {
        immutable alignedOffset = alignUp(offset, alignment);
        if (alignedOffset + size > buffer.length)
            return null;  // Out of memory
        
        auto result = buffer[alignedOffset .. alignedOffset + size];
        offset = alignedOffset + size;
        return result;
    }
    
    /// Allocate and construct typed value
    T* make(T, Args...)(auto ref Args args) @system
    {
        auto mem = allocate(T.sizeof, T.alignof);
        if (mem.ptr is null) return null;
        
        import core.lifetime : emplace;
        return emplace(cast(T*)mem.ptr, args);
    }
    
    /// Reset arena (keep memory, reset offset)
    void reset() nothrow @nogc { offset = 0; }
    
    /// Get NUMA node this arena belongs to
    @property uint node() const nothrow @nogc => nodeId;
    
    /// Get remaining capacity
    @property size_t remaining() const nothrow @nogc =>
        buffer.length > offset ? buffer.length - offset : 0;
    
    /// Get total capacity
    @property size_t capacity() const nothrow @nogc => buffer.length;
    
private:
    static size_t alignUp(size_t value, size_t alignment) pure nothrow @nogc =>
        (value + alignment - 1) & ~(alignment - 1);
}

// ═══════════════════════════════════════════════════════════════════════
// Thread-Local NUMA Arena
// ═══════════════════════════════════════════════════════════════════════

/// Thread-local NUMA-aware arena
/// Automatically allocates on current thread's NUMA node
struct ThreadLocalNUMAArena
{
    private static NUMAArena* tls;
    private static shared size_t _totalAllocations;
    
    enum DEFAULT_SIZE = 256 * 1024;  // 256KB default
    
    /// Get or create thread-local arena on current NUMA node
    static NUMAArena* get(size_t capacity = DEFAULT_SIZE) @system nothrow
    {
        if (tls is null)
        {
            try tls = NUMAArena.forCurrentNode(capacity);
            catch (Exception) return null;
        }
        return tls;
    }
    
    /// Allocate from thread-local NUMA arena
    static ubyte[] allocate(size_t size, size_t alignment = size_t.sizeof) @system
    {
        auto arena = get();
        if (arena is null)
            throw new Exception("Failed to initialize thread-local NUMA arena");
        
        atomicOp!"+="(_totalAllocations, 1);
        auto result = arena.allocate(size, alignment);
        if (result.ptr is null)
            throw new Exception("NUMA arena out of memory");
        return result;
    }
    
    /// Make typed value in thread-local NUMA arena
    static T* make(T, Args...)(auto ref Args args) @system
    {
        auto arena = get();
        if (arena is null) return null;
        atomicOp!"+="(_totalAllocations, 1);
        return arena.make!T(args);
    }
    
    /// Reset thread-local arena
    static void reset() @system nothrow
    {
        if (tls !is null) tls.reset();
    }
    
    /// Get current NUMA node
    static uint currentNode() nothrow @nogc
    {
        if (tls !is null) return tls.node;
        return NUMATopology.currentNode();
    }
}

// ═══════════════════════════════════════════════════════════════════════
// NUMA-Aware Work Distribution
// ═══════════════════════════════════════════════════════════════════════

/// Distribute work items across NUMA nodes for optimal locality
/// Returns array of (nodeId, startIdx, endIdx) tuples
struct NUMAWorkDistribution
{
    uint node;
    size_t startIdx;
    size_t endIdx;
}

/// Distribute work evenly across NUMA nodes
NUMAWorkDistribution[] distributeWork(size_t totalItems, uint preferNode = uint.max) @system
{
    if (totalItems == 0) return [];
    
    immutable nodeCount = NUMATopology.nodeCount();
    if (nodeCount <= 1)
        return [NUMAWorkDistribution(0, 0, totalItems)];
    
    auto result = new NUMAWorkDistribution[nodeCount];
    immutable itemsPerNode = totalItems / nodeCount;
    immutable remainder = totalItems % nodeCount;
    
    size_t offset = 0;
    foreach (uint i; 0 .. nodeCount)
    {
        immutable extra = i < remainder ? 1 : 0;
        immutable count = itemsPerNode + extra;
        result[i] = NUMAWorkDistribution(i, offset, offset + count);
        offset += count;
    }
    
    return result;
}

/// Reorder work distribution to start from preferred node
NUMAWorkDistribution[] distributeWorkFromNode(size_t totalItems, uint startNode) @system
{
    auto dist = distributeWork(totalItems);
    if (dist.length <= 1 || startNode == 0) return dist;
    
    // Rotate to put startNode first
    immutable rotate = startNode % dist.length;
    return dist[rotate .. $] ~ dist[0 .. rotate];
}

// ═══════════════════════════════════════════════════════════════════════
// Linux NUMA API Bindings
// ═══════════════════════════════════════════════════════════════════════

version (linux)
{
    extern(C) nothrow @nogc:
    
    // libnuma functions
    int numa_available();
    int numa_max_node();
    long numa_node_size64(int node, long* freep);
    void* numa_alloc_onnode(size_t size, int node);
    void numa_free(void* start, size_t size);
    int numa_run_on_node(int node);
    int numa_preferred();
    int numa_distance(int node1, int node2);
    int numa_num_configured_cpus();
    
    // CPU mask operations
    struct numa_bitmask;
    numa_bitmask* numa_allocate_cpumask();
    void numa_free_cpumask(numa_bitmask* bmp);
    int numa_node_to_cpus(int node, numa_bitmask* mask);
    int numa_bitmask_isbitset(const numa_bitmask* bmp, uint n);
    
    // sched functions
    int sched_getcpu();
    int numa_node_of_cpu(int cpu);
}

// ═══════════════════════════════════════════════════════════════════════
// Unit Tests
// ═══════════════════════════════════════════════════════════════════════

unittest
{
    import std.stdio : writeln, writefln;
    
    writeln("\x1b[36m[TEST]\x1b[0m memory.numa - NUMA topology detection");
    
    auto nodeCount = NUMATopology.nodeCount();
    auto available = NUMATopology.available();
    auto currentNode = NUMATopology.currentNode();
    
    assert(nodeCount >= 1, "Must have at least 1 node");
    assert(currentNode < nodeCount, "Current node must be valid");
    
    writefln("  NUMA available: %s", available);
    writefln("  Node count: %d", nodeCount);
    writefln("  Current node: %d", currentNode);
    
    if (available)
    {
        foreach (ref node; NUMATopology.nodes())
        {
            writefln("  Node %d: %d CPUs, %d MB total, %d MB free",
                     node.id, node.cpus.length,
                     node.totalMemory / (1024*1024),
                     node.freeMemory / (1024*1024));
        }
    }
    
    writeln("\x1b[32m  ✓ NUMA topology detection\x1b[0m");
}

unittest
{
    import std.stdio : writeln, writefln;
    
    writeln("\x1b[36m[TEST]\x1b[0m memory.numa - NUMA arena allocation");
    
    // Create arena on current node
    auto arena = NUMAArena.forCurrentNode(64 * 1024);
    assert(arena !is null, "Arena creation failed");
    
    // Allocate some data
    auto data1 = arena.allocate(1024);
    assert(data1.length == 1024, "Allocation failed");
    
    auto data2 = arena.allocate(2048, 64);  // Cache-line aligned
    assert(data2.length == 2048, "Aligned allocation failed");
    assert(cast(size_t)data2.ptr % 64 == 0, "Alignment incorrect");
    
    writefln("  Arena node: %d", arena.node);
    writefln("  Remaining: %d KB", arena.remaining / 1024);
    
    // Reset and reuse
    arena.reset();
    assert(arena.remaining == arena.capacity, "Reset failed");
    
    writeln("\x1b[32m  ✓ NUMA arena allocation\x1b[0m");
}

unittest
{
    import std.stdio : writeln, writefln;
    
    writeln("\x1b[36m[TEST]\x1b[0m memory.numa - Work distribution");
    
    auto dist = distributeWork(100);
    
    assert(dist.length >= 1, "Must have distribution");
    
    // Verify coverage
    size_t total = 0;
    foreach (ref d; dist)
    {
        assert(d.endIdx > d.startIdx, "Invalid range");
        total += d.endIdx - d.startIdx;
    }
    assert(total == 100, "Work not fully distributed");
    
    writefln("  Distributed 100 items across %d nodes", dist.length);
    foreach (ref d; dist)
        writefln("    Node %d: items %d-%d", d.node, d.startIdx, d.endIdx);
    
    writeln("\x1b[32m  ✓ Work distribution\x1b[0m");
}

unittest
{
    import std.stdio : writeln;
    
    writeln("\x1b[36m[TEST]\x1b[0m memory.numa - Thread-local NUMA arena");
    
    // Get thread-local arena
    auto arena = ThreadLocalNUMAArena.get();
    assert(arena !is null, "TLS arena creation failed");
    
    // Allocate data
    auto data = ThreadLocalNUMAArena.allocate(512);
    assert(data.length == 512, "TLS allocation failed");
    
    writefln("  TLS arena node: %d", ThreadLocalNUMAArena.currentNode());
    
    // Reset for next use
    ThreadLocalNUMAArena.reset();
    
    writeln("\x1b[32m  ✓ Thread-local NUMA arena\x1b[0m");
}

