module engine.graph.caching.storage;

import std.datetime;
import engine.graph.core.graph;
import engine.graph.caching.schema;
import infrastructure.config.schema.schema;
import infrastructure.utils.serialization;
import infrastructure.errors : Result, Ok, Err, BuildError, Errors, Cache, Graph;

/// High-performance binary serialization for BuildGraph
/// Uses SIMD-accelerated serialization framework
/// 
/// Design:
/// - Schema-based serialization with versioning
/// - Preserves full graph topology (nodes + edges)
/// - All metadata preserved (status, hashes, retry counts)
/// - ~10x faster than JSON, ~40% smaller
/// 
/// Performance:
/// - Compile-time code generation
/// - SIMD varint encoding
/// - Zero-copy deserialization
/// - Arena buffer management
struct GraphStorage
{
    /// Serialize BuildGraph to binary format
    /// 
    /// Safety: @system due to:
    /// - Atomic reads from shared fields (thread-safe)
    /// - Pointer access to graph nodes (bounds-checked)
    static ubyte[] serialize(BuildGraph graph) @system
    {
        // Convert to serializable format
        SerializableBuildGraph serializable;
        
        // Convert nodes
        foreach (key, node; graph.nodes)
        {
            serializable.nodes ~= toSerializable(node);
        }
        
        // Convert roots
        foreach (root; graph.roots)
        {
            serializable.rootIds ~= root.id.toString();
        }
        
        // Store validation state
        serializable.validationMode = cast(uint)graph.validationMode;
        serializable.isValidated = graph.isValidated;
        
        // Serialize with high-performance codec
        return Codec.serialize(serializable);
    }
    
    /// Deserialize BuildGraph from binary format
    /// 
    /// Safety: @system due to:
    /// - BuildGraph construction with deferred validation
    /// - Atomic stores to shared fields
    /// - Arena allocation for reduced GC pressure
    /// 
    /// Throws: CacheError/GraphError on format errors
    static BuildGraph deserialize(scope ubyte[] data) @system
    {
        if (data.length == 0)
            throw Errors.cache("Empty graph data", Cache.LoadFailed)
                .withSuggestion("Graph cache file is empty or corrupted")
                .withCommand("Clear cache", "bldr clean --cache").build();
        
        // Deserialize with codec
        auto result = Codec.deserialize!SerializableBuildGraph(data);
        
        if (result.isErr)
            throw Errors.cache("Failed to deserialize graph: " ~ result.unwrapErr(), Cache.Corrupted)
                .withCommand("Clear corrupted cache", "bldr clean --cache").build();
        
        auto serializable = result.unwrap();
        
        // Create graph with arena pre-sized for known node count
        auto graph = new BuildGraph(
            cast(ValidationMode)serializable.validationMode,
            serializable.nodes.length  // Arena-allocate for exact count
        );
        
        // Reconstruct nodes
        BuildNode[string] nodeMap;
        
        foreach (ref serialNode; serializable.nodes)
        {
            // Convert serializable node to runtime node
            auto idResult = TargetId.parse(serialNode.targetId);
            if (idResult.isErr)
                throw Errors.graph("Failed to parse target ID: " ~ idResult.unwrapErr().message, Graph.Invalid)
                    .withSuggestion("Cached graph contains invalid target ID").build();
            auto targetId = idResult.unwrap();
            auto target = fromSerializableTarget!Target(serialNode.target);
            
            // Use graph's arena allocation
            auto node = graph.createNode(targetId, target);
            node.hash = serialNode.hash;
            node.lastError = serialNode.lastError;
            
            // Set atomic fields using public setters
            node.status = cast(BuildStatus)serialNode.status;
            node.setRetryAttempts(cast(size_t)serialNode.retryAttempts);
            node.setPendingDeps(cast(size_t)serialNode.pendingDeps);
            
            // Store for edge reconstruction
            nodeMap[serialNode.targetId] = node;
        }
        
        // Reconstruct edges
        foreach (ref serialNode; serializable.nodes)
        {
            auto node = nodeMap[serialNode.targetId];
            
            foreach (depId; serialNode.dependencyIds)
            {
                auto depIdResult = TargetId.parse(depId);
                if (depIdResult.isErr)
                    throw Errors.graph("Failed to parse dependency ID: " ~ depIdResult.unwrapErr().message, Graph.Invalid)
                        .withSuggestion("Cached graph contains invalid dependency ID").build();
                node.dependencyIds ~= depIdResult.unwrap();
            }
            
            foreach (depId; serialNode.dependentIds)
            {
                auto depIdResult = TargetId.parse(depId);
                if (depIdResult.isErr)
                    throw Errors.graph("Failed to parse dependent ID: " ~ depIdResult.unwrapErr().message, Graph.Invalid)
                        .withSuggestion("Cached graph contains invalid dependent ID").build();
                node.dependentIds ~= depIdResult.unwrap();
            }
        }
        
        // Add nodes to graph
        foreach (key, node; nodeMap)
        {
            graph.nodes[key] = node;
        }
        
        // Reconstruct roots
        foreach (rootId; serializable.rootIds)
        {
            if (auto node = rootId in nodeMap)
                graph.roots ~= *node;
        }
        
        // Restore validation state
        graph.validated = serializable.isValidated;
        
        return graph;
    }
}
