module engine.graph.caching.storage;

import std.datetime;
import engine.graph.core.graph;
import engine.graph.caching.schema;
import infrastructure.config.schema.schema;
import infrastructure.utils.serialization;
import infrastructure.utils.compression.streaming : zstdCompress, zstdDecompress;
import infrastructure.errors : Result, Ok, Err, BuildError, Errors, Cache, Graph;

/// High-performance binary serialization for BuildGraph
/// Uses SIMD-accelerated serialization framework + zstd compression
/// 
/// Design:
/// - Schema-based serialization with versioning
/// - Preserves full graph topology (nodes + edges)
/// - All metadata preserved (status, hashes, retry counts)
/// - ~10x faster than JSON, ~60-80% smaller with compression
/// 
/// Performance:
/// - Compile-time code generation
/// - SIMD varint encoding
/// - Zstd compression (typically 50-70% reduction on graphs)
/// - Arena buffer management
struct GraphStorage
{
    /// Magic header for compressed graphs
    private enum ubyte[4] COMPRESSED_MAGIC = [0x47, 0x52, 0x43, 0x5A];  // "GRCZ"
    
    /// Serialize BuildGraph to binary format (with compression)
    /// 
    /// Safety: @system due to:
    /// - Atomic reads from shared fields (thread-safe)
    /// - Pointer access to graph nodes (bounds-checked)
    static ubyte[] serialize(BuildGraph graph, bool compress = true) @system
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
        auto raw = Codec.serialize(serializable);
        
        // Compress if enabled and beneficial
        if (compress && raw.length > 1024)
        {
            auto compResult = zstdCompress(raw, 3);
            if (compResult.isOk)
            {
                auto compressed = compResult.unwrap();
                if (compressed.length < raw.length * 9 / 10)
                {
                    // Prepend magic header
                    ubyte[] result;
                    result.reserve(4 + compressed.length);
                    result ~= COMPRESSED_MAGIC[];
                    result ~= compressed;
                    return result;
                }
            }
        }
        
        return raw;
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
        
        // Check for compression header and decompress
        ubyte[] toDeserialize = data;
        if (data.length > 4 && data[0..4] == COMPRESSED_MAGIC)
        {
            auto decompResult = zstdDecompress(data[4 .. $]);
            if (decompResult.isErr)
                throw Errors.cache("Graph decompression failed", Cache.CompressionFailed)
                    .withCommand("Clear corrupted cache", "bldr clean --cache").build();
            toDeserialize = decompResult.unwrap();
        }
        
        // Deserialize with codec
        auto result = Codec.deserialize!SerializableBuildGraph(toDeserialize);
        
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
        
        // Add nodes to graph with indexed lookup
        foreach (key, node; nodeMap)
        {
            graph._stringToIndex[key] = node._nodeIndex;
            graph.nodes[key] = node;
        }
        
        // Reconstruct roots using indexed lookup
        foreach (rootId; serializable.rootIds)
        {
            auto node = graph.getNodeByKey(rootId);
            if (node !is null)
                graph.roots ~= node;
        }
        
        // Restore validation state
        graph.validated = serializable.isValidated;
        
        return graph;
    }
}
