module engine.distributed.memory.local;

import core.memory : GC;
import core.atomic;
import std.algorithm : max, min;
import engine.distributed.memory.arena : Arena;

/// Thread-local arena - zero synchronization for per-thread allocations
/// Each worker thread gets exclusive ownership of its arena
/// 
/// Performance:
/// - No mutex contention (100% thread-local)
/// - O(1) allocation (bump pointer)
/// - Batch reset between work units
/// 
/// Design:
/// - Static thread-local storage for arena pointer
/// - Lazy initialization on first access
/// - Explicit reset() between logical work units
struct ThreadLocalArena
{
    private static Arena* tls;  // Thread-local storage
    private static shared size_t _totalAllocations;
    private static shared size_t _totalResets;
    
    enum DEFAULT_SIZE = 64 * 1024;  // 64KB default
    
    /// Get or create thread-local arena
    static Arena* get(size_t capacity = DEFAULT_SIZE) @trusted nothrow
    {
        if (tls is null)
        {
            try tls = new Arena(capacity);
            catch (Exception) return null;
        }
        return tls;
    }
    
    /// Allocate from thread-local arena
    static ubyte[] allocate(size_t size, size_t alignment = size_t.sizeof) @trusted
    {
        auto arena = get();
        if (arena is null)
            throw new Exception("Failed to initialize thread-local arena");
        
        atomicOp!"+="(_totalAllocations, 1);
        return arena.allocate(size, alignment);
    }
    
    /// Make typed value in thread-local arena
    static T* make(T, Args...)(auto ref Args args) @trusted
    {
        auto arena = get();
        if (arena is null) return null;
        atomicOp!"+="(_totalAllocations, 1);
        return arena.make!T(args);
    }
    
    /// Make array in thread-local arena
    static T[] makeArray(T)(size_t count) @trusted
    {
        auto arena = get();
        if (arena is null) return null;
        atomicOp!"+="(_totalAllocations, 1);
        return arena.makeArray!T(count);
    }
    
    /// Reset thread-local arena (call between work units)
    static void reset() @safe nothrow @nogc
    {
        if (tls !is null)
        {
            tls.reset();
            atomicOp!"+="(_totalResets, 1);
        }
    }
    
    /// Check if arena has capacity
    static bool canAllocate(size_t size) @safe nothrow @nogc =>
        tls !is null && tls.canAllocate(size);
    
    /// Get usage stats
    static size_t used() @safe nothrow @nogc => tls !is null ? tls.used() : 0;
    static size_t available() @safe nothrow @nogc => tls !is null ? tls.available() : 0;
    
    /// Global statistics (atomic reads)
    struct Stats
    {
        size_t totalAllocations;
        size_t totalResets;
    }
    
    static Stats stats() @trusted nothrow @nogc =>
        Stats(atomicLoad(_totalAllocations), atomicLoad(_totalResets));
}

/// Thread-local object pool - zero synchronization
/// Each thread maintains its own free list
template ThreadLocalPool(T)
{
    struct ThreadLocalPool
    {
        private static T[] available;  // Thread-local free list
        private static size_t maxSize = 64;
        private static shared size_t _totalCreated;
        private static shared size_t _totalReused;
        
        /// Configure max pool size (call before first use)
        static void configure(size_t max) @safe nothrow @nogc { maxSize = max; }
        
        /// Acquire object (creates new if pool empty)
        static T acquire() @trusted
        {
            if (available.length > 0)
            {
                auto obj = available[$ - 1];
                available = available[0 .. $ - 1];
                atomicOp!"+="(_totalReused, 1);
                return obj;
            }
            
            atomicOp!"+="(_totalCreated, 1);
            static if (is(T == class)) return new T();
            else return new T;
        }
        
        /// Release object back to pool
        static void release(T obj) @trusted nothrow
        {
            if (obj is null) return;
            
            static if (__traits(hasMember, T, "reset"))
            {
                try obj.reset();
                catch (Exception) {}
            }
            
            if (available.length < maxSize)
                available ~= obj;
        }
        
        /// Clear thread-local pool
        static void clear() @safe nothrow @nogc { available = null; }
        
        /// Statistics
        struct Stats
        {
            size_t pooled;
            size_t totalCreated;
            size_t totalReused;
            float reuseRatio;
        }
        
        static Stats stats() @trusted nothrow @nogc
        {
            immutable created = atomicLoad(_totalCreated);
            immutable reused = atomicLoad(_totalReused);
            return Stats(
                available.length,
                created,
                reused,
                created > 0 ? cast(float)reused / (created + reused) : 0.0f
            );
        }
    }
}

