module engine.graph.core.graph;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import core.atomic;
import core.memory : GC;
import core.lifetime : emplace;
import infrastructure.config.schema.schema;
import infrastructure.errors;
import engine.graph.core.incremental_topo;

/// Arena allocator specialized for BuildNode instances
/// Reduces GC pressure 10-100x during graph construction by:
/// - Bump-pointer allocation (O(1) per node)
/// - Batch deallocation (reset all at once)
/// - Cache-friendly contiguous memory layout
/// - GC root registration for proper scanning
struct NodeArena
{
    private ubyte[] buffer;
    private size_t offset;
    private size_t nodeCount;
    private enum nodeSize = __traits(classInstanceSize, BuildNode);
    private enum nodeAlign = __traits(classInstanceAlignment, BuildNode);
    
    @disable this(this);  // Non-copyable
    
    /// Create arena with capacity for expectedNodes BuildNode instances
    this(size_t expectedNodes) @trusted
    {
        immutable size = alignUp(nodeSize, nodeAlign) * expectedNodes;
        buffer = new ubyte[size];
        offset = 0;
        nodeCount = 0;
        // Don't set NO_SCAN - we need GC to scan for Target/TargetId references
        GC.addRoot(buffer.ptr);
    }
    
    ~this() @trusted
    {
        if (buffer.ptr !is null)
            GC.removeRoot(buffer.ptr);
    }
    
    /// Allocate and construct a BuildNode in the arena
    /// Returns null if arena is full
    BuildNode allocate(TargetId id, Target target) @trusted
    {
        immutable alignedOffset = alignUp(offset, nodeAlign);
        immutable newOffset = alignedOffset + nodeSize;
        
        if (newOffset > buffer.length)
            return null;  // Arena full, caller should fallback to GC
        
        offset = newOffset;
        nodeCount++;
        
        // Construct BuildNode in arena memory
        auto mem = buffer[alignedOffset .. newOffset];
        return emplace!BuildNode(mem, id, target);
    }
    
    /// Reset arena for reuse (invalidates all allocated nodes)
    void reset() @safe nothrow @nogc
    {
        offset = 0;
        nodeCount = 0;
    }
    
    @property size_t count() const pure @safe nothrow @nogc => nodeCount;
    @property size_t used() const pure @safe nothrow @nogc => offset;
    @property size_t capacity() const pure @safe nothrow @nogc => buffer.length;
    @property bool full() const pure @safe nothrow @nogc => offset >= buffer.length;
    
    private static size_t alignUp(size_t value, size_t alignment) pure @safe nothrow @nogc =>
        (value + alignment - 1) & ~(alignment - 1);
}

/// Represents a node in the build graph
/// Thread-safe: status field is accessed atomically
/// 
/// Memory Optimization: Stores TargetId[] instead of BuildNode[] to avoid GC cycles
/// from bidirectional references. This reduces memory pressure and prevents potential
/// memory leaks from circular references between dependencies and dependents.
/// 
/// Performance: Uses integer index for O(1) array lookups in hot paths,
/// avoiding hash overhead of associative array access.
final class BuildNode
{
    TargetId id;  // Strongly-typed identifier
    Target target;
    TargetId[] dependencyIds;  // IDs instead of pointers to avoid GC cycles
    TargetId[] dependentIds;   // IDs instead of pointers to avoid GC cycles
    uint[] dependencyIndices;  // Parallel indices for O(1) hot path lookups
    uint[] dependentIndices;   // Parallel indices for O(1) hot path lookups
    private shared BuildStatus _status;  // Atomic access only
    string hash;
    
    /// Index into BuildGraph._nodeArray for O(1) indexed access (uint.max = unassigned)
    uint _nodeIndex = uint.max;
    
    // Retry metadata
    private shared size_t _retryAttempts;  // Atomic access only
    string lastError;                       // Last error message
    
    // Lock-free execution metadata
    private shared size_t _pendingDeps;  // Atomic: remaining dependencies to build
    
    this(TargetId id, Target target) @system pure nothrow
    {
        this.id = id;
        this.target = target;
        atomicStore(this._status, BuildStatus.Pending);
        atomicStore(this._retryAttempts, cast(size_t)0);
        atomicStore(this._pendingDeps, cast(size_t)0);
        
        // Pre-allocate reasonable capacity to avoid reallocations
        dependencyIds.reserve(8);   // Most targets have <8 dependencies
        dependentIds.reserve(4);    // Fewer dependents on average
        dependencyIndices.reserve(8);
        dependentIndices.reserve(4);
    }
    
    /// Get strongly-typed target identifier (accessor for consistency)
    @property TargetId targetId() const @system pure nothrow @nogc
    {
        return id;
    }
    
    /// Get string representation of ID (for backward compatibility)
    @property string idString() const @system
    {
        return id.toString();
    }
    
