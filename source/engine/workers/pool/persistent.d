module engine.workers.pool.persistent;

import std.algorithm : filter, map, canFind;
import std.array : array;
import std.conv : to;
import std.datetime : Duration;
import core.time : MonoTime, seconds, minutes, msecs;
import core.sync.mutex : Mutex;
import core.atomic;
import engine.workers.protocol;
import engine.workers.pool.manager;
import engine.workers.pool.recycler : WarmthLevel;
import engine.workers.jvm;
import engine.workers.go;
import engine.workers.python;
import infrastructure.config.schema.schema : TargetLanguage;
import infrastructure.errors : Errors, Internal, System, Language, BuildError, BuildResult, Err, Ok;
import infrastructure.utils.logging;

/// Persistent Worker Pool
/// 
/// High-level API for language handlers to amortize process startup costs
/// across multiple compilations. Provides per-language locking to ensure
/// thread-safe access to warm workers.
/// 
/// ## Supported Languages (with startup cost amortization)
/// 
/// | Language   | Cold Start | Warm Worker | Speedup |
/// |------------|------------|-------------|---------|
/// | Java       | 800ms      | 15-50ms     | 16-53x  |
/// | Kotlin     | 2000ms     | 30-100ms    | 20-67x  |
/// | Scala      | 1500ms     | 50-100ms    | 15-30x  |
/// | Go         | 100ms      | 20-40ms     | 2-5x    |
/// | Python/mypy| 1500ms     | 30-100ms    | 15-50x  |
/// 
/// ## Usage
/// 
/// ```d
/// auto pool = PersistentWorkerPool.create();
/// pool.start();
/// 
/// // Compile Java with warm worker
/// auto result = pool.execute(TargetLanguage.Java, ["src/Main.java", "-d", "bin/"]);
/// 
/// // Compile Go with warm worker
/// auto goResult = pool.execute(TargetLanguage.Go, ["build", "./..."]);
/// 
/// // Type-check Python
/// auto pyResult = pool.execute(TargetLanguage.Python, ["src/", "--strict"]);
/// 
/// pool.stop();
/// ```
/// 
/// ## Economics Integration
/// 
/// Tracks startup time savings for cost optimization:
/// - Records cold vs warm execution times
/// - Calculates amortized cost savings
/// - Feeds into build economics optimizer

/// Languages supported by persistent workers
enum WorkerLanguage
{
    Java,      /// javac - JVM
    Kotlin,    /// kotlinc - JVM
    Scala,     /// scalac - JVM
    Groovy,    /// groovyc - JVM
    Go,        /// go build/test
    Python,    /// mypy/ruff type checking
}

/// Configuration for persistent worker pool
struct PersistentPoolConfig
{
    size_t maxWorkersPerLanguage = 4;   /// Max concurrent workers per language
    Duration idleTimeout = minutes(10); /// Idle before eviction
    Duration warmupTime = seconds(2);   /// Time to consider worker "warmed"
    bool trackEconomics = true;         /// Track cost savings
    bool enableJVM = true;              /// Enable JVM workers (Java/Kotlin/Scala)
    bool enableGo = true;               /// Enable Go workers
    bool enablePython = true;           /// Enable Python workers
    size_t maxHeapMB = 2048;            /// Max JVM heap size
}

/// Execution result from worker
struct WorkerExecutionResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool usedWarmWorker;
    long coldStartSavedMs;    /// Startup time saved by using warm worker
    WarmthLevel warmthLevel;
    string[] outputFiles;
    
    /// Estimated speedup vs cold start
    float speedup() const pure nothrow @safe @nogc =>
        usedWarmWorker && executionTimeMs > 0 
            ? cast(float)(executionTimeMs + coldStartSavedMs) / executionTimeMs 
            : 1.0f;
}

/// Economics tracking for worker startup savings
struct WorkerEconomics
{
    size_t[WorkerLanguage] coldStarts;
    size_t[WorkerLanguage] warmExecutions;
    long[WorkerLanguage] totalSavedMs;
    long[WorkerLanguage] totalColdStartMs;
    
