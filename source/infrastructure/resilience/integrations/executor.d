module infrastructure.resilience.integrations.executor;

import std.datetime;
import engine.runtime.remote.core.executor;
import engine.runtime.hermetic;
import engine.distributed.protocol.protocol : ActionId;
import infrastructure.resilience;
import infrastructure.errors;

/// Resilient remote executor wrapper
/// Wraps RemoteExecutor with circuit breaker and rate limiting
final class ResilientRemoteExecutor
{
    private RemoteExecutor inner;
    private NetworkResilience resilience;
    private string coordinatorEndpoint;
    
    this(RemoteExecutor inner, string coordinatorUrl, NetworkResilience resilience = null) @trusted
    {
        this.inner = inner;
        this.coordinatorEndpoint = coordinatorUrl;
        
        // Use provided resilience service or create new one
        if (resilience is null)
        {
            this.resilience = new NetworkResilience(PolicyPresets.standard());
        }
        else
        {
            this.resilience = resilience;
        }
        
        // Register coordinator with standard policy
        this.resilience.registerEndpoint(
            coordinatorEndpoint,
            PolicyPresets.standard()
        );
    }
    
    /// Execute action remotely with resilience
    BuildResult!RemoteExecutionResult execute(
        ActionId actionId,
        SandboxSpec spec,
        string[] command,
        string workDir
    ) @trusted
    {
        // Action execution is normal priority by default
        // Can be elevated based on action metadata
        return resilience.execute!(RemoteExecutionResult)(
            coordinatorEndpoint,
            () => inner.execute(actionId, spec, command, workDir),
            Priority.Normal,
            300.seconds  // 5 minute timeout for execution
        );
    }
    
    /// Execute with custom priority (for critical actions)
    BuildResult!RemoteExecutionResult executeWithPriority(
        ActionId actionId,
        SandboxSpec spec,
        string[] command,
        string workDir,
        Priority priority,
        Duration timeout
    ) @trusted
    {
        return resilience.execute!(RemoteExecutionResult)(
            coordinatorEndpoint,
            () => inner.execute(actionId, spec, command, workDir),
            priority,
            timeout
        );
    }
    
    /// Get circuit breaker state for coordinator
    BreakerState getBreakerState() @trusted
    {
        return resilience.getBreakerState(coordinatorEndpoint);
    }
    
    /// Get rate limiter metrics
    LimiterMetrics getMetrics() @trusted
    {
        return resilience.getLimiterMetrics(coordinatorEndpoint);
    }
    
    /// Adjust rate based on coordinator health
    /// Should be called periodically based on health monitoring
    void adjustRate(float healthScore) @trusted
    {
        resilience.adjustRate(coordinatorEndpoint, healthScore);
    }
    
    /// Check if coordinator is available (circuit not open)
    bool isAvailable() @trusted
    {
        return getBreakerState() != BreakerState.Open;
    }
    
    /// Get underlying executor
    RemoteExecutor getExecutor() @trusted
    {
        return inner;
    }
}

