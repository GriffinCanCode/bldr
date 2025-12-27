module engine.workers.service;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import core.time : Duration, MonoTime, seconds, minutes, msecs;
import core.atomic;
import core.thread : Thread;
import infrastructure.utils.concurrency.structured : TaskScope, VoidTask;
import engine.workers.protocol;
import engine.workers.pool;
import engine.workers.pool.recycler : WarmthLevel;
import engine.workers.base;
import engine.workers.jvm;
import engine.workers.typescript;
import engine.workers.rust;
import engine.workers.go;
import engine.workers.python;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Persistent Worker Service
/// 
/// High-level service managing persistent workers for all supported languages.
/// Integrates with build system execution pipeline.
/// 
/// Supported Languages:
/// - JVM: javac, kotlinc, scalac, groovyc (10-50x speedup)
/// - TypeScript: tsc, swc, esbuild, bun (5-20x speedup)
/// - Rust: cargo build/check, rustc, clippy (3-15x speedup)
/// - Go: go build/test/vet/fmt (2-5x speedup)
/// - Python: mypy, ruff, pylint, black, pytest (3-20x speedup)
/// 
/// Features:
/// - Automatic worker lifecycle management
/// - Health monitoring and recovery
/// - Warmth-aware worker selection
/// - Memory monitoring with OOM prevention
/// - Metrics collection and speedup tracking

/// Worker service configuration
struct WorkerServiceConfig
{
    WorkerPoolConfig poolConfig;
    
    // Language toggles
    bool enableJVMWorkers = true;
    bool enableTSWorkers = true;
    bool enableRustWorkers = true;
    bool enableGoWorkers = true;
    bool enablePythonWorkers = true;
    
    // Language-specific configs
    JVMWorkerConfig jvmConfig;
    TSWorkerConfig tsConfig;
    RustWorkerConfig rustConfig;
    GoWorkerConfig goConfig;
    PythonWorkerConfig pythonConfig;
    
    Duration metricsInterval = seconds(30);
    bool enableAutoRecovery = true;
}

/// Service status
enum WorkerServiceStatus
{
    Stopped,
    Starting,
    Running,
    Degraded,
    Stopping
}

/// Service metrics with per-language breakdown
struct WorkerServiceMetrics
{
    size_t totalCompilations;
    size_t successfulCompilations;
    size_t failedCompilations;
    Duration totalSavedTime;
    float averageSpeedupFactor;
    WorkerPoolStats poolStats;
    MonoTime lastUpdated;
    
    // Per-language stats
    LanguageMetrics[string] byLanguage;
    
    // Recycling stats
    size_t warmWorkers;
    size_t hotWorkers;
    float warmthSpeedup;
    
    // Memory stats
    size_t workersAtOOMRisk;
    size_t oomRestarts;
}

/// Per-language metrics
struct LanguageMetrics
{
    size_t compilations;
    size_t successes;
    long avgExecutionMs;
    long coldStartMs;
    float speedup;
}

/// Persistent Worker Service
/// Uses structured concurrency via TaskScope for background task management
final class PersistentWorkerService
{
    private WorkerServiceConfig config;
    private WorkerPool pool;
    private WorkerServiceStatus status;
    private WorkerServiceMetrics metrics;
    private shared bool running;
    
    // Structured concurrency: TaskScope guarantees metrics thread cleanup
    private TaskScope taskScope;
    private VoidTask metricsTask;
    
    this(WorkerServiceConfig config = WorkerServiceConfig.init) @trusted
    {
        this.config = config;
        this.pool = new WorkerPool(config.poolConfig);
        this.status = WorkerServiceStatus.Stopped;
    }
    
    /// Start the worker service using structured concurrency
    void start() @trusted
    {
        if (status != WorkerServiceStatus.Stopped) return;
        
        status = WorkerServiceStatus.Starting;
        structuredLog.info("worker_service_starting").emit();
        
        registerJVMWorkers();
        registerTypeScriptWorkers();
        registerRustWorkers();
        registerGoWorkers();
        registerPythonWorkers();
        
        pool.start();
        
        atomicStore(running, true);
        
        // Create TaskScope for hierarchical task management
        taskScope = new TaskScope("worker-service");
        
        // Launch metrics as periodic structured task
        metricsTask = taskScope.launchPeriodic("metrics", config.metricsInterval, 
            () @trusted => metricsBody());
        
        status = WorkerServiceStatus.Running;
        
        auto langs = [
            config.enableJVMWorkers ? "JVM" : null,
            config.enableTSWorkers ? "TypeScript" : null,
            config.enableRustWorkers ? "Rust" : null,
            config.enableGoWorkers ? "Go" : null,
            config.enablePythonWorkers ? "Python" : null
        ].filter!(l => l !is null).array;
        
        structuredLog.info("worker_service_started")
            .field("languages", langs.join(","))
            .emit();
    }
    
