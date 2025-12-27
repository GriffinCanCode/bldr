module infrastructure.utils.concurrency.lockfree;

import core.atomic;
import core.sync.mutex;
import std.algorithm;
import std.range;


/// Lock-free SPMC (Single Producer Multiple Consumer) queue using atomic operations
/// Optimized for the build executor's ready queue pattern
/// 
/// Thread Safety:
/// - Single producer (main scheduling thread) enqueues ready nodes
/// - Multiple consumers (worker threads) dequeue and process nodes
/// - All operations are lock-free using atomic compare-and-swap
/// 
/// Performance:
/// - Zero allocation after initialization
/// - No mutex contention between workers
/// - Cache-friendly circular buffer design
struct LockFreeQueue(T) if (is(T == class))
{
    private struct Node
    {
        shared T item;
        shared size_t sequence;
    }
    
    private Node[] buffer;
    private shared size_t enqueuePos;
    private shared size_t dequeuePos;
    private immutable size_t mask;
    
    @disable this(this); // Non-copyable
    
    /// Constructor: Initialize queue with power-of-2 capacity
    /// 
    /// Safety: This constructor is @system because:
    /// 1. Buffer allocation is safe (GC-managed array)
    /// 2. atomicStore() for position initialization
    /// 3. Power-of-2 enforcement for efficient modulo via mask
    /// 
    /// Invariants:
    /// - Capacity must be power of 2 (enforced by assertion)
    /// - Buffer is fully initialized before use
    /// - Positions start at 0
    @system
    this(size_t capacity)
    {
        import std.math : isPowerOf2;
        assert(isPowerOf2(capacity), "Capacity must be power of 2");
        
        buffer.length = capacity;
        mask = capacity - 1;
        
        // Initialize sequences
        foreach (i; 0 .. capacity)
            atomicStore(buffer[i].sequence, i);
        
        atomicStore(enqueuePos, cast(size_t)0);
        atomicStore(dequeuePos, cast(size_t)0);
    }
    
    /// Enqueue an item (producer side)
    /// Returns true if successful, false if queue is full
    /// 
    /// Safety: This function is @system because:
    /// 1. atomicLoad/Store/Cas operations ensure thread-safe access
    /// 2. Mask operation keeps index within bounds
    /// 3. Sequence checking prevents ABA problems
    /// 4. Compare-and-swap prevents race conditions
    /// 
    /// Invariants:
    /// - pos & mask is always < buffer.length
    /// - Sequence numbers prevent slot reuse conflicts
    /// - CAS ensures only one thread updates position
    @system
    bool enqueue(T item)
    {
        size_t pos;
        Node* node;
        size_t seq;
        
        while (true)
        {
            pos = atomicLoad(enqueuePos);
            node = &buffer[pos & mask];
            seq = atomicLoad(node.sequence);
            
            immutable diff = cast(ptrdiff_t)(seq - pos);
            
            if (diff == 0)
            {
                // Slot is available, try to claim it
                if (cas(&enqueuePos, pos, pos + 1))
                {
                    atomicStore(node.item, cast(shared)item);
                    atomicStore(node.sequence, pos + 1);
                    return true;
                }
            }
            else if (diff < 0)
            {
                // Queue is full
                return false;
            }
            // else: another thread got this slot, retry
        }
    }
    
    /// Dequeue an item (consumer side)
    /// Returns the item if successful, null if queue is empty
    /// 
    /// Safety: This function is @system because:
    /// 1. atomicLoad/Store/Cas operations ensure thread-safe access
    /// 2. Mask operation keeps index within bounds
    /// 3. Sequence checking prevents ABA problems
    /// 4. Cast from shared is safe after successful dequeue
    /// 
    /// Invariants:
    /// - pos & mask is always < buffer.length
    /// - Sequence numbers prevent reading before write completes
    /// - CAS ensures only one consumer gets each item
    @system
    T tryDequeue()
    {
        size_t pos;
        Node* node;
        size_t seq;
        
        while (true)
        {
            pos = atomicLoad(dequeuePos);
            node = &buffer[pos & mask];
            seq = atomicLoad(node.sequence);
            
            immutable diff = cast(ptrdiff_t)(seq - (pos + 1));
            
            if (diff == 0)
            {
                // Item is available, try to claim it
                if (cas(&dequeuePos, pos, pos + 1))
                {
                    auto item = cast(T)atomicLoad(node.item);
                    atomicStore(node.sequence, pos + mask + 1);
                    return item;
                }
            }
            else if (diff < 0)
            {
                // Queue is empty
                return null;
            }
            // else: item not ready yet, retry
        }
    }
    
