# Action-Level Caching Architecture

## Overview

Action-level caching extends Builder's caching system from target-level to individual build steps (actions), enabling incremental builds at the action level for improved rebuild performance and cache utilization.

### Metrics
| Metric | Target Cache | Action Cache |
|--------|--------------|--------------|
| Granularity | Entire targets | Individual actions (compile, link, test) |
| Default entries | 10,000 | 50,000 |
| Storage per entry | ~256 bytes | ~512 bytes |
| Incremental hit rate | 1x baseline | 2-3x improvement |

## Design Principles

### Non-Invasive Integration
- No core structure changes to BuildNode or Target
- Backward compatible with existing handlers
- Opt-in: Handlers choose to implement action-level caching
- Dual caching: Target and action caches operate independently

### Composability
- **ActionId**: Composite key = targetId + actionType + inputHash + subId
- Handlers define their own action granularity
- Actions belong to targets, enabling both caching levels

### Security & Integrity
- BLAKE3 HMAC signatures prevent tampering
- Workspace-specific signing keys for isolation
- Automatic expiration (30 days default)
- Constant-time signature verification

### Performance
- SIMD-accelerated hash comparisons
- Binary serialization (5-10x faster than JSON)
- Buffer pooling reduces GC pressure
- Hash memoization avoids duplicate hashing within build session

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        BuildExecutor                         │
│                                                              │
│  ┌────────────────┐              ┌─────────────────────┐   │
│  │  BuildCache    │              │   ActionCache       │   │
│  │  (Target-Level)│              │  (Action-Level)     │   │
│  │                │              │                     │   │
│  │ - isCached()   │              │ - isCached()        │   │
│  │ - update()     │              │ - update()          │   │
│  │ - flush()      │              │ - flush()           │   │
│  └────────────────┘              └─────────────────────┘   │
│         │                                   ▲               │
│         │                                   │               │
│         ▼                                   │               │
│  ┌─────────────────────────────────────────┼──────────┐   │
│  │           LanguageHandler                │          │   │
│  │                                          │          │   │
│  │  buildWithContext(BuildContext)         │          │   │
│  │    │                                     │          │   │
│  │    ├─ Compile Actions ─────────── recordAction()   │   │
│  │    ├─ Link Actions ────────────── recordAction()   │   │
│  │    └─ Test Actions ────────────── recordAction()   │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
  ┌─────────────┐                    ┌───────────────┐
  │ cache.bin   │                    │ actions.bin   │
  │ (Targets)   │                    │ (Actions)     │
  └─────────────┘                    └───────────────┘
```

## Core Types

### ActionId

Composite key for action identification:

```d
struct ActionId
{
    string targetId;      // Parent target ("myapp")
    ActionType type;      // Compile, Link, Test, etc.
    string inputHash;     // Hash of action inputs
    string subId;         // Optional identifier ("src/main.cpp")
}
```

**ActionType enum values**: `Compile`, `Link`, `Codegen`, `Test`, `Package`, `Transform`, `Lint`, `TypeCheck`, `Custom`

**Example ActionIds**:
```
myapp:Compile:abc123:src/main.cpp
myapp:Compile:def456:src/utils.cpp
myapp:Link:789xyz:
myapp:Test:111aaa:
```

### ActionEntry

Cache entry storing action results:

```d
struct ActionEntry
{
    ActionId actionId;
    string[] inputs;
    string[string] inputHashes;
    string[] outputs;
    string[string] outputHashes;
    string[string] metadata;
    SysTime timestamp;
    SysTime lastAccess;
    string executionHash;
    bool success;
    
    // Determinism tracking
    bool isDeterministic;
    string verificationHash;
    uint determinismVerifications;
}
```

### ActionCache

```d
final class ActionCache
{
    // Check if action is cached and valid
    bool isCached(ActionId id, string[] inputs, string[string] metadata);
    
    // Update cache with action result
    void update(ActionId id, string[] inputs, string[] outputs, 
                string[string] metadata, bool success);
    
    // Invalidate action
    void invalidate(ActionId actionId);
    
