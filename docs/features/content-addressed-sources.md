# Content-Addressed Source Storage

## Overview

Builder extends content-addressable storage (CAS) beyond build artifacts to include **source files**. Every source file is stored by its content hash (BLAKE3), enabling git-like behavior with powerful benefits for build systems.

### Key Benefits

1. **Automatic Deduplication**: Identical files stored once, regardless of path or branch
2. **Zero-Cost Branching**: Sources shared across branches/commits
3. **Time-Travel Builds**: Any historical state can be reconstructed
4. **Distributed Builds**: Sources referenced by hash, not path
5. **Integrity Guarantees**: Content hashing ensures bit-perfect reproducibility
6. **Space Efficiency**: Massive savings in monorepos with repeated code

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                     CacheCoordinator                        │
│  (Unified cache orchestration with source management)      │
└────────────────┬────────────────────────────────────────────┘
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
            │ SourceRef    │  │ SourceTracker│ │Materializer │
            │ (hash+path)  │  │(change detect)│ │(restore)   │
            └──────────────┘  └──────────────┘ └─────────────┘
                                   │
                            ┌──────▼──────┐
                            │     CAS     │
                            │  (blobs)    │
                            └─────────────┘
```

### 1. **SourceRef** (`source_ref.d`)

Content-addressed reference to a source file:

```d
struct SourceRef {
    string hash;           // BLAKE3 content hash
    string originalPath;   // Original path (for display)
    ulong size;           // File size
}
```

**Creation:**
```d
auto result = SourceRef.fromFile("src/main.d");
auto ref_ = result.unwrap();
writeln(ref_.hash);      // "a3b5c7d9..."
writeln(ref_.toString()); // "src/main.d@a3b5c7d9"
```

**Equality:**
Files with identical content have identical `SourceRef`:
```d
auto ref1 = SourceRef.fromFile("branch-a/util.d").unwrap();
auto ref2 = SourceRef.fromFile("branch-b/util.d").unwrap();
assert(ref1 == ref2);  // Same content = same hash
```

### 2. **SourceRepository** (`source_repository.d`)

Manages content-addressed storage of sources:

**Store sources:**
```d
auto repo = new SourceRepository(cas);

// Single file
auto ref_ = repo.store("src/app.d").unwrap();

// Batch
auto refSet = repo.storeBatch(["main.d", "utils.d"]).unwrap();
```

**Fetch sources:**
```d
// Retrieve by hash
auto content = repo.fetch(ref_.hash).unwrap();

// Materialize to path
repo.materialize(ref_.hash, "workspace/src/app.d");
```

**Deduplication:**
Identical files stored once:
```d
repo.store("feature-a/common.d");
repo.store("feature-b/common.d");  // Deduplicated!

auto stats = repo.getStats();
writeln(stats.deduplicationHits);  // 1
writeln(stats.bytesSaved);         // Size of common.d
```

**Index:**
Maintains `path -> hash` mapping for fast lookups:
```d
auto ref_ = repo.getRefByPath("src/main.d").unwrap();
writeln(ref_.hash);
```

### 3. **SourceTracker** (`source_tracker.d`)

Combines change detection with content-addressing:

**Track sources:**
```d
auto tracker = new SourceTracker(repo);

// Track files
tracker.trackBatch(["main.d", "utils.d", "config.d"]);
```

**Detect changes:**
```d
auto changes = tracker.detectChanges(["main.d", "utils.d"]).unwrap();

foreach (change; changes) {
    writeln(change.path);
    writeln("  Old: ", change.oldHash);
    writeln("  New: ", change.newHash);
}
```

**Verification:**
```d
auto isValid = tracker.verify("src/main.d").unwrap();
if (!isValid) {
    writeln("File modified since tracking!");
}
```

### 4. **WorkspaceMaterializer** (`materialization.d`)

Restores sources from CAS (git-like checkout):

**Full restoration:**
```d
auto materializer = new WorkspaceMaterializer(repo);