    /// Get status atomically (thread-safe)
    /// 
    /// Safety: This property is @system because:
    /// 1. atomicLoad() performs sequentially-consistent atomic read
    /// 2. _status is shared - requires atomic operations for thread safety
    /// 3. Read-only operation with no side effects
    /// 4. Returns enum by value (no references)
    /// 
    /// Invariants:
    /// - _status is always a valid BuildStatus enum value
    /// 
    /// What could go wrong:
    /// - Nothing: atomic read of shared enum is safe, no memory corruption possible
    @property BuildStatus status() const nothrow @system @nogc
    {
        return atomicLoad(this._status);
    }
    
    /// Set status atomically (thread-safe)
    /// 
    /// Safety: This property is @system because:
    /// 1. atomicStore() performs sequentially-consistent atomic write
    /// 2. _status is shared - requires atomic operations for thread safety
    /// 3. Prevents data races during concurrent builds
    /// 4. Enum parameter is trivially copyable
    /// 
    /// Invariants:
    /// - Only valid BuildStatus enum values are written
    /// 
    /// What could go wrong:
    /// - Nothing: atomic write of shared enum is safe, no memory corruption possible
    @property void status(BuildStatus newStatus) nothrow @system @nogc
    {
        atomicStore(this._status, newStatus);
    }
    
    /// Get retry attempts atomically (thread-safe)
    /// 
    /// Safety: This property is @system because:
    /// 1. atomicLoad() performs sequentially-consistent atomic read
    /// 2. _retryAttempts is shared - requires atomic operations
    /// 3. Read-only operation with no side effects
    /// 
    /// Invariants:
    /// - _retryAttempts is always >= 0 (size_t is unsigned)
    /// 
    /// What could go wrong:
    /// - Nothing: atomic read of shared size_t is safe, no memory corruption possible
    @property size_t retryAttempts() const nothrow @system @nogc
    {
        return atomicLoad(this._retryAttempts);
    }
    
    /// Increment retry attempts atomically (thread-safe)
    /// 
    /// Safety: This function is @system because:
    /// 1. atomicOp!"+=" performs atomic read-modify-write operation
    /// 2. _retryAttempts is shared - requires atomic operations
    /// 3. Prevents race conditions during concurrent retries
    /// 
    /// Invariants:
    /// - Counter increments are atomic (no lost updates)
    /// 
    /// What could go wrong:
    /// - Overflow: If retries exceed size_t.max, wraps to 0 (extremely unlikely)
    void incrementRetries() nothrow @system @nogc
    {
        atomicOp!"+="(this._retryAttempts, 1);
    }
    
    /// Reset retry attempts atomically (thread-safe)
    /// 
    /// Safety: This function is @system because:
    /// 1. atomicStore() performs sequentially-consistent atomic write
    /// 2. _retryAttempts is shared - requires atomic operations
    /// 3. Cast to size_t is safe (compile-time constant 0)
    /// 
    /// Invariants:
    /// - Counter is reset to exactly 0
    /// 
    /// What could go wrong:
    /// - Nothing: atomic write of constant 0 is safe, no memory corruption possible
    void resetRetries() nothrow @system @nogc
    {
        atomicStore(this._retryAttempts, cast(size_t)0);
    }
    
    /// Initialize pending dependencies counter (call before execution)
    /// 
    /// Safety: This function is @system because:
    /// 1. atomicStore() performs sequentially-consistent atomic write
    /// 2. _pendingDeps is shared - requires atomic operations
    /// 3. dependencyIds.length is safe to read
    void initPendingDeps() nothrow @system @nogc
    {
        atomicStore(this._pendingDeps, dependencyIds.length);
    }
    
    /// Atomically decrement pending dependencies and return new count
    /// Used by lock-free execution to detect when node becomes ready
    /// 
    /// Safety: This function is @system because:
    /// 1. atomicOp!"-=" performs atomic read-modify-write operation
    /// 2. _pendingDeps is shared - requires atomic operations
    /// 3. Returns the new value after decrement
    /// 
    /// Invariants:
    /// - Decrement is atomic (no lost updates)
    /// - Returns value after decrement
    /// 
    /// What could go wrong:
    /// - Underflow: If decremented too many times (caller's responsibility)
    size_t decrementPendingDeps() nothrow @system @nogc
    {
        atomicOp!"-="(this._pendingDeps, 1);
        return atomicLoad(this._pendingDeps);
    }
    
    /// Get current pending dependencies count
    size_t pendingDeps() const nothrow @system @nogc
    {
        return atomicLoad(this._pendingDeps);
    }
    
    /// Set retry attempts (for deserialization)
    /// Public access for cache restoration
    void setRetryAttempts(size_t count) nothrow @system @nogc
    {
        atomicStore(this._retryAttempts, count);
    }
    