    // Flush to disk
    void flush(bool runEviction = true);
    
    // Statistics
    ActionCacheStats getStats();
}
```

**Configuration** (via environment variables):
- `BUILDER_ACTION_CACHE_MAX_SIZE`: Max cache size in bytes (default: 1GB)
- `BUILDER_ACTION_CACHE_MAX_ENTRIES`: Max entries (default: 50,000)
- `BUILDER_ACTION_CACHE_MAX_AGE_DAYS`: Max age in days (default: 30)

### BuildContext

Integration point for language handlers:

```d
struct BuildContext
{
    Target target;
    WorkspaceConfig config;
    IServiceContainer services;
    ActionRecorder recorder;
    DependencyRecorder depRecorder;
    bool incrementalEnabled;
    
    void recordAction(ActionId id, string[] inputs, string[] outputs,
                      string[string] metadata, bool success);
    void recordDependencies(string sourceFile, string[] deps);
}
```

## Validation Logic

```d
bool isValid(ActionEntry entry)
{
    // 1. Check previous success
    if (!entry.success) return false;
    
    // 2. Validate inputs unchanged
    foreach (input; entry.inputs)
    {
        if (hash(input) != entry.inputHashes[input])
            return false;
    }
    
    // 3. Validate outputs exist
    foreach (output; entry.outputs)
    {
        if (!exists(output))
            return false;
    }
    
    // 4. Validate execution context
    if (currentMetadataHash() != entry.executionHash)
        return false;
    
    return true;
}
```

## Data Flow

### Build Execution

```
1. BuildExecutor.execute()
   │
   ├─ Check BuildCache (target-level)
   │  └─ MISS
   │
   ├─ Create BuildContext with ActionRecorder
   │
   ├─ Call handler.buildWithContext(context)
   │  │
   │  ├─ For each source file:
   │  │  ├─ Create ActionId (Compile)
   │  │  ├─ Check ActionCache.isCached(actionId)
   │  │  │  ├─ HIT  → Skip compilation
   │  │  │  └─ MISS → Compile
   │  │  └─ context.recordAction(actionId, ...)
   │  │
   │  └─ Link phase:
   │     ├─ Create ActionId (Link)
   │     ├─ Check ActionCache
   │     └─ context.recordAction(linkId, ...)
   │
   ├─ BuildCache.update(targetId, ...)
   └─ ActionCache.flush()
```

### Cache Invalidation

```
File Change (src/main.cpp)
   │
   ├─ Target cache INVALID (source changed)
   │
   ├─ Action caches:
   │  ├─ main.cpp:Compile → INVALID (input changed)
   │  ├─ utils.cpp:Compile → VALID (input unchanged)
   │  └─ Link → INVALID (dependency changed)
   │
   └─ Rebuild:
      ├─ Recompile main.cpp only
      ├─ Reuse utils.cpp.o
      └─ Relink executable
```

## Storage Format

### File Structure

```
.builder-cache/
├── cache.bin                # Target-level cache
│   ├── Header (BLDC magic)
│   ├── Version (1)
│   ├── Entry count
│   └── Entries[]
│
└── actions/
    └── actions.bin          # Action-level cache
        ├── Header (ACTC magic)
        ├── Version (1)
        ├── Entry count
        └── Entries[]
