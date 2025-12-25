module tests.integration.distributed_recovery_edge_cases;

import std.stdio : writeln;
import std.datetime : Duration, seconds, msecs, MonoTime, Clock;
import std.conv : to;
import std.algorithm : map, filter, sort, min, max, canFind, count;
import std.array : array;
import std.random : uniform, uniform01, Random;
import std.range : iota;
import std.parallelism : parallel;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import engine.distributed.coordinator.coordinator;
import engine.distributed.coordinator.registry;
import engine.distributed.coordinator.recover;
import engine.distributed.coordinator.scheduler;
import engine.distributed.coordinator.health;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.messages;
import engine.graph.core.graph : BuildGraph;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// ============================================================================
// DISTRIBUTED RECOVERY EDGE CASES
// Tests for complex failure scenarios not covered by basic chaos tests
// ============================================================================

/// Simulates a coordinator that can participate in split-brain scenarios
class SplitBrainCoordinator
{
    private Mutex mutex;
    private ActionId[][WorkerId] assignedWork;
    private ActionId[] completedActions;
    private shared bool isPrimary;
    private string coordinatorId;
    
    this(string id) @trusted
    {
        this.coordinatorId = id;
        this.mutex = new Mutex();
        atomicStore(isPrimary, true);
    }
    
    void demote() @trusted { atomicStore(isPrimary, false); }
    void promote() @trusted { atomicStore(isPrimary, true); }
    bool primary() @trusted => atomicLoad(isPrimary);
    
    Result!DistributedError assignWork(ActionId action, WorkerId worker) @trusted
    {
        if (!atomicLoad(isPrimary))
            return Result!DistributedError.err(new DistributedError("Not primary"));
        
        synchronized (mutex)
        {
            if (worker !in assignedWork)
                assignedWork[worker] = [];
            assignedWork[worker] ~= action;
        }
        return Ok!DistributedError();
    }
    
    void recordCompletion(ActionId action) @trusted
    {
        synchronized (mutex)
        {
            if (!completedActions.canFind(action))
                completedActions ~= action;
        }
    }
    
    size_t completionCount() @trusted
    {
        synchronized (mutex) return completedActions.length;
    }
    
    bool hasCompletion(ActionId action) @trusted
    {
        synchronized (mutex) return completedActions.canFind(action);
    }
}

/// Simulates a worker that can become a "zombie" (thought dead but still running)
class ZombieWorker
{
    private WorkerId id;
    private Mutex mutex;
    private ActionId[] inProgress;
    private ActionId[] completed;
    private shared bool connected;
    private shared bool processing;
    
    this(WorkerId id) @trusted
    {
        this.id = id;
        this.mutex = new Mutex();
        atomicStore(connected, true);
        atomicStore(processing, false);
    }
    
    void disconnect() @trusted { atomicStore(connected, false); }
    void reconnect() @trusted { atomicStore(connected, true); }
    bool isConnected() @trusted => atomicLoad(connected);
    
    void startWork(ActionId action) @trusted
    {
        synchronized (mutex)
        {
            inProgress ~= action;
            atomicStore(processing, true);
        }
    }
    
    /// Complete work even while "disconnected" (zombie behavior)
    ActionId completeWork() @trusted
    {
        synchronized (mutex)
        {
            if (inProgress.length == 0)
                return ActionId.init;
            
            auto action = inProgress[0];
            inProgress = inProgress[1 .. $];
            completed ~= action;
            
            if (inProgress.length == 0)
                atomicStore(processing, false);
            
            return action;
        }
    }
    
    ActionId[] getCompleted() @trusted
    {
        synchronized (mutex) return completed.dup;
    }
    
    bool isProcessing() @trusted => atomicLoad(processing);
}

/// Simulates partial output state for actions
struct PartialOutputState
{
    string[] expectedOutputs;
    string[] writtenOutputs;
    bool completed;
    
    float completionRatio() const pure @safe nothrow
    {
        if (expectedOutputs.length == 0) return 1.0f;
        return cast(float)writtenOutputs.length / cast(float)expectedOutputs.length;
    }
    
