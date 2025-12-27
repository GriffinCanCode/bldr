module frontend.cli.watch.discovery;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import engine.graph;
import infrastructure.config.schema.schema;
import infrastructure.utils.logging;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;

/// Re-discovery statistics
struct RediscoveryStats
{
    size_t rediscoveredTargets;
    size_t newNodes;
    size_t rebuiltTargets;
}

/// Watch mode discovery tracker
/// Tracks file changes that may trigger discovery re-execution
final class WatchDiscoveryTracker
{
    private DynamicBuildGraph dynamicGraph;
    private string[string] discoveredFileOrigins; // file -> originTarget
    private string[][string] targetInputs;  // targetId -> input files
    
    this(DynamicBuildGraph dynamicGraph) @system
    {
        this.dynamicGraph = dynamicGraph;
    }
    
    /// Register a discovery result for watching
    void registerDiscovery(DiscoveryMetadata discovery) @system
    {
        auto originKey = discovery.originTarget.toString();
        
        // Track which target discovered which files
        foreach (output; discovery.discoveredOutputs)
        {
            discoveredFileOrigins[output] = originKey;
        }
        
        structuredLog.debug_("registered_discovery_").field("detail", "Registered discovery: " ~ originKey ~ " -> " ~ 
                       discovery.discoveredOutputs.length.to!string ~ " files").emit();
    }
    
    /// Check if a changed file requires re-discovery
    /// Returns the origin target that needs to re-run discovery
    Result!(string[], string) checkForRediscovery(string[] changedFiles) @system
    {
        bool[string] targetsNeedingRediscovery;
        
        foreach (file; changedFiles)
        {
            // Check if this is an input to a discoverable target
            foreach (targetId, inputs; targetInputs)
            {
                if (inputs.canFind(file))
                {
                    if (dynamicGraph.isDiscoverable(TargetId(targetId)))
                    {
                        targetsNeedingRediscovery[targetId] = true;
                        structuredLog.info("file_change_triggers_rediscovery_").field("detail", "File change triggers re-discovery: " ~ file ~ " -> " ~ targetId).emit();
                    }
                }
            }
            
            // Check if this is a discovered file (might need to invalidate)
            if (file in discoveredFileOrigins)
            {
                auto originTarget = discoveredFileOrigins[file];
                structuredLog.warning("discovered_file_changed_").field("detail", "Discovered file changed: " ~ file ~ 
                             " (originally from " ~ originTarget ~ ")").emit();
                // This is unusual - user modified a generated file
                // We should re-run discovery to regenerate
                targetsNeedingRediscovery[originTarget] = true;
            }
        }
        
        return Result!(string[], string).ok(targetsNeedingRediscovery.keys);
    }
    
    /// Track input files for a target
    void trackTargetInputs(string targetId, string[] inputs) @system
    {
        targetInputs[targetId] = inputs;
    }
    
    /// Clear all tracking data
    void clear() @system
    {
        discoveredFileOrigins.clear();
        targetInputs.clear();
    }
    
    /// Get statistics
    struct Stats
    {
        size_t trackedFiles;
        size_t trackedTargets;
    }
    
    Stats getStats() const @system
    {
        Stats stats;
        stats.trackedFiles = discoveredFileOrigins.length;
        stats.trackedTargets = targetInputs.length;
        return stats;
    }
}

/// Watch mode with discovery support
/// Extends watch mode to handle dynamic dependency changes
class WatchModeWithDiscovery
{
    private DynamicBuildGraph dynamicGraph;
    private WatchDiscoveryTracker tracker;
    private BuildGraph baseGraph;
    
    this(BuildGraph baseGraph) @system
    {
        this.baseGraph = baseGraph;
        this.dynamicGraph = new DynamicBuildGraph(baseGraph);
        this.tracker = new WatchDiscoveryTracker(dynamicGraph);
        
        // Mark discoverable targets
        import engine.runtime.core.engine.discovery;
        DiscoveryMarker.markCodeGenTargets(dynamicGraph);
    }
    
    /// Handle file changes in watch mode
    void onFilesChanged(string[] changedFiles) @system
    {
        structuredLog.info("files_changed_").field("detail", "Files changed: " ~ changedFiles.length.to!string).emit();
        
        // Check if any changes require re-discovery
        auto rediscoveryResult = tracker.checkForRediscovery(changedFiles);
        if (rediscoveryResult.isErr)
        {
            structuredLog.error("failed_to_check_for_rediscovery").emit();
            structuredLog.error("log_event").field("message", rediscoveryResult.unwrapErr()).emit();
            return;
        }
        
        auto targetsNeedingRediscovery = rediscoveryResult.unwrap();
        
        if (!targetsNeedingRediscovery.empty)
        {
            structuredLog.info("rediscovery_needed_for_").field("detail", "Re-discovery needed for " ~ targetsNeedingRediscovery.length.to!string ~ " targets").emit();
            
            foreach (targetId; targetsNeedingRediscovery)
                structuredLog.info("___").field("detail", "  • " ~ targetId).emit();
            
            // Execute full re-discovery workflow
            auto result = executeRediscovery(targetsNeedingRediscovery);
            if (result.isErr)
            {
                structuredLog.error("rediscovery_failed").emit();
                structuredLog.error("log_event").field("message", result.unwrapErr()).emit();
            }
            else
            {
                auto stats = result.unwrap();
                structuredLog.info("rediscovery_complete_").field("detail", "Re-discovery complete: " ~ 
                             stats.rediscoveredTargets.to!string ~ " targets, " ~
                             stats.newNodes.to!string ~ " new nodes, " ~
                             stats.rebuiltTargets.to!string ~ " targets rebuilt").emit();
            }
        }
    }
    
