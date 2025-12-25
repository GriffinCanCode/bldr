# Error Recovery & Build Resumption

Automatic retry logic, build checkpointing, and intelligent build resumption.

## Architecture

### Design Principles

Traditional build systems fail completely on errors—one failure stops everything, discarding completed work. The recovery system implements:

1. **Circuit Breaker Pattern** — Fault tolerance with intelligent failure handling
2. **Event Sourcing** — State reconstruction from build checkpoints
3. **Exponential Backoff with Jitter** — Prevents thundering herd on retries

### Core Components

#### 1. Retry Orchestration (`engine/runtime/recovery/retry.d`)

Handles transient failures with exponential backoff and jitter.

**Features:**
- Category-based retry policies (System, Cache, IO)
- Exponential backoff: `delay = initial × (multiplier ^ attempt)`
- Random jitter (10-15%) prevents thundering herd
- Configurable max attempts and delays
- Retry statistics for observability

**Recoverable Errors:**
- `ProcessTimeout` — 3 retries, 200ms initial, 10s max
- `BuildTimeout` — 2 retries, 1s initial, 30s max
- `CacheLoadFailed` — 3 retries, 100ms initial, 5s max
- `FileReadFailed` / `FileWriteFailed` — 3 retries for NFS/network drives

**Non-Recoverable Errors:**
- Syntax errors, compilation failures, logic errors
- Graph cycles, missing dependencies
- Configuration errors

**Usage:**
```d
auto orchestrator = new RetryOrchestrator();
auto result = orchestrator.withRetry!ActionResult(
    "build-target",
    () => handler.buildWithContext(context),
    RetryPolicy.forCategory(ErrorCategory.System)
);
```

#### 2. Build Checkpointing (`engine/runtime/recovery/checkpoint.d`)

Persists build state for resumption after failures.

**Checkpoint Storage:**
- Location: `.builder-cache/checkpoint.bin`
- Format: Binary with structured serialization
- Contains: Node states, hashes, timestamps, failed targets

**Checkpoint Data:**
```d
struct Checkpoint {
    string workspaceRoot;
    SysTime timestamp;
    BuildStatus[string] nodeStates;   // Target → Status
    string[string] nodeHashes;        // Target → Hash
    size_t totalTargets;
    size_t completedTargets;
    size_t failedTargets;
    string[] failedTargetIds;
}
```

**Operations:**
- `capture()` — Create checkpoint from build graph
- `save()` — Persist to disk (binary format)
- `load()` — Restore from disk
- `isValid()` — Validate against current graph
- `mergeWith()` — Restore successful builds to graph

**Lifecycle:**
- Created: On build failure (non-fatal errors)
- Loaded: At build start if exists
- Cleared: On successful build or manual `clean`
- Expires: After 24 hours (configurable)

#### 3. Build Resumption (`engine/runtime/recovery/resume.d`)

Intelligently resumes builds from checkpoints.

**Resume Strategies:**

1. **Smart** (default)
   - Validates dependencies haven't changed
   - Retries failed targets
   - Rebuilds affected dependents
   - Skips successful targets

2. **RetryFailed**
   - Retries all failed targets
   - Rebuilds their dependents
   - Skips successful targets

3. **SkipFailed**
   - Skips failed targets entirely
   - Continues with remaining builds

4. **RebuildAll**
   - Ignores checkpoint
   - Rebuilds everything

**Resume Planning:**
```d
auto planner = new ResumePlanner(ResumeConfig.fromEnvironment());
auto planResult = planner.plan(checkpoint, graph);

if (planResult.isOk) {
    auto plan = planResult.unwrap();
    plan.print();  // Shows what will be rebuilt
}
```

### Integration

#### BuildExecutor Integration

The executor handles recovery automatically:

1. **On Build Start:**
   - Checks for checkpoint
   - Validates against current graph
   - Restores successful builds
   - Plans retry strategy

2. **During Build:**
   - Wraps each target build in retry logic
   - Tracks retry attempts per node
   - Logs retry statistics

3. **On Build End:**
   - Saves checkpoint if failures
   - Clears checkpoint if success
   - Reports retry statistics

#### Resilience Service (`engine/runtime/services/resilience/service.d`)