    /// Batch dequeue: claim range with single CAS, reducing atomic overhead
    /// Returns actual count dequeued (may be less than maxCount if queue has fewer items)
    /// 
    /// Performance:
    /// - Single CAS to claim entire range vs N CAS for N items
    /// - Reduces cache line contention between consumers
    /// - Amortizes atomic overhead over batch size
    /// 
    /// Safety: This function is @system because:
    /// 1. Single CAS claims contiguous range atomically
    /// 2. Sequence checks ensure items are ready before reading
    /// 3. Handles partial batches when queue becomes empty
    /// 
    /// Invariants:
    /// - Claimed range is exclusive to this consumer
    /// - All sequence updates happen after reads complete
    @system
    size_t tryDequeueBatch(size_t maxCount, ref T[] results)
    {
        if (maxCount == 0) return 0;
        
        // Pre-allocate or ensure capacity
        if (results.length < maxCount)
            results.length = maxCount;
        
        size_t startPos, endPos, claimed;
        
        // Claim range with single CAS
        while (true)
        {
            startPos = atomicLoad(dequeuePos);
            immutable enqPos = atomicLoad(enqueuePos);
            immutable available = enqPos - startPos;
            
            if (available == 0) return 0;  // Empty
            
            claimed = available < maxCount ? available : maxCount;
            endPos = startPos + claimed;
            
            if (cas(&dequeuePos, startPos, endPos))
                break;
            // CAS failed, retry
        }
        
        // Read items from claimed range
        size_t count = 0;
        foreach (i; 0 .. claimed)
        {
            immutable pos = startPos + i;
            auto node = &buffer[pos & mask];
            
            // Spin until item is ready (producer has written)
            while (true)
            {
                immutable seq = atomicLoad(node.sequence);
                if (cast(ptrdiff_t)(seq - (pos + 1)) >= 0)
                    break;
                // Item not ready yet, spin (rare in practice)
            }
            
            results[count++] = cast(T)atomicLoad(node.item);
            atomicStore(node.sequence, pos + mask + 1);
        }
        
        return count;
    }
    
    /// Batch enqueue: insert multiple items with minimal atomic overhead
    /// Returns actual count enqueued (may be less than items.length if queue fills)
    /// 
    /// Performance:
    /// - Single CAS to claim producer range
    /// - Efficient for bulk insertions
    /// 
    /// Safety: This function is @system because:
    /// 1. Producer-only operation (SPMC pattern)
    /// 2. CAS claims exclusive range for writes
    @system
    size_t enqueueBatch(T[] items)
    {
        if (items.length == 0) return 0;
        
        size_t startPos, endPos, claimed;
        immutable bufCap = mask + 1;
        
        // Claim range with single CAS
        while (true)
        {
            startPos = atomicLoad(enqueuePos);
            immutable deqPos = atomicLoad(dequeuePos);
            immutable used = startPos - deqPos;
            immutable available = bufCap - used;
            
            if (available == 0) return 0;  // Full
            
            claimed = available < items.length ? available : items.length;
            endPos = startPos + claimed;
            
            if (cas(&enqueuePos, startPos, endPos))
                break;
        }
        
        // Write items to claimed range
        foreach (i; 0 .. claimed)
        {
            immutable pos = startPos + i;
            auto node = &buffer[pos & mask];
            
            // Wait for slot to be ready (consumer has freed)
            while (true)
            {
                immutable seq = atomicLoad(node.sequence);
                if (cast(ptrdiff_t)(seq - pos) >= 0)
                    break;
            }
            
            atomicStore(node.item, cast(shared)items[i]);
            atomicStore(node.sequence, pos + 1);
        }
        
        return claimed;
    }
    
