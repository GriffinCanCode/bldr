module infrastructure.utils.io.uring;

/// io_uring async I/O for Linux 5.1+
/// Enables kernel-level async file I/O without thread pool overhead
/// 
/// Design:
/// - Zero-copy via registered buffers
/// - Batch submission (multiple SQEs per syscall)
/// - SQPOLL mode for kernel-side polling
/// - Fallback to null implementation on non-Linux

version(linux):

import core.stdc.errno : errno, EAGAIN, EINTR, ENOSYS;
import core.stdc.string : memset;
import core.sys.posix.unistd : close;
import core.sys.posix.fcntl : open, O_RDONLY, O_DIRECT;
import core.sys.posix.sys.mman : mmap, munmap, PROT_READ, PROT_WRITE, MAP_SHARED, MAP_FAILED;
import core.memory : GC;
import std.exception : enforce;
import std.conv : to;

/// io_uring operation codes
enum IoUringOp : ubyte
{
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

/// io_uring setup flags
enum IoUringSetup : uint
{
    IOPOLL = 1 << 0,      // Busy-poll completion queue
    SQPOLL = 1 << 1,      // Kernel-side SQ polling
    SQ_AFF = 1 << 2,      // SQ poll thread CPU affinity
    CQSIZE = 1 << 3,      // Custom CQ size
    CLAMP = 1 << 4,       // Clamp SQ/CQ ring size
    ATTACH_WQ = 1 << 5,   // Share async backend
    R_DISABLED = 1 << 6,  // Ring starts disabled
}

/// SQE flags
enum IoUringSqeFlags : ubyte
{
    FIXED_FILE = 1 << 0,
    IO_DRAIN = 1 << 1,
    IO_LINK = 1 << 2,
    IO_HARDLINK = 1 << 3,
    ASYNC = 1 << 4,
    BUFFER_SELECT = 1 << 5,
}

/// Submission Queue Entry (SQE) - 64 bytes
struct IoUringSqe
{
    ubyte opcode;
    ubyte flags;
    ushort ioprio;
    int fd;
    union {
        ulong off;       // offset
        ulong addr2;
    }
    union {
        ulong addr;      // buffer address
        ulong splice_off_in;
    }
    uint len;            // buffer length
    union {
        uint rw_flags;
        uint fsync_flags;
        uint open_flags;
        ushort buf_index;
    }
    ulong user_data;     // completion identifier
    union {
        ushort buf_group;
        ubyte[3] __pad;
    }
    ushort personality;
    union {
        int splice_fd_in;
        uint file_index;
    }
    ulong[2] __pad2;
}

/// Completion Queue Entry (CQE) - 16 bytes
struct IoUringCqe
{
    ulong user_data;     // matches SQE user_data
    int res;             // result or -errno
    uint flags;
}

/// io_uring parameters for setup
struct IoUringParams
{
    uint sq_entries;
    uint cq_entries;
    uint flags;
    uint sq_thread_cpu;
    uint sq_thread_idle;
    uint[5] features;
    uint wq_fd;
    uint[3] resv;
    uint sq_off_head;
    uint sq_off_tail;
    uint sq_off_ring_mask;
    uint sq_off_ring_entries;
    uint sq_off_flags;
    uint sq_off_dropped;
    uint sq_off_array;
    uint resv1;
    ulong resv2;
    uint cq_off_head;
    uint cq_off_tail;
    uint cq_off_ring_mask;
    uint cq_off_ring_entries;
    uint cq_off_overflow;
    uint cq_off_cqes;
    uint cq_off_flags;
    uint resv3;
    ulong resv4;
}

/// io_uring syscall wrappers
extern(C) @nogc nothrow
{
    // NR_io_uring_setup = 425 on x86_64
    private int io_uring_setup(uint entries, IoUringParams* params)
    {
        import core.sys.posix.unistd : syscall;
        return cast(int)syscall(425, entries, params);
    }
    
    // NR_io_uring_enter = 426 on x86_64
    private int io_uring_enter(int fd, uint to_submit, uint min_complete, uint flags, void* sig)
    {
        import core.sys.posix.unistd : syscall;
        return cast(int)syscall(426, fd, to_submit, min_complete, flags, sig);
    }
    
    // NR_io_uring_register = 427 on x86_64
    private int io_uring_register(int fd, uint opcode, void* arg, uint nr_args)
    {
        import core.sys.posix.unistd : syscall;
        return cast(int)syscall(427, fd, opcode, arg, nr_args);
    }
}

/// Register opcodes
enum IoUringRegisterOp : uint
{
    REGISTER_BUFFERS = 0,
    UNREGISTER_BUFFERS = 1,
    REGISTER_FILES = 2,
    UNREGISTER_FILES = 3,
}

/// Enter flags
enum IoUringEnter : uint
{
    GETEVENTS = 1 << 0,
    SQ_WAKEUP = 1 << 1,
    SQ_WAIT = 1 << 2,
}

/// Statistics for io_uring operations
struct UringStats
{
    size_t sqesSubmitted;
    size_t cqesCompleted;
    size_t bytesRead;
    size_t bytesWritten;
    size_t syscallsEnter;
    