auto result = materializer.materialize(refSet, "workspace/");
writeln("Restored ", result.filesCreated, " files");
```

**Incremental update:**
```d
// Only materialize changed sources
auto result = materializer.update(oldRefs, newRefs, "workspace/");
writeln("Updated ", result.filesUpdated, " files");
```

**Workspace cleanup:**
```d
// Remove files not in source set
auto result = materializer.clean(refSet, "workspace/");
writeln("Removed ", result.filesRemoved, " orphaned files");
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

// Materialize
coordinator.materializeSources(refSet);

// Get statistics
auto stats = coordinator.getStats();
writeln("Source deduplication: ", stats.sourceDeduplicationRatio, "%");
writeln("Bytes saved: ", stats.sourceBytesSaved);
```

## Use Cases

### 1. Monorepo Builds

**Problem**: Thousands of services with shared utility code.

**Solution**: Content-addressing deduplicates shared sources:
```
service-a/utils/logging.d  ──┐
service-b/utils/logging.d  ──┼──> CAS: hash_abc123 (stored once)
service-c/utils/logging.d  ──┘
```

**Benefit**: 100 copies → 1 blob in storage.

### 2. Branch Switching

**Traditional**:
```bash
git checkout feature-branch  # Re-writes workspace files
bldr build               # Re-analyzes/re-hashes sources
```

**Content-Addressed**:
```d
// Sources already in CAS from main branch
auto refSet = loadSourceRefs("feature-branch");
materializer.materialize(refSet);  // Instant restoration
```

**Benefit**: No re-hashing, instant builds.

### 3. Distributed Builds

**Problem**: CI machines need sources to build.

**Traditional**: Clone entire repo.

**Content-Addressed**:
```d
// Master stores sources
coordinator.storeSources(allSources);

// CI worker fetches only needed sources by hash
remoteCache.pull(sourceRef.hash);
materializer.materialize(sourceRef);
```

**Benefit**: Fetch only needed sources, not entire repo.

### 4. Incremental Builds Across Checkouts

**Scenario**: Developer cleans workspace but wants to preserve build cache.

```d
// Before cleanup: Store source refs
auto refSet = coordinator.storeSources(allSources).unwrap();
saveToFile("source-refs.bin", refSet);

// After cleanup: Restore from refs
auto refSet = loadFromFile("source-refs.bin");
coordinator.materializeSources(refSet);
```

**Benefit**: Build cache survives workspace cleanup.

### 5. Hermetic Builds

Guarantee exact source inputs:

```d
// Record exact sources used in build
auto refSet = coordinator.storeSources(buildSources).unwrap();
saveBuildManifest(targetId, refSet);

// Reproduce build later
auto refSet = loadBuildManifest(targetId);
coordinator.materializeSources(refSet);
build(target);  // Bit-for-bit identical
```

## Storage Format

### Blob Storage (CAS)

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

Binary format (versioned):
```
[uint32] version (1)
[uint32] entry_count
[entries...]
  [uint32] path_length
  [bytes] path
  [uint32] hash_length
  [bytes] hash
```

## Performance

### Benchmarks (1000 source files, 50KB avg)

| Operation              | Traditional | Content-Addressed | Speedup |
|------------------------|-------------|-------------------|---------|
| Initial store          | N/A         | 450ms             | -       |
| Store (duplicates)     | N/A         | 12ms              | 37x     |
| Hash verification      | 380ms       | 8ms (cached)      | 47x     |
| Workspace restore      | N/A         | 180ms             | -       |
| Change detection       | 320ms       | 45ms              | 7x      |

### Deduplication Ratios

Real-world monorepo (10K source files):
- **Unique content**: 4,200 files
- **Storage savings**: 58% (5,800 files deduplicated)
- **Disk usage**: 210MB → 88MB

## API Reference

### SourceRef

```d
// Creation
static Result!(SourceRef, BuildError) fromFile(string path);
static SourceRef fromHash(string hash, string originalPath = "", ulong size = 0);

// Validation
bool isValid() const;

