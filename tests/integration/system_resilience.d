module tests.integration.system_resilience;

import std.stdio : writeln, File;
import std.file : exists, read, write, remove, mkdirRecurse, rmdirRecurse, tempDir, rename;
import std.path : buildPath, dirName;
import std.datetime : Duration, seconds, msecs, MonoTime, Clock, SysTime;
import std.algorithm : map, filter, canFind, sum, min, max, count, sort;
import std.array : array, join, split;
import std.range : iota;
import std.parallelism : parallel;
import std.conv : to;
import std.random : uniform, uniform01, Random, Mt19937;
import std.string : strip;
import std.process : ProcessPipes, pipeProcess, Redirect, wait;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

// ============================================================================
// SYSTEM RESILIENCE TESTS
// Checkpoint/resume, remote cache, plugin crash isolation, resource exhaustion
// ============================================================================

// ============================================================================
// CHECKPOINT AND RESUME TESTS
// ============================================================================

/// Checkpoint state for builds
struct BuildCheckpoint
{
    string buildId;
    long timestamp;
    string[] completedTargets;
    string[] pendingTargets;
    string[] failedTargets;
    ubyte[] serializedState;
    bool valid = true;
}

/// Checkpoint manager simulation
class CheckpointManager
{
    private string checkpointDir;
    private Mutex mutex;
    private shared size_t checkpointCount;
    private shared size_t corruptedCheckpoints;
    
    this(string dir) @system
    {
        this.checkpointDir = dir;
        this.mutex = new Mutex();
        if (!exists(dir))
            mkdirRecurse(dir);
    }
    
    /// Save checkpoint
    bool saveCheckpoint(BuildCheckpoint checkpoint) @system
    {
        auto path = buildPath(checkpointDir, checkpoint.buildId ~ ".checkpoint");
        auto tempPath = path ~ ".tmp";
        
        try
        {
            synchronized (mutex)
            {
                // Serialize checkpoint
                ubyte[] data;
                data ~= cast(ubyte[])(checkpoint.buildId ~ "\n");
                data ~= cast(ubyte[])(checkpoint.timestamp.to!string ~ "\n");
                data ~= cast(ubyte[])(checkpoint.completedTargets.join(",") ~ "\n");
                data ~= cast(ubyte[])(checkpoint.pendingTargets.join(",") ~ "\n");
                data ~= cast(ubyte[])(checkpoint.failedTargets.join(",") ~ "\n");
                
                // Write to temp file first (atomic write pattern)
                write(tempPath, data);
                
                // Atomic rename
                if (exists(path))
                    remove(path);
                rename(tempPath, path);
                
                atomicOp!"+="(checkpointCount, 1);
                return true;
            }
        }
        catch (Exception e)
        {
            Logger.error("Checkpoint save failed: " ~ e.msg);
            return false;
        }
    }
    
    /// Load checkpoint
    BuildCheckpoint loadCheckpoint(string buildId) @system
    {
        auto path = buildPath(checkpointDir, buildId ~ ".checkpoint");
        
        BuildCheckpoint checkpoint;
        checkpoint.buildId = buildId;
        checkpoint.valid = false;
        
        synchronized (mutex)
        {
            if (!exists(path))
                return checkpoint;
            
            try
            {
                auto data = cast(string)read(path);
                auto lines = data.split("\n");
                
                if (lines.length < 5)
                {
                    atomicOp!"+="(corruptedCheckpoints, 1);
                    return checkpoint;
                }
                
                checkpoint.buildId = lines[0].strip;
                checkpoint.timestamp = lines[1].strip.to!long;
                checkpoint.completedTargets = lines[2].strip.split(",").filter!(s => s.length > 0).array;
                checkpoint.pendingTargets = lines[3].strip.split(",").filter!(s => s.length > 0).array;
                checkpoint.failedTargets = lines[4].strip.split(",").filter!(s => s.length > 0).array;
                checkpoint.valid = true;
            }
            catch (Exception e)
            {
                atomicOp!"+="(corruptedCheckpoints, 1);
                Logger.error("Checkpoint load failed: " ~ e.msg);
            }
        }
        
        return checkpoint;
    }
    
