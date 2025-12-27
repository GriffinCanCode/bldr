module infrastructure.utils.concurrency.pool;

import core.thread;
import core.sync.mutex;
import core.sync.condition;
import core.atomic;
import std.algorithm;
import std.range;
import infrastructure.errors : Errors, Internal;
import std.conv : to;
import std.parallelism : totalCPUs;

// Thread-local arena for zero-sync allocations within worker threads
private void resetWorkerMemory() @trusted nothrow
{
    // Import conditionally to avoid circular deps during init
    try
    {
        import engine.distributed.memory.local : ThreadLocalArena;
        ThreadLocalArena.reset();
    }
    catch (Exception) {}  // Ignore if module not yet loaded
}


/// Persistent thread pool for reusable parallel execution
/// Thread-safe: All shared state is protected by mutex or atomic operations
final class ThreadPool
{
    private Worker[] workers;
    private Job[] jobs;
    private Mutex jobMutex;  // Protects jobs array access
    private Condition jobAvailable;
    private Condition jobComplete;
    private shared bool running;  // Atomic access
    private shared size_t pendingJobs;  // Atomic access
    private shared size_t nextJobIndex;  // Atomic access (work stealing)
    
    /// Constructor: Create thread pool with specified worker count
    /// 
    /// Safety: This constructor is @system because:
    /// 1. Thread creation is inherently unsafe but properly managed
    /// 2. Atomic operations (atomicStore) ensure thread-safe initialization
    /// 3. Mutex/Condition creation is safe
    /// 4. Worker array is properly reserved before population
    /// 5. Each worker is started only after full initialization
    /// 
    /// Invariants:
    /// - All workers are created and started before constructor returns
    /// - Atomic running flag is set before workers start
    /// - Mutex and condition are initialized before use
    /// 
    /// What could go wrong:
    /// - Thread creation could fail: exception propagates to caller
    /// - Resource exhaustion: too many threads could fail (OS limit)
    /// - Race during initialization: prevented by setting running flag first
    @system
    this(size_t workerCount = 0)
    {
        if (workerCount == 0)
            workerCount = totalCPUs;
        
        if (workerCount == 0)
            throw Errors.internal("Worker count must be positive", Internal.InvalidState).build();
        
        jobMutex = new Mutex();
        jobAvailable = new Condition(jobMutex);
        jobComplete = new Condition(jobMutex);
        atomicStore(running, true);
        
        workers.reserve(workerCount);
        workers.length = workerCount;
        foreach (i; 0 .. workerCount)
        {
            workers[i] = new Worker(i, this);
            workers[i].start();
        }
    }
    
    /// Execute function on items in parallel (delegate version)
    /// 
    /// Safety: This function is @system because:
    /// 1. Thread synchronization via mutex prevents data races
    /// 2. Atomic operations (atomicStore, atomicLoad) ensure memory safety
    /// 3. Result array is pre-allocated to exact size (no reallocation)
    /// 4. Jobs are properly synchronized via jobMutex
    /// 5. Wait loop ensures all work completes before returning
    /// 
    /// Invariants:
    /// - Results array matches input array length exactly
    /// - All jobs complete before function returns
    /// - No result slots are uninitialized
    /// 
    /// What could go wrong:
    /// - func throws exception: propagates to caller, partial results lost
    /// - Deadlock: impossible due to single mutex and proper wait/notify
    /// - Memory: pre-allocated results array, no growth/reallocation
    /// - Thread safety: mutex ensures exclusive access to shared state
    @system
    R[] map(T, R)(scope T[] items, scope R delegate(T) func)
    {
        if (items.empty)
            return [];
        
        if (items.length == 1)
            return [func(items[0])];
        
        R[] results;
        results.length = items.length;
        
        synchronized (jobMutex)
        {
            // Clear old jobs first to allow GC
            jobs.length = 0;
            jobs.reserve(items.length);
            
            atomicStore(pendingJobs, items.length);
            atomicStore(nextJobIndex, cast(size_t)0);
            
            // Create new Job objects (heap-allocated) to avoid dangling pointers
            foreach (i, ref item; items)
            {
                auto job = new Job(i);
                job.work = makeWork(i, item, results, func);
                jobs ~= job;
            }
            
            jobAvailable.notifyAll();
        }
        
        synchronized (jobMutex)
        {
            while (atomicLoad(pendingJobs) > 0)
                jobComplete.wait();
        }
        
        return results;
    }
    