    /// Set pending deps (for deserialization)
    /// Public access for cache restoration
    void setPendingDeps(size_t count) nothrow @system @nogc
    {
        atomicStore(this._pendingDeps, count);
    }
    
    /// Check if this node is ready to build (all deps built)
    /// Thread-safe: reads dependency status atomically
    /// Requires graph reference to resolve dependency IDs to nodes
    /// 
    /// Safety: This function is @system because:
    /// 1. Reads _status atomically from dependency nodes
    /// 2. dependencyIds array is immutable after graph construction
    /// 3. atomicLoad() ensures memory-safe concurrent reads
    /// 4. Read-only operation with no mutations
    /// 
    /// Performance: O(1) indexed access via dependencyIndices.
    /// 
    /// Invariants:
    /// - dependencyIndices array must NOT be modified after graph construction
    /// - All dependency nodes must remain valid in the graph
    bool isReady(const BuildGraph graph) const @system nothrow
    {
        foreach (idx; dependencyIndices)
        {
            auto dep = graph.getNodeByIndex(idx);
            if (dep is null) continue;
            auto depStatus = atomicLoad(dep._status);
            if (depStatus != BuildStatus.Success && depStatus != BuildStatus.Cached)
                return false;
        }
        return true;
    }
    
    /// Cached depth value (size_t.max = uncomputed)
    private size_t _cachedDepth = size_t.max;
    
    /// Get topological depth for scheduling (memoized)
    /// 
    /// Performance: O(V+E) total across all nodes due to memoization.
    /// Uses O(1) indexed access via dependencyIndices.
    /// 
    /// Note: Not const because it modifies internal cache (_cachedDepth).
    size_t depth(BuildGraph graph) @system nothrow
    {
        if (_cachedDepth != size_t.max)
            return _cachedDepth;
        
        if (dependencyIndices.empty)
        {
            _cachedDepth = 0;
            return 0;
        }
        
        size_t maxDepth = 0;
        foreach (idx; dependencyIndices)
        {
            auto dep = graph.getNodeByIndex(idx);
            if (dep is null) continue;
            auto depDepth = dep.depth(graph);
            if (depDepth > maxDepth)
                maxDepth = depDepth;
        }
        
        _cachedDepth = maxDepth + 1;
        return _cachedDepth;
    }
    
    /// Invalidate cached depth (call when dependencies change)
    private void invalidateDepthCache() @system nothrow
    {
        _cachedDepth = size_t.max;
    }
}

enum BuildStatus
{
    Pending,
    Building,
    Success,
    Failed,
    Cached
}

/// Cycle detection strategy for graph construction
enum ValidationMode
{
    /// Check for cycles on every edge addition (O(V²) worst-case)
    /// Provides immediate feedback but slower for large graphs
    Immediate,
    
    /// Defer cycle detection until validate() is called (O(V+E) total)
    /// Optimal for batch construction of large graphs
    Deferred
}

/// Build graph with topological ordering and cycle detection
/// 
/// Performance:
/// - Arena allocation: 10-100x reduction in GC pressure for graph construction
/// - Immediate validation: O(V²) for dense graphs (per-edge cycle check)
/// - Deferred validation: O(V+E) total (single topological sort)
/// 
/// Usage:
/// ```d
/// // Fast batch construction for large graphs with arena allocation
/// auto graph = new BuildGraph(ValidationMode.Deferred, 1000);  // Expect ~1000 nodes
/// foreach (target; targets) graph.addTarget(target);
/// foreach (dep; deps) graph.addDependency(from, to).unwrap();
/// auto result = graph.validate(); // Single O(V+E) validation
/// if (result.isErr) handleCycle(result.unwrapErr());
/// ```
/// 
/// TargetId Migration:
/// - Use `addTargetById(TargetId, Target)` for type-safe target addition
/// - Use `addDependencyById(TargetId, TargetId)` for type-safe dependencies
/// - Use `getNode(TargetId)` and `hasTarget(TargetId)` for lookups
/// - Old string-based methods still available for backward compatibility
/// 
/// Example:
///   auto id = TargetId.parse("//path:target").unwrap();
///   graph.addTargetById(id, target);
///   graph.addDependencyById(id, otherId);
final class BuildGraph
{
    BuildNode[string] nodes;  // Keep string keys for backward compatibility
    BuildNode[] _nodeArray;   // Parallel array for O(1) indexed access in hot paths
    uint[string] _stringToIndex;  // String → index map for O(1) indexed lookup from string keys
    BuildNode[] roots;
    private ValidationMode _validationMode;
    private bool _validated;
    private NodeArena* _arena;  // Optional arena for batch allocation
    private IncrementalTopoOrder _incrementalTopo;  // Incremental topological ordering
    private IncrementalTopoStats _topoStats;        // Statistics for incremental updates
    