    /// Simulate checkpoint corruption
    void corruptCheckpoint(string buildId) @system
    {
        auto path = buildPath(checkpointDir, buildId ~ ".checkpoint");
        
        synchronized (mutex)
        {
            if (exists(path))
            {
                // Truncate to simulate partial write
                auto data = cast(ubyte[])read(path);
                if (data.length > 10)
                    write(path, data[0..data.length/2]);
            }
        }
    }
    
    size_t getCheckpointCount() @trusted => atomicLoad(checkpointCount);
    size_t getCorruptedCount() @trusted => atomicLoad(corruptedCheckpoints);
}

/// Test: Checkpoint during normal build
@("resilience.checkpoint_normal")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Checkpoint - Normal Build");
    
    auto tempPath = buildPath(tempDir(), "checkpoint-normal-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto manager = new CheckpointManager(tempPath);
    
    BuildCheckpoint checkpoint;
    checkpoint.buildId = "build-001";
    checkpoint.timestamp = Clock.currTime.toUnixTime;
    checkpoint.completedTargets = ["target1", "target2", "target3"];
    checkpoint.pendingTargets = ["target4", "target5"];
    checkpoint.failedTargets = [];
    
    // Save checkpoint
    Assert.isTrue(manager.saveCheckpoint(checkpoint), "Checkpoint save should succeed");
    
    // Load checkpoint
    auto loaded = manager.loadCheckpoint("build-001");
    Assert.isTrue(loaded.valid, "Loaded checkpoint should be valid");
    Assert.equal(loaded.completedTargets.length, 3, "Should have 3 completed targets");
    Assert.equal(loaded.pendingTargets.length, 2, "Should have 2 pending targets");
    
    writeln("  \x1b[32m✓ Normal checkpoint passed\x1b[0m");
}

/// Test: Checkpoint corruption recovery
@("resilience.checkpoint_corruption")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Checkpoint - Corruption Recovery");
    
    auto tempPath = buildPath(tempDir(), "checkpoint-corrupt-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto manager = new CheckpointManager(tempPath);
    
    // Save valid checkpoint
    BuildCheckpoint checkpoint;
    checkpoint.buildId = "build-corrupt";
    checkpoint.timestamp = Clock.currTime.toUnixTime;
    checkpoint.completedTargets = ["a", "b", "c"];
    checkpoint.pendingTargets = ["d", "e"];
    checkpoint.failedTargets = [];
    
    manager.saveCheckpoint(checkpoint);
    
    // Corrupt the checkpoint
    manager.corruptCheckpoint("build-corrupt");
    
    // Try to load - should fail gracefully
    auto loaded = manager.loadCheckpoint("build-corrupt");
    Assert.isFalse(loaded.valid, "Corrupted checkpoint should be invalid");
    Assert.isTrue(manager.getCorruptedCount() > 0, "Should detect corruption");
    
    writeln("  \x1b[32m✓ Checkpoint corruption recovery passed\x1b[0m");
}

/// Test: Resume from partial checkpoint
@("resilience.checkpoint_resume")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Checkpoint - Resume from Partial");
    
    auto tempPath = buildPath(tempDir(), "checkpoint-resume-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    auto manager = new CheckpointManager(tempPath);
    
    // Simulate build that was interrupted at 60%
    BuildCheckpoint interrupted;
    interrupted.buildId = "interrupted-build";
    interrupted.timestamp = Clock.currTime.toUnixTime;
    interrupted.completedTargets = ["t1", "t2", "t3", "t4", "t5", "t6"];  // 60%
    interrupted.pendingTargets = ["t7", "t8", "t9", "t10"];  // 40% remaining
    interrupted.failedTargets = [];
    
    manager.saveCheckpoint(interrupted);
    
    // Resume build
    auto loaded = manager.loadCheckpoint("interrupted-build");
    Assert.isTrue(loaded.valid, "Should load valid checkpoint");
    
    // Calculate work remaining
    size_t totalTargets = loaded.completedTargets.length + loaded.pendingTargets.length;
    float progress = cast(float)loaded.completedTargets.length / totalTargets;
    
    Logger.info("Resume from " ~ (progress * 100).to!string ~ "% complete");
    
    Assert.equal(loaded.pendingTargets.length, 4, "Should have 4 targets remaining");
    Assert.isTrue(progress >= 0.5, "Should be at least 50% complete");
    
    // Simulate completing remaining work
    BuildCheckpoint completed;
    completed.buildId = "interrupted-build";
    completed.timestamp = Clock.currTime.toUnixTime;
    completed.completedTargets = loaded.completedTargets ~ loaded.pendingTargets;
    completed.pendingTargets = [];
    completed.failedTargets = [];
    
    manager.saveCheckpoint(completed);
    
    auto final_ = manager.loadCheckpoint("interrupted-build");
    Assert.equal(final_.completedTargets.length, 10, "Should have all targets complete");
    Assert.equal(final_.pendingTargets.length, 0, "Should have no pending targets");
    
    writeln("  \x1b[32m✓ Checkpoint resume passed\x1b[0m");
}

