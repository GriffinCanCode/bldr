module infrastructure.utils.concurrency.structured;

import core.thread;
import core.atomic;
import core.sync.mutex;
import core.sync.condition;
import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm : remove, filter, each, canFind;
import std.array : array;
import std.conv : to;
import std.concurrency;
import infrastructure.utils.concurrency.pool;
import infrastructure.utils.concurrency.priority;
import infrastructure.errors : Errors, Internal;


/// Cancellation token for hierarchical cancellation
/// Propagates cancellation from parent to children automatically
final class CancellationToken
{
    private CancellationToken parent;
    private CancellationToken[] children;
    private shared bool cancelled;
    private Mutex mutex;
    private void delegate() @system[] callbacks;
    
    this(CancellationToken parent = null) @trusted
    {
        this.parent = parent;
        this.mutex = new Mutex();
        atomicStore(cancelled, false);
        if (parent !is null)
            parent.addChild(this);
    }
    
    /// Check if cancellation was requested (this or any parent)
    bool isCancelled() const @trusted nothrow @nogc
        => atomicLoad(cancelled) || (parent !is null && parent.isCancelled());
    
    /// Request cancellation (propagates to children)
    void cancel() @trusted
    {
        if (atomicLoad(cancelled)) return;
        atomicStore(cancelled, true);
        
        // Execute callbacks
        synchronized (mutex)
        {
            foreach (cb; callbacks)
            {
                try { cb(); }
                catch (Exception) {} // Swallow callback exceptions
            }
        }
        
        // Propagate to children
        CancellationToken[] toCancel;
        synchronized (mutex)
            toCancel = children.dup;
        foreach (child; toCancel)
            child.cancel();
    }
    
    /// Register callback to invoke on cancellation
    void onCancel(void delegate() @system callback) @trusted
    {
        if (isCancelled())
        {
            callback();
            return;
        }
        synchronized (mutex)
            callbacks ~= callback;
    }
    
    /// Throw if cancelled (for cooperative cancellation)
    void throwIfCancelled() @trusted
    {
        if (isCancelled())
            throw new CancelledException("Operation cancelled");
    }
    
    private void addChild(CancellationToken child) @trusted
    {
        synchronized (mutex)
            children ~= child;
    }
    
    private void removeChild(CancellationToken child) @trusted
    {
        synchronized (mutex)
            children = children.filter!(c => c !is child).array;
    }
}

/// Exception thrown when operation is cancelled
class CancelledException : Exception
{
    this(string msg) { super(msg); }
}

/// Task state for lifecycle tracking
enum TaskState : ubyte
{
    Created,     // Initial state
    Running,     // Actively executing
    Completed,   // Finished successfully
    Cancelled,   // Cancelled before/during execution
    Faulted      // Threw exception
}

/// Structured task with cancellation and parent tracking
/// Ensures proper lifecycle management and exception propagation
final class StructuredTask(T)
{
    alias ResultType = T;
    
    private TaskScope parentScope;
    private CancellationToken token;
    private Thread thread;
    private Mutex mutex;
    private Condition completion;
    private shared TaskState state;
    static if (!is(T == void))
        private T result;
    private Exception error;
    private string name;
    private MonoTime startTime;
    private MonoTime endTime;
    
    this(TaskScope parent, string name, CancellationToken token = null) @trusted
    {
        this.parentScope = parent;
        this.name = name;
        this.token = token !is null ? token : (parent !is null ? parent.getToken() : new CancellationToken());
        this.mutex = new Mutex();
        this.completion = new Condition(mutex);
        atomicStore(state, TaskState.Created);
    }
    
