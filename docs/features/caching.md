# Action-Level Caching

## Overview

Action-level caching provides finer granularity than target-level caching by tracking individual build steps (actions) within a target:

- **Incremental Builds**: Reuse successful actions even if later actions fail
- **Partial Rebuilds**: Only re-execute changed actions
- **Better Cache Utilization**: More precise invalidation

## Architecture

### Components

Located in `source/engine/caching/actions/`:

1. **ActionCache** (`action.d`)
   - Fine-grained cache for individual build actions
   - BLAKE3-based hashing with HMAC signatures
   - LRU eviction policy
   - SQLite-backed index for metadata queries

2. **ActionStorage** (`storage.d`)
   - Binary serialization for cache entries
   - SIMD-accelerated operations via Codec
   - Schema-based versioning

3. **ActionEntry** - Cache entry structure
4. **ActionId** - Composite action identifier

### Action Types

```d
enum ActionType : ubyte
{
    Compile,      // Compilation step
    Link,         // Linking step
    Codegen,      // Code generation (protobuf, etc)
    Test,         // Test execution
    Package,      // Packaging/bundling
    Transform,    // Asset transformation
    Lint,         // Linting/static analysis
    TypeCheck,    // Type checking
    Custom        // User-defined action
}
```

## Data Structures

### ActionId

Composite key for unique action identification:

```d
struct ActionId
{
    string targetId;      // Parent target
    ActionType type;      // Type of action
    string inputHash;     // Hash of action inputs
    string subId;         // Optional sub-identifier (e.g., source filename)
    
    // Format: "targetId:type:subId:inputHash" or "targetId:type:inputHash"
    string toString();
    static BuildResult!ActionId parse(string str);
}
```

### ActionEntry

```d
struct ActionEntry
{
    ActionId actionId;                  // Composite identifier
    string[] inputs;                    // Input files
    string[string] inputHashes;         // Input file hashes
    string[] outputs;                   // Output files
    string[string] outputHashes;        // Output file hashes
    string[string] metadata;            // Execution context (flags, env)
    SysTime timestamp;                  // Creation time
    SysTime lastAccess;                 // Last access (LRU)
    string executionHash;               // Hash of execution context
    bool success;                       // Whether action succeeded
    
    // Determinism tracking
    bool isDeterministic;               // Verified deterministic?
    string verificationHash;            // Hash for verification
    uint determinismVerifications;      // Successful verification count
}
```

## Usage

### For Language Handler Authors

Language handlers can use action-level caching by creating ActionIds and calling the cache:

```d
import engine.caching.actions.action;

// Create action ID
auto actionId = ActionId(
    target.name,              // Target ID
    ActionType.Compile,       // Action type
    hashFile(source),         // Input hash
    source                    // Sub-identifier
);

// Prepare metadata
string[string] metadata;
metadata["flags"] = target.flags.join(" ");
metadata["compiler"] = "gcc";

// Check cache
if (actionCache.isCached(actionId, [source], metadata))
{
    writeln("  [Cached] ", source);
    return;  // Skip execution
}

// Execute compilation...
auto result = compileFile(source, config);

// Record result
actionCache.update(
    actionId,
    [source],           // Inputs
    [result.objectFile], // Outputs
    metadata,
    result.success
);
```

### Cache Validation

An action is considered valid if:

1. **Entry Exists**: ActionId matches an entry
2. **Action Succeeded**: Previous execution was successful
3. **Inputs Unchanged**: All input files have same content hashes
4. **Outputs Exist**: All output files still exist on disk
5. **Metadata Unchanged**: Flags, environment variables match

```d
// Two-tier validation:
// 1. Fast metadata check (mtime + size)
// 2. Content hash only if metadata changed

auto cached = hashCache.get(input);
auto currentMeta = FastHash.hashMetadata(input);

if (cached.found && cached.metadataHash == currentMeta)
    currentHash = cached.contentHash;  // Fast path
else
    currentHash = FastHash.hashFile(input);  // Hash content
```

## Performance

### Optimizations

- **Hash Memoization**: Per-session hash cache avoids duplicate hashing
- **SIMD Acceleration**: Fast hash comparison (`SIMDHash.equals`)
- **Binary Serialization**: Schema-based codec (~10x faster than JSON)
- **Two-Tier Validation**: Metadata check before content hash
- **Async Hashing**: io_uring for cold cache scenarios (>8 files)
- **SQLite Index**: Efficient queries and eviction selection

### Space Complexity

- **Per Action**: ~512 bytes (estimated)
- **Default Limit**: 50,000 actions
- **Configurable**: Via environment variables

### Time Complexity

