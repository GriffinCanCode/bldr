# Action-Level Caching

## Overview

Action-level caching provides finer granularity than traditional target-level caching by tracking individual build steps (actions) within a target. This enables:

- **Incremental Builds**: Reuse successful actions even if later actions fail
- **Partial Rebuilds**: Only re-execute changed actions
- **Better Cache Utilization**: More precise invalidation and reuse
- **Improved Performance**: Skip unchanged compilation steps

## Architecture

### Components

1. **ActionCache** (`source/engine/caching/actions/action.d`)
   - Fine-grained cache for individual build actions
   - Tracks inputs, outputs, and execution context per action
   - BLAKE3-based security with HMAC signatures
   - LRU eviction policy

2. **ActionStorage** (`source/engine/caching/actions/storage.d`)
   - Binary serialization for action cache entries
   - SIMD-accelerated operations
   - Buffer pooling for reduced GC pressure

3. **BuildContext** (`source/languages/base/base.d`)
   - Context object passed to language handlers
   - Contains ActionRecorder callback for reporting actions

### Action Types

```d
enum ActionType : ubyte
{
    Compile,      // Compilation step (per file or batch)
    Link,         // Linking step
    Codegen,      // Code generation (protobuf, etc)
    Test,         // Test execution
    Package,      // Packaging/bundling
    Transform,    // Asset transformation
    Custom        // Custom user-defined action
}
```

## Usage

### For Language Handler Authors

Language handlers can opt into action-level caching by overriding `buildWithContext`:

```d
class MyLanguageHandler : BaseLanguageHandler
{
    override Result!(string, BuildError) buildWithContext(BuildContext context) @safe
    {
        auto target = context.target;
        auto config = context.config;
        
        // Compile phase
        foreach (i, source; target.sources)
        {
            // Create action ID
            auto actionId = ActionId(
                target.name,              // Target ID
                ActionType.Compile,       // Action type
                hashFile(source),         // Input hash
                source                    // Sub-identifier
            );
            
            // Prepare metadata (flags, env, etc)
            string[string] metadata;
            metadata["flags"] = target.flags.join(" ");
            metadata["compiler"] = "gcc";
            
            // Check if action is cached
            auto cached = checkActionCache(actionId, [source], metadata);
            if (cached)
            {
                writeln("  [Cached] ", source);
                continue;
            }
            
            // Execute compilation
            auto result = compileFile(source, config);
            
            // Record action result
            context.recordAction(
                actionId,
                [source],                           // Inputs
                [result.objectFile],                // Outputs
                metadata,                           // Metadata
                result.success                      // Success flag
            );
            
            if (!result.success)
                return Err!(string, BuildError)(result.error);
        }
        
        // Link phase
        auto linkActionId = ActionId(
            target.name,
            ActionType.Link,
            hashCombine(target.sources),
            ""
        );
        
        string[string] linkMetadata;
        linkMetadata["linker"] = "ld";
        linkMetadata["flags"] = target.flags.join(" ");
        
        auto linkResult = linkObjects(objectFiles, config);
        
        context.recordAction(
            linkActionId,
            objectFiles,                // Inputs
            [linkResult.executable],    // Outputs
            linkMetadata,
            linkResult.success
        );
        
        if (linkResult.success)
            return Ok!(string, BuildError)(linkResult.hash);
        else
            return Err!(string, BuildError)(linkResult.error);
    }
}
```

### Benefits

1. **Compile Once, Link Multiple Times**: If only linker flags change, reuse compiled objects
2. **Per-File Incremental Builds**: Only recompile changed source files
3. **Test Caching**: Skip unchanged test executions
4. **Codegen Caching**: Reuse generated code when specs unchanged

## Implementation Details

### ActionId Structure

```d
struct ActionId
{
    string targetId;      // Parent target
    ActionType type;      // Type of action
    string inputHash;     // Hash of action inputs
    string subId;         // Optional sub-identifier (e.g., filename)
}
```

The composite key ensures:
- **Uniqueness**: Each action has a distinct identifier
- **Determinism**: Same inputs = same ActionId
- **Granularity**: Multiple actions per target possible

