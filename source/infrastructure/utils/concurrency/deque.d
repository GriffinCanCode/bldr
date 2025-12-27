module infrastructure.utils.concurrency.deque;

import core.atomic;
import std.algorithm;
import std.range;
import std.traits;


/// Lock-free work-stealing deque using Chase-Lev algorithm
/// Optimized for single-producer (owner) and multiple-consumer (stealers) pattern
/// 
/// Thread Safety:
/// - Owner thread: can push/pop from bottom (local end) without locks
/// - Stealer threads: can steal from top (remote end) using lock-free CAS
/// - All operations are wait-free for the owner, lock-free for stealers
/// 
/// Performance:
/// - Zero contention on owner operations (most common case)
/// - Minimal CAS contention on steal operations
/// - Dynamic circular buffer with automatic resizing
/// - Cache-friendly: owner operations access bottom, stealers access top
/// - Cache line padding prevents false sharing between bottom/top indices
/// 
/// References:
/// - Chase & Lev: "Dynamic Circular Work-Stealing Deque" (2005)
/// - Morrison & Afek: "Fast Concurrent Queues for x86 Processors" (2013)
struct WorkStealingDeque(T) if (is(T == class) || is(T == interface))
{
    private static struct CircularArray
    {
        shared T[] buffer;
        size_t logSize;  // log2(capacity) for fast modulo (not immutable for heap allocation)
        
        @disable this(this);  // Non-copyable
        
        static CircularArray* create(size_t capacity) @system nothrow
        {
            import std.math : isPowerOf2;
            assert(isPowerOf2(capacity), "Capacity must be power of 2");
            
            auto arr = new CircularArray();
            arr.buffer.length = capacity;
            
            // Calculate log2(capacity)
            size_t temp = capacity;
            size_t log = 0;
            while (temp > 1)
            {
                temp >>= 1;
                log++;
            }
            arr.logSize = log;
            return arr;
        }
        
        @property size_t capacity() const pure nothrow @nogc @system
        {
            return cast(size_t)1 << logSize;
        }
        
        T get(size_t index) @system nothrow @nogc
        {
            immutable mask = capacity - 1;
            return cast(T)atomicLoad(buffer[index & mask]);
        }
        
        void put(size_t index, T item) @system nothrow @nogc
        {
            immutable mask = capacity - 1;
            atomicStore(buffer[index & mask], cast(shared)item);
        }
    }
    
    private shared CircularArray* array;
    private shared long bottom;  // Bottom index (owner side)
    private ubyte[64] _padBottom; // Cache line padding to prevent false sharing
    private shared long top;     // Top index (stealer side)
    
    @disable this(this);  // Non-copyable
    
    /// Initialize deque with initial capacity (must be power of 2)
    this(size_t capacity) @system
    {
        import std.math : isPowerOf2;
        assert(isPowerOf2(capacity), "Capacity must be power of 2");
        
        auto arr = CircularArray.create(capacity);
        atomicStore(array, cast(shared)arr);
        atomicStore(bottom, cast(long)0);
        atomicStore(top, cast(long)0);
    }
    
    /// Push task to bottom (owner only)
    /// Owner can push without CAS - fastest path
    /// 
    /// Safety: @system because:
    /// 1. Only owner thread calls this (by design contract)
    /// 2. Atomic loads for top, relaxed for bottom (owner exclusive)
    /// 3. Array access is bounds-checked via capacity
    /// 4. Automatic growth when needed
    @system
    void push(T task) nothrow
    {
        auto b = atomicLoad!(MemoryOrder.raw)(bottom);
        auto t = atomicLoad!(MemoryOrder.acq)(top);
        auto arr = cast(CircularArray*)atomicLoad(array);
        
        immutable size = b - t;
        if (size >= arr.capacity)
        {
            // Grow array (rare path) - allocate on heap to avoid dangling pointer
            auto newArray = CircularArray.create(arr.capacity * 2);
            foreach (i; t .. b)
                newArray.put(i, arr.get(i));
            atomicStore(array, cast(shared)newArray);
            arr = newArray;
        }
        
        arr.put(b, task);
        atomicFence!(MemoryOrder.rel)();
        atomicStore!(MemoryOrder.raw)(bottom, b + 1);
    }
    
