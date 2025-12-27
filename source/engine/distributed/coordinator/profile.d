module engine.distributed.coordinator.profile;

import std.algorithm : map, filter, max, sort, sum;
import std.array : array, assocArray;
import std.datetime : Duration, msecs;
import std.conv : to;
import std.typecons : Tuple, tuple;
import core.sync.mutex : Mutex;
import engine.graph : BuildGraph, BuildNode;
import engine.economics.estimator : CostEstimator, ExecutionHistory, BuildEstimate;
import engine.distributed.protocol.protocol : ActionId, ActionRequest, Priority;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.errors;
import infrastructure.utils.logging;
import Concurrency = infrastructure.utils.concurrency.priority;

/// Profile data for a single action
struct ActionProfile
{
    size_t estimatedCostMs;     // Estimated execution time (ms)
    size_t criticalPathCost;    // Cost to reach this + downstream
    size_t dependentCount;      // Number of actions depending on this
    size_t depth;               // Depth in dependency graph
    float cacheHitProbability;  // Likelihood of cache hit
    
    /// Calculate scheduling priority score
    /// Higher score = schedule earlier
    size_t schedulingScore() const pure @safe nothrow @nogc
    {
        // Weight factors for priority:
        // - Critical path cost dominates (schedule long chains early)
        // - Dependent count rewards unblocking parallelism
        // - Depth penalty to favor breadth-first for parallelism
        enum CRITICAL_PATH_WEIGHT = 100;
        enum DEPENDENT_WEIGHT = 10;
        enum DEPTH_PENALTY = 1;
        
        return criticalPathCost * CRITICAL_PATH_WEIGHT +
               dependentCount * DEPENDENT_WEIGHT -
               depth * DEPTH_PENALTY;
    }
}

/// Profile-guided action scheduler
/// Uses economic estimator data to inform critical-path scheduling
/// Schedules expensive actions early to maximize parallelism
final class ProfileGuidedScheduler
{
    private CostEstimator estimator;
    private BuildGraph graph;
    private Mutex mutex;
    
    // Cached profile data
    private ActionProfile[string] profiles;
    private size_t[string] criticalPathCosts;
    private bool profilesComputed;

    this(CostEstimator estimator, BuildGraph graph) @trusted
    {
        this.estimator = estimator;
        this.graph = graph;
        this.mutex = new Mutex();
        this.profilesComputed = false;
    }
    
    /// Compute profiles for all actions in graph
    /// Call before scheduling to enable profile-guided optimization
    void computeProfiles() @trusted
    {
        synchronized (mutex)
        {
            if (profilesComputed) return;
            
            // 1. Compute critical path costs using economic estimates
            criticalPathCosts = computeCriticalPathCosts();
            
            // 2. Build profile for each node
            foreach (key, node; graph.nodes)
            {
                profiles[key] = buildProfile(node, key);
            }
            
            profilesComputed = true;
            structuredLog.info("computed_").field("detail", "Computed " ~ profiles.length.to!string ~ " action profiles for scheduling").emit();
        }
    }
    
    /// Get profile for an action
    /// Returns null if not found
    const(ActionProfile)* getProfile(string targetId) @trusted
    {
        synchronized (mutex)
        {
            if (auto p = targetId in profiles)
                return p;
            return null;
        }
    }
    
    /// Create PriorityTask with profile-guided scheduling data
    Concurrency.PriorityTask!ActionId createProfiledTask(
        ActionId actionId,
        TargetId targetId,
        Priority basePriority
    ) @trusted
    {
        synchronized (mutex)
        {
            auto key = targetId.toString();
            size_t cost = 0, depth = 0, dependents = 0;
            
            if (auto profile = key in profiles)
            {
                cost = profile.criticalPathCost;
                depth = profile.depth;
                dependents = profile.dependentCount;
            }
            
            return new Concurrency.PriorityTask!ActionId(
                actionId,
                toConcurrencyPriority(basePriority),
                cost,
                depth,
                dependents
            );
        }
    }
    
    /// Get scheduling order for ready actions (most critical first)
    ActionId[] prioritizeReadyActions(ActionId[] readyActions, TargetId delegate(ActionId) @trusted getTarget) @trusted
    {
        synchronized (mutex)
        {
            // Score each action
            auto scored = readyActions.map!(id => tuple(id, getSchedulingScore(id, getTarget(id)))).array;
            
            // Sort by score descending (highest priority first)
            scored.sort!((a, b) => a[1] > b[1]);
            
            return scored.map!(t => t[0]).array;
        }
    }
    