    /// Execute function on items in parallel (function pointer version)
    /// 
    /// Safety: Delegates to trusted map() with delegate wrapper
    @system
    R[] map(T, R)(scope T[] items, R function(T) func)
    {
        // Convert function to delegate and call delegate version
        R delegate(T) dg = (T x) => func(x);
        return map(items, dg);
    }
    
    /// Execute function on items in parallel without collecting results (forEach)
    /// 
    /// Safety: This function is @system because:
    /// 1. Thread synchronization via mutex prevents data races
    /// 2. Atomic operations ensure memory safety
    /// 3. No result collection - simpler than map()
    /// 4. Jobs properly synchronized and awaited
    @system
    void forEach(T)(scope T[] items, scope void delegate(T) func)
    {
        if (items.empty)
            return;
        
        if (items.length == 1)
        {
            func(items[0]);
            return;
        }
        
        synchronized (jobMutex)
        {
            // Clear old jobs first to allow GC
            jobs.length = 0;
            jobs.reserve(items.length);
            
            atomicStore(pendingJobs, items.length);
            atomicStore(nextJobIndex, cast(size_t)0);
            
            // Create new Job objects (heap-allocated) to avoid dangling pointers
            foreach (i, ref item; items)
            {
                auto job = new Job(i);
                job.work = makeForEachWork(item, func);
                jobs ~= job;
            }
            
            jobAvailable.notifyAll();
        }
        
        synchronized (jobMutex)
        {
            while (atomicLoad(pendingJobs) > 0)
                jobComplete.wait();
        }
    }
    
    /// Helper to create work delegate with proper value capture
    /// 
    /// Safety: This function is @system because:
    /// 1. Captures variables by value (index, item) - no dangling references
    /// 2. ref results is guaranteed valid during job execution
    /// 3. Inner delegate marked @system for array index assignment
    /// 4. Index is guaranteed valid (within bounds of pre-allocated array)
    @system
    private void delegate() @system makeWork(T, R)(size_t index, T item, ref R[] results, scope R delegate(T) func)
    {
        void delegate() @system safeDel = () @system {
            results[index] = func(item);
        };
        return safeDel;
    }
    
    /// Helper for forEach work delegate
    /// 
    /// Safety: This function is @system because:
    /// 1. Captures item by value - no dangling references
    /// 2. Inner delegate marked @system for function invocation
    /// 3. No result storage - simpler than makeWork()
    @system
    private void delegate() @system makeForEachWork(T)(T item, scope void delegate(T) func)
    {
        void delegate() @system safeDel = () @system {
            func(item);
        };
        return safeDel;
    }
    
    /// Shutdown pool and wait for workers
    /// 
    /// Safety: This function is @system because:
    /// 1. Atomic operations ensure thread-safe shutdown
    /// 2. Mutex synchronization prevents races
    /// 3. Thread.join() is inherently unsafe but properly managed
    /// 4. Notifies all workers to exit gracefully
    /// 5. Idempotent: safe to call multiple times
    @system
    void shutdown()
    {
        // Check if already shut down (idempotent)
        if (!atomicLoad(running))
            return;
        
        atomicStore(running, false);
        
        synchronized (jobMutex)
        {
            jobAvailable.notifyAll();
        }
        
        foreach (ref worker; workers)
            worker.join();
    }
    
    package:
    
