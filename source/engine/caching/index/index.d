module engine.caching.index.index;

import std.datetime : Clock, SysTime;
import std.conv : to;
import std.file : exists, mkdirRecurse;
import std.path : buildPath, dirName;
import std.algorithm : map, filter, canFind;
import std.array : array, split;
import std.string : toStringz, fromStringz, strip;
import core.sync.mutex : Mutex;
import engine.caching.index.sqlite;
import infrastructure.errors;

/// SQLite-backed cache index providing:
/// - Efficient partial queries (SELECT WHERE)
/// - LRU tracking without full cache load
/// - WAL-based crash recovery
/// - Cache introspection
/// 
/// Design: Index lives alongside binary data files
/// - index.db: SQLite with metadata/index
/// - cache.bin: Binary data (unchanged)
/// - actions.bin: Binary data (unchanged)
final class CacheIndex
{
    private sqlite3* db;
    private Mutex dbMutex;
    private string dbPath;
    private bool closed;
    
    // Prepared statements for performance
    private sqlite3_stmt* stmtTargetGet;
    private sqlite3_stmt* stmtTargetPut;
    private sqlite3_stmt* stmtTargetDelete;
    private sqlite3_stmt* stmtTargetUpdateAccess;
    private sqlite3_stmt* stmtActionGet;
    private sqlite3_stmt* stmtActionPut;
    private sqlite3_stmt* stmtActionDelete;
    private sqlite3_stmt* stmtActionUpdateAccess;
    private sqlite3_stmt* stmtJournalWrite;
    private sqlite3_stmt* stmtJournalCommit;
    private sqlite3_stmt* stmtStatIncrement;

    /// Initialize cache index with SQLite database
    this(string cacheDir = ".builder-cache") @system
    {
        this.dbMutex = new Mutex();
        this.dbPath = buildPath(cacheDir, "index.db");
        
        // Ensure directory exists
        auto dir = dirName(dbPath);
        if (!exists(dir)) mkdirRecurse(dir);
        
        // Open database with WAL mode
        auto rc = sqlite3_open(dbPath.toStringz, &db);
        if (rc != SQLITE_OK)
            throw Errors.cache("Failed to open cache index: " ~ fromStringz(sqlite3_errmsg(db)).idup, 
                              ErrorCode.CacheLoadFailed).build();
        
        // Enable WAL mode for crash recovery and concurrent reads
        execSQL("PRAGMA journal_mode=WAL");
        execSQL("PRAGMA synchronous=NORMAL");
        execSQL("PRAGMA cache_size=-64000");  // 64MB cache
        execSQL("PRAGMA temp_store=MEMORY");
        execSQL("PRAGMA busy_timeout=5000");  // 5 second busy timeout
        
        // Initialize schema
        initializeSchema();
        
        // Prepare statements
        prepareStatements();
        
        // Replay any uncommitted journal entries
        replayJournal();
    }
    
    ~this() @trusted nothrow {
        // Don't call close() during GC - the mutex may already be finalized
        // Destructor is for emergency cleanup only; prefer explicit close() calls
        if (!closed && dbMutex !is null) {
            closed = true;
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
            
            // Finalize prepared statements
            finalizeStatements();
            
            // Checkpoint WAL
            sqlite3_wal_checkpoint_v2(db, null, SQLITE_CHECKPOINT_TRUNCATE, null, null);
            
            sqlite3_close(db);
            closed = true;
        }
    }
    
    // ─────────────────────────────────────────────────────────────────
    // Target Entry Operations
    // ─────────────────────────────────────────────────────────────────
    
