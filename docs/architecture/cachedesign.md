# Action-Level Caching Architecture

## Executive Summary

Action-level caching extends Builder's caching system from target-level granularity to individual build steps (actions). This enables incremental builds at the action level, improving rebuild performance and cache utilization.

### Key Metrics
- **Granularity**: Individual actions (compile, link, test) vs. entire targets
- **Cache Entries**: 50,000 actions (default) vs. 10,000 targets
- **Storage**: ~512 bytes per action vs. ~256 bytes per target
- **Hit Rate Improvement**: 2-3x in typical incremental build scenarios

## Design Principles

### 1. Non-Invasive Integration
- **No Core Structure Changes**: BuildNode and Target remain unchanged
- **Backward Compatible**: Existing handlers work without modification
- **Opt-In**: Handlers choose to implement action-level caching
- **Dual Caching**: Target and action caches coexist independently

### 2. Composability
- **ActionId**: Composite key = targetId + actionType + inputHash + subId
- **Flexible Actions**: Handlers define their own action granularity
- **Hierarchical**: Actions belong to targets, enabling both caching levels

### 3. Security & Integrity
- **BLAKE3 HMAC**: Same security as target cache
- **Workspace Isolation**: Per-workspace signing keys
- **Tamper Detection**: Cryptographic verification
- **Expiration**: Configurable age-based eviction

### 4. Performance
- **SIMD Acceleration**: Hash comparisons and data transfer
- **Binary Serialization**: Compact, fast format
- **Buffer Pooling**: Reduced GC pressure
- **Hash Memoization**: Avoid duplicate hashing within build session

## Architecture Diagram

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

## Component Specifications

### ActionId (Composite Key)

```d
struct ActionId
{
    string targetId;      // Parent target ("myapp")
    ActionType type;      // Compile, Link, Test, etc.
    string inputHash;     // Hash of action inputs
    string subId;         // Optional identifier ("src/main.cpp")
}
```

**Key Properties:**
- **Uniqueness**: No collisions within or across targets
- **Determinism**: Same inputs → same ActionId
- **Composability**: Multiple actions per target
- **Readability**: Human-interpretable string format

**Example ActionIds:**
```
myapp:Compile:abc123:src/main.cpp
myapp:Compile:def456:src/utils.cpp
myapp:Link:789xyz:
myapp:Test:111aaa:
```

### ActionEntry (Cache Value)

```d
struct ActionEntry
{
    ActionId actionId;                  // Composite identifier
    string[] inputs;                    // Input files
    string[string] inputHashes;         // Input content hashes
    string[] outputs;                   // Output files
    string[string] outputHashes;        // Output content hashes
    string[string] metadata;            // Execution context
    SysTime timestamp;                  // Creation time
    SysTime lastAccess;                 // LRU tracking
    string executionHash;               // Metadata hash
    bool success;                       // Execution result
}
```

**Validation Logic:**
```d
bool isValid(ActionEntry entry)
{
    // 1. Check previous success
    if (!entry.success)
        return false;
    
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

### ActionCache (Storage & Management)

**Public API:**
```d
class ActionCache
{
    // Check if action is cached and valid
    bool isCached(ActionId id, string[] inputs, string[string] metadata);
    
    // Update cache with action result
    void update(ActionId id, string[] inputs, string[] outputs, 
                string[string] metadata, bool success);
    
    // Invalidate action
    void invalidate(ActionId id);
    
    // Flush to disk
    void flush(bool runEviction = true);
    
    // Statistics
    ActionCacheStats getStats();
}
```

**Internal Mechanisms:**
- **Storage**: Binary serialization via ActionStorage
- **Security**: BLAKE3 HMAC signatures
- **Eviction**: LRU + age + size limits
- **Thread Safety**: Mutex-synchronized access
- **Hash Cache**: Per-session memoization

### BuildContext (Handler Integration)

```d
struct BuildContext
{
    Target target;
    WorkspaceConfig config;
    ActionRecorder recorder;  // Callback to ActionCache
    
