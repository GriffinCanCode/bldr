module engine.graph.dynamic.discovery;

import std.array;
import std.algorithm;
import std.conv;
import core.sync.mutex;
import infrastructure.config.schema.schema;
import engine.graph.core.graph;
import infrastructure.errors;

/// Discovery metadata emitted by actions during execution
/// Allows actions to declare new dependencies or targets discovered at runtime
/// Example: protobuf compiler discovers which source files it generates
struct DiscoveryMetadata
{
    /// Target that performed the discovery
    TargetId originTarget;
    
    /// Newly discovered output files
    string[] discoveredOutputs;
    
    /// Newly discovered dependencies (targets that should be built after this)
    TargetId[] discoveredDependents;
    
    /// Optional: New targets to create and build
    Target[] newTargets;
    
    /// Metadata about what was discovered
    string[string] metadata;
}

/// Discovery result from an action execution
/// Contains both the build result and any discovered dependencies
struct DiscoveryResult
{
    bool success;
    bool hasDiscovery;
    DiscoveryMetadata discovery;
    string error;
}

/// Discovery phase status for a node
enum DiscoveryStatus
{
    None,           // No discovery expected
    Pending,        // Discovery action not yet run
    Discovered,     // Discovery complete, metadata available
    Applied         // Discovery applied to graph
}

/// Dynamic graph extension - manages runtime graph mutations
/// Thread-safe operations for adding nodes and edges during execution
final class GraphExtension
{
    private BuildGraph graph;
    private core.sync.mutex.Mutex mutex;
    private DiscoveryMetadata[] pendingDiscoveries;
    private bool[string] discoveredTargets; // Track which targets came from discovery
    
    this(BuildGraph graph) @trusted
    {
        this.graph = graph;
        this.mutex = new core.sync.mutex.Mutex();
    }
    
    /// Record discovery metadata for processing
    void recordDiscovery(DiscoveryMetadata discovery) @trusted
    {
        synchronized (mutex)
        {
            pendingDiscoveries ~= discovery;
        }
    }
    
    /// Apply pending discoveries to graph
    /// Returns newly added nodes that need to be scheduled
    BuildResult!(BuildNode[]) applyDiscoveries() @system
    {
        synchronized (mutex)
        {
            if (pendingDiscoveries.empty)
                return BuildResult!(BuildNode[]).ok([]);
            
            BuildNode[] newNodes;
            
            foreach (discovery; pendingDiscoveries)
            {
                // Apply each discovery
                auto result = applyDiscovery(discovery);
                if (result.isErr)
                    return BuildResult!(BuildNode[]).err(result.unwrapErr());
                
                newNodes ~= result.unwrap();
            }
            
            // Clear processed discoveries
            pendingDiscoveries = [];
            
            return BuildResult!(BuildNode[]).ok(newNodes);
        }
    }
    
    /// Apply a single discovery to the graph
    private BuildResult!(BuildNode[]) applyDiscovery(DiscoveryMetadata discovery) @system
    {
        BuildNode[] newNodes;
        
        // 1. Add new targets to graph
        foreach (target; discovery.newTargets)
        {
            auto targetKey = target.id.toString();
            
            // Skip if already exists
            if (targetKey in graph.nodes)
                continue;
            
            auto addResult = graph.addTarget(target);
            if (addResult.isErr)
                return BuildResult!(BuildNode[]).err(addResult.unwrapErr());
            
            // Track as discovered
            discoveredTargets[targetKey] = true;
            
            // Get the newly added node
            if (targetKey in graph.nodes)
                newNodes ~= graph.nodes[targetKey];
        }
        
        // 2. Add dependencies from origin target to new dependents
        auto originKey = discovery.originTarget.toString();
        if (originKey in graph.nodes)
        {
            foreach (dependentId; discovery.discoveredDependents)
            {
                auto dependentKey = dependentId.toString();
                
                // Add edge: dependent depends on origin
                // This means origin must build before dependent
                if (dependentKey in graph.nodes)
                {
                    auto addDepResult = graph.addDependency(dependentKey, originKey);
                    if (addDepResult.isErr)
                    {
                        auto error = addDepResult.unwrapErr();
                        
                        // Allow duplicate edge errors (idempotent)
                        if (error.code != Graph.Invalid)
                            return BuildResult!(BuildNode[]).err(error);
                    }
                }
            }
        }
        
        return BuildResult!(BuildNode[]).ok(newNodes);
    }
    
    /// Check if a target was discovered dynamically
    bool isDiscovered(TargetId id) const @trusted
    {
        synchronized (cast(core.sync.mutex.Mutex)mutex)
        {
            return (id.toString() in discoveredTargets) !is null;
        }
    }
    
    /// Get statistics about discoveries
    struct DiscoveryStats
    {
        size_t totalDiscoveries;
        size_t targetsDiscovered;
        size_t dependenciesAdded;
    }
    
    DiscoveryStats getStats() const @trusted
    {
        synchronized (cast(core.sync.mutex.Mutex)mutex)
        {
            DiscoveryStats stats;
            stats.totalDiscoveries = pendingDiscoveries.length;
            stats.targetsDiscovered = discoveredTargets.length;
            return stats;
        }
    }
}

/// Interface for actions that support discovery
interface DiscoverableAction
{
    /// Execute the action and return discovery metadata
    /// This runs before dependent actions to discover new dependencies
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config);
}

/// Helper to create discovery metadata
struct DiscoveryBuilder
{
    private DiscoveryMetadata metadata;
    
    /// Start building discovery for a target
    static DiscoveryBuilder forTarget(TargetId target) pure nothrow @nogc
    {
        DiscoveryBuilder builder;
        builder.metadata.originTarget = target;
        return builder;
    }
    
    /// Add discovered output files
    DiscoveryBuilder addOutputs(string[] outputs) pure nothrow
    {
        metadata.discoveredOutputs ~= outputs;
        return this;
    }
    
    /// Add discovered dependent targets
    DiscoveryBuilder addDependents(TargetId[] deps) pure nothrow
    {
        metadata.discoveredDependents ~= deps;
        return this;
    }
    
    /// Add new targets to create
    DiscoveryBuilder addTargets(Target[] targets) pure nothrow
    {
        metadata.newTargets ~= targets;
        return this;
    }
    
    /// Add metadata
    DiscoveryBuilder withMetadata(string key, string value) pure
    {
        metadata.metadata[key] = value;
        return this;
    }
    
    /// Build the discovery metadata
    DiscoveryMetadata build() pure nothrow @nogc
    {
        return metadata;
    }
}