    bool isPartial() const pure @safe nothrow
    {
        return writtenOutputs.length > 0 && writtenOutputs.length < expectedOutputs.length;
    }
}

// ============================================================================
// SPLIT-BRAIN SCENARIO TESTS
// ============================================================================

/// Test: Split-brain - two coordinators both think they're primary
@("distributed_edge.split_brain_dual_primary")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Split Brain Dual Primary");
    
    auto coord1 = new SplitBrainCoordinator("coord-1");
    auto coord2 = new SplitBrainCoordinator("coord-2");
    
    // Both think they're primary (split-brain condition)
    Assert.isTrue(coord1.primary(), "Coord1 should be primary");
    Assert.isTrue(coord2.primary(), "Coord2 should be primary");
    
    // Create test action
    ubyte[32] hash;
    hash[0] = 1;
    auto action = ActionId(hash);
    
    // Both assign same work to different workers
    auto worker1 = WorkerId(1);
    auto worker2 = WorkerId(2);
    
    auto result1 = coord1.assignWork(action, worker1);
    auto result2 = coord2.assignWork(action, worker2);
    
    Assert.isTrue(result1.isOk, "Coord1 assignment should succeed");
    Assert.isTrue(result2.isOk, "Coord2 assignment should succeed");
    
    // Simulate work completion on both
    coord1.recordCompletion(action);
    coord2.recordCompletion(action);
    
    // Both have recorded completion - this is the split-brain problem
    Assert.isTrue(coord1.hasCompletion(action), "Coord1 has completion");
    Assert.isTrue(coord2.hasCompletion(action), "Coord2 has completion");
    
    // Resolution: demote one coordinator
    coord2.demote();
    Assert.isFalse(coord2.primary(), "Coord2 should be demoted");
    
    // Further work should only go to primary
    ubyte[32] hash2;
    hash2[0] = 2;
    auto action2 = ActionId(hash2);
    
    auto result3 = coord1.assignWork(action2, worker1);
    auto result4 = coord2.assignWork(action2, worker2);
    
    Assert.isTrue(result3.isOk, "Primary should accept work");
    Assert.isTrue(result4.isErr, "Demoted should reject work");
    
    writeln("  \x1b[32m✓ Split brain dual primary handling passed\x1b[0m");
}

/// Test: Split-brain resolution with fencing tokens
@("distributed_edge.split_brain_fencing")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Split Brain Fencing");
    
    // Fencing tokens ensure only one coordinator can make progress
    shared ulong currentFencingToken = 1;
    auto mutex = new Mutex();
    
    struct FencedOperation
    {
        ulong token;
        ActionId action;
        bool accepted;
    }
    
    FencedOperation[] operations;
    
    // Simulate two coordinators trying to assign work
    foreach (coordId; parallel(iota(2)))
    {
        ulong myToken;
        synchronized (mutex)
        {
            myToken = atomicLoad(currentFencingToken);
        }
        
        // Simulate network delay
        Thread.sleep(uniform(1, 10).msecs);
        
        // Try to execute operation with fencing token
        synchronized (mutex)
        {
            ubyte[32] hash;
            hash[0] = cast(ubyte)coordId;
            auto action = ActionId(hash);
            
            bool accepted = myToken == atomicLoad(currentFencingToken);
            operations ~= FencedOperation(myToken, action, accepted);
            
            // First successful operation increments token
            if (accepted)
                atomicOp!"+="(currentFencingToken, 1);
        }
    }
    
    // Only one operation should succeed per token
    auto acceptedCount = operations.filter!(op => op.accepted).count;
    Logger.info("Fencing test - accepted operations: " ~ acceptedCount.to!string);
    
    Assert.isTrue(acceptedCount >= 1, "At least one operation should succeed");
    
    writeln("  \x1b[32m✓ Split brain fencing passed\x1b[0m");
}

// ============================================================================
// ZOMBIE WORKER TESTS
// ============================================================================

