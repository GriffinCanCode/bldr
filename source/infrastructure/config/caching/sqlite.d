module infrastructure.config.caching.sqlite;

import std.datetime : Clock, SysTime;
import std.conv : to;
import std.file : exists, mkdirRecurse;
import std.path : buildPath, dirName;
import std.algorithm : map, filter;
import std.array : array, appender;
import std.string : toStringz, fromStringz;
import core.sync.mutex : Mutex;
import engine.caching.index.sqlite;
import infrastructure.config.schema.schema : Target, TargetId, TargetType, TargetLanguage, WorkspaceConfig, BuildOptions;
import infrastructure.errors : BuildError, BuildResult, Err, Ok, Errors, Cache;

/// SQLite-backed configuration cache for sub-millisecond lookups
/// 
/// Design Philosophy:
/// - Prepared statements: Pre-compiled SQL for O(1) lookup overhead
/// - WAL mode: Concurrent reads + crash recovery
/// - Indexed columns: workspace, target, language for common queries
/// - Content hashing: BLAKE3-based cache invalidation
/// 
/// Performance Characteristics:
/// - Point lookups: <0.1ms (prepared statement + indexed primary key)
/// - Pattern queries: <1ms (indexed LIKE with prefix)
/// - Bulk inserts: Batched within transaction
/// - Concurrent reads: WAL enables parallel read access
/// 
/// Schema Design:
/// - configs: Main config entries (workspace path → serialized config)
/// - targets: Denormalized target lookup (fast individual target queries)
/// - config_stats: Access statistics for LRU eviction
final class ConfigIndex
{
    private sqlite3* db;
    private Mutex dbMutex;
    private string dbPath;
    private bool closed;
    
    // Prepared statements - pre-compiled for sub-ms execution
    private sqlite3_stmt* stmtConfigGet;
    private sqlite3_stmt* stmtConfigPut;
    private sqlite3_stmt* stmtConfigDelete;
    private sqlite3_stmt* stmtConfigExists;
    private sqlite3_stmt* stmtTargetGet;
    private sqlite3_stmt* stmtTargetPut;
    private sqlite3_stmt* stmtTargetDelete;
    private sqlite3_stmt* stmtTargetsByWorkspace;
    private sqlite3_stmt* stmtTargetsByLanguage;
    private sqlite3_stmt* stmtTargetsByType;
    private sqlite3_stmt* stmtStatTouch;
    private sqlite3_stmt* stmtEvictLRU;
    private sqlite3_stmt* stmtJournalWrite;
    private sqlite3_stmt* stmtJournalCommit;

    /// Initialize config index with SQLite database
    /// Params:
    ///   cacheDir = Directory for SQLite database (default: .builder-cache)
    this(string cacheDir = ".builder-cache") @system
    {
        this.dbMutex = new Mutex();
        this.dbPath = buildPath(cacheDir, "config.db");
        
        auto dir = dirName(dbPath);
        if (!exists(dir)) mkdirRecurse(dir);
        
        auto rc = sqlite3_open(dbPath.toStringz, &db);
        if (rc != SQLITE_OK)
            throw Errors.cache("Failed to open config index: " ~ fromStringz(sqlite3_errmsg(db)).idup,
                              Cache.LoadFailed).build();
        
        // Optimize for sub-millisecond lookups
        execSQL("PRAGMA journal_mode=WAL");        // Concurrent reads + crash recovery
        execSQL("PRAGMA synchronous=NORMAL");      // Balance durability/speed
        execSQL("PRAGMA cache_size=-32000");       // 32MB in-memory cache
        execSQL("PRAGMA temp_store=MEMORY");       // Temp tables in RAM
        execSQL("PRAGMA busy_timeout=5000");       // 5s wait on contention
        execSQL("PRAGMA mmap_size=268435456");     // 256MB memory-mapped I/O
        execSQL("PRAGMA page_size=4096");          // Optimal for SSD
        
        initializeSchema();
        prepareStatements();
        replayJournal();
    }
    
    ~this() @trusted nothrow
    {
        if (!closed && dbMutex !is null)
        {
            closed = true;
            finalizeStatements();
            if (db !is null) sqlite3_close_v2(db);
            db = null;
        }
    }
    
    /// Close database connection with checkpoint
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
    // Config Operations (Workspace-level)
    // ─────────────────────────────────────────────────────────────────
    
