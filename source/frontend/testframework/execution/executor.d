module frontend.testframework.execution.executor;

import std.algorithm : map, filter;
import std.array : array;
import std.conv : to;
import std.datetime : MonoTime;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.parallelism : parallel;
import core.atomic;
import infrastructure.config.schema.schema : Target, WorkspaceConfig;
import engine.runtime.services.container.services : BuildServices;
import languages.base.base : BuildContext;
import frontend.testframework.results;
import frontend.testframework.sharding;
import frontend.testframework.caching;
import frontend.testframework.flaky;
import infrastructure.utils.concurrency.scheduler;
import infrastructure.utils.logging.logger;

/// Test execution mode
enum TestExecutionMode
{
    Sequential,     // Run tests sequentially
    Parallel,       // Run tests in parallel (default)
    Sharded,        // Run tests with explicit sharding
    Distributed     // Distributed execution (future)
}

/// Test execution configuration
struct TestExecutionConfig
{
    TestExecutionMode mode = TestExecutionMode.Parallel;
    size_t maxParallelism = 0;              // 0 = auto-detect
    size_t shardCount = 0;                  // 0 = auto (based on CPU count)
    bool enableCaching = true;              // Enable test result caching
    bool enableRetry = true;                // Enable automatic retry
    bool enableSharding = true;             // Enable test sharding
    bool enableFlakyDetection = true;       // Enable flaky test detection
    bool skipQuarantined = false;           // Skip quarantined tests
    
    ShardConfig shardConfig;
    RetryPolicy retryPolicy;
    TestCacheConfig cacheConfig;
}

/// Advanced test executor
/// Integrates sharding, caching, retry, and flaky detection
final class TestExecutor
{
    private TestExecutionConfig config;
    private TestCache cache;
    private FlakyDetector detector;
    private RetryOrchestrator retryOrch;
    private ShardEngine shardEngine;
    private ShardCoordinator shardCoord;
    private WorkStealingScheduler!(TestTask) scheduler;
    
    // Statistics
    private shared size_t testsRun;
    private shared size_t testsPassed;
    private shared size_t testsFailed;
    private shared size_t testsSkipped;
    private shared size_t testsCached;
    
    /// Test task for scheduler
    private struct TestTask
    {
        string testId;
        Target target;
        TestShard shard;
    }
    
    this(TestExecutionConfig config) @system
    {
        this.config = config;
        
        // Initialize components
        if (config.enableCaching)
        {
            cache = new TestCache(".builder-cache/tests", config.cacheConfig);
        }
        
        if (config.enableFlakyDetection)
        {
            detector = new FlakyDetector();
        }
        
        if (config.enableRetry && detector !is null)
        {
            retryOrch = new RetryOrchestrator(config.retryPolicy, detector);
        }
        
        if (config.enableSharding)
        {
            shardEngine = new ShardEngine(config.shardConfig);
            shardCoord = new ShardCoordinator();
        }
        
        // Reset statistics
        atomicStore(testsRun, cast(size_t)0);
        atomicStore(testsPassed, cast(size_t)0);
        atomicStore(testsFailed, cast(size_t)0);
        atomicStore(testsSkipped, cast(size_t)0);
        atomicStore(testsCached, cast(size_t)0);
    }
    
    /// Execute test suite
    TestResult[] execute(
        Target[] testTargets,
        WorkspaceConfig wsConfig,
        BuildServices services
    ) @system
    {
        auto sw = StopWatch(AutoStart.yes);
        
        Logger.info("Executing " ~ testTargets.length.to!string ~ " test targets");
        
        // Filter quarantined tests
        if (config.skipQuarantined && detector !is null)
        {
            testTargets = testTargets.filter!(t => !detector.isQuarantined(t.name)).array;
            Logger.info("Filtered quarantined tests, " ~ testTargets.length.to!string ~ " remaining");
        }
        
        TestResult[] results;
        
        final switch (config.mode)
        {
            case TestExecutionMode.Sequential:
                results = executeSequential(testTargets, wsConfig, services);
                break;
            
            case TestExecutionMode.Parallel:
                results = executeParallel(testTargets, wsConfig, services);
                break;
            
            case TestExecutionMode.Sharded:
                results = executeSharded(testTargets, wsConfig, services);
                break;
            
            case TestExecutionMode.Distributed:
                // Future: distributed execution
                results = executeParallel(testTargets, wsConfig, services);
                break;
        }
        
        sw.stop();
        
        Logger.info("Test execution completed in " ~ sw.peek().total!"msecs".to!string ~ "ms");
        logStatistics();
        
        return results;
    }
    