    /// Check if target entry exists
    bool hasTarget(string key) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtTargetGet);
            sqlite3_bind_text(stmtTargetGet, 1, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            return sqlite3_step(stmtTargetGet) == SQLITE_ROW;
        }
    }
    
    /// Get target entry metadata
    BuildResult!TargetIndexEntry getTarget(string key) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtTargetGet);
            sqlite3_bind_text(stmtTargetGet, 1, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            
            if (sqlite3_step(stmtTargetGet) != SQLITE_ROW)
                return Err!(TargetIndexEntry, BuildError)(
                    Errors.cache("Target not found: " ~ key, ErrorCode.CacheNotFound).build());
            
            TargetIndexEntry entry;
            entry.key = fromStringz(sqlite3_column_text(stmtTargetGet, 0)).idup;
            entry.contentHash = fromStringz(sqlite3_column_text(stmtTargetGet, 1)).idup;
            entry.metadataHash = fromStringz(sqlite3_column_text(stmtTargetGet, 2)).idup;
            entry.size = sqlite3_column_int64(stmtTargetGet, 3);
            entry.createdAt = SysTime.fromUnixTime(sqlite3_column_int64(stmtTargetGet, 4));
            entry.lastAccess = SysTime.fromUnixTime(sqlite3_column_int64(stmtTargetGet, 5));
            
            return Ok!(TargetIndexEntry, BuildError)(entry);
        }
    }
    
    /// Insert or update target entry
    void putTarget(TargetIndexEntry entry) @system
    {
        immutable now = Clock.currTime.toUnixTime;
        
        synchronized (dbMutex)
        {
            // Write to journal first (uncommitted)
            writeJournal("put", "target", entry.key);
            
            sqlite3_reset(stmtTargetPut);
            sqlite3_bind_text(stmtTargetPut, 1, entry.key.toStringz, cast(int)entry.key.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtTargetPut, 2, entry.contentHash.toStringz, cast(int)entry.contentHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtTargetPut, 3, entry.metadataHash.toStringz, cast(int)entry.metadataHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmtTargetPut, 4, entry.size);
            sqlite3_bind_int64(stmtTargetPut, 5, entry.createdAt == SysTime.init ? now : entry.createdAt.toUnixTime);
            sqlite3_bind_int64(stmtTargetPut, 6, now);
            sqlite3_bind_int(stmtTargetPut, 7, cast(int)entry.sourceCount);
            sqlite3_bind_int(stmtTargetPut, 8, cast(int)entry.depCount);
            
            if (sqlite3_step(stmtTargetPut) != SQLITE_DONE)
                throw Errors.cache("Failed to insert target: " ~ fromStringz(sqlite3_errmsg(db)).idup,
                                  ErrorCode.CacheWriteFailed).build();
            
            // Mark journal entry as committed
            commitJournal();
        }
    }
    
    /// Delete target entry
    void deleteTarget(string key) @system
    {
        synchronized (dbMutex)
        {
            writeJournal("delete", "target", key);
            
            sqlite3_reset(stmtTargetDelete);
            sqlite3_bind_text(stmtTargetDelete, 1, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtTargetDelete);
            
            commitJournal();
        }
    }
    
    /// Update last access time (for LRU tracking)
    void touchTarget(string key) @system
    {
        immutable now = Clock.currTime.toUnixTime;
        
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtTargetUpdateAccess);
            sqlite3_bind_int64(stmtTargetUpdateAccess, 1, now);
            sqlite3_bind_text(stmtTargetUpdateAccess, 2, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtTargetUpdateAccess);
        }
    }
    
    /// Select targets for eviction using LRU policy
    string[] selectTargetEvictions(size_t maxEntries, size_t maxSize, size_t maxAgeDays) @system
    {
        synchronized (dbMutex)
        {
            string[] toEvict;
            immutable cutoffTime = Clock.currTime.toUnixTime - (maxAgeDays * 86400);
            
            // Get expired entries
            auto stmt1 = prepareQuery("SELECT key FROM target_entries WHERE created_at < ?");
            scope(exit) sqlite3_finalize(stmt1);
            sqlite3_bind_int64(stmt1, 1, cutoffTime);
            while (sqlite3_step(stmt1) == SQLITE_ROW)
                toEvict ~= fromStringz(sqlite3_column_text(stmt1, 0)).idup;
            
            // Get entries exceeding count limit (LRU order)
            auto stmt2 = prepareQuery(
                "SELECT key FROM target_entries ORDER BY last_access ASC " ~
                "LIMIT (SELECT MAX(0, COUNT(*) - ?) FROM target_entries)");
            scope(exit) sqlite3_finalize(stmt2);
            sqlite3_bind_int64(stmt2, 1, cast(long)maxEntries);
            while (sqlite3_step(stmt2) == SQLITE_ROW)
            {
                auto key = fromStringz(sqlite3_column_text(stmt2, 0)).idup;
                if (!toEvict.canFind(key)) toEvict ~= key;
            }
            
            return toEvict;
        }
    }
    
    /// Get target cache statistics
    TargetCacheStats getTargetStats() @system
    {
        synchronized (dbMutex)
        {
            TargetCacheStats stats;
            
            auto stmt = prepareQuery(
                "SELECT COUNT(*), COALESCE(SUM(size), 0), MIN(created_at), MAX(created_at) FROM target_entries");
            scope(exit) sqlite3_finalize(stmt);
            
            if (sqlite3_step(stmt) == SQLITE_ROW)
            {
                stats.totalEntries = sqlite3_column_int64(stmt, 0);
                stats.totalSize = sqlite3_column_int64(stmt, 1);
                auto minTime = sqlite3_column_int64(stmt, 2);
                auto maxTime = sqlite3_column_int64(stmt, 3);
                if (minTime > 0) stats.oldestEntry = SysTime.fromUnixTime(minTime);
                if (maxTime > 0) stats.newestEntry = SysTime.fromUnixTime(maxTime);
            }
            
            stats.hits = getStat("target_hits");
            stats.misses = getStat("target_misses");
            
            return stats;
        }
    }
    
    /// Increment target hit counter
    void recordTargetHit() @system { incrementStat("target_hits"); }
    
    /// Increment target miss counter
    void recordTargetMiss() @system { incrementStat("target_misses"); }
    
    // ─────────────────────────────────────────────────────────────────
    // Action Entry Operations
    // ─────────────────────────────────────────────────────────────────
    
    /// Check if action entry exists
    bool hasAction(string key) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtActionGet);
            sqlite3_bind_text(stmtActionGet, 1, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            return sqlite3_step(stmtActionGet) == SQLITE_ROW;
        }
    }
    
    /// Get action entry metadata
    BuildResult!ActionIndexEntry getAction(string key) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtActionGet);
            sqlite3_bind_text(stmtActionGet, 1, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            
            if (sqlite3_step(stmtActionGet) != SQLITE_ROW)
                return Err!(ActionIndexEntry, BuildError)(
                    Errors.cache("Action not found: " ~ key, ErrorCode.CacheNotFound).build());
            
            ActionIndexEntry entry;
            entry.key = fromStringz(sqlite3_column_text(stmtActionGet, 0)).idup;
            entry.targetId = fromStringz(sqlite3_column_text(stmtActionGet, 1)).idup;
            entry.actionType = cast(ubyte)sqlite3_column_int(stmtActionGet, 2);
            entry.contentHash = fromStringz(sqlite3_column_text(stmtActionGet, 3)).idup;
            entry.size = sqlite3_column_int64(stmtActionGet, 4);
            entry.createdAt = SysTime.fromUnixTime(sqlite3_column_int64(stmtActionGet, 5));
            entry.lastAccess = SysTime.fromUnixTime(sqlite3_column_int64(stmtActionGet, 6));
            entry.success = sqlite3_column_int(stmtActionGet, 7) != 0;
            
            return Ok!(ActionIndexEntry, BuildError)(entry);
        }
    }
    
    /// Insert or update action entry
    void putAction(ActionIndexEntry entry) @system
    {
        immutable now = Clock.currTime.toUnixTime;
        
        synchronized (dbMutex)
        {
            writeJournal("put", "action", entry.key);
            
            sqlite3_reset(stmtActionPut);
            sqlite3_bind_text(stmtActionPut, 1, entry.key.toStringz, cast(int)entry.key.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtActionPut, 2, entry.targetId.toStringz, cast(int)entry.targetId.length, SQLITE_TRANSIENT);
            sqlite3_bind_int(stmtActionPut, 3, entry.actionType);
            sqlite3_bind_text(stmtActionPut, 4, entry.contentHash.toStringz, cast(int)entry.contentHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmtActionPut, 5, entry.size);
            sqlite3_bind_int64(stmtActionPut, 6, entry.createdAt == SysTime.init ? now : entry.createdAt.toUnixTime);
            sqlite3_bind_int64(stmtActionPut, 7, now);
            sqlite3_bind_int(stmtActionPut, 8, entry.success ? 1 : 0);
            sqlite3_bind_int(stmtActionPut, 9, cast(int)entry.inputCount);
            sqlite3_bind_int(stmtActionPut, 10, cast(int)entry.outputCount);
            
            if (sqlite3_step(stmtActionPut) != SQLITE_DONE)
                throw Errors.cache("Failed to insert action: " ~ fromStringz(sqlite3_errmsg(db)).idup,
                                  ErrorCode.CacheWriteFailed).build();
            
            commitJournal();
        }
    }
    
    /// Delete action entry
    void deleteAction(string key) @system
    {
        synchronized (dbMutex)
        {
            writeJournal("delete", "action", key);
            
            sqlite3_reset(stmtActionDelete);
            sqlite3_bind_text(stmtActionDelete, 1, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtActionDelete);
            
            commitJournal();
        }
    }
    
    /// Update last access time for action
    void touchAction(string key) @system
    {
        immutable now = Clock.currTime.toUnixTime;
        
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtActionUpdateAccess);
            sqlite3_bind_int64(stmtActionUpdateAccess, 1, now);
            sqlite3_bind_text(stmtActionUpdateAccess, 2, key.toStringz, cast(int)key.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtActionUpdateAccess);
        }
    }
    
    /// Select actions for eviction
    string[] selectActionEvictions(size_t maxEntries, size_t maxSize, size_t maxAgeDays) @system
    {
        synchronized (dbMutex)
        {
            string[] toEvict;
            immutable cutoffTime = Clock.currTime.toUnixTime - (maxAgeDays * 86400);
            
            auto stmt1 = prepareQuery("SELECT key FROM action_entries WHERE created_at < ?");
            scope(exit) sqlite3_finalize(stmt1);
            sqlite3_bind_int64(stmt1, 1, cutoffTime);
            while (sqlite3_step(stmt1) == SQLITE_ROW)
                toEvict ~= fromStringz(sqlite3_column_text(stmt1, 0)).idup;
            
            auto stmt2 = prepareQuery(
                "SELECT key FROM action_entries ORDER BY last_access ASC " ~
                "LIMIT (SELECT MAX(0, COUNT(*) - ?) FROM action_entries)");
            scope(exit) sqlite3_finalize(stmt2);
            sqlite3_bind_int64(stmt2, 1, cast(long)maxEntries);
            while (sqlite3_step(stmt2) == SQLITE_ROW)
            {
                auto key = fromStringz(sqlite3_column_text(stmt2, 0)).idup;
                if (!toEvict.canFind(key)) toEvict ~= key;
            }
            
            return toEvict;
        }
    }
    
    /// Get all actions for a target
    string[] getActionsForTarget(string targetId) @system
    {
        synchronized (dbMutex)
        {
            string[] actions;
            auto stmt = prepareQuery("SELECT key FROM action_entries WHERE target_id = ?");
            scope(exit) sqlite3_finalize(stmt);
            sqlite3_bind_text(stmt, 1, targetId.toStringz, cast(int)targetId.length, SQLITE_TRANSIENT);
            
            while (sqlite3_step(stmt) == SQLITE_ROW)
                actions ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            return actions;
        }
    }
    
    /// Get action cache statistics
    ActionCacheStats getActionStats() @system
    {
        synchronized (dbMutex)
        {
            ActionCacheStats stats;
            
            auto stmt = prepareQuery(
                "SELECT COUNT(*), COALESCE(SUM(size), 0), " ~
                "SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END), " ~
                "SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END) FROM action_entries");
            scope(exit) sqlite3_finalize(stmt);
            
            if (sqlite3_step(stmt) == SQLITE_ROW)
            {
                stats.totalEntries = sqlite3_column_int64(stmt, 0);
                stats.totalSize = sqlite3_column_int64(stmt, 1);
                stats.successfulActions = sqlite3_column_int64(stmt, 2);
                stats.failedActions = sqlite3_column_int64(stmt, 3);
            }
            
            stats.hits = getStat("action_hits");
            stats.misses = getStat("action_misses");
            
            return stats;
        }
    }
    
    /// Increment action hit counter
    void recordActionHit() @system { incrementStat("action_hits"); }
    
    /// Increment action miss counter  
    void recordActionMiss() @system { incrementStat("action_misses"); }
    
    // ─────────────────────────────────────────────────────────────────
    // Introspection API
    // ─────────────────────────────────────────────────────────────────
    
    /// List all target keys
    string[] listTargets() @system
    {
        synchronized (dbMutex)
        {
            string[] targets;
            auto stmt = prepareQuery("SELECT key FROM target_entries ORDER BY last_access DESC");
            scope(exit) sqlite3_finalize(stmt);
            while (sqlite3_step(stmt) == SQLITE_ROW)
                targets ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            return targets;
        }
    }
    
    /// List all action keys
    string[] listActions() @system
    {
        synchronized (dbMutex)
        {
            string[] actions;
            auto stmt = prepareQuery("SELECT key FROM action_entries ORDER BY last_access DESC");
            scope(exit) sqlite3_finalize(stmt);
            while (sqlite3_step(stmt) == SQLITE_ROW)
                actions ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            return actions;
        }
    }
    
    /// Query targets by partial key match
    string[] queryTargets(string pattern) @system
    {
        synchronized (dbMutex)
        {
            string[] results;
            auto stmt = prepareQuery("SELECT key FROM target_entries WHERE key LIKE ?");
            scope(exit) sqlite3_finalize(stmt);
            auto likePattern = "%" ~ pattern ~ "%";
            sqlite3_bind_text(stmt, 1, likePattern.toStringz, cast(int)likePattern.length, SQLITE_TRANSIENT);
            
            while (sqlite3_step(stmt) == SQLITE_ROW)
                results ~= fromStringz(sqlite3_column_text(stmt, 0)).idup;
            
            return results;
        }
    }
    
    /// Clear all entries (for testing or reset)
    void clear() @system
    {
        synchronized (dbMutex)
        {
            execSQL("DELETE FROM target_entries");
            execSQL("DELETE FROM action_entries");
            execSQL("DELETE FROM source_entries");
            execSQL("DELETE FROM journal");
            execSQL("UPDATE stats SET value = 0");
        }
    }
    
    /// Get total entry count (for quick checks)
    size_t totalEntryCount() @system
    {
        synchronized (dbMutex)
        {
            auto stmt = prepareQuery(
                "SELECT (SELECT COUNT(*) FROM target_entries) + (SELECT COUNT(*) FROM action_entries)");
            scope(exit) sqlite3_finalize(stmt);
            return sqlite3_step(stmt) == SQLITE_ROW ? cast(size_t)sqlite3_column_int64(stmt, 0) : 0;
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
        // Create tables individually (SQLite exec handles one statement well)
        execSQL("CREATE TABLE IF NOT EXISTS target_entries (" ~
                "key TEXT PRIMARY KEY, content_hash TEXT NOT NULL, metadata_hash TEXT, " ~
                "size INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, last_access INTEGER NOT NULL, " ~
                "source_count INTEGER DEFAULT 0, dep_count INTEGER DEFAULT 0)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_target_last_access ON target_entries(last_access)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_target_created ON target_entries(created_at)");
        
        execSQL("CREATE TABLE IF NOT EXISTS action_entries (" ~
                "key TEXT PRIMARY KEY, target_id TEXT NOT NULL, action_type INTEGER NOT NULL, " ~
                "content_hash TEXT NOT NULL, size INTEGER NOT NULL DEFAULT 0, " ~
                "created_at INTEGER NOT NULL, last_access INTEGER NOT NULL, " ~
                "success INTEGER NOT NULL DEFAULT 1, input_count INTEGER DEFAULT 0, output_count INTEGER DEFAULT 0)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_action_last_access ON action_entries(last_access)");
        execSQL("CREATE INDEX IF NOT EXISTS idx_action_target ON action_entries(target_id)");
        
        execSQL("CREATE TABLE IF NOT EXISTS source_entries (" ~
                "path TEXT PRIMARY KEY, content_hash TEXT NOT NULL, metadata_hash TEXT NOT NULL, " ~
                "size INTEGER NOT NULL, mtime INTEGER NOT NULL, last_check INTEGER NOT NULL)");
        
        execSQL("CREATE TABLE IF NOT EXISTS journal (" ~
                "seq INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT NOT NULL, " ~
                "table_name TEXT NOT NULL, entry_key TEXT NOT NULL, " ~
                "timestamp INTEGER NOT NULL, committed INTEGER NOT NULL DEFAULT 0)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_journal_uncommitted ON journal(committed)");
        
        execSQL("CREATE TABLE IF NOT EXISTS stats (" ~
                "name TEXT PRIMARY KEY, value INTEGER NOT NULL, updated_at INTEGER NOT NULL)");
        
        // Initialize default stats
        execSQL("INSERT OR IGNORE INTO stats (name, value, updated_at) VALUES ('target_hits', 0, 0)");
        execSQL("INSERT OR IGNORE INTO stats (name, value, updated_at) VALUES ('target_misses', 0, 0)");
        execSQL("INSERT OR IGNORE INTO stats (name, value, updated_at) VALUES ('action_hits', 0, 0)");
        execSQL("INSERT OR IGNORE INTO stats (name, value, updated_at) VALUES ('action_misses', 0, 0)");
    }
    
    void prepareStatements() @trusted
    {
        stmtTargetGet = prepareQuery(
            "SELECT key, content_hash, metadata_hash, size, created_at, last_access FROM target_entries WHERE key = ?");
        stmtTargetPut = prepareQuery(
            "INSERT OR REPLACE INTO target_entries (key, content_hash, metadata_hash, size, created_at, last_access, source_count, dep_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?)");
        stmtTargetDelete = prepareQuery("DELETE FROM target_entries WHERE key = ?");
        stmtTargetUpdateAccess = prepareQuery("UPDATE target_entries SET last_access = ? WHERE key = ?");
        
        stmtActionGet = prepareQuery(
            "SELECT key, target_id, action_type, content_hash, size, created_at, last_access, success FROM action_entries WHERE key = ?");
        stmtActionPut = prepareQuery(
            "INSERT OR REPLACE INTO action_entries (key, target_id, action_type, content_hash, size, created_at, last_access, success, input_count, output_count) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
        stmtActionDelete = prepareQuery("DELETE FROM action_entries WHERE key = ?");
        stmtActionUpdateAccess = prepareQuery("UPDATE action_entries SET last_access = ? WHERE key = ?");
        
        stmtJournalWrite = prepareQuery(
            "INSERT INTO journal (operation, table_name, entry_key, timestamp, committed) VALUES (?, ?, ?, ?, 0)");
        stmtJournalCommit = prepareQuery("UPDATE journal SET committed = 1 WHERE seq = ?");
        
        stmtStatIncrement = prepareQuery("UPDATE stats SET value = value + 1, updated_at = ? WHERE name = ?");
    }
    
    void finalizeStatements() @trusted nothrow
    {
        if (stmtTargetGet) sqlite3_finalize(stmtTargetGet);
        if (stmtTargetPut) sqlite3_finalize(stmtTargetPut);
        if (stmtTargetDelete) sqlite3_finalize(stmtTargetDelete);
        if (stmtTargetUpdateAccess) sqlite3_finalize(stmtTargetUpdateAccess);
        if (stmtActionGet) sqlite3_finalize(stmtActionGet);
        if (stmtActionPut) sqlite3_finalize(stmtActionPut);
        if (stmtActionDelete) sqlite3_finalize(stmtActionDelete);
        if (stmtActionUpdateAccess) sqlite3_finalize(stmtActionUpdateAccess);
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
        // For safety, delete uncommitted entries (they will be rebuilt from binary files)
        execSQL("DELETE FROM journal WHERE committed = 0");
        // Clean old journal entries
        immutable cutoff = Clock.currTime.toUnixTime - 86400;
        execSQL("DELETE FROM journal WHERE timestamp < " ~ cutoff.to!string);
    }
    
    long getStat(string name) @trusted
    {
        auto stmt = prepareQuery("SELECT value FROM stats WHERE name = ?");
        scope(exit) sqlite3_finalize(stmt);
        sqlite3_bind_text(stmt, 1, name.toStringz, cast(int)name.length, SQLITE_TRANSIENT);
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0;
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

/// Target index entry (metadata only - data lives in binary file)
struct TargetIndexEntry
{
    string key;
    string contentHash;
    string metadataHash;
    long size;
    SysTime createdAt;
    SysTime lastAccess;
    size_t sourceCount;
    size_t depCount;
}

/// Action index entry (metadata only - data lives in binary file)
struct ActionIndexEntry
{
    string key;
    string targetId;
    ubyte actionType;
    string contentHash;
    long size;
    SysTime createdAt;
    SysTime lastAccess;
    bool success;
    size_t inputCount;
    size_t outputCount;
}

/// Target cache statistics from index
struct TargetCacheStats
{
    long totalEntries;
    long totalSize;
    SysTime oldestEntry;
    SysTime newestEntry;
    long hits;
    long misses;
    
    float hitRate() const pure @safe
        => (hits + misses) > 0 ? (hits * 100.0f) / (hits + misses) : 0.0f;
}

/// Action cache statistics from index
struct ActionCacheStats
{
    long totalEntries;
    long totalSize;
    long hits;
    long misses;
    long successfulActions;
    long failedActions;
    
    float hitRate() const pure @safe
        => (hits + misses) > 0 ? (hits * 100.0f) / (hits + misses) : 0.0f;
}