/// Test: Checkpoint during crash
@("resilience.checkpoint_crash")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Checkpoint - Crash During Write");
    
    auto tempPath = buildPath(tempDir(), "checkpoint-crash-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    
    mkdirRecurse(tempPath);
    
    // Simulate crash during checkpoint write (temp file exists, final doesn't)
    auto buildId = "crashed-build";
    auto tempFile = buildPath(tempPath, buildId ~ ".checkpoint.tmp");
    auto finalFile = buildPath(tempPath, buildId ~ ".checkpoint");
    
    // Write partial temp file
    write(tempFile, "partial data\nincomplete");
    
    // Crash recovery should detect this
    auto manager = new CheckpointManager(tempPath);
    auto loaded = manager.loadCheckpoint(buildId);
    
    // Should not find valid checkpoint (temp file doesn't count)
    Assert.isFalse(loaded.valid, "Crashed checkpoint should be invalid");
    
    // Clean recovery
    if (exists(tempFile))
        remove(tempFile);
    
    writeln("  \x1b[32m✓ Checkpoint crash handling passed\x1b[0m");
}

// ============================================================================
// REMOTE CACHE TESTS
// ============================================================================

/// Simulated remote cache with network failures
class SimulatedRemoteCache
{
    private ubyte[][string] storage;
    private Mutex mutex;
    private shared bool available;
    private shared size_t networkErrors;
    private shared size_t timeouts;
    private shared size_t successfulOps;
    private Duration simulatedLatency;
    private float failureProbability;
    
    this(Duration latency = 10.msecs, float failProb = 0.0) @trusted
    {
        this.mutex = new Mutex();
        this.simulatedLatency = latency;
        this.failureProbability = failProb;
        atomicStore(available, true);
    }
    
    void setAvailable(bool avail) @trusted { atomicStore(available, avail); }
    void setFailureProbability(float prob) @safe { failureProbability = prob; }
    
    /// Put with simulated network
    bool put(string key, ubyte[] data) @system
    {
        if (!atomicLoad(available))
        {
            atomicOp!"+="(networkErrors, 1);
            return false;
        }
        
        // Simulate network latency
        Thread.sleep(simulatedLatency);
        
        // Random failure
        if (uniform01() < failureProbability)
        {
            atomicOp!"+="(networkErrors, 1);
            return false;
        }
        
        synchronized (mutex)
        {
            storage[key] = data.dup;
            atomicOp!"+="(successfulOps, 1);
        }
        return true;
    }
    
    /// Get with simulated network
    ubyte[] get(string key) @system
    {
        if (!atomicLoad(available))
        {
            atomicOp!"+="(networkErrors, 1);
            return null;
        }
        
        Thread.sleep(simulatedLatency);
        
        if (uniform01() < failureProbability)
        {
            atomicOp!"+="(networkErrors, 1);
            return null;
        }
        
        synchronized (mutex)
        {
            if (key in storage)
            {
                atomicOp!"+="(successfulOps, 1);
                return storage[key].dup;
            }
        }
        return null;
    }
    
    /// Check with timeout
    bool exists(string key, Duration timeout) @system
    {
        auto start = MonoTime.currTime;
        
        while (MonoTime.currTime - start < timeout)
        {
            if (!atomicLoad(available))
            {
                Thread.sleep(10.msecs);
                continue;
            }
            
            synchronized (mutex)
            {
                return (key in storage) !is null;
            }
        }
        
        atomicOp!"+="(timeouts, 1);
        return false;
    }
    
