module engine.graph.persistence.index;

import std.datetime : Clock, SysTime;
import std.conv : to;
import std.file : exists, mkdirRecurse;
import std.path : buildPath, dirName;
import std.algorithm : map, filter, canFind;
import std.array : array, appender;
import std.string : toStringz, fromStringz;
import core.sync.mutex : Mutex;
import engine.caching.index.sqlite;
import engine.graph.core.graph : BuildStatus;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.errors;

/// SQLite-backed build graph persistence providing:
/// - Efficient partial queries (SELECT WHERE) without full graph load
/// - WAL-based crash recovery for build interruptions
/// - Graph introspection (dependency chains, critical path queries)
/// - Status tracking across build sessions
/// - LRU-based graph node eviction
/// 
/// Design: Normalized relational schema for query efficiency
/// - graph_nodes: Node metadata and status
/// - graph_edges: Directed edges (dependency relationships)
/// - Enables SQL-based graph traversal queries
final class GraphIndex
{
    private sqlite3* db;
    private Mutex dbMutex;
    private string dbPath;
    private bool closed;
    
    // Prepared statements for performance
    private sqlite3_stmt* stmtNodeGet;
    private sqlite3_stmt* stmtNodePut;
    private sqlite3_stmt* stmtNodeDelete;
    private sqlite3_stmt* stmtNodeStatus;
    private sqlite3_stmt* stmtEdgeAdd;
    private sqlite3_stmt* stmtEdgeRemove;
    private sqlite3_stmt* stmtDepsGet;
    private sqlite3_stmt* stmtDependentsGet;
    private sqlite3_stmt* stmtJournalWrite;
    private sqlite3_stmt* stmtJournalCommit;
    private sqlite3_stmt* stmtStatIncrement;

    /// Initialize graph index with SQLite database
    this(string cacheDir = ".builder-cache") @system
    {
        this.dbMutex = new Mutex();
        this.dbPath = buildPath(cacheDir, "graph.db");
        
        auto dir = dirName(dbPath);
        if (!exists(dir)) mkdirRecurse(dir);
        
        auto rc = sqlite3_open(dbPath.toStringz, &db);
        if (rc != SQLITE_OK)
            throw Errors.graph("Failed to open graph index: " ~ fromStringz(sqlite3_errmsg(db)).idup,
                              ErrorCode.CacheLoadFailed).build();
        
        // WAL mode for crash recovery and concurrent reads
        execSQL("PRAGMA journal_mode=WAL");
        execSQL("PRAGMA synchronous=NORMAL");
        execSQL("PRAGMA cache_size=-64000");  // 64MB cache
        execSQL("PRAGMA temp_store=MEMORY");
        execSQL("PRAGMA busy_timeout=5000");
        execSQL("PRAGMA foreign_keys=ON");
        
        initializeSchema();
        prepareStatements();
        replayJournal();
    }
    
    ~this() @trusted nothrow { 
        // Don't call close() during GC - the mutex may already be finalized
        // Destructor is for emergency cleanup only; prefer explicit close() calls
        if (!closed && dbMutex !is null) {
            closed = true;
            // Finalize statements and close DB without synchronization
            // since we can't safely acquire mutex during GC
            finalizeStatements();
            if (db !is null) sqlite3_close_v2(db);
            db = null;
        }
    }
    
