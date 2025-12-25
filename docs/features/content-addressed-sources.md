# Content-Addressed Source Storage

**Status:** Implemented  
**Module:** `engine.caching.storage`

## Overview

Builder extends content-addressable storage (CAS) to include source files. Every source file is stored by its content hash (BLAKE3), enabling deduplication and integrity verification.

### Benefits

1. **Automatic Deduplication**: Identical files stored once, regardless of path
2. **Zero-Cost Branching**: Sources shared across branches/commits
3. **Time-Travel Builds**: Historical states can be reconstructed
4. **Distributed Builds**: Sources referenced by hash, not path
5. **Integrity Verification**: Content hashing ensures reproducibility

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   CacheCoordinator                       │
│           (Unified cache orchestration)                  │
└────────────────┬────────────────────────────────────────┘
                 │
    ┌────────────┼────────────┐
    │            │            │
┌───▼────┐  ┌───▼────────┐  ┌▼────────────┐
│ Target │  │   Action   │  │   Source    │
│ Cache  │  │   Cache    │  │ Repository  │
└────────┘  └────────────┘  └─────┬───────┘
                                  │
                   ┌──────────────┼──────────────┐
                   │              │              │
           ┌───────▼──────┐  ┌───▼────────┐  ┌──▼──────────┐
           │ SourceRef    │  │SourceTracker│ │Materializer │
           │ (hash+path)  │  │(change detect)│ │(restore)   │
           └──────────────┘  └──────────────┘ └─────────────┘
                                  │
                           ┌──────▼──────┐
                           │     CAS     │
                           │  (blobs)    │
                           └─────────────┘
```

## Components

### SourceRef (`source_ref.d`)

Content-addressed reference to a source file:

```d
struct SourceRef {
    string hash;           // BLAKE3 content hash
    string originalPath;   // Original path (for display)
    ulong size;            // File size in bytes
}
```

**Creation:**
```d
auto result = SourceRef.fromFile("src/main.d");
auto ref_ = result.unwrap();

writeln(ref_.hash);       // "a3b5c7d9..."
writeln(ref_.shortHash); // "a3b5c7d9" (first 8 chars)
writeln(ref_.toString()); // "src/main.d@a3b5c7d9"
```

**From Existing Hash:**
```d
auto ref_ = SourceRef.fromHash("a3b5c7d9...", "src/main.d", 1024);
```

**Equality:**
Files with identical content have identical `SourceRef`:
```d
auto ref1 = SourceRef.fromFile("branch-a/util.d").unwrap();
auto ref2 = SourceRef.fromFile("branch-b/util.d").unwrap();
assert(ref1 == ref2);  // Same content = same hash
```

### SourceRefSet

Collection of source references with quick lookup:

```d
struct SourceRefSet {
    SourceRef[] sources;
    string[string] pathToHash;  // path -> hash lookup
    
    void add(SourceRef ref_);
    SourceRef* getByPath(string path);
    SourceRef* getByHash(string hash);
    ulong totalSize();
    bool empty();
    size_t length();
}
```

### SourceRepository (`source_repository.d`)

Content-addressed source repository with automatic deduplication:

```d
auto repo = new SourceRepository(cas, ".builder-cache/sources");

// Store single file
auto ref_ = repo.store("src/app.d").unwrap();

// Store batch
auto refSet = repo.storeBatch(["main.d", "utils.d"]).unwrap();

// Fetch by hash
auto content = repo.fetch(ref_.hash).unwrap();

// Materialize to path
repo.materialize(ref_.hash, "workspace/src/app.d");

// Get reference by path
auto ref_ = repo.getRefByPath("src/main.d").unwrap();

// Verify integrity
auto isValid = repo.verify("src/main.d").unwrap();

// Statistics
auto stats = repo.getStats();
writeln("Deduplication hits: ", stats.deduplicationHits);
writeln("Bytes saved: ", stats.bytesSaved);
```

**Features:**
- Automatic deduplication via CAS
- Path-to-hash index for lookups
- Integrity verification
- Thread-safe operations

### SourceTracker (`source_tracker.d`)

Combines change detection with content-addressing:

```d
auto tracker = new SourceTracker(repo);

// Track and store files
auto ref_ = tracker.track("main.d").unwrap();
auto refSet = tracker.trackBatch(["main.d", "utils.d"]).unwrap();

// Detect changes
auto changes = tracker.detectChanges(["main.d", "utils.d"]).unwrap();

foreach (change; changes) {
    writeln(change.path);
    writeln("  Old: ", change.oldHash);
    writeln("  New: ", change.newHash);
}

// Verify integrity
auto isValid = tracker.verify("src/main.d").unwrap();

// Materialize from CAS
tracker.materialize(hash, "workspace/file.d");

