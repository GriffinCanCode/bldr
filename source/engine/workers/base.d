module engine.workers.base;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.file;
import std.path;
import std.process;
import std.string;
import core.time : Duration, MonoTime, seconds, minutes, msecs;
import core.sync.mutex : Mutex;
import engine.workers.protocol;
import engine.workers.pool;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Base Persistent Worker Factory
/// 
/// Abstract base class providing common functionality for all persistent worker types.
/// Integrates with logging, metrics, warmth tracking, and memory monitoring.
/// 
/// Language-specific factories extend this and implement:
/// - `workerType()` - Unique identifier
/// - `buildWorkerArgs()` - Compiler-specific arguments
/// - `getExecutable()` - Path to compiler/runtime
/// - `buildEnvironment()` - Runtime-specific env vars
/// - `generateWorkerScript()` (optional) - Inline worker script
/// 
/// Common functionality provided:
/// - Process spawning with timeout handling
/// - Startup health checking
/// - Structured logging with worker context
/// - Metrics collection hooks
/// - Error handling with recovery
abstract class BasePersistentWorkerFactory : IWorkerFactory
{
    protected BaseWorkerConfig baseConfig;
    protected Mutex factoryMutex;
    protected size_t workersCreated;
    protected MonoTime lastCreation;
    
    /// Telemetry hooks for external metrics collection
    protected void delegate(WorkerId, string) onWorkerStarted;
    protected void delegate(WorkerId, string) onWorkerStopped;
    protected void delegate(WorkerId, Duration) onWorkerReady;
    protected void delegate(WorkerId, string) onWorkerError;
    
    this(BaseWorkerConfig config = BaseWorkerConfig.init) @trusted
    {
        this.baseConfig = config;
        this.factoryMutex = new Mutex();
    }
    
    /// Create a new worker instance with full lifecycle management
    Result!(PersistentWorker, WorkerError) createWorker(WorkerId id) @trusted
    {
        auto startTime = MonoTime.currTime;
        
        logWorkerEvent(id, "starting", LogFields.of(
            "worker_type", workerType(),
            "instance", id.instanceId.to!string
        ));
        
        // Get configuration
        auto cfg = defaultConfig();
        auto executable = getExecutable();
        auto args = buildWorkerArgs();
        auto env = buildEnvironment();
        
        // Validate executable exists
        if (!validateExecutable(executable))
        {
            auto err = new WorkerError(
                "Executable not found: " ~ executable,
                WorkerErrorCode.StartupFailed
            );
            logWorkerError(id, err);
            return Err!(PersistentWorker, WorkerError)(err);
        }
        
        // Spawn worker process
        auto spawnResult = spawnWorkerProcess(executable, args, cfg.workDir, env);
        if (spawnResult.isErr)
        {
            logWorkerError(id, spawnResult.unwrapErr());
            return Err!(PersistentWorker, WorkerError)(spawnResult.unwrapErr());
        }
        
        auto transport = spawnResult.unwrap();
        auto worker = new PersistentWorker(id, cfg, transport);
        
        // Wait for worker to signal ready
        auto readyResult = waitForWorkerReady(transport, cfg.startupTimeout);
        if (readyResult.isErr)
        {
            transport.close();
            logWorkerError(id, readyResult.unwrapErr());
            return Err!(PersistentWorker, WorkerError)(readyResult.unwrapErr());
        }
        
        worker.markReady();
        auto startupDuration = MonoTime.currTime - startTime;
        
        // Update factory stats
        synchronized (factoryMutex)
        {
            workersCreated++;
            lastCreation = MonoTime.currTime;
        }
        
        logWorkerEvent(id, "ready", LogFields.of(
            "startup_ms", startupDuration.total!"msecs".to!string,
            "executable", executable.baseName
        ));
        
        // Fire telemetry hook
        if (onWorkerReady !is null)
            onWorkerReady(id, startupDuration);
        
        return Ok!(PersistentWorker, WorkerError)(worker);
    }
    
    /// Get default configuration - override to customize timeouts/limits
    PersistentWorkerConfig defaultConfig() const @safe
    {
        PersistentWorkerConfig cfg;
        cfg.startupTimeout = baseConfig.startupTimeout;
        cfg.requestTimeout = baseConfig.requestTimeout;
        cfg.idleTimeout = baseConfig.idleTimeout;
        cfg.maxRequests = baseConfig.maxRequests;
        cfg.workDir = baseConfig.workDir;
        return cfg;
    }
    
    /// Abstract: Return unique worker type identifier (e.g., "rust-cargo", "go-build")
    abstract string workerType() const pure nothrow @safe;
    
    /// Abstract: Build compiler/runtime-specific arguments
    protected abstract string[] buildWorkerArgs() const @trusted;
    
    /// Abstract: Get path to compiler/runtime executable
    protected abstract string getExecutable() const @trusted;
    
    /// Build environment variables for worker process
    /// Override to add language-specific env vars
    protected string[string] buildEnvironment() const @trusted
    {
        string[string] env;
        
        // Copy base environment vars
        foreach (key, value; baseConfig.environment)
            env[key] = value;
        
        return env;
    }
    