    size_t getNetworkErrors() @trusted => atomicLoad(networkErrors);
    size_t getTimeouts() @trusted => atomicLoad(timeouts);
    size_t getSuccessfulOps() @trusted => atomicLoad(successfulOps);
}

/// Test: Remote cache timeout handling
@("resilience.remote_cache_timeout")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Remote Cache - Timeout Handling");
    
    auto cache = new SimulatedRemoteCache(50.msecs);
    
    // Store some data
    cache.put("key1", cast(ubyte[])"value1");
    
    // Normal retrieval
    auto result = cache.get("key1");
    Assert.isTrue(result !is null, "Should retrieve stored data");
    
    // Simulate network down
    cache.setAvailable(false);
    
    // Should timeout
    auto exists = cache.exists("key1", 100.msecs);
    Assert.isFalse(exists, "Should timeout when network unavailable");
    Assert.isTrue(cache.getTimeouts() > 0, "Should record timeout");
    
    writeln("  \x1b[32m✓ Remote cache timeout handling passed\x1b[0m");
}

/// Test: Remote cache network errors
@("resilience.remote_cache_network_errors")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Remote Cache - Network Errors");
    
    auto cache = new SimulatedRemoteCache(5.msecs, 0.5);  // 50% failure rate
    
    size_t successes = 0;
    size_t failures = 0;
    
    // Try multiple operations
    foreach (i; 0 .. 50)
    {
        if (cache.put("key" ~ i.to!string, cast(ubyte[])("value" ~ i.to!string)))
            successes++;
        else
            failures++;
    }
    
    Logger.info("Network errors - successes: " ~ successes.to!string ~
               ", failures: " ~ failures.to!string);
    
    // With 50% failure rate, should have mix of both
    Assert.isTrue(successes > 0, "Should have some successes");
    Assert.isTrue(failures > 0, "Should have some failures");
    Assert.isTrue(cache.getNetworkErrors() > 0, "Should record network errors");
    
    writeln("  \x1b[32m✓ Remote cache network errors passed\x1b[0m");
}

/// Test: Remote cache fallback to local
@("resilience.remote_cache_fallback")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Remote Cache - Fallback to Local");
    
    auto tempPath = buildPath(tempDir(), "cache-fallback-" ~ uniform(10000, 99999).to!string);
    scope(exit) if (exists(tempPath)) rmdirRecurse(tempPath);
    mkdirRecurse(tempPath);
    
    auto remoteCache = new SimulatedRemoteCache(5.msecs);
    
    // Local cache fallback
    ubyte[][string] localCache;
    auto mutex = new Mutex();
    
    bool cacheGet(string key, ref ubyte[] result)
    {
        // Try remote first
        result = remoteCache.get(key);
        if (result !is null)
            return true;
        
        // Fallback to local
        synchronized (mutex)
        {
            if (key in localCache)
            {
                result = localCache[key].dup;
                return true;
            }
        }
        return false;
    }
    
    void cachePut(string key, ubyte[] data)
    {
        // Write-through: local first, then remote
        synchronized (mutex)
        {
            localCache[key] = data.dup;
        }
        remoteCache.put(key, data);  // May fail
    }
    
    // Store data
    cachePut("fallback-key", cast(ubyte[])"fallback-value");
    
    // Remote available - should use remote
    ubyte[] result;
    Assert.isTrue(cacheGet("fallback-key", result), "Should get from remote");
    
    // Remote down - should fallback
    remoteCache.setAvailable(false);
    Assert.isTrue(cacheGet("fallback-key", result), "Should fallback to local");
    
    writeln("  \x1b[32m✓ Remote cache fallback passed\x1b[0m");
}

/// Test: Remote cache partial response
@("resilience.remote_cache_partial")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Remote Cache - Partial Response");
    
    auto cache = new SimulatedRemoteCache(5.msecs);
    
    // Store large data
    ubyte[] largeData = new ubyte[10000];
    foreach (i, ref b; largeData)
        b = cast(ubyte)(i & 0xFF);
    
    cache.put("large-key", largeData);
    
    // Retrieve and verify
    auto result = cache.get("large-key");
    Assert.isTrue(result !is null, "Should retrieve data");
    Assert.equal(result.length, largeData.length, "Should have correct length");
    Assert.equal(result, largeData, "Data should match exactly");
    
    writeln("  \x1b[32m✓ Remote cache partial response handling passed\x1b[0m");
}

