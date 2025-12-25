module infrastructure.utils.memory.mmap;

import core.stdc.errno : errno, EINVAL, ENOMEM, EACCES, ENOENT;
import core.memory : GC;
import std.exception : enforce;
import std.file : exists, getSize;
import std.conv : to;
import std.string : fromStringz, toStringz;

version(Posix)
{
    import core.sys.posix.sys.mman;
    import core.sys.posix.unistd : sysconf, _SC_PAGESIZE, close;
    import core.sys.posix.fcntl : open, O_RDONLY, O_RDWR, O_CREAT;
}

version(Windows)
{
    import core.sys.windows.windows;
}

/// Memory mapping mode
enum MapMode : ubyte
{
    ReadOnly,   /// Read-only mapping (default, most efficient)
    ReadWrite,  /// Read-write mapping (changes written to file)
    Private,    /// Copy-on-write mapping (changes not persisted)
}

/// Memory mapping advice for kernel optimization
enum MapAdvice : ubyte
{
    Normal,      /// Default access pattern
    Sequential,  /// Sequential access (prefetch ahead)
    Random,      /// Random access (disable prefetch)
    WillNeed,    /// Expect access soon (prefetch now)
    DontNeed,    /// Not needed soon (allow eviction)
}

/// Statistics for memory mapping operations
struct MmapStats
{
    size_t mappingsCreated;
    size_t mappingsClosed;
    size_t totalBytesRead;
    size_t totalBytesMapped;
    size_t pageFaults;
    
    /// Memory efficiency ratio
    double efficiency() const pure nothrow @nogc =>
        totalBytesMapped > 0 ? cast(double)totalBytesRead / totalBytesMapped : 0.0;
}

/// Global mmap statistics (thread-local)
private MmapStats _stats;

/// Get mmap statistics for current thread
MmapStats mmapStats() @safe nothrow @nogc => _stats;

/// Reset mmap statistics
void resetMmapStats() @safe nothrow @nogc { _stats = MmapStats.init; }

/// RAII wrapper for memory-mapped regions (class for reference semantics)
/// Provides zero-copy file access with automatic cleanup
/// 
/// Design:
/// - Kernel page cache shared across processes
/// - No user-space buffering (zero-copy)
/// - Lazy loading via page faults
/// - Automatic unmap on destructor
/// 
/// Use Cases:
/// - Large blob access without heap allocation
/// - Graph persistence (load without deserialization)
/// - Artifact streaming (no intermediate copies)
final class MmapRegion
{
    private void* _ptr;
    private void* _basePtr;      // Actual mmap'd address (page-aligned)
    private size_t _length;
    private size_t _mapLength;   // Actual mmap'd length (includes alignment padding)
    private MapMode _mode;
    private bool _valid;
    
    version(Posix) private int _fd = -1;
    version(Windows)
    {
        private HANDLE _fileHandle = INVALID_HANDLE_VALUE;
        private HANDLE _mapHandle;
    }
    
    private this() {}  // Use factory methods
    
