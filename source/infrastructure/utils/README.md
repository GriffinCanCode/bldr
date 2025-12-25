# Utils Package

Common utilities for file handling, concurrency, cryptography, and serialization used throughout Builder.

## Architecture

```
utils/
├── files/             # File system operations
│   ├── glob.d         # Glob pattern matching
│   ├── hash.d         # Fast file hashing with BLAKE3
│   ├── chunking.d     # File chunking for parallel I/O
│   ├── metadata.d     # File metadata and timestamps
│   ├── ignore.d       # Ignore patterns (.builderignore)
│   ├── directories.d  # Directory operations
│   ├── watch.d        # File system watching
│   └── xml.d          # XML parsing utilities
├── concurrency/       # Parallelism and scheduling
│   ├── pool.d         # Persistent thread pool
│   ├── parallel.d     # Parallel execution strategies
│   ├── deque.d        # Lock-free work-stealing deque (Chase-Lev)
│   ├── scheduler.d    # Work-stealing scheduler
│   ├── balancer.d     # Dynamic load balancing
│   ├── priority.d     # Priority queues
│   ├── lockfree.d     # Lock-free data structures
│   └── simd.d         # SIMD-aware parallel operations
├── crypto/            # Cryptographic operations
│   ├── blake3.d       # BLAKE3 hashing wrapper
│   ├── blake3_bindings.d # C bindings for BLAKE3
│   └── c/             # Native BLAKE3 implementation
├── memory/            # Memory management
│   ├── intern.d       # String interning (60-80% dedup)
│   ├── mmap.d         # Memory-mapped file I/O
│   └── profiler.d     # Memory profiling
├── logging/           # Logging infrastructure
│   ├── logger.d       # Core logger
│   └── structured.d   # Structured JSON logging
├── security/          # Security utilities
│   ├── validation.d   # Path and argument validation
│   ├── executor.d     # Secure command execution
│   ├── integrity.d    # Integrity verification
│   └── tempdir.d      # Secure temporary directories
├── process/           # Process management
│   └── checker.d      # Tool availability checking
├── python/            # Python integration
│   ├── pycheck.d      # Python environment validation
│   └── pywrap.d       # Python integration wrapper
├── compression/       # Data compression
│   └── compress.d     # Compression algorithms
├── benchmarking/      # Performance utilities
│   └── bench.d        # Benchmarking framework
├── serialization/     # Binary serialization
│   ├── core/          # Serialization core
│   │   ├── buffer.d   # Buffer management
│   │   ├── codec.d    # Encode/decode operations
│   │   ├── schema.d   # Schema definitions
│   │   └── evolution.d # Schema evolution
│   └── c/             # Native serialization helpers
├── simd/              # SIMD acceleration
│   ├── hash.d         # SIMD-accelerated hashing
│   ├── bloom.d        # SIMD bloom filters
│   ├── ops.d          # SIMD operations
│   ├── detection.d    # CPU feature detection
│   ├── dispatch.d     # Runtime dispatch
│   └── c/             # Native SIMD implementations
└── io/                # Async I/O (io_uring)
    ├── uring.d        # Linux io_uring bindings
    ├── async.d        # Abstract async I/O backend
    ├── batch.d        # Batch file hashing
    └── package.d      # Module exports
```

## Modules

### File Operations (`files/`)
- **glob.d** - Glob pattern matching for file selection
- **hash.d** - Fast file hashing with BLAKE3
- **chunking.d** - File chunking for parallel processing
- **metadata.d** - File metadata and timestamps
- **ignore.d** - Ignore patterns for dependency and build directories

### Concurrency (`concurrency/`)
- **pool.d** - Persistent thread pool implementation
- **parallel.d** - Enhanced parallel execution with multiple strategies
- **deque.d** - Lock-free work-stealing deque (Chase-Lev algorithm)
- **scheduler.d** - Work-stealing scheduler with priority support
- **balancer.d** - Dynamic load balancing with adaptive strategies
- **priority.d** - Priority queues and critical path scheduling
- **lockfree.d** - Lock-free queue and hash cache
- **simd.d** - SIMD-aware parallel operations

### Memory Optimization (`memory/`)
- **intern.d** - String interning for memory deduplication (60-80% savings)
- **mmap.d** - Memory-mapped file I/O for large files
- **profiler.d** - Memory usage profiling

### Async I/O (`io/`)
- **uring.d** - Linux io_uring bindings (kernel 5.1+)
- **async.d** - Abstract async I/O backend with platform auto-detection
- **batch.d** - Batch file hashing optimized for cold cache scenarios

### Other Utilities
- **logging/logger.d** - Structured logging infrastructure
- **benchmarking/bench.d** - Performance benchmarking utilities
- **python/pycheck.d** - Python environment validation
- **python/pywrap.d** - Python integration wrapper
- **security/validation.d** - Security validation for paths and arguments
- **process/checker.d** - Process and tool availability checking

## Usage Examples

### String Interning (Memory Optimization)
```d
import utils;

// Basic interning with thread-local pool
auto s1 = intern("common/path");
auto s2 = intern("common/path");
assert(s1 == s2);  // O(1) pointer equality!

// Custom pool for fine-grained control
auto pool = new StringPool();
auto interned = pool.intern("/usr/local/bin");

// Domain-specific pools (recommended for large systems)
DomainPools pools = DomainPools(0);
auto path = pools.internPath("/src/main.d");
auto target = pools.internTarget("mylib");
auto import = pools.internImport("std.stdio");

// Get statistics
auto stats = pools.getCombinedStats();
writeln("Deduplication rate: ", stats.deduplicationRate, "%");
writeln("Memory saved: ", stats.savedBytes / 1024, " KB");
```

