# Cache Coordinator Architecture

**Status:** Implemented  
**Module:** `engine.caching.coordinator`

## Overview

The Cache Coordinator provides unified orchestration of all caching tiers, eliminating fragmentation where `BuildCache`, `ActionCache`, and `DistributedCache` operated independently.

### Features

1. **Single Source of Truth** - One coordinator for all cache operations
2. **Event-Driven Telemetry** - Automatic metrics collection
3. **Content-Addressable Storage** - Deduplication across targets/actions
4. **Garbage Collection** - Automatic cleanup of orphaned artifacts
5. **Bloom Filters** - Fast negative lookups
6. **Batch Validation** - Parallel cache checking

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   CacheCoordinator                       │
│              (Unified cache orchestration)               │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │
│  │BuildCache   │  │ActionCache  │  │RemoteCache  │     │
│  │(Targets)    │  │(Actions)    │  │(Distributed)│     │
│  └─────────────┘  └─────────────┘  └─────────────┘     │
│                                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │   ContentAddressableStorage (CAS)               │   │
│  │   - Deduplication by content hash               │   │
│  │   - Reference counting                          │   │
│  │   - Sharded storage (2-char prefix)             │   │
│  └─────────────────────────────────────────────────┘   │
│                                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │   Bloom Filters (fast negative lookups)         │   │
│  │   - targetBloom: 50K entries, 0.1% FPR          │   │
│  │   - actionBloom: 100K entries, 0.1% FPR         │   │
│  └─────────────────────────────────────────────────┘   │
│                                                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │   CacheGarbageCollector                         │   │
│  │   - Mark-and-sweep orphaned blobs               │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
                  ┌───────────────┐
                  │EventPublisher │
                  │ (telemetry)   │
                  └───────────────┘
```

## Components

### CacheCoordinator

Unified interface for all cache operations:

```d
final class CacheCoordinator {
    private CacheIndex sharedIndex;       // SQLite index
    private BuildCache targetCache;
    private ActionCache actionCache;
    private DependencyCache depCache;
    private IncrementalFilter filter;
    private RemoteCacheClient remoteCache;
    private ContentAddressableStorage cas;
    private CacheGarbageCollector gc;
    private SourceRepository sourceRepo;
    private SourceTracker sourceTracker;
    private DedupStore dedupStore;
    private BloomFilter targetBloom;
    private BloomFilter actionBloom;
    private EventPublisher publisher;
}
```

**Key Methods:**
```d
// Target cache operations
bool isCached(string targetId, const(string)[] sources, const(string)[] deps);
void update(string targetId, const(string)[] sources, const(string)[] deps, string outputHash);

// Batch validation
BatchValidationResult batchValidate(const(TargetValidationRequest)[] requests);
BatchActionValidationResult batchValidateActions(const(ActionValidationRequest)[] requests);

// Action cache operations
bool isActionCached(ActionId actionId, const(string)[] inputs, const(string[string]) metadata);
void recordAction(ActionId actionId, const(string)[] inputs, const(string)[] outputs,
                  const(string[string]) metadata, bool success);

// Maintenance
void flush();
void close();
BuildResult!size_t runGC();
CacheCoordinatorStats getStats();
```

### ContentAddressableStorage

Deduplicates artifacts by content hash:

```d
Result!(string, BuildError) putBlob(const(ubyte)[] data);  // Returns hash
Result!(ubyte[], BuildError) getBlob(string hash);
bool hasBlob(string hash);
void addRef(string hash);
bool removeRef(string hash);  // Returns true if deletable
```

### CacheGarbageCollector

Cleans up orphaned artifacts:

1. **Mark Phase**: Collect all referenced hashes from caches
2. **Sweep Phase**: Remove unreferenced blobs from CAS

```d
auto result = coordinator.runGC().unwrap();
writeln("Freed ", result, " bytes");
```

## Batch Validation

Validate multiple cache entries in parallel using work-stealing scheduler.

### Target Validation

```d
struct TargetValidationRequest {
    string targetId;
    string[] sources;
    string[] deps;
}

struct TargetValidationResult {
    string targetId;
    bool cached;
    bool fromRemote;  // True if hit came from remote cache
}

struct BatchValidationResult {
    TargetValidationResult[string] results;
    size_t totalTargets;
    size_t cachedTargets;
    size_t remoteCachedTargets;
    Duration duration;
    Duration averageTimePerTarget;
    
    float hitRate() const;
    float remoteHitRate() const;
}
```

**Usage:**
```d
auto requests = targets.map!(t => 
    TargetValidationRequest(t.id, t.sources, t.deps)
).array;

auto results = coordinator.batchValidate(requests);

writeln("Cache hit rate: ", results.hitRate() * 100, "%");
writeln("Remote hits: ", results.remoteCachedTargets);
```

### Action Validation

```d
struct ActionValidationRequest {
    ActionId actionId;
    string[] inputs;
    string[string] metadata;
}

struct BatchActionValidationResult {
    ActionValidationResult[string] results;
    size_t totalActions;
    size_t cachedActions;
    Duration duration;
    Duration averageTimePerAction;
    
    float hitRate() const;
}

