# Configuration Caching

This module provides incremental DSL parse caching for the Builder build system.

## Overview

Parse caching eliminates redundant parsing of unchanged Builderfiles by caching Abstract Syntax Trees (ASTs). This provides significant performance improvements for incremental builds.

## Components

### `parse.d` - Main Cache Implementation

The `ParseCache` class provides:
- In-memory LRU cache with configurable size limits
- Optional disk persistence across builds
- Two-tier validation (metadata + content hash)
- Thread-safe concurrent access
- Comprehensive statistics and monitoring

**Key Features:**
- Content-addressable storage (BLAKE3 hashing)
- ~100x speedup on cache hits (unchanged files)
- Automatic invalidation on file changes
- Binary serialization for speed

### `storage.d` - AST Serialization

The `ASTStorage` struct provides:
- Custom binary format for BuildFile ASTs
- Fast serialization (~5x faster than JSON)
- Compact representation (~50% smaller than JSON)
- Version-aware format for forward compatibility

**Format Features:**
- Type-safe tagged union serialization
- Length-prefixed strings and arrays
- Big-endian encoding for portability
- Zero-copy deserialization where possible

### `sqlite.d` - SQLite Configuration Cache

The `ConfigIndex` class provides persistent SQLite-backed caching:
- **Prepared statements** for sub-millisecond lookups
- **WAL mode** for crash recovery + concurrent reads
- **Indexed queries** by workspace, language, target type
- **Denormalized target lookup** for O(1) access
- **LRU eviction** with access time tracking

**Key Features:**
- Point lookups: <0.1ms via prepared statements
- Pattern queries: <1ms via indexed columns
- Crash-safe journaling for atomic operations
- Memory-mapped I/O for large datasets

### `package.d` - Module Exports

Public API surface for the caching module.

## Usage

### Basic Usage

```d
import config.caching.parse;

// Create cache
auto cache = new ParseCache();

// Check cache
auto cached = cache.get("path/to/Builderfile");
if (cached !is null)
{
    // Use cached AST
    auto targets = analyzeAST(*cached);
}
else
{
    // Parse and cache
    auto ast = parse(source);
    cache.put("path/to/Builderfile", ast);
}

// Cleanup
cache.close();
```

### Integration with parseDSL

```d
import config.interpretation.dsl;
import config.caching.parse;

auto cache = new ParseCache();
auto result = parseDSL(source, filePath, workspaceRoot, cache);
```

### Statistics

```d
auto stats = cache.getStats();
writefln("Hit rate: %.1f%%", stats.hitRate);
writefln("Fast path rate: %.1f%%", stats.metadataHitRate);

// Pretty print
cache.printStats();
```

### SQLite Configuration Cache

```d
import infrastructure.config.caching.sqlite;

// Create persistent config cache
auto configIndex = new ConfigIndex(".builder-cache");

// Store workspace configuration
ConfigEntry entry;
entry.workspacePath = "/path/to/workspace";
entry.contentHash = computeBlake3(allBuilderfiles);
entry.configData = serializeConfig(workspaceConfig);
entry.targetCount = cast(int)targets.length;
configIndex.putConfig(entry);

// Sub-millisecond config lookup
auto result = configIndex.getConfig("/path/to/workspace");
if (result.isOk)
{
    auto config = deserializeConfig(result.unwrap().configData);
}

// Fast target queries by language
auto dTargets = configIndex.getTargetsByLanguage(TargetLanguage.D);
auto rustTargets = configIndex.getTargetsByLanguage(TargetLanguage.Rust);

// Query by type
auto tests = configIndex.getTargetsByType(TargetType.Test);
auto executables = configIndex.getTargetsByType(TargetType.Executable);

// Individual target lookup (O(1))
auto target = configIndex.getTarget("//myapp:server");

// Batch insert within transaction
TargetEntry[] entries = buildTargetEntries(targets);
configIndex.putTargetsBatch(entries);

// Cache statistics
auto stats = configIndex.getStats();
writefln("Cached configs: %d", stats.totalConfigs);
writefln("Cached targets: %d", stats.totalTargets);
writefln("Avg targets/config: %.1f", stats.avgTargetsPerConfig());

// Maintenance
configIndex.evictLRU(1000);  // Keep max 1000 configs
configIndex.close();         // Checkpoint WAL + cleanup
```

## Performance

### Parse Cache Benchmarks

| Operation | Time | Speedup |
|-----------|------|---------|
| Parse (no cache) | 165 µs | 1x |
| Cache hit (metadata) | 2.3 µs | **~72x** |
| Cache hit (content hash) | 48 µs | ~3.4x |

### SQLite Config Cache Benchmarks