    /// Get estimated cold start time for language
    static long coldStartMs(WorkerLanguage lang) pure nothrow @safe @nogc
    {
        final switch (lang)
        {
            case WorkerLanguage.Java: return 800;
            case WorkerLanguage.Kotlin: return 2000;
            case WorkerLanguage.Scala: return 1500;
            case WorkerLanguage.Groovy: return 1000;
            case WorkerLanguage.Go: return 100;
            case WorkerLanguage.Python: return 1500;
        }
    }
    
    /// Record execution
    void record(WorkerLanguage lang, bool warm, long execMs) @safe
    {
        if (warm)
        {
            warmExecutions[lang] = warmExecutions.get(lang, 0) + 1;
            auto saved = coldStartMs(lang) - execMs;
            if (saved > 0)
                totalSavedMs[lang] = totalSavedMs.get(lang, 0) + saved;
        }
        else
        {
            coldStarts[lang] = coldStarts.get(lang, 0) + 1;
            totalColdStartMs[lang] = totalColdStartMs.get(lang, 0) + execMs;
        }
    }
    
    /// Total time saved across all languages
    long totalTimeSavedMs() const pure @safe
    {
        long total;
        foreach (saved; totalSavedMs)
            total += saved;
        return total;
    }
    
    /// Average speedup factor
    float averageSpeedup() const pure @safe
    {
        size_t totalExecs;
        float totalSpeedup;
        
        foreach (lang, count; warmExecutions)
        {
            if (count > 0)
            {
                totalExecs += count;
                auto avgExec = totalSavedMs.get(lang, 0) / count;
                auto cold = coldStartMs(lang);
                totalSpeedup += (cold > avgExec && avgExec > 0) 
                    ? cast(float)cold / avgExec * count 
                    : count;
            }
        }
        
        return totalExecs > 0 ? totalSpeedup / totalExecs : 1.0f;
    }
    
    /// Format summary for display
    string summary() const @safe
    {
        import std.format : format;
        
        size_t totalWarm, totalCold;
        foreach (w; warmExecutions) totalWarm += w;
        foreach (c; coldStarts) totalCold += c;
        
        return format(
            "Worker Economics:\n" ~
            "  Warm executions: %d\n" ~
            "  Cold starts: %d\n" ~
            "  Time saved: %.1fs\n" ~
            "  Avg speedup: %.1fx",
            totalWarm, totalCold,
            totalTimeSavedMs() / 1000.0,
            averageSpeedup()
        );
    }
}

/// Persistent Worker Pool - manages warm worker processes across builds
final class PersistentWorkerPool
{
    private PersistentPoolConfig config;
    private WorkerPool pool;
    private Mutex[WorkerLanguage] locks;
    private shared bool running;
    private WorkerEconomics economics;
    private Mutex economicsMutex;
    
    /// Create with default configuration
    static PersistentWorkerPool create(PersistentPoolConfig config = PersistentPoolConfig.init) @trusted
    {
        return new PersistentWorkerPool(config);
    }
    
    private this(PersistentPoolConfig config) @trusted
    {
        this.config = config;
        
        WorkerPoolConfig poolCfg;
        poolCfg.maxWorkersPerType = config.maxWorkersPerLanguage;
        poolCfg.idleTimeout = config.idleTimeout;
        poolCfg.maxHeapMB = config.maxHeapMB;
        poolCfg.enableMetrics = config.trackEconomics;
        poolCfg.enableRecycling = true;
        poolCfg.enableMemoryMonitor = true;
        poolCfg.persistAcrossBuilds = true;
        
        this.pool = new WorkerPool(poolCfg);
        this.economicsMutex = new Mutex();
        
        // Initialize per-language locks
        import std.traits : EnumMembers;
        static foreach (lang; EnumMembers!WorkerLanguage)
            locks[lang] = new Mutex();
    }
    
    /// Start the worker pool and register factories
    void start() @trusted
    {
        if (atomicLoad(running)) return;
        
        registerFactories();
        pool.start();
        atomicStore(running, true);
        
        structuredLog.info("persistent_worker_pool_started").emit();
    }
    