    /// Register JVM worker factories
    private void registerJVMWorkers() @trusted
    {
        if (!config.enableJVMWorkers) return;
        
        foreach (compiler; [JVMCompiler.Javac, JVMCompiler.Kotlinc, JVMCompiler.Scalac, JVMCompiler.Groovyc])
        {
            auto cfg = config.jvmConfig;
            cfg.compiler = compiler;
            pool.registerFactory(new JVMWorkerFactory(cfg));
        }
        
        structuredLog.debug_("jvm_workers_registered")
            .field("compilers", "javac,kotlinc,scalac,groovyc")
            .emit();
    }
    
    /// Register TypeScript worker factories
    private void registerTypeScriptWorkers() @trusted
    {
        if (!config.enableTSWorkers) return;
        
        foreach (compiler; [TSCompilerType.TSC, TSCompilerType.SWC, TSCompilerType.ESBuild, TSCompilerType.Bun])
        {
            auto cfg = config.tsConfig;
            cfg.compiler = compiler;
            pool.registerFactory(new TypeScriptWorkerFactory(cfg));
        }
        
        structuredLog.debug_("typescript_workers_registered")
            .field("compilers", "tsc,swc,esbuild,bun")
            .emit();
    }
    
    /// Register Rust worker factories
    private void registerRustWorkers() @trusted
    {
        if (!config.enableRustWorkers) return;
        
        foreach (compiler; [RustCompiler.Cargo, RustCompiler.CargoCheck, RustCompiler.Rustc, RustCompiler.Clippy])
        {
            auto cfg = config.rustConfig;
            cfg.compiler = compiler;
            pool.registerFactory(new RustWorkerFactory(cfg));
        }
        
        structuredLog.debug_("rust_workers_registered")
            .field("compilers", "cargo,cargo-check,rustc,clippy")
            .emit();
    }
    
    /// Register Go worker factories
    private void registerGoWorkers() @trusted
    {
        if (!config.enableGoWorkers) return;
        
        foreach (compiler; [GoCompiler.Build, GoCompiler.Test, GoCompiler.Vet, GoCompiler.Fmt])
        {
            auto cfg = config.goConfig;
            cfg.compiler = compiler;
            pool.registerFactory(new GoWorkerFactory(cfg));
        }
        
        structuredLog.debug_("go_workers_registered")
            .field("compilers", "build,test,vet,fmt")
            .emit();
    }
    
    /// Register Python worker factories
    private void registerPythonWorkers() @trusted
    {
        if (!config.enablePythonWorkers) return;
        
        foreach (tool; [PythonTool.Mypy, PythonTool.Ruff, PythonTool.Pylint, PythonTool.Black, PythonTool.Pytest])
        {
            auto cfg = config.pythonConfig;
            cfg.tool = tool;
            pool.registerFactory(new PythonWorkerFactory(cfg));
        }
        
        structuredLog.debug_("python_workers_registered")
            .field("tools", "mypy,ruff,pylint,black,pytest")
            .emit();
    }
    
    /// Stop the worker service - TaskScope guarantees cleanup
    void stop() @trusted
    {
        if (status == WorkerServiceStatus.Stopped) return;
        
        status = WorkerServiceStatus.Stopping;
        structuredLog.info("worker_service_stopping").emit();
        
        atomicStore(running, false);
        
        // TaskScope ensures metrics task completes before continuing
        if (taskScope !is null)
        {
            taskScope.cancelAndJoin();
            taskScope = null;
        }
        
        pool.stop();
        
        status = WorkerServiceStatus.Stopped;
        structuredLog.info("worker_service_stopped").emit();
    }
    
    // ==================== JVM Compilation ====================
    
