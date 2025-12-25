module engine.graph.persistence;

/// SQLite-backed build graph persistence
/// 
/// Provides crash-safe graph storage with efficient queries:
/// - WAL mode for crash recovery
/// - Partial graph queries without full memory load
/// - Dependency chain analysis (transitive closure)
/// - Impact analysis (what rebuilds on change)
/// - Build order optimization
/// 
/// ## Architecture
/// 
/// ```
/// persistence/
/// ├── index.d     GraphIndex - SQLite storage layer
/// ├── queries.d   GraphQuery - High-level query interface
/// └── adapter.d   GraphAdapter - BuildGraph ↔ SQLite bridge
/// ```
/// 
/// ## Components
/// 
/// ### GraphIndex
/// Low-level SQLite operations with prepared statements:
/// - Node CRUD (putNode, getNode, deleteNode)
/// - Edge management (addEdge, removeEdge)
/// - Status updates (updateStatus)
/// - Transitive queries (getTransitiveDeps, getTransitiveDependents)
/// - Graph analysis (getRoots, getLeaves, getCriticalPath)
/// 
/// ### GraphQuery  
/// High-level semantic queries:
/// - getBuildOrder() - Topological sort for execution
/// - getReadyNodes() - Nodes ready to build
/// - getImpact() - What rebuilds if X changes
/// - findBottlenecks() - Nodes blocking parallelism
/// - getParallelOpportunities() - Current parallelism potential
/// 
/// ### GraphAdapter
/// Bidirectional sync between BuildGraph and SQLite:
/// - persist() - Save BuildGraph to SQLite
/// - restore() - Load BuildGraph from SQLite
/// - syncStatus() - Incremental status updates
/// 
/// ## Usage
/// 
/// ```d
/// import engine.graph.persistence;
/// 
/// // Direct SQLite access
/// auto index = new GraphIndex(".builder-cache");
/// index.putNode(GraphNodeEntry(...));
/// index.addEdge(fromId, toId);
/// auto deps = index.getTransitiveDeps(nodeId);
/// 
/// // High-level queries
/// auto query = GraphQuery(index);
/// auto ready = query.getReadyNodes();
/// auto bottlenecks = query.findBottlenecks();
/// 
/// // BuildGraph integration
/// auto adapter = GraphAdapter(index);
/// adapter.persist(buildGraph);
/// auto restored = adapter.restore();
/// 
/// index.close();
/// ```
/// 
/// ## Storage
/// 
/// - Location: `.builder-cache/graph.db`
/// - Format: SQLite with WAL mode
/// - Schema: Normalized (nodes + edges tables)
/// - Indexes: status, depth, type for fast queries
/// 
/// ## Performance
/// 
/// - Transitive queries: O(V+E) via recursive CTE
/// - Point lookups: O(1) via prepared statements
/// - Crash recovery: WAL checkpoint on close
/// - Concurrent reads: WAL enables read parallelism

public import engine.graph.persistence.index;
public import engine.graph.persistence.queries;
public import engine.graph.persistence.adapter;