    /// Execute tests sequentially
    private TestResult[] executeSequential(
        Target[] testTargets,
        WorkspaceConfig wsConfig,
        BuildServices services
    ) @system
    {
        TestResult[] results;
        results.reserve(testTargets.length);
        
        foreach (target; testTargets)
        {
            auto result = executeSingleTest(target, wsConfig, services);
            results ~= result;
        }
        
        return results;
    }
    
    /// Execute tests in parallel
    private TestResult[] executeParallel(
        Target[] testTargets,
        WorkspaceConfig wsConfig,
        BuildServices services
    ) @system
    {
        import std.parallelism : TaskPool, totalCPUs;
        
        immutable parallelism = config.maxParallelism == 0 ? totalCPUs : config.maxParallelism;
        Logger.info("Running tests with parallelism: " ~ parallelism.to!string);
        
        TestResult[] results;
        results.length = testTargets.length;
        
        foreach (i, target; parallel(testTargets))
        {
            results[i] = executeSingleTest(target, wsConfig, services);
        }
        
        return results;
    }
    
    /// Execute tests with sharding
    private TestResult[] executeSharded(
        Target[] testTargets,
        WorkspaceConfig wsConfig,
        BuildServices services
    ) @system
    {
        // Compute shards
        string[] testIds = testTargets.map!(t => t.name).array;
        auto shards = shardEngine.computeShards(testIds);
        
        Logger.info("Created " ~ shards.length.to!string ~ " test shards");
        
        // Log sharding statistics
        auto stats = shardEngine.computeStats(shards);
        Logger.info("Shard balance: " ~ stats.loadBalance.to!string);
        
        // Initialize coordinator
        shardCoord.initialize(shards);
        
        // Execute shards in parallel
        import std.parallelism : TaskPool, totalCPUs;
        
        immutable parallelism = config.maxParallelism == 0 ? totalCPUs : config.maxParallelism;
        
        TestResult[] results;
        results.reserve(testTargets.length);
        
        // Worker function
        void executeShardWorker(size_t workerId) @system
        {
            while (!shardCoord.isComplete())
            {
                // Claim next shard
                auto shardContext = shardCoord.claimShard(workerId);
                if (shardContext is null)
                    break;
                
                // Find target
                auto targetPtr = testTargets.filter!(t => t.name == shardContext.shard.testId).array;
                if (targetPtr.length == 0)
                    continue;
                
                // Execute test
                auto target = targetPtr[0];
                auto result = executeSingleTest(target, wsConfig, services);
                
                // Update coordinator
                if (result.passed)
                {
                    shardCoord.completeShard(target.name, cast(size_t)result.duration.total!"msecs");
                }
                else
                {
                    shardCoord.failShard(target.name);
                }
                
                synchronized
                {
                    results ~= result;
                }
            }
        }
        
        // Launch workers manually (task() doesn't work with nested functions)
        import core.thread : Thread;
        import core.time : msecs;
        Thread[] workers;
        foreach (workerId; 0 .. parallelism)
        {
            auto t = new Thread(() => executeShardWorker(workerId));
            t.start();
            workers ~= t;
        }
        
        // Wait for completion
        foreach (worker; workers)
        {
            worker.join();
        }
        
        return results;
    }
    