    /// Execute re-discovery workflow for changed targets
    private Result!(RediscoveryStats, string) executeRediscovery(string[] targetIds) @system
    {
        import engine.runtime.core.engine.discovery;
        import engine.runtime.services;
        import languages.base.base;
        
        RediscoveryStats stats;
        
        // 1. Clear old discoveries for these targets
        clearOldDiscoveries(targetIds);
        stats.rediscoveredTargets = targetIds.length;
        
        // 2. Re-run discovery phase for affected targets
        BuildNode[] nodesToRediscover;
        foreach (targetId; targetIds)
        {
            if (targetId in dynamicGraph.graph.nodes)
                nodesToRediscover ~= dynamicGraph.graph.nodes[targetId];
        }
        
        if (nodesToRediscover.empty)
            return Result!(RediscoveryStats, string).ok(stats);
        
        // 3. Execute discovery on each node
        auto discoveryResult = runDiscoveryPhase(nodesToRediscover);
        if (discoveryResult.isErr)
            return Result!(RediscoveryStats, string).err(discoveryResult.unwrapErr());
        
        auto newNodes = discoveryResult.unwrap();
        stats.newNodes = newNodes.length;
        
        // 4. Update graph with new discoveries and rebuild affected targets
        auto rebuildResult = rebuildAffectedTargets(nodesToRediscover, newNodes);
        if (rebuildResult.isErr)
            return Result!(RediscoveryStats, string).err(rebuildResult.unwrapErr());
        
        stats.rebuiltTargets = rebuildResult.unwrap();
        
        return Result!(RediscoveryStats, string).ok(stats);
    }
    
    /// Clear old discoveries for targets needing re-discovery
    private void clearOldDiscoveries(string[] targetIds) @system
    {
        foreach (targetId; targetIds)
        {
            // Remove tracked discovered files from this target
            string[] filesToRemove;
            foreach (file, origin; tracker.discoveredFileOrigins)
            {
                if (origin == targetId)
                    filesToRemove ~= file;
            }
            
            foreach (file; filesToRemove)
                tracker.discoveredFileOrigins.remove(file);
            
            structuredLog.debug_("cleared_old_discoveries_for_").field("detail", "Cleared old discoveries for " ~ targetId).emit();
        }
    }
    
    /// Run discovery phase on nodes
    private Result!(BuildNode[], string) runDiscoveryPhase(BuildNode[] nodes) @system
    {
        import engine.runtime.core.engine.discovery;
        import engine.runtime.services;
        import languages.base.base;
        
        BuildNode[] newNodes;
        
        foreach (node; nodes)
        {
            // Mark as discoverable if not already
            if (!dynamicGraph.isDiscoverable(node.id))
                dynamicGraph.markDiscoverable(node.id);
            
            // Get language handler
            auto handlers = new HandlerRegistry();
            auto handler = handlers.get(node.target.language);
            if (handler is null)
            {
                structuredLog.warning("no_handler_for_language_").field("detail", "No handler for language: " ~ node.target.language.to!string).emit();
                continue;
            }
            
            // Check if handler supports discovery
            auto discoverableHandler = cast(DiscoverableAction) handler;
            if (discoverableHandler is null)
                continue;
            
            // Execute discovery
            import infrastructure.config.schema.schema : WorkspaceConfig;
            WorkspaceConfig config; // Use default config for now
            auto discoveryResult = discoverableHandler.executeWithDiscovery(node.target, config);
            
            if (discoveryResult.success && discoveryResult.hasDiscovery)
            {
                // Record discovery
                tracker.registerDiscovery(discoveryResult.discovery);
                dynamicGraph.recordDiscovery(discoveryResult.discovery);
                
                structuredLog.info("rediscovered_").field("detail", "Re-discovered " ~ discoveryResult.discovery.discoveredOutputs.length.to!string ~ 
                          " files for " ~ node.idString).emit();
            }
        }
        
        // Apply discoveries to graph
        auto applyResult = dynamicGraph.applyDiscoveries();
        if (applyResult.isErr)
            return Result!(BuildNode[], string).err(applyResult.unwrapErr().message());
        
        newNodes = applyResult.unwrap();
        return Result!(BuildNode[], string).ok(newNodes);
    }
    
    /// Rebuild affected targets after discovery
    private Result!(size_t, string) rebuildAffectedTargets(BuildNode[] originalNodes, BuildNode[] newNodes) @system
    {
        import engine.runtime.services.container.services;
        
        size_t rebuiltCount = 0;
        
        // Reset state for original nodes
        foreach (node; originalNodes)
        {
            // Reset node status to pending for rebuild
            node.status = BuildStatus.Pending;
            rebuiltCount++;
        }
        
        // Initialize new nodes
        foreach (node; newNodes)
        {
            node.initPendingDeps();
            if (node.pendingDeps == 0)
                rebuiltCount++;
        }
        
        // Note: Actual rebuild execution would be triggered by the watch loop
        // This just prepares nodes for rebuild
        structuredLog.info("prepared_").field("detail", "Prepared " ~ rebuiltCount.to!string ~ " targets for rebuild").emit();
        
        return Result!(size_t, string).ok(rebuiltCount);
    }
    
    /// Register a discovery result
    void onDiscoveryComplete(DiscoveryMetadata discovery) @system
    {
        tracker.registerDiscovery(discovery);
        dynamicGraph.recordDiscovery(discovery);
    }
    
    /// Get tracker statistics
    auto getStats() const @system
    {
        return tracker.getStats();
    }
}