/// Test: Zombie worker returns with completed work
@("distributed_edge.zombie_worker_resurrection")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Zombie Worker Resurrection");
    
    auto worker = new ZombieWorker(WorkerId(1));
    
    // Worker receives and starts work
    ubyte[32] hash;
    hash[0] = 42;
    auto action = ActionId(hash);
    worker.startWork(action);
    
    Assert.isTrue(worker.isProcessing(), "Worker should be processing");
    Assert.isTrue(worker.isConnected(), "Worker should be connected");
    
    // Network partition - worker appears dead
    worker.disconnect();
    Assert.isFalse(worker.isConnected(), "Worker should appear disconnected");
    
    // Worker completes work while "dead" (zombie)
    Thread.sleep(50.msecs);  // Simulate work
    auto completedAction = worker.completeWork();
    
    Assert.equal(completedAction, action, "Work should complete even while disconnected");
    Assert.isFalse(worker.isProcessing(), "Worker should finish processing");
    
    // Worker reconnects with completed work
    worker.reconnect();
    Assert.isTrue(worker.isConnected(), "Worker should reconnect");
    
    auto completed = worker.getCompleted();
    Assert.equal(completed.length, 1, "Should have one completed action");
    Assert.isTrue(completed.canFind(action), "Completed should include original action");
    
    writeln("  \x1b[32m✓ Zombie worker resurrection passed\x1b[0m");
}

/// Test: Zombie worker result vs reassigned work race
@("distributed_edge.zombie_vs_reassignment_race")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Zombie vs Reassignment Race");
    
    auto mutex = new Mutex();
    
    struct ActionResult
    {
        ActionId action;
        WorkerId worker;
        MonoTime completionTime;
        bool accepted;
    }
    
    ActionResult[] results;
    shared bool firstResultAccepted = false;
    
    ubyte[32] hash;
    hash[0] = 99;
    auto action = ActionId(hash);
    
    auto zombie = new ZombieWorker(WorkerId(1));
    auto replacement = new ZombieWorker(WorkerId(2));
    
    // Both workers work on same action
    zombie.startWork(action);
    replacement.startWork(action);
    
    // Zombie takes longer but completes
    auto zombieThread = new Thread({
        Thread.sleep(100.msecs);
        zombie.completeWork();
        
        synchronized (mutex)
        {
            bool accepted = !atomicLoad(firstResultAccepted);
            if (accepted) atomicStore(firstResultAccepted, true);
            results ~= ActionResult(action, WorkerId(1), MonoTime.currTime, accepted);
        }
    });
    
    // Replacement completes faster
    auto replacementThread = new Thread({
        Thread.sleep(50.msecs);
        replacement.completeWork();
        
        synchronized (mutex)
        {
            bool accepted = !atomicLoad(firstResultAccepted);
            if (accepted) atomicStore(firstResultAccepted, true);
            results ~= ActionResult(action, WorkerId(2), MonoTime.currTime, accepted);
        }
    });
    
    zombieThread.start();
    replacementThread.start();
    zombieThread.join();
    replacementThread.join();
    
    // Exactly one result should be accepted
    auto acceptedResults = results.filter!(r => r.accepted).array;
    Assert.equal(acceptedResults.length, 1, "Exactly one result should be accepted");
    
    // First completion should win
    Assert.equal(acceptedResults[0].worker, WorkerId(2), "Faster worker should win");
    
    writeln("  \x1b[32m✓ Zombie vs reassignment race passed\x1b[0m");
}