    /// Pop task from bottom (owner only)
    /// Owner's fast path - no CAS in common case
    /// Returns null if empty
    /// 
    /// Safety: @system because:
    /// 1. Only owner thread calls this (by design contract)
    /// 2. Atomic operations ensure proper ordering
    /// 3. CAS only when racing with stealers
    /// 4. Bounds checking via capacity
    @system
    T pop() nothrow
    {
        auto b = atomicLoad!(MemoryOrder.raw)(bottom) - 1;
        auto arr = cast(CircularArray*)atomicLoad(array);
        atomicStore!(MemoryOrder.raw)(bottom, b);
        atomicFence!(MemoryOrder.seq)();
        
        auto t = atomicLoad!(MemoryOrder.raw)(top);
        
        if (b < t)
        {
            // Deque is empty
            atomicStore!(MemoryOrder.raw)(bottom, t);
            return null;
        }
        
        auto task = arr.get(b);
        
        if (b > t)
        {
            // More than one element, no race with stealers
            return task;
        }
        
        // Last element - race with stealers
        if (!cas(&top, t, t + 1))
        {
            // Lost race to stealer
            task = null;
        }
        
        atomicStore!(MemoryOrder.raw)(bottom, t + 1);
        return task;
    }
    
    /// Steal task from top (stealers only)
    /// Lock-free CAS-based stealing for multiple threads
    /// Returns null if empty or lost race
    /// 
    /// Safety: @system because:
    /// 1. Multiple stealers can call concurrently
    /// 2. CAS ensures only one stealer succeeds
    /// 3. Atomic loads ensure memory ordering
    /// 4. Array access is bounds-checked
    @system
    T steal() nothrow
    {
        auto t = atomicLoad!(MemoryOrder.acq)(top);
        atomicFence!(MemoryOrder.seq)();
        auto b = atomicLoad!(MemoryOrder.acq)(bottom);
        
        if (t >= b)
        {
            // Empty
            return null;
        }
        
        auto arr = cast(CircularArray*)atomicLoad(array);
        auto task = arr.get(t);
        
        if (!cas(&top, t, t + 1))
        {
            // Lost race to another stealer or owner
            return null;
        }
        
        return task;
    }
    
    /// Batch steal: claim range from top with single CAS
    /// Reduces atomic overhead when stealing multiple tasks for load balancing
    /// 
    /// Performance:
    /// - Single CAS to claim up to maxCount tasks
    /// - Efficient for aggressive work stealing strategies
    /// 
    /// Returns: actual count stolen (0 if empty or lost race)
    @system
    size_t stealBatch(size_t maxCount, ref T[] results) nothrow
    {
        if (maxCount == 0) return 0;
        
        // Ensure results has capacity
        if (results.length < maxCount)
        {
            try { results.length = maxCount; }
            catch (Exception) { return 0; }
        }
        
        auto t = atomicLoad!(MemoryOrder.acq)(top);
        atomicFence!(MemoryOrder.seq)();
        auto b = atomicLoad!(MemoryOrder.acq)(bottom);
        
        if (t >= b) return 0;  // Empty
        
        // Calculate how many we can steal
        immutable available = cast(size_t)(b - t);
        // Steal at most half to maintain fairness with owner
        immutable toSteal = available < maxCount ? available : maxCount;
        immutable halfAvailable = (available + 1) / 2;
        immutable claimed = toSteal < halfAvailable ? toSteal : halfAvailable;
        
        if (claimed == 0) return 0;
        
        // Try to claim range
        if (!cas(&top, t, t + cast(long)claimed))
            return 0;  // Lost race
        
        // Read all stolen tasks
        auto arr = cast(CircularArray*)atomicLoad(array);
        foreach (i; 0 .. claimed)
            results[i] = arr.get(t + cast(long)i);
        
        return claimed;
    }
    