    /// Start task with work delegate
    void start(T delegate() @system work) @trusted
    {
        if (atomicLoad(state) != TaskState.Created)
            throw Errors.internal("Task already started", Internal.InvalidState).build();
        
        startTime = MonoTime.currTime;
        atomicStore(state, TaskState.Running);
        
        thread = new Thread(() @trusted {
            try
            {
                if (token.isCancelled())
                {
                    atomicStore(state, TaskState.Cancelled);
                }
                else
                {
                    static if (!is(T == void))
                        result = work();
                    else
                        work();
                    
                    if (token.isCancelled())
                        atomicStore(state, TaskState.Cancelled);
                    else
                        atomicStore(state, TaskState.Completed);
                }
            }
            catch (CancelledException)
            {
                atomicStore(state, TaskState.Cancelled);
            }
            catch (Exception e)
            {
                error = e;
                atomicStore(state, TaskState.Faulted);
            }
            finally
            {
                endTime = MonoTime.currTime;
                synchronized (mutex)
                    completion.notifyAll();
                
                if (parentScope !is null)
                    parentScope.notifyTaskComplete(this);
            }
        });
        thread.start();
    }
    
    /// Wait for completion (blocks)
    void join() @trusted
    {
        if (thread !is null)
            thread.join();
    }
    
    /// Wait with timeout, returns true if completed
    bool join(Duration timeout) @trusted
    {
        if (isComplete()) return true;
        
        synchronized (mutex)
        {
            if (!isComplete())
                completion.wait(timeout);
        }
        return isComplete();
    }
    
    /// Get result (blocks until complete, throws on error/cancellation)
    T getResult() @trusted
    {
        join();
        
        final switch (atomicLoad(state))
        {
            case TaskState.Completed:
                static if (!is(T == void))
                    return result;
                else
                    return;
            case TaskState.Cancelled:
                throw new CancelledException("Task was cancelled");
            case TaskState.Faulted:
                throw error;
            case TaskState.Created:
            case TaskState.Running:
                throw Errors.internal("Task not complete", Internal.Error).build();
        }
    }
    
    /// Check if task completed (success, cancelled, or faulted)
    bool isComplete() const @trusted nothrow @nogc
    {
        auto s = atomicLoad(state);
        return s == TaskState.Completed || s == TaskState.Cancelled || s == TaskState.Faulted;
    }
    
    /// Get current state
    TaskState getState() const @trusted nothrow @nogc
        => atomicLoad(state);
    
    /// Get task name
    string getName() const @safe nothrow => name;
    
    /// Get execution duration (valid after completion)
    Duration getDuration() const @trusted
        => endTime - startTime;
    
    /// Get error (null if none)
    inout(Exception) getError() inout @safe nothrow => error;
    
    /// Cancel this task
    void cancel() @trusted
    {
        token.cancel();
    }
}

/// Void specialization helper
alias VoidTask = StructuredTask!void;

/// Task scope providing structured concurrency guarantees:
/// 1. All child tasks complete before scope exits
/// 2. Cancellation propagates to all children
/// 3. Exceptions from children are collected
/// 4. Prevents thread leaks
final class TaskScope
{
    private TaskScope parent;
    private CancellationToken token;
    private Mutex mutex;
    private Condition allComplete;
    private VoidTask[] tasks;
    private Exception[] errors;
    private shared bool closed;
    private shared size_t activeTasks;
    private string name;
    private ThreadPool pool;  // Optional shared pool
    
    this(string name, TaskScope parent = null, ThreadPool pool = null) @trusted
    {
        this.name = name;
        this.parent = parent;
        this.token = new CancellationToken(parent !is null ? parent.getToken() : null);
        this.mutex = new Mutex();
        this.allComplete = new Condition(mutex);
        this.pool = pool;
        atomicStore(closed, false);
        atomicStore(activeTasks, cast(size_t)0);
    }
    
    /// Get cancellation token for this scope
    CancellationToken getToken() @safe nothrow => token;
    
    /// Check if scope is cancelled
    bool isCancelled() const @trusted nothrow @nogc
        => token.isCancelled();
    
