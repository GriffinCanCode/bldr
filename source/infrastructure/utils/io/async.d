module infrastructure.utils.io.async;

import core.atomic;
import std.algorithm : min;
import std.conv : to;
import std.file : exists, getSize;
import std.string : toStringz;
import infrastructure.utils.concurrency.pool;

/// Async I/O operation result
struct AsyncResult
{
    ulong id;           // Request identifier
    int result;         // Bytes read/written or -errno
    string path;        // File path (for error context)
    
    bool success() const pure nothrow @nogc => result >= 0;
    bool isError() const pure nothrow @nogc => result < 0;
    int errorCode() const pure nothrow @nogc => result < 0 ? -result : 0;
}

/// Async read request
struct ReadRequest
{
    string path;
    ulong offset;
    uint length;
    ulong userData;     // Opaque user data for completion tracking
}

/// Async I/O capabilities enumeration
enum AsyncIOCapability
{
    IoUring,            // Linux io_uring (zero-copy, kernel-polled)
    AIO,                // POSIX AIO (legacy)
    ThreadPool,         // Fallback thread pool
    Sync,               // Synchronous fallback
}

/// Statistics for async I/O operations
struct AsyncIOStats
{
    size_t readsSubmitted;
    size_t readsCompleted;
    size_t bytesRead;
    size_t batchesSubmitted;
    double avgBatchSize;
    
    void recordBatch(size_t count) @safe nothrow @nogc
    {
        if (batchesSubmitted == 0)
            avgBatchSize = cast(double)count;
        else
            avgBatchSize = (avgBatchSize * batchesSubmitted + count) / (batchesSubmitted + 1);
        batchesSubmitted++;
    }
}

/// Abstract async I/O backend
/// Enables platform-specific implementations with common interface
interface AsyncIOBackend
{
    /// Get backend capability type
    AsyncIOCapability capability() const @safe nothrow;
    
    /// Check if backend is available and functional
    bool available() const @safe nothrow;
    
    /// Submit batch of read requests
    /// Returns: number of requests successfully submitted
    size_t submitReads(const(ReadRequest)[] requests, scope ubyte[][] buffers) @system;
    
    /// Wait for and collect completed operations
    /// Returns: completed results (may be fewer than submitted)
    AsyncResult[] waitCompletions(uint minComplete = 1) @system;
    
    /// Process completions with callback (non-blocking)
    /// Returns: number of completions processed
    size_t processCompletions(scope void delegate(AsyncResult) @system handler) @system;
    
    /// Get statistics
    const(AsyncIOStats) stats() const @safe nothrow;
    
    /// Shutdown backend
    void shutdown() @system;
}

/// io_uring backend (Linux only)
version(linux)
{
    final class IoUringBackend : AsyncIOBackend
    {
        private
        {
            import infrastructure.utils.io.uring : IoUring, isIoUringAvailable;
            
            IoUring _ring;
            bool _available;
            AsyncIOStats _stats;
            
            // Pending requests tracking
            struct PendingRead { string path; int fd; }
            PendingRead[ulong] _pending;
            ulong _nextId;
            
            // Pre-opened file descriptors cache
            int[string] _fdCache;
        }
        
        this(uint queueDepth = 256) @system
        {
            if (isIoUringAvailable())
            {
                string err;
                _ring = IoUring.create(queueDepth, 0, &err);
                _available = _ring !is null && _ring.valid;
            }
        }
        
        AsyncIOCapability capability() const @safe nothrow => AsyncIOCapability.IoUring;
        
        bool available() const @safe nothrow => _available;
        
        size_t submitReads(const(ReadRequest)[] requests, scope ubyte[][] buffers) @system
        {
            if (!_available || requests.length == 0) return 0;
            if (buffers.length < requests.length) return 0;
            
            size_t submitted = 0;
            
            foreach (i, ref req; requests)
            {
                // Get or open file descriptor
                int fd = getFd(req.path);
                if (fd < 0) continue;
                
                // Prepare read
                ulong id = _nextId++;
                if (!_ring.prepRead(fd, buffers[i].ptr, req.length, req.offset, id))
                    break;  // Queue full
                
                _pending[id] = PendingRead(req.path, fd);
                submitted++;
                _stats.readsSubmitted++;
            }
            
            if (submitted > 0)
            {
                _ring.submit();
                _stats.recordBatch(submitted);
            }
            
            return submitted;
        }
        
        AsyncResult[] waitCompletions(uint minComplete = 1) @system
        {
            if (!_available) return [];
            
            _ring.submitAndWait(minComplete);
            
            AsyncResult[] results;
            results.reserve(minComplete);
            
            processCompletions((AsyncResult r) @system {
                results ~= r;
            });
            
            return results;
        }
        
        size_t processCompletions(scope void delegate(AsyncResult) @system handler) @system
        {
            if (!_available) return 0;
            
            return _ring.processCompletions((ulong userData, int result) @system {
                AsyncResult r;
                r.id = userData;
                r.result = result;
                
                if (auto pending = userData in _pending)
                {
                    r.path = pending.path;
                    _pending.remove(userData);
                }
                
                if (result > 0)
                {
                    _stats.bytesRead += result;
                    _stats.readsCompleted++;
                }
                
                handler(r);
            });
        }
        
        const(AsyncIOStats) stats() const @safe nothrow => _stats;
        
        void shutdown() @system
        {
            if (!_available) return;
            
            // Close cached file descriptors
            import core.sys.posix.unistd : close;
            foreach (fd; _fdCache.byValue)
                if (fd >= 0) close(fd);
            _fdCache.clear();
            
            _ring.cleanup();
            _available = false;
        }
        
        private int getFd(string path) @system nothrow
        {
            import core.sys.posix.fcntl : open, O_RDONLY;
            
            if (auto cached = path in _fdCache)
                return *cached;
            
            int fd = open(path.toStringz, O_RDONLY);
            if (fd >= 0)
                _fdCache[path] = fd;
            
            return fd;
        }
    }
}