    /// Stop the worker pool
    void stop() @trusted
    {
        if (!atomicLoad(running)) return;
        
        atomicStore(running, false);
        pool.stop();
        
        if (config.trackEconomics)
        {
            auto summary = economics.summary();
            structuredLog.info("worker_economics_summary")
                .field("warm_executions", economics.warmExecutions.length)
                .field("time_saved_ms", economics.totalTimeSavedMs())
                .field("avg_speedup", economics.averageSpeedup())
                .emit();
        }
        
        structuredLog.info("persistent_worker_pool_stopped").emit();
    }
    
    /// Execute compilation with warm worker for specified language
    /// Uses per-language locking for thread safety
    BuildResult!WorkerExecutionResult execute(
        TargetLanguage lang,
        string[] args,
        InputFile[] inputs = []
    ) @trusted
    {
        auto workerLang = mapLanguage(lang);
        if (workerLang.isErr)
            return Err!(WorkerExecutionResult, BuildError)(workerLang.unwrapErr());
        
        return executeForLanguage(workerLang.unwrap(), args, inputs);
    }
    
    /// Execute for WorkerLanguage directly (bypasses TargetLanguage mapping)
    BuildResult!WorkerExecutionResult executeForLanguage(
        WorkerLanguage lang,
        string[] args,
        InputFile[] inputs = []
    ) @trusted
    {
        if (!atomicLoad(running))
            return Err!(WorkerExecutionResult, BuildError)(
                Errors.internal("Persistent worker pool not running", Internal.InvalidState).build());
        
        // Per-language lock ensures serialized access to workers of same type
        synchronized (locks[lang])
        {
            auto workerType = getWorkerType(lang);
            auto startTime = MonoTime.currTime;
            
            auto result = pool.execute(workerType, args, inputs);
            
            if (result.isErr)
            {
                // Track cold start fallback
                if (config.trackEconomics)
                {
                    synchronized (economicsMutex)
                        economics.record(lang, false, WorkerEconomics.coldStartMs(lang));
                }
                return Err!(WorkerExecutionResult, BuildError)(
                    Errors.system("Worker execution failed: " ~ result.unwrapErr().message(), System.ProcessSpawnFailed).build());
            }
            
            auto response = result.unwrap();
            auto execMs = response.executionTimeMs;
            
            // Get warmth from recycler
            WarmthLevel warmth = WarmthLevel.Cold;
            if (auto recycler = pool.getRecycler())
            {
                // Find worker ID for warmth check
                auto workerType2 = getWorkerType(lang);
                auto stats = pool.getStats();
                if (workerType2 in stats.activeWorkers && stats.activeWorkers[workerType2] > 0)
                    warmth = WarmthLevel.Warm;  // Approximation
            }
            
            bool warm = warmth >= WarmthLevel.Warming;
            long coldSaved = warm ? WorkerEconomics.coldStartMs(lang) - execMs : 0;
            if (coldSaved < 0) coldSaved = 0;
            
            // Track economics
            if (config.trackEconomics)
            {
                synchronized (economicsMutex)
                    economics.record(lang, warm, execMs);
            }
            
            return Ok!(WorkerExecutionResult, BuildError)(WorkerExecutionResult(
                response.success,
                response.output,
                execMs,
                warm,
                coldSaved,
                warmth,
                response.outputs.map!(o => o.path).array
            ));
        }
    }
    
    /// Get current economics data
    WorkerEconomics getEconomics() @trusted
    {
        synchronized (economicsMutex)
            return economics;
    }
    
    /// Get underlying pool for advanced usage
    WorkerPool getPool() @safe nothrow => pool;
    
    /// Check if running
    bool isRunning() const @safe nothrow => atomicLoad(running);
    
    // ==================== Private Helpers ====================
    