    /// Launch a void task in this scope
    VoidTask launch(string taskName, void delegate() @system work) @trusted
    {
        if (atomicLoad(closed))
            throw Errors.internal("TaskScope is closed", Internal.InvalidState).build();
        
        auto task = new VoidTask(this, taskName, token);
        
        synchronized (mutex)
        {
            tasks ~= task;
            atomicOp!"+="(activeTasks, 1);
        }
        
        task.start(work);
        return task;
    }
    
    /// Launch a task returning a result
    StructuredTask!T launch(T)(string taskName, T delegate() @system work) @trusted
    {
        if (atomicLoad(closed))
            throw Errors.internal("TaskScope is closed", Internal.InvalidState).build();
        
        auto task = new StructuredTask!T(this, taskName, token);
        atomicOp!"+="(activeTasks, 1);
        
        // Wrap to track as VoidTask for scope management
        auto wrapper = new VoidTask(this, taskName ~ "-wrapper", token);
        synchronized (mutex)
            tasks ~= wrapper;
        
        task.start(work);
        return task;
    }
    
    /// Launch background task (loop until cancelled)
    VoidTask launchBackground(string taskName, void delegate() @system loopBody) @trusted
    {
        return launch(taskName, () @trusted {
            while (!token.isCancelled())
            {
                try
                {
                    loopBody();
                }
                catch (CancelledException)
                {
                    break;
                }
                catch (Exception e)
                {
                    synchronized (mutex)
                        errors ~= e;
                    // Continue loop unless cancelled
                }
            }
        });
    }
    
    /// Launch periodic task (runs at interval until cancelled)
    VoidTask launchPeriodic(string taskName, Duration interval, void delegate() @system work) @trusted
    {
        return launch(taskName, () @trusted {
            while (!token.isCancelled())
            {
                auto start = MonoTime.currTime;
                try
                {
                    work();
                }
                catch (CancelledException)
                {
                    break;
                }
                catch (Exception e)
                {
                    synchronized (mutex)
                        errors ~= e;
                }
                
                auto elapsed = MonoTime.currTime - start;
                auto remaining = elapsed < interval ? interval - elapsed : Duration.zero;
                
                // Sleep in short intervals to allow fast cancellation
                while (remaining > Duration.zero && !token.isCancelled())
                {
                    auto sleepTime = remaining > msecs(100) ? msecs(100) : remaining;
                    Thread.sleep(sleepTime);
                    remaining -= sleepTime;
                }
            }
        });
    }
    
    /// Create a child scope (for nested structured concurrency)
    TaskScope createChild(string childName) @trusted
    {
        if (atomicLoad(closed))
            throw Errors.internal("TaskScope is closed", Internal.InvalidState).build();
        return new TaskScope(childName, this, pool);
    }
    
    /// Cancel all tasks in this scope (and children via token)
    void cancel() @trusted
    {
        token.cancel();
    }
    
    /// Wait for all tasks to complete, then close scope
    /// This is the key structured concurrency guarantee
    void joinAll() @trusted
    {
        atomicStore(closed, true);
        
        // Wait for all tasks
        foreach (task; tasks)
            task.join();
        
        // Propagate first error if any
        synchronized (mutex)
        {
            if (errors.length > 0)
                throw new AggregateException("TaskScope '" ~ name ~ "' had " ~ 
                    errors.length.to!string ~ " errors", errors);
        }
    }
    
    /// Wait with timeout, returns true if all completed
    bool joinAll(Duration timeout) @trusted
    {
        atomicStore(closed, true);
        
        auto deadline = MonoTime.currTime + timeout;
        foreach (task; tasks)
        {
            auto remaining = deadline - MonoTime.currTime;
            if (remaining <= Duration.zero || !task.join(remaining))
                return false;
        }
        return true;
    }
    
    /// Cancel all tasks and wait for cleanup
    void cancelAndJoin() @trusted
    {
        cancel();
        joinAll();
    }
    
    /// Get number of active tasks
    size_t activeTaskCount() const @trusted nothrow @nogc
        => atomicLoad(activeTasks);
    