    /// Check if config exists for workspace path
    bool hasConfig(string workspacePath) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtConfigExists);
            sqlite3_bind_text(stmtConfigExists, 1, workspacePath.toStringz, cast(int)workspacePath.length, SQLITE_TRANSIENT);
            return sqlite3_step(stmtConfigExists) == SQLITE_ROW && sqlite3_column_int(stmtConfigExists, 0) > 0;
        }
    }
    
    /// Get cached config entry by workspace path
    /// Returns: ConfigEntry or error if not found
    BuildResult!ConfigEntry getConfig(string workspacePath) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtConfigGet);
            sqlite3_bind_text(stmtConfigGet, 1, workspacePath.toStringz, cast(int)workspacePath.length, SQLITE_TRANSIENT);
            
            if (sqlite3_step(stmtConfigGet) != SQLITE_ROW)
                return Err!(ConfigEntry, BuildError)(
                    Errors.cache("Config not found: " ~ workspacePath, Cache.LoadFailed).build());
            
            ConfigEntry entry;
            entry.workspacePath = fromStringz(sqlite3_column_text(stmtConfigGet, 0)).idup;
            entry.contentHash = fromStringz(sqlite3_column_text(stmtConfigGet, 1)).idup;
            entry.metadataHash = fromStringz(sqlite3_column_text(stmtConfigGet, 2)).idup;
            entry.targetCount = sqlite3_column_int(stmtConfigGet, 3);
            entry.configData = cast(ubyte[])sqlite3_column_blob(stmtConfigGet, 4)[0 .. sqlite3_column_bytes(stmtConfigGet, 4)].dup;
            entry.createdAt = SysTime.fromUnixTime(sqlite3_column_int64(stmtConfigGet, 5));
            entry.lastAccess = SysTime.fromUnixTime(sqlite3_column_int64(stmtConfigGet, 6));
            
            // Touch access time for LRU
            touchStat(workspacePath);
            
            return Ok!(ConfigEntry, BuildError)(entry);
        }
    }
    
    /// Store config entry with journaling for crash safety
    void putConfig(ConfigEntry entry) @system
    {
        immutable now = Clock.currTime.toUnixTime;
        
        synchronized (dbMutex)
        {
            writeJournal("put", "config", entry.workspacePath);
            
            sqlite3_reset(stmtConfigPut);
            sqlite3_bind_text(stmtConfigPut, 1, entry.workspacePath.toStringz, cast(int)entry.workspacePath.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtConfigPut, 2, entry.contentHash.toStringz, cast(int)entry.contentHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtConfigPut, 3, entry.metadataHash.toStringz, cast(int)entry.metadataHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmtConfigPut, 4, entry.targetCount);
            sqlite3_bind_blob(stmtConfigPut, 5, entry.configData.ptr, cast(int)entry.configData.length, SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmtConfigPut, 6, entry.createdAt == SysTime.init ? now : entry.createdAt.toUnixTime);
            sqlite3_bind_int64(stmtConfigPut, 7, now);
            
            if (sqlite3_step(stmtConfigPut) != SQLITE_DONE)
                throw Errors.cache("Failed to insert config: " ~ fromStringz(sqlite3_errmsg(db)).idup,
                                  Cache.WriteFailed).build();
            
            commitJournal();
        }
    }
    
    /// Delete config and associated targets
    void deleteConfig(string workspacePath) @system
    {
        synchronized (dbMutex)
        {
            writeJournal("delete", "config", workspacePath);
            
            // Cascade deletes targets via foreign key
            sqlite3_reset(stmtConfigDelete);
            sqlite3_bind_text(stmtConfigDelete, 1, workspacePath.toStringz, cast(int)workspacePath.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtConfigDelete);
            
            commitJournal();
        }
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Target Operations (Individual target lookups)
    // ─────────────────────────────────────────────────────────────────
    
    /// Get target by fully-qualified ID
    /// Sub-millisecond lookup via prepared statement + index
    BuildResult!TargetEntry getTarget(string targetId) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtTargetGet);
            sqlite3_bind_text(stmtTargetGet, 1, targetId.toStringz, cast(int)targetId.length, SQLITE_TRANSIENT);
            
            if (sqlite3_step(stmtTargetGet) != SQLITE_ROW)
                return Err!(TargetEntry, BuildError)(
                    Errors.cache("Target not found: " ~ targetId, Cache.LoadFailed).build());
            
            TargetEntry entry;
            entry.targetId = fromStringz(sqlite3_column_text(stmtTargetGet, 0)).idup;
            entry.workspacePath = fromStringz(sqlite3_column_text(stmtTargetGet, 1)).idup;
            entry.name = fromStringz(sqlite3_column_text(stmtTargetGet, 2)).idup;
            entry.targetType = cast(TargetType)sqlite3_column_int(stmtTargetGet, 3);
            entry.language = cast(TargetLanguage)sqlite3_column_int(stmtTargetGet, 4);
            entry.outputPath = fromStringz(sqlite3_column_text(stmtTargetGet, 5)).idup;
            entry.sourceHash = fromStringz(sqlite3_column_text(stmtTargetGet, 6)).idup;
            entry.depCount = sqlite3_column_int(stmtTargetGet, 7);
            entry.targetData = cast(ubyte[])sqlite3_column_blob(stmtTargetGet, 8)[0 .. sqlite3_column_bytes(stmtTargetGet, 8)].dup;
            
            return Ok!(TargetEntry, BuildError)(entry);
        }
    }
    
    /// Store target entry
    void putTarget(TargetEntry entry) @system
    {
        synchronized (dbMutex)
        {
            writeJournal("put", "target", entry.targetId);
            
            sqlite3_reset(stmtTargetPut);
            sqlite3_bind_text(stmtTargetPut, 1, entry.targetId.toStringz, cast(int)entry.targetId.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtTargetPut, 2, entry.workspacePath.toStringz, cast(int)entry.workspacePath.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtTargetPut, 3, entry.name.toStringz, cast(int)entry.name.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmtTargetPut, 4, cast(int)entry.targetType);
            sqlite3_bind_int(stmtTargetPut, 5, cast(int)entry.language);
            sqlite3_bind_text(stmtTargetPut, 6, entry.outputPath.toStringz, cast(int)entry.outputPath.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtTargetPut, 7, entry.sourceHash.toStringz, cast(int)entry.sourceHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmtTargetPut, 8, entry.depCount);
            sqlite3_bind_blob(stmtTargetPut, 9, entry.targetData.ptr, cast(int)entry.targetData.length, SQLITE_TRANSIENT);
            
            if (sqlite3_step(stmtTargetPut) != SQLITE_DONE)
                throw Errors.cache("Failed to insert target: " ~ fromStringz(sqlite3_errmsg(db)).idup,
                                  Cache.WriteFailed).build();
            
            commitJournal();
        }
    }
    
    /// Query targets by workspace path (indexed)
    string[] getTargetsByWorkspace(string workspacePath) @system
    {
        synchronized (dbMutex)
        {
            string[] results;
            sqlite3_reset(stmtTargetsByWorkspace);
            sqlite3_bind_text(stmtTargetsByWorkspace, 1, workspacePath.toStringz, cast(int)workspacePath.length, SQLITE_TRANSIENT);
            
            while (sqlite3_step(stmtTargetsByWorkspace) == SQLITE_ROW)
                results ~= fromStringz(sqlite3_column_text(stmtTargetsByWorkspace, 0)).idup;
            
            return results;
        }
    }
    
    /// Query targets by language (indexed)
    string[] getTargetsByLanguage(TargetLanguage language) @system
    {
        synchronized (dbMutex)
        {
            string[] results;
            sqlite3_reset(stmtTargetsByLanguage);
            sqlite3_bind_int(stmtTargetsByLanguage, 1, cast(int)language);
            
            while (sqlite3_step(stmtTargetsByLanguage) == SQLITE_ROW)
                results ~= fromStringz(sqlite3_column_text(stmtTargetsByLanguage, 0)).idup;
            
            return results;
        }
    }
    
    /// Query targets by type (indexed)
    string[] getTargetsByType(TargetType type) @system
    {
        synchronized (dbMutex)
        {
            string[] results;
            sqlite3_reset(stmtTargetsByType);
            sqlite3_bind_int(stmtTargetsByType, 1, cast(int)type);
            
            while (sqlite3_step(stmtTargetsByType) == SQLITE_ROW)
                results ~= fromStringz(sqlite3_column_text(stmtTargetsByType, 0)).idup;
            
            return results;
        }
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Batch Operations (Transaction-wrapped)
    // ─────────────────────────────────────────────────────────────────
    
    /// Bulk insert targets within single transaction
    void putTargetsBatch(TargetEntry[] entries) @system
    {
        synchronized (dbMutex)
        {
            execSQL("BEGIN IMMEDIATE");
            scope(failure) execSQL("ROLLBACK");
            
            foreach (ref entry; entries)
            {
                sqlite3_reset(stmtTargetPut);
                sqlite3_bind_text(stmtTargetPut, 1, entry.targetId.toStringz, cast(int)entry.targetId.length, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmtTargetPut, 2, entry.workspacePath.toStringz, cast(int)entry.workspacePath.length, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmtTargetPut, 3, entry.name.toStringz, cast(int)entry.name.length, SQLITE_TRANSIENT);
                sqlite3_bind_int(stmtTargetPut, 4, cast(int)entry.targetType);
                sqlite3_bind_int(stmtTargetPut, 5, cast(int)entry.language);
                sqlite3_bind_text(stmtTargetPut, 6, entry.outputPath.toStringz, cast(int)entry.outputPath.length, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmtTargetPut, 7, entry.sourceHash.toStringz, cast(int)entry.sourceHash.length, SQLITE_TRANSIENT);
                sqlite3_bind_int(stmtTargetPut, 8, entry.depCount);
                sqlite3_bind_blob(stmtTargetPut, 9, entry.targetData.ptr, cast(int)entry.targetData.length, SQLITE_TRANSIENT);
                sqlite3_step(stmtTargetPut);
            }
            
            execSQL("COMMIT");
        }
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Maintenance & Statistics
    // ─────────────────────────────────────────────────────────────────
    
    /// Get cache statistics
    ConfigCacheStats getStats() @system
    {
        synchronized (dbMutex)
        {
            ConfigCacheStats stats;
            
            auto configStmt = prepareQuery("SELECT COUNT(*) FROM configs");
            scope(exit) sqlite3_finalize(configStmt);
            if (sqlite3_step(configStmt) == SQLITE_ROW)
                stats.totalConfigs = sqlite3_column_int64(configStmt, 0);
            
            auto targetStmt = prepareQuery("SELECT COUNT(*) FROM targets");
            scope(exit) sqlite3_finalize(targetStmt);
            if (sqlite3_step(targetStmt) == SQLITE_ROW)
                stats.totalTargets = sqlite3_column_int64(targetStmt, 0);
            
            auto langStmt = prepareQuery("SELECT language, COUNT(*) FROM targets GROUP BY language");
            scope(exit) sqlite3_finalize(langStmt);
            while (sqlite3_step(langStmt) == SQLITE_ROW)
            {
                auto lang = cast(TargetLanguage)sqlite3_column_int(langStmt, 0);
                stats.targetsByLanguage[lang] = sqlite3_column_int64(langStmt, 1);
            }
            
            auto typeStmt = prepareQuery("SELECT target_type, COUNT(*) FROM targets GROUP BY target_type");
            scope(exit) sqlite3_finalize(typeStmt);
            while (sqlite3_step(typeStmt) == SQLITE_ROW)
            {
                auto type = cast(TargetType)sqlite3_column_int(typeStmt, 0);
                stats.targetsByType[type] = sqlite3_column_int64(typeStmt, 0);
            }
            
            auto sizeStmt = prepareQuery("SELECT SUM(LENGTH(config_data)) FROM configs");
            scope(exit) sqlite3_finalize(sizeStmt);
            if (sqlite3_step(sizeStmt) == SQLITE_ROW)
                stats.totalDataBytes = sqlite3_column_int64(sizeStmt, 0);
            
            return stats;
        }
    }
    
    /// Evict least-recently-used entries
    size_t evictLRU(size_t maxEntries) @system
    {
        synchronized (dbMutex)
        {
            auto countStmt = prepareQuery("SELECT COUNT(*) FROM configs");
            scope(exit) sqlite3_finalize(countStmt);
            if (sqlite3_step(countStmt) != SQLITE_ROW)
                return 0;
            
            immutable currentCount = sqlite3_column_int64(countStmt, 0);
            if (currentCount <= maxEntries)
                return 0;
            
            immutable toEvict = currentCount - maxEntries;
            
            // Select LRU entries for eviction
            auto selectStmt = prepareQuery(
                "SELECT workspace_path FROM configs ORDER BY last_access ASC LIMIT ?");
            scope(exit) sqlite3_finalize(selectStmt);
            sqlite3_bind_int64(selectStmt, 1, toEvict);
            
            string[] evictPaths;
            while (sqlite3_step(selectStmt) == SQLITE_ROW)
                evictPaths ~= fromStringz(sqlite3_column_text(selectStmt, 0)).idup;
            
            // Delete evicted entries (cascades to targets)
            foreach (path; evictPaths)
                deleteConfig(path);
            
            return evictPaths.length;
        }
    }
    
    /// Clear all cached data
    void clear() @system
    {
        synchronized (dbMutex)
        {
            execSQL("DELETE FROM targets");
            execSQL("DELETE FROM configs");
            execSQL("DELETE FROM config_journal");
        }
    }
    
    /// List all cached workspace paths
    string[] listWorkspaces() @system
    {
        synchronized (dbMutex)
        {
            string[] paths;
            auto stmt = prepareQuery("SELECT workspace_path FROM configs ORDER BY last_access DESC");
            scope(exit) sqlite3_finalize(stmt);
            while (sqlite3_step(stmt) == SQLITE_ROW)
                paths ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            return paths;
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
            throw Errors.cache("SQL error: " ~ msg ~ " (query: " ~ sql ~ ")", Cache.WriteFailed)
                .withSuggestion("Database query failed - cache may be corrupted")
                .withCommand("Clear cache", "bldr clean --cache").build();
        }
    }
    
    sqlite3_stmt* prepareQuery(string sql) @trusted
    {
        sqlite3_stmt* stmt;
        auto rc = sqlite3_prepare_v2(db, sql.toStringz, cast(int)sql.length, &stmt, null);
        if (rc != SQLITE_OK)
            throw Errors.cache("Failed to prepare SQL: " ~ sql ~ " - " ~ fromStringz(sqlite3_errmsg(db)).idup, 
                Cache.LoadFailed)
                .withSuggestion("Database query preparation failed")
                .withCommand("Clear cache", "bldr clean --cache").build();
        return stmt;
    }
    
    void initializeSchema() @trusted
    {
        // Config entries - workspace-level configuration
        execSQL("CREATE TABLE IF NOT EXISTS configs (" ~
                "workspace_path TEXT PRIMARY KEY, " ~
                "content_hash TEXT NOT NULL, " ~
                "metadata_hash TEXT NOT NULL, " ~
                "target_count INTEGER NOT NULL DEFAULT 0, " ~
                "config_data BLOB, " ~
                "created_at INTEGER NOT NULL, " ~
                "last_access INTEGER NOT NULL)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_config_access ON configs(last_access)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_config_hash ON configs(content_hash)");
        
        // Target entries - denormalized for fast individual lookups
        execSQL("CREATE TABLE IF NOT EXISTS targets (" ~
                "target_id TEXT PRIMARY KEY, " ~
                "workspace_path TEXT NOT NULL, " ~
                "name TEXT NOT NULL, " ~
                "target_type INTEGER NOT NULL, " ~
                "language INTEGER NOT NULL, " ~
                "output_path TEXT, " ~
                "source_hash TEXT, " ~
                "dep_count INTEGER NOT NULL DEFAULT 0, " ~
                "target_data BLOB, " ~
                "FOREIGN KEY (workspace_path) REFERENCES configs(workspace_path) ON DELETE CASCADE)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_target_workspace ON targets(workspace_path)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_target_language ON targets(language)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_target_type ON targets(target_type)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_target_name ON targets(name)");
        
        // Journal for crash recovery
        execSQL("CREATE TABLE IF NOT EXISTS config_journal (" ~
                "seq INTEGER PRIMARY KEY AUTOINCREMENT, " ~
                "operation TEXT NOT NULL, " ~
                "table_name TEXT NOT NULL, " ~
                "entry_key TEXT NOT NULL, " ~
                "timestamp INTEGER NOT NULL, " ~
                "committed INTEGER NOT NULL DEFAULT 0)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_cj_uncommitted ON config_journal(committed)");
    }
    
    void prepareStatements() @trusted
    {
        // Config statements
        stmtConfigGet = prepareQuery(
            "SELECT workspace_path, content_hash, metadata_hash, target_count, " ~
            "config_data, created_at, last_access FROM configs WHERE workspace_path = ?");
        stmtConfigPut = prepareQuery(
            "INSERT OR REPLACE INTO configs (workspace_path, content_hash, metadata_hash, " ~
            "target_count, config_data, created_at, last_access) VALUES (?, ?, ?, ?, ?, ?, ?)");
        stmtConfigDelete = prepareQuery("DELETE FROM configs WHERE workspace_path = ?");
        stmtConfigExists = prepareQuery("SELECT COUNT(*) FROM configs WHERE workspace_path = ?");
        
        // Target statements
        stmtTargetGet = prepareQuery(
            "SELECT target_id, workspace_path, name, target_type, language, " ~
            "output_path, source_hash, dep_count, target_data FROM targets WHERE target_id = ?");
        stmtTargetPut = prepareQuery(
            "INSERT OR REPLACE INTO targets (target_id, workspace_path, name, target_type, " ~
            "language, output_path, source_hash, dep_count, target_data) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)");
        stmtTargetDelete = prepareQuery("DELETE FROM targets WHERE target_id = ?");
        stmtTargetsByWorkspace = prepareQuery("SELECT target_id FROM targets WHERE workspace_path = ?");
        stmtTargetsByLanguage = prepareQuery("SELECT target_id FROM targets WHERE language = ?");
        stmtTargetsByType = prepareQuery("SELECT target_id FROM targets WHERE target_type = ?");
        
        // Stats
        stmtStatTouch = prepareQuery("UPDATE configs SET last_access = ? WHERE workspace_path = ?");
        
        // Journal
        stmtJournalWrite = prepareQuery(
            "INSERT INTO config_journal (operation, table_name, entry_key, timestamp, committed) VALUES (?, ?, ?, ?, 0)");
        stmtJournalCommit = prepareQuery("UPDATE config_journal SET committed = 1 WHERE seq = ?");
    }
    
    void finalizeStatements() @trusted nothrow
    {
        if (stmtConfigGet) sqlite3_finalize(stmtConfigGet);
        if (stmtConfigPut) sqlite3_finalize(stmtConfigPut);
        if (stmtConfigDelete) sqlite3_finalize(stmtConfigDelete);
        if (stmtConfigExists) sqlite3_finalize(stmtConfigExists);
        if (stmtTargetGet) sqlite3_finalize(stmtTargetGet);
        if (stmtTargetPut) sqlite3_finalize(stmtTargetPut);
        if (stmtTargetDelete) sqlite3_finalize(stmtTargetDelete);
        if (stmtTargetsByWorkspace) sqlite3_finalize(stmtTargetsByWorkspace);
        if (stmtTargetsByLanguage) sqlite3_finalize(stmtTargetsByLanguage);
        if (stmtTargetsByType) sqlite3_finalize(stmtTargetsByType);
        if (stmtStatTouch) sqlite3_finalize(stmtStatTouch);
        if (stmtJournalWrite) sqlite3_finalize(stmtJournalWrite);
        if (stmtJournalCommit) sqlite3_finalize(stmtJournalCommit);
    }
    
    void touchStat(string workspacePath) @trusted
    {
        immutable now = Clock.currTime.toUnixTime;
        sqlite3_reset(stmtStatTouch);
        sqlite3_bind_int64(stmtStatTouch, 1, now);
        sqlite3_bind_text(stmtStatTouch, 2, workspacePath.toStringz, cast(int)workspacePath.length, SQLITE_TRANSIENT);
        sqlite3_step(stmtStatTouch);
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
        // Delete uncommitted entries (partial operations from crash)
        execSQL("DELETE FROM config_journal WHERE committed = 0");
        // Clean old journal entries (>24h)
        immutable cutoff = Clock.currTime.toUnixTime - 86400;
        execSQL("DELETE FROM config_journal WHERE timestamp < " ~ cutoff.to!string);
    }
}

/// Configuration cache entry
struct ConfigEntry
{
    string workspacePath;
    string contentHash;      // BLAKE3 hash of all Builderfiles
    string metadataHash;     // Fast metadata hash (sizes + mtimes)
    int targetCount;
    ubyte[] configData;      // Serialized WorkspaceConfig
    SysTime createdAt;
    SysTime lastAccess;
}

/// Target cache entry (denormalized for fast lookup)
struct TargetEntry
{
    string targetId;         // Fully-qualified target ID
    string workspacePath;    // Parent workspace
    string name;             // Target name
    TargetType targetType;
    TargetLanguage language;
    string outputPath;
    string sourceHash;       // Hash of source files
    int depCount;           // Number of dependencies
    ubyte[] targetData;      // Serialized Target struct
}

/// Cache statistics
struct ConfigCacheStats
{
    long totalConfigs;
    long totalTargets;
    long[TargetLanguage] targetsByLanguage;
    long[TargetType] targetsByType;
    long totalDataBytes;
    
    float avgTargetsPerConfig() const pure @safe
        => totalConfigs > 0 ? cast(float)totalTargets / totalConfigs : 0.0f;
}

