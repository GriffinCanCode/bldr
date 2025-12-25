module engine.runtime.remote.core.executor;

import std.datetime : Duration, Clock, MonoTime, minutes, msecs;
import std.algorithm : map;
import std.array : array;
import std.conv : to;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import engine.distributed.protocol.protocol;
import engine.distributed.coordinator.coordinator;
import engine.distributed.coordinator.scheduler;
import engine.runtime.hermetic;
import engine.runtime.remote.serialization.codec : HermeticSpecCodec;
import engine.runtime.remote.artifacts.manager : ArtifactManager;
import engine.caching.distributed.remote.client;
import engine.distributed.storage.store : ArtifactStore;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Remote executor - executes actions on remote workers using native hermetic sandboxing
///
/// Design Philosophy:
/// - Ship SandboxSpec to workers (not containers)
/// - Workers use native OS sandboxing (namespaces/sandbox-exec/job objects)
/// - Zero container runtime overhead
/// - Leverage existing hermetic infrastructure
///
/// Flow:
/// 1. Build SandboxSpec from action
/// 2. Upload inputs to artifact store
/// 3. Send ActionRequest + SandboxSpec to worker
/// 4. Worker executes hermetically using native backend
/// 5. Worker uploads outputs to artifact store
/// 6. Return results

/// Remote execution configuration
struct RemoteExecutorConfig
{
    string coordinatorUrl;              // Coordinator endpoint
    string artifactStoreUrl;            // Artifact store endpoint
    bool enableCaching = true;          // Use action cache?
    bool enableCompression = true;      // Compress artifacts?
    size_t maxConcurrent = 100;         // Max concurrent executions
    Duration defaultTimeout = minutes(5);
}

/// Remote execution result
struct RemoteExecutionResult
{
    ActionId actionId;
    ResultStatus status;
    Duration duration;
    string stdout;
    string stderr;
    int exitCode;
    ResourceUsage resources;
    ArtifactId[] outputArtifacts;
    bool fromCache;
    WorkerId executedBy;
}

/// Action completion tracker for async operations
private final class ActionCompletionTracker
{
    private struct CompletionInfo
    {
        bool completed;
        ActionResult result;
        BuildError error;
        Mutex mutex;
        Condition condition;
    }
    
    private CompletionInfo[ActionId] pending;
    private Mutex trackerMutex;
    
    this() @trusted
    {
        trackerMutex = new Mutex();
    }
    
    /// Register action for tracking
    void register(ActionId actionId) @trusted
    {
        synchronized (trackerMutex)
        {
            CompletionInfo info;
            info.completed = false;
            info.mutex = new Mutex();
            info.condition = new Condition(info.mutex);
            pending[actionId] = info;
        }
    }
    
    /// Wait for action completion with timeout
    BuildResult!ActionResult wait(ActionId actionId, Duration timeout) @trusted
    {
        CompletionInfo* info;
        
        synchronized (trackerMutex)
        {
            info = actionId in pending;
            if (info is null)
            {
                return Err!(ActionResult, BuildError)(
                    new GenericError("Action not registered: " ~ actionId.toString(), 
                                   ErrorCode.InternalError));
            }
        }
        
        // Wait on the action's condition variable
        synchronized (info.mutex)
        {
            immutable startTime = MonoTime.currTime;
            
            while (!info.completed)
            {
                immutable elapsed = MonoTime.currTime - startTime;
                if (elapsed >= timeout)
                {
                    return Err!(ActionResult, BuildError)(
                        new GenericError("Action timed out: " ~ actionId.toString(),
                                       ErrorCode.ProcessTimeout));
                }
                
                immutable remaining = timeout - elapsed;
                info.condition.wait(remaining);
            }
            
            // Action completed - return result
            if (info.error !is null)
                return Err!(ActionResult, BuildError)(info.error);
            
            return Ok!(ActionResult, BuildError)(info.result);
        }
    }
    
    /// Notify completion (success)
    void notifyComplete(ActionId actionId, ActionResult result) @trusted
    {
        CompletionInfo* info;
        
        synchronized (trackerMutex)
        {
            info = actionId in pending;
            if (info is null)
                return;
        }
        
        synchronized (info.mutex)
        {
            info.completed = true;
            info.result = result;
            info.condition.notifyAll();
        }
    }
    
    /// Notify completion (failure)
    void notifyError(ActionId actionId, BuildError error) @trusted
    {
        CompletionInfo* info;
        
        synchronized (trackerMutex)
        {
            info = actionId in pending;
            if (info is null)
                return;
        }
        
        synchronized (info.mutex)
        {
            info.completed = true;
            info.error = error;
            info.condition.notifyAll();
        }
    }
    