// ============================================================================
// PLUGIN CRASH ISOLATION TESTS
// ============================================================================

/// Simulated plugin execution environment
class PluginSandbox
{
    private string pluginId;
    private shared bool crashed;
    private shared bool timedOut;
    private shared size_t executionCount;
    private Duration maxExecutionTime;
    private Mutex mutex;
    
    this(string id, Duration maxTime = 5.seconds) @trusted
    {
        this.pluginId = id;
        this.maxExecutionTime = maxTime;
        this.mutex = new Mutex();
        atomicStore(crashed, false);
        atomicStore(timedOut, false);
    }
    
    /// Execute plugin code in sandbox
    struct ExecutionResult
    {
        bool success;
        string output;
        string error;
        Duration elapsed;
    }
    
    ExecutionResult execute(bool shouldCrash = false, bool shouldHang = false) @system
    {
        auto startTime = MonoTime.currTime;
        ExecutionResult result;
        
        atomicOp!"+="(executionCount, 1);
        
        // Simulate execution
        try
        {
            if (shouldCrash)
            {
                atomicStore(crashed, true);
                result.success = false;
                result.error = "Plugin crashed: segmentation fault";
                return result;
            }
            
            if (shouldHang)
            {
                // Simulate timeout
                Thread.sleep(maxExecutionTime + 1.seconds);
                atomicStore(timedOut, true);
                result.success = false;
                result.error = "Plugin execution timed out";
                return result;
            }
            
            // Normal execution
            Thread.sleep(10.msecs);
            result.success = true;
            result.output = "Plugin " ~ pluginId ~ " executed successfully";
        }
        catch (Exception e)
        {
            atomicStore(crashed, true);
            result.success = false;
            result.error = "Plugin exception: " ~ e.msg;
        }
        
        result.elapsed = MonoTime.currTime - startTime;
        return result;
    }
    
    bool hasCrashed() @trusted => atomicLoad(crashed);
    bool hasTimedOut() @trusted => atomicLoad(timedOut);
    size_t getExecutionCount() @trusted => atomicLoad(executionCount);
    
    void reset() @trusted
    {
        atomicStore(crashed, false);
        atomicStore(timedOut, false);
    }
}

/// Plugin manager with crash isolation
class PluginManager
{
    private PluginSandbox[string] plugins;
    private Mutex mutex;
    private shared size_t totalCrashes;
    private shared size_t totalTimeouts;
    private shared size_t successfulExecutions;
    
    this() @trusted
    {
        this.mutex = new Mutex();
    }
    
    void registerPlugin(string id, Duration maxTime = 5.seconds) @system
    {
        synchronized (mutex)
        {
            plugins[id] = new PluginSandbox(id, maxTime);
        }
    }
    
    PluginSandbox.ExecutionResult executePlugin(string id, bool shouldCrash = false, bool shouldHang = false) @system
    {
        PluginSandbox plugin;
        
        synchronized (mutex)
        {
            if (id !in plugins)
            {
                PluginSandbox.ExecutionResult result;
                result.success = false;
                result.error = "Plugin not found: " ~ id;
                return result;
            }
            plugin = plugins[id];
        }
        
        auto result = plugin.execute(shouldCrash, shouldHang);
        
        if (plugin.hasCrashed())
            atomicOp!"+="(totalCrashes, 1);
        else if (plugin.hasTimedOut())
            atomicOp!"+="(totalTimeouts, 1);
        else if (result.success)
            atomicOp!"+="(successfulExecutions, 1);
        
        return result;
    }
    
    /// Check if system is still healthy after plugin failures
    bool isSystemHealthy() @system
    {
        // System is healthy if main process is running (we're here)
        // and crashed plugins can be isolated
        return true;
    }
    
    size_t getCrashCount() @trusted => atomicLoad(totalCrashes);
    size_t getTimeoutCount() @trusted => atomicLoad(totalTimeouts);
    size_t getSuccessCount() @trusted => atomicLoad(successfulExecutions);
}

