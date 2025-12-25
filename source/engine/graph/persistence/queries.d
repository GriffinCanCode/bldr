module engine.graph.persistence.queries;

import std.algorithm : map, filter, sort, uniq;
import std.array : array, appender;
import std.range : take;
import engine.graph.persistence.index;
import engine.graph.core.graph : BuildStatus;
import infrastructure.errors;

/// High-level graph query interface built on GraphIndex
/// Provides semantic queries without loading full graph into memory
/// 
/// Design: Composable query primitives for build analysis
/// - Dependency chain analysis
/// - Impact analysis (what rebuilds if X changes)
/// - Build order optimization
/// - Bottleneck detection
struct GraphQuery
{
    private GraphIndex index;
    
    this(GraphIndex index) @system { this.index = index; }
    
    /// Get build order (topological sort via depth)
    string[] getBuildOrder() @system
    {
        auto nodes = index.listNodes();  // Already sorted by depth DESC
        nodes.reverse();  // Leaves first for build order
        return nodes;
    }
    
    /// Get nodes ready to build (all deps satisfied)
    string[] getReadyNodes() @system
    {
        auto pending = index.queryByStatus(BuildStatus.Pending);
        
        string[] ready;
        foreach (nodeId; pending)
        {
            auto deps = index.getDependencies(nodeId);
            bool allSatisfied = true;
            
            foreach (dep; deps)
            {
                auto depResult = index.getNode(dep);
                if (depResult.isErr) continue;
                
                auto status = depResult.unwrap().status;
                if (status != BuildStatus.Success && status != BuildStatus.Cached)
                {
                    allSatisfied = false;
                    break;
                }
            }
            
            if (allSatisfied)
                ready ~= nodeId;
        }
        
        return ready;
    }
    
    /// Impact analysis: what needs to rebuild if nodeId changes?
    string[] getImpact(string nodeId) @system
    {
        return index.getTransitiveDependents(nodeId);
    }
    
    /// Get minimal rebuild set for changed files
    string[] getMinimalRebuild(string[] changedNodeIds) @system
    {
        bool[string] toRebuild;
        
        foreach (nodeId; changedNodeIds)
        {
            toRebuild[nodeId] = true;
            foreach (dep; index.getTransitiveDependents(nodeId))
                toRebuild[dep] = true;
        }
        
        return toRebuild.keys.array;
    }
    
    /// Find bottlenecks (nodes with most dependents)
    BottleneckInfo[] findBottlenecks(size_t limit = 10) @system
    {
        auto nodes = index.listNodes();
        
        BottleneckInfo[] bottlenecks;
        bottlenecks.reserve(nodes.length);
        
        foreach (nodeId; nodes)
        {
            auto dependents = index.getTransitiveDependents(nodeId);
            if (dependents.length > 0)
            {
                auto nodeResult = index.getNode(nodeId);
                bottlenecks ~= BottleneckInfo(
                    nodeId,
                    dependents.length,
                    nodeResult.isOk ? nodeResult.unwrap().buildDuration : 0
                );
            }
        }
        
        // Sort by impact (dependents count * build time)
        bottlenecks.sort!((a, b) => a.impact > b.impact);
        
        return bottlenecks.length > limit ? bottlenecks[0 .. limit] : bottlenecks;
    }
    
    /// Find parallel build opportunities at current state
    ParallelInfo getParallelOpportunities() @system
    {
        auto ready = getReadyNodes();
        auto stats = index.getStats();
        
        return ParallelInfo(
            ready.length,
            stats.totalNodes,
            ready.length > 0 ? cast(float)ready.length / stats.totalNodes : 0
        );
    }
    
    /// Get failed nodes with their error info
    FailedNodeInfo[] getFailedNodes() @system
    {
        auto failed = index.queryByStatus(BuildStatus.Failed);
        
        FailedNodeInfo[] results;
        results.reserve(failed.length);
        
        foreach (nodeId; failed)
        {
            auto nodeResult = index.getNode(nodeId);
            if (nodeResult.isOk)
            {
                auto node = nodeResult.unwrap();
                results ~= FailedNodeInfo(
                    nodeId,
                    node.lastBuild,
                    index.getDependents(nodeId).length
                );
            }
        }
        
        return results;
    }
    
    /// Check if path exists between two nodes
    bool hasPath(string fromId, string toId) @system
    {
        auto deps = index.getTransitiveDeps(fromId);
        foreach (dep; deps)
            if (dep == toId) return true;
        return false;
    }
    
    /// Get nodes by type
    string[] getNodesByType(string targetType) @system
    {
        // Query via index - returns nodes matching type
        auto allNodes = index.listNodes();
        
        string[] results;
        foreach (nodeId; allNodes)
        {
            auto nodeResult = index.getNode(nodeId);
            if (nodeResult.isOk && nodeResult.unwrap().targetType == targetType)
                results ~= nodeId;
        }
        
        return results;
    }
    
    /// Get dependency depth histogram
    DepthHistogram getDepthHistogram() @system
    {
        auto stats = index.getStats();
        
        size_t[] counts;
        counts.length = stats.maxDepth + 1;
        
        foreach (nodeId; index.listNodes())
        {
            auto nodeResult = index.getNode(nodeId);
            if (nodeResult.isOk)
            {
                auto depth = nodeResult.unwrap().depth;
                if (depth >= 0 && depth < counts.length)
                    counts[depth]++;
            }
        }
        
        return DepthHistogram(counts, stats.maxDepth);
    }
}

/// Bottleneck analysis result
struct BottleneckInfo
{
    string nodeId;
    size_t dependentCount;
    long buildDuration;
    
    /// Impact score (dependents * build time)
    @property long impact() const pure @safe
        => dependentCount * (buildDuration > 0 ? buildDuration : 1);
}

/// Parallel build opportunity info
struct ParallelInfo
{
    size_t readyCount;
    long totalNodes;
    float parallelism;
}

/// Failed node info
struct FailedNodeInfo
{
    string nodeId;
    import std.datetime : SysTime;
    SysTime lastAttempt;
    size_t blockedCount;  // How many nodes are blocked by this failure
}

/// Depth histogram for graph analysis
struct DepthHistogram
{
    size_t[] countsByDepth;
    int maxDepth;
    
    /// Get count at specific depth
    size_t at(int depth) const pure @safe
        => depth >= 0 && depth < countsByDepth.length ? countsByDepth[depth] : 0;
    
    /// Get max parallelism (max nodes at any depth level)
    size_t maxParallelism() const pure @safe
    {
        size_t max = 0;
        foreach (c; countsByDepth)
            if (c > max) max = c;
        return max;
    }
}