    /// Get statistics about profile distribution
    ProfileStats getStats() @trusted
    {
        synchronized (mutex)
        {
            ProfileStats stats;
            if (profiles.length == 0) return stats;
            
            foreach (profile; profiles.values)
            {
                stats.totalActions++;
                stats.totalCriticalPathCost += profile.criticalPathCost;
                stats.maxCriticalPathCost = max(stats.maxCriticalPathCost, profile.criticalPathCost);
                stats.totalDependents += profile.dependentCount;
            }
            
            stats.avgCriticalPathCost = stats.totalCriticalPathCost / stats.totalActions;
            stats.avgDependents = stats.totalDependents / stats.totalActions;
            
            return stats;
        }
    }
    
private:
    /// Compute critical path costs for all nodes
    /// Critical path = longest path from node to any leaf (weighted by estimated cost)
    size_t[string] computeCriticalPathCosts() @trusted
    {
        size_t[string] costs;
        bool[string] visited;
        
        // Recursive DFS to compute critical path
        size_t visit(BuildNode node) @trusted
        {
            auto key = node.id.toString();
            if (key in visited)
                return costs.get(key, 0);
            
            visited[key] = true;
            
            // Get estimated cost for this node
            size_t nodeCost = estimateNodeCostMs(node);
            
            // Find max cost among dependents (downstream nodes that depend on us)
            size_t maxDownstreamCost = 0;
            foreach (dependentId; node.dependentIds)
            {
                auto depKey = dependentId.toString();
                if (depKey in graph.nodes)
                {
                    auto dependentCost = visit(graph.nodes[depKey]);
                    maxDownstreamCost = max(maxDownstreamCost, dependentCost);
                }
            }
            
            // Critical path cost = own cost + max downstream path
            auto totalCost = nodeCost + maxDownstreamCost;
            costs[key] = totalCost;
            return totalCost;
        }
        
        // Visit all nodes (handles disconnected components)
        foreach (node; graph.nodes.values)
            visit(node);
        
        return costs;
    }
    
    /// Estimate node execution cost in milliseconds
    size_t estimateNodeCostMs(BuildNode node) @trusted
    {
        if (estimator is null)
        {
            // Fallback: use depth-based heuristic
            return 1000 + node.dependencyIds.length * 100;
        }
        
        auto result = estimator.estimateNode(node);
        if (result.isErr)
            return 1000; // Default 1 second
        
        return result.unwrap().duration.total!"msecs";
    }
    
    /// Build profile for a node
    ActionProfile buildProfile(BuildNode node, string key) @trusted
    {
        ActionProfile profile;
        
        // Get critical path cost
        profile.criticalPathCost = criticalPathCosts.get(key, 0);
        
        // Count dependents
        profile.dependentCount = node.dependentIds.length;
        
        // Get depth
        profile.depth = node.depth(graph);
        
        // Estimate execution time
        profile.estimatedCostMs = estimateNodeCostMs(node);
        
        // Estimate cache hit probability
        profile.cacheHitProbability = estimator !is null 
            ? estimator.estimateCacheHitProbabilityForNode(node)
            : 0.0f;
        
        return profile;
    }
    
    /// Get scheduling score for an action
    size_t getSchedulingScore(ActionId actionId, TargetId targetId) @trusted
    {
        auto key = targetId.toString();
        if (auto profile = key in profiles)
            return profile.schedulingScore();
        return 0;
    }
    
    Concurrency.Priority toConcurrencyPriority(Priority p) pure nothrow @nogc
    {
        final switch (p)
        {
            case Priority.Low: return Concurrency.Priority.Low;
            case Priority.Normal: return Concurrency.Priority.Normal;
            case Priority.High: return Concurrency.Priority.High;
            case Priority.Critical: return Concurrency.Priority.Critical;
        }
    }
}

/// Profile statistics
struct ProfileStats
{
    size_t totalActions;
    size_t totalCriticalPathCost;
    size_t maxCriticalPathCost;
    size_t avgCriticalPathCost;
    size_t totalDependents;
    size_t avgDependents;
    
    string format() const @safe
    {
        import std.format : format;
        return format(
            "Profile Stats:\n" ~
            "  Actions: %d\n" ~
            "  Critical Path (max): %dms\n" ~
            "  Critical Path (avg): %dms\n" ~
            "  Avg Dependents: %d",
            totalActions,
            maxCriticalPathCost,
            avgCriticalPathCost,
            avgDependents
        );
    }
}

/// Create profile-guided scheduler from execution history
ProfileGuidedScheduler createProfiledScheduler(BuildGraph graph, ExecutionHistory history) @trusted
{
    auto estimator = new CostEstimator(history);
    auto scheduler = new ProfileGuidedScheduler(estimator, graph);
    scheduler.computeProfiles();
    return scheduler;
}

/// Unit tests
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m distributed.coordinator.profile - ActionProfile scoring");
    
    // Test profile scoring prioritizes critical path
    ActionProfile p1 = ActionProfile(1000, 5000, 3, 1, 0.0f);
    ActionProfile p2 = ActionProfile(500, 10000, 1, 2, 0.0f);
    
    // p2 has higher critical path cost, should have higher score
    assert(p2.schedulingScore() > p1.schedulingScore(), "Higher critical path should score higher");
    
    writeln("\x1b[32m  ✓ Profile scoring\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m distributed.coordinator.profile - Dependent count influence");
    
    // Test that more dependents increases priority
    ActionProfile p1 = ActionProfile(1000, 5000, 1, 1, 0.0f);
    ActionProfile p2 = ActionProfile(1000, 5000, 10, 1, 0.0f);
    
    assert(p2.schedulingScore() > p1.schedulingScore(), "More dependents should score higher");
    
    writeln("\x1b[32m  ✓ Dependent count influence\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m distributed.coordinator.profile - Depth penalty");
    
    // Test that deeper nodes get penalized (to favor parallelism)
    ActionProfile p1 = ActionProfile(1000, 5000, 3, 1, 0.0f);
    ActionProfile p2 = ActionProfile(1000, 5000, 3, 10, 0.0f);
    
    assert(p1.schedulingScore() > p2.schedulingScore(), "Shallower depth should score higher");
    
    writeln("\x1b[32m  ✓ Depth penalty\x1b[0m");
}

