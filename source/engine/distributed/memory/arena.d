module engine.distributed.memory.arena;

import core.memory : GC;
import std.algorithm : max;
import infrastructure.errors : Errors, Internal;

/// Memory arena for fast batch allocations
/// Reduces GC pressure and improves cache locality
/// 
/// Design:
/// - Bump-pointer allocation (extremely fast)
/// - Batch deallocation (all at once)
/// - No individual free operations
/// - Cache-friendly contiguous memory
/// 
/// Use Cases:
/// - Temporary allocations during action execution
/// - Message serialization buffers
/// - Batch processing of actions
/// 
/// Performance:
/// - O(1) allocation (just bump pointer)
/// - Zero fragmentation
/// - Excellent cache locality
/// - Minimal GC pressure
struct Arena
{
    private ubyte[] buffer;
    private size_t offset;
    private size_t capacity;
    private bool ownsMemory;
    
    @disable this(this);  // Non-copyable
    
    /// Create arena with specified capacity
    this(size_t capacity) @trusted
    {
        this.capacity = capacity;
        this.buffer = new ubyte[capacity];
        this.offset = 0;
        this.ownsMemory = true;
        
        // Prevent GC from scanning this memory (performance)
        GC.setAttr(buffer.ptr, GC.BlkAttr.NO_SCAN);
    }
    
    /// Create arena with pre-allocated buffer
    this(ubyte[] buffer) @trusted
    {
        this.buffer = buffer;
        this.capacity = buffer.length;
        this.offset = 0;
        this.ownsMemory = false;
    }
    
    /// Allocate bytes from arena
    /// Returns slice into arena memory
    /// Throws on out-of-memory
    ubyte[] allocate(size_t size, size_t alignment = size_t.sizeof) @trusted
    {
        immutable alignedOffset = alignUp(offset, alignment);
        immutable newOffset = alignedOffset + size;
        
        if (newOffset > capacity)
            throw Errors.internal("Arena out of memory: " ~ newOffset.to!string ~ " > " ~ capacity.to!string, Internal.Error).build();
        
        offset = newOffset;
        return buffer[alignedOffset .. newOffset];
    }
    
    /// Allocate and construct value
    T* make(T, Args...)(auto ref Args args) @trusted
    {
        import std.conv : emplace;
        
        // Allocate aligned memory for T
        auto mem = allocate(T.sizeof, T.alignof);
        
        // Construct T in place
        auto ptr = cast(T*)mem.ptr;
        emplace(ptr, args);
        
        return ptr;
    }
    
    /// Allocate array of T
    T[] makeArray(T)(size_t count) @trusted
    {
        immutable size = T.sizeof * count;
        auto mem = allocate(size, T.alignof);
        
        return cast(T[])mem;
    }
    
    void reset() @safe nothrow @nogc { offset = 0; }
    size_t used() const pure @safe nothrow @nogc => offset;
    size_t available() const pure @safe nothrow @nogc => capacity - offset;
    size_t totalCapacity() const pure @safe nothrow @nogc => capacity;
    
    /// Check if arena has space for allocation
    bool canAllocate(size_t size, size_t alignment = size_t.sizeof) const pure @safe nothrow @nogc =>
        alignUp(offset, alignment) + size <= capacity;
    
    private:
    
    /// Align value up to alignment boundary
    static size_t alignUp(size_t value, size_t alignment) pure @safe nothrow @nogc =>
        (value + alignment - 1) & ~(alignment - 1);
}

/// Thread-safe arena pool
/// Maintains pool of arenas for reuse
final class ArenaPool
{
    private Arena*[] available;
    private size_t arenaSize;
    private size_t maxArenas;
    private size_t totalAllocated;
    
    import core.sync.mutex : Mutex;
    private Mutex mutex;
    
    /// Create arena pool
    this(size_t arenaSize = 64 * 1024, size_t maxArenas = 32) @trusted
    {
        this.arenaSize = arenaSize;
        this.maxArenas = maxArenas;
        this.mutex = new Mutex();
    }
    
    /// Acquire arena from pool
    Arena* acquire() @trusted
    {
        synchronized (mutex)
        {
            if (available.length > 0)
            {
                auto arena = available[$ - 1];
                available = available[0 .. $ - 1];
                arena.reset();
                return arena;
            }
        }
        
        // Allocate new arena
        auto arena = new Arena(arenaSize);
        totalAllocated++;
        
        return arena;
    }
    
    /// Release arena back to pool
    void release(Arena* arena) @trusted
    {
        if (arena is null) return;
        arena.reset();
        
        synchronized (mutex)
        {
            if (available.length < maxArenas)
                available ~= arena;
            // else: let it be GC'd
        }
    }
    
    /// Get pool statistics
    struct PoolStats
    {
        size_t available;
        size_t totalAllocated;
        size_t arenaSize;
        size_t maxArenas;
    }
    
    PoolStats getStats() @trusted
    {
        synchronized (mutex)
        {
            return PoolStats(
                available.length,
                totalAllocated,
                arenaSize,
                maxArenas
            );
        }
    }
}

/// RAII wrapper for arena from pool
struct ScopedArena
{
    private Arena* arena;
    private ArenaPool pool;
    
    @disable this(this);  // Non-copyable
    
    this(ArenaPool pool) @trusted
    {
        this.pool = pool;
        this.arena = pool.acquire();
    }
    
    ~this() @trusted
    {
        if (pool !is null && arena !is null)
            pool.release(arena);
    }
    
    /// Get underlying arena
    Arena* get() @safe nothrow @nogc => arena;
    
    /// Convenience: forward to arena
    alias get this;
}

// Import at the end to avoid circular dependency with tests
import std.conv : to;