    /// Close database connection
    void close() @system
    {
        if (dbMutex is null) return;
        synchronized (dbMutex)
        {
            if (closed) return;
            finalizeStatements();
            sqlite3_wal_checkpoint_v2(db, null, SQLITE_CHECKPOINT_TRUNCATE, null, null);
            sqlite3_close(db);
            closed = true;
        }
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Node Operations
    // ─────────────────────────────────────────────────────────────────
    
    /// Check if node exists
    bool hasNode(string nodeId) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtNodeGet);
            sqlite3_bind_text(stmtNodeGet, 1, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            return sqlite3_step(stmtNodeGet) == SQLITE_ROW;
        }
    }
    
    /// Get node metadata
    BuildResult!GraphNodeEntry getNode(string nodeId) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtNodeGet);
            sqlite3_bind_text(stmtNodeGet, 1, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            
            if (sqlite3_step(stmtNodeGet) != SQLITE_ROW)
                return Err!(GraphNodeEntry, BuildError)(
                    Errors.graph("Node not found: " ~ nodeId, ErrorCode.NodeNotFound).build());
            
            GraphNodeEntry entry;
            entry.nodeId = fromStringz(sqlite3_column_text(stmtNodeGet, 0)).idup;
            entry.targetType = fromStringz(sqlite3_column_text(stmtNodeGet, 1)).idup;
            entry.targetName = fromStringz(sqlite3_column_text(stmtNodeGet, 2)).idup;
            entry.outputPath = fromStringz(sqlite3_column_text(stmtNodeGet, 3)).idup;
            entry.status = cast(BuildStatus)sqlite3_column_int(stmtNodeGet, 4);
            entry.hash = fromStringz(sqlite3_column_text(stmtNodeGet, 5)).idup;
            entry.depth = sqlite3_column_int(stmtNodeGet, 6);
            entry.createdAt = SysTime.fromUnixTime(sqlite3_column_int64(stmtNodeGet, 7));
            entry.lastBuild = SysTime.fromUnixTime(sqlite3_column_int64(stmtNodeGet, 8));
            entry.buildDuration = sqlite3_column_int64(stmtNodeGet, 9);
            
            return Ok!(GraphNodeEntry, BuildError)(entry);
        }
    }
    
    /// Insert or update node
    void putNode(GraphNodeEntry entry) @system
    {
        immutable now = Clock.currTime.toUnixTime;
        
        synchronized (dbMutex)
        {
            writeJournal("put", "node", entry.nodeId);
            
            sqlite3_reset(stmtNodePut);
            sqlite3_bind_text(stmtNodePut, 1, entry.nodeId.toStringz, cast(int)entry.nodeId.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtNodePut, 2, entry.targetType.toStringz, cast(int)entry.targetType.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtNodePut, 3, entry.targetName.toStringz, cast(int)entry.targetName.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtNodePut, 4, entry.outputPath.toStringz, cast(int)entry.outputPath.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmtNodePut, 5, cast(int)entry.status);
            sqlite3_bind_text(stmtNodePut, 6, entry.hash.toStringz, cast(int)entry.hash.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmtNodePut, 7, entry.depth);
            sqlite3_bind_int64(stmtNodePut, 8, entry.createdAt == SysTime.init ? now : entry.createdAt.toUnixTime);
            sqlite3_bind_int64(stmtNodePut, 9, entry.lastBuild == SysTime.init ? 0 : entry.lastBuild.toUnixTime);
            sqlite3_bind_int64(stmtNodePut, 10, entry.buildDuration);
            
            if (sqlite3_step(stmtNodePut) != SQLITE_DONE)
                throw Errors.graph("Failed to insert node: " ~ fromStringz(sqlite3_errmsg(db)).idup,
                                  ErrorCode.CacheWriteFailed).build();
            
            commitJournal();
        }
    }
    
    /// Delete node and its edges
    void deleteNode(string nodeId) @system
    {
        synchronized (dbMutex)
        {
            writeJournal("delete", "node", nodeId);
            
            // Edges cascade delete via foreign key
            sqlite3_reset(stmtNodeDelete);
            sqlite3_bind_text(stmtNodeDelete, 1, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtNodeDelete);
            
            commitJournal();
        }
    }
    
    /// Update node status atomically
    void updateStatus(string nodeId, BuildStatus status, long buildDuration = 0) @system
    {
        immutable now = Clock.currTime.toUnixTime;
        
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtNodeStatus);
            sqlite3_bind_int(stmtNodeStatus, 1, cast(int)status);
            sqlite3_bind_int64(stmtNodeStatus, 2, now);
            sqlite3_bind_int64(stmtNodeStatus, 3, buildDuration);
            sqlite3_bind_text(stmtNodeStatus, 4, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtNodeStatus);
        }
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Edge Operations
    // ─────────────────────────────────────────────────────────────────
    
    /// Add dependency edge: from depends on to
    void addEdge(string fromId, string toId) @system
    {
        synchronized (dbMutex)
        {
            writeJournal("add", "edge", fromId ~ "->" ~ toId);
            
            sqlite3_reset(stmtEdgeAdd);
            sqlite3_bind_text(stmtEdgeAdd, 1, fromId.toStringz, cast(int)fromId.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtEdgeAdd, 2, toId.toStringz, cast(int)toId.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtEdgeAdd);
            
            commitJournal();
        }
    }
    
    /// Remove dependency edge
    void removeEdge(string fromId, string toId) @system
    {
        synchronized (dbMutex)
        {
            writeJournal("remove", "edge", fromId ~ "->" ~ toId);
            
            sqlite3_reset(stmtEdgeRemove);
            sqlite3_bind_text(stmtEdgeRemove, 1, fromId.toStringz, cast(int)fromId.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtEdgeRemove, 2, toId.toStringz, cast(int)toId.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtEdgeRemove);
            
            commitJournal();
        }
    }
    
    /// Get direct dependencies of a node
    string[] getDependencies(string nodeId) @system
    {
        synchronized (dbMutex)
        {
            string[] deps;
            sqlite3_reset(stmtDepsGet);
            sqlite3_bind_text(stmtDepsGet, 1, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            
            while (sqlite3_step(stmtDepsGet) == SQLITE_ROW)
                deps ~= fromStringz(sqlite3_column_text(stmtDepsGet, 0)).idup;
            
            return deps;
        }
    }
    
    /// Get direct dependents of a node
    string[] getDependents(string nodeId) @system
    {
        synchronized (dbMutex)
        {
            string[] deps;
            sqlite3_reset(stmtDependentsGet);
            sqlite3_bind_text(stmtDependentsGet, 1, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            
            while (sqlite3_step(stmtDependentsGet) == SQLITE_ROW)
                deps ~= fromStringz(sqlite3_column_text(stmtDependentsGet, 0)).idup;
            
            return deps;
        }
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Graph Queries (without full load)
    // ─────────────────────────────────────────────────────────────────
    
    /// Get all nodes with specific status
    string[] queryByStatus(BuildStatus status) @system
    {
        synchronized (dbMutex)
        {
            string[] results;
            auto stmt = prepareQuery("SELECT node_id FROM graph_nodes WHERE status = ?");
            scope(exit) sqlite3_finalize(stmt);
            sqlite3_bind_int(stmt, 1, cast(int)status);
            
            while (sqlite3_step(stmt) == SQLITE_ROW)
                results ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            return results;
        }
    }
    
    /// Get transitive closure of dependencies (all ancestors)
    string[] getTransitiveDeps(string nodeId, size_t maxDepth = 100) @system
    {
        synchronized (dbMutex)
        {
            // Recursive CTE for transitive closure
            auto sql = "WITH RECURSIVE deps(node_id, depth) AS (" ~
                      "  SELECT to_node, 1 FROM graph_edges WHERE from_node = ?" ~
                      "  UNION" ~
                      "  SELECT e.to_node, d.depth + 1 FROM graph_edges e" ~
                      "  JOIN deps d ON e.from_node = d.node_id WHERE d.depth < ?" ~
                      ") SELECT DISTINCT node_id FROM deps";
            
            auto stmt = prepareQuery(sql);
            scope(exit) sqlite3_finalize(stmt);
            sqlite3_bind_text(stmt, 1, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmt, 2, cast(int)maxDepth);
            
            string[] results;
            while (sqlite3_step(stmt) == SQLITE_ROW)
                results ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            return results;
        }
    }
    
    /// Get transitive closure of dependents (all descendants)
    string[] getTransitiveDependents(string nodeId, size_t maxDepth = 100) @system
    {
        synchronized (dbMutex)
        {
            auto sql = "WITH RECURSIVE deps(node_id, depth) AS (" ~
                      "  SELECT from_node, 1 FROM graph_edges WHERE to_node = ?" ~
                      "  UNION" ~
                      "  SELECT e.from_node, d.depth + 1 FROM graph_edges e" ~
                      "  JOIN deps d ON e.to_node = d.node_id WHERE d.depth < ?" ~
                      ") SELECT DISTINCT node_id FROM deps";
            
            auto stmt = prepareQuery(sql);
            scope(exit) sqlite3_finalize(stmt);
            sqlite3_bind_text(stmt, 1, nodeId.toStringz, cast(int)nodeId.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmt, 2, cast(int)maxDepth);
            
            string[] results;
            while (sqlite3_step(stmt) == SQLITE_ROW)
                results ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            return results;
        }
    }
    
    /// Get roots (nodes with no dependencies)
    string[] getRoots() @system
    {
        synchronized (dbMutex)
        {
            auto stmt = prepareQuery(
                "SELECT node_id FROM graph_nodes WHERE node_id NOT IN " ~
                "(SELECT from_node FROM graph_edges)");
            scope(exit) sqlite3_finalize(stmt);
            
            string[] roots;
            while (sqlite3_step(stmt) == SQLITE_ROW)
                roots ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            return roots;
        }
    }
    
    /// Get leaves (nodes with no dependents)
    string[] getLeaves() @system
    {
        synchronized (dbMutex)
        {
            auto stmt = prepareQuery(
                "SELECT node_id FROM graph_nodes WHERE node_id NOT IN " ~
                "(SELECT to_node FROM graph_edges)");
            scope(exit) sqlite3_finalize(stmt);
            
            string[] leaves;
            while (sqlite3_step(stmt) == SQLITE_ROW)
                leaves ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            return leaves;
        }
    }
    
    /// Get critical path (longest dependency chain by depth)
    string[] getCriticalPath() @system
    {
        synchronized (dbMutex)
        {
            // Find node with max depth, then trace back to root
            auto stmt = prepareQuery(
                "SELECT node_id FROM graph_nodes ORDER BY depth DESC LIMIT 1");
            scope(exit) sqlite3_finalize(stmt);
            
            if (sqlite3_step(stmt) != SQLITE_ROW)
                return [];
            
            auto deepest = fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            // Trace path back using recursive CTE
            auto pathSql = "WITH RECURSIVE path(node_id, d) AS (" ~
                          "  SELECT ?, depth FROM graph_nodes WHERE node_id = ?" ~
                          "  UNION ALL" ~
                          "  SELECT e.to_node, n.depth FROM path p" ~
                          "  JOIN graph_edges e ON e.from_node = p.node_id" ~
                          "  JOIN graph_nodes n ON n.node_id = e.to_node" ~
                          "  WHERE n.depth = p.d - 1" ~
                          ") SELECT node_id FROM path ORDER BY d DESC";
            
            auto pathStmt = prepareQuery(pathSql);
            scope(exit) sqlite3_finalize(pathStmt);
            sqlite3_bind_text(pathStmt, 1, deepest.toStringz, cast(int)deepest.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(pathStmt, 2, deepest.toStringz, cast(int)deepest.length, SQLITE_TRANSIENT);
            
            string[] path;
            while (sqlite3_step(pathStmt) == SQLITE_ROW)
                path ~= fromStringz(sqlite3_column_text(pathStmt, 0)).idup;
            
            return path;
        }
    }
    
    /// Get subgraph (node + all transitive deps)
    GraphNodeEntry[] getSubgraph(string nodeId) @system
    {
        auto deps = getTransitiveDeps(nodeId);
        GraphNodeEntry[] entries;
        entries.reserve(deps.length + 1);
        
        // Include root node
        auto rootResult = getNode(nodeId);
        if (rootResult.isOk)
            entries ~= rootResult.unwrap();
        
        // Include all dependencies
        foreach (dep; deps)
        {
            auto result = getNode(dep);
            if (result.isOk)
                entries ~= result.unwrap();
        }
        
        return entries;
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Statistics
    // ─────────────────────────────────────────────────────────────────
    
    /// Get graph statistics
    GraphStats getStats() @system
    {
        synchronized (dbMutex)
        {
            GraphStats stats;
            
            auto nodeStmt = prepareQuery("SELECT COUNT(*), MAX(depth) FROM graph_nodes");
            scope(exit) sqlite3_finalize(nodeStmt);
            if (sqlite3_step(nodeStmt) == SQLITE_ROW)
            {
                stats.totalNodes = sqlite3_column_int64(nodeStmt, 0);
                stats.maxDepth = sqlite3_column_int(nodeStmt, 1);
            }
            
            auto edgeStmt = prepareQuery("SELECT COUNT(*) FROM graph_edges");
            scope(exit) sqlite3_finalize(edgeStmt);
            if (sqlite3_step(edgeStmt) == SQLITE_ROW)
                stats.totalEdges = sqlite3_column_int64(edgeStmt, 0);
            
            auto statusStmt = prepareQuery(
                "SELECT status, COUNT(*) FROM graph_nodes GROUP BY status");
            scope(exit) sqlite3_finalize(statusStmt);
            while (sqlite3_step(statusStmt) == SQLITE_ROW)
            {
                auto status = cast(BuildStatus)sqlite3_column_int(statusStmt, 0);
                auto count = sqlite3_column_int64(statusStmt, 1);
                final switch (status)
                {
                    case BuildStatus.Pending: stats.pendingNodes = count; break;
                    case BuildStatus.Building: stats.buildingNodes = count; break;
                    case BuildStatus.Success: stats.successNodes = count; break;
                    case BuildStatus.Failed: stats.failedNodes = count; break;
                    case BuildStatus.Cached: stats.cachedNodes = count; break;
                }
            }
            
            return stats;
        }
    }
    
    /// Clear all graph data
    void clear() @system
    {
        synchronized (dbMutex)
        {
            execSQL("DELETE FROM graph_edges");
            execSQL("DELETE FROM graph_nodes");
            execSQL("DELETE FROM graph_journal");
            execSQL("UPDATE graph_stats SET value = 0");
        }
    }
    
    /// List all node IDs
    string[] listNodes() @system
    {
        synchronized (dbMutex)
        {
            string[] nodes;
            auto stmt = prepareQuery("SELECT node_id FROM graph_nodes ORDER BY depth DESC");
            scope(exit) sqlite3_finalize(stmt);
            while (sqlite3_step(stmt) == SQLITE_ROW)
                nodes ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            return nodes;
        }
    }

private:
    void execSQL(string sql) @trusted
    {
        char* errMsg;
        auto rc = sqlite3_exec(db, sql.toStringz, null, null, &errMsg);
        if (rc != SQLITE_OK)
        {
            auto msg = errMsg ? fromStringz(errMsg).idup : "Unknown error";
            sqlite3_free(errMsg);
            throw new Exception("SQL error: " ~ msg ~ " (query: " ~ sql ~ ")");
        }
    }
    
    sqlite3_stmt* prepareQuery(string sql) @trusted
    {
        sqlite3_stmt* stmt;
        auto rc = sqlite3_prepare_v2(db, sql.toStringz, cast(int)sql.length, &stmt, null);
        if (rc != SQLITE_OK)
            throw new Exception("Failed to prepare: " ~ sql ~ " - " ~ fromStringz(sqlite3_errmsg(db)).idup);
        return stmt;
    }
    
    void initializeSchema() @trusted
    {
        // Nodes table - stores all node metadata
        execSQL("CREATE TABLE IF NOT EXISTS graph_nodes (" ~
                "node_id TEXT PRIMARY KEY, target_type TEXT NOT NULL, target_name TEXT NOT NULL, " ~
                "output_path TEXT, status INTEGER NOT NULL DEFAULT 0, hash TEXT, " ~
                "depth INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, " ~
                "last_build INTEGER DEFAULT 0, build_duration INTEGER DEFAULT 0)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_node_status ON graph_nodes(status)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_node_depth ON graph_nodes(depth)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_node_type ON graph_nodes(target_type)");
        
        // Edges table - normalized for query efficiency
        execSQL("CREATE TABLE IF NOT EXISTS graph_edges (" ~
                "from_node TEXT NOT NULL, to_node TEXT NOT NULL, " ~
                "PRIMARY KEY (from_node, to_node), " ~
                "FOREIGN KEY (from_node) REFERENCES graph_nodes(node_id) ON DELETE CASCADE, " ~
                "FOREIGN KEY (to_node) REFERENCES graph_nodes(node_id) ON DELETE CASCADE)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_edge_from ON graph_edges(from_node)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_edge_to ON graph_edges(to_node)");
        
        // Journal for crash recovery
        execSQL("CREATE TABLE IF NOT EXISTS graph_journal (" ~
                "seq INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT NOT NULL, " ~
                "table_name TEXT NOT NULL, entry_key TEXT NOT NULL, " ~
                "timestamp INTEGER NOT NULL, committed INTEGER NOT NULL DEFAULT 0)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_gj_uncommitted ON graph_journal(committed)");
        
        // Statistics
        execSQL("CREATE TABLE IF NOT EXISTS graph_stats (" ~
                "name TEXT PRIMARY KEY, value INTEGER NOT NULL, updated_at INTEGER NOT NULL)");
        
        execSQL("INSERT OR IGNORE INTO graph_stats (name, value, updated_at) VALUES ('builds', 0, 0)");
        execSQL("INSERT OR IGNORE INTO graph_stats (name, value, updated_at) VALUES ('cache_hits', 0, 0)");
    }
    
    void prepareStatements() @trusted
    {
        stmtNodeGet = prepareQuery(
            "SELECT node_id, target_type, target_name, output_path, status, hash, depth, " ~
            "created_at, last_build, build_duration FROM graph_nodes WHERE node_id = ?");
        stmtNodePut = prepareQuery(
            "INSERT OR REPLACE INTO graph_nodes (node_id, target_type, target_name, output_path, " ~
            "status, hash, depth, created_at, last_build, build_duration) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
        stmtNodeDelete = prepareQuery("DELETE FROM graph_nodes WHERE node_id = ?");
        stmtNodeStatus = prepareQuery(
            "UPDATE graph_nodes SET status = ?, last_build = ?, build_duration = ? WHERE node_id = ?");
        
        stmtEdgeAdd = prepareQuery("INSERT OR IGNORE INTO graph_edges (from_node, to_node) VALUES (?, ?)");
        stmtEdgeRemove = prepareQuery("DELETE FROM graph_edges WHERE from_node = ? AND to_node = ?");
        stmtDepsGet = prepareQuery("SELECT to_node FROM graph_edges WHERE from_node = ?");
        stmtDependentsGet = prepareQuery("SELECT from_node FROM graph_edges WHERE to_node = ?");
        
        stmtJournalWrite = prepareQuery(
            "INSERT INTO graph_journal (operation, table_name, entry_key, timestamp, committed) VALUES (?, ?, ?, ?, 0)");
        stmtJournalCommit = prepareQuery("UPDATE graph_journal SET committed = 1 WHERE seq = ?");
        stmtStatIncrement = prepareQuery("UPDATE graph_stats SET value = value + 1, updated_at = ? WHERE name = ?");
    }
    
    void finalizeStatements() @trusted nothrow
    {
        if (stmtNodeGet) sqlite3_finalize(stmtNodeGet);
        if (stmtNodePut) sqlite3_finalize(stmtNodePut);
        if (stmtNodeDelete) sqlite3_finalize(stmtNodeDelete);
        if (stmtNodeStatus) sqlite3_finalize(stmtNodeStatus);
        if (stmtEdgeAdd) sqlite3_finalize(stmtEdgeAdd);
        if (stmtEdgeRemove) sqlite3_finalize(stmtEdgeRemove);
        if (stmtDepsGet) sqlite3_finalize(stmtDepsGet);
        if (stmtDependentsGet) sqlite3_finalize(stmtDependentsGet);
        if (stmtJournalWrite) sqlite3_finalize(stmtJournalWrite);
        if (stmtJournalCommit) sqlite3_finalize(stmtJournalCommit);
        if (stmtStatIncrement) sqlite3_finalize(stmtStatIncrement);
    }
    
    void writeJournal(string op, string table, string key) @trusted
    {
        immutable now = Clock.currTime.toUnixTime;
        sqlite3_reset(stmtJournalWrite);
        sqlite3_bind_text(stmtJournalWrite, 1, op.toStringz, cast(int)op.length, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmtJournalWrite, 2, table.toStringz, cast(int)table.length, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmtJournalWrite, 3, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmtJournalWrite, 4, now);
        sqlite3_step(stmtJournalWrite);
    }
    
    void commitJournal() @trusted
    {
        auto lastId = sqlite3_last_insert_rowid(db);
        sqlite3_reset(stmtJournalCommit);
        sqlite3_bind_int64(stmtJournalCommit, 1, lastId);
        sqlite3_step(stmtJournalCommit);
    }
    
    void replayJournal() @trusted
    {
        // Delete uncommitted entries (will be rebuilt from source)
        execSQL("DELETE FROM graph_journal WHERE committed = 0");
        // Clean old journal entries (older than 24h)
        immutable cutoff = Clock.currTime.toUnixTime - 86400;
        execSQL("DELETE FROM graph_journal WHERE timestamp < " ~ cutoff.to!string);
    }
    
    void incrementStat(string name) @trusted
    {
        synchronized (dbMutex)
        {
            immutable now = Clock.currTime.toUnixTime;
            sqlite3_reset(stmtStatIncrement);
            sqlite3_bind_int64(stmtStatIncrement, 1, now);
            sqlite3_bind_text(stmtStatIncrement, 2, name.toStringz, cast(int)name.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtStatIncrement);
        }
    }
}

/// Graph node entry (persisted metadata)
struct GraphNodeEntry
{
    string nodeId;
    string targetType;
    string targetName;
    string outputPath;
    BuildStatus status;
    string hash;
    int depth;
    SysTime createdAt;
    SysTime lastBuild;
    long buildDuration;  // milliseconds
}

/// Graph statistics
struct GraphStats
{
    long totalNodes;
    long totalEdges;
    int maxDepth;
    long pendingNodes;
    long buildingNodes;
    long successNodes;
    long failedNodes;
    long cachedNodes;
    
    float cacheRate() const pure @safe
        => totalNodes > 0 ? (cachedNodes * 100.0f) / totalNodes : 0.0f;
    
    float successRate() const pure @safe
    {
        immutable completed = successNodes + failedNodes + cachedNodes;
        return completed > 0 ? ((successNodes + cachedNodes) * 100.0f) / completed : 0.0f;
    }
}