/// Thread-local buffer pool for network I/O
/// Zero synchronization byte buffer management
struct ThreadLocalBufferPool
{
    private static ubyte[][] available;  // Thread-local
    private static size_t bufferSize = 64 * 1024;
    private static size_t maxBuffers = 32;
    private static shared size_t _totalCreated;
    private static shared size_t _totalReused;
    
    /// Configure pool (call before first use)
    static void configure(size_t size, size_t max) @safe nothrow @nogc
    {
        bufferSize = size;
        maxBuffers = max;
    }
    
    /// Acquire buffer
    static ubyte[] acquire() @trusted
    {
        if (available.length > 0)
        {
            auto buf = available[$ - 1];
            available = available[0 .. $ - 1];
            atomicOp!"+="(_totalReused, 1);
            return buf;
        }
        
        atomicOp!"+="(_totalCreated, 1);
        return new ubyte[bufferSize];
    }
    
    /// Acquire buffer of specific size (falls back to allocation if size mismatch)
    static ubyte[] acquire(size_t size) @trusted
    {
        if (size == bufferSize) return acquire();
        return new ubyte[size];
    }
    
    /// Release buffer back to pool
    static void release(ubyte[] buf) @trusted nothrow
    {
        if (buf is null || buf.length != bufferSize) return;
        
        buf[] = 0;  // Security: zero before reuse
        
        if (available.length < maxBuffers)
            available ~= buf;
    }
    
    /// Preallocate buffers
    static void preallocate(size_t count) @trusted
    {
        count = min(count, maxBuffers);
        while (available.length < count)
        {
            available ~= new ubyte[bufferSize];
            atomicOp!"+="(_totalCreated, 1);
        }
    }
    
    /// Clear thread-local pool
    static void clear() @safe nothrow @nogc { available = null; }
    
    /// Statistics
    struct Stats
    {
        size_t pooled;
        size_t totalCreated;
        size_t totalReused;
        size_t bufferSize;
        size_t memoryBytes;
    }
    
    static Stats stats() @trusted nothrow @nogc
    {
        immutable created = atomicLoad(_totalCreated);
        return Stats(
            available.length,
            created,
            atomicLoad(_totalReused),
            bufferSize,
            available.length * bufferSize
        );
    }
}

/// Scoped thread-local arena usage
/// Automatically resets arena at scope exit
struct ScopedLocalArena
{
    private size_t startOffset;
    
    @disable this(this);
    
    this(size_t capacity) @trusted
    {
        auto arena = ThreadLocalArena.get(capacity);
        startOffset = arena !is null ? arena.used() : 0;
    }
    
    ~this() @trusted
    {
        // Reset to start offset (partial reset for nested scopes)
        if (auto arena = ThreadLocalArena.get())
        {
            if (arena.used() > startOffset)
                arena.reset();  // Full reset (bump allocator limitation)
        }
    }
    
    /// Allocate from scoped arena
    ubyte[] allocate(size_t size) @trusted => ThreadLocalArena.allocate(size);
    
    /// Make typed value
    T* make(T, Args...)(auto ref Args args) @trusted => ThreadLocalArena.make!T(args);
}

/// RAII guard for thread-local pool object
struct LocalPooled(T)
{
    private T obj;
    
    @disable this(this);
    
    this(int) @trusted { obj = ThreadLocalPool!T.acquire(); }
    
    ~this() @trusted nothrow
    {
        if (obj !is null)
            ThreadLocalPool!T.release(obj);
    }
    
    T get() @safe nothrow @nogc => obj;
    alias get this;
}

/// Convenience: create pooled object
LocalPooled!T localPooled(T)() @trusted => LocalPooled!T(0);

/// RAII guard for thread-local buffer
struct LocalBuffer
{
    private ubyte[] buf;
    
    @disable this(this);
    
    this(size_t size) @trusted
    {
        buf = size == ThreadLocalBufferPool.bufferSize
            ? ThreadLocalBufferPool.acquire()
            : ThreadLocalBufferPool.acquire(size);
    }
    
    ~this() @trusted nothrow { ThreadLocalBufferPool.release(buf); }
    
    ubyte[] get() @safe nothrow @nogc => buf;
    inout(ubyte)[] opSlice() inout @safe nothrow @nogc => buf;
    ref ubyte opIndex(size_t i) @safe nothrow @nogc => buf[i];
}

/// Combined statistics for all thread-local pools
struct LocalMemoryStats
{
    ThreadLocalArena.Stats arena;
    ThreadLocalBufferPool.Stats buffers;
    
    static LocalMemoryStats collect() @trusted nothrow @nogc =>
        LocalMemoryStats(ThreadLocalArena.stats(), ThreadLocalBufferPool.stats());
}

/// Reset all thread-local memory (call at worker idle/shutdown)
void resetThreadLocalMemory() @safe nothrow @nogc
{
    ThreadLocalArena.reset();
    ThreadLocalBufferPool.clear();
}

