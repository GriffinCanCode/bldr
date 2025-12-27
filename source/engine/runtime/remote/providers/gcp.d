module engine.runtime.remote.providers.gcp;

import engine.runtime.remote.providers.base;
import engine.distributed.protocol.protocol : WorkerId;
import infrastructure.errors;
import infrastructure.utils.logging;
import std.process : execute;
import std.format : format;
import std.datetime : Clock;
import std.string : strip, split, indexOf;
import std.conv : to;

/// Google Cloud Platform Compute Engine provider implementation
/// 
/// Responsibility: Manage workers on GCP Compute Engine
/// Uses: gcloud CLI for instance lifecycle management
final class GcpComputeProvider : CloudProvider
{
    private string project;
    private string zone;
    private string serviceAccountKey;
    private string[WorkerId] instanceNameMap;  // Maps WorkerId to GCP instance name
    
    this(string project, string zone, string serviceAccountKey = "") @safe
    {
        this.project = project;
        this.zone = zone;
        this.serviceAccountKey = serviceAccountKey;
    }
    
    BuildResult!WorkerId provisionWorker(
        string instanceType,
        string imageId,
        string[string] tags
    ) @trusted
    {
        import std.uuid : randomUUID;
        
        // Generate unique instance name
        immutable instanceName = "builder-worker-" ~ randomUUID().toString()[0..13];
        
        // Build gcloud command
        string[] gcloudArgs = [
            "gcloud", "compute", "instances", "create",
            instanceName,
            "--project=" ~ project,
            "--zone=" ~ zone,
            "--machine-type=" ~ instanceType,
            "--image=" ~ imageId,
            "--boot-disk-size=50GB",
            "--boot-disk-type=pd-standard",
            "--scopes=cloud-platform",
            "--format=json"
        ];
        
        // Add labels (GCP equivalent of tags)
        if (tags.length > 0)
        {
            string labelStr = "--labels=";
            size_t count = 0;
            foreach (key, value; tags)
            {
                if (count > 0)
                    labelStr ~= ",";
                labelStr ~= format("%s=%s", key, value);
                count++;
            }
            gcloudArgs ~= labelStr;
        }
        
        // Set up environment
        string[string] env;
        if (serviceAccountKey.length > 0)
            env["GOOGLE_APPLICATION_CREDENTIALS"] = serviceAccountKey;
        
        auto result = execute(gcloudArgs, env);
        
        if (result.status != 0)
            return Err!(WorkerId, BuildError)(
                Errors.system(format("Failed to create GCP instance: %s", result.output), Network.Error));
        
        // Convert string instance name to WorkerId by hashing
        import std.digest.murmurhash : MurmurHash3;
        MurmurHash3!128 hasher;
        hasher.put(cast(ubyte[])instanceName);
        auto hash = hasher.finish();
        ulong id = *cast(ulong*)&hash[0];
        
        structuredLog.info("created_gcp_instance_").field("detail", "Created GCP instance: " ~ instanceName).emit();
        instanceNameMap[WorkerId(id)] = instanceName;
        return Ok!(WorkerId, BuildError)(WorkerId(id));
    }
    
    VoidBuildResult terminateWorker(WorkerId workerId) @trusted
    {
        // Lookup actual instance name
        auto instanceNamePtr = workerId in instanceNameMap;
        if (instanceNamePtr is null)
            return VoidBuildResult.err(
                Errors.system("Worker ID not found in instance map", Distributed.WorkerFailed));
        
        string instanceName = *instanceNamePtr;
        
        string[] gcloudArgs = [
            "gcloud", "compute", "instances", "delete",
            instanceName,
            "--project=" ~ project,
            "--zone=" ~ zone,
            "--quiet"
        ];
        
        // Set up environment
        string[string] env;
        if (serviceAccountKey.length > 0)
            env["GOOGLE_APPLICATION_CREDENTIALS"] = serviceAccountKey;
        
        auto result = execute(gcloudArgs, env);
        
        if (result.status != 0)
            return VoidBuildResult.err(
                Errors.system(format("Failed to delete GCP instance %s: %s", instanceName, result.output), Network.Error));
        
        structuredLog.info("deleted_gcp_instance_").field("detail", "Deleted GCP instance: " ~ instanceName).emit();
        instanceNameMap.remove(workerId);
        return Ok!BuildError();
    }
    