    /// Check if queue is empty (approximate - may be stale immediately)
    @system
    bool empty() const
    {
        immutable enq = atomicLoad(enqueuePos);
        immutable deq = atomicLoad(dequeuePos);
        return enq == deq;
    }
    
    /// Get approximate size (may be stale immediately)
    @system
    size_t length() const
    {
        immutable enq = atomicLoad(enqueuePos);
        immutable deq = atomicLoad(dequeuePos);
        return enq - deq;
    }
    
    /// Get queue capacity
    @system
    size_t capacity() const pure nothrow @nogc => mask + 1;
}

/// Hash cache for per-build-session memoization
/// Thread-safe for concurrent reads and writes
/// Optimized for the pattern: compute once, read many times
struct FastHashCache
{
    private struct CacheEntry
    {
        shared string contentHash;
        shared string metadataHash;
        shared bool valid;
    }
    
    private CacheEntry[string] cache;
    private shared size_t hits;
    private shared size_t misses;
    private Mutex cacheMutex;  // Protects cache AA access
    
    @disable this(this); // Non-copyable
    
    /// Explicitly initialize the cache (must be called before use)
    @system
    void initialize()
    {
        cacheMutex = new Mutex();
    }
    
    /// Get cached hash if available
    /// Returns tuple: (found, contentHash, metadataHash)
    /// 
    /// Safety: This function is @system because:
    /// 1. Associative array lookup is bounds-checked
    /// 2. atomicLoad ensures thread-safe read of shared data
    /// 3. String casts are safe (strings are immutable)
    /// 4. Synchronized access to AA via mutex
    @system
    auto get(string path)
    {
        struct Result
        {
            bool found;
            string contentHash;
            string metadataHash;
        }
        
        assert(cacheMutex !is null, "FastHashCache not initialized - call initialize() first");
        
        synchronized (cacheMutex)
        {
            if (auto entry = path in cache)
            {
                if (atomicLoad(entry.valid))
                {
                    atomicOp!"+="(hits, 1);
                    return Result(
                        true,
                        cast(string)atomicLoad(entry.contentHash),
                        cast(string)atomicLoad(entry.metadataHash)
                    );
                }
            }
        }
        
        atomicOp!"+="(misses, 1);
        return Result(false, "", "");
    }
    
    /// Store hash in cache
    /// 
    /// Safety: This function is @system because:
    /// 1. Associative array insert is memory-safe when synchronized
    /// 2. atomicStore ensures thread-safe write to entry fields
    /// 3. String to shared string cast is safe (immutable data)
    /// 4. Mutex protects concurrent AA modifications
    @system
    void put(string path, string contentHash, string metadataHash)
    {
        if (cacheMutex is null)
        {
            import std.stdio : stderr;
            stderr.writeln("ERROR: FastHashCache.put called with null mutex!");
            return; // Fail gracefully instead of crashing
        }
        
        try
        {
            synchronized (cacheMutex)
            {
                CacheEntry entry;
                entry.contentHash = cast(shared)contentHash;
                entry.metadataHash = cast(shared)metadataHash;
                entry.valid = cast(shared)true;
                cache[path] = entry;
            }
        }
        catch (Exception e)
        {
            import std.stdio : stderr;
            stderr.writeln("ERROR in FastHashCache.put: ", e.msg);
        }
    }
    
    /// Check if cache entry exists and is valid
    @system
    bool isValid(string path) const
    {
        assert(cacheMutex !is null, "FastHashCache not initialized - call initialize() first");
        
        synchronized (cast(Mutex)cacheMutex)
        {
            if (auto entry = path in cache)
                return atomicLoad(entry.valid);
        }
        return false;
    }
    