    /// Create graph with specified validation mode
    /// expectedNodes: Hint for arena pre-allocation (0 = no arena, use GC)
    this(ValidationMode mode = ValidationMode.Immediate, size_t expectedNodes = 0) @system
    {
        _validationMode = mode;
        _validated = false;
        _incrementalTopo = IncrementalTopoOrder(this);
        
        if (expectedNodes > 0)
        {
            _arena = new NodeArena(expectedNodes);
        }
    }
    
    /// Create arena-backed node (falls back to GC if arena full)
    /// Assigns index for O(1) array access. Public for use during graph construction.
    BuildNode createNode(TargetId id, Target target) @system
    {
        BuildNode node;
        if (_arena !is null)
        {
            node = _arena.allocate(id, target);
            if (node is null)
                node = new BuildNode(id, target);  // Arena full, fallback
        }
        else
        {
            node = new BuildNode(id, target);
        }
        
        // Assign index and add to parallel array
        node._nodeIndex = cast(uint)_nodeArray.length;
        _nodeArray ~= node;
        return node;
    }
    
    /// Get node by index for O(1) hot path access (no hash overhead)
    /// Returns null if index out of bounds
    inout(BuildNode) getNodeByIndex(uint idx) inout @system pure nothrow @nogc
    {
        return idx < _nodeArray.length ? _nodeArray[idx] : null;
    }
    
    /// Get node by string key using indexed lookup (O(1) + hash)
    /// Preferred over direct nodes[key] access for consistency
    /// Returns null if key not found
    inout(BuildNode) getNodeByKey(string key) inout @system nothrow
    {
        if (auto idxPtr = key in _stringToIndex)
            return getNodeByIndex(*idxPtr);
        return null;
    }
    
    /// Get node index by string key for O(1) subsequent lookups
    /// Returns uint.max if key not found
    uint getIndexByKey(string key) const @system nothrow
    {
        if (auto idxPtr = key in _stringToIndex)
            return *idxPtr;
        return uint.max;
    }
    
    /// Check if key exists using indexed lookup
    bool hasKey(string key) const @system nothrow
    {
        return (key in _stringToIndex) !is null;
    }
    
    /// Validate entire graph for cycles (O(V+E))
    /// 
    /// Must be called when using ValidationMode.Deferred before execution.
    /// For Immediate mode, this is optional (cycles already detected).
    /// 
    /// Returns: Ok on success, Err with cycle details on failure
    /// 
    /// Note: Not const because it modifies internal validation state (_validated).
    VoidBuildResult validate() @system
    {
        auto sortResult = topologicalSort();
        if (sortResult.isErr)
            return VoidBuildResult.err(sortResult.unwrapErr());
        
        _validated = true;
        return Ok!BuildError();
    }
    
    /// Check if graph has been validated
    @property bool isValidated() const @system pure nothrow @nogc
    {
        return _validated || _validationMode == ValidationMode.Immediate;
    }
    
    /// Get node count (excludes nulled-out removed nodes)
    @property size_t nodeCount() const @system pure nothrow @nogc
    {
        return _stringToIndex.length;
    }
    
    /// Get validation mode (for serialization)
    @property ValidationMode validationMode() const @system pure nothrow @nogc
    {
        return _validationMode;
    }
    
    /// Set validation mode (for deserialization)
    /// Public access for cache restoration
    @property void validationMode(ValidationMode mode) @system pure nothrow @nogc
    {
        _validationMode = mode;
    }
    
    /// Set validated state (for deserialization)
    /// Public access for cache restoration
    @property void validated(bool v) @system pure nothrow @nogc
    {
        _validated = v;
    }
    
    /// Add a target to the graph (uses TargetId internally)
    /// Returns: Ok on success, Err if target with same ID already exists
    VoidBuildResult addTarget(Target target) @system
    {
        auto id = target.id;
        auto key = id.toString();
        
        if (key in _stringToIndex)
        {
            auto error = ErrorBuilder!GraphError
                .create("Duplicate target in build graph: " ~ key, Graph.Invalid)
                .withContext("adding target to graph", "target: " ~ key)
                .withSuggestion(ErrorSuggestion.fileCheck("Check for duplicate target definitions in Builderfile"))
                .withSuggestion(ErrorSuggestion.fileCheck("Ensure each target has a unique name"))
                .withCommand("List all targets", "bldr list")
                .build();
            return VoidBuildResult.err(cast(BuildError) error);
        }
        
        auto node = createNode(id, target);
        _stringToIndex[key] = node._nodeIndex;
        nodes[key] = node;  // Keep for backward compatibility
        _incrementalTopo.notifyNodeAdded(id);
        return Ok!BuildError();
    }
    
