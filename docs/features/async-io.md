# Async I/O

High-performance asynchronous file I/O for cold cache scenarios using Linux io_uring with automatic fallback to thread pool on other platforms.

## Overview

File hashing is typically CPU-bound due to BLAKE3's speed and SIMD acceleration. However, when the page cache is cold (after system restart, first project scan, etc.), I/O latency becomes the bottleneck. The async I/O module addresses this with:

- **io_uring on Linux 5.1+**: Kernel-level async I/O with batch syscalls
- **Thread pool fallback**: Parallel reads on non-Linux platforms
- **Automatic backend selection**: Best backend chosen at runtime

## Architecture

### Components

1. **AsyncIOBackend** (`infrastructure/utils/io/async.d`)
   - Abstract interface for async I/O implementations
   - `IoUringBackend` - Linux io_uring implementation
   - `ThreadPoolBackend` - Cross-platform fallback
   - `SyncBackend` - Minimal synchronous fallback

2. **IoUring** (`infrastructure/utils/io/uring.d`)
   - Low-level io_uring wrapper with syscall bindings
   - Submission/completion queue management
   - Registered buffer support for zero-copy operations

3. **BatchHasher** (`infrastructure/utils/io/batch.d`)
   - Batch file hashing with async I/O
   - Intelligent batching based on file sizes
   - Integration with BLAKE3 hashing

### Backend Selection

```d
auto io = AsyncIO.create(queueDepth: 256);
// Returns IoUringBackend on Linux 5.1+ if available
// Falls back to ThreadPoolBackend otherwise
```

## Usage

### Simple Batch Hashing

```d
import infrastructure.utils.files.hash : FastHash;

// Hash many files with optimal async I/O
string[] paths = ["file1.c", "file2.c", ...];
string[] hashes = FastHash.hashFilesAsync(paths);
```

### Custom Configuration

```d
import infrastructure.utils.io : BatchHasher;

BatchHasher.Config config;
config.bufferSize = 512 * 1024;   // 512 KB read buffers
config.maxConcurrent = 128;        // 128 parallel reads
config.smallFileThreshold = 1024 * 1024;  // 1 MB
config.useFixedBuffers = true;     // Zero-copy (io_uring)

auto hashes = FastHash.hashFilesAsync(paths, config);
```

### Reusable Hasher

```d
// Create once, use for multiple batches
auto hasher = FastHash.createAsyncHasher(maxConcurrent: 64);
scope(exit) hasher.shutdown();

auto batch1 = hasher.hashFiles(sourceFiles);
auto batch2 = hasher.hashFiles(headerFiles);
```

### Check Backend Availability

```d
if (FastHash.hasAsyncIO()) {
    // io_uring available on Linux
} else {
    // Using thread pool fallback
}
```

### Low-Level AsyncIO API

```d
import infrastructure.utils.io.async;

auto io = AsyncIO.create(queueDepth: 256);
scope(exit) io.shutdown();

// Prepare read requests
ReadRequest[] requests = [
    ReadRequest("file1.c", offset: 0, length: 4096, userData: 0),
    ReadRequest("file2.c", offset: 0, length: 4096, userData: 1),
];

ubyte[][] buffers = [new ubyte[4096], new ubyte[4096]];

// Submit batch
size_t submitted = io.submitReads(requests, buffers);

// Wait for completions
auto completions = io.waitCompletions(minComplete: submitted);

foreach (comp; completions) {
    if (comp.success)
        writeln("Read ", comp.result, " bytes from ", comp.path);
    else
        writeln("Error: ", comp.errorCode);
}
```

## io_uring Details

### Syscall Interface

```d
// Setup ring (syscall 425)
int fd = io_uring_setup(entries, &params);

// Map rings to userspace
mmap(sq_ring, cq_ring, sqes);

// Submit and wait (syscall 426)
io_uring_enter(fd, to_submit, min_complete, GETEVENTS);
```

### Structures

```d
// Submission Queue Entry (SQE) - 64 bytes
struct IoUringSqe {
    ubyte opcode;      // READ, WRITE, etc.
    ubyte flags;
    int fd;
    ulong off;         // Offset
    ulong addr;        // Buffer address
    uint len;          // Buffer length
    ulong user_data;   // Completion identifier
}

// Completion Queue Entry (CQE) - 16 bytes
struct IoUringCqe {
    ulong user_data;   // Matches SQE
    int res;           // Result or -errno
    uint flags;
}
```

### Supported Operations

```d
enum IoUringOp : ubyte {
    NOP = 0,
    READV = 1,
    WRITEV = 2,
    READ_FIXED = 4,
    WRITE_FIXED = 5,
    FSYNC = 6,
    READ = 22,
    WRITE = 23,
    OPENAT = 28,
    CLOSE = 29,
}
```

## When to Use

### Recommended

- **Many small files (>8)**: Async overhead is amortized
- **Cold page cache**: After restart, fresh clone, etc.
- **Initial project scan**: First build, large globs
- **CI/CD cold starts**: Fresh containers/VMs

### Not Recommended

- **Few files (<8)**: Sequential is faster (no overhead)
- **Hot page cache**: Files already in memory, CPU-bound
- **Very large files (>100MB)**: mmap is competitive

## Platform Support

| Platform | Backend | Notes |
|----------|---------|-------|
| Linux 5.1+ | io_uring | Optimal performance |
| Linux <5.1 | Thread Pool | Automatic fallback |
| macOS | Thread Pool | Default fallback |
| Windows | Thread Pool | Default fallback |

## Statistics

```d
auto hasher = new BatchHasher();
// ... hash files ...

auto stats = hasher.stats;
writefln("Files: %d", stats.filesHashed);
writefln("Bytes: %d MB", stats.bytesHashed / (1024 * 1024));
writefln("Batches: %d", stats.batchesProcessed);
writefln("Avg files/batch: %.1f", stats.avgFilesPerBatch());

auto elapsed = stopwatch.peek.total!"msecs" / 1000.0;
writefln("Throughput: %.2f MB/s", stats.throughputMBps(elapsed));
```

## Configuration

### BatchHasher.Config

| Field | Default | Description |
|-------|---------|-------------|
| `bufferSize` | 256 KB | Read buffer per file |
| `maxConcurrent` | 64 | Max parallel reads |
| `smallFileThreshold` | 1 MB | Direct read threshold |
| `useFixedBuffers` | true | Registered buffers (zero-copy) |

### AsyncIOCapability

```d
enum AsyncIOCapability {
    IoUring,      // Linux io_uring
    AIO,          // POSIX AIO (legacy)
    ThreadPool,   // Thread pool fallback
    Sync,         // Synchronous fallback
}
```

## Thread Safety

- `IoUring`: Single-producer (not thread-safe)
- `AsyncIO`: Thread-safe backend selection
- `BatchHasher`: Uses internal synchronization

## Troubleshooting

### io_uring Not Available

```d
if (!FastHash.hasAsyncIO()) {
    // Check: Linux 5.1+ required
    // WSL2 may not support io_uring
}
```

### Permission Errors

io_uring requires sufficient open file limits:
```bash
ulimit -n 65536
```

### Memory Pressure

Reduce `maxConcurrent` if seeing OOM:
```d
config.maxConcurrent = 32;  // Lower for constrained systems
```

## Related

- [BLAKE3 Hashing](blake3.md) - Hash algorithm used
- [Caching](caching.md) - How hashes enable caching