High-level service interface:
```d
interface IResilienceService {
    BuildResult!string withRetryString(string targetId, 
        BuildResult!string delegate() action, RetryPolicy policy);
    bool hasCheckpoint();
    bool isCheckpointStale();
    bool saveCheckpoint(BuildGraph graph);
    BuildResult!Checkpoint loadCheckpoint();
    BuildResult!ResumePlan planResume(BuildGraph graph);
    void clearCheckpoint();
    RetryPolicy policyFor(BuildError error);
}
```

## CLI Usage

### Build with Recovery

```bash
# Normal build — automatically checkpoints on failure
bldr build

# If build fails, resume with:
bldr resume
```

### Resume Options

```bash
# Resume with specific strategy
BUILDER_RESUME_STRATEGY=retry bldr resume    # Retry failed
BUILDER_RESUME_STRATEGY=skip bldr resume     # Skip failed
BUILDER_RESUME_STRATEGY=smart bldr resume    # Smart (default)
BUILDER_RESUME_STRATEGY=rebuild bldr resume  # Rebuild all

# Resume with verbose output
bldr resume -m verbose
```

### Configuration

Environment variables:
```bash
# Checkpoint age limit
export BUILDER_RESUME_MAX_AGE_HOURS=24

# Disable checkpoints
export BUILDER_ENABLE_CHECKPOINTS=false

# Disable retries
export BUILDER_ENABLE_RETRIES=false
```

## Examples

### Network Timeout Recovery

```bash
$ bldr build
Building 100 targets...
  ✓ target1
  ✓ target2
  ✗ target3 (ProcessTimeout)
  Retry attempt 1 for target3
  ✓ target3 (succeeded after 1 retry)
  ✓ target4
```

### Build Failure Resumption

```bash
$ bldr build
Building 100 targets...
[... 50 targets succeed ...]
  ✗ target51 (CompilationFailed)
Build failed with 1 errors
Checkpoint saved for resume with 'bldr resume'

# Fix the issue, then:
$ bldr resume
Found checkpoint from 2025-01-27 14:30:00
Progress: 50/100 targets (50%)
Failed targets:
  - target51

=== Resume Plan ===
Strategy: Smart
Targets to rebuild (51):
  - target51
  - target52 (depends on target51)
  ... and 49 more
Targets to skip (50):
  - target1
  - target2
  ... and 48 more

Resuming build (saving ~50% time)...
  ✓ target51
  ✓ target52
[...]
Build completed successfully!
```

## Performance

### Retry Overhead

- **No failures:** Zero overhead (retry logic not executed)
- **Transient failures:** 100-500ms per retry (backoff delay)
- **Persistent failures:** Fast-fail after max attempts (~1-2s total)

### Checkpoint Overhead

- **Capture:** O(V) where V = targets, ~1-5ms for 1000 targets
- **Serialize:** ~10ms for typical builds
- **Load:** ~1-2ms
- **Validation:** O(V), ~1ms for 1000 targets

### Build Resumption Savings

Typical measurements:
- **50% failure point:** ~45-48% time savings
- **90% failure point:** ~85-88% time savings
- **With retries:** Additional 2-5% success rate improvement

## Implementation Details

### Thread Safety

- **Retry statistics:** Atomic operations
- **Checkpoint capture:** Single-threaded (called at build end)
- **Node retry counts:** Atomic increment/read
- **Build status:** Atomic via BuildNode

### Error Handling

All operations use Result types:
```d
Result!(Checkpoint, string) load();
Result!(ResumePlan, string) plan(checkpoint, graph);
BuildResult!T withRetry(operation);
```

## Best Practices

1. **Use Smart Resume** — Best balance of correctness and performance
2. **Enable Retries** — Handles transient failures automatically
3. **Monitor Retry Stats** — High retry rates indicate systemic issues
4. **Clear Stale Checkpoints** — Run `bldr clean` after major refactors
5. **Validate After Resume** — Check build outputs after resuming

## Comparison

| Feature | bldr | Bazel | Buck2 | Gradle |
|---------|------|-------|-------|--------|
| Automatic Retry | ✓ | — | — | — |
| Build Checkpoints | ✓ | — | — | Partial |
| Smart Resume | ✓ | — | — | Limited |
| Exponential Backoff | ✓ | — | — | — |
| Dependency Validation | ✓ | ✓ | ✓ | ✓ |

## References

- [Circuit Breaker Pattern](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Exponential Backoff and Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