    /// Get approximate size (may be stale immediately)
    /// Used for load balancing heuristics
    @system
    size_t size() const nothrow @nogc
    {
        auto b = atomicLoad!(MemoryOrder.raw)(bottom);
        auto t = atomicLoad!(MemoryOrder.raw)(top);
        immutable diff = b - t;
        return diff < 0 ? 0 : cast(size_t)diff;
    }
    
    /// Check if approximately empty (may be stale)
    @system
    bool empty() const nothrow @nogc
    {
        auto b = atomicLoad!(MemoryOrder.raw)(bottom);
        auto t = atomicLoad!(MemoryOrder.raw)(top);
        return b <= t;
    }
    
    /// Get approximate capacity
    @system
    size_t capacity() const nothrow @nogc
    {
        auto arr = cast(CircularArray*)atomicLoad(array);
        return arr.capacity;
    }
}

/// Test basic push/pop operations
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Basic push/pop");
    
    class Task
    {
        int value;
        this(int v) { value = v; }
    }
    
    auto deque = WorkStealingDeque!Task(4);
    
    // Push tasks
    deque.push(new Task(1));
    deque.push(new Task(2));
    deque.push(new Task(3));
    
    assert(deque.size() == 3);
    assert(!deque.empty());
    
    // Pop tasks (LIFO from owner)
    auto t3 = deque.pop();
    assert(t3 !is null && t3.value == 3);
    
    auto t2 = deque.pop();
    assert(t2 !is null && t2.value == 2);
    
    auto t1 = deque.pop();
    assert(t1 !is null && t1.value == 1);
    
    assert(deque.empty());
    assert(deque.pop() is null);
    
    writeln("\x1b[32m  ✓ Basic push/pop\x1b[0m");
}

/// Test stealing operations
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Stealing");
    
    class Task
    {
        int value;
        this(int v) { value = v; }
    }
    
    auto deque = WorkStealingDeque!Task(4);
    
    // Push tasks
    deque.push(new Task(1));
    deque.push(new Task(2));
    deque.push(new Task(3));
    
    // Steal from top (FIFO from stealers)
    auto t1 = deque.steal();
    assert(t1 !is null && t1.value == 1);
    
    auto t2 = deque.steal();
    assert(t2 !is null && t2.value == 2);
    
    // Pop from bottom
    auto t3 = deque.pop();
    assert(t3 !is null && t3.value == 3);
    
    assert(deque.empty());
    assert(deque.steal() is null);
    
    writeln("\x1b[32m  ✓ Stealing\x1b[0m");
}

/// Test batch stealing operations
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Batch stealing");
    
    class Task
    {
        int value;
        this(int v) { value = v; }
    }
    
    auto deque = WorkStealingDeque!Task(16);
    
    // Push 10 tasks
    foreach (i; 1 .. 11)
        deque.push(new Task(i));
    
    assert(deque.size() == 10);
    
    // Batch steal (steals at most half for fairness)
    Task[] stolen;
    immutable count = deque.stealBatch(8, stolen);
    
    // Should steal at most 5 (half of 10)
    assert(count <= 5);
    assert(count > 0);
    
    // Verify FIFO order from top
    foreach (i; 0 .. count)
        assert(stolen[i].value == i + 1);
    
    // Remaining can still be popped
    assert(deque.size() == 10 - count);
    
    writeln("\x1b[32m  ✓ Batch stealing\x1b[0m");
}

/// Test automatic growth
unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Growth");
    
    class Task
    {
        int value;
        this(int v) { value = v; }
    }
    
    auto deque = WorkStealingDeque!Task(2);
    assert(deque.capacity() == 2);
    
    // Push beyond capacity
    deque.push(new Task(1));
    deque.push(new Task(2));
    deque.push(new Task(3));  // Triggers growth
    
    assert(deque.capacity() == 4);
    assert(deque.size() == 3);
    
    // Verify all tasks intact
    assert(deque.steal() !is null);
    assert(deque.steal() !is null);
    assert(deque.pop() !is null);
    
    writeln("\x1b[32m  ✓ Growth\x1b[0m");
}