    Result!(CompilationResult, WorkerError) compileJava(
        string[] sources, string outputDir,
        string[] classpath = [], string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(CompilationResult)();
        
        auto result = compileWithJVMWorker(pool, JVMCompiler.Javac, sources, outputDir, classpath, options);
        recordCompilationMetrics("jvm-javac", result);
        return result;
    }
    
    Result!(CompilationResult, WorkerError) compileKotlin(
        string[] sources, string outputDir,
        string[] classpath = [], string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(CompilationResult)();
        
        auto result = compileWithJVMWorker(pool, JVMCompiler.Kotlinc, sources, outputDir, classpath, options);
        recordCompilationMetrics("jvm-kotlinc", result);
        return result;
    }
    
    Result!(CompilationResult, WorkerError) compileScala(
        string[] sources, string outputDir,
        string[] classpath = [], string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(CompilationResult)();
        
        auto result = compileWithJVMWorker(pool, JVMCompiler.Scalac, sources, outputDir, classpath, options);
        recordCompilationMetrics("jvm-scalac", result);
        return result;
    }
    
    // ==================== TypeScript Compilation ====================
    
    Result!(TSCompilationResult, WorkerError) compileTypeScript(
        string[] sources, string outDir,
        TSCompileOptions options = TSCompileOptions.init
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(TSCompilationResult)();
        
        auto result = compileWithTSWorker(pool, TSCompilerType.TSC, sources, outDir, options);
        recordTSMetrics("ts-tsc", result);
        return result;
    }
    
    Result!(TSCompilationResult, WorkerError) compileWithSWC(
        string[] sources, string outDir,
        TSCompileOptions options = TSCompileOptions.init
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(TSCompilationResult)();
        
        auto result = compileWithTSWorker(pool, TSCompilerType.SWC, sources, outDir, options);
        recordTSMetrics("ts-swc", result);
        return result;
    }
    
    // ==================== Rust Compilation ====================
    
    Result!(RustCompilationResult, WorkerError) buildRust(
        string manifestPath, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(RustCompilationResult)();
        
        auto result = compileWithRustWorker(pool, RustCompiler.Cargo, manifestPath, options);
        recordRustMetrics("rust-cargo", result);
        return result;
    }
    
    Result!(RustCompilationResult, WorkerError) checkRust(
        string manifestPath, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(RustCompilationResult)();
        
        auto result = compileWithRustWorker(pool, RustCompiler.CargoCheck, manifestPath, options);
        recordRustMetrics("rust-cargo-check", result);
        return result;
    }
    
    Result!(RustCompilationResult, WorkerError) lintRust(
        string manifestPath, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(RustCompilationResult)();
        
        auto result = compileWithRustWorker(pool, RustCompiler.Clippy, manifestPath, options);
        recordRustMetrics("rust-clippy", result);
        return result;
    }
    
    // ==================== Go Compilation ====================
    
    Result!(GoCompilationResult, WorkerError) buildGo(
        string[] packages, string outputPath = "", string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(GoCompilationResult)();
        
        auto result = compileWithGoWorker(pool, GoCompiler.Build, packages, outputPath, options);
        recordGoMetrics("go-build", result);
        return result;
    }
    
    Result!(GoCompilationResult, WorkerError) testGo(
        string[] packages, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(GoCompilationResult)();
        
        auto result = compileWithGoWorker(pool, GoCompiler.Test, packages, "", options);
        recordGoMetrics("go-test", result);
        return result;
    }
    
    Result!(GoCompilationResult, WorkerError) vetGo(
        string[] packages, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(GoCompilationResult)();
        
        auto result = compileWithGoWorker(pool, GoCompiler.Vet, packages, "", options);
        recordGoMetrics("go-vet", result);
        return result;
    }
    
    // ==================== Python Tools ====================
    
    Result!(PythonToolResult, WorkerError) typecheckPython(
        string[] paths, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(PythonToolResult)();
        
        auto result = runPythonTool(pool, PythonTool.Mypy, paths, options);
        recordPythonMetrics("python-mypy", result);
        return result;
    }
    
    Result!(PythonToolResult, WorkerError) lintPython(
        string[] paths, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(PythonToolResult)();
        
        auto result = runPythonTool(pool, PythonTool.Ruff, paths, options);
        recordPythonMetrics("python-ruff", result);
        return result;
    }
    
