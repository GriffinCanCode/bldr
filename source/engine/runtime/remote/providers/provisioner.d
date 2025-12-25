module engine.runtime.remote.providers.provisioner;

import std.datetime : Duration;
import engine.distributed.protocol.protocol : WorkerId;
import engine.runtime.remote.providers.base : CloudProvider;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.logging.logger;

/// Worker provisioner - single responsibility: provision and deprovision workers
/// 
/// Separation of concerns:
/// - WorkerPool: manages pool state, scaling decisions, statistics
/// - WorkerProvisioner: handles actual worker provisioning/deprovisioning
/// - LoadPredictor: handles load prediction algorithms
/// - CloudProvider: handles cloud-specific operations (AWS, GCP, K8s, etc.)
final class WorkerProvisioner
{
    private CloudProvider provider;
    private size_t provisionedCount;
    private string instanceType;
    private string imageId;
    
    this(CloudProvider provider, string instanceType = "", string imageId = "") @safe
    {
        this.provider = provider;
        this.provisionedCount = 0;
        this.instanceType = instanceType;
        this.imageId = imageId;
    }
    
    /// Provision a new worker
    /// 
    /// Responsibility: Coordinate with cloud provider to launch worker instance
    /// Returns: Worker ID of newly provisioned worker
    BuildResult!WorkerId provisionWorker() @trusted
    {
        Logger.debugLog("Provisioning new worker via provider");
        
        // Build tags for worker identification
        string[string] tags;
        tags["Role"] = "builder-worker";
        tags["ManagedBy"] = "builder-autoscaler";
        
        // Delegate to cloud provider (AWS, GCP, K8s, etc.)
        auto result = provider.provisionWorker(instanceType, imageId, tags);
        
        if (result.isOk)
        {
            provisionedCount++;
            auto workerId = result.unwrap();
            Logger.info("Provisioned worker: " ~ workerId.toString());
        }
        else
        {
            Logger.error("Failed to provision worker");
            Logger.error(formatError(result.unwrapErr()));
        }
        
        return result;
    }
    
    /// Provision multiple workers in batch
    /// 
    /// Responsibility: Efficiently provision multiple workers
    /// Returns: Array of successfully provisioned worker IDs
    BuildResult!(WorkerId[]) provisionBatch(size_t count) @trusted
    {
        WorkerId[] workers;
        workers.reserve(count);
        
        foreach (_; 0 .. count)
        {
            auto result = provisionWorker();
            if (result.isOk)
            {
                workers ~= result.unwrap();
            }
            else
            {
                // Continue provisioning others even if one fails
                Logger.warning("Batch provisioning: partial failure");
            }
        }
        
        if (workers.length == 0)
        {
            auto error = new GenericError(
                "Failed to provision any workers in batch",
                ErrorCode.InternalError
            );
            return Err!(WorkerId[], BuildError)(error);
        }
        
        return Ok!(WorkerId[], BuildError)(workers);
    }
    
    /// Deprovision a worker
    /// 
    /// Responsibility: Gracefully terminate worker instance
    VoidBuildResult deprovisionWorker(WorkerId workerId) @trusted
    {
        Logger.info("Deprovisioning worker: " ~ workerId.toString());
        
        auto result = provider.terminateWorker(workerId);
        
        if (result.isOk)
        {
            provisionedCount--;
            Logger.info("Deprovisioned worker: " ~ workerId.toString());
        }
        else
        {
            Logger.error("Failed to deprovision worker");
            Logger.error(formatError(result.unwrapErr()));
        }
        
        return result;
    }
    
    /// Deprovision multiple workers in batch
    /// 
    /// Responsibility: Efficiently deprovision multiple workers
    VoidBuildResult deprovisionBatch(WorkerId[] workerIds) @trusted
    {
        size_t successCount = 0;
        
        foreach (workerId; workerIds)
        {
            auto result = deprovisionWorker(workerId);
            if (result.isOk)
                successCount++;
        }
        
        if (successCount == 0)
        {
            auto error = new GenericError(
                "Failed to deprovision any workers in batch",
                ErrorCode.InternalError
            );
            return VoidBuildResult.err(error);
        }
        
        return Ok!BuildError();
    }
    
    /// Get provisioning statistics
    size_t getProvisionedCount() const pure nothrow @safe @nogc
    {
        return provisionedCount;
    }
}