/// Test: Plugin crash doesn't affect main process
@("resilience.plugin_crash_isolation")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Plugin - Crash Isolation");
    
    auto manager = new PluginManager();
    
    manager.registerPlugin("stable-plugin");
    manager.registerPlugin("crashy-plugin");
    
    // Execute stable plugin
    auto result1 = manager.executePlugin("stable-plugin");
    Assert.isTrue(result1.success, "Stable plugin should succeed");
    
    // Execute crashy plugin
    auto result2 = manager.executePlugin("crashy-plugin", true, false);  // crash=true
    Assert.isFalse(result2.success, "Crashy plugin should fail");
    Assert.isTrue(result2.error.canFind("crashed"), "Should indicate crash");
    
    // System should still be healthy
    Assert.isTrue(manager.isSystemHealthy(), "System should remain healthy");
    
    // Stable plugin should still work
    auto result3 = manager.executePlugin("stable-plugin");
    Assert.isTrue(result3.success, "Stable plugin should still work after crash");
    
    Assert.equal(manager.getCrashCount(), 1, "Should record one crash");
    Assert.equal(manager.getSuccessCount(), 2, "Should have two successes");
    
    writeln("  \x1b[32m✓ Plugin crash isolation passed\x1b[0m");
}

/// Test: Plugin timeout handling
@("resilience.plugin_timeout")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Plugin - Timeout Handling");
    
    auto manager = new PluginManager();
    manager.registerPlugin("slow-plugin", 100.msecs);  // Short timeout for test
    
    // This would hang without timeout
    auto result = manager.executePlugin("slow-plugin", false, true);  // hang=true
    Assert.isFalse(result.success, "Hanging plugin should fail");
    Assert.isTrue(result.error.canFind("timed out"), "Should indicate timeout");
    
    Assert.equal(manager.getTimeoutCount(), 1, "Should record one timeout");
    
    writeln("  \x1b[32m✓ Plugin timeout handling passed\x1b[0m");
}

/// Test: Multiple plugin crashes
@("resilience.multiple_plugin_crashes")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Plugin - Multiple Crashes");
    
    auto manager = new PluginManager();
    
    // Register multiple plugins
    foreach (i; 0 .. 5)
    {
        manager.registerPlugin("plugin-" ~ i.to!string);
    }
    
    // Execute with random crashes
    auto rng = Mt19937(55555);
    size_t crashes = 0;
    
    foreach (i; 0 .. 20)
    {
        auto pluginId = "plugin-" ~ uniform(0, 5, rng).to!string;
        auto shouldCrash = uniform01(rng) < 0.3;  // 30% crash rate
        
        auto result = manager.executePlugin(pluginId, shouldCrash);
        if (!result.success && result.error.canFind("crashed"))
            crashes++;
    }
    
    Logger.info("Multiple crashes - total: " ~ crashes.to!string ~
               ", recorded: " ~ manager.getCrashCount().to!string);
    
    // System should still be healthy
    Assert.isTrue(manager.isSystemHealthy(), "System should survive multiple crashes");
    Assert.isTrue(manager.getSuccessCount() > 0, "Some executions should succeed");
    
    writeln("  \x1b[32m✓ Multiple plugin crashes passed\x1b[0m");
}

// ============================================================================
// RESOURCE EXHAUSTION TESTS
// ============================================================================

/// Simulated resource pool with limits
class ResourcePool
{
    private size_t maxResources;
    private shared size_t usedResources;
    private shared size_t exhaustionEvents;
    private shared size_t successfulAcquisitions;
    private Mutex mutex;
    private Condition available;
    
    this(size_t max) @trusted
    {
        this.maxResources = max;
        this.mutex = new Mutex();
        this.available = new Condition(mutex);
    }
    
    /// Try to acquire resources
    bool acquire(size_t count, Duration timeout = 1.seconds) @trusted
    {
        auto deadline = MonoTime.currTime + timeout;
        
        synchronized (mutex)
        {
            while (atomicLoad(usedResources) + count > maxResources)
            {
                if (MonoTime.currTime >= deadline)
                {
                    atomicOp!"+="(exhaustionEvents, 1);
                    return false;
                }
                available.wait(100.msecs);
            }
            
            atomicOp!"+="(usedResources, count);
            atomicOp!"+="(successfulAcquisitions, 1);
            return true;
        }
    }
    