    /// Cleanup completed action
    void cleanup(ActionId actionId) @trusted
    {
        synchronized (trackerMutex)
        {
            pending.remove(actionId);
        }
    }
}

/// Remote executor
/// 
/// Responsibility: Orchestrate remote execution flow
/// Delegates artifact management to ArtifactManager (SRP)
final class RemoteExecutor
{
    private RemoteExecutorConfig config;
    private Coordinator coordinator;
    private ArtifactManager artifactManager;
    private ActionCompletionTracker completionTracker;
    
    this(RemoteExecutorConfig config) @trusted
    {
        this.config = config;
        
        // Initialize artifact store client
        import engine.caching.distributed.remote.protocol : RemoteCacheConfig;
        
        RemoteCacheConfig cacheConfig;
        cacheConfig.url = config.artifactStoreUrl;
        cacheConfig.enableCompression = config.enableCompression;
        
        auto cacheClient = new RemoteCacheClient(cacheConfig);
        
        // Initialize artifact manager (SRP: separated from execution orchestration)
        this.artifactManager = new ArtifactManager(cacheClient);
        
        // Initialize completion tracker for async operations
        this.completionTracker = new ActionCompletionTracker();
    }
    
    /// Execute action remotely
    BuildResult!RemoteExecutionResult execute(
        ActionId actionId,
        SandboxSpec spec,
        string[] command,
        string workDir
    ) @trusted
    {
        auto startTime = MonoTime.currTime;
        
        Logger.info("Remote execution: " ~ actionId.toString());
        
        // 1. Check action cache
        if (config.enableCaching)
        {
            auto cacheResult = checkActionCache(actionId);
            if (cacheResult.isOk)
            {
                auto cached = cacheResult.unwrap();
                Logger.info("Action cache hit: " ~ actionId.toString());
                return Ok!(RemoteExecutionResult, BuildError)(cached);
            }
        }
        
        // 2. Upload input artifacts (delegated to ArtifactManager)
        auto uploadResult = artifactManager.uploadInputs(spec);
        if (uploadResult.isErr)
        {
            return Err!(RemoteExecutionResult, BuildError)(uploadResult.unwrapErr());
        }
        
        auto inputArtifacts = uploadResult.unwrap();
        
        // 3. Build action request with hermetic spec
        auto request = buildActionRequest(
            actionId,
            spec,
            command,
            inputArtifacts
        );
        
        // 4. Submit to coordinator for execution
        auto executeResult = submitToWorker(request);
        if (executeResult.isErr)
        {
            return Err!(RemoteExecutionResult, BuildError)(executeResult.unwrapErr());
        }
        
        auto builderResult = executeResult.unwrap();
        
        // 5. Download output artifacts (delegated to ArtifactManager)
        auto downloadResult = artifactManager.downloadOutputs(builderResult.outputs);
        if (downloadResult.isErr)
        {
            return Err!(RemoteExecutionResult, BuildError)(downloadResult.unwrapErr());
        }
        
        // 6. Build result
        RemoteExecutionResult result;
        result.actionId = actionId;
        result.status = builderResult.status;
        result.duration = builderResult.duration;
        result.stdout = builderResult.stdout;
        result.stderr = builderResult.stderr;
        result.exitCode = builderResult.exitCode;
        result.resources = builderResult.resources;
        result.outputArtifacts = builderResult.outputs;
        result.fromCache = false;
        
        // 7. Cache result if successful
        if (config.enableCaching && result.status == ResultStatus.Success)
        {
            cacheActionResult(actionId, result);
        }
        
        immutable totalDuration = MonoTime.currTime - startTime;
        Logger.info("Remote execution completed in " ~ 
                   totalDuration.total!"msecs".to!string ~ "ms");
        
        return Ok!(RemoteExecutionResult, BuildError)(result);
    }
    
    /// Build action request from hermetic spec
    private ActionRequest buildActionRequest(
        ActionId actionId,
        SandboxSpec spec,
        string[] command,
        InputSpec[] inputs
    ) @safe
    {
        import std.algorithm : joiner;
        
        // Convert command array to shell command
        immutable cmdStr = command.joiner(" ").array.to!string;
        
        // Build output specs from hermetic spec
        OutputSpec[] outputs;
        foreach (outputPath; spec.outputs.paths)
        {
            outputs ~= OutputSpec(outputPath, false);
        }
        
        // Convert hermetic spec to capabilities
        auto caps = specToCapabilities(spec);
        
        // Build environment from EnvSet
        string[string] env = spec.environment.vars.dup;
        
        // Calculate timeout from resource limits (convert ms to Duration)
        import std.datetime : msecs;
        auto timeout = spec.resources.maxCpuTimeMs > 0 ? 
            msecs(spec.resources.maxCpuTimeMs) : msecs(0);
        
        return new ActionRequest(
            actionId,
            cmdStr,
            env,
            inputs,
            outputs,
            caps,
            Priority.Normal,
            timeout
        );
    }
    