    private void registerFactories() @trusted
    {
        // JVM workers
        if (config.enableJVM)
        {
            foreach (compiler; [JVMCompiler.Javac, JVMCompiler.Kotlinc, 
                               JVMCompiler.Scalac, JVMCompiler.Groovyc])
            {
                JVMWorkerConfig cfg;
                cfg.compiler = compiler;
                cfg.maxHeapMB = config.maxHeapMB;
                pool.registerFactory(new JVMWorkerFactory(cfg));
            }
            structuredLog.debug_("registered_jvm_workers").emit();
        }
        
        // Go workers
        if (config.enableGo)
        {
            foreach (compiler; [GoCompiler.Build, GoCompiler.Test, GoCompiler.Vet])
            {
                GoWorkerConfig cfg;
                cfg.compiler = compiler;
                pool.registerFactory(new GoWorkerFactory(cfg));
            }
            structuredLog.debug_("registered_go_workers").emit();
        }
        
        // Python workers
        if (config.enablePython)
        {
            foreach (tool; [PythonTool.Mypy, PythonTool.Ruff, PythonTool.Pylint])
            {
                PythonWorkerConfig cfg;
                cfg.tool = tool;
                pool.registerFactory(new PythonWorkerFactory(cfg));
            }
            structuredLog.debug_("registered_python_workers").emit();
        }
    }
    
    /// Map TargetLanguage to WorkerLanguage
    private static BuildResult!WorkerLanguage mapLanguage(TargetLanguage lang) @trusted
    {
        switch (lang)
        {
            case TargetLanguage.Java: return Ok!(WorkerLanguage, BuildError)(WorkerLanguage.Java);
            case TargetLanguage.Kotlin: return Ok!(WorkerLanguage, BuildError)(WorkerLanguage.Kotlin);
            case TargetLanguage.Scala: return Ok!(WorkerLanguage, BuildError)(WorkerLanguage.Scala);
            case TargetLanguage.Go: return Ok!(WorkerLanguage, BuildError)(WorkerLanguage.Go);
            case TargetLanguage.Python: return Ok!(WorkerLanguage, BuildError)(WorkerLanguage.Python);
            default:
                return Err!(WorkerLanguage, BuildError)(
                    Errors.language(lang.to!string, "Language not supported by persistent workers", Language.NotSupported).build());
        }
    }
    
    /// Get worker type string for pool
    private static string getWorkerType(WorkerLanguage lang) pure nothrow @safe
    {
        final switch (lang)
        {
            case WorkerLanguage.Java: return "jvm-javac";
            case WorkerLanguage.Kotlin: return "jvm-kotlinc";
            case WorkerLanguage.Scala: return "jvm-scalac";
            case WorkerLanguage.Groovy: return "jvm-groovyc";
            case WorkerLanguage.Go: return "go-build";
            case WorkerLanguage.Python: return "python-mypy";
        }
    }
}

// ==================== Global Instance ====================

private __gshared PersistentWorkerPool globalPool;

/// Get or create global persistent worker pool
PersistentWorkerPool getPersistentPool() @trusted
{
    if (globalPool is null)
    {
        globalPool = PersistentWorkerPool.create();
        globalPool.start();
    }
    return globalPool;
}

/// Initialize global pool with custom config
void initPersistentPool(PersistentPoolConfig config) @trusted
{
    if (globalPool !is null)
        globalPool.stop();
    
    globalPool = PersistentWorkerPool.create(config);
    globalPool.start();
}

/// Shutdown global pool
void shutdownPersistentPool() @trusted
{
    if (globalPool !is null)
    {
        globalPool.stop();
        globalPool = null;
    }
}

/// Check if language benefits from persistent workers
bool supportsPersistentWorker(TargetLanguage lang) pure nothrow @safe
{
    return lang == TargetLanguage.Java ||
           lang == TargetLanguage.Kotlin ||
           lang == TargetLanguage.Scala ||
           lang == TargetLanguage.Go ||
           lang == TargetLanguage.Python;
}

/// Get estimated cold start time for language (milliseconds)
long estimatedColdStartMs(TargetLanguage lang) pure nothrow @safe
{
    switch (lang)
    {
        case TargetLanguage.Java: return 800;
        case TargetLanguage.Kotlin: return 2000;
        case TargetLanguage.Scala: return 1500;
        case TargetLanguage.Go: return 100;
        case TargetLanguage.Python: return 1500;
        default: return 0;
    }
}