auto results = coordinator.batchValidateActions(actionRequests);
```

### Performance

- **Single target**: Sequential (avoids overhead)
- **Multiple targets**: Work-stealing parallelism
- **Expected speedup**: 3-5x for large batches

## Bloom Filters

Fast negative lookups for cache entries:

```d
// Fast path: bloom filter says definitely not cached
if (targetBloom.valid && !targetBloom.mayContain(targetId)) {
    return false;  // Skip actual cache check
}

// Bloom filter says maybe cached, do actual check
return targetCache.isCached(targetId, sources, deps);
```

**Configuration:**
- Target bloom: 50,000 entries, 0.1% false positive rate
- Action bloom: 100,000 entries, 0.1% false positive rate

## Statistics

```d
struct CacheCoordinatorStats {
    // Target cache
    size_t targetCacheEntries;
    size_t targetCacheSize;
    float targetHitRate;
    
    // Action cache
    size_t actionCacheEntries;
    size_t actionCacheSize;
    float actionHitRate;
    
    // CAS
    size_t uniqueBlobs;
    size_t totalBlobSize;
    float deduplicationRatio;
    
    // Remote cache
    size_t remoteHits;
    size_t remoteMisses;
    float remoteHitRate;
    
    // Source repository
    size_t sourcesStored;
    size_t sourceDeduplicationHits;
    ulong sourceBytes;
    ulong sourceBytesSaved;
    float sourceDeduplicationRatio;
    
    // Deduplication
    size_t dedupUniqueBlobs;
    size_t dedupDuplicateRefs;
    ulong dedupSavedBytes;
    float dedupEfficiency;
}

auto stats = coordinator.getStats();
writeln("Target cache entries: ", stats.targetCacheEntries);
writeln("Action hit rate: ", stats.actionHitRate * 100, "%");
writeln("Deduplication ratio: ", stats.deduplicationRatio * 100, "%");
```

## Integration

### CacheService

`CacheService` wraps `CacheCoordinator` for dependency injection:

```d
final class CacheService : ICacheService {
    private CacheCoordinator coordinator;
    private CacheMetricsCollector metricsCollector;
    
    this(string cacheDir = ".builder-cache", EventPublisher publisher = null) {
        if (publisher !is null) {
            this.metricsCollector = new CacheMetricsCollector();
            publisher.subscribe(this.metricsCollector);
        }
        
        this.coordinator = new CacheCoordinator(cacheDir, publisher);
    }
    
    bool isCached(...) => coordinator.isCached(...);
    void update(...) => coordinator.update(...);
    void recordAction(...) => coordinator.recordAction(...);
}
```

### ExecutionEngine

Engine uses `ICacheService` interface:

```d
final class ExecutionEngine {
    private ICacheService cache;
    
    void buildTarget(Target target) {
        if (!cache.isCached(targetId, sources, deps)) {
            // Build
            cache.update(targetId, sources, deps, outputHash);
        }
    }
}
```

## Remote Cache

Remote cache is automatically checked if configured:

```d
// Check local first, then remote
if (targetCache.isCached(targetId, sources, deps))
    return true;  // Local hit

if (remoteCache !is null) {
    auto contentHash = computeContentHash(targetId, sources, deps);
    if (remoteCache.has(contentHash).match((ok) => ok, (_) => false))
        return true;  // Remote hit
}

return false;
```

**Async Push:**
Updates are pushed to remote cache asynchronously:

```d
if (remoteCache !is null && config.enableRemotePush) {
    (new Thread(() => pushToRemote(targetId, sources, deps, outputHash))).start();
}
```

## Configuration

Environment variables:

```bash
# Target cache
BUILDER_CACHE_MAX_SIZE=1073741824      # 1GB
BUILDER_CACHE_MAX_ENTRIES=10000
BUILDER_CACHE_MAX_AGE_DAYS=30

# Action cache
BUILDER_ACTION_CACHE_MAX_SIZE=1073741824
BUILDER_ACTION_CACHE_MAX_ENTRIES=50000

# Remote cache
BUILDER_REMOTE_CACHE_URL=http://cache.example.com:8080
BUILDER_REMOTE_CACHE_TOKEN=...
BUILDER_REMOTE_CACHE_TIMEOUT=30
BUILDER_REMOTE_CACHE_RETRY_COUNT=3
```

## Usage Example

```d
auto publisher = new EventPublisher();
auto coordinator = new CacheCoordinator(".builder-cache", publisher);

// Check cache
if (!coordinator.isCached(targetId, sources, deps)) {
    // Build target
    auto outputHash = buildTarget(target);
    
    // Update cache
    coordinator.update(targetId, sources, deps, outputHash);
}

// Batch validation
auto requests = targets.map!(t => TargetValidationRequest(t.id, t.sources, t.deps)).array;
auto results = coordinator.batchValidate(requests);

// Garbage collection
coordinator.runGC();

// Cleanup
coordinator.flush();
coordinator.close();
```

## See Also

- [Action Caching](./caching.md)
- [Remote Caching](./remotecache.md)
- [Content-Addressed Sources](./content-addressed-sources.md)
- [CAS Design](../architecture/cachedesign.md)