    Result!(PythonToolResult, WorkerError) testPython(
        string[] paths, string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return serviceNotRunningError!(PythonToolResult)();
        
        auto result = runPythonTool(pool, PythonTool.Pytest, paths, options);
        recordPythonMetrics("python-pytest", result);
        return result;
    }
    
    // ==================== Status & Metrics ====================
    
    WorkerServiceStatus getStatus() const @safe => status;
    
    WorkerServiceMetrics getMetrics() @trusted
    {
        metrics.poolStats = pool.getStats();
        metrics.lastUpdated = MonoTime.currTime;
        
        if (auto recycler = pool.getRecycler())
        {
            auto rStats = recycler.getStats();
            metrics.warmWorkers = rStats.byLevel.get(WarmthLevel.Warm, 0);
            metrics.hotWorkers = rStats.byLevel.get(WarmthLevel.Hot, 0);
            metrics.warmthSpeedup = recycler.estimatedSpeedup();
        }
        
        if (auto memMonitor = pool.getMemoryMonitor())
        {
            auto mStats = memMonitor.getStats();
            metrics.workersAtOOMRisk = mStats.atRisk + mStats.critical;
            metrics.oomRestarts = mStats.oomDetections;
        }
        
        return metrics;
    }
    
    /// Get speedup factor for specific compiler type
    float getSpeedupFactor(string compilerType) @trusted
    {
        if (compilerType !in metrics.byLanguage) return 1.0f;
        return metrics.byLanguage[compilerType].speedup;
    }
    
    /// Get worker pool (for advanced usage)
    WorkerPool getPool() @safe => pool;
    
    // ==================== Private Helpers ====================
    
    private static Result!(T, WorkerError) serviceNotRunningError(T)() @trusted
    {
        return Err!(T, WorkerError)(new WorkerError("Service not running", WorkerErrorCode.Unknown));
    }
    
    private void recordCompilationMetrics(string workerType, Result!(CompilationResult, WorkerError) result) @trusted
    {
        metrics.totalCompilations++;
        
        if (result.isOk)
        {
            auto r = result.unwrap();
            if (r.success) metrics.successfulCompilations++;
            else metrics.failedCompilations++;
            
            updateLanguageMetrics(workerType, r.success, r.executionTimeMs);
        }
        else
        {
            metrics.failedCompilations++;
        }
        
        updateAverageSpeedup();
    }
    
    private void recordTSMetrics(string workerType, Result!(TSCompilationResult, WorkerError) result) @trusted
    {
        metrics.totalCompilations++;
        
        if (result.isOk)
        {
            auto r = result.unwrap();
            if (r.success) metrics.successfulCompilations++;
            else metrics.failedCompilations++;
            
            updateLanguageMetrics(workerType, r.success, r.executionTimeMs);
        }
        else
        {
            metrics.failedCompilations++;
        }
        
        updateAverageSpeedup();
    }
    
    private void recordRustMetrics(string workerType, Result!(RustCompilationResult, WorkerError) result) @trusted
    {
        metrics.totalCompilations++;
        
        if (result.isOk)
        {
            auto r = result.unwrap();
            if (r.success) metrics.successfulCompilations++;
            else metrics.failedCompilations++;
            
            updateLanguageMetrics(workerType, r.success, r.executionTimeMs);
        }
        else
        {
            metrics.failedCompilations++;
        }
        
        updateAverageSpeedup();
    }
    
    private void recordGoMetrics(string workerType, Result!(GoCompilationResult, WorkerError) result) @trusted
    {
        metrics.totalCompilations++;
        
        if (result.isOk)
        {
            auto r = result.unwrap();
            if (r.success) metrics.successfulCompilations++;
            else metrics.failedCompilations++;
            
            updateLanguageMetrics(workerType, r.success, r.executionTimeMs);
        }
        else
        {
            metrics.failedCompilations++;
        }
        
        updateAverageSpeedup();
    }
    
    private void recordPythonMetrics(string workerType, Result!(PythonToolResult, WorkerError) result) @trusted
    {
        metrics.totalCompilations++;
        
        if (result.isOk)
        {
            auto r = result.unwrap();
            if (r.success) metrics.successfulCompilations++;
            else metrics.failedCompilations++;
            
            updateLanguageMetrics(workerType, r.success, r.executionTimeMs);
        }
        else
        {
            metrics.failedCompilations++;
        }
        
        updateAverageSpeedup();
    }
    
