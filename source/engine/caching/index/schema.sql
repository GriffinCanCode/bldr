-- Cache Index SQLite Schema
-- Provides efficient metadata indexing for binary cache storage
-- Uses WAL mode for crash recovery and concurrent read access

-- Schema version for migrations
PRAGMA user_version = 1;

-- Target cache entries (index for cache.bin data)
CREATE TABLE IF NOT EXISTS target_entries (
    key TEXT PRIMARY KEY,           -- Target ID
    content_hash TEXT NOT NULL,     -- Hash of build output
    metadata_hash TEXT,             -- Fast metadata hash
    size INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,    -- Unix timestamp
    last_access INTEGER NOT NULL,   -- Unix timestamp for LRU
    source_count INTEGER DEFAULT 0,
    dep_count INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_target_last_access ON target_entries(last_access);
CREATE INDEX IF NOT EXISTS idx_target_created ON target_entries(created_at);
CREATE INDEX IF NOT EXISTS idx_target_size ON target_entries(size);

-- Action cache entries (index for actions.bin data)  
CREATE TABLE IF NOT EXISTS action_entries (
    key TEXT PRIMARY KEY,           -- ActionId.toString()
    target_id TEXT NOT NULL,        -- Parent target
    action_type INTEGER NOT NULL,   -- ActionType enum
    content_hash TEXT NOT NULL,     -- Execution hash
    size INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_access INTEGER NOT NULL,
    success INTEGER NOT NULL DEFAULT 1,
    input_count INTEGER DEFAULT 0,
    output_count INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_action_last_access ON action_entries(last_access);
CREATE INDEX IF NOT EXISTS idx_action_target ON action_entries(target_id);
CREATE INDEX IF NOT EXISTS idx_action_type ON action_entries(action_type);
CREATE INDEX IF NOT EXISTS idx_action_success ON action_entries(success);

-- Source file tracking (for incremental compilation)
CREATE TABLE IF NOT EXISTS source_entries (
    path TEXT PRIMARY KEY,
    content_hash TEXT NOT NULL,
    metadata_hash TEXT NOT NULL,    -- size + mtime hash
    size INTEGER NOT NULL,
    mtime INTEGER NOT NULL,         -- Unix timestamp
    last_check INTEGER NOT NULL     -- When last validated
);

CREATE INDEX IF NOT EXISTS idx_source_mtime ON source_entries(mtime);

-- Write-ahead journal for crash recovery
-- Entries marked committed=0 need replay on startup
CREATE TABLE IF NOT EXISTS journal (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    operation TEXT NOT NULL,        -- 'put', 'delete', 'invalidate'
    table_name TEXT NOT NULL,       -- 'target', 'action', 'source'
    entry_key TEXT NOT NULL,        -- Key of affected entry
    data BLOB,                      -- Optional serialized data for replay
    timestamp INTEGER NOT NULL,
    committed INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_journal_uncommitted ON journal(committed) WHERE committed = 0;

-- Cache statistics (aggregated periodically)
CREATE TABLE IF NOT EXISTS stats (
    name TEXT PRIMARY KEY,
    value INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

-- Reference counting for content-addressable storage
CREATE TABLE IF NOT EXISTS blob_refs (
    hash TEXT PRIMARY KEY,
    ref_count INTEGER NOT NULL DEFAULT 1,
    size INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_blob_refs_count ON blob_refs(ref_count);

-- Initialize default stats
INSERT OR IGNORE INTO stats (name, value, updated_at) VALUES
    ('target_hits', 0, 0),
    ('target_misses', 0, 0),
    ('action_hits', 0, 0),
    ('action_misses', 0, 0),
    ('total_evictions', 0, 0),
    ('bytes_evicted', 0, 0);

