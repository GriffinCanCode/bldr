module engine.runtime.remote.core.interface_;

import engine.distributed.protocol.protocol : ActionId;
import engine.runtime.hermetic : SandboxSpec;
import engine.runtime.remote.core.executor : RemoteExecutionResult;
import engine.runtime.remote.protocol.reapi : Action, ExecuteResponse;
import engine.runtime.remote.monitoring.metrics : ServiceMetrics;
import infrastructure.errors;

/// Service status
struct ServiceStatus
{
    bool running;
    import engine.distributed.coordinator.coordinator : Coordinator;
    import engine.runtime.remote.pool.manager : PoolStats;
    Coordinator.CoordinatorStats coordinatorStats;
    PoolStats poolStats;
    ServiceMetrics metrics;
}

/// Remote execution service interface
/// Enables distributed build execution with coordinator and worker pool
interface IRemoteExecutionService
{
    /// Start the remote execution service
    /// Initializes coordinator, worker pool, and health monitoring
    VoidBuildResult start();
    
    /// Stop the remote execution service
    /// Gracefully shuts down all components
    void stop();
    
    /// Execute action remotely
    /// 
    /// Parameters:
    ///   actionId = Unique action identifier
    ///   spec = Hermetic sandbox specification
    ///   command = Command to execute
    ///   workDir = Working directory for execution
    /// 
    /// Returns: Execution result or error
    BuildResult!RemoteExecutionResult execute(
        ActionId actionId,
        SandboxSpec spec,
        string[] command,
        string workDir
    );
    
    /// Execute via REAPI (Bazel Remote Execution API compatibility)
    /// 
    /// Parameters:
    ///   action = REAPI action to execute
    ///   skipCacheLookup = Bypass cache and force execution
    /// 
    /// Returns: REAPI execution response or error
    BuildResult!ExecuteResponse executeReapi(
        Action action,
        bool skipCacheLookup = false
    );
    
    /// Get current service status
    /// Returns running state, coordinator stats, pool stats, and metrics
    ServiceStatus getStatus();
    
    /// Get service metrics
    /// Returns aggregated execution metrics
    ServiceMetrics getMetrics();
}

/// Null remote execution service for testing/disabled remote execution
/// Provides no-op implementations of all interface methods
final class NullRemoteExecutionService : IRemoteExecutionService
{
    @trusted {
        VoidBuildResult start()
        {
            return Ok!BuildError();
        }
        
        void stop()
        {
        }
        
        BuildResult!RemoteExecutionResult execute(
            ActionId actionId,
            SandboxSpec spec,
            string[] command,
            string workDir
        )
        {
            auto error = new GenericError(
                "Remote execution not enabled",
                ErrorCode.NotSupported
            );
            return Err!(RemoteExecutionResult, BuildError)(error);
        }
        
        BuildResult!ExecuteResponse executeReapi(
            Action action,
            bool skipCacheLookup = false
        )
        {
            auto error = new GenericError(
                "REAPI not enabled",
                ErrorCode.NotSupported
            );
            return Err!(ExecuteResponse, BuildError)(error);
        }
        
        ServiceStatus getStatus()
        {
            ServiceStatus status;
            status.running = false;
            return status;
        }
        
        ServiceMetrics getMetrics()
        {
            return ServiceMetrics.init;
        }
    }
}