    double efficiency() const pure nothrow @nogc =>
        sqesSubmitted > 0 ? cast(double)cqesCompleted / sqesSubmitted : 0.0;
}

/// Global stats (thread-local)
private UringStats _stats;
UringStats uringStats() @safe nothrow @nogc => _stats;
void resetUringStats() @safe nothrow @nogc { _stats = UringStats.init; }

/// io_uring ring instance
/// RAII wrapper with automatic cleanup
final class IoUring
{
    private int _ringFd = -1;
    private void* _sqRing;
    private void* _cqRing;
    private IoUringSqe* _sqes;
    private size_t _sqRingSize;
    private size_t _cqRingSize;
    private size_t _sqeSize;
    private uint _sqMask;
    private uint _cqMask;
    private uint* _sqHead;
    private uint* _sqTail;
    private uint* _sqArray;
    private uint* _cqHead;
    private uint* _cqTail;
    private IoUringCqe* _cqes;
    private bool _valid;
    private uint _pendingSubmissions;
    
    // Fixed buffers for zero-copy
    private ubyte[][] _registeredBuffers;
    private bool _buffersRegistered;
    
    private this() {}  // Use factory
    
    /// Create io_uring instance
    /// entries: queue depth (power of 2, max ~32K)
    /// flags: setup flags (SQPOLL for kernel polling)
    static IoUring create(uint entries = 256, uint flags = 0, string* error = null) @system
    {
        auto ring = new IoUring();
        
        IoUringParams params;
        memset(&params, 0, IoUringParams.sizeof);
        params.flags = flags;
        
        ring._ringFd = io_uring_setup(entries, &params);
        if (ring._ringFd < 0)
        {
            if (error) *error = "io_uring_setup failed: " ~ errnoMsg();
            return null;
        }
        
        // Map SQ ring
        ring._sqRingSize = params.sq_off_array + params.sq_entries * uint.sizeof;
        ring._sqRing = mmap(null, ring._sqRingSize, PROT_READ | PROT_WRITE,
                           MAP_SHARED, ring._ringFd, 0);
        
        if (ring._sqRing == MAP_FAILED)
        {
            close(ring._ringFd);
            if (error) *error = "Failed to mmap SQ ring";
            return null;
        }
        
        // Map CQ ring (may overlap with SQ ring in newer kernels)
        ring._cqRingSize = params.cq_off_cqes + params.cq_entries * IoUringCqe.sizeof;
        ring._cqRing = mmap(null, ring._cqRingSize, PROT_READ | PROT_WRITE,
                           MAP_SHARED, ring._ringFd, 0x8000000UL);
        
        if (ring._cqRing == MAP_FAILED)
        {
            munmap(ring._sqRing, ring._sqRingSize);
            close(ring._ringFd);
            if (error) *error = "Failed to mmap CQ ring";
            return null;
        }
        
        // Map SQEs
        ring._sqeSize = params.sq_entries * IoUringSqe.sizeof;
        auto sqeMem = mmap(null, ring._sqeSize, PROT_READ | PROT_WRITE,
                          MAP_SHARED, ring._ringFd, 0x10000000UL);
        
        if (sqeMem == MAP_FAILED)
        {
            munmap(ring._cqRing, ring._cqRingSize);
            munmap(ring._sqRing, ring._sqRingSize);
            close(ring._ringFd);
            if (error) *error = "Failed to mmap SQEs";
            return null;
        }
        ring._sqes = cast(IoUringSqe*)sqeMem;
        
        // Setup ring pointers
        ring._sqMask = *cast(uint*)(ring._sqRing + params.sq_off_ring_mask);
        ring._cqMask = *cast(uint*)(ring._cqRing + params.cq_off_ring_mask);
        ring._sqHead = cast(uint*)(ring._sqRing + params.sq_off_head);
        ring._sqTail = cast(uint*)(ring._sqRing + params.sq_off_tail);
        ring._sqArray = cast(uint*)(ring._sqRing + params.sq_off_array);
        ring._cqHead = cast(uint*)(ring._cqRing + params.cq_off_head);
        ring._cqTail = cast(uint*)(ring._cqRing + params.cq_off_tail);
        ring._cqes = cast(IoUringCqe*)(ring._cqRing + params.cq_off_cqes);
        
        ring._valid = true;
        GC.addRoot(cast(void*)ring);  // Prevent premature collection
        
        return ring;
    }
    