/// Test: Zombie worker with stale data
@("distributed_edge.zombie_stale_data")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Zombie Worker Stale Data");
    
    // Simulate version tracking for actions
    shared ulong currentVersion = 1;
    
    struct VersionedResult
    {
        ActionId action;
        ulong version_;
        ubyte[] output;
    }
    
    auto mutex = new Mutex();
    VersionedResult[] acceptedResults;
    
    ubyte[32] hash;
    hash[0] = 77;
    auto action = ActionId(hash);
    
    // Zombie has old version
    auto zombieVersion = atomicLoad(currentVersion);
    
    // Increment version (action was reassigned)
    atomicOp!"+="(currentVersion, 1);
    auto newVersion = atomicLoad(currentVersion);
    
    // Zombie completes with old version
    VersionedResult zombieResult;
    zombieResult.action = action;
    zombieResult.version_ = zombieVersion;
    zombieResult.output = cast(ubyte[])"zombie output";
    
    // New worker completes with current version
    VersionedResult newResult;
    newResult.action = action;
    newResult.version_ = newVersion;
    newResult.output = cast(ubyte[])"new output";
    
    // Accept only current version
    synchronized (mutex)
    {
        if (zombieResult.version_ == atomicLoad(currentVersion))
            acceptedResults ~= zombieResult;
        if (newResult.version_ == atomicLoad(currentVersion))
            acceptedResults ~= newResult;
    }
    
    Assert.equal(acceptedResults.length, 1, "Only current version should be accepted");
    Assert.equal(acceptedResults[0].version_, newVersion, "New version should be accepted");
    Assert.equal(acceptedResults[0].output, cast(ubyte[])"new output", "New output should be used");
    
    writeln("  \x1b[32m✓ Zombie stale data rejection passed\x1b[0m");
}

// ============================================================================
// PARTIAL OUTPUT TESTS
// ============================================================================

/// Test: Worker dies after writing partial outputs
@("distributed_edge.partial_output_cleanup")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Partial Output Cleanup");
    
    auto tempDir = new TempDir("partial-output-test");
    tempDir.setup();
    scope(exit) tempDir.teardown();
    
    // Action that produces 3 output files
    PartialOutputState state;
    state.expectedOutputs = ["output1.o", "output2.o", "output3.o"];
    state.writtenOutputs = [];
    state.completed = false;
    
    // Simulate partial write before crash
    import std.file : write, exists, remove;
    import std.path : buildPath;
    
    auto basePath = tempDir.getPath();
    
    // Write 2 of 3 outputs
    write(buildPath(basePath, "output1.o"), "compiled object 1");
    state.writtenOutputs ~= "output1.o";
    
    write(buildPath(basePath, "output2.o"), "compiled object 2");
    state.writtenOutputs ~= "output2.o";
    
    // Crash before writing output3.o
    Assert.isTrue(state.isPartial(), "State should be partial");
    Assert.equal(state.completionRatio(), 2.0f/3.0f, "Should be 2/3 complete");
    
    // Cleanup partial outputs before retry
    foreach (output; state.writtenOutputs)
    {
        auto path = buildPath(basePath, output);
        if (exists(path))
            remove(path);
    }
    
    // Verify cleanup
    Assert.isFalse(exists(buildPath(basePath, "output1.o")), "output1.o should be cleaned");
    Assert.isFalse(exists(buildPath(basePath, "output2.o")), "output2.o should be cleaned");
    
    writeln("  \x1b[32m✓ Partial output cleanup passed\x1b[0m");
}

/// Test: Detect partial outputs on recovery
@("distributed_edge.partial_output_detection")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Partial Output Detection");
    
    auto tempDir = new TempDir("partial-detect-test");
    tempDir.setup();
    scope(exit) tempDir.teardown();
    
    import std.file : write, exists, getSize;
    import std.path : buildPath;
    
    auto basePath = tempDir.getPath();
    
    // Simulate various partial states
    struct OutputSpec
    {
        string name;
        size_t expectedSize;
        size_t actualSize;
    }
    
    OutputSpec[] specs = [
        OutputSpec("complete.o", 1000, 1000),      // Complete
        OutputSpec("truncated.o", 1000, 500),      // Truncated
        OutputSpec("empty.o", 1000, 0),            // Empty (write started but no data)
        // missing.o - not written at all
    ];
    
    // Write files according to specs
    foreach (spec; specs)
    {
        auto path = buildPath(basePath, spec.name);
        ubyte[] data = new ubyte[spec.actualSize];
        data[] = 0x42;
        write(path, data);
    }
    
    // Detection logic
    bool detectPartialOutputs(OutputSpec[] expected, string dir)
    {
        foreach (spec; expected)
        {
            auto path = buildPath(dir, spec.name);
            
            if (!exists(path))
                return true;  // Missing file
            
            if (getSize(path) != spec.expectedSize)
                return true;  // Wrong size
        }
        return false;
    }
    
    // Add missing file to expected
    OutputSpec[] fullExpected = specs ~ OutputSpec("missing.o", 1000, 1000);
    
    Assert.isTrue(detectPartialOutputs(fullExpected, basePath), "Should detect partial outputs");
    
    // With only complete file
    Assert.isFalse(detectPartialOutputs([specs[0]], basePath), "Complete file should pass");
    
    writeln("  \x1b[32m✓ Partial output detection passed\x1b[0m");
}

