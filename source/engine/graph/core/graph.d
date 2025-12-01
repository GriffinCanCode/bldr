module engine.graph.core.graph;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import core.atomic;
import infrastructure.config.schema.schema;
import infrastructure.errors;

/// Represents a node in the build graph
/// Thread-safe: status field is accessed atomically
/// 
/// Memory Optimization: Stores TargetId[] instead of BuildNode[] to avoid GC cycles
/// from bidirectional references. This reduces memory pressure and prevents potential
/// memory leaks from circular references between dependencies and dependents.
final class BuildNode
{
    TargetId id;  // Strongly-typed identifier
    Target target;
    TargetId[] dependencyIds;  // IDs instead of pointers to avoid GC cycles
    TargetId[] dependentIds;   // IDs instead of pointers to avoid GC cycles
    private shared BuildStatus _status;  // Atomic access only
    string hash;
    
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
        dependencyIds.reserve(8);  // Most targets have <8 dependencies
        dependentIds.reserve(4);    // Fewer dependents on average
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
    /// Invariants:
    /// - dependencyIds array must NOT be modified after graph construction
    /// - All dependency nodes must remain valid in the graph
    /// 
    /// What could go wrong:
    /// - If dependencyIds array is modified during iteration: undefined behavior
    /// - If dependency nodes are removed from graph: lookup fails
    /// - These are prevented by design: graph is immutable after construction
    bool isReady(const BuildGraph graph) const @system nothrow
    {
        foreach (depId; dependencyIds)
        {
            auto depKey = depId.toString();
            if (depKey !in graph.nodes)
                continue;  // Skip missing dependencies (defensive)
            
            auto dep = graph.nodes[depKey];
            auto depStatus = atomicLoad(dep._status);
            if (depStatus != BuildStatus.Success && depStatus != BuildStatus.Cached)
                return false;
        }
        return true;
    }
    
    /// Cached depth value (size_t.max = uncomputed)
    private size_t _cachedDepth = size_t.max;
    
