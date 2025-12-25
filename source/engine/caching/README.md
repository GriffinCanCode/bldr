# Builder Caching System

High-performance multi-tier caching for incremental builds, distributed builds, and CI/CD optimization.

## Architecture Overview

The caching system uses a **hybrid architecture**:
- **Binary serialization** for data storage (~10x faster than JSON)
- **SQLite index** for metadata, queries, and crash recovery

This provides the best of both worlds:
- Fast bulk read/write operations via binary format
- Efficient partial queries and LRU tracking via SQLite
- WAL-based crash recovery without data loss
- Cache introspection without loading full data

## Directory Structure

```
engine/caching/
├── package.d              # Root module with overview
├── README.md              # This file
│
├── index/                 # SQLite-backed metadata index
│   ├── index.d            # CacheIndex implementation
│   ├── sqlite.d           # SQLite C bindings
│   └── schema.sql         # Database schema
│
├── targets/               # Target-level caching
│   ├── cache.d            # BuildCache implementation
│   ├── discovery.d        # Cache discovery utilities
│   ├── schema.d           # Cache schema definitions
│   └── storage.d          # Binary serialization for targets
│
├── actions/               # Action-level caching (fine-grained)
│   ├── action.d           # ActionCache, ActionId, ActionEntry
│   ├── schema.d           # Action schema definitions
│   └── storage.d          # Binary serialization for actions
│
├── policies/              # Cache eviction policies
│   └── eviction.d         # LRU + age + size-based eviction
│
├── coordinator/           # Unified cache orchestration
│   └── coordinator.d      # CacheCoordinator with shared index
│
├── distributed/           # Distributed caching
│   ├── coordinator.d      # DistributedCache coordinator
│   └── remote/            # Remote cache client/server
│       ├── artifact.d     # Artifact transfer
│       ├── cdn.d          # CDN integration
│       ├── client.d       # HTTP client for remote cache
│       ├── compress.d     # Compression utilities
│       ├── limiter.d      # Rate limiting
│       ├── metrics.d      # Cache metrics
│       ├── protocol.d     # Cache protocol definitions
│       ├── schema.d       # Remote cache schema
│       ├── server.d       # HTTP server for cache hosting
│       ├── tls.d          # TLS configuration
│       ├── transport.d    # HTTP transport implementation
│       └── unified.d      # Unified remote cache API
│
├── incremental/           # Incremental caching
│   ├── ast_dependency.d   # AST-level dependency tracking
│   ├── ast_storage.d      # AST storage
│   ├── dependency.d       # Dependency tracking
│   ├── filter.d           # Cache filtering
│   ├── schema.d           # Incremental cache schema
│   └── storage.d          # Incremental storage
│
├── dedup/                 # Content deduplication
│   ├── blobindex.d        # Blob indexing
│   ├── dedup.d            # Deduplication logic
│   ├── manifest.d         # Manifest tracking
│   └── store.d            # Dedup storage
│
├── storage/               # Content-addressable storage
│   ├── cas.d              # CAS implementation
│   ├── gc.d               # Garbage collection
│   ├── mapped.d           # Memory-mapped storage
│   ├── materialization.d  # Artifact materialization
│   ├── source_ref.d       # Source references
│   ├── source_repository.d # Source repository
│   └── source_tracker.d   # Source tracking
│
├── metrics/               # Cache metrics
│   ├── collector.d        # Metrics collection
│   └── stats.d            # Statistics tracking
│
├── helpers/               # Cache helpers
│   └── action.d           # Action cache helpers
│
└── events/                # Cache events
    └── package.d          # Event definitions
```

## Module Organization

### `caching.index`

SQLite-backed metadata index providing:
- Efficient partial queries (SELECT WHERE)
- LRU tracking without full cache load
- WAL-based crash recovery
- Unified statistics tracking
- Cache introspection API

**Key Types:**
- `CacheIndex` - Main SQLite index class
- `TargetIndexEntry` - Target metadata
- `ActionIndexEntry` - Action metadata
- `TargetCacheStats` - Target statistics
- `ActionCacheStats` - Action statistics

**Storage Layout:**
```
.builder-cache/
├── index.db          # SQLite database (WAL mode)
├── index.db-wal      # WAL file (auto-managed)
├── cache.bin         # Binary target data
├── actions/
│   └── actions.bin   # Binary action data
└── blobs/            # Content-addressable storage
```

### `caching.targets`

Target-level caching is the primary caching mechanism. Now uses SQLite index for metadata tracking.

**Key Types:**
- `BuildCache` - Main cache class (uses CacheIndex)
- `CacheEntry` - Cache entry with metadata
- `CacheConfig` - Configuration structure
- `BinaryStorage` - Binary serialization

### `caching.actions`

Action-level caching provides finer-grained caching. Now uses shared SQLite index.

**Key Types:**
- `ActionCache` - Action-level cache (uses CacheIndex)
- `ActionId` - Composite action identifier
- `ActionEntry` - Action cache entry
- `ActionType` - Enum of action types
- `ActionCacheConfig` - Configuration structure
- `ActionStorage` - Binary serialization

### `caching.coordinator`

Unified orchestration with shared SQLite index.

**Key Types:**
- `CacheCoordinator` - Main coordinator (owns shared index)

### `caching.policies`

Cache eviction policies. Now powered by SQLite index queries.

**Key Types:**
- `EvictionPolicy` - Hybrid LRU + age + size eviction

### `caching.distributed`

Distributed caching coordinates local and remote cache tiers.

**Key Types:**
- `DistributedCache` - Multi-tier cache coordinator
- `RemoteCacheClient` - HTTP client
- `CacheServer` - HTTP server
- `RemoteCacheConfig` - Remote cache configuration

## Performance Characteristics