    /// Add a target to the graph using TargetId
    /// Returns: Ok on success, Err if target with same ID already exists
    VoidBuildResult addTargetById(TargetId id, Target target) @system
    {
        auto key = id.toString();
        if (key in _stringToIndex)
        {
            auto error = ErrorBuilder!GraphError
                .create("Duplicate target ID in build graph: " ~ key, Graph.Invalid)
                .withContext("adding target by ID", "targetId: " ~ key)
                .withSuggestion(ErrorSuggestion.fileCheck("Check for duplicate target IDs"))
                .withSuggestion(ErrorSuggestion.fileCheck("Ensure all TargetId values are unique"))
                .withCommand("View dependency graph", "bldr graph")
                .build();
            return VoidBuildResult.err(cast(BuildError) error);
        }
        
        auto node = createNode(id, target);
        _stringToIndex[key] = node._nodeIndex;
        nodes[key] = node;  // Keep for backward compatibility
        _incrementalTopo.notifyNodeAdded(id);
        return Ok!BuildError();
    }
    
    /// Get node by TargetId using indexed lookup
    BuildNode getNodeById(TargetId id) @system nothrow
    {
        return getNodeByKey(id.toString());
    }
    
    /// Get node by TargetId (pointer version for backward compatibility)
    /// Prefer getNodeById() for new code
    BuildNode* getNode(TargetId id) @system
    {
        auto key = id.toString();
        if (key in nodes)
            return &nodes[key];
        return null;
    }
    
    /// Check if graph contains a target by TargetId
    bool hasTarget(TargetId id) @system nothrow
    {
        return hasKey(id.toString());
    }
    
    /// Add dependency between two targets (string version for backward compatibility)
    VoidBuildResult addDependency(in string from, in string to) @system
    {
        auto fromNode = getNodeByKey(from);
        if (fromNode is null)
        {
            auto error = targetNotFoundError(from);
            error.addContext(ErrorContext("adding dependency", "from: " ~ from ~ ", to: " ~ to));
            return VoidBuildResult.err(cast(BuildError) error);
        }
        
        auto toNode = getNodeByKey(to);
        if (toNode is null)
        {
            auto error = targetNotFoundError(to);
            error.addContext(ErrorContext("adding dependency", "from: " ~ from ~ ", to: " ~ to));
            return VoidBuildResult.err(cast(BuildError) error);
        }
        
        // Check for cycles only in immediate mode
        if (_validationMode == ValidationMode.Immediate)
        {
        if (wouldCreateCycle(fromNode, toNode))
        {
            // Use builder pattern with typed suggestions for cycle errors
            import infrastructure.errors.types.context : ErrorSuggestion;
            
            auto error = ErrorBuilder!GraphError.create("Circular dependency detected: adding '" ~ from ~ "' -> '" ~ to ~ "' would create a cycle", Graph.Cycle)
                .withContext("adding dependency", "would create cycle")
                .withCommand("Visualize the dependency cycle", "bldr graph")
                .withFileCheck("Remove or reorder dependencies to break the cycle")
                .withSuggestion("Consider extracting shared code into a separate target")
                .withFileCheck("Check if the dependency is actually needed")
                .build();
            return VoidBuildResult.err(cast(BuildError) error);
            }
        }
        
        fromNode.dependencyIds ~= toNode.id;
        fromNode.dependencyIndices ~= toNode._nodeIndex;  // O(1) index for hot paths
        toNode.dependentIds ~= fromNode.id;
        toNode.dependentIndices ~= fromNode._nodeIndex;   // O(1) index for hot paths
        
        // Invalidate depth cache for affected nodes
        invalidateDepthCascade(fromNode);
        
        // Notify incremental topo order (may update incrementally)
        auto topoResult = _incrementalTopo.notifyEdgeAdded(fromNode.id, toNode.id);
        if (topoResult.isErr)
            return VoidBuildResult.err(topoResult.unwrapErr());
        
        _topoStats.totalEdgeNotifications++;
        
        return Ok!BuildError();
    }
    
