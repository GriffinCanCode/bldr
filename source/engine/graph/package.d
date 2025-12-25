module engine.graph;

/// Dependency graph module - build graph construction, analysis, and execution
/// 
/// ## Module Organization
/// 
/// ### Core (`engine.graph.core`)
/// Core graph data structures and algorithms:
/// - BuildGraph: Main dependency graph with topological ordering
/// - BuildNode: Thread-safe graph nodes with atomic state
/// - BuildStatus: Build execution status tracking
/// - ValidationMode: Cycle detection strategies
/// 
/// ### Caching (`engine.graph.caching`)
/// High-performance graph caching subsystem:
/// - GraphCache: Incremental cache with two-tier validation
/// - GraphStorage: SIMD-accelerated binary serialization
/// - Schema definitions for versioned binary format
/// 
/// ### Persistence (`engine.graph.persistence`)
/// SQLite-backed graph storage for crash safety:
/// - GraphIndex: WAL-mode SQLite storage layer
/// - GraphQuery: Efficient partial graph queries
/// - Transitive dependency/dependent queries
/// - Impact analysis and bottleneck detection
/// 
/// ### Dynamic (`engine.graph.dynamic`)
/// Runtime graph extension and discovery:
/// - DynamicBuildGraph: Runtime dependency discovery
/// - DiscoveryMetadata: Protocol for dynamic dependencies
/// - Common patterns for codegen, tests, libraries
/// 
/// ### Verification (`engine.graph.verification`)
/// Formal verification of build correctness:
/// - BuildVerifier: Generate mathematical proofs of graph properties
/// - BuildProof: Acyclicity, hermeticity, determinism, race-freedom
/// - ProofCertificate: Cryptographically signed proof certificates
/// - Uses SMT-style verification with constructive proofs
/// 
/// ## Performance
/// - Graph construction: O(V+E) with deferred validation
/// - Cache hits: 10-50x speedup, sub-millisecond validation
/// - Binary format: ~10x faster than JSON, ~40% smaller
/// - Persistence: SQLite WAL for crash recovery
/// - Thread-safe: atomic operations for concurrent execution
/// - Verification: O(V+E) proof generation
/// 
/// ## Thread Safety
/// - BuildNode: Atomic status fields for concurrent reads/writes
/// - GraphCache: Mutex-protected cache operations
/// - GraphIndex: Mutex-protected SQLite operations
/// - DynamicBuildGraph: Synchronized mutation operations
/// - BuildVerifier: Immutable proofs, no shared state

// Core graph structures
public import engine.graph.core;

// Caching subsystem
public import engine.graph.caching;

// SQLite persistence
public import engine.graph.persistence;

// Dynamic discovery
public import engine.graph.dynamic;

// Formal verification
public import engine.graph.verification;

