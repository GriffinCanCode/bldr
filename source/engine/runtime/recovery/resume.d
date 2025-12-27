module engine.runtime.recovery.resume;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.range;
import engine.graph;
import engine.runtime.recovery.checkpoint;
import infrastructure.errors : BuildResult, Errors, Cache, BuildError;

/// Resume strategy - determines how to handle checkpoint
enum ResumeStrategy
{
    /// Retry all failed targets
    RetryFailed,
    
    /// Skip failed targets, continue with pending
    SkipFailed,
    
    /// Rebuild everything (ignore checkpoint)
    RebuildAll,
    
    /// Smart resume - analyze what changed
    Smart
}

/// Resume configuration
struct ResumeConfig
{
    ResumeStrategy strategy = ResumeStrategy.Smart;
    bool clearOnSuccess = true;      // Clear checkpoint after successful build
    bool validateDependencies = true; // Re-check if dependencies changed
    Duration maxCheckpointAge = 24.hours;
    
    /// Create config from environment
    static ResumeConfig fromEnvironment() @system
    {
        import std.process : environment;
        
        static immutable ResumeStrategy[string] strategyMap = [
            "retry": ResumeStrategy.RetryFailed,
            "skip": ResumeStrategy.SkipFailed,
            "rebuild": ResumeStrategy.RebuildAll,
            "smart": ResumeStrategy.Smart
        ];
        
        ResumeConfig config;
        if (auto strategy = environment.get("BUILDER_RESUME_STRATEGY"))
            config.strategy = strategyMap.get(strategy, ResumeStrategy.Smart);
        
        return config;
    }
}

/// Resume planner - decides what to rebuild
final class ResumePlanner
{
    private ResumeConfig config;
    
    this(ResumeConfig config = ResumeConfig.init) @system
    {
        this.config = config;
    }
    
    /// Plan resume from checkpoint
    BuildResult!ResumePlan plan(
        const ref Checkpoint checkpoint,
        BuildGraph graph
    ) @system
    {
        // Validate checkpoint
        if (!checkpoint.isValid(graph))
            return BuildResult!ResumePlan.err(Errors.cache("Checkpoint invalid for current graph", Cache.Corrupted).build());
        
        // Check age
        if (Clock.currTime() - checkpoint.timestamp > config.maxCheckpointAge)
            return BuildResult!ResumePlan.err(Errors.cache("Checkpoint too old", Cache.Expired).build());
        
        // Build plan based on strategy
        ResumePlan plan;
        plan.strategy = config.strategy;
        plan.checkpointAge = Clock.currTime() - checkpoint.timestamp;
        
        final switch (config.strategy)
        {
            case ResumeStrategy.RetryFailed:
                planRetryFailed(checkpoint, graph, plan);
                break;
            
            case ResumeStrategy.SkipFailed:
                planSkipFailed(checkpoint, graph, plan);
                break;
            
            case ResumeStrategy.RebuildAll:
                planRebuildAll(graph, plan);
                break;
            
            case ResumeStrategy.Smart:
                planSmart(checkpoint, graph, plan);
                break;
        }
        
        return BuildResult!ResumePlan.ok(plan);
    }
    
    private void planRetryFailed(
        const ref Checkpoint checkpoint,
        BuildGraph graph,
        ref ResumePlan plan
    ) @system
    {
        // Restore successful builds
        checkpoint.mergeWith(graph);
        
        // Retry all failed targets
        foreach (targetId; checkpoint.failedTargetIds)
        {
            if (targetId in graph.nodes)
            {
                auto node = graph.nodes[targetId];
                node.status = BuildStatus.Pending;
                plan.targetsToRetry ~= targetId;
            }
        }
        
        // Mark dependent targets as pending
        markDependentsPending(graph, checkpoint.failedTargetIds, plan);
        
        plan.targetsToSkip = checkpoint.nodeStates.keys
            .filter!(id => checkpoint.nodeStates[id] == BuildStatus.Success)
            .array;
    }
    
    private void planSkipFailed(
        const ref Checkpoint checkpoint,
        BuildGraph graph,
        ref ResumePlan plan
    ) @system
    {
        checkpoint.mergeWith(graph);
        
        plan.targetsToSkip = checkpoint.failedTargetIds.filter!(id => id in graph.nodes).array ~
                             checkpoint.nodeStates.keys.filter!(id => checkpoint.nodeStates[id] == BuildStatus.Success).array;
    }
    
    private void planRebuildAll(BuildGraph graph, ref ResumePlan plan) @system
    {
        // Clear all node states
        foreach (node; graph.nodes.values)
            node.status = BuildStatus.Pending;
        
        plan.message = "Rebuilding all targets (checkpoint ignored)";
    }
    