    ~this() @system
    {
        cleanup();
    }
    
    /// Explicit cleanup
    void cleanup() @system nothrow
    {
        if (!_valid) return;
        
        if (_buffersRegistered)
        {
            io_uring_register(_ringFd, IoUringRegisterOp.UNREGISTER_BUFFERS, null, 0);
            _buffersRegistered = false;
        }
        
        if (_sqes !is null)
            munmap(cast(void*)_sqes, _sqeSize);
        if (_cqRing !is null)
            munmap(_cqRing, _cqRingSize);
        if (_sqRing !is null)
            munmap(_sqRing, _sqRingSize);
        if (_ringFd >= 0)
            close(_ringFd);
        
        _valid = false;
        GC.removeRoot(cast(void*)&this);
    }
    
    /// Check if ring is valid
    bool valid() const @safe pure nothrow @nogc => _valid;
    
    /// Get next SQE slot (returns null if queue full)
    IoUringSqe* getSqe() @system nothrow @nogc
    {
        if (!_valid) return null;
        
        uint head = atomicLoad(_sqHead);
        uint tail = atomicLoad(_sqTail);
        uint next = tail + 1;
        
        // Check if queue is full
        if (next - head > _sqMask + 1)
            return null;
        
        uint idx = tail & _sqMask;
        _sqArray[idx] = idx;
        
        auto sqe = &_sqes[idx];
        memset(sqe, 0, IoUringSqe.sizeof);
        
        return sqe;
    }
    
    /// Advance SQ tail (call after populating SQE)
    void advanceSq() @system nothrow @nogc
    {
        import core.atomic : atomicOp;
        atomicOp!"+="(*_sqTail, 1);
        _pendingSubmissions++;
    }
    
    /// Prepare read operation
    bool prepRead(int fd, void* buf, uint len, ulong offset, ulong userData) @system nothrow @nogc
    {
        auto sqe = getSqe();
        if (sqe is null) return false;
        
        sqe.opcode = IoUringOp.READ;
        sqe.fd = fd;
        sqe.addr = cast(ulong)buf;
        sqe.len = len;
        sqe.off = offset;
        sqe.user_data = userData;
        
        advanceSq();
        return true;
    }
    
    /// Prepare read with fixed buffer (zero-copy)
    bool prepReadFixed(int fd, ushort bufIdx, uint len, ulong offset, ulong userData) @system nothrow @nogc
    {
        auto sqe = getSqe();
        if (sqe is null) return false;
        
        sqe.opcode = IoUringOp.READ_FIXED;
        sqe.flags = IoUringSqeFlags.FIXED_FILE;
        sqe.fd = fd;
        sqe.len = len;
        sqe.off = offset;
        sqe.buf_index = bufIdx;
        sqe.user_data = userData;
        
        advanceSq();
        return true;
    }
    
    /// Submit queued operations
    int submit() @system nothrow
    {
        if (!_valid || _pendingSubmissions == 0) return 0;
        
        int ret = io_uring_enter(_ringFd, _pendingSubmissions, 0, 0, null);
        
        if (ret >= 0)
        {
            _stats.sqesSubmitted += ret;
            _stats.syscallsEnter++;
            _pendingSubmissions = 0;
        }
        
        return ret;
    }
    