- **Cache Check**: O(inputs) - hash comparison per input
- **Cache Update**: O(inputs + outputs) - hash computation
- **Eviction**: Via SQLite index queries

## Configuration

### Environment Variables

```bash
# Maximum cache size (bytes)
export BUILDER_ACTION_CACHE_MAX_SIZE=1073741824  # 1 GB

# Maximum number of actions
export BUILDER_ACTION_CACHE_MAX_ENTRIES=50000

# Maximum age (days)
export BUILDER_ACTION_CACHE_MAX_AGE_DAYS=30
```

### Programmatic Configuration

```d
ActionCacheConfig config;
config.maxSize = 1_073_741_824;   // 1 GB
config.maxEntries = 50_000;
config.maxAge = 30;               // days

// Or from environment
config = ActionCacheConfig.fromEnvironment();
```

### Cache Location

```
.builder-cache/
  ├── cache.bin          # Target-level cache
  └── actions/
      └── actions.bin    # Action-level cache
```

## Integration with Target-Level Cache

Both caching layers work together:

1. **Target Cache Check**: First check if entire target is cached
2. **Action Cache Check**: If target miss, check action cache for individual steps
3. **Partial Rebuild**: Execute only uncached actions
4. **Update Both**: After successful build, update both caches

```
Is target cached?
├─ Yes → Skip build (fastest path)
└─ No → Check action cache
    ├─ Some actions cached → Partial rebuild
    └─ No actions cached → Full rebuild
```

## Statistics

```d
struct ActionCacheStats
{
    size_t totalEntries;
    size_t totalSize;
    size_t hits;
    size_t misses;
    float hitRate;
    size_t successfulActions;
    size_t failedActions;
    size_t indexHits;
    size_t indexMisses;
    float indexHitRate;
}

auto stats = actionCache.getStats();
writefln("Action Cache:");
writefln("  Total actions: %d", stats.totalEntries);
writefln("  Cache size: %.1f MB", stats.totalSize / (1024.0 * 1024.0));
writefln("  Hit rate: %.1f%%", stats.hitRate);
```

## Security

- **BLAKE3 HMAC**: Signatures prevent tampering
- **Workspace-specific keys**: Isolation via `IntegrityValidator`
- **Automatic expiration**: Default 30 days

```d
// Signature verification on load
if (!validator.verifyWithMetadata(signed))
{
    // Cache corrupted or tampered - start fresh
    entries.clear();
}

// Expiration check
if (IntegrityValidator.isExpired(signed, 30.days))
{
    entries.clear();
}
```

## Best Practices

### 1. Deterministic Actions

```d
// Good: Reproducible compilation
metadata["compiler"] = "gcc-11.2.0";
metadata["flags"] = "-O2 -Wall";

// Bad: Non-deterministic timestamps
metadata["build_time"] = Clock.currTime().toString();
```

### 2. Granular Action IDs

```d
// Good: Per-file action
ActionId(target, ActionType.Compile, hash, "src/main.cpp")

// Less granular
ActionId(target, ActionType.Compile, hash, "all_sources")
```

### 3. Minimal Metadata

```d
// Good: Only build-affecting flags
metadata["optimization"] = "-O2";

// Bad: Irrelevant metadata
metadata["user"] = getUsername();
```

### 4. Track All Dependencies

```d
// Good: Include headers
inputs = [sourceFile] ~ getHeaderDependencies(sourceFile);

// Bad: Missing implicit dependencies
inputs = [sourceFile];  // Headers not tracked!
```

## API Reference

### ActionCache

```d
final class ActionCache
{
    // Constructor
    this(string cacheDir = ".builder-cache/actions",
         ActionCacheConfig config = ActionCacheConfig.init,
         CacheIndex sharedIndex = null);
    
    // Check if action is cached and valid
    bool isCached(ActionId actionId,
                  scope const(string)[] inputs,
                  scope const(string[string]) metadata);
    
    // Update cache entry
    void update(ActionId actionId,
                scope const(string)[] inputs,
                scope const(string)[] outputs,
                scope const(string[string]) metadata,
                bool success);
    
    // Invalidate entry
    void invalidate(ActionId actionId);
    
    // Clear entire cache
    void clear();
    
    // Flush to disk
    void flush(bool runEviction = true);
    
    // Get statistics
    ActionCacheStats getStats();
    
    // Get actions for a target
    ActionEntry[] getActionsForTarget(string targetId);
    
    // List all action keys
    string[] listActions();
    
    // Close and flush
    void close();
}
```

## Related

- [Cache Coordinator](./coordinator.md) - Multi-tier caching architecture
- [BLAKE3 Security](./blake3.md)
- [Incremental Compilation](./incremental-compilation.md)