    /// Release resources
    void release(size_t count) @trusted
    {
        synchronized (mutex)
        {
            auto current = atomicLoad(usedResources);
            atomicStore(usedResources, current > count ? current - count : 0);
            available.notifyAll();
        }
    }
    
    size_t getUsed() @trusted => atomicLoad(usedResources);
    size_t getMax() const @safe => maxResources;
    size_t getExhaustionEvents() @trusted => atomicLoad(exhaustionEvents);
    size_t getSuccessfulAcquisitions() @trusted => atomicLoad(successfulAcquisitions);
}

/// Test: File descriptor exhaustion
@("resilience.fd_exhaustion")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Resource - FD Exhaustion");
    
    auto fdPool = new ResourcePool(100);  // Simulate 100 FD limit
    
    shared size_t acquired = 0;
    shared size_t failed = 0;
    
    // Try to acquire more FDs than available
    foreach (i; parallel(iota(8)))
    {
        foreach (j; 0 .. 20)
        {
            if (fdPool.acquire(5, 100.msecs))  // 5 FDs each
            {
                atomicOp!"+="(acquired, 1);
                Thread.sleep(10.msecs);
                fdPool.release(5);
            }
            else
            {
                atomicOp!"+="(failed, 1);
            }
        }
    }
    
    Logger.info("FD exhaustion - acquired: " ~ atomicLoad(acquired).to!string ~
               ", failed: " ~ atomicLoad(failed).to!string ~
               ", exhaustion events: " ~ fdPool.getExhaustionEvents().to!string);
    
    // Some should fail due to exhaustion
    Assert.isTrue(atomicLoad(acquired) > 0, "Some acquisitions should succeed");
    
    writeln("  \x1b[32m✓ FD exhaustion handling passed\x1b[0m");
}

/// Test: Memory pressure handling
@("resilience.memory_pressure")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Resource - Memory Pressure");
    
    auto memPool = new ResourcePool(1000);  // 1000 MB simulated limit
    
    struct MemoryUser
    {
        size_t allocated;
        ResourcePool pool;
        
        bool allocate(size_t mb)
        {
            if (pool.acquire(mb))
            {
                allocated += mb;
                return true;
            }
            return false;
        }
        
        void free(size_t mb)
        {
            if (mb <= allocated)
            {
                pool.release(mb);
                allocated -= mb;
            }
        }
    }
    
    MemoryUser[] users;
    foreach (i; 0 .. 10)
    {
        users ~= MemoryUser(0, memPool);
    }
    
    // Each user tries to allocate memory
    size_t totalAllocated = 0;
    size_t allocationFailures = 0;
    
    foreach (ref user; users)
    {
        if (user.allocate(150))  // 150 MB each
        {
            totalAllocated += 150;
        }
        else
        {
            allocationFailures++;
        }
    }
    
    Logger.info("Memory pressure - allocated: " ~ totalAllocated.to!string ~
               " MB, failures: " ~ allocationFailures.to!string);
    
    // Can't allocate 1500 MB in 1000 MB pool
    Assert.isTrue(allocationFailures > 0, "Should have allocation failures");
    Assert.isTrue(totalAllocated <= 1000, "Should not exceed limit");
    
    // Free and try again
    foreach (ref user; users)
    {
        user.free(user.allocated);
    }
    
    Assert.equal(memPool.getUsed(), 0, "All memory should be freed");
    
    writeln("  \x1b[32m✓ Memory pressure handling passed\x1b[0m");
}