    private void updateLanguageMetrics(string workerType, bool success, long execMs) @trusted
    {
        if (workerType !in metrics.byLanguage)
        {
            metrics.byLanguage[workerType] = LanguageMetrics(0, 0, 0, getColdStartMs(workerType), 1.0f);
        }
        
        auto m = &metrics.byLanguage[workerType];
        m.compilations++;
        if (success) m.successes++;
        
        // Update rolling average
        m.avgExecutionMs = (m.avgExecutionMs * (m.compilations - 1) + execMs) / m.compilations;
        
        // Calculate speedup
        if (m.avgExecutionMs > 0)
            m.speedup = cast(float)m.coldStartMs / m.avgExecutionMs;
        
        // Update total saved time
        auto savedMs = m.coldStartMs - execMs;
        if (savedMs > 0)
            metrics.totalSavedTime += msecs(savedMs);
    }
    
    private static long getColdStartMs(string workerType) pure nothrow @safe @nogc
    {
        // Cold start estimates by worker type
        if (workerType.startsWith("jvm-javac")) return 800;
        if (workerType.startsWith("jvm-kotlinc")) return 2000;
        if (workerType.startsWith("jvm-scalac")) return 1500;
        if (workerType.startsWith("jvm-groovyc")) return 1000;
        if (workerType.startsWith("ts-tsc")) return 400;
        if (workerType.startsWith("ts-swc")) return 50;
        if (workerType.startsWith("ts-esbuild")) return 30;
        if (workerType.startsWith("ts-bun")) return 20;
        if (workerType.startsWith("rust-cargo")) return 800;
        if (workerType.startsWith("rust-cargo-check")) return 400;
        if (workerType.startsWith("rust-rustc")) return 200;
        if (workerType.startsWith("rust-clippy")) return 600;
        if (workerType.startsWith("go-")) return 100;
        if (workerType.startsWith("python-mypy")) return 1500;
        if (workerType.startsWith("python-ruff")) return 50;
        if (workerType.startsWith("python-pylint")) return 800;
        if (workerType.startsWith("python-black")) return 200;
        if (workerType.startsWith("python-pytest")) return 400;
        return 500;
    }
    
    private void updateAverageSpeedup() @trusted
    {
        if (metrics.totalCompilations == 0)
        {
            metrics.averageSpeedupFactor = 1.0f;
            return;
        }
        
        float totalSpeedup = 0;
        size_t count = 0;
        
        foreach (ref m; metrics.byLanguage)
        {
            if (m.compilations > 0)
            {
                totalSpeedup += m.speedup * m.compilations;
                count += m.compilations;
            }
        }
        
        metrics.averageSpeedupFactor = count > 0 ? totalSpeedup / count : 1.0f;
    }
    
    /// Metrics body (called periodically by TaskScope.launchPeriodic)
    private void metricsBody() @trusted
    {
        if (!atomicLoad(running)) return;
        
        auto stats = pool.getStats();
        metrics.poolStats = stats;
        metrics.lastUpdated = MonoTime.currTime;
        
        structuredLog.debug_("worker_service_metrics")
            .field("total_compilations", metrics.totalCompilations)
            .field("avg_speedup", metrics.averageSpeedupFactor)
            .field("time_saved_s", metrics.totalSavedTime.total!"seconds")
            .emit();
        
        // Check degraded state
        if (stats.totalFailures > stats.totalStartups / 4)
        {
            status = WorkerServiceStatus.Degraded;
            structuredLog.warning("worker_service_degraded")
                .field("reason", "high_failure_rate")
                .field("failures", stats.totalFailures)
                .field("startups", stats.totalStartups)
                .emit();
        }
        else if (status == WorkerServiceStatus.Degraded)
        {
            status = WorkerServiceStatus.Running;
        }
    }
}

// ==================== Global Service ====================

private __gshared PersistentWorkerService globalService;

PersistentWorkerService getWorkerService() @trusted
{
    if (globalService is null)
        globalService = new PersistentWorkerService();
    return globalService;
}

void initWorkerService(WorkerServiceConfig config) @trusted
{
    if (globalService !is null)
        globalService.stop();
    
    globalService = new PersistentWorkerService(config);
    globalService.start();
}

void shutdownWorkerService() @trusted
{
    if (globalService !is null)
    {
        globalService.stop();
        globalService = null;
    }
}