/// Thread pool fallback backend (all platforms)
final class ThreadPoolBackend : AsyncIOBackend
{
    private
    {
        ThreadPool _pool;
        AsyncIOStats _stats;
        shared ulong _nextId;
        
        // Completion queue
        AsyncResult[] _completions;
        Object _completionLock;
    }
    
    this(size_t workerCount = 0) @system
    {
        import std.parallelism : totalCPUs;
        _pool = new ThreadPool(workerCount == 0 ? totalCPUs : workerCount);
        _completionLock = new Object();
    }
    
    AsyncIOCapability capability() const @safe nothrow => AsyncIOCapability.ThreadPool;
    
    bool available() const @safe nothrow => _pool !is null;
    
    size_t submitReads(const(ReadRequest)[] requests, scope ubyte[][] buffers) @system
    {
        import std.file : read;
        import std.stdio : File;
        
        if (requests.length == 0) return 0;
        if (buffers.length < requests.length) return 0;
        
        // Execute reads in thread pool
        size_t submitted = requests.length;
        
        // Create work items
        auto workItems = new void delegate() @system[requests.length];
        foreach (i, ref req; requests)
        {
            immutable idx = i;
            immutable path = req.path;
            immutable offset = req.offset;
            immutable length = req.length;
            auto buf = buffers[idx];
            immutable id = atomicOp!"+="(_nextId, 1) - 1;
            
            workItems[idx] = () @system {
                AsyncResult result;
                result.id = id;
                result.path = path;
                
                try
                {
                    if (!exists(path))
                    {
                        result.result = -2; // ENOENT
                    }
                    else
                    {
                        auto file = File(path, "rb");
                        if (offset > 0) file.seek(offset);
                        auto bytesRead = file.rawRead(buf[0 .. min(length, buf.length)]);
                        result.result = cast(int)bytesRead.length;
                    }
                }
                catch (Exception)
                {
                    result.result = -5; // EIO
                }
                
                synchronized (_completionLock)
                    _completions ~= result;
            };
        }
        
        // Submit all work items
        _pool.forEach(workItems, (void delegate() @system work) @system { work(); });
        
        _stats.readsSubmitted += submitted;
        _stats.recordBatch(submitted);
        
        return submitted;
    }
    
    AsyncResult[] waitCompletions(uint minComplete = 1) @system
    {
        // Thread pool executes synchronously in forEach, so completions are ready
        AsyncResult[] results;
        
        synchronized (_completionLock)
        {
            results = _completions.dup;
            
            foreach (ref r; results)
            {
                if (r.success)
                {
                    _stats.bytesRead += r.result;
                    _stats.readsCompleted++;
                }
            }
            
            _completions.length = 0;
        }
        
        return results;
    }
    
    size_t processCompletions(scope void delegate(AsyncResult) @system handler) @system
    {
        size_t count = 0;
        
        synchronized (_completionLock)
        {
            foreach (ref r; _completions)
            {
                if (r.success)
                {
                    _stats.bytesRead += r.result;
                    _stats.readsCompleted++;
                }
                handler(r);
                count++;
            }
            _completions.length = 0;
        }
        
        return count;
    }
    
    const(AsyncIOStats) stats() const @safe nothrow => _stats;
    
