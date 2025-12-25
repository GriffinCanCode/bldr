module engine.runtime.services.resilience.service;

import engine.runtime.recovery.retry : RetryOrchestrator, RetryPolicy;
import engine.runtime.recovery.checkpoint : CheckpointManager, Checkpoint;
import engine.runtime.recovery.resume : ResumePlanner, ResumePlan, ResumeConfig;
import engine.graph : BuildGraph;
import infrastructure.errors;

/// Resilience service interface
/// Handles retry logic and checkpoint/resume functionality
interface IResilienceService
{
    /// Execute action with retry logic (string result version)
    BuildResult!string withRetryString(
        string targetId,
        BuildResult!string delegate() action,
        RetryPolicy policy
    );
    
    /// Check if a checkpoint exists
    bool hasCheckpoint();
    
    /// Check if checkpoint is stale
    bool isCheckpointStale();
    
    /// Save a checkpoint
    bool saveCheckpoint(BuildGraph graph);
    
    /// Load checkpoint
    BuildResult!Checkpoint loadCheckpoint();
    
    /// Plan resume from checkpoint
    BuildResult!ResumePlan planResume(BuildGraph graph);
    
    /// Clear checkpoint
    void clearCheckpoint();
    
    /// Get retry policy for an error
    RetryPolicy policyFor(BuildError error);
}

/// Concrete resilience service implementation
final class ResilienceService : IResilienceService
{
    private RetryOrchestrator retryOrchestrator;
    private CheckpointManager checkpointManager;
    private ResumePlanner resumePlanner;
    private bool enableRetries;
    private bool enableCheckpoints;
    
    this(bool enableRetries = true, bool enableCheckpoints = true, string workspaceRoot = ".")
    {
        this.enableRetries = enableRetries;
        this.enableCheckpoints = enableCheckpoints;
        
        // Initialize retry orchestrator
        this.retryOrchestrator = new RetryOrchestrator();
        this.retryOrchestrator.setEnabled(enableRetries);
        
        // Initialize checkpoint manager
        this.checkpointManager = new CheckpointManager(workspaceRoot, enableCheckpoints);
        
        // Initialize resume planner
        this.resumePlanner = new ResumePlanner(ResumeConfig.fromEnvironment());
    }
    
    // Constructor for dependency injection (testing)
    this(RetryOrchestrator retryOrchestrator, 
         CheckpointManager checkpointManager,
         ResumePlanner resumePlanner)
    {
        this.retryOrchestrator = retryOrchestrator;
        this.checkpointManager = checkpointManager;
        this.resumePlanner = resumePlanner;
        this.enableRetries = true;
        this.enableCheckpoints = true;
    }
    
    /// Generic template method (kept for internal/test use)
    BuildResult!T withRetry(T)(
        string targetId,
        BuildResult!T delegate() action,
        RetryPolicy policy
    ) @trusted
    {
        return !enableRetries ? action() : retryOrchestrator.withRetry(targetId, action, policy);
    }
    
    /// Execute action with retry logic (string result version)
    BuildResult!string withRetryString(
        string targetId,
        BuildResult!string delegate() action,
        RetryPolicy policy
    ) @trusted
    {
        return withRetry!string(targetId, action, policy);
    }
    
    bool hasCheckpoint() @trusted
    {
        return enableCheckpoints && checkpointManager.exists();
    }
    
    bool isCheckpointStale() @trusted
    {
        return !enableCheckpoints || checkpointManager.isStale();
    }
    
    bool saveCheckpoint(BuildGraph graph) @trusted
    {
        if (!enableCheckpoints)
            return true;
        
        // Implementation would save checkpoint
        // Left as exercise - depends on checkpoint format
        return true;
    }
    
    BuildResult!Checkpoint loadCheckpoint() @trusted
    {
        if (!enableCheckpoints)
        {
            return BuildResult!Checkpoint.err(
                Errors.system("Checkpoints disabled", ErrorCode.UnknownError)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        auto loadResult = checkpointManager.load();
        if (loadResult.isErr)
        {
            return BuildResult!Checkpoint.err(
                Errors.system(loadResult.unwrapErr(), ErrorCode.CacheLoadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        return BuildResult!Checkpoint.ok(loadResult.unwrap());
    }
    
    BuildResult!ResumePlan planResume(BuildGraph graph) @trusted
    {
        if (!enableCheckpoints)
        {
            return BuildResult!ResumePlan.err(
                Errors.system("Checkpoints disabled", ErrorCode.UnknownError)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        auto checkpointResult = checkpointManager.load();
        if (checkpointResult.isErr)
        {
            return BuildResult!ResumePlan.err(
                Errors.system(checkpointResult.unwrapErr(), ErrorCode.CacheLoadFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        auto checkpoint = checkpointResult.unwrap();
        auto planResult = resumePlanner.plan(checkpoint, graph);
        if (planResult.isErr)
        {
            return BuildResult!ResumePlan.err(
                Errors.system(planResult.unwrapErr(), ErrorCode.UnknownError)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        return BuildResult!ResumePlan.ok(planResult.unwrap());
    }
    
    void clearCheckpoint() @trusted
    {
        if (enableCheckpoints)
        {
            checkpointManager.clear();
        }
    }
    
    RetryPolicy policyFor(BuildError error) @trusted
    {
        return retryOrchestrator.policyFor(error);
    }
}


/// Null resilience service for testing/disabled resilience
final class NullResilienceService : IResilienceService
{
    private SystemError nullError;
    
    this()
    {
        nullError = Errors.system("Null resilience service", ErrorCode.UnknownError)
            .withLocation(__FILE__, __LINE__)
            .build();
    }
    
    @trusted {
        BuildResult!string withRetryString(
            string targetId,
            BuildResult!string delegate() action,
            RetryPolicy policy
        ) { return action(); }
        
        bool hasCheckpoint() { return false; }
        bool isCheckpointStale() { return true; }
        bool saveCheckpoint(BuildGraph graph) { return true; }
        
        BuildResult!Checkpoint loadCheckpoint()
        {
            return BuildResult!Checkpoint.err(cast(BuildError)nullError);
        }
        
        BuildResult!ResumePlan planResume(BuildGraph graph)
        {
            return BuildResult!ResumePlan.err(cast(BuildError)nullError);
        }
        
        void clearCheckpoint() { }
        RetryPolicy policyFor(BuildError error) { return RetryPolicy(); }
    }
}