    void recordAction(ActionId id, string[] inputs, string[] outputs,
                      string[string] metadata, bool success);
}
```

**Usage Pattern:**
1. Executor creates BuildContext with ActionRecorder
2. Passes context to handler's `buildWithContext()`
3. Handler executes actions, calls `context.recordAction()`
4. Recorder updates ActionCache asynchronously

## Data Flow

### Build Execution Flow

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
   │  │  │
   │  │  ├─ Create ActionId (Compile)
   │  │  │
   │  │  ├─ Check if ActionCache.isCached(actionId)
   │  │  │  ├─ HIT  → Skip compilation
   │  │  │  └─ MISS → Compile
   │  │  │
   │  │  └─ context.recordAction(actionId, ...)
   │  │
   │  └─ Link phase:
   │     ├─ Create ActionId (Link)
   │     ├─ Check ActionCache
   │     └─ context.recordAction(linkId, ...)
   │
   ├─ BuildCache.update(targetId, ...)
   │
   └─ ActionCache.flush()
```

### Cache Invalidation Flow

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
│       ├── targetId
│       ├── buildHash
│       ├── sourceHashes
│       └── ...
│
└── actions/
    └── actions.bin          # Action-level cache
        ├── Header (ACTC magic)
        ├── Version (1)
        ├── Entry count
        └── Entries[]
            ├── ActionId
            │   ├── targetId
            │   ├── type (enum)
            │   ├── inputHash
            │   └── subId
            ├── inputs[]
            ├── inputHashes{}
            ├── outputs[]
            ├── outputHashes{}
            ├── metadata{}
            ├── timestamp
            ├── lastAccess
            ├── executionHash
            └── success (bool)
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
│  - count (4 bytes)                   │
│  - pairs (key, value)                │
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

## Performance Analysis

### Theoretical Bounds

**Time Complexity:**
- Cache check: O(inputs) - hash each input file
- Cache update: O(inputs + outputs) - hash all files
- Eviction: O(n log n) - sort by LRU

**Space Complexity:**
- Per action: ~512 bytes base + file paths
- 50,000 actions: ~25 MB typical
- With compression: ~10-15 MB potential

### Empirical Results

**Scenario: Large C++ Project (1000 files)**

| Build Type | Target Cache | Action Cache | Speedup |
|------------|-------------|--------------|---------|
| Clean | 0% | 0% | 1.0x (baseline) |
| Full cached | 100% | N/A | 100x |
| 1 file changed | 0% | 99.9% | 50x |
| 10 files changed | 0% | 99% | 25x |
| Header changed | 0% | 70% | 8x |

**Memory Overhead:**
- Action cache: +12 MB (1000 files)
- Hash memoization: +5 MB (build session)
- Total overhead: ~20 MB

**Disk I/O:**
- Initial load: 15 ms (cold)
- Subsequent loads: 5 ms (warm)
- Flush: 20 ms (with eviction)

## Comparison with Alternatives

### Build System Comparison

| Feature | Builder Action Cache | Bazel | Buck2 | Ninja |
|---------|---------------------|-------|-------|-------|
| Granularity | Action-level | Action-level | Action-level | Command-level |
| Security | BLAKE3 HMAC | SHA256 | BLAKE3 | None |
| Distribution | Local (v1) | Remote | Remote | Local |
| Language-agnostic | Yes | Yes | Yes | No |
| Incremental | Yes | Yes | Yes | Yes |
| Metadata tracking | Yes | Yes | Yes | No |

### Trade-offs

**Advantages:**
- ✓ Finer granularity than target-level
- ✓ Reuse partial work on failure
- ✓ Language handler flexibility
- ✓ Security through HMAC
- ✓ Minimal core changes

**Disadvantages:**
- ✗ Higher storage overhead
- ✗ More cache checks per build
- ✗ Handler complexity increase
- ✗ No distributed caching (yet)

## Future Work

### Phase 2: Distributed Caching
```d
interface DistributedCache
{
    bool tryFetch(ActionId id, string outputPath);
    void upload(ActionId id, string outputPath);
}
```

### Phase 3: Content-Addressable Storage
```d
// Store outputs by content hash
string uploadContent(ubyte[] data) → hash
ubyte[] downloadContent(string hash)
```

### Phase 4: Machine Learning
```d
// Predict which actions will be needed
ActionId[] predictNextActions(BuildHistory history)
```

### Phase 5: Cross-Target Optimization
```d
// Share compilation results across targets
ActionId normalizeActionId(ActionId id)
```

## Testing Strategy

### Unit Tests
- ActionId serialization/deserialization
- ActionEntry validation logic
- ActionCache CRUD operations
- Eviction policy correctness

### Integration Tests
- End-to-end build with action caching
- Incremental build correctness
- Cache invalidation on file changes
- Multi-threaded access safety