    /// Clear the cache (typically at build end)
    @system
    void clear()
    {
        assert(cacheMutex !is null, "FastHashCache not initialized - call initialize() first");
        
        synchronized (cacheMutex)
        {
            cache.clear();
        }
        atomicStore(hits, cast(size_t)0);
        atomicStore(misses, cast(size_t)0);
    }
    
    /// Get cache statistics
    @system
    auto getStats() const
    {
        struct Stats
        {
            size_t hits;
            size_t misses;
            size_t entries;
            float hitRate;
        }
        
        Stats stats;
        stats.hits = atomicLoad(hits);
        stats.misses = atomicLoad(misses);
        stats.entries = cache.length;
        
        immutable total = stats.hits + stats.misses;
        if (total > 0)
            stats.hitRate = (stats.hits * 100.0) / total;
        
        return stats;
    }
}

// ==================== UNIT TESTS ====================

/// Test basic batch dequeue operations
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.lockfree - Batch dequeue basic");
    
    class Task { int id; this(int i) { id = i; } }
    
    auto queue = LockFreeQueue!Task(16);
    
    // Enqueue 10 items
    foreach (i; 0 .. 10)
        assert(queue.enqueue(new Task(i)));
    
    assert(queue.length == 10);
    
    // Batch dequeue 5
    Task[] batch;
    immutable count = queue.tryDequeueBatch(5, batch);
    
    assert(count == 5);
    assert(batch.length >= 5);
    foreach (i; 0 .. 5)
        assert(batch[i].id == i);
    
    assert(queue.length == 5);
    
    writeln("\x1b[32m  ✓ Batch dequeue basic\x1b[0m");
}

/// Test batch dequeue partial (fewer items than requested)
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.lockfree - Batch dequeue partial");
    
    class Task { int id; this(int i) { id = i; } }
    
    auto queue = LockFreeQueue!Task(16);
    
    // Enqueue 3 items
    foreach (i; 0 .. 3)
        queue.enqueue(new Task(i));
    
    // Request 10, should get 3
    Task[] batch;
    immutable count = queue.tryDequeueBatch(10, batch);
    
    assert(count == 3);
    assert(queue.empty);
    
    writeln("\x1b[32m  ✓ Batch dequeue partial\x1b[0m");
}

/// Test batch enqueue operations
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.lockfree - Batch enqueue");
    
    class Task { int id; this(int i) { id = i; } }
    
    auto queue = LockFreeQueue!Task(16);
    
    // Batch enqueue 8 items
    Task[] items;
    foreach (i; 0 .. 8)
        items ~= new Task(i);
    
    immutable enqueued = queue.enqueueBatch(items);
    assert(enqueued == 8);
    assert(queue.length == 8);
    
    // Verify order preserved
    foreach (i; 0 .. 8)
    {
        auto t = queue.tryDequeue();
        assert(t !is null && t.id == i);
    }
    
    writeln("\x1b[32m  ✓ Batch enqueue\x1b[0m");
}

/// Test batch enqueue partial (queue fills)
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.lockfree - Batch enqueue partial");
    
    class Task { int id; this(int i) { id = i; } }
    
    auto queue = LockFreeQueue!Task(8);  // Small capacity
    
    // Fill partially
    foreach (i; 0 .. 5)
        queue.enqueue(new Task(i));
    
    // Try batch enqueue 10 items (only 3 should fit)
    Task[] items;
    foreach (i; 100 .. 110)
        items ~= new Task(i);
    
    immutable enqueued = queue.enqueueBatch(items);
    assert(enqueued == 3);  // 8 - 5 = 3 slots available
    assert(queue.length == 8);
    
    writeln("\x1b[32m  ✓ Batch enqueue partial\x1b[0m");
}

/// Test batch operations on empty queue
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.lockfree - Batch on empty");
    
    class Task { int id; this(int i) { id = i; } }
    
    auto queue = LockFreeQueue!Task(16);
    
    Task[] batch;
    immutable count = queue.tryDequeueBatch(5, batch);
    
    assert(count == 0);
    assert(queue.empty);
    
    writeln("\x1b[32m  ✓ Batch on empty\x1b[0m");
}