    /// Map a file into memory
    /// 
    /// Safety: @system due to:
    /// - Direct syscall invocation (mmap/MapViewOfFile)
    /// - Raw pointer management
    /// - File descriptor handling
    /// 
    /// Returns: MmapRegion on success, null with error message on failure
    static MmapRegion map(
        string path,
        MapMode mode = MapMode.ReadOnly,
        size_t offset = 0,
        size_t length = 0,
        string* error = null
    ) @system
    {
        if (!exists(path))
        {
            if (error) *error = "File not found: " ~ path;
            return null;
        }
        
        immutable fileSize = getSize(path);
        if (fileSize == 0)
        {
            if (error) *error = "Cannot map empty file: " ~ path;
            return null;
        }
        
        // Default to mapping entire file
        if (length == 0)
            length = fileSize - offset;
        
        if (offset + length > fileSize)
        {
            if (error) *error = "Mapping extends beyond file end";
            return null;
        }
        
        auto region = new MmapRegion();
        region._length = length;
        region._mode = mode;
        
        version(Posix)
        {
            // Open file descriptor
            int flags = (mode == MapMode.ReadOnly) ? O_RDONLY : O_RDWR;
            region._fd = open(path.toStringz, flags);
            
            if (region._fd < 0)
            {
                if (error) *error = "Failed to open file: " ~ errnoString();
                return null;
            }
            
            // Align offset down to page boundary (mmap requires page-aligned offsets)
            immutable ps = pageSize();
            immutable alignedOffset = offset & ~(ps - 1);
            immutable offsetDelta = offset - alignedOffset;
            immutable mapLen = length + offsetDelta;
            
            region._mapLength = mapLen;
            
            // Map memory
            int prot = (mode == MapMode.ReadOnly) ? PROT_READ : (PROT_READ | PROT_WRITE);
            int mapFlags = (mode == MapMode.Private) ? MAP_PRIVATE : MAP_SHARED;
            
            region._basePtr = mmap(null, mapLen, prot, mapFlags, region._fd, alignedOffset);
            
            if (region._basePtr == MAP_FAILED)
            {
                close(region._fd);
                region._fd = -1;
                if (error) *error = "mmap failed: " ~ errnoString();
                return null;
            }
            
            // Adjust pointer to requested offset within the mapped region
            region._ptr = region._basePtr + offsetDelta;
        }
        version(Windows)
        {
            // Open file
            DWORD access = (mode == MapMode.ReadOnly) ? GENERIC_READ : (GENERIC_READ | GENERIC_WRITE);
            region._fileHandle = CreateFileA(
                path.toStringz, access, FILE_SHARE_READ, null,
                OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null
            );
            
            if (region._fileHandle == INVALID_HANDLE_VALUE)
            {
                if (error) *error = "Failed to open file";
                return null;
            }
            
            // Create file mapping
            DWORD protect = (mode == MapMode.ReadOnly) ? PAGE_READONLY :
                           (mode == MapMode.Private) ? PAGE_WRITECOPY : PAGE_READWRITE;
            
            region._mapHandle = CreateFileMappingA(
                region._fileHandle, null, protect, 0, 0, null
            );
            
            if (region._mapHandle is null)
            {
                CloseHandle(region._fileHandle);
                if (error) *error = "CreateFileMapping failed";
                return null;
            }
            
            // Map view (Windows handles alignment internally)
            DWORD mapAccess = (mode == MapMode.ReadOnly) ? FILE_MAP_READ :
                             (mode == MapMode.Private) ? FILE_MAP_COPY : FILE_MAP_ALL_ACCESS;
            
            region._basePtr = MapViewOfFile(region._mapHandle, mapAccess, 0, cast(DWORD)offset, length);
            region._ptr = region._basePtr;
            region._mapLength = length;
            
            if (region._ptr is null)
            {
                CloseHandle(region._mapHandle);
                CloseHandle(region._fileHandle);
                if (error) *error = "MapViewOfFile failed";
                return null;
            }
        }
        
        region._valid = true;
        _stats.mappingsCreated++;
        _stats.totalBytesMapped += length;
        
        return region;
    }
    
