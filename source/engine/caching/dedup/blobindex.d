module engine.caching.dedup.blobindex;

import std.datetime : Clock;
import std.conv : to;
import std.file : exists, mkdirRecurse;
import std.path : buildPath, dirName;
import std.string : toStringz, fromStringz;
import std.algorithm : map;
import std.array : array;
import core.sync.mutex : Mutex;
import engine.caching.index.sqlite;
import infrastructure.errors;

/// SQLite-backed blob reference index
/// Tracks which actions reference which blobs for efficient GC
/// 
/// Schema:
/// - blobs: hash, size, created_at, ref_count
/// - blob_refs: blob_hash, action_id (many-to-many)
/// 
/// Benefits:
/// - O(1) reference count updates
/// - Efficient orphan detection for GC
/// - Persistent across restarts
final class BlobIndex
{
    private sqlite3* db;
    private Mutex dbMutex;
    private string dbPath;
    private bool closed;
    
    // Prepared statements
    private sqlite3_stmt* stmtBlobGet;
    private sqlite3_stmt* stmtBlobPut;
    private sqlite3_stmt* stmtBlobIncRef;
    private sqlite3_stmt* stmtBlobDecRef;
    private sqlite3_stmt* stmtBlobDelete;
    private sqlite3_stmt* stmtRefAdd;
    private sqlite3_stmt* stmtRefRemove;
    private sqlite3_stmt* stmtRefGetBlobs;
    private sqlite3_stmt* stmtOrphans;
    
    this(string cacheDir = ".builder-cache/dedup") @system
    {
        this.dbMutex = new Mutex();
        this.dbPath = buildPath(cacheDir, "blobs.db");
        
        auto dir = dirName(dbPath);
        if (!exists(dir)) mkdirRecurse(dir);
        
        auto rc = sqlite3_open(dbPath.toStringz, &db);
        if (rc != SQLITE_OK)
            throw Errors.cache("Failed to open blob index: " ~ 
                fromStringz(sqlite3_errmsg(db)).idup, Cache.LoadFailed).build();
        
        // Configure for performance
        execSQL("PRAGMA journal_mode=WAL");
        execSQL("PRAGMA synchronous=NORMAL");
        execSQL("PRAGMA cache_size=-16000");  // 16MB cache
        execSQL("PRAGMA temp_store=MEMORY");
        
        initSchema();
        prepareStatements();
    }
    
    ~this() @trusted nothrow
    {
        if (!closed && dbMutex !is null)
        {
            closed = true;
            finalizeStatements();
            if (db !is null) sqlite3_close_v2(db);
        }
    }
    
    /// Register blob in index
    void putBlob(string hash, size_t size) @system
    {
        synchronized (dbMutex)
        {
            immutable now = Clock.currTime.toUnixTime;
            
            sqlite3_reset(stmtBlobPut);
            sqlite3_bind_text(stmtBlobPut, 1, hash.toStringz, cast(int)hash.length, SQLITE_TRANSIENT);
            sqlite3_bind_int64(stmtBlobPut, 2, cast(long)size);
            sqlite3_bind_int64(stmtBlobPut, 3, now);
            sqlite3_step(stmtBlobPut);
        }
    }
    