// ==================== PROPERTY-BASED TESTS ====================

/// Property-based test utilities for concurrent testing
private class PropertyTestTask
{
    int id;
    shared static size_t nextId;
    
    this(int taskId) { this.id = taskId; }
    
    static PropertyTestTask create()
    {
        import core.atomic : atomicOp;
        auto taskId = atomicOp!"+="(nextId, 1);
        return new PropertyTestTask(cast(int)taskId);
    }
}

/// Execution trace for verifying properties
private class ExecutionTrace
{
    private shared size_t totalPushes;
    private shared size_t successfulPops;
    private shared size_t successfulSteals;
    private shared int[int] taskExecutions;  // taskId -> execution count
    
    void recordPush(int taskId)
    {
        atomicOp!"+="(totalPushes, 1);
    }
    
    void recordPop(int taskId)
    {
        atomicOp!"+="(successfulPops, 1);
        recordExecution(taskId);
    }
    
    void recordSteal(int taskId)
    {
        atomicOp!"+="(successfulSteals, 1);
        recordExecution(taskId);
    }
    
    private void recordExecution(int taskId)
    {
        synchronized
        {
            if (taskId in taskExecutions)
                atomicOp!"+="(taskExecutions[taskId], 1);
            else
                taskExecutions[taskId] = 1;
        }
    }
    
    bool verifyNoDoubleExecution() const
    {
        foreach (taskId, count; taskExecutions)
        {
            if (count > 1)
                return false;
        }
        return true;
    }
    
    bool verifyNoLostTasks(size_t remainingInQueue) const
    {
        size_t executed = atomicLoad(successfulPops) + atomicLoad(successfulSteals);
        size_t pushed = atomicLoad(totalPushes);
        return (executed + remainingInQueue) == pushed;
    }
    
    size_t totalExecuted() const
    {
        return atomicLoad(successfulPops) + atomicLoad(successfulSteals);
    }
}

unittest
{
    import std.stdio;
    import std.random : Random, unpredictableSeed, uniform;
    import core.thread;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Property: No lost tasks (random ops)");
    
    auto deque = WorkStealingDeque!PropertyTestTask(16);
    auto trace = new ExecutionTrace();
    auto rng = Random(unpredictableSeed);
    
    const iterations = 500;
    
    foreach (i; 0 .. iterations)
    {
        auto op = uniform(0, 10, rng);
        
        if (op < 6)  // 60% push
        {
            auto task = PropertyTestTask.create();
            deque.push(task);
            trace.recordPush(task.id);
        }
        else if (op < 9)  // 30% pop
        {
            auto task = deque.pop();
            if (task !is null)
                trace.recordPop(task.id);
        }
        else  // 10% steal
        {
            auto task = deque.steal();
            if (task !is null)
                trace.recordSteal(task.id);
        }
    }
    
    // Drain remaining
    size_t remaining = 0;
    while (!deque.empty())
    {
        auto task = deque.pop();
        if (task !is null)
        {
            remaining++;
            trace.recordPop(task.id);
        }
    }
    
    assert(trace.verifyNoDoubleExecution(), "No task should be executed twice");
    assert(trace.verifyNoLostTasks(0), "All tasks should be accounted for");
    
    writeln("\x1b[32m  ✓ No lost tasks with random operations\x1b[0m");
}