**Benefits:**
- **60-80% memory reduction** - Eliminates duplicate strings
- **O(1) equality** - Pointer comparison instead of content comparison
- **O(1) hashing** - Pre-computed hashes cached
- **Thread-safe** - Lock-free reads, synchronized writes
- **Cache-friendly** - Fewer allocations, better locality

**When to use:**
- File paths (highly duplicated in build systems)
- Target names (referenced many times)
- Import statements (repeated across analysis)
- Any frequently repeated strings

### Basic Parallel Execution (Backward Compatible)
```d
import utils;

// Simple parallel execution
auto results = ParallelExecutor.execute(items, func, 4);

// Auto-detect CPU count
auto results = ParallelExecutor.executeAuto(items, func);
```

### Advanced Work-Stealing Scheduler
```d
import utils;

// Work-stealing with automatic load balancing
auto results = ParallelExecutor.mapWorkStealing(items, func);

// With custom parallelism
auto results = ParallelExecutor.mapWorkStealing(items, func, 8);
```

### Priority-Based Scheduling
```d
import utils;

// High-priority execution for critical path
auto results = ParallelExecutor.mapPriority(items, func, Priority.Critical);

// Dynamic load balancing
auto results = ParallelExecutor.mapLoadBalanced(items, func);
```

### Advanced Configuration
```d
import utils;

ParallelConfig config;
config.mode = ExecutionMode.WorkStealing;
config.basePriority = Priority.High;
config.balanceStrategy = BalanceStrategy.Adaptive;
config.maxParallelism = 8;

auto results = ParallelExecutor.executeAdvanced(items, func, config);
```

### Statistics Collection
```d
import utils;

ParallelConfig config;
config.mode = ExecutionMode.WorkStealing;
config.enableStatistics = true;

ExecutionStats stats;
auto results = ParallelExecutor.executeWithStats(items, func, results, config);

writeln("Total stolen: ", stats.totalStolen);
writeln("Steal success rate: ", stats.stealSuccessRate);
writeln("Load imbalance: ", stats.loadImbalance);
```

### Direct Scheduler Usage
```d
import utils;

auto scheduler = new WorkStealingScheduler!Task(
    4,  // worker count
    (Task t) { /* execute task */ }
);

// Submit with priorities
scheduler.submit(task1, Priority.Critical, 1000, 1, 5);
scheduler.submit(task2, Priority.Normal);

scheduler.waitAll();
auto stats = scheduler.getStats();
scheduler.shutdown();
```

### Load Balancer
```d
import utils;

auto balancer = new LoadBalancer(4, BalanceStrategy.Adaptive);

// Select worker for task assignment
auto workerId = balancer.selectWorker();

// Select victim for work stealing
auto victimId = balancer.selectVictim(thiefId);

// Check if rebalancing needed
if (balancer.needsRebalancing()) {
    // Trigger rebalancing logic
}
```

### Async I/O (io_uring)
```d
import infrastructure.utils.files.hash : FastHash;

// Simple batch hashing with auto-detected backend
// Uses io_uring on Linux 5.1+, thread pool elsewhere
string[] paths = ["file1.c", "file2.c", "file3.c"];
string[] hashes = FastHash.hashFilesAsync(paths);

// Check if io_uring is available
if (FastHash.hasAsyncIO()) {
    writeln("Using io_uring for 8-9x faster cold cache hashing!");
}

// Reusable hasher for multiple batches
auto hasher = FastHash.createAsyncHasher(64);
scope(exit) hasher.shutdown();

auto batch1 = hasher.hashFiles(sourceFiles);
auto batch2 = hasher.hashFiles(headerFiles);

// Statistics
auto stats = hasher.stats;
writefln("Hashed %d files, %d bytes", stats.filesHashed, stats.bytesHashed);
```

**Benefits:**
- **8-9x faster** on cold page cache with io_uring
- **4-5x faster** with thread pool fallback
- **Zero-copy** via registered buffers (Linux)
- **Batch syscalls** - 64 reads in 1 syscall

**When to use:**
- Many small files (>8) on cold cache
- Initial project scan, CI cold starts
- After system restart

## Key Features

### Performance
- **Lock-free data structures** - Chase-Lev deque for minimal contention
- **Work-stealing** - Automatic load balancing across workers
- **Priority scheduling** - Critical path optimization
- **Dynamic load balancing** - Adaptive strategies based on runtime metrics
- **SIMD acceleration** - Data-parallel operations where applicable
- **BLAKE3 hashing** - 3-5x faster than SHA-256 with SIMD

### Scheduling Strategies
- **Simple** - Basic std.parallelism (backward compatible)
- **WorkStealing** - Distributed deques with stealing on demand
- **LoadBalanced** - Dynamic distribution based on worker load
- **Priority** - Critical path tasks scheduled first
- **Adaptive** - Dynamically adjusts based on system metrics

### Design Principles
- **Backward compatible** - Existing code continues to work
- **Zero-cost abstraction** - Advanced features only when used
- **Type-safe** - Strong typing reduces runtime errors
- **Well-tested** - Comprehensive unit tests for all components
- **Documented** - Extensive inline documentation and examples

## Architecture

The concurrency system is layered:

1. **Foundation** - Lock-free deque (deque.d) for low-level task storage
2. **Prioritization** - Priority queues (priority.d) for task ordering
3. **Scheduling** - Work-stealing scheduler (scheduler.d) coordinates workers
4. **Balancing** - Load balancer (balancer.d) optimizes distribution
5. **Interface** - ParallelExecutor (parallel.d) provides high-level API

Each layer is independently testable and can be used standalone or composed.