// ============================================================================
// IDEMPOTENCY TESTS
// ============================================================================

/// Test: Same action assigned to multiple workers produces consistent result
@("distributed_edge.idempotent_execution")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Idempotent Execution");
    
    auto mutex = new Mutex();
    
    // Simulate deterministic action execution
    ubyte[] executeAction(ActionId action, string input) pure @trusted
    {
        // Deterministic computation based on action and input
        import std.digest.sha : sha256Of;
        auto combined = cast(ubyte[])input ~ action.hash[];
        return sha256Of(combined)[].dup;
    }
    
    ubyte[32] hash;
    hash[0] = 123;
    auto action = ActionId(hash);
    immutable input = "source code content";
    
    ubyte[][] results;
    
    // Multiple workers execute same action
    foreach (workerId; parallel(iota(4)))
    {
        auto result = executeAction(action, input);
        synchronized (mutex)
        {
            results ~= result;
        }
    }
    
    // All results should be identical
    Assert.equal(results.length, 4, "Should have 4 results");
    foreach (i, result; results[1..$])
    {
        Assert.equal(result, results[0], "Result " ~ (i+1).to!string ~ " should match result 0");
    }
    
    writeln("  \x1b[32m✓ Idempotent execution passed\x1b[0m");
}

/// Test: Non-idempotent action detection
@("distributed_edge.non_idempotent_detection")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Non-Idempotent Detection");
    
    auto mutex = new Mutex();
    shared uint executionCounter = 0;
    
    // Non-deterministic action (uses execution count)
    ubyte[] executeNonIdempotent(ActionId action) @trusted
    {
        auto count = atomicOp!"+="(executionCounter, 1);
        return cast(ubyte[])(count.to!string ~ "-" ~ action.hash[0].to!string);
    }
    
    ubyte[32] hash;
    hash[0] = 200;
    auto action = ActionId(hash);
    
    ubyte[][] results;
    
    // Multiple executions
    foreach (i; 0 .. 3)
    {
        synchronized (mutex)
        {
            results ~= executeNonIdempotent(action);
        }
    }
    
    // Results should differ (non-idempotent)
    bool allSame = true;
    foreach (result; results[1..$])
    {
        if (result != results[0])
            allSame = false;
    }
    
    Assert.isFalse(allSame, "Non-idempotent action should produce different results");
    
    writeln("  \x1b[32m✓ Non-idempotent detection passed\x1b[0m");
}

// ============================================================================
// QUEUE OVERFLOW TESTS
// ============================================================================