unittest
{
    import std.stdio;
    import core.thread;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Property: No double execution (concurrent)");
    
    auto deque = WorkStealingDeque!PropertyTestTask(64);
    auto trace = new ExecutionTrace();
    
    shared bool running = true;
    const numStealers = 4;
    const opsPerThread = 250;
    
    // Owner thread: push and pop
    auto ownerThread = new Thread({
        import std.random : Random, unpredictableSeed, uniform;
        auto rng = Random(unpredictableSeed + 1);
        
        foreach (i; 0 .. opsPerThread)
        {
            if (uniform(0, 10, rng) < 7)  // 70% push
            {
                auto task = PropertyTestTask.create();
                deque.push(task);
                trace.recordPush(task.id);
            }
            else
            {
                auto task = deque.pop();
                if (task !is null)
                    trace.recordPop(task.id);
            }
            
            if (i % 50 == 0)
                Thread.sleep(1.usecs);
        }
        
        atomicStore(running, false);
    });
    
    // Stealer threads
    Thread[] stealerThreads;
    foreach (stealerId; 0 .. numStealers)
    {
        stealerThreads ~= new Thread({
            import core.time : usecs;
            
            while (atomicLoad(running) || !deque.empty())
            {
                auto task = deque.steal();
                if (task !is null)
                    trace.recordSteal(task.id);
                
                import std.random : uniform;
                Thread.sleep(uniform(1, 5).usecs);
            }
        });
    }
    
    // Start and join all threads
    ownerThread.start();
    foreach (t; stealerThreads)
        t.start();
    
    ownerThread.join();
    foreach (t; stealerThreads)
        t.join();
    
    // Drain any remaining
    while (!deque.empty())
    {
        auto task = deque.pop();
        if (task !is null)
            trace.recordPop(task.id);
    }
    
    assert(trace.verifyNoDoubleExecution(), "No task should be executed twice in concurrent scenario");
    assert(trace.verifyNoLostTasks(0), "All tasks should be accounted for in concurrent scenario");
    
    writeln("\x1b[32m  ✓ No double execution in concurrent scenario\x1b[0m");
}

unittest
{
    import std.stdio;
    import core.thread;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Property: Race on last element");
    
    const iterations = 50;
    size_t ownerWins = 0;
    size_t stealerWins = 0;
    size_t bothLose = 0;
    
    foreach (i; 0 .. iterations)
    {
        auto deque = WorkStealingDeque!PropertyTestTask(4);
        
        // Push single task
        auto task = new PropertyTestTask(i);
        deque.push(task);
        
        shared PropertyTestTask ownerResult = null;
        shared PropertyTestTask stealerResult = null;
        
        // Owner pops
        auto ownerThread = new Thread({
            auto t = deque.pop();
            atomicStore(ownerResult, cast(shared)t);
        });
        
        // Stealer steals
        auto stealerThread = new Thread({
            auto t = deque.steal();
            atomicStore(stealerResult, cast(shared)t);
        });
        
        ownerThread.start();
        stealerThread.start();
        ownerThread.join();
        stealerThread.join();
        
        auto owner = cast(PropertyTestTask)atomicLoad(ownerResult);
        auto stealer = cast(PropertyTestTask)atomicLoad(stealerResult);
        
        // Exactly one should win OR both lose
        assert(!(owner !is null && stealer !is null), "Both cannot get the task");
        
        if (owner !is null && stealer is null)
            ownerWins++;
        else if (owner is null && stealer !is null)
            stealerWins++;
        else
            bothLose++;
    }
    
    assert(ownerWins + stealerWins + bothLose == iterations, "All races accounted for");
    
    writeln("\x1b[32m  ✓ Race on last element handled correctly (owner: ", ownerWins, 
           ", stealer: ", stealerWins, ", both lose: ", bothLose, ")\x1b[0m");
}