    /// Get blob metadata
    BuildResult!BlobEntry getBlob(string hash) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtBlobGet);
            sqlite3_bind_text(stmtBlobGet, 1, hash.toStringz, cast(int)hash.length, SQLITE_TRANSIENT);
            
            if (sqlite3_step(stmtBlobGet) != SQLITE_ROW)
                return Err!(BlobEntry, BuildError)(Errors.cache(
                    "Blob not found: " ~ hash, Cache.NotFound).build());
            
            BlobEntry entry;
            entry.hash = fromStringz(sqlite3_column_text(stmtBlobGet, 0)).idup;
            entry.size = cast(size_t)sqlite3_column_int64(stmtBlobGet, 1);
            entry.createdAt = sqlite3_column_int64(stmtBlobGet, 2);
            entry.refCount = cast(size_t)sqlite3_column_int64(stmtBlobGet, 3);
            
            return Ok!(BlobEntry, BuildError)(entry);
        }
    }
    
    /// Increment blob reference count
    void incRef(string hash) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtBlobIncRef);
            sqlite3_bind_text(stmtBlobIncRef, 1, hash.toStringz, cast(int)hash.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtBlobIncRef);
        }
    }
    
    /// Decrement blob reference count
    /// Returns: new reference count
    size_t decRef(string hash) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtBlobDecRef);
            sqlite3_bind_text(stmtBlobDecRef, 1, hash.toStringz, cast(int)hash.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtBlobDecRef);
            
            // Get new count
            auto result = getBlob(hash);
            return result.isOk ? result.unwrap().refCount : 0;
        }
    }
    
    /// Add action -> blob reference
    void addRef(string actionId, string blobHash) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtRefAdd);
            sqlite3_bind_text(stmtRefAdd, 1, blobHash.toStringz, cast(int)blobHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtRefAdd, 2, actionId.toStringz, cast(int)actionId.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtRefAdd);
            
            incRef(blobHash);
        }
    }
    
    /// Remove action -> blob reference
    void removeRef(string actionId, string blobHash) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtRefRemove);
            sqlite3_bind_text(stmtRefRemove, 1, blobHash.toStringz, cast(int)blobHash.length, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmtRefRemove, 2, actionId.toStringz, cast(int)actionId.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtRefRemove);
            
            decRef(blobHash);
        }
    }
    
    /// Bulk add references for action
    void addRefs(string actionId, const(string)[] blobHashes) @system
    {
        synchronized (dbMutex)
        {
            execSQL("BEGIN TRANSACTION");
            scope(failure) execSQL("ROLLBACK");
            
            foreach (hash; blobHashes)
            {
                sqlite3_reset(stmtRefAdd);
                sqlite3_bind_text(stmtRefAdd, 1, hash.toStringz, cast(int)hash.length, SQLITE_TRANSIENT);
                sqlite3_bind_text(stmtRefAdd, 2, actionId.toStringz, cast(int)actionId.length, SQLITE_TRANSIENT);
                sqlite3_step(stmtRefAdd);
                
                sqlite3_reset(stmtBlobIncRef);
                sqlite3_bind_text(stmtBlobIncRef, 1, hash.toStringz, cast(int)hash.length, SQLITE_TRANSIENT);
                sqlite3_step(stmtBlobIncRef);
            }
            
            execSQL("COMMIT");
        }
    }
    
    /// Get all blobs referenced by action
    string[] getBlobsForAction(string actionId) @system
    {
        synchronized (dbMutex)
        {
            string[] hashes;
            
            sqlite3_reset(stmtRefGetBlobs);
            sqlite3_bind_text(stmtRefGetBlobs, 1, actionId.toStringz, cast(int)actionId.length, SQLITE_TRANSIENT);
            
            while (sqlite3_step(stmtRefGetBlobs) == SQLITE_ROW)
                hashes ~= fromStringz(sqlite3_column_text(stmtRefGetBlobs, 0)).idup;
            
            return hashes;
        }
    }
    
    /// Find orphaned blobs (ref_count = 0)
    string[] findOrphans() @system
    {
        synchronized (dbMutex)
        {
            string[] orphans;
            
            sqlite3_reset(stmtOrphans);
            while (sqlite3_step(stmtOrphans) == SQLITE_ROW)
                orphans ~= fromStringz(sqlite3_column_text(stmtOrphans, 0)).idup;
            
            return orphans;
        }
    }
    
    /// Delete blob from index
    void deleteBlob(string hash) @system
    {
        synchronized (dbMutex)
        {
            sqlite3_reset(stmtBlobDelete);
            sqlite3_bind_text(stmtBlobDelete, 1, hash.toStringz, cast(int)hash.length, SQLITE_TRANSIENT);
            sqlite3_step(stmtBlobDelete);
        }
    }
    
    /// Get index statistics
    BlobIndexStats getStats() @system
    {
        synchronized (dbMutex)
        {
            BlobIndexStats stats;
            
            auto stmt1 = prepareQuery("SELECT COUNT(*), COALESCE(SUM(size), 0) FROM blobs");
            scope(exit) sqlite3_finalize(stmt1);
            if (sqlite3_step(stmt1) == SQLITE_ROW)
            {
                stats.totalBlobs = cast(size_t)sqlite3_column_int64(stmt1, 0);
                stats.totalSize = cast(size_t)sqlite3_column_int64(stmt1, 1);
            }
            
            auto stmt2 = prepareQuery("SELECT COUNT(*) FROM blobs WHERE ref_count = 0");
            scope(exit) sqlite3_finalize(stmt2);
            if (sqlite3_step(stmt2) == SQLITE_ROW)
                stats.orphanBlobs = cast(size_t)sqlite3_column_int64(stmt2, 0);
            
            auto stmt3 = prepareQuery("SELECT COUNT(*) FROM blob_refs");
            scope(exit) sqlite3_finalize(stmt3);
            if (sqlite3_step(stmt3) == SQLITE_ROW)
                stats.totalRefs = cast(size_t)sqlite3_column_int64(stmt3, 0);
            
            return stats;
        }
    }
    
    /// Close the index
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

