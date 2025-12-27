module engine.distributed.memory.buffer;

import core.sync.mutex : Mutex;
import core.atomic;
import std.algorithm : max, min;

/// Ring buffer for bounded queues
/// Lock-free single-producer single-consumer
/// 
/// Performance:
/// - Cache line padding prevents false sharing between reader/writer positions
/// 
/// Use Cases:
/// - Message queues between threads
/// - Bounded action buffers
/// - Streaming data processing
struct RingBuffer(T)
{
    private T[] buffer;
    private shared size_t readPos;
    private ubyte[64] _padRead; // Cache line padding to prevent false sharing
    private shared size_t writePos;
    private immutable size_t capacity;
    private immutable size_t mask;
    
    @disable this(this);  // Non-copyable
    
    /// Create ring buffer (capacity must be power of 2)
    this(size_t capacity) @trusted
    {
        import std.math : isPowerOf2;
        assert(isPowerOf2(capacity), "Capacity must be power of 2");
        
        this.capacity = capacity;
        this.mask = capacity - 1;
        this.buffer.length = capacity;
        atomicStore(readPos, cast(size_t)0);
        atomicStore(writePos, cast(size_t)0);
    }
    
    /// Push item (producer side)
    bool push(T item) @trusted nothrow @nogc
    {
        immutable write = atomicLoad!(MemoryOrder.raw)(writePos);
        immutable next = (write + 1) & mask;
        
        if (next == (atomicLoad!(MemoryOrder.acq)(readPos) & mask)) return false;  // Full
        
        buffer[write & mask] = item;
        atomicStore!(MemoryOrder.rel)(writePos, write + 1);
        return true;
    }
    
    /// Pop item (consumer side)
    bool pop(ref T item) @trusted nothrow @nogc
    {
        immutable read = atomicLoad!(MemoryOrder.raw)(readPos);
        if (read == atomicLoad!(MemoryOrder.acq)(writePos)) return false;  // Empty
        
        item = buffer[read & mask];
        atomicStore!(MemoryOrder.rel)(readPos, read + 1);
        return true;
    }
    
    /// Check if empty
    bool empty() @trusted const nothrow @nogc => atomicLoad(readPos) == atomicLoad(writePos);
    
    /// Check if full
    bool full() @trusted const nothrow @nogc
    {
        immutable write = atomicLoad(writePos);
        return ((write + 1) & mask) == (atomicLoad(readPos) & mask);
    }
    
    /// Get approximate size
    size_t size() @trusted const nothrow @nogc => (atomicLoad(writePos) - atomicLoad(readPos)) & mask;
}

/// Growable byte buffer with efficient resizing
/// For building serialized messages
struct ByteBuffer
{
    private ubyte[] data;
    private size_t pos;
    private size_t cap;
    
    /// Create buffer with initial capacity
    this(size_t initialCapacity) @trusted
    {
        this.cap = initialCapacity;
        this.data = new ubyte[initialCapacity];
        this.pos = 0;
    }
    
    /// Create buffer with default capacity (4096 bytes)
    static ByteBuffer create() @trusted
    {
        return ByteBuffer(4096);
    }
    
    /// Write bytes
    void write(const ubyte[] bytes) @trusted
    {
        ensureCapacity(bytes.length);
        data[pos .. pos + bytes.length] = bytes;
        pos += bytes.length;
    }
    
    /// Write single byte
    void writeByte(ubyte b) @trusted nothrow
    {
        ensureCapacity(1);
        data[pos++] = b;
    }
    
    /// Write integer (little-endian)
    void writeInt(T)(T value) @trusted nothrow
        if (is(T == int) || is(T == uint) || is(T == long) || is(T == ulong))
    {
        ensureCapacity(T.sizeof);
        *cast(T*)&data[pos] = value;
        pos += T.sizeof;
    }
    
    const(ubyte)[] get() const @safe nothrow @nogc => data[0 .. pos];
    void reset() @safe nothrow @nogc { pos = 0; }
    size_t position() const @safe nothrow @nogc pure => pos;
    size_t capacity() const @safe nothrow @nogc pure => cap;
    
    private:
    
    void ensureCapacity(size_t additional) @trusted nothrow
    {
        immutable needed = pos + additional;
        if (needed <= cap)
            return;
        
        // Grow by 1.5x or exact need, whichever is larger
        immutable newCap = max(needed, cap + cap / 2);
        
        auto newData = new ubyte[newCap];
        newData[0 .. pos] = data[0 .. pos];
        data = newData;
        cap = newCap;
    }
}

/// Slab allocator for fixed-size objects
/// Extremely fast allocation/deallocation
/// 
/// Use Cases:
/// - Message nodes
/// - Small fixed-size structures
/// - High-frequency allocations
struct SlabAllocator(T, size_t SLAB_SIZE = 256)
{
    private struct Slab
    {
        T[SLAB_SIZE] items;
        bool[SLAB_SIZE] used;
        size_t freeCount;
        Slab* next;
    }
    
    private Slab* head;
    private Mutex mutex;
    private size_t totalSlabs;
    
    @disable this(this);  // Non-copyable
    
    /// Initialize allocator
    void initialize() @trusted
    {
        mutex = new Mutex();
        head = allocateSlab();
    }
    
    /// Allocate object
    T* allocate() @trusted
    {
        synchronized (mutex)
        {
            Slab* slab = head;
            
            // Find slab with free slot
            while (slab !is null)
            {
                if (slab.freeCount > 0)
                {
                    // Find free slot
                    foreach (i; 0 .. SLAB_SIZE)
                    {
                        if (!slab.used[i])
                        {
                            slab.used[i] = true;
                            slab.freeCount--;
                            return &slab.items[i];
                        }
                    }
                }
                slab = slab.next;
            }
            
            // No free slots, allocate new slab
            auto newSlab = allocateSlab();
            newSlab.next = head;
            head = newSlab;
            
            newSlab.used[0] = true;
            newSlab.freeCount--;
            return &newSlab.items[0];
        }
    }
    
    /// Deallocate object
    void deallocate(T* ptr) @trusted
    {
        if (ptr is null) return;
        
        synchronized (mutex)
        {
            Slab* slab = head;
            
            // Find which slab owns this pointer
            while (slab !is null)
            {
                auto slabStart = cast(void*)&slab.items[0];
                auto slabEnd = cast(void*)&slab.items[SLAB_SIZE];
                auto ptrAddr = cast(void*)ptr;
                
                if (ptrAddr >= slabStart && ptrAddr < slabEnd)
                {
                    // Calculate index
                    immutable offset = cast(size_t)(ptrAddr - slabStart);
                    immutable index = offset / T.sizeof;
                    
                    if (slab.used[index])
                    {
                        slab.used[index] = false;
                        slab.freeCount++;
                    }
                    return;
                }
                
                slab = slab.next;
            }
        }
    }
    
    private:
    
    Slab* allocateSlab() @trusted
    {
        auto slab = new Slab();
        slab.freeCount = SLAB_SIZE;
        totalSlabs++;
        return slab;
    }
}
