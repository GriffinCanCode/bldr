module infrastructure.utils.io;

/// Async I/O infrastructure for high-performance file operations
/// 
/// Platform Support:
/// - Linux 5.1+: io_uring (zero-copy, kernel-polled, batch submission)
/// - All platforms: Thread pool fallback (parallel reads)
/// - Fallback: Synchronous I/O
/// 
/// Key Components:
/// - AsyncIO: Abstract async I/O service with automatic backend selection
/// - BatchHasher: Optimized batch file hashing for cold cache scenarios
/// 
/// Usage:
/// ```d
/// // Simple batch hashing
/// auto hashes = hashFilesAsync(paths);
/// 
/// // With custom configuration
/// auto hasher = new BatchHasher(BatchHasher.Config(
///     bufferSize: 512 * 1024,
///     maxConcurrent: 128
/// ));
/// auto results = hasher.hashFiles(paths);
/// hasher.shutdown();
/// ```
/// 
/// Performance:
/// - io_uring: ~3-5x faster on cold cache vs thread pool
/// - Thread pool: ~2x faster than sequential I/O
/// - Batch submission: amortizes syscall overhead

public import infrastructure.utils.io.async :
    AsyncIO,
    AsyncIOBackend,
    AsyncIOCapability,
    AsyncIOStats,
    AsyncResult,
    ReadRequest,
    ThreadPoolBackend,
    SyncBackend;

public import infrastructure.utils.io.batch :
    BatchHasher,
    BatchHashStats,
    hashFilesAsync;

version(linux)
{
    public import infrastructure.utils.io.uring :
        IoUring,
        UringStats,
        uringStats,
        resetUringStats,
        isIoUringAvailable;
    
    public import infrastructure.utils.io.async : IoUringBackend;
}