| Operation | Time | Notes |
|-----------|------|-------|
| Config lookup (prepared) | ~50 µs | **Sub-millisecond** |
| Target lookup by ID | ~30 µs | Indexed primary key |
| Targets by language | ~200 µs | Indexed query |
| Targets by workspace | ~150 µs | Indexed foreign key |
| Batch insert (100 targets) | ~5 ms | Single transaction |

### Real-World Impact

For a workspace with 120 Builderfiles:
- Cold parse: ~29ms
- Warm cache (no changes): ~0.3ms (**98x faster**)
- Warm cache (1 file changed): ~0.5ms (~58x faster)

For SQLite config cache (1000 targets):
- Config lookup: <0.1ms (vs. ~10ms full reparse)
- Target by language query: <0.5ms (vs. full scan)
- Startup with cached config: ~1ms (vs. ~50ms cold)

## Configuration

### Environment Variables

```bash
# Enable/disable parse cache (default: enabled)
export BUILDER_PARSE_CACHE=true

# Disable for debugging
export BUILDER_PARSE_CACHE=false
```

### Programmatic

```d
auto cache = new ParseCache(
    enableDiskCache: true,
    cacheDir: ".builder-cache/parse",
    maxEntries: 1000
);
```

## Implementation Details

### Two-Tier Validation

1. **Metadata Hash** (fast): `BLAKE3(fileSize || mtime)`
   - O(1) constant time
   - 99%+ accuracy
   
2. **Content Hash** (slow): `BLAKE3(fileContent)`
   - O(n) linear in file size
   - 100% accuracy
   - Only computed when metadata changes

### Thread Safety

All operations are protected by an internal mutex:
- Safe for concurrent `get()` and `put()`
- Minimal lock contention (fast critical sections)
- No reader/writer locks needed (single mutex sufficient)

### Memory Management

- **LRU Eviction**: Automatic removal of old entries
- **Max Entries**: Configurable (default: 1000)
- **Memory per Entry**: ~5-20 KB (varies by AST complexity)
- **Total Memory**: ~5-20 MB for 1000 cached files

### Disk Persistence (Parse Cache)

- **Format**: Binary (see `storage.d`)
- **Location**: `.builder-cache/parse/parse-cache.bin`
- **Size**: Typically 1-10 MB
- **Expiration**: None (content-addressed)

### SQLite Configuration Database

- **Location**: `.builder-cache/config.db`
- **Mode**: WAL (Write-Ahead Logging)
- **Schema**:
  - `configs`: Workspace-level configuration entries
  - `targets`: Denormalized target entries for fast lookup
  - `config_journal`: Crash recovery journal

**Indexes** (for sub-millisecond queries):
- `configs(workspace_path)` - Primary key
- `configs(last_access)` - LRU eviction
- `configs(content_hash)` - Duplicate detection
- `targets(target_id)` - Primary key
- `targets(workspace_path)` - Foreign key lookups
- `targets(language)` - Language-specific queries
- `targets(target_type)` - Type-specific queries
- `targets(name)` - Name pattern matching

**PRAGMA optimizations**:
```sql
PRAGMA journal_mode=WAL;       -- Concurrent reads + crash recovery
PRAGMA synchronous=NORMAL;     -- Balance durability/performance
PRAGMA cache_size=-32000;      -- 32MB in-memory page cache
PRAGMA mmap_size=268435456;    -- 256MB memory-mapped I/O
PRAGMA temp_store=MEMORY;      -- Temp tables in RAM
```

## Testing

Run the test suite:

```bash
./bin/test-runner tests/unit/config/parse_cache.d
```

Tests cover:
- Basic caching behavior
- Cache invalidation
- Two-tier validation
- LRU eviction
- AST serialization
- Concurrent access

## Documentation

See [PARSE_CACHE.md](../../../docs/implementation/PARSE_CACHE.md) for comprehensive documentation including:
- Design philosophy
- Architecture diagrams
- Performance benchmarks
- Integration guides
- Best practices

## Related Modules

- `config.interpretation.dsl` - DSL parser integration
- `config.parsing.parser` - ConfigParser integration
- `config.workspace.ast` - AST node types
- `utils.files.hash` - BLAKE3 hashing utilities
- `utils.simd.hash` - SIMD-accelerated hash comparison
- `engine.caching.index.sqlite` - Shared SQLite bindings
- `engine.graph.persistence` - Similar SQLite pattern for graph

## Future Work

1. **Distributed cache** - Share cache across machines
2. **Compression** - LZ4/Zstd for disk cache
3. **Incremental semantic analysis** - Only re-analyze changed targets
4. **Watch mode** - File system watcher integration
5. **Cache warming** - Background pre-population
6. **SQLite FTS5** - Full-text search for target discovery
7. **Virtual tables** - SQLite extension for custom queries