### Target Cache
- **Hit check**: O(1) lookup + O(n) hash validation (SIMD-accelerated)
- **Update**: O(n) parallel hashing with work-stealing
- **Flush**: O(n log n) for LRU sorting + O(n) serialization
- **Memory**: ~256 bytes per entry (estimated)

### Action Cache
- **Hit check**: O(1) lookup + O(n) hash validation
- **Update**: O(n) hashing with memoization
- **Flush**: O(n log n) for LRU sorting + O(n) serialization
- **Memory**: ~512 bytes per entry (estimated)

### Remote Cache
- **Fetch**: Network RTT + transfer time + HTTP overhead
- **Push**: Async (non-blocking build)
- **Connection pooling**: Reuses TCP connections
- **Compression**: Optional zstd compression

## Implementation Notes

### Thread Safety
- All cache operations are synchronized via internal mutexes
- Safe for concurrent access from multiple build threads
- Lock-free hash caching for per-session memoization

### Security
- BLAKE3-based HMAC signatures prevent tampering
- Workspace-specific keys for isolation
- Automatic expiration (30 days default)
- Constant-time signature verification

### Memory Management
- Buffer pooling to reduce GC pressure
- Zero-copy string slicing from deserialized data
- Scoped parameters to prevent escaping references
- Explicit `close()` for clean shutdown

### Error Handling
- Corrupted cache files: Start fresh (no fatal errors)
- Signature verification failures: Clear and rebuild
- Remote cache errors: Fall back to local only
- Eviction failures: Save without eviction

## Configuration

All caches can be configured via environment variables or programmatically:

```bash
# Target cache limits
export BUILDER_CACHE_MAX_SIZE=1073741824        # 1 GB
export BUILDER_CACHE_MAX_ENTRIES=10000          # 10k entries
export BUILDER_CACHE_MAX_AGE_DAYS=30            # 30 days

# Action cache limits
export BUILDER_ACTION_CACHE_MAX_SIZE=1073741824
export BUILDER_ACTION_CACHE_MAX_ENTRIES=50000   # More than targets
export BUILDER_ACTION_CACHE_MAX_AGE_DAYS=30

# Remote cache configuration
export BUILDER_REMOTE_CACHE_URL=http://cache.example.com:8080
export BUILDER_REMOTE_CACHE_TIMEOUT=30
export BUILDER_REMOTE_CACHE_RETRY_COUNT=3
export BUILDER_REMOTE_CACHE_COMPRESSION=true
```

## Testing

See `tests/unit/caching/` for comprehensive unit tests covering:
- Cache hit/miss behavior
- Eviction policy correctness
- Binary serialization round-trip
- Remote cache operations
- Security (signature verification)
- Concurrent access patterns

## New: Unified Cache Coordinator (v2.0)

**Status:** ✅ Implemented

The Cache Coordinator provides centralized orchestration:

### `core.caching.coordinator`

Single source of truth for all caching operations:
- Multi-tier caching (local target, action, remote)
- Event-driven telemetry integration
- Automatic garbage collection
- Content-addressable storage with deduplication

**Usage:**
```d
auto coordinator = new CacheCoordinator(cacheDir, publisher);

// Check all tiers automatically
if (!coordinator.isCached(targetId, sources, deps)) {
    coordinator.update(targetId, sources, deps, outputHash);
}

// Action caching
if (!coordinator.isActionCached(actionId, inputs, metadata)) {
    coordinator.recordAction(actionId, inputs, outputs, metadata, true);
}

// Maintenance
coordinator.runGC();  // Clean orphaned artifacts
coordinator.flush();
coordinator.close();
```

### `core.caching.storage`

Content-addressable storage with deduplication:
- Automatic dedup by content hash
- Reference counting for safe deletion
- Sharded filesystem layout for performance

### `core.caching.metrics`

Real-time metrics collection:
- Event-driven (zero overhead when disabled)
- Comprehensive statistics (hit rates, latencies, storage)
- Integrates with telemetry system

See [CACHE_COORDINATOR.md](../../../docs/implementation/CACHE_COORDINATOR.md) for details.

## SQLite Index Benefits

The SQLite index provides several advantages over the previous all-binary approach:

### 1. Partial Queries
```d
// Query targets by pattern (fast SQL LIKE)
auto frontendTargets = coordinator.queryTargets("frontend/");

// Get actions for specific target
auto actions = index.getActionsForTarget("//myapp:server");
```

### 2. Efficient Eviction
```d
// SQLite selects LRU entries without loading full cache
auto toEvict = index.selectTargetEvictions(maxEntries, maxSize, maxAgeDays);
```

### 3. Crash Recovery
- WAL mode ensures durability
- Journal table tracks uncommitted operations
- Automatic replay on startup

### 4. Cache Introspection
```d
// List all cached targets
writeln(coordinator.listTargets());

// Get statistics without loading data
auto stats = index.getTargetStats();
writefln("Hit rate: %.1f%%", stats.hitRate);
```

### 5. Concurrent Access
- WAL mode allows concurrent readers
- Single-writer with readers doesn't block

## Related: Graph Persistence

The build graph itself can also be persisted to SQLite using the same patterns:

- **Location**: `engine.graph.persistence`
- **Storage**: `.builder-cache/graph.db` (separate from cache index)
- **Features**: Transitive queries, impact analysis, crash recovery

See `source/engine/graph/README.md` for details.

## Future Enhancements

Potential improvements for future versions:
- **Compression**: Compress large artifacts before storage (in progress)
- **Cache warming**: Pre-populate from CI artifacts
- **Distributed GC**: Coordinate cleanup across build cluster
- **ML-based prediction**: Intelligent cache pre-fetching
- **Index replication**: Sync index across distributed builds