    /// Map anonymous memory (not backed by file)
    /// Useful for large temporary allocations that bypass GC
    static MmapRegion anonymous(size_t length, string* error = null) @system
    {
        if (length == 0)
        {
            if (error) *error = "Cannot map zero bytes";
            return null;
        }
        
        auto region = new MmapRegion();
        region._length = length;
        region._mapLength = length;
        region._mode = MapMode.Private;
        
        version(Posix)
        {
            region._basePtr = mmap(null, length, PROT_READ | PROT_WRITE,
                                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            
            if (region._basePtr == MAP_FAILED)
            {
                if (error) *error = "Anonymous mmap failed: " ~ errnoString();
                return null;
            }
            region._ptr = region._basePtr;
        }
        version(Windows)
        {
            region._mapHandle = CreateFileMappingA(
                INVALID_HANDLE_VALUE, null, PAGE_READWRITE,
                cast(DWORD)(length >> 32), cast(DWORD)length, null
            );
            
            if (region._mapHandle is null)
            {
                if (error) *error = "CreateFileMapping failed for anonymous";
                return null;
            }
            
            region._basePtr = MapViewOfFile(region._mapHandle, FILE_MAP_ALL_ACCESS, 0, 0, length);
            region._ptr = region._basePtr;
            
            if (region._ptr is null)
            {
                CloseHandle(region._mapHandle);
                if (error) *error = "MapViewOfFile failed for anonymous";
                return null;
            }
        }
        
        region._valid = true;
        _stats.mappingsCreated++;
        _stats.totalBytesMapped += length;
        
        return region;
    }
    
    ~this() @system { unmap(); }
    
    /// Explicitly unmap the region
    void unmap() @system nothrow
    {
        if (!_valid) return;
        
        version(Posix)
        {
            if (_basePtr !is null && _basePtr != MAP_FAILED)
                munmap(_basePtr, _mapLength);
            if (_fd >= 0)
                close(_fd);
            _fd = -1;
        }
        version(Windows)
        {
            if (_basePtr !is null)
                UnmapViewOfFile(_basePtr);
            if (_mapHandle !is null)
                CloseHandle(_mapHandle);
            if (_fileHandle != INVALID_HANDLE_VALUE)
                CloseHandle(_fileHandle);
        }
        
        _ptr = null;
        _basePtr = null;
        _valid = false;
        _stats.mappingsClosed++;
    }
    
    /// Get read-only slice of mapped data
    const(ubyte)[] opSlice() const @system nothrow @nogc
    {
        if (!_valid || _ptr is null) return null;
        _stats.totalBytesRead += _length;
        return (cast(const(ubyte)*)_ptr)[0 .. _length];
    }
    
    /// Get slice with bounds
    const(ubyte)[] opSlice(size_t start, size_t end) const @system nothrow @nogc
    {
        if (!_valid || _ptr is null) return null;
        if (end > _length) end = _length;
        if (start >= end) return null;
        
        immutable len = end - start;
        _stats.totalBytesRead += len;
        return (cast(const(ubyte)*)_ptr)[start .. end];
    }
    
    /// Index access
    ubyte opIndex(size_t idx) const @system nothrow @nogc
    {
        if (!_valid || _ptr is null || idx >= _length) return 0;
        return (cast(const(ubyte)*)_ptr)[idx];
    }
    
    /// Get mutable slice (only for ReadWrite/Private modes)
    ubyte[] mutableSlice() @system nothrow @nogc
    {
        if (!_valid || _ptr is null || _mode == MapMode.ReadOnly) return null;
        return (cast(ubyte*)_ptr)[0 .. _length];
    }
    
    /// Apply kernel advice for access pattern optimization
    void advise(MapAdvice advice) @system nothrow
    {
        version(Posix)
        {
            if (!_valid || _basePtr is null) return;
            
            int madv;
            final switch (advice)
            {
                case MapAdvice.Normal:     madv = MADV_NORMAL; break;
                case MapAdvice.Sequential: madv = MADV_SEQUENTIAL; break;
                case MapAdvice.Random:     madv = MADV_RANDOM; break;
                case MapAdvice.WillNeed:   madv = MADV_WILLNEED; break;
                case MapAdvice.DontNeed:   madv = MADV_DONTNEED; break;
            }
            
            madvise(_basePtr, _mapLength, madv);
        }
        // Windows: no direct equivalent, hints via PrefetchVirtualMemory (Win8+)
    }
    
    /// Synchronize changes to underlying file (for ReadWrite mode)
    bool sync(bool async = false) @system nothrow
    {
        if (!_valid || _basePtr is null || _mode == MapMode.ReadOnly) return false;
        
        version(Posix)
        {
            return msync(_basePtr, _mapLength, async ? MS_ASYNC : MS_SYNC) == 0;
        }
        version(Windows)
        {
            return FlushViewOfFile(_basePtr, _mapLength) != 0;
        }
    }
    
    /// Lock pages in physical memory (prevent swapping)
    bool lock() @system nothrow
    {
        if (!_valid || _basePtr is null) return false;
        
        version(Posix)
        {
            return mlock(_basePtr, _mapLength) == 0;
        }
        version(Windows)
        {
            return VirtualLock(_basePtr, _mapLength) != 0;
        }
    }
    
    /// Unlock pages from physical memory
    bool unlock() @system nothrow
    {
        if (!_valid || _basePtr is null) return false;
        
        version(Posix)
        {
            return munlock(_basePtr, _mapLength) == 0;
        }
        version(Windows)
        {
            return VirtualUnlock(_basePtr, _mapLength) != 0;
        }
    }
    
    /// Check if mapping is valid
    bool valid() const @safe pure nothrow @nogc => _valid;
    
    /// Get mapped length
    size_t length() const @safe pure nothrow @nogc => _valid ? _length : 0;
    
    /// Get raw pointer (use with caution)
    const(void)* ptr() const @system nothrow @nogc => _valid ? _ptr : null;
    
    /// Get mapping mode
    MapMode mode() const @safe pure nothrow @nogc => _mode;
}

/// Get system page size
size_t pageSize() @trusted nothrow @nogc
{
    version(Posix)
    {
        static size_t cached = 0;
        if (cached == 0)
            cached = cast(size_t)sysconf(_SC_PAGESIZE);
        return cached;
    }
    version(Windows)
    {
        static size_t cached = 0;
        if (cached == 0)
        {
            SYSTEM_INFO si;
            GetSystemInfo(&si);
            cached = si.dwPageSize;
        }
        return cached;
    }
}

/// Align size up to page boundary
size_t pageAlign(size_t size) @trusted nothrow @nogc
{
    immutable ps = pageSize();
    return (size + ps - 1) & ~(ps - 1);
}

/// Convert errno to string
private string errnoString() @trusted nothrow
{
    version(Posix)
    {
        import core.stdc.string : strerror;
        auto err = errno;
        auto msg = strerror(err);
        return msg ? fromStringz(msg).idup : "Unknown error " ~ err.to!string;
    }
    else return "Unknown error";
}

version(Posix)
{
    // Additional POSIX declarations
    private extern(C) @nogc nothrow
    {
        void* mmap(void*, size_t, int, int, int, long);
        int munmap(void*, size_t);
        int madvise(void*, size_t, int);
        int msync(void*, size_t, int);
        int mlock(void*, size_t);
        int munlock(void*, size_t);
        
        enum MAP_FAILED = cast(void*)-1;
        enum MAP_SHARED = 0x01;
        enum MAP_PRIVATE = 0x02;
        enum MAP_ANONYMOUS = 0x20;
        
        enum PROT_READ = 0x1;
        enum PROT_WRITE = 0x2;
        
        enum MADV_NORMAL = 0;
        enum MADV_RANDOM = 1;
        enum MADV_SEQUENTIAL = 2;
        enum MADV_WILLNEED = 3;
        enum MADV_DONTNEED = 4;
        
        enum MS_ASYNC = 1;
        enum MS_SYNC = 4;
    }
}

version(Windows)
{
    private extern(Windows) @nogc nothrow
    {
        HANDLE CreateFileMappingA(HANDLE, void*, DWORD, DWORD, DWORD, const(char)*);
        void* MapViewOfFile(HANDLE, DWORD, DWORD, DWORD, size_t);
        BOOL UnmapViewOfFile(const(void)*);
        BOOL FlushViewOfFile(const(void)*, size_t);
        BOOL VirtualLock(void*, size_t);
        BOOL VirtualUnlock(void*, size_t);
        void GetSystemInfo(SYSTEM_INFO*);
        
        enum FILE_MAP_READ = 0x0004;
        enum FILE_MAP_WRITE = 0x0002;
        enum FILE_MAP_COPY = 0x0001;
        enum FILE_MAP_ALL_ACCESS = 0xF001F;
        enum PAGE_READONLY = 0x02;
        enum PAGE_READWRITE = 0x04;
        enum PAGE_WRITECOPY = 0x08;
        
        struct SYSTEM_INFO
        {
            DWORD dwOemId;
            DWORD dwPageSize;
            void* lpMinimumApplicationAddress;
            void* lpMaximumApplicationAddress;
            size_t dwActiveProcessorMask;
            DWORD dwNumberOfProcessors;
            DWORD dwProcessorType;
            DWORD dwAllocationGranularity;
            WORD wProcessorLevel;
            WORD wProcessorRevision;
        }
    }
}

unittest
{
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    
    // Create test file
    immutable testPath = buildPath(tempDir(), "mmap_test.bin");
    scope(exit) if (exists(testPath)) remove(testPath);
    
    ubyte[4096] testData;
    foreach (i, ref b; testData)
        b = cast(ubyte)(i & 0xFF);
    
    write(testPath, testData);
    
    // Test read-only mapping
    auto region = MmapRegion.map(testPath, MapMode.ReadOnly);
    assert(region !is null, "Failed to map file");
    scope(exit) region.unmap();
    
    assert(region.valid);
    assert(region.length == 4096);
    
    auto data = region[];
    assert(data.length == 4096);
    assert(data[0] == 0);
    assert(data[255] == 255);
    assert(data[256] == 0);
}

unittest
{
    // Test anonymous mapping
    auto region = MmapRegion.anonymous(4096);
    assert(region !is null);
    scope(exit) region.unmap();
    
    assert(region.valid);
    assert(region.length == 4096);
    
    // Write to anonymous memory
    auto slice = region.mutableSlice();
    assert(slice !is null);
    slice[0] = 42;
    assert(region[0] == 42);
}

unittest
{
    // Test page size
    auto ps = pageSize();
    assert(ps > 0);
    assert(ps == 4096 || ps == 16384 || ps == 65536);  // Common sizes
    
    // Test alignment
    assert(pageAlign(1) == ps);
    assert(pageAlign(ps) == ps);
    assert(pageAlign(ps + 1) == ps * 2);
}