    /// Add dependency using TargetId (type-safe version)
    VoidBuildResult addDependencyById(TargetId from, TargetId to) @system
    {
        auto fromKey = from.toString();
        auto toKey = to.toString();
        
        auto fromNode = getNodeByKey(fromKey);
        if (fromNode is null)
            return VoidBuildResult.err(
                Errors.graph("Target '" ~ fromKey ~ "' not found in dependency graph", Graph.NodeNotFound)
                    .withContext("adding dependency", "from: " ~ fromKey ~ ", to: " ~ toKey)
                    .withSuggestion("Ensure target '" ~ fromKey ~ "' is defined in your Builderfile")
                    .withCommand("See all available targets", "bldr graph")
                    .withSuggestion("Check for typos in the target name")
                    .build());
        
        auto toNode = getNodeByKey(toKey);
        if (toNode is null)
            return VoidBuildResult.err(
                Errors.graph("Target '" ~ toKey ~ "' not found in dependency graph", Graph.NodeNotFound)
                    .withContext("adding dependency", "from: " ~ fromKey ~ ", to: " ~ toKey)
                    .withSuggestion("Ensure target '" ~ toKey ~ "' is defined in your Builderfile")
                    .withCommand("See all available targets", "bldr graph")
                    .withSuggestion("Check for typos in the target name")
                    .build());
        
        // Check for cycles only in immediate mode
        if (_validationMode == ValidationMode.Immediate)
        {
        if (wouldCreateCycle(fromNode, toNode))
            return VoidBuildResult.err(
                Errors.graph("Circular dependency detected: adding '" ~ fromKey ~ "' -> '" ~ toKey ~ "' would create a cycle", Graph.Cycle)
                    .withContext("adding dependency", "would create cycle")
                    .withCommand("Visualize the dependency cycle", "bldr graph")
                    .withSuggestion("Remove or reorder dependencies to break the cycle")
                    .withSuggestion("Consider extracting shared code into a separate target")
                    .withSuggestion("Check if the dependency is actually needed")
                    .build());
        }
        
        fromNode.dependencyIds ~= toNode.id;
        fromNode.dependencyIndices ~= toNode._nodeIndex;  // O(1) index for hot paths
        toNode.dependentIds ~= fromNode.id;
        toNode.dependentIndices ~= fromNode._nodeIndex;   // O(1) index for hot paths
        
        // Invalidate depth cache for affected nodes
        invalidateDepthCascade(fromNode);
        
        // Notify incremental topo order (may update incrementally)
        auto topoResult = _incrementalTopo.notifyEdgeAdded(from, to);
        if (topoResult.isErr)
            return VoidBuildResult.err(topoResult.unwrapErr());
        
        _topoStats.totalEdgeNotifications++;
        
        return Ok!BuildError();
    }
    
    /// Invalidate depth cache for node and all dependents (cascade upward)
    /// 
    /// When a node gains a new dependency, all nodes that depend on it
    /// may need recalculation of their depth.
    /// 
    /// Note: Uses visited set to prevent infinite recursion in case of cycles
    /// (cycles will be detected later during validation).
    private void invalidateDepthCascade(BuildNode node) @system nothrow
    {
        bool[uint] visited;  // Use index for faster visited check
        
        void invalidateRecursive(BuildNode n) nothrow
        {
            if (n._nodeIndex in visited)
                return;
            
            visited[n._nodeIndex] = true;
            n.invalidateDepthCache();
            
            // Fast path: indexed access
            if (n.dependentIndices.length == n.dependentIds.length && _nodeArray.length > 0)
            {
                foreach (idx; n.dependentIndices)
                {
                    if (idx < _nodeArray.length && _nodeArray[idx] !is null)
                        invalidateRecursive(_nodeArray[idx]);
                }
            }
            else
            {
                foreach (dependentId; n.dependentIds)
                {
                    auto dep = getNodeByKey(dependentId.toString());
                    if (dep !is null)
                        invalidateRecursive(dep);
                }
            }
        }
        
        invalidateRecursive(node);
    }
    
    /// Check if adding an edge would create a cycle (O(V+E) worst case)
    /// 
    /// Uses O(1) indexed access when available for hot path optimization.
    /// Used only in Immediate validation mode. For large graphs, prefer
    /// Deferred mode with a single O(V+E) topological sort.
    private bool wouldCreateCycle(BuildNode from, BuildNode to) @system
    {
        bool[uint] visited;  // Use index for faster visited check
        
        bool dfs(BuildNode node)
        {
            if (node == from)
                return true;
            
            if (node._nodeIndex in visited)
                return false;
            
            visited[node._nodeIndex] = true;
            
            // Fast path: indexed access
            if (node.dependencyIndices.length == node.dependencyIds.length && _nodeArray.length > 0)
            {
                foreach (idx; node.dependencyIndices)
                {
                    if (idx < _nodeArray.length && _nodeArray[idx] !is null)
                        if (dfs(_nodeArray[idx]))
                            return true;
                }
            }
            else
            {
                foreach (depId; node.dependencyIds)
                {
                    auto dep = getNodeByKey(depId.toString());
                    if (dep !is null && dfs(dep))
                        return true;
                }
            }
            
            return false;
        }
        
        return dfs(to);
    }
    
