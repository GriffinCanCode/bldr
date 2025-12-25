# Concurrency and Thread Safety

**Status:** Implemented  
**Module:** `infrastructure.utils.concurrency`, `engine.graph.core`

## Overview

Builder uses parallel execution to build multiple targets concurrently. Key concurrency components:

1. **BuildGraph**: Dependency graph with atomic node status tracking
2. **ThreadPool**: Persistent worker pool with work-stealing
3. **SchedulingService**: Task scheduling with multiple strategies
4. **BuildCache**: Thread-safe content-addressable cache

## Thread Safety Guarantees

### BuildNode

`BuildNode` represents a node in the build dependency graph. Status tracking is lock-free via atomic operations.

**Thread-Safe Fields:**
- `_status`: `shared BuildStatus` with atomic access
- `_retryAttempts`: `shared size_t` with atomic access
- `_pendingDeps`: `shared size_t` for lock-free ready detection

**Implementation:**
```d
final class BuildNode {
    private shared BuildStatus _status;
    private shared size_t _retryAttempts;
    private shared size_t _pendingDeps;
    
    @property BuildStatus status() const nothrow @system @nogc {
        return atomicLoad(this._status);
    }
    
    @property void status(BuildStatus newStatus) nothrow @system @nogc {
        atomicStore(this._status, newStatus);
    }
    
    // Lock-free ready detection
    size_t decrementPendingDeps() nothrow @system @nogc {
        atomicOp!"-="(this._pendingDeps, 1);
        return atomicLoad(this._pendingDeps);
    }
}
```

**Invariants:**
- Graph structure (nodes, edges) is immutable after construction
- Only status fields are modified during execution
- All status operations are atomic (no locks required)

### ThreadPool

Persistent worker pool with work-stealing for efficient task distribution.

**Shared State:**
- `running`: `shared bool` - pool active flag
- `pendingJobs`: `shared size_t` - uncompleted job count
- `nextJobIndex`: `shared size_t` - work-stealing index (CAS)
- `jobs`: Array protected by `jobMutex`
- `Job.completed`: `shared bool` per job

**Work Distribution:**
```d
// Worker claims job via CAS (lock-free)
if (cas(&nextJobIndex, idx, idx + 1)) {
    if (!atomicLoad(jobs[idx].completed))
        return jobs[idx];
}
```

1. Main thread populates `jobs` array under `jobMutex`
2. Workers atomically increment `nextJobIndex` to claim jobs (CAS)
3. Each worker executes claimed job and marks `completed` atomically
4. Main thread waits on condition variable until all jobs complete

**Usage:**
```d
auto pool = new ThreadPool(8);  // 8 workers

// Parallel map
auto results = pool.map(items, (item) => process(item));

// Parallel forEach
pool.forEach(items, (item) => process(item));

pool.shutdown();
```

### BuildGraph

Dependency graph with topological ordering and cycle detection.

**Memory Optimization:**
- Arena allocator for batch node allocation (10-100x GC reduction)
- `TargetId[]` instead of `BuildNode[]` to avoid GC cycles
- Incremental topological ordering for watch mode

**Validation Modes:**
```d
enum ValidationMode {
    Immediate,  // Check cycles on every edge (O(V²) worst-case)
    Deferred    // Single O(V+E) validation at end
}

// Fast batch construction
auto graph = new BuildGraph(ValidationMode.Deferred, 1000);
foreach (target; targets) graph.addTarget(target);
foreach (dep; deps) graph.addDependency(from, to);
auto result = graph.validate();  // Single O(V+E) validation
```

### SchedulingService

Multiple scheduling strategies for task execution:

```d
enum SchedulingMode {
    ThreadPool,    // Simple thread pool parallelism
    WorkStealing,  // Work-stealing scheduler
    Adaptive       // Auto-select based on workload
}

auto scheduler = new SchedulingService(SchedulingMode.WorkStealing);
scheduler.initialize(0);  // 0 = auto-detect CPU count

// Submit tasks
scheduler.submit(node, Priority.Normal);

// Execute batch in parallel
auto results = scheduler.executeBatch(nodes, executor);

// Wait for completion
scheduler.waitForCompletion();
```

### BuildCache

Thread-safe caching with internal synchronization.

- Uses `Mutex` for all mutable state
- All public methods are synchronized
- Safe for concurrent access from multiple build threads
- BLAKE3 hashing is thread-safe (pure function)

## Lock-Free Patterns

### Atomic Status Updates

