module engine.workers.service;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import core.time : Duration, MonoTime, seconds, minutes;
import core.atomic;
import core.thread : Thread;
import engine.workers.protocol;
import engine.workers.pool;
import engine.workers.jvm;
import engine.workers.typescript;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Persistent Worker Service
/// 
/// High-level service that manages persistent workers and integrates
/// with the build system's execution pipeline.
/// 
/// Features:
/// - Automatic worker lifecycle management
/// - Health monitoring and recovery
/// - Metrics collection
/// - Integration hooks for language handlers

/// Worker service configuration
struct WorkerServiceConfig
{
    WorkerPoolConfig poolConfig;
    bool enableJVMWorkers = true;
    bool enableTSWorkers = true;
    JVMWorkerConfig jvmConfig;
    TSWorkerConfig tsConfig;
    Duration metricsInterval = seconds(30);
    bool enableAutoRecovery = true;
}

/// Service status
enum WorkerServiceStatus
{
    Stopped,
    Starting,
    Running,
    Degraded,  // Some workers failed
    Stopping
}

/// Service metrics
struct WorkerServiceMetrics
{
    size_t totalCompilations;
    size_t successfulCompilations;
    size_t failedCompilations;
    Duration totalSavedTime;        // Estimated time saved vs cold starts
    float averageSpeedupFactor;
    WorkerPoolStats poolStats;
    MonoTime lastUpdated;
    
    /// Estimate total time saved
    Duration estimateSavedTime(size_t compilations, Duration avgColdStart, Duration avgWarmStart) const pure @safe
    {
        auto savedPerCompilation = avgColdStart > avgWarmStart ? avgColdStart - avgWarmStart : Duration.zero;
        return savedPerCompilation * compilations;
    }
}

/// Persistent Worker Service
final class PersistentWorkerService
{
    private WorkerServiceConfig config;
    private WorkerPool pool;
    private WorkerServiceStatus status;
    private WorkerServiceMetrics metrics;
    private Thread metricsThread;
    private shared bool running;
    
    // Cold start baselines for speedup calculation (in milliseconds)
    private immutable long jvmColdStartMs = 800;
    private immutable long kotlinColdStartMs = 2000;
    private immutable long tscColdStartMs = 400;
    
    this(WorkerServiceConfig config = WorkerServiceConfig.init) @trusted
    {
        this.config = config;
        this.pool = new WorkerPool(config.poolConfig);
        this.status = WorkerServiceStatus.Stopped;
    }
    
    /// Start the worker service
    void start() @trusted
    {
        if (status != WorkerServiceStatus.Stopped)
            return;
        
        status = WorkerServiceStatus.Starting;
        Logger.info("Starting persistent worker service");
        
        // Register worker factories
        if (config.enableJVMWorkers)
        {
            // Register javac worker
            auto javacConfig = config.jvmConfig;
            javacConfig.compiler = JVMCompiler.Javac;
            pool.registerFactory(new JVMWorkerFactory(javacConfig));
            
            // Register kotlinc worker
            auto kotlincConfig = config.jvmConfig;
            kotlincConfig.compiler = JVMCompiler.Kotlinc;
            pool.registerFactory(new JVMWorkerFactory(kotlincConfig));
            
            // Register scalac worker
            auto scalacConfig = config.jvmConfig;
            scalacConfig.compiler = JVMCompiler.Scalac;
            pool.registerFactory(new JVMWorkerFactory(scalacConfig));
            
            Logger.info("Registered JVM worker factories (javac, kotlinc, scalac)");
        }
        
        if (config.enableTSWorkers)
        {
            // Register tsc worker
            auto tscConfig = config.tsConfig;
            tscConfig.compiler = TSCompilerType.TSC;
            pool.registerFactory(new TypeScriptWorkerFactory(tscConfig));
            
            // Register swc worker
            auto swcConfig = config.tsConfig;
            swcConfig.compiler = TSCompilerType.SWC;
            pool.registerFactory(new TypeScriptWorkerFactory(swcConfig));
            
            // Register esbuild worker
            auto esbuildConfig = config.tsConfig;
            esbuildConfig.compiler = TSCompilerType.ESBuild;
            pool.registerFactory(new TypeScriptWorkerFactory(esbuildConfig));
            
            Logger.info("Registered TypeScript worker factories (tsc, swc, esbuild)");
        }
        
        // Start the pool
        pool.start();
        
        // Start metrics collection
        atomicStore(running, true);
        metricsThread = new Thread(&metricsLoop);
        metricsThread.start();
        
        status = WorkerServiceStatus.Running;
        Logger.info("Persistent worker service started");
    }
    