/// Test concurrent batch dequeue (stress test)
unittest
{
    import std.stdio;
    import core.thread;
    import core.atomic;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.lockfree - Concurrent batch dequeue");
    
    class Task { int id; this(int i) { id = i; } }
    
    enum QUEUE_SIZE = 1024;
    enum ITEMS_PER_CONSUMER = 250;
    enum NUM_CONSUMERS = 4;
    enum TOTAL_ITEMS = ITEMS_PER_CONSUMER * NUM_CONSUMERS;
    
    auto queue = LockFreeQueue!Task(QUEUE_SIZE);
    shared size_t totalDequeued = 0;
    shared bool[TOTAL_ITEMS] seen;  // Track which items were dequeued
    
    // Producer: enqueue all items
    foreach (i; 0 .. TOTAL_ITEMS)
        queue.enqueue(new Task(i));
    
    // Consumer threads using batch dequeue
    Thread[] consumers;
    foreach (c; 0 .. NUM_CONSUMERS)
    {
        consumers ~= new Thread({
            Task[] batch;
            while (true)
            {
                immutable count = queue.tryDequeueBatch(16, batch);
                if (count == 0)
                {
                    if (atomicLoad(totalDequeued) >= TOTAL_ITEMS)
                        break;
                    Thread.yield();
                    continue;
                }
                
                foreach (i; 0 .. count)
                {
                    auto id = batch[i].id;
                    atomicStore(seen[id], true);
                }
                atomicOp!"+="(totalDequeued, count);
            }
        });
    }
    
    foreach (t; consumers)
        t.start();
    foreach (t; consumers)
        t.join();
    
    // Verify all items were dequeued exactly once
    assert(atomicLoad(totalDequeued) == TOTAL_ITEMS);
    foreach (i; 0 .. TOTAL_ITEMS)
        assert(atomicLoad(seen[i]), "Item " ~ toString(i) ~ " not seen");
    
    writeln("\x1b[32m  ✓ Concurrent batch dequeue\x1b[0m");
}

/// Test interleaved batch enqueue/dequeue
unittest
{
    import std.stdio;
    import core.thread;
    import core.atomic;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.lockfree - Interleaved batch ops");
    
    class Task { int id; this(int i) { id = i; } }
    
    auto queue = LockFreeQueue!Task(256);
    shared size_t produced = 0;
    shared size_t consumed = 0;
    shared bool producerDone = false;
    
    enum TOTAL = 1000;
    
    // Producer using batch enqueue
    auto producer = new Thread({
        Task[] batch;
        int nextId = 0;
        
        while (nextId < TOTAL)
        {
            batch.length = 0;
            immutable batchSize = 8;
            foreach (i; 0 .. batchSize)
            {
                if (nextId >= TOTAL) break;
                batch ~= new Task(nextId++);
            }
            
            if (batch.length > 0)
            {
                immutable enqueued = queue.enqueueBatch(batch);
                atomicOp!"+="(produced, enqueued);
                if (enqueued < batch.length)
                {
                    // Queue was full, retry remaining
                    nextId -= (batch.length - enqueued);
                    Thread.yield();
                }
            }
        }
        
        atomicStore(producerDone, true);
    });
    
    // Consumer using batch dequeue
    auto consumer = new Thread({
        Task[] batch;
        
        while (!atomicLoad(producerDone) || !queue.empty)
        {
            immutable count = queue.tryDequeueBatch(16, batch);
            if (count > 0)
                atomicOp!"+="(consumed, count);
            else
                Thread.yield();
        }
    });
    
    producer.start();
    consumer.start();
    producer.join();
    consumer.join();
    
    assert(atomicLoad(produced) == TOTAL);
    assert(atomicLoad(consumed) == TOTAL);
    
    writeln("\x1b[32m  ✓ Interleaved batch ops\x1b[0m");
}

private string toString(T)(T val)
{
    import std.conv : to;
    return to!string(val);
}