    BuildResult!WorkerStatus getWorkerStatus(WorkerId workerId) @trusted
    {
        // Lookup actual instance name
        auto instanceNamePtr = workerId in instanceNameMap;
        if (instanceNamePtr is null)
            return Err!(WorkerStatus, BuildError)(
                Errors.system("Worker ID not found in instance map", Distributed.WorkerFailed));
        
        string instanceName = *instanceNamePtr;
        
        string[] gcloudArgs = [
            "gcloud", "compute", "instances", "describe",
            instanceName,
            "--project=" ~ project,
            "--zone=" ~ zone,
            "--format=json"
        ];
        
        // Set up environment
        string[string] env;
        if (serviceAccountKey.length > 0)
            env["GOOGLE_APPLICATION_CREDENTIALS"] = serviceAccountKey;
        
        auto result = execute(gcloudArgs, env);
        
        if (result.status != 0)
            return Err!(WorkerStatus, BuildError)(
                Errors.system(format("Failed to describe GCP instance %s: %s", instanceName, result.output), Network.Error));
        
        // Parse JSON output
        WorkerStatus status;
        
        try
        {
            import std.json : parseJSON, JSONException, JSONType;
            import std.datetime : SysTime;
            
            auto json = parseJSON(result.output);
            
            if (json.type != JSONType.object)
                return Err!(WorkerStatus, BuildError)(
                    Errors.system("Invalid JSON response from GCP", Network.Error));
            
            // Extract status
            if ("status" in json)
            {
                immutable statusName = json["status"].str;
                switch (statusName)
                {
                    case "PROVISIONING":
                    case "STAGING":
                        status.state = WorkerStatus.State.Pending;
                        break;
                    case "RUNNING":
                        status.state = WorkerStatus.State.Running;
                        break;
                    case "STOPPING":
                    case "SUSPENDING":
                        status.state = WorkerStatus.State.Stopping;
                        break;
                    case "TERMINATED":
                    case "SUSPENDED":
                        status.state = WorkerStatus.State.Stopped;
                        break;
                    default:
                        status.state = WorkerStatus.State.Failed;
                }
            }
            
            // Extract external IP (from networkInterfaces[0].accessConfigs[0].natIP)
            if ("networkInterfaces" in json && 
                json["networkInterfaces"].type == JSONType.array &&
                json["networkInterfaces"].array.length > 0)
            {
                auto netInterface = json["networkInterfaces"].array[0];
                
                // Get internal IP
                if ("networkIP" in netInterface)
                    status.privateIp = netInterface["networkIP"].str;
                
                // Get external IP
                if ("accessConfigs" in netInterface &&
                    netInterface["accessConfigs"].type == JSONType.array &&
                    netInterface["accessConfigs"].array.length > 0)
                {
                    auto accessConfig = netInterface["accessConfigs"].array[0];
                    if ("natIP" in accessConfig)
                        status.publicIp = accessConfig["natIP"].str;
                }
            }
            
            // Extract creation timestamp
            if ("creationTimestamp" in json)
            {
                try
                {
                    status.launchTime = SysTime.fromISOExtString(json["creationTimestamp"].str);
                }
                catch (Exception)
                {
                    status.launchTime = Clock.currTime;
                }
            }
            else
            {
                status.launchTime = Clock.currTime;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_gcp_status_json_").field("detail", "Failed to parse GCP status JSON: " ~ e.msg).emit();
            status.state = WorkerStatus.State.Failed;
        }
        
        return Ok!(WorkerStatus, BuildError)(status);
    }
}


