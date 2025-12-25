module engine.graph.persistence.adapter;

import std.datetime : Clock;
import std.conv : to;
import engine.graph.core.graph;
import engine.graph.persistence.index;
import infrastructure.config.schema.schema : Target, TargetId, TargetType;
import infrastructure.errors;

/// Adapter bridging in-memory BuildGraph and SQLite GraphIndex
/// 
/// Provides bidirectional sync:
/// - persist(): BuildGraph → SQLite (save current state)
/// - restore(): SQLite → BuildGraph (load persisted state)
/// - sync(): Incremental updates for changed nodes
/// 
/// Usage:
/// ```d
/// auto index = new GraphIndex();
/// auto adapter = GraphAdapter(index);
/// 
/// // Save graph to SQLite
/// adapter.persist(graph);
/// 
/// // Restore graph from SQLite
/// auto graph = adapter.restore();
/// 
/// // Update single node status
/// adapter.syncStatus(nodeId, BuildStatus.Success, duration);
/// ```
struct GraphAdapter
{
    private GraphIndex index;
    
    this(GraphIndex index) @system { this.index = index; }
    
    /// Persist entire BuildGraph to SQLite
    void persist(BuildGraph graph) @system
    {
        // Clear existing data
        index.clear();
        
        // Persist all nodes
        foreach (key, node; graph.nodes)
        {
            GraphNodeEntry entry;
            entry.nodeId = node.id.toString();
            entry.targetType = node.target.type.to!string;
            entry.targetName = node.target.name;
            entry.outputPath = node.target.outputPath;
            entry.status = node.status;
            entry.hash = node.hash;
            entry.depth = cast(int)node.depth(graph);
            entry.createdAt = Clock.currTime();
            
            index.putNode(entry);
        }
        
        // Persist all edges
        foreach (key, node; graph.nodes)
        {
            auto nodeId = node.id.toString();
            foreach (depId; node.dependencyIds)
                index.addEdge(nodeId, depId.toString());
        }
    }
    
    /// Restore BuildGraph from SQLite
    BuildGraph restore() @system
    {
        auto nodeIds = index.listNodes();
        
        // Create graph with known size for arena allocation
        auto graph = new BuildGraph(ValidationMode.Deferred, nodeIds.length);
        
        // First pass: create all nodes
        foreach (nodeId; nodeIds)
        {
            auto entryResult = index.getNode(nodeId);
            if (entryResult.isErr) continue;
            
            auto entry = entryResult.unwrap();
            
            // Parse target ID
            auto idResult = TargetId.parse(entry.nodeId);
            if (idResult.isErr) continue;
            
            // Create minimal target
            Target target;
            target.name = entry.targetName;
            target.type = entry.targetType.to!TargetType;
            target.outputPath = entry.outputPath;
            
            // Add to graph
            auto node = graph.createNode(idResult.unwrap(), target);
            node.status = entry.status;
            node.hash = entry.hash;
            
            graph.nodes[entry.nodeId] = node;
        }
        
        // Second pass: restore edges
        foreach (nodeId; nodeIds)
        {
            if (nodeId !in graph.nodes) continue;
            
            auto node = graph.nodes[nodeId];
            auto deps = index.getDependencies(nodeId);
            
            foreach (depId; deps)
            {
                auto depIdResult = TargetId.parse(depId);
                if (depIdResult.isOk)
                    node.dependencyIds ~= depIdResult.unwrap();
            }
            
            auto dependents = index.getDependents(nodeId);
            foreach (depId; dependents)
            {
                auto depIdResult = TargetId.parse(depId);
                if (depIdResult.isOk)
                    node.dependentIds ~= depIdResult.unwrap();
            }
        }
        
        // Mark as validated (structure already validated in SQLite)
        graph.validated = true;
        
        return graph;
    }
    
    /// Sync single node status to SQLite (for incremental updates during build)
    void syncStatus(string nodeId, BuildStatus status, long buildDuration = 0) @system
    {
        index.updateStatus(nodeId, status, buildDuration);
    }
    
    /// Sync node from BuildGraph to SQLite (single node update)
    void syncNode(BuildGraph graph, string nodeId) @system
    {
        if (nodeId !in graph.nodes) return;
        
        auto node = graph.nodes[nodeId];
        
        GraphNodeEntry entry;
        entry.nodeId = node.id.toString();
        entry.targetType = node.target.type.to!string;
        entry.targetName = node.target.name;
        entry.outputPath = node.target.outputPath;
        entry.status = node.status;
        entry.hash = node.hash;
        entry.depth = cast(int)node.depth(graph);
        entry.lastBuild = Clock.currTime();
        
        index.putNode(entry);
    }
    
    /// Add edge to SQLite (for dynamic dependency discovery)
    void addEdge(string fromId, string toId) @system
    {
        index.addEdge(fromId, toId);
    }
    
    /// Check if graph exists in SQLite
    bool hasPersisted() @system
    {
        return index.listNodes().length > 0;
    }
    
    /// Get persisted stats without loading graph
    GraphStats getStats() @system
    {
        return index.getStats();
    }
}

/// Create adapter with new GraphIndex
GraphAdapter createAdapter(string cacheDir = ".builder-cache") @system
{
    return GraphAdapter(new GraphIndex(cacheDir));
}

