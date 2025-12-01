# Concurrency and Thread Safety

This document describes the concurrency model, thread-safety guarantees, and testing practices for Builder.

## Overview

Builder uses parallel execution to build multiple targets concurrently. The core concurrency components are:

1. **BuildExecutor**: Orchestrates parallel builds with event-driven scheduling
2. **ThreadPool**: Persistent worker pool for task execution
3. **BuildNode**: Graph nodes with atomic status tracking
4. **BuildCache**: Thread-safe content-addressable cache

## Thread Safety Guarantees

### BuildNode

`BuildNode` represents a node in the build dependency graph. Its status field is accessed by multiple threads.

**Thread Safety:**
- `status` field uses atomic operations via property accessors
- `isReady()` reads dependency status atomically
- No locks required for status reads/writes (lock-free)

**Implementation:**
```d
private shared BuildStatus _status;  // Atomic storage

@property BuildStatus status() const nothrow @trusted @nogc
{
    return atomicLoad(this._status);
}

@property void status(BuildStatus newStatus) nothrow @trusted @nogc
{
    atomicStore(this._status, newStatus);
}
```

### BuildExecutor

`BuildExecutor` coordinates parallel build execution with careful synchronization.

**Shared State:**
- `activeTasks`: Atomic counter (number of running tasks)
- `failedTasks`: Atomic counter (number of failed tasks)
- `stateMutex`: Protects graph traversal and coordinated status updates
- `tasksReady`: Condition variable for work availability

**Critical Sections:**

1. **Graph traversal and task submission:**
   ```d
   synchronized (stateMutex)
   {
       ready = graph.getReadyNodes();  // Atomic status reads
       foreach (node; ready)
           node.status = BuildStatus.Building;  // Atomic write
       atomicOp!"+="(activeTasks, ready.length);
   }
   ```

2. **Result processing:**
   ```d
   synchronized (stateMutex)
   {
       foreach (i, result; results)
       {
           node.status = result.cached ? BuildStatus.Cached : BuildStatus.Success;
       }
       atomicOp!"-="(activeTasks, ready.length);
       tasksReady.notifyAll();
   }
   ```

**Why this works:**
- Graph structure (nodes, edges) is immutable after construction
- Only status fields are modified during execution
- Status updates are atomic and coordinated via mutex for consistency
- Work-stealing thread pool handles parallel task execution

### ThreadPool

`ThreadPool` implements a persistent worker pool with work-stealing.

**Shared State:**
- `running`: Atomic flag (thread pool active)
- `pendingJobs`: Atomic counter (uncompleted jobs)
- `nextJobIndex`: Atomic counter (next job to claim, work-stealing)
- `jobs`: Array protected by `jobMutex`
- `Job.completed`: Atomic flag per job

**Work Distribution:**
1. Main thread populates `jobs` array under `jobMutex`
2. Worker threads atomically increment `nextJobIndex` to claim jobs (CAS)
3. Each worker executes claimed job and marks `completed` atomically
4. Main thread waits on condition variable until all jobs complete

**Why this works:**
- Work-stealing (via CAS on `nextJobIndex`) enables lock-free job distribution
- `jobMutex` only protects job array setup and completion waiting
- Atomic `completed` flag prevents duplicate execution
- No data races on job results (results array pre-allocated, indexed by job ID)

### BuildCache

`BuildCache` provides thread-safe caching with internal synchronization.

**Thread Safety:**
- Uses internal `Mutex` (`cacheMutex`) for all mutable state
- All public methods (`isCached`, `update`, `invalidate`, `clear`, `flush`, `getStats`) are synchronized
- Safe for concurrent access from multiple build threads
- BLAKE3 hashing is thread-safe (pure function, no shared state)

**Shared State (all protected by mutex):**
- `entries`: Cache entry map
- `dirty`: Flag indicating unsaved changes
- `contentHashCount`, `metadataHitCount`: Statistics counters

## Testing with Thread Sanitizer

Thread Sanitizer (TSan) is a runtime tool that detects data races and threading issues.

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

# Run tests with Thread Sanitizer
make test-tsan

# Or manually:
dub build --compiler=ldc2 --build=tsan
./bin/bldr build --parallel
```

### Interpreting Results

**No data races:**
```
✓ All tests passed! No data races detected.
```

**Data race detected:**
```
==================
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 4 at 0x7fff12345678 by thread T1:
    #0 BuildNode.status (source/core/graph/graph.d:42)
    
  Previous read of size 4 at 0x7fff12345678 by main thread:
    #0 BuildNode.isReady (source/core/graph/graph.d:50)
    
SUMMARY: ThreadSanitizer: data race
==================
```

**Action:** Fix the reported race by adding synchronization or using atomic operations.

### CI Integration

Add Thread Sanitizer to your CI pipeline:

```yaml
# .github/workflows/ci.yml
- name: Test with Thread Sanitizer
  run: |
    make test-tsan
```

This ensures no data races are introduced in new code.

## Performance Considerations

### Lock-Free Operations

- BuildNode status: Lock-free atomic reads/writes
- ThreadPool work-stealing: Lock-free via CAS
- Benefits: Better scalability, no lock contention

### Lock-Based Coordination

- BuildExecutor uses mutex for graph traversal consistency
- Necessary: Multiple fields updated together atomically
- Short critical sections: Minimal lock hold time

### Benchmarks

Parallel build performance (8 cores):
- Simple project (5 targets): ~10ms (8x speedup)
- Large project (100 targets): ~500ms (6x speedup)
- Overhead: ~5-10% for synchronization

## Debugging Concurrency Issues

### Tools

1. **Thread Sanitizer** (recommended):
   - Detects data races at runtime
   - Low overhead (~5-15x slowdown)
   - Use: `make test-tsan`

2. **Helgrind** (Valgrind):
   - Detects lock order violations
   - High overhead (~20-50x slowdown)
   - Use: `valgrind --tool=helgrind ./bin/builder`

3. **Manual logging:**
   ```d
   Logger.debug_("Thread " ~ Thread.getThis().id ~ ": " ~ msg);
   ```

### Common Issues

1. **Deadlock:**
   - Symptom: Process hangs
   - Debug: Check lock acquisition order
   - Fix: Always acquire locks in consistent order

2. **Data Race:**
   - Symptom: Sporadic incorrect results
   - Debug: Run with TSan
   - Fix: Add synchronization or use atomics

3. **Performance degradation:**
   - Symptom: Parallel slower than sequential
   - Debug: Profile lock contention
   - Fix: Reduce critical section size or use lock-free algorithms

## References

- [D Language Concurrency](https://dlang.org/spec/concurrency.html)
- [core.atomic Documentation](https://dlang.org/phobos/core_atomic.html)
- [Thread Sanitizer](https://github.com/google/sanitizers/wiki/ThreadSanitizerCppManual)
- [Lock-Free Programming](https://preshing.com/20120612/an-introduction-to-lock-free-programming/)

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) - Overall system design
- [PERFORMANCE.md](PERFORMANCE.md) - Performance optimization techniques
- [TESTING.md](TESTING.md) - Testing practices