    /// Get topological depth for scheduling (memoized)
    /// Requires graph reference to resolve dependency IDs to nodes
    /// 
    /// Performance: O(V+E) total across all nodes due to memoization.
    /// Without memoization, this would be O(E^depth) - exponential for deep graphs.
    /// 
    /// Note: Not const because it modifies internal cache (_cachedDepth) for memoization.
    size_t depth(BuildGraph graph) @system nothrow
    {
        if (_cachedDepth != size_t.max)
            return _cachedDepth;
        
        if (dependencyIds.empty)
        {
            _cachedDepth = 0;
            return 0;
        }
        
        size_t maxDepth = 0;
        foreach (depId; dependencyIds)
        {
            auto depKey = depId.toString();
            if (depKey !in graph.nodes)
                continue;  // Skip missing dependencies (defensive)
            
            auto dep = graph.nodes[depKey];
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
/// - Immediate validation: O(V²) for dense graphs (per-edge cycle check)
/// - Deferred validation: O(V+E) total (single topological sort)
/// 
/// Usage:
/// ```d
/// // Fast batch construction for large graphs
/// auto graph = new BuildGraph(ValidationMode.Deferred);
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
    BuildNode[] roots;
    private ValidationMode _validationMode;
    private bool _validated;
    
    /// Create graph with specified validation mode
    this(ValidationMode mode = ValidationMode.Immediate) @system pure nothrow
    {
        _validationMode = mode;
        _validated = false;
    }
    
    /// Validate entire graph for cycles (O(V+E))
    /// 
    /// Must be called when using ValidationMode.Deferred before execution.
    /// For Immediate mode, this is optional (cycles already detected).
    /// 
    /// Returns: Ok on success, Err with cycle details on failure
    /// 
    /// Note: Not const because it modifies internal validation state (_validated).
    Result!BuildError validate() @system
    {
        auto sortResult = topologicalSort();
        if (sortResult.isErr)
            return Result!BuildError.err(sortResult.unwrapErr());
        
        _validated = true;
        return Ok!BuildError();
    }
    
    /// Check if graph has been validated
    @property bool isValidated() const @system pure nothrow @nogc
    {
        return _validated || _validationMode == ValidationMode.Immediate;
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
    Result!BuildError addTarget(Target target) @system
    {
        auto id = target.id;
        auto key = id.toString();
        
        if (key in nodes)
        {
            auto error = ErrorBuilder!GraphError
                .create("Duplicate target in build graph: " ~ key, ErrorCode.GraphInvalid)
                .withContext("adding target to graph", "target: " ~ key)
                .withSuggestion(ErrorSuggestion.fileCheck("Check for duplicate target definitions in Builderfile"))
                .withSuggestion(ErrorSuggestion.fileCheck("Ensure each target has a unique name"))
                .withCommand("List all targets", "bldr list")
                .build();
            return Result!BuildError.err(cast(BuildError) error);
        }
        
        auto node = new BuildNode(id, target);
        nodes[key] = node;
        return Ok!BuildError();
    }
    
    /// Add a target to the graph using TargetId
    /// Returns: Ok on success, Err if target with same ID already exists
    Result!BuildError addTargetById(TargetId id, Target target) @system
    {
        auto key = id.toString();
        if (key in nodes)
        {
            auto error = ErrorBuilder!GraphError
                .create("Duplicate target ID in build graph: " ~ key, ErrorCode.GraphInvalid)
                .withContext("adding target by ID", "targetId: " ~ key)
                .withSuggestion(ErrorSuggestion.fileCheck("Check for duplicate target IDs"))
                .withSuggestion(ErrorSuggestion.fileCheck("Ensure all TargetId values are unique"))
                .withCommand("View dependency graph", "bldr graph")
                .build();
            return Result!BuildError.err(cast(BuildError) error);
        }
        
        auto node = new BuildNode(id, target);
        nodes[key] = node;
        return Ok!BuildError();
    }
    
    /// Get node by TargetId
    BuildNode* getNode(TargetId id) @system
    {
        auto key = id.toString();
        if (key in nodes)
            return &nodes[key];
        return null;
    }
    
    /// Check if graph contains a target by TargetId
    bool hasTarget(TargetId id) @system
    {
        return (id.toString() in nodes) !is null;
    }
    
    /// Add dependency between two targets (string version for backward compatibility)
    Result!BuildError addDependency(in string from, in string to) @system
    {
        if (from !in nodes)
        {
            // Use smart constructor for target not found errors
            auto error = targetNotFoundError(from);
            error.addContext(ErrorContext("adding dependency", "from: " ~ from ~ ", to: " ~ to));
            return Result!BuildError.err(cast(BuildError) error);
        }
        
        if (to !in nodes)
        {
            // Use smart constructor for target not found errors
            auto error = targetNotFoundError(to);
            error.addContext(ErrorContext("adding dependency", "from: " ~ from ~ ", to: " ~ to));
            return Result!BuildError.err(cast(BuildError) error);
        }
        
        auto fromNode = nodes[from];
        auto toNode = nodes[to];
        
        // Check for cycles only in immediate mode
        if (_validationMode == ValidationMode.Immediate)
        {
        if (wouldCreateCycle(fromNode, toNode))
        {
            // Use builder pattern with typed suggestions for cycle errors
            import infrastructure.errors.types.context : ErrorSuggestion;
            
            auto error = ErrorBuilder!GraphError.create("Circular dependency detected: adding '" ~ from ~ "' -> '" ~ to ~ "' would create a cycle", ErrorCode.GraphCycle)
                .withContext("adding dependency", "would create cycle")
                .withCommand("Visualize the dependency cycle", "bldr graph")
                .withFileCheck("Remove or reorder dependencies to break the cycle")
                .withSuggestion("Consider extracting shared code into a separate target")
                .withFileCheck("Check if the dependency is actually needed")
                .build();
            return Result!BuildError.err(cast(BuildError) error);
            }
        }
        
        fromNode.dependencyIds ~= toNode.id;
        toNode.dependentIds ~= fromNode.id;
        
        // Invalidate depth cache for affected nodes
        invalidateDepthCascade(fromNode);
        
        return Ok!BuildError();
    }
    
    /// Add dependency using TargetId (type-safe version)
    Result!BuildError addDependencyById(TargetId from, TargetId to) @system
    {
        auto fromKey = from.toString();
        auto toKey = to.toString();
        
        if (fromKey !in nodes)
        {
            auto error = new GraphError("Target '" ~ fromKey ~ "' not found in dependency graph", ErrorCode.NodeNotFound);
            error.addContext(ErrorContext("adding dependency", "from: " ~ fromKey ~ ", to: " ~ toKey));
            error.addSuggestion("Ensure target '" ~ fromKey ~ "' is defined in your Builderfile");
            error.addSuggestion("Run 'bldr graph' to see all available targets");
            error.addSuggestion("Check for typos in the target name");
            return Result!BuildError.err(cast(BuildError) error);
        }
        
        if (toKey !in nodes)
        {
            auto error = new GraphError("Target '" ~ toKey ~ "' not found in dependency graph", ErrorCode.NodeNotFound);
            error.addContext(ErrorContext("adding dependency", "from: " ~ fromKey ~ ", to: " ~ toKey));
            error.addSuggestion("Ensure target '" ~ toKey ~ "' is defined in your Builderfile");
            error.addSuggestion("Run 'bldr graph' to see all available targets");
            error.addSuggestion("Check for typos in the target name");
            return Result!BuildError.err(cast(BuildError) error);
        }
        
        auto fromNode = nodes[fromKey];
        auto toNode = nodes[toKey];
        
        // Check for cycles only in immediate mode
        if (_validationMode == ValidationMode.Immediate)
        {
        if (wouldCreateCycle(fromNode, toNode))
        {
            auto error = new GraphError("Circular dependency detected: adding '" ~ fromKey ~ "' -> '" ~ toKey ~ "' would create a cycle", ErrorCode.GraphCycle);
            error.addContext(ErrorContext("adding dependency", "would create cycle"));
            error.addSuggestion("Run 'bldr graph' to visualize the dependency cycle");
            error.addSuggestion("Remove or reorder dependencies to break the cycle");
            error.addSuggestion("Consider extracting shared code into a separate target");
            error.addSuggestion("Check if the dependency is actually needed");
            return Result!BuildError.err(cast(BuildError) error);
            }
        }
        
        fromNode.dependencyIds ~= toNode.id;
        toNode.dependentIds ~= fromNode.id;
        
        // Invalidate depth cache for affected nodes
        invalidateDepthCascade(fromNode);
        
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
        bool[string] visited;
        
        void invalidateRecursive(BuildNode n) nothrow
        {
            auto key = n.id.toString();
            if (key in visited)
                return;
            
            visited[key] = true;
            n.invalidateDepthCache();
            
            foreach (dependentId; n.dependentIds)
            {
                auto depKey = dependentId.toString();
                if (depKey in nodes)
                    invalidateRecursive(nodes[depKey]);
            }
        }
        
        invalidateRecursive(node);
    }
    
    /// Check if adding an edge would create a cycle (O(V+E) worst case)
    /// 
    /// Note: This function could potentially be @system as it only performs
    /// safe operations (AA access, reference comparisons, array traversal).
    /// Marked @system conservatively for nested function with closure.
    /// 
    /// Used only in Immediate validation mode. For large graphs, prefer
    /// Deferred mode with a single O(V+E) topological sort.
    private bool wouldCreateCycle(BuildNode from, BuildNode to) @system
    {
        bool[string] visited;
        
        bool dfs(BuildNode node)
        {
            if (node == from)
                return true;
            
            auto nodeKey = node.id.toString();
            if (nodeKey in visited)
                return false;
            
            visited[nodeKey] = true;
            
            foreach (depId; node.dependencyIds)
            {
                auto depKey = depId.toString();
                if (depKey in nodes)
                {
                    if (dfs(nodes[depKey]))
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
    Result!(BuildNode[], BuildError) topologicalSort() @system
    {
        BuildNode[] sorted;
        bool[string] visited;
        bool[string] visiting;
        BuildError cycleError = null;
        
        void visit(BuildNode node)
        {
            if (cycleError !is null)
                return;
            
            auto nodeKey = node.id.toString();
            if (nodeKey in visited)
                return;
            
            if (nodeKey in visiting)
            {
                auto error = new GraphError("Circular dependency detected in build graph involving target: " ~ node.id.toString(), ErrorCode.GraphCycle);
                error.addContext(ErrorContext("topological sort", "cycle detected"));
                error.addSuggestion("Run 'bldr graph' to visualize all dependencies");
                error.addSuggestion("Trace the cycle by checking which targets depend on '" ~ node.id.toString() ~ "'");
                error.addSuggestion("Break the cycle by removing or refactoring dependencies");
                error.addSuggestion("Consider using lazy loading or interface-based design patterns");
                cycleError = cast(BuildError) error;
                return;
            }
            
            visiting[nodeKey] = true;
            
            foreach (depId; node.dependencyIds)
            {
                auto depKey = depId.toString();
                if (depKey in nodes)
                    visit(nodes[depKey]);
            }
            
            visiting.remove(nodeKey);
            visited[nodeKey] = true;
            sorted ~= node;
        }
        
        foreach (node; nodes.values)
        {
            visit(node);
            if (cycleError !is null)
                return Result!(BuildNode[], BuildError).err(cycleError);
        }
        
        return Result!(BuildNode[], BuildError).ok(sorted);
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
        import infrastructure.utils.logging.logger;
        import infrastructure.errors.formatting.format;
        
        writeln("\nBuild Graph:");
        writeln("============");
        
        auto sortResult = topologicalSort();
        if (sortResult.isErr)
        {
            Logger.error("Cannot print graph: " ~ format(sortResult.unwrapErr()));
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
        
        return stats;
    }
    
    /// Calculate critical path cost for all nodes
    /// Returns map of node ID to critical path cost (estimated build time to completion)
    size_t[string] calculateCriticalPath(size_t delegate(BuildNode) @system estimateCost) @system
    {
        size_t[string] costs;
        bool[string] visited;
        
        size_t visit(BuildNode node) @system
        {
            if (node.id.toString() in visited)
                return costs[node.id.toString()];
            
            visited[node.id.toString()] = true;
            
            // Get max cost of dependents (reverse direction - who depends on me)
            size_t maxDependentCost = 0;
            foreach (dependentId; node.dependentIds)
            {
                auto depKey = dependentId.toString();
                if (depKey in nodes)
                {
                    immutable depCost = visit(nodes[depKey]);
                    maxDependentCost = max(maxDependentCost, depCost);
                }
            }
            
            // Critical path cost = own cost + max dependent cost
            immutable cost = estimateCost(node) + maxDependentCost;
            costs[node.id.toString()] = cost;
            return cost;
        }
        
        foreach (node; nodes.values)
            visit(node);
        
        return costs;
    }
    
    /// Calculate critical path length (longest chain)
    private size_t calculateCriticalPathLength() @system
    {
        if (nodes.empty)
            return 0;
        
        size_t maxPath = 0;
        bool[string] visited;
        
        size_t dfs(BuildNode node)
        {
            auto nodeKey = node.id.toString();
            if (nodeKey in visited)
                return 0;
            
            visited[nodeKey] = true;
            
            size_t maxDepPath = 0;
            foreach (depId; node.dependencyIds)
            {
                auto depKey = depId.toString();
                if (depKey in nodes)
                    maxDepPath = max(maxDepPath, dfs(nodes[depKey]));
            }
            
            return 1 + maxDepPath;
        }
        
        foreach (node; nodes.values)
            maxPath = max(maxPath, dfs(node));
        
        return maxPath;
    }
}

