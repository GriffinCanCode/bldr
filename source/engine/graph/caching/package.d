module engine.graph.caching;

/// High-performance graph caching subsystem
/// 
/// Exports:
/// - GraphCache: Dependency graph cache with incremental invalidation
/// - GraphStorage: Binary serialization/deserialization for graphs
/// - MmapGraphCache: Zero-copy memory-mapped graph cache (preferred)
/// - MappedGraphView: Zero-copy graph view via mmap (implements IGraphReader)
/// - MmapGraphOverlay: Mutable status overlay for mmap'd topology
/// - Serializable*: Schema definitions for binary format
/// 
/// Design Philosophy:
/// - Memory-mapped graph persistence eliminates deserialization overhead entirely
/// - Graph topology stays in mmap (read-only, zero-copy from kernel page cache)
/// - Status updates tracked in lightweight overlay (no mmap modification)
/// - Two-tier validation: metadata hash (fast) → content hash (slow)
/// - SIMD-accelerated hash comparisons for performance
/// - Thread-safe concurrent access with mutex protection
/// 
/// Zero-Copy Architecture:
/// - MmapGraphCache.loadView(): O(1) mmap, no parsing (~0.1ms any size)
/// - MmapGraphCache.loadWithOverlay(): Zero-copy topology + mutable status
/// - MmapGraphCache.loadGraph(): Full deserialization (fallback only)
/// 
/// Performance Benefits:
/// - 100-1000x speedup for graph loading via mmap (vs deserialization)
/// - 10-50x speedup for unchanged graphs via cache validation
/// - Sub-millisecond cache validation for typical projects
/// - Graph pages loaded on-demand by kernel (lazy loading)
/// 
/// Cache Location:
/// - .builder-cache/graph.mmap (memory-mapped graph format)
/// - .builder-cache/graph.bin (legacy binary graph data)
/// - .builder-cache/graph-metadata.bin (validation metadata)

public import engine.graph.caching.cache;
public import engine.graph.caching.storage;
public import engine.graph.caching.schema;
public import engine.graph.caching.mapped;

