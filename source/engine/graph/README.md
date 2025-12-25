# Graph Module

The graph module provides the core dependency graph infrastructure for Builder's build system. It handles graph construction, validation, caching, dynamic runtime extension, and formal verification.

## Architecture Overview

```
graph/
├── core/          Core graph data structures
├── caching/       High-performance graph caching
├── persistence/   SQLite-backed crash-safe storage
├── dynamic/       Runtime graph extension
└── verification/  Formal correctness proofs
```

### Core (`engine.graph.core`)

Core graph data structures and algorithms:

- **BuildGraph** - Main dependency graph with topological ordering and cycle detection
- **BuildNode** - Thread-safe graph nodes with atomic state management
- **BuildStatus** - Build execution status (Pending, Building, Success, Failed, Cached)
- **ValidationMode** - Cycle detection strategies (Immediate vs Deferred)

**Key Features:**
- Topological ordering for correct build execution
- Two validation modes: immediate O(V²) or deferred O(V+E)
- Thread-safe atomic operations for concurrent execution
- Depth calculation with memoization
- Critical path analysis for scheduling optimization

### Caching (`engine.graph.caching`)

High-performance graph caching subsystem:

- **GraphCache** - Incremental cache with two-tier validation
- **GraphStorage** - SIMD-accelerated binary serialization
- **Schema** - Versioned binary format definitions

**Key Features:**
- 10-50x speedup for unchanged graphs
- Sub-millisecond cache validation
- Two-tier validation: metadata (fast) → content hash (slow)
- SIMD-accelerated hash comparisons
- Integrity validation with workspace-specific keys
- ~10x faster than JSON, ~40% smaller

**Cache Location:**
- `.builder-cache/graph.bin` - Binary graph data
- `.builder-cache/graph-metadata.bin` - Validation metadata

### Persistence (`engine.graph.persistence`)

SQLite-backed graph storage for crash safety and efficient queries:

- **GraphIndex** - WAL-mode SQLite storage layer
- **GraphQuery** - High-level query interface
- **GraphAdapter** - Bridge between BuildGraph and GraphIndex

**Key Features:**
- WAL mode for crash recovery
- Partial graph queries without full memory load
- Transitive dependency/dependent queries via recursive CTE
- Impact analysis (what rebuilds if X changes)
- Bottleneck detection
- Build order optimization
- Thread-safe mutex-protected operations

**Storage Location:**
- `.builder-cache/graph.db` - SQLite database with WAL

**Query Capabilities:**
- `getTransitiveDeps()` - All ancestors of a node
- `getTransitiveDependents()` - All descendants of a node
- `getCriticalPath()` - Longest dependency chain
- `queryByStatus()` - Find nodes by build status
- `getSubgraph()` - Load partial graph for analysis

**Usage:**

```d
import engine.graph.persistence;

// Create index
auto index = new GraphIndex(".builder-cache");

// Store nodes and edges
index.putNode(GraphNodeEntry(...));
index.addEdge(fromId, toId);

// Query without loading full graph
auto deps = index.getTransitiveDeps(nodeId);
auto impact = index.getTransitiveDependents(nodeId);
auto path = index.getCriticalPath();

// High-level queries
auto query = GraphQuery(index);
auto ready = query.getReadyNodes();
auto bottlenecks = query.findBottlenecks();

// Adapter for BuildGraph integration
auto adapter = GraphAdapter(index);
adapter.persist(graph);           // Save to SQLite
auto restored = adapter.restore(); // Load from SQLite

index.close();
```

### Dynamic (`engine.graph.dynamic`)

Runtime graph extension and discovery:

- **DynamicBuildGraph** - Extends BuildGraph with runtime mutations
- **DiscoveryMetadata** - Protocol for declaring dynamic dependencies
- **DiscoveryBuilder** - Builder pattern for discovery metadata

**Key Features:**
- Discover dependencies during build execution
- Add nodes/edges after graph construction
- Thread-safe mutation with synchronization
- Common patterns: codegen, test discovery, library scanning

**Use Cases:**
- Code generation that creates new targets
- Test frameworks that discover tests at runtime
- Dynamic language dependency analysis
- Protobuf/gRPC service generation

### Verification (`engine.graph.verification`)

Formal verification of build correctness:

- **BuildVerifier** - Generate mathematical proofs of graph properties
- **BuildProof** - Comprehensive correctness proof
- **ProofCertificate** - Cryptographically signed certificates