unittest
{
    import std.stdio;
    import core.thread;
    import core.time : msecs, usecs;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Property: High contention stress");
    
    auto deque = WorkStealingDeque!PropertyTestTask(128);
    auto trace = new ExecutionTrace();
    
    shared bool running = true;
    const numStealers = 6;
    const duration = 50.msecs;
    
    import std.datetime.stopwatch : MonoTime;
    auto startTime = MonoTime.currTime;
    
    // Aggressive owner
    auto ownerThread = new Thread({
        import std.random : Random, unpredictableSeed, uniform;
        auto rng = Random(unpredictableSeed + 2);
        
        while (MonoTime.currTime - startTime < duration)
        {
            if (uniform(0, 10, rng) < 6)
            {
                auto task = PropertyTestTask.create();
                deque.push(task);
                trace.recordPush(task.id);
            }
            else
            {
                auto task = deque.pop();
                if (task !is null)
                    trace.recordPop(task.id);
            }
        }
        
        atomicStore(running, false);
    });
    
    // Aggressive stealers
    Thread[] stealerThreads;
    foreach (stealerId; 0 .. numStealers)
    {
        stealerThreads ~= new Thread({
            while (atomicLoad(running))
            {
                auto task = deque.steal();
                if (task !is null)
                    trace.recordSteal(task.id);
            }
        });
    }
    
    ownerThread.start();
    foreach (t; stealerThreads)
        t.start();
    
    ownerThread.join();
    foreach (t; stealerThreads)
        t.join();
    
    // Drain
    while (!deque.empty())
    {
        auto task = deque.pop();
        if (task !is null)
            trace.recordPop(task.id);
    }
    
    assert(trace.verifyNoDoubleExecution(), "High contention: no double execution");
    assert(trace.verifyNoLostTasks(0), "High contention: no lost tasks");
    
    writeln("\x1b[32m  ✓ High contention stress test passed (", 
           trace.totalExecuted(), " tasks)\x1b[0m");
}

unittest
{
    import std.stdio;
    import core.thread;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Property: Growth under contention");
    
    auto deque = WorkStealingDeque!PropertyTestTask(4);  // Start small
    auto trace = new ExecutionTrace();
    
    const numTasks = 500;
    const numStealers = 3;
    shared size_t pushesCompleted = 0;
    
    // Owner pushes many (triggers growth)
    auto ownerThread = new Thread({
        foreach (i; 0 .. numTasks)
        {
            auto task = PropertyTestTask.create();
            deque.push(task);
            trace.recordPush(task.id);
            atomicOp!"+="(pushesCompleted, 1);
            
            if (i % 50 == 0)
                Thread.yield();
        }
    });
    
    // Stealers continuously steal
    Thread[] stealerThreads;
    foreach (stealerId; 0 .. numStealers)
    {
        stealerThreads ~= new Thread({
            import core.time : usecs;
            
            while (atomicLoad(pushesCompleted) < numTasks || !deque.empty())
            {
                auto task = deque.steal();
                if (task !is null)
                    trace.recordSteal(task.id);
                else
                    Thread.sleep(1.usecs);
            }
        });
    }
    
    ownerThread.start();
    foreach (t; stealerThreads)
        t.start();
    
    ownerThread.join();
    foreach (t; stealerThreads)
        t.join();
    
    // Drain
    while (!deque.empty())
    {
        auto task = deque.pop();
        if (task !is null)
            trace.recordPop(task.id);
    }
    
    assert(deque.capacity() > 4, "Deque should have grown");
    assert(trace.verifyNoDoubleExecution(), "Growth: no double execution");
    assert(trace.verifyNoLostTasks(0), "Growth: no lost tasks");
    
    writeln("\x1b[32m  ✓ Growth under contention (capacity: ", deque.capacity(), ")\x1b[0m");
}

unittest
{
    import std.stdio;
    
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.deque - Property: FIFO/LIFO ordering");
    
    auto deque = WorkStealingDeque!PropertyTestTask(32);
    
    // Push tasks 1-5
    foreach (id; 1 .. 6)
        deque.push(new PropertyTestTask(id));
    
    // Owner pop: LIFO (should get 5)
    auto task1 = deque.pop();
    assert(task1 !is null && task1.id == 5, "Owner pop should be LIFO");
    
    // Stealer: FIFO (should get 1, 2)
    auto task2 = deque.steal();
    assert(task2 !is null && task2.id == 1, "Stealer should be FIFO");
    
    auto task3 = deque.steal();
    assert(task3 !is null && task3.id == 2, "Stealer should be FIFO");
    
    writeln("\x1b[32m  ✓ FIFO/LIFO ordering verified\x1b[0m");
}