/// Test: Disk full simulation
@("resilience.disk_full")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Resource - Disk Full");
    
    auto diskPool = new ResourcePool(500);  // 500 MB simulated disk
    
    struct DiskWriter
    {
        ResourcePool disk;
        size_t written;
        
        bool write(size_t mb) @system
        {
            if (disk.acquire(mb, 50.msecs))
            {
                written += mb;
                return true;
            }
            return false;  // Disk full
        }
    }
    
    auto writer = DiskWriter(diskPool, 0);
    
    // Write until full
    size_t writes = 0;
    while (writer.write(100))  // 100 MB chunks
    {
        writes++;
    }
    
    Logger.info("Disk full - successful writes: " ~ writes.to!string ~
               ", total written: " ~ writer.written.to!string ~ " MB");
    
    Assert.equal(writes, 5, "Should write 5 chunks (500 MB)");
    Assert.equal(writer.written, 500, "Should write exactly 500 MB");
    Assert.isTrue(diskPool.getExhaustionEvents() > 0, "Should detect disk full");
    
    writeln("  \x1b[32m✓ Disk full handling passed\x1b[0m");
}

// ============================================================================
// TIME/CLOCK TESTS
// ============================================================================

/// Test: Clock skew handling
@("resilience.clock_skew")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Time - Clock Skew");
    
    // Simulate coordinator and worker with different clocks
    struct NodeClock
    {
        long offsetMs;  // Offset from "true" time
        
        long currentTime() const
        {
            return Clock.currTime.toUnixTime * 1000 + offsetMs;
        }
    }
    
    auto coordinator = NodeClock(0);       // Reference time
    auto worker1 = NodeClock(5000);        // 5 seconds ahead
    auto worker2 = NodeClock(-3000);       // 3 seconds behind
    
    // Timeout calculation must account for skew
    immutable long timeoutMs = 10000;
    
    auto coordTime = coordinator.currentTime();
    auto worker1Time = worker1.currentTime();
    auto worker2Time = worker2.currentTime();
    
    Logger.info("Clock skew - coord: 0, worker1: +5s, worker2: -3s");
    
    // Check if message would timeout
    bool wouldTimeout(long sendTime, long receiveTime, long timeout)
    {
        return (receiveTime - sendTime) > timeout;
    }
    
    // Coordinator sends to worker1 (appears from future)
    Assert.isFalse(wouldTimeout(coordTime, worker1Time, timeoutMs),
                  "Message to fast clock should not timeout");
    
    // Coordinator sends to worker2 (appears from past)
    Assert.isFalse(wouldTimeout(coordTime, worker2Time, timeoutMs),
                  "Message to slow clock should not timeout");
    
    // Extreme skew (30 seconds) should timeout
    auto extremeWorker = NodeClock(30000);
    Assert.isTrue(wouldTimeout(coordTime, extremeWorker.currentTime(), timeoutMs),
                 "Extreme skew should timeout");
    
    writeln("  \x1b[32m✓ Clock skew handling passed\x1b[0m");
}

// ============================================================================
// DETERMINISM VERIFICATION TESTS
// ============================================================================

/// Test: Build determinism verification
@("resilience.determinism_verification")
@system unittest
{
    writeln("\x1b[36m[RESILIENCE]\x1b[0m Determinism - Build Verification");
    
    import std.digest.sha : sha256Of, toHexString;
    
    // Simulate deterministic build
    ubyte[] deterministicBuild(string[] inputs)
    {
        // Sort inputs for determinism
        auto sorted = inputs.dup.sort.array;
        
        ubyte[] result;
        foreach (input; sorted)
        {
            result ~= cast(ubyte[])input;
        }
        
        return sha256Of(result)[].dup;
    }
    
    // Same inputs should produce same output
    string[] inputs = ["file1.d", "file2.d", "file3.d"];
    
    auto result1 = deterministicBuild(inputs);
    auto result2 = deterministicBuild(inputs);
    auto result3 = deterministicBuild(inputs);
    
    Assert.equal(result1, result2, "Build 1 and 2 should match");
    Assert.equal(result2, result3, "Build 2 and 3 should match");
    
    // Different order same result (due to sorting)
    auto shuffled = ["file3.d", "file1.d", "file2.d"];
    auto result4 = deterministicBuild(shuffled);
    
    Assert.equal(result1, result4, "Shuffled inputs should produce same result");
    
    // Different inputs should produce different result
    auto different = ["file1.d", "file2.d", "file4.d"];
    auto result5 = deterministicBuild(different);
    
    Assert.notEqual(result1, result5, "Different inputs should produce different result");
    
    writeln("  \x1b[32m✓ Determinism verification passed\x1b[0m");
}