    /// Stop the worker service
    void stop() @trusted
    {
        if (status == WorkerServiceStatus.Stopped)
            return;
        
        status = WorkerServiceStatus.Stopping;
        Logger.info("Stopping persistent worker service");
        
        atomicStore(running, false);
        
        if (metricsThread !is null)
        {
            metricsThread.join();
            metricsThread = null;
        }
        
        pool.stop();
        
        status = WorkerServiceStatus.Stopped;
        Logger.info("Persistent worker service stopped");
    }
    
    /// Compile Java sources using persistent worker
    Result!(CompilationResult, WorkerError) compileJava(
        string[] sources,
        string outputDir,
        string[] classpath = [],
        string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return Err!(CompilationResult, WorkerError)(
                new WorkerError("Service not running", WorkerErrorCode.Unknown));
        
        auto result = compileWithJVMWorker(pool, JVMCompiler.Javac, sources, outputDir, classpath, options);
        recordMetrics(result);
        return result;
    }
    
    /// Compile Kotlin sources using persistent worker
    Result!(CompilationResult, WorkerError) compileKotlin(
        string[] sources,
        string outputDir,
        string[] classpath = [],
        string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return Err!(CompilationResult, WorkerError)(
                new WorkerError("Service not running", WorkerErrorCode.Unknown));
        
        auto result = compileWithJVMWorker(pool, JVMCompiler.Kotlinc, sources, outputDir, classpath, options);
        recordMetrics(result);
        return result;
    }
    
    /// Compile Scala sources using persistent worker
    Result!(CompilationResult, WorkerError) compileScala(
        string[] sources,
        string outputDir,
        string[] classpath = [],
        string[] options = []
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return Err!(CompilationResult, WorkerError)(
                new WorkerError("Service not running", WorkerErrorCode.Unknown));
        
        auto result = compileWithJVMWorker(pool, JVMCompiler.Scalac, sources, outputDir, classpath, options);
        recordMetrics(result);
        return result;
    }
    
    /// Compile TypeScript sources using persistent worker
    Result!(TSCompilationResult, WorkerError) compileTypeScript(
        string[] sources,
        string outDir,
        TSCompileOptions options = TSCompileOptions.init
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return Err!(TSCompilationResult, WorkerError)(
                new WorkerError("Service not running", WorkerErrorCode.Unknown));
        
        auto result = compileWithTSWorker(pool, TSCompilerType.TSC, sources, outDir, options);
        recordTSMetrics(result);
        return result;
    }
    
    /// Compile TypeScript with SWC (faster, no type checking)
    Result!(TSCompilationResult, WorkerError) compileTypeScriptWithSWC(
        string[] sources,
        string outDir,
        TSCompileOptions options = TSCompileOptions.init
    ) @trusted
    {
        if (status != WorkerServiceStatus.Running)
            return Err!(TSCompilationResult, WorkerError)(
                new WorkerError("Service not running", WorkerErrorCode.Unknown));
        
        auto result = compileWithTSWorker(pool, TSCompilerType.SWC, sources, outDir, options);
        recordTSMetrics(result);
        return result;
    }
    
    /// Get current service status
    WorkerServiceStatus getStatus() const @safe
    {
        return status;
    }
    
    /// Get service metrics
    WorkerServiceMetrics getMetrics() @trusted
    {
        metrics.poolStats = pool.getStats();
        metrics.lastUpdated = MonoTime.currTime;
        return metrics;
    }
    