```

### Binary Encoding

```
Entry Format:
┌──────────────────────────────────────┐
│ ActionId                             │
│  - targetId (length-prefixed string) │
│  - type (1 byte)                     │
│  - inputHash (length-prefixed)       │
│  - subId (length-prefixed)           │
├──────────────────────────────────────┤
│ inputs (array of strings)            │
├──────────────────────────────────────┤
│ inputHashes (map)                    │
├──────────────────────────────────────┤
│ outputs (array of strings)           │
├──────────────────────────────────────┤
│ outputHashes (map)                   │
├──────────────────────────────────────┤
│ metadata (map)                       │
├──────────────────────────────────────┤
│ timestamp (8 bytes)                  │
├──────────────────────────────────────┤
│ lastAccess (8 bytes)                 │
├──────────────────────────────────────┤
│ executionHash (length-prefixed)      │
├──────────────────────────────────────┤
│ success (1 byte boolean)             │
└──────────────────────────────────────┘
```

## Performance

### Complexity

| Operation | Time Complexity |
|-----------|----------------|
| Cache check | O(inputs) |
| Cache update | O(inputs + outputs) |
| Eviction | O(n log n) |

### Space

| Item | Size |
|------|------|
| Per action | ~512 bytes + file paths |
| 50,000 actions | ~25 MB typical |

### Benchmark: Large C++ Project (1000 files)

| Build Type | Target Cache | Action Cache | Speedup |
|------------|-------------|--------------|---------|
| Clean | 0% | 0% | 1.0x baseline |
| Full cached | 100% | N/A | ~100x |
| 1 file changed | 0% | 99.9% | ~50x |
| 10 files changed | 0% | 99% | ~25x |
| Header changed | 0% | 70% | ~8x |

## Content-Defined Chunking for Large Artifacts

For artifacts exceeding 100MB, Builder uses FastCDC (Content-Defined Chunking) for delta transfers with 80-95% bandwidth savings.

### Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                 Large Artifact (>100MB)                       │
└───────────────────────────┬──────────────────────────────────┘
                            │ FastCDC (gear hash)
                            ▼
┌──────────────────────────────────────────────────────────────┐
│  Variable-size Chunks (8KB-256KB, content-defined)           │
└───────────────────────────┬──────────────────────────────────┘
                            │
         ┌──────────────────┼──────────────────┐
         ▼                  ▼                  ▼
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│ ChunkedCAS     │  │ ChunkManifest  │  │ DeltaTransfer  │
│ (local store)  │  │ (metadata)     │  │ (remote sync)  │
└────────────────┘  └────────────────┘  └────────────────┘
```

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| FastCDC | `infrastructure/utils/files/cdc.d` | Gear-based chunking algorithm |
| ChunkedCAS | `engine/caching/storage/chunked.d` | Chunk-aware CAS with auto-threshold |
| DeltaTransfer | `engine/caching/distributed/remote/delta.d` | Delta transfer protocol |

### Metrics

- **Chunking Speed**: ~500 MB/s (gear hash + BLAKE3)
- **Bandwidth Savings**: 80-95% for typical incremental changes
- **Chunk Deduplication**: 40-70% across similar artifacts
- **Threshold**: 100MB (configurable)

### Caching Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    Caching Architecture                      │
├─────────────────────────────────────────────────────────────┤
│  L1: Target Cache     - Full target outputs                  │
│  L2: Action Cache     - Individual action results            │
│  L3: Dedup CAS        - Content-addressed blobs              │
│  L4: Chunked CAS      - Large artifacts with CDC             │
│  L5: Remote Cache     - Distributed with delta transfers     │
└─────────────────────────────────────────────────────────────┘
```

## Comparison

| Feature | Builder | Bazel | Buck2 | Ninja |
|---------|---------|-------|-------|-------|
| Granularity | Action-level | Action-level | Action-level | Command-level |
| Security | BLAKE3 HMAC | SHA256 | BLAKE3 | None |
| Distribution | Local (remote planned) | Remote | Remote | Local |
| Language-agnostic | Yes | Yes | Yes | No |
| Metadata tracking | Yes | Yes | Yes | No |

## Future Work

- **Distributed Caching**: Remote cache servers with delta sync
- **Content-Addressable Storage**: Store outputs by content hash
- **Cross-Target Optimization**: Share compilation results across targets

## Source Files

| Component | File |
|-----------|------|
| Target Cache | `source/engine/caching/targets/cache.d` |
| Action Cache | `source/engine/caching/actions/action.d` |
| Chunked Storage | `source/engine/caching/storage/chunked.d` |
| FastCDC | `source/infrastructure/utils/files/cdc.d` |
| Delta Transfer | `source/engine/caching/distributed/remote/delta.d` |
| Language Handler Base | `source/languages/base/base.d` |