    private void planSmart(
        const ref Checkpoint checkpoint,
        BuildGraph graph,
        ref ResumePlan plan
    ) @system
    {
        // Restore successful builds
        checkpoint.mergeWith(graph);
        
        if (config.validateDependencies)
        {
            // Check if any dependencies changed
            auto invalidated = findInvalidated(checkpoint, graph);
            
            foreach (targetId; invalidated)
            {
                if (targetId in graph.nodes)
                {
                    auto node = graph.nodes[targetId];
                    node.status = BuildStatus.Pending;
                    plan.targetsToRetry ~= targetId;
                }
            }
        }
        
        // Retry failed targets
        foreach (targetId; checkpoint.failedTargetIds)
        {
            if (targetId in graph.nodes && !canFind(plan.targetsToRetry, targetId))
            {
                auto node = graph.nodes[targetId];
                node.status = BuildStatus.Pending;
                plan.targetsToRetry ~= targetId;
            }
        }
        
        // Mark dependent targets as pending
        markDependentsPending(graph, plan.targetsToRetry, plan);
        
        plan.targetsToSkip = checkpoint.nodeStates.keys
            .filter!((id) {
                auto status = checkpoint.nodeStates[id];
                return (status == BuildStatus.Success || status == BuildStatus.Cached) &&
                       !canFind(plan.targetsToRetry, id);
            })
            .array;
        
        plan.message = "Smart resume: " ~ plan.targetsToRetry.length.to!string ~ 
                       " targets to rebuild, " ~ plan.targetsToSkip.length.to!string ~ " cached";
    }
    
    private string[] findInvalidated(
        const ref Checkpoint checkpoint,
        BuildGraph graph
    ) const @system
    {
        import engine.caching.targets.cache : BuildCache, CacheConfig;
        
        string[] invalidated;
        
        // Use cache to check if sources changed
        auto cache = new BuildCache(".builder-cache", CacheConfig.fromEnvironment());
        
        foreach (targetId, node; graph.nodes)
        {
            // Skip if not in checkpoint
            if (targetId !in checkpoint.nodeStates)
                continue;
            
            // Skip if was failed/pending
            immutable status = checkpoint.nodeStates[targetId];
            if (status != BuildStatus.Success && status != BuildStatus.Cached)
                continue;
            
            // Check cache validity
            auto target = node.target;
            auto deps = node.dependencyIds;  // Already TargetId[]
            
            if (!cache.isCached(targetId, target.sources, deps.map!(d => d.toString()).array))
                invalidated ~= targetId;
        }
        
        return invalidated;
    }
    
    private void markDependentsPending(
        BuildGraph graph,
        const string[] changedTargets,
        ref ResumePlan plan
    ) @system
    {
        import std.range : chain;
        
        bool[string] visited;
        
        void markRecursive(BuildNode node)
        {
            if (node.id.toString() in visited)
                return;
            
            visited[node.id.toString()] = true;
            
            // Mark as pending and add to retry list
            node.status = BuildStatus.Pending;
            plan.targetsToRetry ~= node.id.toString();
            
            // Recursively mark dependents
            foreach (dependentId; node.dependentIds)
            {
                auto depKey = dependentId.toString();
                if (depKey in graph.nodes)
                    markRecursive(graph.nodes[depKey]);
            }
        }
        
        // Start from changed targets
        foreach (targetId; changedTargets)
        {
            if (targetId !in graph.nodes)
                continue;
            
            auto node = graph.nodes[targetId];
            foreach (dependentId; node.dependentIds)
            {
                auto depKey = dependentId.toString();
                if (depKey in graph.nodes)
                    markRecursive(graph.nodes[depKey]);
            }
        }
    }
}

/// Resume plan - output from planner
struct ResumePlan
{
    ResumeStrategy strategy;
    Duration checkpointAge;
    string[] targetsToRetry;
    string[] targetsToSkip;
    string message;
    
    /// Print summary
    void print() const @system
    {
        writeln("\n=== Resume Plan ===");
        writeln("Strategy: ", strategy);
        writeln("Checkpoint age: ", checkpointAge.total!"seconds", " seconds");
        
        if (!targetsToRetry.empty)
        {
            writeln("\nTargets to rebuild (", targetsToRetry.length, "):");
            foreach (target; targetsToRetry.take(10))
                writeln("  - ", target);
            if (targetsToRetry.length > 10)
                writeln("  ... and ", targetsToRetry.length - 10, " more");
        }
        
        if (!targetsToSkip.empty)
        {
            writeln("\nTargets to skip (cached) (", targetsToSkip.length, "):");
            foreach (target; targetsToSkip.take(5))
                writeln("  - ", target);
            if (targetsToSkip.length > 5)
                writeln("  ... and ", targetsToSkip.length - 5, " more");
        }
        
        if (!message.empty)
            writeln("\n", message);
        
        writeln("===================\n");
    }
    
    /// Get estimated time savings
    float estimatedSavings() const pure nothrow @nogc @system
    {
        immutable total = targetsToRetry.length + targetsToSkip.length;
        return total == 0 ? 0.0 : (cast(float)targetsToSkip.length / cast(float)total) * 100.0;
    }
}