### ActionEntry Structure

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
}
```

### Cache Validation

An action is considered valid (cached) if:

1. **Entry Exists**: ActionId matches an entry
2. **Action Succeeded**: Previous execution was successful
3. **Inputs Unchanged**: All input files have same content hashes
4. **Outputs Exist**: All output files still exist on disk
5. **Context Unchanged**: Flags, environment variables, etc. match

## Performance Characteristics

### Space Complexity
- **Per Action**: ~512 bytes (estimated)
- **Default Limit**: 50,000 actions (~25 MB)
- **Configurable**: `BUILDER_ACTION_CACHE_MAX_ENTRIES`

### Time Complexity
- **Cache Check**: O(inputs) - hash comparison per input
- **Cache Update**: O(inputs + outputs) - hash computation
- **Eviction**: O(n log n) - LRU sort when limit exceeded

### Optimizations
- **Hash Memoization**: Per-build hash cache avoids duplicate hashing
- **SIMD Acceleration**: Fast hash comparison and data transfer
- **Binary Serialization**: 5-10x faster than JSON
- **Two-Tier Validation**: Metadata check before content hash

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

### Cache Location

Actions are stored separately from targets:
```
.builder-cache/
  ├── cache.bin          # Target-level cache
  └── actions/
      └── actions.bin    # Action-level cache
```

## Integration with Target-Level Cache

Both caching layers work together:

1. **Target Cache Check**: First check if entire target is cached
2. **Action Cache Check**: If target cache miss, check action cache for individual steps
3. **Partial Rebuild**: Execute only uncached actions
4. **Target Cache Update**: After successful build, update target cache
5. **Action Cache Update**: Record each action result

### Decision Tree

```
Is target cached?
├─ Yes → Skip build (fastest path)
└─ No → Check action cache
    ├─ Some actions cached → Partial rebuild
    └─ No actions cached → Full rebuild
```

## Statistics and Monitoring

### Action Cache Stats

```d
struct ActionCacheStats
{
    size_t totalEntries;           // Total cached actions
    size_t totalSize;              // Cache size in bytes
    size_t hits;                   // Cache hits
    size_t misses;                 // Cache misses
    float hitRate;                 // Hit percentage
    size_t successfulActions;      // Actions that succeeded
    size_t failedActions;          // Actions that failed
}
```

### Example Output

```
Action-Level Cache:
  Total actions: 1,248
  Cache size: 12.4 MB
  Hit rate: 87.3%
  Successful actions: 1,180
  Failed actions: 68
```

## Best Practices

### 1. Deterministic Actions

Ensure actions are deterministic:
```d
// Good: Reproducible compilation
metadata["compiler"] = "gcc-11.2.0";
metadata["flags"] = "-O2 -Wall";
metadata["timestamp"] = "disabled";

// Bad: Non-deterministic timestamps
metadata["build_time"] = Clock.currTime().toString();
```

### 2. Granular Action IDs

Use specific sub-identifiers:
```d
// Good: Per-file action
ActionId(target, ActionType.Compile, hash, "src/main.cpp")

// Bad: Batch action (less granular)
ActionId(target, ActionType.Compile, hash, "all_sources")
```

### 3. Minimal Metadata

Only include relevant metadata:
```d
// Good: Only build-affecting flags
metadata["optimization"] = "-O2";
metadata["warnings"] = "-Wall";

// Bad: Irrelevant metadata causing unnecessary invalidation
metadata["user"] = getUsername();
metadata["machine"] = getHostname();
```

### 4. Explicit Dependencies

Track all inputs:
```d
// Good: Include headers
inputs = [sourceFile] ~ getHeaderDependencies(sourceFile);

// Bad: Missing implicit dependencies
inputs = [sourceFile];  // Headers not tracked!
```

## Migration Guide

### Existing Handlers

To add action-level caching to an existing handler:

1. **Override buildWithContext**:
   ```d
   override Result!(string, BuildError) buildWithContext(BuildContext context)
   ```

2. **Identify Actions**: Break build into logical steps (compile, link, test, etc.)

3. **Create ActionIds**: Generate unique IDs for each action

4. **Check Cache**: Before executing, check if action is cached

5. **Record Results**: Call `context.recordAction()` after each step

6. **Fallback**: Keep existing `build()` method for backward compatibility

### Incremental Adoption

Action-level caching is optional:
- **Handlers without support**: Use target-level caching only (existing behavior)
- **Handlers with support**: Benefit from action-level granularity
- **Mixed projects**: Both approaches coexist seamlessly

## Future Enhancements

### Potential Improvements

1. **Distributed Caching**: Share action cache across machines
2. **Content-Addressable Storage**: Deduplicate outputs
3. **Action DAG**: Model intra-target dependencies
4. **Predictive Prefetching**: Warm cache based on typical build patterns
5. **Compression**: Reduce cache size for large outputs

### Research Areas

- **Optimal Granularity**: Balance overhead vs. reuse
- **Smart Invalidation**: ML-based cache eviction
- **Cross-Target Actions**: Share compilation results across targets
- **Incremental Linking**: Cache link map for faster relinking

## References

- [Target-Level Caching](./performance.md#caching)
- [BLAKE3 Security](./blake3.md)
- [Language Handler Base](../../source/languages/base/base.d)
- [Build Optimization](./performance.md)