    /// Execute single test with caching and retry
    private TestResult executeSingleTest(
        Target target,
        WorkspaceConfig wsConfig,
        BuildServices services
    ) @system
    {
        auto sw = StopWatch(AutoStart.yes);
        
        // Check cache
        if (config.enableCaching && cache !is null)
        {
            immutable contentHash = computeTestContentHash(target);
            immutable envHash = computeTestEnvHash(wsConfig);
            
            if (cache.isCached(target.name, contentHash, envHash))
            {
                atomicOp!"+="(testsCached, 1);
                atomicOp!"+="(testsRun, 1);
                
                auto result = cache.get(target.name);
                Logger.debugLog("Test result from cache: " ~ target.name);
                return result;
            }
        }
        
        // Execute test
        TestResult result;
        
        if (config.enableRetry && retryOrch !is null)
        {
            // Execute with retry
            result = retryOrch.executeWithRetry(
                target.name,
                () => executeTestOnce(target, wsConfig, services)
            );
        }
        else
        {
            // Execute once
            result = executeTestOnce(target, wsConfig, services);
            
            // Record with detector
            if (detector !is null)
            {
                detector.recordExecution(target.name, result.passed);
            }
        }
        
        // Update statistics
        atomicOp!"+="(testsRun, 1);
        if (result.passed)
            atomicOp!"+="(testsPassed, 1);
        else
            atomicOp!"+="(testsFailed, 1);
        
        // Cache result if successful
        if (config.enableCaching && cache !is null && result.passed)
        {
            immutable contentHash = computeTestContentHash(target);
            immutable envHash = computeTestEnvHash(wsConfig);
            cache.put(target.name, contentHash, envHash, result);
        }
        
        return result;
    }
    
    /// Execute test once (no retry)
    private TestResult executeTestOnce(
        Target target,
        WorkspaceConfig wsConfig,
        BuildServices services
    ) @system
    {
        auto sw = StopWatch(AutoStart.yes);
        
        try
        {
            // Get language handler
            auto handler = services.registry.get(target.language);
            if (handler is null)
            {
                return TestResult.fail(
                    target.name,
                    sw.peek(),
                    "No language handler for: " ~ target.language.to!string
                );
            }
            
            // Build/run the test with context using service container (DI pattern)
            BuildContext buildContext;
            buildContext.target = target;
            buildContext.config = wsConfig;
            buildContext.services = services;  // Inject service container
            buildContext.incrementalEnabled = false;  // Tests always run fresh
            
            auto buildResult = handler.buildWithContext(buildContext);
            
            sw.stop();
            
            if (buildResult.isOk)
            {
                return TestResult.pass(target.name, sw.peek());
            }
            else
            {
                auto error = buildResult.unwrapErr();
                return TestResult.fail(target.name, sw.peek(), error.message());
            }
        }
        catch (Exception e)
        {
            sw.stop();
            return TestResult.fail(target.name, sw.peek(), "Exception: " ~ e.msg);
        }
    }
    
    /// Compute content hash for test
    private string computeTestContentHash(Target target) @trusted
    {
        import infrastructure.utils.crypto.blake3 : Blake3;
        import std.algorithm : joiner;
        
        // Hash test sources and dependencies
        string content = target.sources.joiner("\n").to!string;
        return Blake3.hashHex(content ~ target.language.to!string);
    }
    
    /// Compute environment hash
    private string computeTestEnvHash(WorkspaceConfig wsConfig) @trusted
    {
        import infrastructure.utils.crypto.blake3 : Blake3;
        
        // Simple environment hash (can be extended)
        return Blake3.hashHex(wsConfig.root);
    }
    
    /// Log execution statistics
    private void logStatistics() @system
    {
        Logger.info("═══ Test Execution Statistics ═══");
        Logger.info("  Total tests:    " ~ atomicLoad(testsRun).to!string);
        Logger.info("  Passed:         " ~ atomicLoad(testsPassed).to!string);
        Logger.info("  Failed:         " ~ atomicLoad(testsFailed).to!string);
        Logger.info("  Skipped:        " ~ atomicLoad(testsSkipped).to!string);
        Logger.info("  Cached:         " ~ atomicLoad(testsCached).to!string);
        
        if (cache !is null)
        {
            auto cacheStats = cache.getStats();
            Logger.info("  Cache hit rate: " ~ (cacheStats.hitRate * 100).to!string ~ "%");
        }
        
        if (detector !is null)
        {
            auto detectorStats = detector.getStats();
            Logger.info("  Flaky tests:    " ~ detectorStats.flakyTests.to!string);
            Logger.info("  Quarantined:    " ~ detectorStats.quarantinedTests.to!string);
        }
    }
    
    /// Get flaky detector instance
    @property FlakyDetector flakyDetector() @safe nothrow @nogc
    {
        return detector;
    }
    
    /// Shutdown and cleanup
    void shutdown() @system
    {
        if (cache !is null)
        {
            cache.flush();
        }
    }
}