/// Test: Reassignment queue overflow during mass failure
@("distributed_edge.queue_overflow")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Queue Overflow");
    
    auto mutex = new Mutex();
    
    // Bounded queue simulation
    struct BoundedQueue(T)
    {
        T[] items;
        size_t maxSize;
        size_t dropped;
        
        bool push(T item) @trusted
        {
            if (items.length >= maxSize)
            {
                dropped++;
                return false;
            }
            items ~= item;
            return true;
        }
        
        T pop() @trusted
        {
            if (items.length == 0)
                return T.init;
            auto item = items[0];
            items = items[1..$];
            return item;
        }
        
        size_t length() const @safe => items.length;
    }
    
    BoundedQueue!ActionId queue;
    queue.maxSize = 100;
    
    // Mass failure produces 500 actions to reassign
    foreach (i; 0 .. 500)
    {
        ubyte[32] hash;
        hash[0] = cast(ubyte)(i & 0xFF);
        hash[1] = cast(ubyte)((i >> 8) & 0xFF);
        
        synchronized (mutex)
        {
            queue.push(ActionId(hash));
        }
    }
    
    Logger.info("Queue overflow test - queued: " ~ queue.length.to!string ~ 
               ", dropped: " ~ queue.dropped.to!string);
    
    Assert.equal(queue.length, 100, "Queue should be at capacity");
    Assert.equal(queue.dropped, 400, "Should have dropped 400 items");
    
    writeln("  \x1b[32m✓ Queue overflow handling passed\x1b[0m");
}

/// Test: Backpressure mechanism
@("distributed_edge.backpressure")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Backpressure");
    
    shared size_t pendingWork = 0;
    shared bool acceptingWork = true;
    immutable size_t highWaterMark = 50;
    immutable size_t lowWaterMark = 20;
    
    auto mutex = new Mutex();
    size_t rejectedCount = 0;
    size_t acceptedCount = 0;
    
    // Submit work with backpressure
    bool submitWork() @trusted
    {
        if (!atomicLoad(acceptingWork))
            return false;
        
        auto pending = atomicOp!"+="(pendingWork, 1);
        
        // Check high water mark
        if (pending >= highWaterMark)
            atomicStore(acceptingWork, false);
        
        return true;
    }
    
    // Complete work
    void completeWork() @trusted
    {
        auto pending = atomicOp!"-="(pendingWork, 1);
        
        // Check low water mark
        if (pending <= lowWaterMark)
            atomicStore(acceptingWork, true);
    }
    
    // Rapid submission
    foreach (i; 0 .. 100)
    {
        if (submitWork())
            acceptedCount++;
        else
            rejectedCount++;
    }
    
    Logger.info("Backpressure - accepted: " ~ acceptedCount.to!string ~ 
               ", rejected: " ~ rejectedCount.to!string);
    
    Assert.equal(acceptedCount, highWaterMark, "Should accept up to high water mark");
    Assert.equal(rejectedCount, 100 - highWaterMark, "Should reject excess");
    
    // Drain some work
    foreach (i; 0 .. 35)
        completeWork();
    
    // Should accept work again
    Assert.isTrue(atomicLoad(acceptingWork), "Should resume accepting work");
    Assert.isTrue(submitWork(), "Should accept new work after drain");
    
    writeln("  \x1b[32m✓ Backpressure mechanism passed\x1b[0m");
}

// ============================================================================
// BLACKLIST THRASHING TESTS
// ============================================================================

/// Test: Worker repeatedly fails/recovers faster than backoff
@("distributed_edge.blacklist_thrashing")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Blacklist Thrashing");
    
    struct BlacklistEntry
    {
        size_t failureCount;
        MonoTime blacklistUntil;
        bool isBlacklisted(MonoTime now) const => now < blacklistUntil;
    }
    
    BlacklistEntry[WorkerId] blacklist;
    auto mutex = new Mutex();
    
    void recordFailure(WorkerId worker, MonoTime now) @trusted
    {
        synchronized (mutex)
        {
            if (worker !in blacklist)
                blacklist[worker] = BlacklistEntry(0, MonoTime.zero);
            
            auto entry = &blacklist[worker];
            entry.failureCount++;
            
            // Exponential backoff: 100ms * 2^failures (capped at 10s)
            auto backoffMs = min(100 * (1 << min(entry.failureCount, 7)), 10_000);
            entry.blacklistUntil = now + backoffMs.msecs;
        }
    }
    
    bool canAssign(WorkerId worker, MonoTime now) @trusted
    {
        synchronized (mutex)
        {
            if (worker !in blacklist)
                return true;
            return !blacklist[worker].isBlacklisted(now);
        }
    }
    
    auto worker = WorkerId(1);
    auto startTime = MonoTime.currTime;
    
    // Rapid failures
    foreach (i; 0 .. 10)
    {
        recordFailure(worker, startTime + (i * 10).msecs);
    }
    
    synchronized (mutex)
    {
        auto entry = blacklist[worker];
        Logger.info("After 10 rapid failures - count: " ~ entry.failureCount.to!string);
        Assert.equal(entry.failureCount, 10, "Should record all failures");
    }
    
    // Check blacklist duration increases
    Assert.isFalse(canAssign(worker, startTime + 100.msecs), "Should be blacklisted at 100ms");
    Assert.isFalse(canAssign(worker, startTime + 1.seconds), "Should be blacklisted at 1s");
    
    // Eventually expires (at 10s max)
    Assert.isTrue(canAssign(worker, startTime + 15.seconds), "Should expire after 15s");
    
    writeln("  \x1b[32m✓ Blacklist thrashing handling passed\x1b[0m");
}