    void shutdown() @system
    {
        if (_pool !is null)
        {
            _pool.shutdown();
            _pool = null;
        }
    }
}

/// Synchronous fallback backend (minimal overhead)
final class SyncBackend : AsyncIOBackend
{
    private AsyncIOStats _stats;
    
    AsyncIOCapability capability() const @safe nothrow => AsyncIOCapability.Sync;
    bool available() const @safe nothrow => true;
    
    size_t submitReads(const(ReadRequest)[] requests, scope ubyte[][] buffers) @system
    {
        import std.stdio : File;
        
        if (requests.length == 0) return 0;
        
        foreach (i, ref req; requests)
        {
            if (i >= buffers.length) break;
            
            try
            {
                if (!exists(req.path)) continue;
                
                auto file = File(req.path, "rb");
                if (req.offset > 0) file.seek(req.offset);
                auto bytesRead = file.rawRead(buffers[i][0 .. min(req.length, buffers[i].length)]);
                
                _stats.bytesRead += bytesRead.length;
                _stats.readsCompleted++;
            }
            catch (Exception) { }
            
            _stats.readsSubmitted++;
        }
        
        _stats.recordBatch(requests.length);
        return requests.length;
    }
    
    AsyncResult[] waitCompletions(uint minComplete = 1) @system => [];
    
    size_t processCompletions(scope void delegate(AsyncResult) @system handler) @system => 0;
    
    const(AsyncIOStats) stats() const @safe nothrow => _stats;
    
    void shutdown() @system {}
}

/// Async I/O service - factory and capability management
/// Automatically selects best available backend for platform
final class AsyncIO
{
    private AsyncIOBackend _backend;
    private bool _initialized;
    
    private this() {}  // Use factory
    
    /// Create async I/O service with best available backend
    static AsyncIO create(uint queueDepth = 256) @system
    {
        auto io = new AsyncIO();
        
        // Try io_uring first (Linux)
        version(linux)
        {
            auto uringBackend = new IoUringBackend(queueDepth);
            if (uringBackend.available)
            {
                io._backend = uringBackend;
                io._initialized = true;
                return io;
            }
        }
        
        // Fallback to thread pool
        io._backend = new ThreadPoolBackend();
        io._initialized = true;
        
        return io;
    }
    
    /// Create with specific backend type
    static AsyncIO createWithBackend(AsyncIOCapability cap, uint queueDepth = 256) @system
    {
        auto io = new AsyncIO();
        
        final switch (cap)
        {
            case AsyncIOCapability.IoUring:
                version(linux)
                {
                    io._backend = new IoUringBackend(queueDepth);
                }
                else
                {
                    io._backend = new ThreadPoolBackend();
                }
                break;
                
            case AsyncIOCapability.ThreadPool:
                io._backend = new ThreadPoolBackend();
                break;
                
            case AsyncIOCapability.Sync:
            case AsyncIOCapability.AIO:
                io._backend = new SyncBackend();
                break;
        }
        
        io._initialized = true;
        return io;
    }
    
    /// Get current capability
    AsyncIOCapability capability() const @safe nothrow =>
        _backend !is null ? _backend.capability : AsyncIOCapability.Sync;
    
    /// Check if service is initialized
    bool initialized() const @safe nothrow => _initialized && _backend !is null;
    
    /// Submit batch reads
    size_t submitReads(const(ReadRequest)[] requests, scope ubyte[][] buffers) @system =>
        _backend !is null ? _backend.submitReads(requests, buffers) : 0;
    
    /// Wait for completions
    AsyncResult[] waitCompletions(uint minComplete = 1) @system =>
        _backend !is null ? _backend.waitCompletions(minComplete) : [];
    
    /// Process completions with callback
    size_t processCompletions(scope void delegate(AsyncResult) @system handler) @system =>
        _backend !is null ? _backend.processCompletions(handler) : 0;
    
    /// Get statistics
    const(AsyncIOStats) stats() const @safe nothrow =>
        _backend !is null ? _backend.stats : AsyncIOStats.init;
    
    /// Shutdown service
    void shutdown() @system
    {
        if (_backend !is null)
        {
            _backend.shutdown();
            _backend = null;
        }
        _initialized = false;
    }
    
    /// Get human-readable description
    override string toString() const
    {
        import std.format : format;
        return format("AsyncIO(capability=%s, initialized=%s)", capability, _initialized);
    }
}

unittest
{
    // Test sync backend
    auto syncBackend = new SyncBackend();
    assert(syncBackend.available);
    assert(syncBackend.capability == AsyncIOCapability.Sync);
    
    // Test AsyncIO factory
    auto io = AsyncIO.create();
    assert(io.initialized);
    
    io.shutdown();
}

