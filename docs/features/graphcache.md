# Graph Cache

Dependency graph caching eliminates re-analysis overhead by caching the validated `BuildGraph` structure. This provides significant speedup for incremental builds where configuration files haven't changed.

## Overview

- **Location**: `.builder-cache/graph.bin` and `.builder-cache/graph-metadata.bin`
- **Typical speedup**: 10-50x for unchanged graphs
- **Cache validation**: Two-tier (metadata hash → content hash)
- **Thread-safe**: Concurrent access via mutex

## Architecture

### Components

**Location**: `source/engine/graph/caching/`

```
caching/
├── cache.d      # GraphCache - main cache implementation
├── storage.d    # GraphStorage - binary serialization
├── schema.d     # Serializable types with versioning
├── mapped.d     # Memory-mapped access for large graphs
└── package.d    # Public API
```

### GraphCache

High-performance cache with two-tier validation:

```d
final class GraphCache
{
    BuildGraph get(scope const(string)[] configFiles) @system;
    void put(BuildGraph graph, scope const(string)[] configFiles) @system;
    void invalidate() @system nothrow;
    void clear() @system;
    Stats getStats() const @system;
}

struct Stats
{
    size_t hits;
    size_t misses;
    float hitRate;
    size_t metadataHits;    // Fast path
    size_t contentHashes;   // Slow path
    float metadataHitRate;
}
```

### GraphStorage

Binary serialization using schema-based codec:

```d
struct GraphStorage
{
    static ubyte[] serialize(BuildGraph graph) @system;
    static BuildGraph deserialize(scope ubyte[] data) @system;
}
```

**Format**: Custom binary with magic number `0x42475246` ("BGRF") and schema versioning.

### Schema

```d
@Serializable(SchemaVersion(1, 0), 0x42475246)
struct SerializableBuildGraph
{
    @Field(1) SerializableBuildNode[] nodes;
    @Field(2) string[] rootIds;
    @Field(3) uint validationMode;
    @Field(4) bool isValidated;
}
```

## Validation Strategy

### Two-Tier Validation

**Tier 1: Metadata Hash (Fast Path)**
- Computes hash of `size + mtime` for each config file
- Compares with cached metadata hash
- Typical time: microseconds per file
- Handles most unchanged file cases

**Tier 2: Content Hash (Slow Path)**
- Only triggered if metadata changed
- Computes content hash for changed files
- Handles `touch` and metadata-only changes
- Typical time: milliseconds per file

### Invalidation Triggers

Cache invalidates when:
- Any `Builderfile` content changes
- `Builderspace` content changes
- Config files added or deleted
- Integrity signature verification fails
- Cache expires (default: 30 days)

## Usage

### Automatic (Default)

Graph caching is automatic:

```bash
# First build: analyzes and caches graph
$ bldr build

# Subsequent builds: loads from cache if unchanged
$ bldr build
```

### Manual Management

```bash
# Clear graph cache
$ bldr clean --graph-cache

# Force rebuild
$ bldr build --no-cache
```

### Programmatic

```d
import engine.graph.caching;

auto cache = new GraphCache(".builder-cache");

// Get cached graph
auto graph = cache.get(configFiles);
if (graph !is null) {
    // Use cached graph
}

// Store graph
cache.put(graph, configFiles);

// Statistics
auto stats = cache.getStats();
writefln("Hit rate: %.1f%%", stats.hitRate);
```

## Implementation Details

### Integrity Validation

Cache uses workspace-specific integrity signatures:

```d
// Graph signed with workspace key
auto signed = validator.signWithMetadata(graphData);

// Verification on load
if (!validator.verifyWithMetadata(signed))
    throw new Exception("Signature verification failed");
```

### Memory-Mapped Loading

For large graphs (>1MB), uses mmap for reduced memory copies:

```d
private enum size_t GRAPH_MMAP_THRESHOLD = 1024 * 1024;

if (fileSize >= GRAPH_MMAP_THRESHOLD)
{
    region = MmapRegion.map(cacheFilePath, MapMode.ReadOnly);
    fileData = region[].dup;
}
```

### Config File Collection

Discovers all configuration files:

```d
private string[] collectConfigFiles()
{
    string[] files;
    
    // Find all Builderfiles recursively
    foreach (entry; dirEntries(config.root, "Builderfile", SpanMode.depth))
        files ~= entry.name;
    
    // Add Builderspace if exists
    auto builderspace = buildPath(config.root, "Builderspace");
    if (exists(builderspace))
        files ~= builderspace;
    
    return files;
}
```

## Performance

### Space Complexity

- Per target: ~100-500 bytes
- 1000 targets: ~100-500 KB
- 10000 targets: ~1-5 MB

### Time Complexity

| Operation | Complexity | Typical Time |
|-----------|------------|--------------|
| Cache hit (fast path) | O(files) | 1-5ms |
| Cache hit (slow path) | O(files) | 10-50ms |
| Cache miss | O(V + E) | 100-500ms |
| Serialization | O(V + E) | 10-20ms |
| Deserialization | O(V + E) | 5-10ms |

### Optimizations

- SIMD-accelerated hash comparisons
- Two-tier hashing avoids expensive content hash when possible
- Binary format (faster than JSON)
- Memory-mapped I/O for large graphs
- Pre-allocation to avoid rehashing

## Testing

```d
// Serialization roundtrip
unittest
{
    auto graph = createTestGraph();
    auto serialized = GraphStorage.serialize(graph);
    auto deserialized = GraphStorage.deserialize(serialized);
    assert(graphsEqual(graph, deserialized));
}

// Cache hit/miss
unittest
{
    auto cache = new GraphCache();
    cache.put(graph, ["Builderfile"]);
    
    auto cached = cache.get(["Builderfile"]);
    assert(cached !is null);
}
```

## Integration

### DependencyAnalyzer

The analyzer checks cache before analysis:

```d
// Try cache first
auto cachedGraph = graphCache.get(configFiles);
if (cachedGraph !is null)
{
    Logger.success("Loaded dependency graph from cache");
    return cachedGraph;
}

// Cache miss - analyze and cache
auto graph = analyzeAndBuildGraph();
graphCache.put(graph, configFiles);
```

## Related Documentation

- [Parse Cache](./parsecache.md) - AST caching
- [Action Cache](./caching.md) - Build action caching
- [Performance](./performance.md) - Optimization strategies