/// Test: Circuit breaker pattern for flaky workers
@("distributed_edge.circuit_breaker")
@system unittest
{
    writeln("\x1b[36m[EDGE CASE]\x1b[0m Distributed - Circuit Breaker");
    
    enum CircuitState { Closed, Open, HalfOpen }
    
    struct CircuitBreaker
    {
        CircuitState state = CircuitState.Closed;
        size_t failureCount;
        size_t successCount;
        MonoTime lastFailure;
        
        immutable size_t failureThreshold = 5;
        immutable size_t successThreshold = 3;
        immutable Duration timeout = 5.seconds;
        
        bool allowRequest(MonoTime now)
        {
            final switch (state)
            {
                case CircuitState.Closed:
                    return true;
                case CircuitState.Open:
                    if (now - lastFailure >= timeout)
                    {
                        state = CircuitState.HalfOpen;
                        return true;
                    }
                    return false;
                case CircuitState.HalfOpen:
                    return true;
            }
        }
        
        void recordSuccess()
        {
            final switch (state)
            {
                case CircuitState.Closed:
                    failureCount = 0;
                    break;
                case CircuitState.Open:
                    break;
                case CircuitState.HalfOpen:
                    successCount++;
                    if (successCount >= successThreshold)
                    {
                        state = CircuitState.Closed;
                        failureCount = 0;
                        successCount = 0;
                    }
                    break;
            }
        }
        
        void recordFailure(MonoTime now)
        {
            lastFailure = now;
            
            final switch (state)
            {
                case CircuitState.Closed:
                    failureCount++;
                    if (failureCount >= failureThreshold)
                        state = CircuitState.Open;
                    break;
                case CircuitState.Open:
                    break;
                case CircuitState.HalfOpen:
                    state = CircuitState.Open;
                    successCount = 0;
                    break;
            }
        }
    }
    
    CircuitBreaker cb;
    auto now = MonoTime.currTime;
    
    // Initial state - closed
    Assert.equal(cb.state, CircuitState.Closed, "Should start closed");
    Assert.isTrue(cb.allowRequest(now), "Should allow requests when closed");
    
    // Failures trip the breaker
    foreach (i; 0 .. 5)
    {
        cb.recordFailure(now);
    }
    
    Assert.equal(cb.state, CircuitState.Open, "Should open after failures");
    Assert.isFalse(cb.allowRequest(now), "Should reject requests when open");
    
    // After timeout, transitions to half-open
    Assert.isTrue(cb.allowRequest(now + 6.seconds), "Should allow after timeout");
    Assert.equal(cb.state, CircuitState.HalfOpen, "Should be half-open");
    
    // Successes close the breaker
    foreach (i; 0 .. 3)
    {
        cb.recordSuccess();
    }
    
    Assert.equal(cb.state, CircuitState.Closed, "Should close after successes");
    
    writeln("  \x1b[32m✓ Circuit breaker pattern passed\x1b[0m");
}