    /// Get nodes in topological order (leaves first)
    /// Returns Result to handle cycles gracefully
    /// 
    /// Uses incremental topological ordering for watch mode efficiency:
    /// - O(1) cache hit when graph unchanged
    /// - O(affected) incremental update on edge changes
    /// - O(V+E) full recomputation only when necessary
    /// 
    /// Safety: This function is @system because:
    /// 1. Nested function captures only local variables and graph
    /// 2. Associative array operations are bounds-checked
    /// 3. Array appending (~=) is memory-safe
    /// 4. Node references remain valid (classes on GC heap)
    /// 5. Error result propagation maintains type safety
    /// 
    /// Invariants:
    /// - Graph structure is not modified during traversal
    /// - Node references remain valid (classes on GC heap)
    /// 
    /// What could go wrong:
    /// - If nodes array is modified during iteration: undefined behavior
    /// - Prevented by not exposing mutable access during traversal
    BuildResult!(BuildNode[]) topologicalSort() @system
    {
        // Try incremental cache first
        auto cachedResult = _incrementalTopo.getOrder();
        if (cachedResult.isOk)
        {
            auto cached = cachedResult.unwrap();
            // Validate cache matches current graph state
            if (cached.length == nodes.length)
            {
                _topoStats.cacheHits++;
                return cachedResult;
            }
            // Cache stale (nodes added/removed), invalidate
            _incrementalTopo.invalidate();
        }
        
        // Full recomputation (also updates incremental cache)
        _topoStats.fullRecomputations++;
        return _incrementalTopo.getOrder();
    }
    
    /// Get topological order with forced full recomputation (bypasses cache)
    /// Use when graph structure may have changed externally
    BuildResult!(BuildNode[]) topologicalSortFresh() @system
    {
        _incrementalTopo.invalidate();
        _topoStats.fullRecomputations++;
        return _incrementalTopo.getOrder();
    }
    
    /// Get all nodes that can be built in parallel (no deps or deps satisfied)
    BuildNode[] getReadyNodes()
    {
        return nodes.values
            .filter!(n => n.status == BuildStatus.Pending && n.isReady(this))
            .array;
    }
    
    /// Get root nodes (no dependencies)
    BuildNode[] getRoots()
    {
        return nodes.values
            .filter!(n => n.dependencyIds.empty)
            .array;
    }
    
    /// Print the graph for visualization
    /// 
    /// Note: Not const because it calls topologicalSort() which may modify depth caches.
    void print()
    {
        import infrastructure.utils.logging;
        import infrastructure.errors.formatting.format;
        
        writeln("\nBuild Graph:");
        writeln("============");
        
        auto sortResult = topologicalSort();
        if (sortResult.isErr)
        {
            structuredLog.error("cannot_print_graph_").field("detail", "Cannot print graph: " ~ format(sortResult.unwrapErr())).emit();
            return;
        }
        
        auto sorted = sortResult.unwrap();
        
        foreach (node; sorted)
        {
            // Safety: Skip null nodes to prevent segfault
            if (node is null)
                continue;
            
            writeln("\nTarget: ", node.id);
            writeln("  Type: ", node.target.type);
            writeln("  Sources: ", node.target.sources.length, " files");
            
            if (!node.dependencyIds.empty)
            {
                writeln("  Dependencies:");
                foreach (depId; node.dependencyIds)
                {
                    writeln("    - ", depId);
                }
            }
            
            if (!node.dependentIds.empty)
            {
                writeln("  Dependents:");
                foreach (depId; node.dependentIds)
                {
                    writeln("    - ", depId);
                }
            }
        }
        
        writeln("\nBuild order (", sorted.length, " targets):");
        foreach (i, node; sorted)
        {
            // Safety: Skip null nodes and catch any exceptions from depth()
            if (node !is null)
            {
                try
                {
                    writeln("  ", i + 1, ". ", node.id, " (depth: ", node.depth(this), ")");
                }
                catch (Exception e)
                {
                    writeln("  ", i + 1, ". ", node.id, " (depth: ERROR)");
                }
            }
        }
    }
    
    /// Get statistics about the graph
    struct GraphStats
    {
        size_t totalNodes;
        size_t totalEdges;
        size_t maxDepth;
        size_t parallelism; // Max nodes that can be built in parallel
        size_t criticalPathLength; // Longest path through graph
        // Arena allocation stats (0 = no arena used)
        size_t arenaNodesAllocated;
        size_t arenaCapacityUsed;
        size_t arenaTotalCapacity;
    }
    
    /// Get statistics about the graph
    /// 
    /// Note: Not const because it calls depth() which modifies caches.
    GraphStats getStats()
    {
        GraphStats stats;
        stats.totalNodes = nodes.length;
        
        foreach (node; nodes.values)
        {
            stats.totalEdges += node.dependencyIds.length;
            stats.maxDepth = max(stats.maxDepth, node.depth(this));
        }
        
        // Calculate max parallelism by depth
        size_t[size_t] nodesByDepth;
        foreach (node; nodes.values)
            nodesByDepth[node.depth(this)]++;
        
        if (!nodesByDepth.empty)
            stats.parallelism = nodesByDepth.values.maxElement;
        
        // Calculate critical path length
        stats.criticalPathLength = calculateCriticalPathLength();
        
        // Arena stats
        if (_arena !is null)
        {
            stats.arenaNodesAllocated = _arena.count;
            stats.arenaCapacityUsed = _arena.used;
            stats.arenaTotalCapacity = _arena.capacity;
        }
        
        return stats;
    }
    