private:
    void execSQL(string sql) @trusted
    {
        char* errMsg;
        auto rc = sqlite3_exec(db, sql.toStringz, null, null, &errMsg);
        if (rc != SQLITE_OK)
        {
            auto msg = errMsg ? fromStringz(errMsg).idup : "Unknown error";
            sqlite3_free(errMsg);
            throw Errors.cache("SQL error: " ~ msg, Cache.WriteFailed)
                .withCommand("Clear cache", "bldr clean --cache").build();
        }
    }
    
    sqlite3_stmt* prepareQuery(string sql) @trusted
    {
        sqlite3_stmt* stmt;
        sqlite3_prepare_v2(db, sql.toStringz, cast(int)sql.length, &stmt, null);
        return stmt;
    }
    
    void initSchema() @trusted
    {
        execSQL("CREATE TABLE IF NOT EXISTS blobs (" ~
                "hash TEXT PRIMARY KEY, size INTEGER NOT NULL, " ~
                "created_at INTEGER NOT NULL, ref_count INTEGER NOT NULL DEFAULT 0)");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_blobs_refcount ON blobs(ref_count)");
        
        execSQL("CREATE TABLE IF NOT EXISTS blob_refs (" ~
                "blob_hash TEXT NOT NULL, action_id TEXT NOT NULL, " ~
                "PRIMARY KEY (blob_hash, action_id))");
        
        execSQL("CREATE INDEX IF NOT EXISTS idx_refs_action ON blob_refs(action_id)");
    }
    
    void prepareStatements() @trusted
    {
        stmtBlobGet = prepareQuery("SELECT hash, size, created_at, ref_count FROM blobs WHERE hash = ?");
        stmtBlobPut = prepareQuery("INSERT OR IGNORE INTO blobs (hash, size, created_at, ref_count) VALUES (?, ?, ?, 0)");
        stmtBlobIncRef = prepareQuery("UPDATE blobs SET ref_count = ref_count + 1 WHERE hash = ?");
        stmtBlobDecRef = prepareQuery("UPDATE blobs SET ref_count = MAX(0, ref_count - 1) WHERE hash = ?");
        stmtBlobDelete = prepareQuery("DELETE FROM blobs WHERE hash = ?");
        stmtRefAdd = prepareQuery("INSERT OR IGNORE INTO blob_refs (blob_hash, action_id) VALUES (?, ?)");
        stmtRefRemove = prepareQuery("DELETE FROM blob_refs WHERE blob_hash = ? AND action_id = ?");
        stmtRefGetBlobs = prepareQuery("SELECT blob_hash FROM blob_refs WHERE action_id = ?");
        stmtOrphans = prepareQuery("SELECT hash FROM blobs WHERE ref_count = 0");
    }
    
    void finalizeStatements() @trusted nothrow
    {
        if (stmtBlobGet) sqlite3_finalize(stmtBlobGet);
        if (stmtBlobPut) sqlite3_finalize(stmtBlobPut);
        if (stmtBlobIncRef) sqlite3_finalize(stmtBlobIncRef);
        if (stmtBlobDecRef) sqlite3_finalize(stmtBlobDecRef);
        if (stmtBlobDelete) sqlite3_finalize(stmtBlobDelete);
        if (stmtRefAdd) sqlite3_finalize(stmtRefAdd);
        if (stmtRefRemove) sqlite3_finalize(stmtRefRemove);
        if (stmtRefGetBlobs) sqlite3_finalize(stmtRefGetBlobs);
        if (stmtOrphans) sqlite3_finalize(stmtOrphans);
    }
}

/// Blob entry metadata
struct BlobEntry
{
    string hash;
    size_t size;
    long createdAt;
    size_t refCount;
}

/// Index statistics
struct BlobIndexStats
{
    size_t totalBlobs;
    size_t totalSize;
    size_t orphanBlobs;
    size_t totalRefs;
    
    /// Average refs per blob
    float avgRefsPerBlob() const pure @safe
        => totalBlobs > 0 ? cast(float)totalRefs / totalBlobs : 0;
}