    /// Validate executable exists and is runnable
    protected bool validateExecutable(string executable) const @trusted
    {
        // If it's a bare command, check if it exists in PATH
        if (!executable.canFind(dirSeparator.to!string))
        {
            try
            {
                auto result = execute(["which", executable]);
                return result.status == 0;
            }
            catch (Exception)
            {
                return false;
            }
        }
        
        return exists(executable);
    }
    
    /// Spawn worker process with transport
    protected Result!(StdioWorkerTransport, WorkerError) spawnWorkerProcess(
        string executable,
        string[] args,
        string workDir,
        string[string] env
    ) @trusted
    {
        return spawnWorkerTransport(executable, args, workDir, env);
    }
    
    /// Wait for worker to be ready - sends health check ping
    /// Override for language-specific ready detection
    protected Result!WorkerError waitForWorkerReady(
        StdioWorkerTransport transport,
        Duration timeout
    ) @trusted
    {
        // Default: send a simple version check request
        WorkRequest pingRequest;
        pingRequest.requestId = 0;
        pingRequest.arguments = getHealthCheckArgs();
        
        auto sendResult = transport.sendRequest(pingRequest);
        if (sendResult.isErr)
            return Result!WorkerError.err(sendResult.unwrapErr());
        
        auto recvResult = transport.receiveResponse(timeout);
        if (recvResult.isErr)
            return Result!WorkerError.err(recvResult.unwrapErr());
        
        return Result!WorkerError.ok();
    }
    
    /// Get health check arguments - override for language-specific checks
    protected string[] getHealthCheckArgs() const @safe
    {
        return ["--version"];
    }
    
    /// Log worker lifecycle event with structured fields
    protected void logWorkerEvent(WorkerId id, string event, LogFields fields = LogFields.init) @trusted
    {
        auto enriched = fields
            .add("worker_id", id.toString())
            .add("worker_type", workerType())
            .add("event", event);
        
        Logger.info("Worker " ~ event, enriched);
    }
    
    /// Log worker error with context
    protected void logWorkerError(WorkerId id, WorkerError err) @trusted
    {
        Logger.errorKV("Worker error",
            "worker_id", id.toString(),
            "worker_type", workerType(),
            "error_code", err.workerCode.to!string,
            "message", err.msg
        );
        
        if (onWorkerError !is null)
            onWorkerError(id, err.msg);
    }
    
    /// Set telemetry hooks for metrics collection
    void setTelemetryHooks(
        void delegate(WorkerId, string) started,
        void delegate(WorkerId, string) stopped,
        void delegate(WorkerId, Duration) ready,
        void delegate(WorkerId, string) error
    ) @safe
    {
        onWorkerStarted = started;
        onWorkerStopped = stopped;
        onWorkerReady = ready;
        onWorkerError = error;
    }
    
    /// Get factory statistics
    WorkerFactoryStats getStats() @trusted
    {
        synchronized (factoryMutex)
        {
            return WorkerFactoryStats(
                workerType(),
                workersCreated,
                lastCreation
            );
        }
    }
}

/// Base worker configuration shared across all worker types
struct BaseWorkerConfig
{
    Duration startupTimeout = seconds(30);   /// Max time to wait for worker startup
    Duration requestTimeout = minutes(5);    /// Max time for single request
    Duration idleTimeout = minutes(5);       /// Idle before eviction candidate
    size_t maxRequests = 5000;               /// Recycle after N requests
    string workDir;                          /// Working directory
    string[string] environment;              /// Environment variables
    
    // Cold start baseline for speedup calculation
    long coldStartMs = 500;                  /// Typical cold start time in ms
}

/// Factory statistics for monitoring
struct WorkerFactoryStats
{
    string workerType;
    size_t workersCreated;
    MonoTime lastCreation;
    
    /// Time since last worker was created
    Duration timeSinceLastCreation() const @safe
    {
        return MonoTime.currTime - lastCreation;
    }
}

/// Compilation result common to all worker types
struct WorkerCompilationResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool wasCached;
    string[] outputFiles;
    string[] diagnostics;
    
    /// Create success result
    static WorkerCompilationResult ok(string output, long execMs, string[] outputs = []) pure @safe
    {
        WorkerCompilationResult r;
        r.success = true;
        r.output = output;
        r.executionTimeMs = execMs;
        r.outputFiles = outputs;
        return r;
    }
    
    /// Create failure result
    static WorkerCompilationResult fail(string output, long execMs, string[] diags = []) pure @safe
    {
        WorkerCompilationResult r;
        r.success = false;
        r.output = output;
        r.executionTimeMs = execMs;
        r.diagnostics = diags;
        return r;
    }
}

/// Execute compilation via worker pool with standardized error handling
Result!(WorkerCompilationResult, WorkerError) executeOnWorker(
    WorkerPool pool,
    string workerType,
    string[] args,
    InputFile[] inputs = []
) @trusted
{
    auto result = pool.execute(workerType, args, inputs);
    
    if (result.isErr)
        return Err!(WorkerCompilationResult, WorkerError)(result.unwrapErr());
    
    auto response = result.unwrap();
    
    WorkerCompilationResult compResult;
    compResult.success = response.success;
    compResult.output = response.output;
    compResult.executionTimeMs = response.executionTimeMs;
    compResult.wasCached = response.wasCached;
    compResult.outputFiles = response.outputs.map!(o => o.path).array;
    
    return Ok!(WorkerCompilationResult, WorkerError)(compResult);
}


