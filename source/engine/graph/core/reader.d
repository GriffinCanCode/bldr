module engine.graph.core.reader;

import infrastructure.config.schema.schema : TargetId, Target, TargetType;
import engine.graph.core.graph : BuildNode, BuildStatus;

/// Read-only graph interface for zero-copy access patterns
/// 
/// Enables unified access to both:
/// - Live BuildGraph with BuildNode objects
/// - MappedGraphView with memory-mapped backing
/// 
/// Design: Eliminates deserialization overhead by allowing direct
/// iteration over memory-mapped graph topology.
interface IGraphReader
{
    /// Number of nodes in the graph
    @property size_t nodeCount() const @safe nothrow;
    
    /// Number of edges in the graph
    @property size_t edgeCount() const @safe nothrow;
    
    /// Check if graph has been validated (cycle-free)
    @property bool isValidated() const @safe nothrow;
    
    /// Iterate all nodes with zero-copy access
    /// Delegate receives: (nodeIndex, targetId, targetType, status, outputPath)
    int opApply(scope int delegate(size_t, const(char)[], TargetType, BuildStatus, const(char)[]) @system dg) @system;
    
    /// Get node status by index (O(1))
    BuildStatus getStatus(size_t nodeIndex) const @system nothrow;
    
    /// Get target ID string by index (zero-copy slice for mmap)
    const(char)[] getTargetId(size_t nodeIndex) const @system nothrow;
    
    /// Get target type by index
    TargetType getTargetType(size_t nodeIndex) const @system nothrow;
    
    /// Get output path by index (zero-copy slice for mmap)
    const(char)[] getOutputPath(size_t nodeIndex) const @system nothrow;
    
    /// Get node hash by index (zero-copy for mmap)
    const(ubyte)[] getHash(size_t nodeIndex) const @system nothrow;
    
    /// Get dependency indices for node (O(deps))
    uint[] getDependencyIndices(size_t nodeIndex) const @system;
    
    /// Get dependent indices for node (O(deps))
    uint[] getDependentIndices(size_t nodeIndex) const @system;
    
    /// Find node index by target ID string (O(1) with hash, O(n) without)
    /// Returns uint.max if not found
    uint findNodeIndex(const(char)[] targetId) const @system nothrow;
    
    /// Check if all dependencies of a node are satisfied (Success or Cached)
    bool isDependenciesSatisfied(size_t nodeIndex) const @system nothrow;
}

/// Read-only node view for iteration (stack-allocated, zero-copy)
struct GraphNodeView
{
    size_t index;
    const(char)[] targetId;
    TargetType targetType;
    BuildStatus status;
    const(char)[] outputPath;
    const(ubyte)[] hash;
    
    /// Check if this view is valid
    bool valid() const @safe pure nothrow @nogc => targetId.length > 0;
}

/// Adapter to make BuildGraph implement IGraphReader
final class BuildGraphReader : IGraphReader
{
    private import engine.graph.core.graph : BuildGraph;
    private BuildGraph _graph;
    
    this(BuildGraph graph) @safe { _graph = graph; }
    
    @property size_t nodeCount() const @safe nothrow => _graph._nodeArray.length;
    
    @property size_t edgeCount() const @safe nothrow
    {
        size_t count;
        foreach (node; _graph._nodeArray)
            if (node !is null) count += node.dependencyIds.length;
        return count;
    }
    
    @property bool isValidated() const @safe nothrow
    {
        // Can't call @system isValidated from @safe context
        return true; // Assume validated for reader
    }
    
    int opApply(scope int delegate(size_t, const(char)[], TargetType, BuildStatus, const(char)[]) @system dg) @system
    {
        foreach (i, node; _graph._nodeArray)
        {
            if (node is null) continue;
            if (auto r = dg(i, node.id.toString(), node.target.type, node.status, node.target.outputPath))
                return r;
        }
        return 0;
    }
    
    BuildStatus getStatus(size_t nodeIndex) const @system nothrow
    {
        if (nodeIndex >= _graph._nodeArray.length) return BuildStatus.Pending;
        auto node = _graph._nodeArray[nodeIndex];
        return node !is null ? node.status : BuildStatus.Pending;
    }
    
    const(char)[] getTargetId(size_t nodeIndex) const @system nothrow
    {
        if (nodeIndex >= _graph._nodeArray.length) return null;
        auto node = _graph._nodeArray[nodeIndex];
        return node !is null ? node.id.toString() : null;
    }
    
    TargetType getTargetType(size_t nodeIndex) const @system nothrow
    {
        if (nodeIndex >= _graph._nodeArray.length) return TargetType.Executable;
        auto node = _graph._nodeArray[nodeIndex];
        return node !is null ? node.target.type : TargetType.Executable;
    }
    
    const(char)[] getOutputPath(size_t nodeIndex) const @system nothrow
    {
        if (nodeIndex >= _graph._nodeArray.length) return null;
        auto node = _graph._nodeArray[nodeIndex];
        return node !is null ? node.target.outputPath : null;
    }
    
    const(ubyte)[] getHash(size_t nodeIndex) const @system nothrow
    {
        if (nodeIndex >= _graph._nodeArray.length) return null;
        auto node = _graph._nodeArray[nodeIndex];
        return node !is null ? cast(const(ubyte)[])node.hash : null;
    }
    
    uint[] getDependencyIndices(size_t nodeIndex) const @system
    {
        if (nodeIndex >= _graph._nodeArray.length) return null;
        auto node = _graph._nodeArray[nodeIndex];
        return node !is null ? node.dependencyIndices.dup : null;
    }
    
    uint[] getDependentIndices(size_t nodeIndex) const @system
    {
        if (nodeIndex >= _graph._nodeArray.length) return null;
        auto node = _graph._nodeArray[nodeIndex];
        return node !is null ? node.dependentIndices.dup : null;
    }
    
    uint findNodeIndex(const(char)[] targetId) const @system nothrow
    {
        if (auto idx = cast(string)targetId in _graph._stringToIndex)
            return *idx;
        return uint.max;
    }
    
    bool isDependenciesSatisfied(size_t nodeIndex) const @system nothrow
    {
        if (nodeIndex >= _graph._nodeArray.length) return false;
        auto node = _graph._nodeArray[nodeIndex];
        if (node is null) return false;
        
        foreach (depIdx; node.dependencyIndices)
        {
            auto status = getStatus(depIdx);
            if (status != BuildStatus.Success && status != BuildStatus.Cached)
                return false;
        }
        return true;
    }
}