// Statistics
auto stats = tracker.getStats();
writeln("Files tracked: ", stats.filesTracked);
writeln("Changes detected: ", stats.changesDetected);
writeln("Dedup ratio: ", stats.deduplicationRatio, "%");
```

**ChangedFile Structure:**
```d
struct ChangedFile {
    string path;
    string oldHash;
    string newHash;
    SourceRef newRef;
}
```

## Integration with CacheCoordinator

The `CacheCoordinator` provides unified access:

```d
auto coordinator = new CacheCoordinator(".builder-cache");

// Store sources
auto refSet = coordinator.storeSources([
    "src/main.d",
    "src/utils.d",
    "src/config.d"
]).unwrap();

// Detect changes
auto changes = coordinator.detectSourceChanges([
    "src/main.d",
    "src/utils.d"
]).unwrap();

// Get statistics
auto stats = coordinator.getStats();
writeln("Source deduplication: ", stats.sourceDeduplicationRatio, "%");
writeln("Bytes saved: ", stats.sourceBytesSaved);
```

## Use Cases

### Monorepo Builds

Thousands of services with shared utility code:

```
service-a/utils/logging.d  ──┐
service-b/utils/logging.d  ──┼──> CAS: hash_abc123 (stored once)
service-c/utils/logging.d  ──┘
```

100 copies → 1 blob in storage.

### Branch Switching

```d
// Sources already in CAS from main branch
auto refSet = loadSourceRefs("feature-branch");
tracker.materializeBatch(refSet, "workspace/");  // Instant restoration
```

No re-hashing required.

### Distributed Builds

CI workers fetch only needed sources:

```d
// Master stores sources
coordinator.storeSources(allSources);

// CI worker fetches only needed sources by hash
remoteCache.pull(sourceRef.hash);
tracker.materialize(sourceRef.hash, "src/file.d");
```

### Incremental Builds Across Checkouts

```d
// Before cleanup: Store source refs
auto refSet = coordinator.storeSources(allSources).unwrap();
saveToFile("source-refs.bin", refSet);

// After cleanup: Restore from refs
auto refSet = loadFromFile("source-refs.bin");
tracker.materializeBatch(refSet, "workspace/");
```

Build cache survives workspace cleanup.

### Hermetic Builds

Record exact sources used in build:

```d
// Record exact sources
auto refSet = coordinator.storeSources(buildSources).unwrap();
saveBuildManifest(targetId, refSet);

// Reproduce build later
auto refSet = loadBuildManifest(targetId);
tracker.materializeBatch(refSet, "workspace/");
build(target);  // Bit-for-bit identical
```

## Storage Format

### Blob Storage

```
.builder-cache/blobs/
├── ab/
│   └── abc123...  (source file content)
├── cd/
│   └── cde456...
└── ef/
    └── efg789...
```

- **Sharding**: First 2 hex chars for filesystem performance
- **Naming**: Full BLAKE3 hash
- **Content**: Raw file bytes

### Index Storage

```
.builder-cache/sources/index.bin
```

Path-to-hash mapping for quick lookups.

## Performance

### File Size Optimization

Large files (>256KB) use memory-mapped reads:

```d
if (fileSize >= SOURCE_MMAP_THRESHOLD) {
    auto region = MmapRegion.map(path, MapMode.ReadOnly);
    immutable hash = FastHash.hashBytes(region[]);
}
```

### Benchmarks (1000 source files, 50KB avg)

| Operation | Time |
|-----------|------|
| Initial store | 450ms |
| Store (duplicates) | 12ms |
| Hash verification | 8ms (cached) |
| Workspace restore | 180ms |
| Change detection | 45ms |

### Deduplication Ratios

Example monorepo (10K source files):
- **Unique content**: 4,200 files
- **Storage savings**: 58%
- **Disk usage**: 210MB → 88MB

## Statistics

```d
struct RepositoryStats {
    size_t sourcesStored;
    size_t sourcesFetched;
    size_t deduplicationHits;
    ulong bytesStored;
    ulong bytesSaved;
    float deduplicationRatio;  // bytesSaved / (bytesStored + bytesSaved)
}

struct TrackerStats {
    size_t filesTracked;
    size_t changesDetected;
    size_t storageOperations;
    // Plus repository stats
}
```

## Limitations

1. **Large binary files**: >100MB may impact performance
   - Mitigation: Use `.builderignore` to exclude from CAS

2. **High churn files**: Generated code, timestamps reduce dedup benefits
   - Expected behavior

3. **Network latency**: Remote CAS adds latency to materialization
   - Mitigation: Local cache tier

## See Also

- [CAS Design](../architecture/cachedesign.md)
- [Incremental Builds](./incremental.md)
- [Remote Caching](./remotecache.md)
- [Hermetic Builds](./hermetic.md)