    /// Get incremental topological sort statistics
    @property IncrementalTopoStats incrementalStats() const @system pure nothrow @nogc
    {
        return _topoStats;
    }
    
    /// Check if topological order cache is valid
    @property bool hasValidTopoCache() const @system nothrow
    {
        return _incrementalTopo.isValid;
    }
    
    /// Get topological order cache version (for external coordination)
    @property ulong topoCacheVersion() const @system nothrow
    {
        return _incrementalTopo.version_;
    }
    
    /// Get nodes affected by a change to a specific target
    /// Useful for watch mode to determine minimal rebuild scope
    /// Returns nodes in topological order (leaves first for proper rebuild)
    BuildNode[] getAffectedNodes(TargetId changedTarget) @system
    {
        return _incrementalTopo.getAffectedNodes(changedTarget);
    }
    
    /// Check if target A must be built before target B
    /// Returns true if B depends on A (directly or transitively)
    bool mustPrecede(TargetId a, TargetId b) @system
    {
        return _incrementalTopo.mustPrecede(a, b);
    }
    
    /// Remove a target from the graph
    /// Returns: Ok on success, Err if target not found
    VoidBuildResult removeTarget(TargetId id) @system
    {
        auto key = id.toString();
        auto node = getNodeByKey(key);
        if (node is null)
            return VoidBuildResult.err(
                Errors.graph("Target not found: " ~ key, Graph.NodeNotFound).build());
        
        auto removedIdx = node._nodeIndex;
        
        // Remove from dependents of dependencies (use indexed access)
        foreach (idx; node.dependencyIndices)
        {
            auto dep = getNodeByIndex(idx);
            if (dep !is null)
            {
                dep.dependentIds = dep.dependentIds.filter!(d => d != id).array;
                dep.dependentIndices = dep.dependentIndices.filter!(i => i != removedIdx).array;
            }
        }
        
        // Remove from dependencies of dependents (use indexed access)
        foreach (idx; node.dependentIndices)
        {
            auto dep = getNodeByIndex(idx);
            if (dep !is null)
            {
                dep.dependencyIds = dep.dependencyIds.filter!(d => d != id).array;
                dep.dependencyIndices = dep.dependencyIndices.filter!(i => i != removedIdx).array;
                invalidateDepthCascade(dep);
            }
        }
        
        // Null out in parallel array (lazy deletion - preserves other indices)
        if (removedIdx < _nodeArray.length)
            _nodeArray[removedIdx] = null;
        
        _stringToIndex.remove(key);
        nodes.remove(key);
        _incrementalTopo.notifyNodeRemoved(id);
        
        return Ok!BuildError();
    }
    
    /// Invalidate topological order cache (call when external changes occur)
    void invalidateTopoCache() @system nothrow
    {
        _incrementalTopo.invalidate();
    }
    
    /// Calculate critical path cost for all nodes
    /// Returns map of node ID to critical path cost (estimated build time to completion)
    size_t[string] calculateCriticalPath(size_t delegate(BuildNode) @system estimateCost) @system
    {
        size_t[string] costs;
        bool[uint] visited;  // Index-based for faster check
        
        size_t visit(BuildNode node) @system
        {
            if (node._nodeIndex in visited)
                return costs.get(node.id.toString(), 0);
            
            visited[node._nodeIndex] = true;
            
            // Get max cost of dependents (reverse direction - who depends on me)
            size_t maxDependentCost = 0;
            
            // Fast path: indexed access
            if (node.dependentIndices.length == node.dependentIds.length && _nodeArray.length > 0)
            {
                foreach (idx; node.dependentIndices)
                {
                    if (idx < _nodeArray.length && _nodeArray[idx] !is null)
                        maxDependentCost = max(maxDependentCost, visit(_nodeArray[idx]));
                }
            }
            else
            {
                foreach (idx; node.dependentIndices)
                {
                    auto dep = getNodeByIndex(idx);
                    if (dep !is null)
                        maxDependentCost = max(maxDependentCost, visit(dep));
                }
            }
            
            // Critical path cost = own cost + max dependent cost
            immutable cost = estimateCost(node) + maxDependentCost;
            costs[node.id.toString()] = cost;
            return cost;
        }
        
        foreach (node; _nodeArray)
            if (node !is null)
                visit(node);
        
        return costs;
    }
    
    /// Calculate critical path length (longest chain)
    /// Uses the already-computed depth values from nodes to avoid redundant computation
    private size_t calculateCriticalPathLength() @system
    {
        if (nodes.empty)
            return 0;
        
        // Critical path is the maximum depth across all nodes
        // Each node's depth is computed via the depth() method which tracks the
        // longest path from that node to any leaf (node with no dependencies)
        size_t maxPath = 0;
        foreach (node; nodes.values)
            maxPath = max(maxPath, node.depth(this));
        return maxPath;
    }
}

