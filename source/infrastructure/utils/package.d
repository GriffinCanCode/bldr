module infrastructure.utils;

/// Utilities Package
/// Common utilities for file handling, parallelization, cryptography, and benchmarking
/// 
/// Architecture:
///   glob.d      - Glob pattern matching
///   hash.d      - File hashing and checksums (now uses BLAKE3)
///   ignore.d    - Ignore patterns for dependency and build directories
///   parallel.d  - Enhanced parallel processing with work-stealing and load balancing
///   pool.d      - Thread pool implementation
///   chunking.d  - File chunking utilities
///   logger.d    - Logging infrastructure
///   metadata.d  - File metadata handling
///   bench.d     - Benchmarking utilities
///   blake3.d    - BLAKE3 cryptographic hashing (3-5x faster than SHA-256)
///   pycheck.d   - Python validation
///   pywrap.d    - Python wrapper utilities
///   validation.d - Security validation for paths and command arguments
///   process.d   - Process and tool availability checking utilities
///
/// Async I/O (Linux io_uring):
///   async.d     - Abstract async I/O with platform backends
///   uring.d     - Linux io_uring bindings (kernel 5.1+)
///   batch.d     - Batch file reading and hashing
///
/// Concurrency (Advanced):
///   deque.d     - Lock-free work-stealing deque (Chase-Lev algorithm)
///   scheduler.d - Work-stealing scheduler with priority support
///   balancer.d  - Dynamic load balancing with multiple strategies
///   priority.d  - Priority queues and critical path scheduling
///
/// Memory Optimization:
///   intern.d    - String interning for memory deduplication (60-80% savings)
///
/// Usage:
///   import utils;
///   
///   auto files = glob("src/**/*.d");
///   auto hash = hashFile("source.d");  // Uses BLAKE3 with SIMD automatically
///   
///   auto pool = new ThreadPool(4);
///   pool.submit({ /* work */ });
///   
///   // Basic parallel execution (backward compatible)
///   auto results = ParallelExecutor.execute(items, func, 4);
///   
///   // Advanced parallel execution with work-stealing
///   auto results2 = ParallelExecutor.mapWorkStealing(items, func);
///   
///   // Priority-based scheduling
///   auto results3 = ParallelExecutor.mapPriority(items, func, Priority.High);
///   
///   // SIMD operations
///   CPU.printInfo();              // Show CPU capabilities
///   SIMDOps.copy(dest, src);      // Fast SIMD memcpy
///   SIMDBench.compareAll();       // Benchmark SIMD implementations
///   
///   // Serialization (SIMD-accelerated)
///   @Serializable(SchemaVersion(1, 0))
///   struct MyData { @Field(1) int id; @Field(2) string name; }
///   auto bytes = Codec.serialize(myData);
///   auto result = Codec.deserialize!MyData(bytes);

public import infrastructure.utils.serialization;
public import infrastructure.utils.files.glob;
public import infrastructure.utils.files.hash;
public import infrastructure.utils.files.ignore;
public import infrastructure.utils.concurrency.parallel;
public import infrastructure.utils.concurrency.pool;
public import infrastructure.utils.concurrency.simd;
public import infrastructure.utils.concurrency.lockfree;
public import infrastructure.utils.concurrency.deque;
public import infrastructure.utils.concurrency.scheduler;
public import infrastructure.utils.concurrency.balancer;
public import infrastructure.utils.concurrency.priority;
public import infrastructure.utils.files.chunking;
public import infrastructure.utils.files.cdc;
public import infrastructure.utils.logging.logger;
public import infrastructure.utils.files.metadata;
public import infrastructure.utils.benchmarking.bench;
public import infrastructure.utils.crypto.blake3;
public import infrastructure.utils.python.pycheck;
public import infrastructure.utils.python.pywrap;
public import infrastructure.utils.simd;
public import infrastructure.utils.security.validation;
public import infrastructure.utils.process;
public import infrastructure.utils.memory;
public import infrastructure.utils.io;

