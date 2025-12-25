module engine.runtime.remote.providers.base;

import std.datetime : SysTime;
import engine.distributed.protocol.protocol : WorkerId;
import infrastructure.errors;

/// Worker status from cloud provider
struct WorkerStatus
{
    enum State
    {
        Pending,
        Running,
        Stopping,
        Stopped,
        Failed
    }
    
    State state;
    string publicIp;
    string privateIp;
    SysTime launchTime;
}

/// Cloud provider interface for worker provisioning
/// 
/// Responsibility: Abstract cloud provider operations
/// Implementations: AWS EC2, Kubernetes, GCP, Azure, etc.
interface CloudProvider
{
    /// Provision new worker instance
    /// 
    /// Responsibility: Request worker from cloud provider
    /// Returns: WorkerId on success, error on failure
    BuildResult!WorkerId provisionWorker(
        string instanceType,
        string imageId,
        string[string] tags
    );
    
    /// Terminate worker instance
    /// 
    /// Responsibility: Gracefully shutdown worker
    /// Returns: Success or error
    VoidBuildResult terminateWorker(WorkerId workerId);
    
    /// Get worker status
    /// 
    /// Responsibility: Query worker state from provider
    /// Returns: WorkerStatus with current state
    BuildResult!WorkerStatus getWorkerStatus(WorkerId workerId);
}