```d
// Read status (no lock)
auto status = atomicLoad(node._status);

// Write status (no lock)
atomicStore(node._status, BuildStatus.Building);

// Atomic increment
atomicOp!"+="(counter, 1);
```

### Work-Stealing via CAS

```d
// Worker claims next job atomically
immutable idx = atomicLoad(nextJobIndex);
if (cas(&nextJobIndex, idx, idx + 1)) {
    // Successfully claimed job at idx
}
```

### Ready Detection

```d
// Node becomes ready when pending deps reaches 0
void onDependencyComplete(BuildNode dep) {
    foreach (dependentId; dep.dependentIds) {
        auto dependent = graph.nodes[dependentId.toString()];
        if (dependent.decrementPendingDeps() == 0) {
            // Node is ready, submit for execution
            scheduler.submit(dependent);
        }
    }
}
```

## Testing with Thread Sanitizer

Thread Sanitizer (TSan) detects data races at runtime.

### Requirements

- **LDC compiler** (LLVM-based D compiler)
- Installation:
  - macOS: `brew install ldc`
  - Ubuntu: `apt-get install ldc`
  - Arch: `pacman -S ldc`

### Running Tests

```bash
# Build with Thread Sanitizer
make tsan

# Run tests
make test-tsan

# Manual:
dub build --compiler=ldc2 --build=tsan
./bin/bldr build --parallel
```

### Interpreting Results

**No races:**
```
✓ All tests passed! No data races detected.
```

**Race detected:**
```
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 4 at 0x7fff12345678 by thread T1:
    #0 BuildNode.status (source/engine/graph/core/graph.d:160)
    
  Previous read of size 4 at 0x7fff12345678 by main thread:
    #0 BuildNode.isReady (source/engine/graph/core/graph.d:285)
```

## Performance

### Lock-Free Benefits

- BuildNode status: No lock contention
- Work-stealing: No centralized queue bottleneck
- Scalability: Near-linear scaling with cores

### Benchmarks (8 cores)

| Project Size | Sequential | Parallel | Speedup |
|-------------|-----------|----------|---------|
| 5 targets | 50ms | 10ms | 5x |
| 50 targets | 300ms | 50ms | 6x |
| 100 targets | 600ms | 100ms | 6x |

Synchronization overhead: ~5-10%

## Debugging Concurrency Issues

### Tools

1. **Thread Sanitizer** (recommended):
   - Detects data races at runtime
   - Low overhead (~5-15x slowdown)
   - `make test-tsan`

2. **Helgrind** (Valgrind):
   - Detects lock order violations
   - High overhead (~20-50x slowdown)
   - `valgrind --tool=helgrind ./bin/bldr`

### Common Issues

**Deadlock:**
- Symptom: Process hangs
- Debug: Check lock acquisition order
- Fix: Always acquire locks in consistent order

**Data Race:**
- Symptom: Sporadic incorrect results
- Debug: Run with TSan
- Fix: Add synchronization or use atomics

**Performance Degradation:**
- Symptom: Parallel slower than sequential
- Debug: Profile lock contention
- Fix: Reduce critical section size or use lock-free algorithms

## Arena Allocation

Graph construction uses arena allocation to reduce GC pressure:

```d
struct NodeArena {
    private ubyte[] buffer;
    private size_t offset;
    
    BuildNode allocate(TargetId id, Target target) @trusted {
        immutable alignedOffset = alignUp(offset, nodeAlign);
        immutable newOffset = alignedOffset + nodeSize;
        
        if (newOffset > buffer.length)
            return null;  // Arena full, fallback to GC
        
        offset = newOffset;
        return emplace!BuildNode(buffer[alignedOffset .. newOffset], id, target);
    }
}

// Usage
auto graph = new BuildGraph(ValidationMode.Deferred, 1000);  // Pre-allocate for 1000 nodes
```

**Benefits:**
- 10-100x reduction in GC pressure
- Bump-pointer allocation (O(1) per node)
- Cache-friendly contiguous memory

## See Also

- [Architecture](../architecture/overview.md)
- [Performance](./performance.md)
- [Testing](../user-guides/TESTING.md)
- [Work-Stealing](../architecture/workstealing.md)

## References

- [D Language Concurrency](https://dlang.org/spec/concurrency.html)
- [core.atomic Documentation](https://dlang.org/phobos/core_atomic.html)
- [Thread Sanitizer](https://github.com/google/sanitizers/wiki/ThreadSanitizerCppManual)
- [Lock-Free Programming](https://preshing.com/20120612/an-introduction-to-lock-free-programming/)