    /// Get all errors encountered
    Exception[] getErrors() @trusted
    {
        synchronized (mutex)
            return errors.dup;
    }
    
    /// Called by tasks when they complete
    package void notifyTaskComplete(VoidTask task) @trusted
    {
        atomicOp!"-="(activeTasks, 1);
        
        if (task.getState() == TaskState.Faulted && task.getError() !is null)
        {
            synchronized (mutex)
                errors ~= task.getError();
        }
        
        synchronized (mutex)
        {
            if (atomicLoad(activeTasks) == 0)
                allComplete.notifyAll();
        }
    }
}

/// Aggregate exception for collecting multiple errors
class AggregateException : Exception
{
    Exception[] innerExceptions;
    
    this(string msg, Exception[] inners)
    {
        super(msg);
        innerExceptions = inners;
    }
}

/// RAII guard for TaskScope - ensures joinAll on scope exit
struct ScopedTaskScope
{
    private TaskScope scope_;
    private bool moved;
    
    @disable this(this);
    
    this(string name, TaskScope parent = null) @trusted
    {
        scope_ = new TaskScope(name, parent);
        moved = false;
    }
    
    ~this() @trusted
    {
        if (!moved && scope_ !is null)
        {
            scope_.cancelAndJoin();
        }
    }
    
    /// Access the underlying scope
    TaskScope get() @safe nothrow => scope_;
    
    /// Release ownership (manual management)
    TaskScope release() @safe nothrow
    {
        moved = true;
        return scope_;
    }
}


// ============================================================================
// Message-passing support via std.concurrency
// ============================================================================

/// Message types for actor-style communication
struct TaskMessage(T)
{
    enum Type { Work, Result, Error, Shutdown }
    Type type;
    T payload;
    string errorMsg;
}

/// Create an actor-style worker that processes messages
/// Returns Tid for sending messages
Tid spawnWorker(T, R)(R delegate(T) @system handler, void delegate(Exception) @system errorHandler = null) @trusted
{
    return spawn((R delegate(T) @system h, void delegate(Exception) @system errH) @trusted {
        bool running = true;
        while (running)
        {
            receive(
                (TaskMessage!T msg) {
                    final switch (msg.type)
                    {
                        case TaskMessage!T.Type.Work:
                            try
                            {
                                auto result = h(msg.payload);
                                // Could send result back if needed
                            }
                            catch (Exception e)
                            {
                                if (errH !is null)
                                    errH(e);
                            }
                            break;
                        case TaskMessage!T.Type.Shutdown:
                            running = false;
                            break;
                        case TaskMessage!T.Type.Result:
                        case TaskMessage!T.Type.Error:
                            break; // Ignore
                    }
                }
            );
        }
    }, handler, errorHandler);
}

/// Send work to a worker
void sendWork(T)(Tid worker, T payload) @trusted
{
    TaskMessage!T msg;
    msg.type = TaskMessage!T.Type.Work;
    msg.payload = payload;
    send(worker, msg);
}

/// Signal worker to shutdown
void shutdownWorker(T)(Tid worker) @trusted
{
    TaskMessage!T msg;
    msg.type = TaskMessage!T.Type.Shutdown;
    send(worker, msg);
}


// ============================================================================
// Convenience functions for common patterns
// ============================================================================

/// Run work in a scope that guarantees completion
/// Usage: withScope("mywork", (scope_) { scope_.launch("task", work); });
void withScope(string name, void delegate(TaskScope) @system body) @trusted
{
    auto scope_ = new TaskScope(name);
    scope(exit) scope_.joinAll();
    body(scope_);
}

/// Run parallel tasks and wait for all to complete
R[] parallel(T, R)(T[] items, R delegate(T) @system work, size_t maxParallelism = 0) @trusted
{
    import std.parallelism : totalCPUs;
    
    if (items.length == 0) return [];
    if (items.length == 1) return [work(items[0])];
    
    immutable workers = maxParallelism == 0 ? totalCPUs : maxParallelism;
    
    auto scope_ = new TaskScope("parallel");
    scope(exit) scope_.joinAll();
    
    R[] results;
    results.length = items.length;
    Mutex resultMutex = new Mutex();
    
    foreach (i, item; items)
    {
        scope_.launch("work-" ~ i.to!string, () @trusted {
            auto r = work(item);
            synchronized (resultMutex)
                results[i] = r;
        });
    }
    
    return results;
}