### Performance Tests
- Cache check overhead
- Serialization speed
- Memory usage under load
- Eviction performance

### Stress Tests
- 100,000+ actions
- Concurrent builds
- Disk full scenarios
- Corrupt cache recovery

## Security Considerations

### Threat Model

**Threats Mitigated:**
1. Cache poisoning: HMAC prevents unauthorized modifications
2. Replay attacks: Timestamp validation
3. Cross-workspace leaks: Per-workspace keys

**Threats NOT Mitigated:**
1. Physical disk access: File system permissions
2. Root/admin compromise: Out of scope
3. Side-channel attacks: Not applicable

### HMAC Implementation

```d
// Signing
SignedData sign(ubyte[] data)
{
    auto key = deriveKey(workspacePath);
    auto signature = blake3_hmac(key, data);
    auto timestamp = Clock.currTime();
    return SignedData(data, signature, timestamp);
}

// Verification
bool verify(SignedData signed)
{
    auto key = deriveKey(workspacePath);
    auto computed = blake3_hmac(key, signed.data);
    
    // Constant-time comparison
    if (!constantTimeEquals(computed, signed.signature))
        return false;
    
    // Check expiration
    if (Clock.currTime() - signed.timestamp > 30.days)
        return false;
    
    return true;
}
```

## Monitoring & Observability

### Metrics

```d
struct ActionCacheMetrics
{
    // Efficiency
    size_t hits;
    size_t misses;
    float hitRate;
    
    // Storage
    size_t totalEntries;
    size_t totalSize;
    size_t evictions;
    
    // Quality
    size_t successfulActions;
    size_t failedActions;
    float successRate;
    
    // Performance
    Duration avgCheckTime;
    Duration avgUpdateTime;
}
```

### Tracing Integration

Action cache operations are instrumented with OpenTelemetry spans:

```
build-execute
├── build-target (myapp)
│   ├── cache-check (target) [MISS]
│   ├── compile
│   │   ├── action-check (main.cpp) [HIT]
│   │   ├── action-check (utils.cpp) [MISS]
│   │   ├── action-execute (utils.cpp)
│   │   └── action-record (utils.cpp)
│   └── link
│       ├── action-check [MISS]
│       ├── action-execute
│       └── action-record
└── cache-update (target)
```

## Content-Defined Chunking for Large Artifacts

For artifacts exceeding 100MB, Builder uses FastCDC (Content-Defined Chunking) to enable delta transfers with 80-95% bandwidth savings.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                 Large Artifact (>100MB)                      │
└───────────────────────────┬─────────────────────────────────┘
                            │ FastCDC (gear hash)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Variable-size Chunks (8KB-256KB, content-defined)          │
│  [chunk1:hash1] [chunk2:hash2] [chunk3:hash3] ...           │
└───────────────────────────┬─────────────────────────────────┘
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

### Key Metrics

- **Chunking Speed**: ~500 MB/s (gear hash + BLAKE3)
- **Bandwidth Savings**: 80-95% for typical incremental changes
- **Chunk Deduplication**: 40-70% across similar artifacts
- **Threshold**: 100MB (configurable)

### Integration with Caching Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    Caching Architecture                      │
├─────────────────────────────────────────────────────────────┤
│  L1: Target Cache     - Full target outputs                  │
│  L2: Action Cache     - Individual action results            │
│  L3: Dedup CAS        - Content-addressed blobs              │
│  L4: Chunked CAS      - Large artifacts with CDC    ← NEW   │
│  L5: Remote Cache     - Distributed with delta transfers    │
└─────────────────────────────────────────────────────────────┘
```

## References

- [Target-Level Cache Implementation](../../source/engine/caching/targets/cache.d)
- [Chunked Storage](../../source/engine/caching/storage/chunked.d)
- [FastCDC Algorithm](../../source/infrastructure/utils/files/cdc.d)
- [Delta Transfer Protocol](../../source/engine/caching/distributed/remote/delta.d)
- [BLAKE3 Security Analysis](../features/blake3.md)
- [Language Handler Base](../../source/languages/base/base.d)
- [Performance Benchmarks](../features/performance.md)
- [Bazel Remote Caching](https://bazel.build/remote/caching)
- [Buck2 Architecture](https://buck2.build/docs/concepts/action_cache/)
- [FastCDC Paper](https://www.usenix.org/conference/atc16/technical-sessions/presentation/xia)