**Key Features:**
- **Acyclicity Proof**: Constructive proof via topological ordering
- **Hermeticity Proof**: Set-theoretic verification (I ∩ O = ∅)
- **Determinism Proof**: Content-addressable hashing with BLAKE3
- **Race-Freedom Proof**: Happens-before relation analysis
- **Proof Certificates**: Verifiable, signed proof documents

**Provable Properties:**

1. **Acyclicity**: Graph is a DAG
   - Uses topological sort as constructive proof
   - Verifies each node appears exactly once
   - Verifies all edges point forward

2. **Hermeticity**: I ∩ O = ∅
   - Extends hermetic spec infrastructure
   - Proves input/output disjointness
   - Verifies network isolation

3. **Determinism**: f(I) → O consistently
   - BLAKE3 hashing of inputs, commands, environment
   - Content-addressable proof generation
   - Reproducibility guarantee

4. **Race-Freedom**: No data races
   - Happens-before relation from dependency graph
   - Atomic operation verification
   - Disjoint write-set proof

**Usage:**

```d
import engine.graph.verification;

// Verify graph and generate proof
auto result = BuildVerifier.verify(graph);
if (result.isOk)
{
    auto proof = result.unwrap();
    writeln("✓ Acyclicity: ", proof.acyclicity.isValid);
    writeln("✓ Hermeticity: ", proof.hermeticity.isValid);
    writeln("✓ Determinism: ", proof.determinism.isValid);
    writeln("✓ Race-freedom: ", proof.raceFreedom.isValid);
}

// Generate certificate
auto cert = generateCertificate(graph, "workspace");
if (cert.isOk)
{
    writeln(cert.unwrap().toString());
}
```

**Performance:**
- Acyclicity: O(V+E) topological sort
- Hermeticity: O(N²) disjointness check
- Determinism: O(V) per-target hashing
- Race-freedom: O(V+E) happens-before analysis
- Total: O(V+E) amortized

**Innovation:**

This is the **first build system** to provide:
- Mathematical proofs (not just validation)
- Cryptographically signed certificates
- Formal race-freedom verification
- Set-theoretic correctness foundation

## Thread Safety

### BuildNode
- `status` field uses atomic operations via property accessors
- `isReady()` reads dependency status atomically
- No locks required for status reads/writes (lock-free)

### BuildGraph
- Graph structure (nodes, edges) is immutable after construction
- Only status fields are modified during execution
- Status updates are atomic and coordinated via mutex for consistency

### GraphCache
- Uses internal `Mutex` for all mutable state
- All public methods are synchronized
- Safe for concurrent access from multiple build threads

### GraphIndex
- Uses internal `Mutex` for SQLite operations
- WAL mode enables concurrent reads
- Prepared statements for thread safety
- Crash-safe journal for consistency

### DynamicBuildGraph
- Synchronized mutation operations
- Thread-safe node/edge additions
- Discovery protocol ensures consistency

### BuildVerifier
- Immutable proof structures
- No shared mutable state
- Thread-safe verification

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Graph construction | O(V+E) | Deferred validation mode |
| Cycle detection | O(V+E) | Single topological sort |
| Depth calculation | O(V+E) | Memoized per-node |
| Cache validation | O(1) | Metadata check only |
| Cache save/load | O(V+E) | Binary serialization |
| Persist to SQLite | O(V+E) | Full graph save |
| Transitive deps | O(V+E) | Recursive CTE query |
| Point lookup | O(1) | Prepared statement |
| Dynamic mutation | O(1) | Per node/edge addition |
| Verification | O(V+E) | Proof generation |

## Memory Optimization

BuildNode uses `TargetId[]` instead of `BuildNode[]` for dependencies to avoid GC cycles from bidirectional references. This reduces memory pressure and prevents potential memory leaks.

## Best Practices

1. **Use deferred validation** for large graphs (>1000 nodes)
2. **Cache graphs** between builds for 10-50x speedup
3. **Use SQLite persistence** for crash safety and partial queries
4. **Enable verification** in CI/CD for correctness guarantees
5. **Use dynamic discovery** for runtime dependencies
6. **Profile verification** overhead and enable selectively

## Examples

See:
- `tests/unit/core/graph.d` - Graph construction and validation
- `tests/unit/core/executor.d` - Parallel execution
- `docs/features/graphcache.md` - Caching details
- `docs/features/dynamic-graph.md` - Dynamic discovery
- `docs/architecture/overview.md` - Architecture overview