    /// Get estimated speedup factor for a compiler type
    float getSpeedupFactor(string compilerType) @trusted
    {
        auto stats = pool.getStats();
        
        long coldStartMs;
        if (compilerType.startsWith("jvm-javac"))
            coldStartMs = jvmColdStartMs;
        else if (compilerType.startsWith("jvm-kotlin"))
            coldStartMs = kotlinColdStartMs;
        else if (compilerType.startsWith("ts-"))
            coldStartMs = tscColdStartMs;
        else
            coldStartMs = 500;  // Default estimate
        
        return stats.estimatedSpeedup(compilerType, coldStartMs);
    }
    
    /// Record compilation metrics
    private void recordMetrics(Result!(CompilationResult, WorkerError) result) @trusted
    {
        metrics.totalCompilations++;
        
        if (result.isOk)
        {
            auto r = result.unwrap();
            if (r.success)
                metrics.successfulCompilations++;
            else
                metrics.failedCompilations++;
            
            // Estimate time saved
            auto savedMs = jvmColdStartMs - r.executionTimeMs;
            if (savedMs > 0)
                metrics.totalSavedTime += msecs(savedMs);
        }
        else
        {
            metrics.failedCompilations++;
        }
        
        updateAverageSpeedup();
    }
    
    /// Record TypeScript compilation metrics
    private void recordTSMetrics(Result!(TSCompilationResult, WorkerError) result) @trusted
    {
        metrics.totalCompilations++;
        
        if (result.isOk)
        {
            auto r = result.unwrap();
            if (r.success)
                metrics.successfulCompilations++;
            else
                metrics.failedCompilations++;
            
            // Estimate time saved
            auto savedMs = tscColdStartMs - r.executionTimeMs;
            if (savedMs > 0)
                metrics.totalSavedTime += msecs(savedMs);
        }
        else
        {
            metrics.failedCompilations++;
        }
        
        updateAverageSpeedup();
    }
    
    /// Update average speedup calculation
    private void updateAverageSpeedup() @trusted
    {
        if (metrics.totalCompilations == 0)
        {
            metrics.averageSpeedupFactor = 1.0f;
            return;
        }
        
        // Calculate based on saved time
        auto avgColdMs = (jvmColdStartMs + tscColdStartMs) / 2;
        auto totalExpectedMs = metrics.totalCompilations * avgColdMs;
        auto actualMs = totalExpectedMs - metrics.totalSavedTime.total!"msecs";
        
        if (actualMs > 0)
            metrics.averageSpeedupFactor = cast(float)totalExpectedMs / actualMs;
        else
            metrics.averageSpeedupFactor = 1.0f;
    }
    
    /// Metrics collection loop
    private void metricsLoop() @trusted
    {
        while (atomicLoad(running))
        {
            Thread.sleep(config.metricsInterval);
            
            if (!atomicLoad(running))
                break;
            
            // Update metrics
            auto stats = pool.getStats();
            metrics.poolStats = stats;
            metrics.lastUpdated = MonoTime.currTime;
            
            // Log periodic stats
            Logger.debugLog("Worker service stats: " ~ 
                metrics.totalCompilations.to!string ~ " compilations, " ~
                metrics.averageSpeedupFactor.to!string ~ "x avg speedup, " ~
                metrics.totalSavedTime.total!"seconds".to!string ~ "s total saved");
            
            // Check for degraded state
            if (stats.totalFailures > stats.totalStartups / 4)
            {
                status = WorkerServiceStatus.Degraded;
                Logger.warning("Worker service degraded: high failure rate");
            }
            else if (status == WorkerServiceStatus.Degraded)
            {
                status = WorkerServiceStatus.Running;
            }
        }
    }
}

/// Global worker service instance (optional singleton pattern)
private __gshared PersistentWorkerService globalService;

/// Get or create the global worker service
PersistentWorkerService getWorkerService() @trusted
{
    if (globalService is null)
    {
        globalService = new PersistentWorkerService();
    }
    return globalService;
}

/// Initialize the global worker service with custom config
void initWorkerService(WorkerServiceConfig config) @trusted
{
    if (globalService !is null)
        globalService.stop();
    
    globalService = new PersistentWorkerService(config);
    globalService.start();
}

/// Shutdown the global worker service
void shutdownWorkerService() @trusted
{
    if (globalService !is null)
    {
        globalService.stop();
        globalService = null;
    }
}

