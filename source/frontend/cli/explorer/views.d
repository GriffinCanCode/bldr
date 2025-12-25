module frontend.cli.explorer.views;

import std.algorithm : min, max, sort, filter, map;
import std.array : array, appender;
import std.conv : to;
import std.format : format;
import frontend.cli.control.terminal;
import engine.graph.persistence.index;
import engine.graph.persistence.queries;
import engine.graph.core.graph : BuildStatus;

/// View manager coordinates different visualization modes
final class ViewManager
{
    private GraphIndex graphIndex;
    private GraphQuery graphQuery;
    private Capabilities caps;
    
    this(GraphIndex index, Capabilities caps) @system
    {
        this.graphIndex = index;
        this.graphQuery = GraphQuery(index);
        this.caps = caps;
    }
    
    /// Build rebuild reason explanation for a node
    RebuildReason[] getRebuildReasons(string nodeId) @system
    {
        RebuildReason[] reasons;
        
        auto nodeResult = graphIndex.getNode(nodeId);
        if (nodeResult.isErr) return reasons;
        
        auto node = nodeResult.unwrap();
        
        // Check status-based reasons
        if (node.status == BuildStatus.Pending)
        {
            // Check if any dependency changed
            auto deps = graphIndex.getDependencies(nodeId);
            foreach (depId; deps)
            {
                auto depResult = graphIndex.getNode(depId);
                if (depResult.isOk)
                {
                    auto dep = depResult.unwrap();
                    if (dep.status == BuildStatus.Pending || dep.status == BuildStatus.Building)
                    {
                        reasons ~= RebuildReason(
                            RebuildCause.DependencyChanged,
                            format("Dependency '%s' is %s", depId, statusStr(dep.status)),
                            depId
                        );
                    }
                }
            }
            
            // If no dependency reasons, might be source change
            if (reasons.length == 0)
                reasons ~= RebuildReason(
                    RebuildCause.SourceChanged,
                    "Source files or inputs changed",
                    nodeId
                );
        }
        else if (node.status == BuildStatus.Failed)
        {
            reasons ~= RebuildReason(
                RebuildCause.PreviousFailed,
                "Previous build failed",
                nodeId
            );
        }
        
        return reasons;
    }
    
    /// Get depth histogram for visualization
    DepthVisualization getDepthVisualization() @system
    {
        auto histogram = graphQuery.getDepthHistogram();
        auto stats = graphIndex.getStats();
        
        DepthVisualization viz;
        viz.maxDepth = histogram.maxDepth;
        viz.maxWidth = histogram.maxParallelism();
        viz.levels.reserve(histogram.maxDepth + 1);
        
        foreach (d; 0 .. histogram.maxDepth + 1)
        {
            viz.levels ~= DepthLevel(d, histogram.at(d));
        }
        
        return viz;
    }
    
    /// Get parallelism opportunities at each depth level
    ParallelismOpportunity[] getParallelismMap() @system
    {
        auto histogram = graphQuery.getDepthHistogram();
        
        ParallelismOpportunity[] opportunities;
        opportunities.reserve(histogram.maxDepth + 1);
        
        foreach (d; 0 .. histogram.maxDepth + 1)
        {
            auto count = histogram.at(d);
            opportunities ~= ParallelismOpportunity(
                d,
                count,
                count > 1 ? "Can parallelize " ~ count.to!string ~ " targets" : "Sequential"
            );
        }
        
        return opportunities;
    }
    
    /// Get summary statistics for header display
    GraphSummary getSummary() @system
    {
        auto stats = graphIndex.getStats();
        auto criticalPath = graphIndex.getCriticalPath();
        
        GraphSummary summary;
        summary.totalNodes = stats.totalNodes;
        summary.totalEdges = stats.totalEdges;
        summary.maxDepth = stats.maxDepth;
        summary.criticalPathLength = criticalPath.length;
        summary.pendingCount = stats.pendingNodes;
        summary.successCount = stats.successNodes;
        summary.failedCount = stats.failedNodes;
        summary.cachedCount = stats.cachedNodes;
        summary.cacheRate = stats.cacheRate();
        
        return summary;
    }
    
    /// Get node details with full context
    NodeDetails getNodeDetails(string nodeId) @system
    {
        NodeDetails details;
        details.nodeId = nodeId;
        
        auto nodeResult = graphIndex.getNode(nodeId);
        if (nodeResult.isErr)
        {
            details.exists = false;
            return details;
        }
        
        auto node = nodeResult.unwrap();
        details.exists = true;
        details.targetName = node.targetName;
        details.targetType = node.targetType;
        details.status = node.status;
        details.depth = node.depth;
        details.hash = node.hash;
        details.outputPath = node.outputPath;
        details.buildDuration = node.buildDuration;
        details.lastBuild = node.lastBuild;
        
        details.dependencies = graphIndex.getDependencies(nodeId);
        details.dependents = graphIndex.getDependents(nodeId);
        details.transitiveDeps = graphIndex.getTransitiveDeps(nodeId);
        details.transitiveDependents = graphIndex.getTransitiveDependents(nodeId);
        
        details.rebuildReasons = getRebuildReasons(nodeId);
        
        return details;
    }
}

/// Reason for rebuild
enum RebuildCause
{
    SourceChanged,      /// Source file contents changed
    DependencyChanged,  /// A dependency was modified
    OutputMissing,      /// Output file doesn't exist
    HashMismatch,       /// Content hash doesn't match
    ConfigChanged,      /// Build configuration changed  
    ForcedRebuild,      /// User requested rebuild
    PreviousFailed      /// Previous build attempt failed
}

/// Detailed rebuild reason
struct RebuildReason
{
    RebuildCause cause;
    string explanation;
    string relatedNode;
}

/// Depth level visualization data
struct DepthLevel
{
    int depth;
    size_t nodeCount;
}

/// Full depth visualization
struct DepthVisualization
{
    int maxDepth;
    size_t maxWidth;
    DepthLevel[] levels;
}

/// Parallelism opportunity at a depth level
struct ParallelismOpportunity
{
    int depth;
    size_t availableParallelism;
    string description;
}

/// Summary statistics
struct GraphSummary
{
    long totalNodes;
    long totalEdges;
    int maxDepth;
    size_t criticalPathLength;
    long pendingCount;
    long successCount;
    long failedCount;
    long cachedCount;
    float cacheRate;
}

/// Detailed node information
struct NodeDetails
{
    string nodeId;
    bool exists;
    string targetName;
    string targetType;
    BuildStatus status;
    int depth;
    string hash;
    string outputPath;
    long buildDuration;
    import std.datetime : SysTime;
    SysTime lastBuild;
    
    string[] dependencies;
    string[] dependents;
    string[] transitiveDeps;
    string[] transitiveDependents;
    
    RebuildReason[] rebuildReasons;
}

private string statusStr(BuildStatus s) pure @safe
{
    final switch (s)
    {
        case BuildStatus.Pending: return "pending";
        case BuildStatus.Building: return "building";
        case BuildStatus.Success: return "success";
        case BuildStatus.Failed: return "failed";
        case BuildStatus.Cached: return "cached";
    }
}