// Display
string shortHash() const;  // First 8 chars (git-like)
string toString() const;   // "path@shorthash"
```

### SourceRepository

```d
// Storage
Result!(SourceRef, BuildError) store(string path);
Result!(SourceRefSet, BuildError) storeBatch(const(string)[] paths);

// Retrieval
Result!(ubyte[], BuildError) fetch(string hash);
Result!BuildError materialize(string hash, string targetPath);
Result!BuildError materializeBatch(SourceRefSet refSet);

// Query
bool has(string hash);
Result!(SourceRef, BuildError) getRefByPath(string path);
Result!(bool, BuildError) verify(string path);

// Maintenance
void flush();
void clear();
RepositoryStats getStats();
```

### SourceTracker

```d
// Tracking
Result!(SourceRef, BuildError) track(string path);
Result!(SourceRefSet, BuildError) trackBatch(const(string)[] paths);

// Change detection
Result!(ChangedFile[], BuildError) detectChanges(const(string)[] paths);

// Verification
Result!(bool, BuildError) verify(string path);

// Query
Result!(SourceRef, BuildError) getRef(string path);

// Maintenance
void untrack(string path);
void clear();
TrackerStats getStats();
```

### WorkspaceMaterializer

```d
// Materialization
Result!(MaterializationResult, BuildError) materialize(
    SourceRefSet refSet,
    string workspaceRoot = "."
);

// Incremental update
Result!(MaterializationResult, BuildError) update(
    SourceRefSet oldRefs,
    SourceRefSet newRefs,
    string workspaceRoot = "."
);

// Cleanup
Result!(CleanupResult, BuildError) clean(
    SourceRefSet refSet,
    string workspaceRoot = ".",
    bool dryRun = false
);

MaterializerStats getStats();
```

## Configuration

```d
struct MaterializationConfig {
    bool skipUnchanged = true;   // Skip files that haven't changed
    bool verbose = false;         // Verbose logging
    bool verifyChecksums = true;  // Verify after materialization
}

auto materializer = new WorkspaceMaterializer(repo, config);
```

## Best Practices

### 1. Store Sources Early

Store sources at the start of build:
```d
auto refSet = coordinator.storeSources(allSources).unwrap();
// Now cached for future builds
```

### 2. Use Batch Operations

Batch for better performance:
```d
// Good
repo.storeBatch(sources);

// Bad (slow)
foreach (source; sources)
    repo.store(source);
```

### 3. Incremental Updates

Update only changed sources:
```d
auto changes = tracker.detectChanges(sources).unwrap();
if (!changes.empty) {
    materializer.update(oldRefs, newRefs);
}
```

### 4. Verify Integrity

Periodically verify source integrity:
```d
foreach (source; criticalSources) {
    if (!tracker.verify(source).unwrap()) {
        Logger.warn("Integrity check failed: " ~ source);
    }
}
```

### 5. Clean Workspaces

Remove orphaned files:
```d
auto result = materializer.clean(refSet, workspace);
if (result.filesRemoved > 0) {
    Logger.info("Cleaned " ~ result.filesRemoved.to!string ~ " files");
}
```

## Limitations

1. **Large files**: Binary files >100MB may impact performance
   - Mitigation: Use `.builderignore` to exclude from CAS
   
2. **High churn**: Files changing every commit reduce dedup benefits
   - Expected: Generated code, timestamps
   
3. **Network latency**: Remote CAS adds latency to materialization
   - Mitigation: Local cache tier

## Future Enhancements

1. **Compression**: LZ4/Zstd compression for large sources
2. **Streaming**: Stream large files instead of full read
3. **Partial fetch**: Fetch only changed chunks (rsync-like)
4. **Background prefetch**: Predict needed sources, prefetch async
5. **CDN integration**: Serve sources from CDN for distributed builds

## See Also

- [CAS Design](../architecture/cachedesign.md)
- [Incremental Builds](./incremental.md)
- [Remote Caching](./remotecache.md)
- [Hermetic Builds](./hermetic.md)