    /// Submit and wait for completions
    int submitAndWait(uint minComplete) @system nothrow
    {
        if (!_valid) return -1;
        
        int ret = io_uring_enter(_ringFd, _pendingSubmissions, minComplete,
                                IoUringEnter.GETEVENTS, null);
        
        if (ret >= 0)
        {
            _stats.sqesSubmitted += _pendingSubmissions;
            _stats.syscallsEnter++;
            _pendingSubmissions = 0;
        }
        
        return ret;
    }
    
    /// Peek at completions (non-blocking)
    IoUringCqe* peekCqe() @system nothrow @nogc
    {
        if (!_valid) return null;
        
        uint head = atomicLoad(_cqHead);
        uint tail = atomicLoad(_cqTail);
        
        if (head == tail) return null;
        
        return &_cqes[head & _cqMask];
    }
    
    /// Advance CQ head (call after processing CQE)
    void advanceCq() @system nothrow @nogc
    {
        import core.atomic : atomicOp;
        atomicOp!"+="(*_cqHead, 1);
        _stats.cqesCompleted++;
    }
    
    /// Process all available completions
    size_t processCompletions(scope void delegate(ulong userData, int result) @system handler) @system
    {
        size_t count = 0;
        
        while (true)
        {
            auto cqe = peekCqe();
            if (cqe is null) break;
            
            handler(cqe.user_data, cqe.res);
            advanceCq();
            count++;
        }
        
        return count;
    }
    
    /// Register fixed buffers for zero-copy operations
    bool registerBuffers(ubyte[][] buffers) @system
    {
        if (!_valid || _buffersRegistered) return false;
        
        // Create iovec array
        static struct Iovec { void* base; size_t len; }
        auto iovecs = new Iovec[buffers.length];
        
        foreach (i, ref buf; buffers)
        {
            iovecs[i].base = buf.ptr;
            iovecs[i].len = buf.length;
        }
        
        int ret = io_uring_register(_ringFd, IoUringRegisterOp.REGISTER_BUFFERS,
                                   iovecs.ptr, cast(uint)iovecs.length);
        
        if (ret < 0) return false;
        
        _registeredBuffers = buffers;
        _buffersRegistered = true;
        return true;
    }
    
    /// Unregister fixed buffers
    void unregisterBuffers() @system nothrow
    {
        if (!_valid || !_buffersRegistered) return;
        
        io_uring_register(_ringFd, IoUringRegisterOp.UNREGISTER_BUFFERS, null, 0);
        _buffersRegistered = false;
        _registeredBuffers = null;
    }
    
    /// Get number of pending submissions
    uint pendingSubmissions() const @safe pure nothrow @nogc => _pendingSubmissions;
}

/// Atomic load helper
private T atomicLoad(T)(ref shared T val) @trusted nothrow @nogc
{
    import core.atomic : atomicLoad, MemoryOrder;
    return atomicLoad!(MemoryOrder.acq)(val);
}

private T atomicLoad(T)(T* ptr) @trusted nothrow @nogc
{
    import core.atomic : atomicLoad, MemoryOrder;
    return atomicLoad!(MemoryOrder.acq)(*cast(shared T*)ptr);
}

/// Error message helper
private string errnoMsg() @trusted nothrow
{
    import core.stdc.string : strerror;
    import std.string : fromStringz;
    auto err = errno;
    auto msg = strerror(err);
    return msg ? fromStringz(msg).idup : "errno " ~ err.to!string;
}

/// Check if io_uring is available on this system
bool isIoUringAvailable() @system nothrow
{
    IoUringParams params;
    memset(&params, 0, IoUringParams.sizeof);
    
    int fd = io_uring_setup(1, &params);
    if (fd < 0)
    {
        // ENOSYS = syscall not available
        return errno != ENOSYS;
    }
    
    close(fd);
    return true;
}

unittest
{
    // Test availability check
    bool available = isIoUringAvailable();
    
    if (available)
    {
        string err;
        auto ring = IoUring.create(64, 0, &err);
        assert(ring !is null, err);
        assert(ring.valid);
        
        ring.cleanup();
        assert(!ring.valid);
    }
}