/// Run tasks with timeout, cancel remaining on timeout
bool withTimeout(Duration timeout, void delegate(TaskScope) @system body) @trusted
{
    auto scope_ = new TaskScope("timeout");
    
    body(scope_);
    
    if (!scope_.joinAll(timeout))
    {
        scope_.cancel();
        scope_.joinAll();  // Wait for cancelled tasks to complete
        return false;
    }
    return true;
}


// ============================================================================
// Unit tests
// ============================================================================

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.structured - Basic TaskScope");
    
    shared int counter = 0;
    
    auto scope_ = new TaskScope("test");
    
    foreach (i; 0 .. 5)
    {
        scope_.launch("task-" ~ i.to!string, () @trusted {
            atomicOp!"+="(counter, 1);
        });
    }
    
    scope_.joinAll();
    assert(atomicLoad(counter) == 5);
    
    writeln("\x1b[32m  ✓ Basic TaskScope\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.structured - Cancellation");
    
    auto scope_ = new TaskScope("cancel-test");
    shared bool wasRunning = false;
    
    scope_.launch("long-task", () @trusted {
        atomicStore(wasRunning, true);
        while (!scope_.isCancelled())
            Thread.sleep(10.msecs);
    });
    
    Thread.sleep(50.msecs);
    assert(atomicLoad(wasRunning));
    
    scope_.cancel();
    scope_.joinAll();
    
    writeln("\x1b[32m  ✓ Cancellation\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.structured - Hierarchical cancellation");
    
    auto parent = new TaskScope("parent");
    auto child = parent.createChild("child");
    
    shared bool childTaskRan = false;
    
    child.launch("child-task", () @trusted {
        atomicStore(childTaskRan, true);
        while (!child.isCancelled())
            Thread.sleep(10.msecs);
    });
    
    Thread.sleep(50.msecs);
    
    // Cancel parent should cancel child
    parent.cancel();
    assert(child.isCancelled());
    
    child.joinAll();
    parent.joinAll();
    
    assert(atomicLoad(childTaskRan));
    
    writeln("\x1b[32m  ✓ Hierarchical cancellation\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.structured - ScopedTaskScope RAII");
    
    shared int value = 0;
    
    {
        auto guard = ScopedTaskScope("raii-test");
        guard.get().launch("work", () @trusted {
            Thread.sleep(20.msecs);
            atomicStore(value, 42);
        });
        // Destructor will joinAll
    }
    
    assert(atomicLoad(value) == 42);
    
    writeln("\x1b[32m  ✓ ScopedTaskScope RAII\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.structured - Periodic task");
    
    shared int ticks = 0;
    
    auto scope_ = new TaskScope("periodic-test");
    scope_.launchPeriodic("ticker", 10.msecs, () @trusted {
        atomicOp!"+="(ticks, 1);
    });
    
    Thread.sleep(55.msecs);
    scope_.cancel();
    scope_.joinAll();
    
    assert(atomicLoad(ticks) >= 3 && atomicLoad(ticks) <= 7);
    
    writeln("\x1b[32m  ✓ Periodic task\x1b[0m");
}

unittest
{
    import std.stdio;
    writeln("\x1b[36m[TEST]\x1b[0m utils.concurrency.structured - withScope convenience");
    
    shared int result = 0;
    
    withScope("convenient", (scope_) @trusted {
        scope_.launch("work", () @trusted {
            atomicStore(result, 123);
        });
    });
    
    assert(atomicLoad(result) == 123);
    
    writeln("\x1b[32m  ✓ withScope convenience\x1b[0m");
}

