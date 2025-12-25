module engine.runtime.core.engine.discovery;

import std.algorithm;
import std.array;
import std.conv;
import engine.graph;
import infrastructure.config.schema.schema;
import languages.base.base;
import engine.runtime.services;
import infrastructure.utils.logging.logger;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;

/// Discovery-aware executor extension
/// Handles execution of discoverable actions and graph extension
struct DiscoveryExecutor
{
    private DynamicBuildGraph dynamicGraph;
    private IHandlerRegistry handlers;
    private WorkspaceConfig config;
    
    /// Initialize discovery executor
    void initialize(
        DynamicBuildGraph dynamicGraph,
        IHandlerRegistry handlers,
        WorkspaceConfig config
    ) @trusted
    {
        this.dynamicGraph = dynamicGraph;
        this.handlers = handlers;
        this.config = config;
    }
    
    /// Execute a node with discovery support
    /// Returns tuple of (success, cached, hasDiscovery, error)
    auto executeWithDiscovery(BuildNode node) @system
    {
        struct DiscoveryExecResult
        {
            bool success;
            bool cached;
            bool hasDiscovery;
            string error;
        }
        
        DiscoveryExecResult result;
        
        // Check if this node supports discovery
        if (!dynamicGraph.isDiscoverable(node.id))
        {
            // Not discoverable, skip
            return result;
        }
        
        // Get language handler
        auto handler = handlers.get(node.target.language);
        if (handler is null)
        {
            result.error = "No language handler found for: " ~ node.target.language.to!string;
            return result;
        }
        
        // Check if handler supports discovery
        auto discoverableHandler = cast(DiscoverableAction) handler;
        if (discoverableHandler is null)
        {
            // Handler doesn't support discovery, skip
            Logger.debugLog("Handler for " ~ node.target.language.to!string ~ 
                          " does not support discovery");
            return result;
        }
        
        // Execute with discovery
        Logger.info("Executing discovery for " ~ node.idString);
        auto discoveryResult = discoverableHandler.executeWithDiscovery(node.target, config);
        
        result.success = discoveryResult.success;
        result.hasDiscovery = discoveryResult.hasDiscovery;
        result.error = discoveryResult.error;
        
        // Record discovery if available
        if (discoveryResult.hasDiscovery)
        {
            dynamicGraph.recordDiscovery(discoveryResult.discovery);
            Logger.success("Discovery complete for " ~ node.idString);
        }
        
        return result;
    }
    
    /// Apply pending discoveries and return new nodes to schedule
    BuildResult!(BuildNode[]) applyPendingDiscoveries() @system
    {
        if (!dynamicGraph.hasPendingDiscoveries())
            return BuildResult!(BuildNode[]).ok([]);
        
        Logger.info("Applying pending discoveries...");
        return dynamicGraph.applyDiscoveries();
    }
    
    /// Check if there are pending discoveries
    bool hasPendingDiscoveries() const @trusted
    {
        return dynamicGraph.hasPendingDiscoveries();
    }
}

/// Discovery-aware coordinator extension
/// Integrates discovery phase into the build execution loop
struct DiscoveryCoordinator
{
    /// Execute discovery phase for ready nodes
    /// Returns discovered nodes to add to execution queue
    static BuildNode[] executeDiscoveryPhase(
        BuildNode[] nodes,
        ref DiscoveryExecutor discoveryExec,
        IObservabilityService observability
    ) @system
    {
        BuildNode[] discoveredNodes;
        
        // Execute discovery for each node
        foreach (node; nodes)
        {
            auto result = discoveryExec.executeWithDiscovery(node);
            if (!result.success && result.hasDiscovery)
                Logger.error("Discovery failed for " ~ node.idString ~ ": " ~ result.error);
        }
        
        // Apply discoveries and get new nodes
        if (discoveryExec.hasPendingDiscoveries())
        {
            auto applyResult = discoveryExec.applyPendingDiscoveries();
            if (applyResult.isOk)
            {
                discoveredNodes = applyResult.unwrap();
                observability.logInfo("Discovery phase complete", ["discovered_nodes": discoveredNodes.length.to!string]);
            }
            else
            {
                Logger.error("Failed to apply discoveries");
                Logger.error(formatError(applyResult.unwrapErr()));
            }
        }
        
        return discoveredNodes;
    }
    
    /// Integrate discovered nodes into execution flow
    /// Returns nodes that are immediately ready to execute
    static BuildNode[] integrateDiscoveredNodes(
        BuildNode[] discoveredNodes,
        BuildGraph graph
    ) @system
    {
        import std.algorithm : filter;
        import std.array : array;
        
        return discoveredNodes.filter!(n => n.pendingDeps == 0).array;
    }
}

/// Helper to mark targets as discoverable in the graph
struct DiscoveryMarker
{
    /// Mark code generation targets as discoverable
    static void markCodeGenTargets(DynamicBuildGraph dynamicGraph) @system
    {
        auto graph = dynamicGraph.graph;
        
        foreach (node; graph.nodes.values)
        {
            // Mark protobuf targets
            if (node.target.language == TargetLanguage.Protobuf)
            {
                dynamicGraph.markDiscoverable(node.id);
                Logger.debugLog("Marked " ~ node.idString ~ " as discoverable (protobuf)");
            }
            
            // Mark custom targets with code generation
            if (node.target.type == TargetType.Custom)
            {
                // Check for code generation hints in config
                if ("generates" in node.target.langConfig || 
                    "codegen" in node.target.langConfig)
                {
                    dynamicGraph.markDiscoverable(node.id);
                    Logger.debugLog("Marked " ~ node.idString ~ " as discoverable (custom codegen)");
                }
            }
        }
    }
}


