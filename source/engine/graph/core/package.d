module engine.graph.core;

/// Core graph data structures and algorithms
/// 
/// Exports:
/// - BuildGraph: Main dependency graph structure with topological ordering
/// - BuildNode: Graph node representing a build target with atomic state
/// - BuildStatus: Build execution status enumeration
/// - ValidationMode: Graph validation strategy (Immediate vs Deferred)
/// - IncrementalTopoOrder: Incremental topological ordering for watch mode
/// - IncrementalTopoStats: Statistics for incremental updates
/// - IGraphReader: Read-only interface for zero-copy graph access
/// - BuildGraphReader: Adapter for BuildGraph to implement IGraphReader
/// 
/// Thread Safety:
/// - BuildNode uses atomic operations for status fields
/// - BuildGraph is thread-safe for concurrent reads during execution
/// - Mutations should be performed before parallel execution begins
/// 
/// Performance:
/// - Immediate validation: O(V²) worst-case for dense graphs
/// - Deferred validation: O(V+E) single topological sort
/// - Depth calculation: O(V+E) total with memoization
/// - Incremental topological sort: O(1) cache hit, O(affected) on changes
/// - IGraphReader: Zero-copy access via mmap eliminates deserialization

public import engine.graph.core.graph;
public import engine.graph.core.incremental_topo;
public import engine.graph.core.reader;