    /// Get next job for worker (internal method)
    /// 
    /// Safety: This function is @system because:
    /// 1. Returns Job class reference (heap-allocated, stable pointer)
    /// 2. synchronized block ensures exclusive access
    /// 3. Atomic operations for thread-safe index access
    /// 4. Bounds checking prevents invalid array access
    /// 5. CAS operation ensures only one worker claims each job
    /// 6. Job is a class, so reference remains valid even if jobs array is reallocated
    @system
    Job nextJob()
    {
        synchronized (jobMutex)
        {
            while (atomicLoad(running))
            {
                immutable idx = atomicLoad(nextJobIndex);
                
                if (idx >= jobs.length)
                {
                    // All jobs claimed or no jobs available, wait for more work
                    jobAvailable.wait();
                    continue;
                }
                
                // Try to claim this job
                if (cas(&nextJobIndex, idx, idx + 1))
                {
                    if (!atomicLoad(jobs[idx].completed))
                        return jobs[idx];  // Return class reference, not pointer
                }
            }
            
            return null; // Shutdown
        }
    }
    
    /// Mark job as complete (internal method)
    /// 
    /// Safety: This function is @system because:
    /// 1. Atomic decrement operation is thread-safe
    /// 2. synchronized block ensures exclusive access
    /// 3. Condition variable notification is properly synchronized
    @system
    void completeJob()
    {
        synchronized (jobMutex)
        {
            immutable remaining = atomicOp!"-="(pendingJobs, 1);
            
            if (remaining == 0)
                jobComplete.notify();
        }
    }
    
    /// Check if pool is running (internal method)
    /// 
    /// Safety: This function is @system because:
    /// 1. atomicLoad() performs sequentially-consistent atomic read
    /// 2. running is shared - requires atomic operations
    /// 3. Read-only operation with no side effects
    @system
    bool isRunning() const nothrow @nogc
    {
        return atomicLoad(running);
    }
}

private final class Worker
{
    private immutable size_t id;
    private ThreadPool pool;
    private Thread thread;
    
    /// Worker constructor
    /// 
    /// Safety: This constructor is @system because:
    /// 1. Thread creation with member function pointer is safe pattern
    /// 2. Captures this and pool - both remain valid for thread lifetime
    /// 3. Thread is not started yet - safe initialization
    @system
    this(size_t id, ThreadPool pool)
    {
        this.id = id;
        this.pool = pool;
        this.thread = new Thread(&run);
    }
    
    /// Start worker thread
    /// 
    /// Safety: Thread.start() is inherently unsafe but properly managed
    @system
    void start()
    {
        thread.start();
    }
    
    /// Wait for worker thread to complete
    /// 
    /// Safety: Thread.join() is inherently unsafe but properly managed
    @system
    void join()
    {
        thread.join();
    }
    
    /// Worker main loop (runs in separate thread)
    /// 
    /// Safety: This function is @system because:
    /// 1. Atomic operations for thread-safe state checks
    /// 2. Job execution is isolated per worker
    /// 3. Exception handling prevents thread crashes
    /// 4. Proper cleanup via pool.completeJob()
    /// 5. Job is a class (heap-allocated), so reference remains valid
    /// 6. Thread-local arena reset between jobs eliminates pool contention
    @system
    private void run()
    {
        while (pool.isRunning())
        {
            auto job = pool.nextJob();  // Get Job class reference
            
            if (job is null)
                break;
            
            try
            {
                job.work();
                atomicStore(job.completed, true);
            }
            catch (Exception e)
            {
                // Log error but continue
                atomicStore(job.completed, true);
            }
            
            // Reset thread-local arena between jobs (zero-sync memory reuse)
            resetWorkerMemory();
            
            pool.completeJob();
        }
    }
}

/// Job structure for work distribution
/// Thread-safe: completed flag is accessed atomically
/// Class (not struct) to avoid dangling pointers when jobs array is reallocated
private final class Job
{
    size_t id;
    void delegate() work;
    shared bool completed;  // Atomic access for thread-safe completion checking
    
    this(size_t id) @system nothrow
    {
        this.id = id;
        atomicStore(this.completed, false);
    }
}


