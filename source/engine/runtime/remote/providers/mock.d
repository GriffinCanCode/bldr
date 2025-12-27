module engine.runtime.remote.providers.mock;

import std.datetime : Clock, SysTime;
import engine.distributed.protocol.protocol : WorkerId;
import engine.runtime.remote.providers.base : CloudProvider, WorkerStatus;
import infrastructure.errors;

/// Mock cloud provider for testing and development
/// 
/// Responsibility: Provide stub implementation of CloudProvider
final class MockCloudProvider : CloudProvider
{
    private size_t provisionedCount = 0;
    private WorkerStatus[WorkerId] workers;
    
    BuildResult!WorkerId provisionWorker(
        string instanceType,
        string imageId,
        string[string] tags
    ) @trusted
    {
        import std.random : uniform;
        
        auto workerId = WorkerId(uniform!ulong());
        
        WorkerStatus status;
        status.state = WorkerStatus.State.Running;
        status.publicIp = "127.0.0.1";
        status.privateIp = "127.0.0.1";
        status.launchTime = Clock.currTime;
        
        workers[workerId] = status;
        provisionedCount++;
        
        return Ok!(WorkerId, BuildError)(workerId);
    }
    
    VoidBuildResult terminateWorker(WorkerId workerId) @trusted
    {
        if (workerId in workers)
        {
            workers[workerId].state = WorkerStatus.State.Stopped;
            workers.remove(workerId);
            if (provisionedCount > 0)
                provisionedCount--;
        }
        
        return Ok!BuildError();
    }
    
    BuildResult!WorkerStatus getWorkerStatus(WorkerId workerId) @trusted
    {
        if (auto status = workerId in workers)
        {
            return Ok!(WorkerStatus, BuildError)(*status);
        }
        
        auto error = Errors.generic("Worker not found: " ~ workerId.toString(), Build.TargetNotFound)
            .withLocation(__FILE__, __LINE__)
            .build();
        return Err!(WorkerStatus, BuildError)(error);
    }
}