    /// Convert SandboxSpec to Capabilities for transmission
    private Capabilities specToCapabilities(SandboxSpec spec) const pure @safe
    {
        import std.datetime : msecs;
        
        Capabilities caps;
        
        // Map hermetic spec to capabilities
        caps.network = !spec.network.isHermetic;  // Use network policy - non-hermetic means network allowed
        caps.readPaths = spec.inputs.paths.dup;
        caps.writePaths = spec.outputs.paths.dup;
        caps.timeout = msecs(spec.resources.maxCpuTimeMs);
        caps.maxCpu = 0;  // ResourceLimits doesn't have maxCpuCores
        caps.maxMemory = spec.resources.maxMemoryBytes;
        
        return caps;
    }
    
    
    /// Submit action to worker via coordinator
    private BuildResult!(engine.distributed.protocol.protocol.ActionResult) 
    submitToWorker(ActionRequest request) @trusted
    {
        if (coordinator is null)
        {
            auto error = new GenericError(
                "Coordinator not initialized",
                ErrorCode.InternalError
            );
            return Err!(engine.distributed.protocol.protocol.ActionResult, BuildError)(error);
        }
        
        // Register action for completion tracking
        completionTracker.register(request.id);
        scope(exit) completionTracker.cleanup(request.id);
        
        // Submit to coordinator for scheduling
        auto scheduleResult = coordinator.scheduleAction(request);
        if (scheduleResult.isErr)
        {
            auto error = new GenericError(
                "Failed to schedule action: " ~ scheduleResult.unwrapErr().message(),
                ErrorCode.ActionSchedulingFailed
            );
            completionTracker.notifyError(request.id, error);
            return Err!(engine.distributed.protocol.protocol.ActionResult, BuildError)(error);
        }
        
        Logger.debugLog("Action " ~ request.id.toString() ~ " scheduled, waiting for completion...");
        
        // Wait for completion asynchronously with timeout
        // The coordinator will call onActionComplete() when the action finishes
        immutable timeout = request.timeout > msecs(0) ? request.timeout : config.defaultTimeout;
        auto waitResult = completionTracker.wait(request.id, timeout);
        
        if (waitResult.isErr)
        {
            Logger.error("Action " ~ request.id.toString() ~ " wait failed: " ~ 
                       waitResult.unwrapErr().message());
            return waitResult;
        }
        
        auto result = waitResult.unwrap();
        Logger.info("Action " ~ request.id.toString() ~ " completed with status: " ~ 
                   result.status.to!string);
        
        return Ok!(engine.distributed.protocol.protocol.ActionResult, BuildError)(result);
    }
    
    /// Callback for action completion (called by coordinator/worker)
    /// This method is invoked asynchronously when a remote action completes
    void onActionComplete(ActionId actionId, ActionResult result) @trusted
    {
        Logger.debugLog("Action completion callback: " ~ actionId.toString());
        completionTracker.notifyComplete(actionId, result);
    }
    
    /// Callback for action failure (called by coordinator/worker)
    /// This method is invoked asynchronously when a remote action fails
    void onActionFailed(ActionId actionId, string errorMsg) @trusted
    {
        Logger.debugLog("Action failure callback: " ~ actionId.toString());
        auto error = new GenericError(
            "Remote action failed: " ~ errorMsg,
            ErrorCode.BuildFailed
        );
        completionTracker.notifyError(actionId, error);
    }
    
    /// Check action cache
    private BuildResult!RemoteExecutionResult checkActionCache(ActionId actionId) @trusted
    {
        // Query action cache (would integrate with action cache service)
        auto error = new GenericError("Not in cache", ErrorCode.CacheNotFound);
        return Err!(RemoteExecutionResult, BuildError)(error);
    }
    
    /// Cache action result
    private VoidBuildResult cacheActionResult(
        ActionId actionId,
        RemoteExecutionResult result
    ) @trusted
    {
        // Store in action cache (would integrate with action cache service)
        Logger.debugLog("Caching action result: " ~ actionId.toString());
        return Ok!BuildError();
    }
    
}
