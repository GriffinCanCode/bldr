module engine.runtime.remote.providers.aws;

import engine.runtime.remote.providers.base;
import engine.distributed.protocol.protocol : WorkerId;
import infrastructure.errors;
import infrastructure.utils.logging;
import std.process : execute, environment;
import std.format : format;
import std.datetime : Clock;
import std.string : strip, split, indexOf;
import std.conv : to;

/// AWS EC2 provider implementation
/// 
/// Responsibility: Manage workers on AWS EC2
/// Uses: AWS CLI for EC2 instance lifecycle management
final class AwsEc2Provider : CloudProvider
{
    private string region;
    private string accessKey;
    private string secretKey;
    private string[WorkerId] instanceIdMap;  // Maps WorkerId to AWS instance ID
    
    this(string region, string accessKey, string secretKey) @safe
    {
        this.region = region;
        this.accessKey = accessKey;
        this.secretKey = secretKey;
    }
    
    BuildResult!WorkerId provisionWorker(
        string instanceType,
        string imageId,
        string[string] tags
    ) @trusted
    {
        // Build tag specifications
        string tagSpecs = "ResourceType=instance,Tags=[";
        tagSpecs ~= "{Key=Name,Value=builder-worker},";
        foreach (key, value; tags)
        {
            tagSpecs ~= format("{Key=%s,Value=%s},", key, value);
        }
        tagSpecs ~= "]";
        
        // Run instances using AWS CLI
        string[] awsArgs = [
            "aws", "ec2", "run-instances",
            "--region", region,
            "--image-id", imageId,
            "--instance-type", instanceType,
            "--count", "1",
            "--tag-specifications", tagSpecs,
            "--output", "json"
        ];
        
        // Set AWS credentials in environment
        string[string] env;
        if (accessKey.length > 0 && secretKey.length > 0)
        {
            env["AWS_ACCESS_KEY_ID"] = accessKey;
            env["AWS_SECRET_ACCESS_KEY"] = secretKey;
        }
        env["AWS_REGION"] = region;
        
        auto result = execute(awsArgs, env);
        
        if (result.status != 0)
            return Err!(WorkerId, BuildError)(
                Errors.system(format("Failed to launch EC2 instance: %s", result.output), Network.Error));
        
        // Parse instance ID from JSON output
        string instanceId;
        try
        {
            import std.json : parseJSON, JSONException, JSONType;
            auto json = parseJSON(result.output);
            
            // Navigate: {"Instances": [{"InstanceId": "i-xxx"}]}
            if (json.type != JSONType.object || "Instances" !in json)
                return Err!(WorkerId, BuildError)(
                    Errors.system("Invalid JSON response from AWS: missing 'Instances' field", Network.Error));
            
            auto instances = json["Instances"];
            if (instances.type != JSONType.array || instances.array.length == 0)
                return Err!(WorkerId, BuildError)(
                    Errors.system("Invalid JSON response from AWS: empty or invalid 'Instances' array", Network.Error));
            
            auto firstInstance = instances.array[0];
            if (firstInstance.type != JSONType.object || "InstanceId" !in firstInstance)
                return Err!(WorkerId, BuildError)(
                    Errors.system("Invalid JSON response from AWS: missing 'InstanceId' field", Network.Error));
            
            instanceId = firstInstance["InstanceId"].str;
        }
        catch (Exception e)
        {
            return Err!(WorkerId, BuildError)(
                Errors.system(format("Failed to parse AWS JSON response: %s", e.msg), Network.Error));
        }
        
        // Convert string instance ID to WorkerId by hashing
        import std.digest.murmurhash : MurmurHash3;
        MurmurHash3!128 hasher;
        hasher.put(cast(ubyte[])instanceId);
        auto hash = hasher.finish();
        ulong id = *cast(ulong*)&hash[0];
        
        structuredLog.info("launched_ec2_instance_").field("detail", "Launched EC2 instance: " ~ instanceId).emit();
        // Store mapping for later retrieval
        instanceIdMap[WorkerId(id)] = instanceId;
        return Ok!(WorkerId, BuildError)(WorkerId(id));
    }
    
    VoidBuildResult terminateWorker(WorkerId workerId) @trusted
    {
        // Lookup actual instance ID
        auto instanceIdPtr = workerId in instanceIdMap;
        if (instanceIdPtr is null)
            return VoidBuildResult.err(
                Errors.system("Worker ID not found in instance map", Distributed.WorkerFailed));
        
        string instanceId = *instanceIdPtr;
        
        string[] awsArgs = [
            "aws", "ec2", "terminate-instances",
            "--region", region,
            "--instance-ids", instanceId
        ];
        
        // Set AWS credentials in environment
        string[string] env;
        if (accessKey.length > 0 && secretKey.length > 0)
        {
            env["AWS_ACCESS_KEY_ID"] = accessKey;
            env["AWS_SECRET_ACCESS_KEY"] = secretKey;
        }
        env["AWS_REGION"] = region;
        
        auto result = execute(awsArgs, env);
        
        if (result.status != 0)
            return VoidBuildResult.err(
                Errors.system(format("Failed to terminate EC2 instance %s: %s", instanceId, result.output), Network.Error));
        
        structuredLog.info("terminated_ec2_instance_").field("detail", "Terminated EC2 instance: " ~ instanceId).emit();
        instanceIdMap.remove(workerId);
        return Ok!BuildError();
    }
    
    BuildResult!WorkerStatus getWorkerStatus(WorkerId workerId) @trusted
    {
        // Lookup actual instance ID
        auto instanceIdPtr = workerId in instanceIdMap;
        if (instanceIdPtr is null)
            return Err!(WorkerStatus, BuildError)(
                Errors.system("Worker ID not found in instance map", Distributed.WorkerFailed));
        
        string instanceId = *instanceIdPtr;
        
        string[] awsArgs = [
            "aws", "ec2", "describe-instances",
            "--region", region,
            "--instance-ids", instanceId,
            "--output", "json"
        ];
        
        // Set AWS credentials in environment
        string[string] env;
        if (accessKey.length > 0 && secretKey.length > 0)
        {
            env["AWS_ACCESS_KEY_ID"] = accessKey;
            env["AWS_SECRET_ACCESS_KEY"] = secretKey;
        }
        env["AWS_REGION"] = region;
        
        auto result = execute(awsArgs, env);
        
        if (result.status != 0)
            return Err!(WorkerStatus, BuildError)(
                Errors.system(format("Failed to describe EC2 instance %s: %s", instanceId, result.output), Network.Error));
        
        // Parse JSON output
        WorkerStatus status;
        
        try
        {
            import std.json : parseJSON, JSONException, JSONType;
            import std.datetime : SysTime, parseRFC822DateTime;
            
            auto json = parseJSON(result.output);
            
            // Navigate: {"Reservations": [{"Instances": [{"State": {...}, ...}]}]}
            if (json.type != JSONType.object || "Reservations" !in json)
                return Err!(WorkerStatus, BuildError)(
                    Errors.system("Invalid JSON response from AWS: missing 'Reservations'", Network.Error));
            
            auto reservations = json["Reservations"];
            if (reservations.type != JSONType.array || reservations.array.length == 0)
            {
                status.state = WorkerStatus.State.Failed;
                return Ok!(WorkerStatus, BuildError)(status);
            }
            
            auto reservation = reservations.array[0];
            if ("Instances" !in reservation || reservation["Instances"].array.length == 0)
            {
                status.state = WorkerStatus.State.Failed;
                return Ok!(WorkerStatus, BuildError)(status);
            }
            
            auto instance = reservation["Instances"].array[0];
            
            // Extract state
            if ("State" in instance && "Name" in instance["State"])
            {
                immutable stateName = instance["State"]["Name"].str;
                switch (stateName)
                {
                    case "pending":
                        status.state = WorkerStatus.State.Pending;
                        break;
                    case "running":
                        status.state = WorkerStatus.State.Running;
                        break;
                    case "stopping":
                        status.state = WorkerStatus.State.Stopping;
                        break;
                    case "stopped":
                    case "terminated":
                        status.state = WorkerStatus.State.Stopped;
                        break;
                    default:
                        status.state = WorkerStatus.State.Failed;
                }
            }
            
            // Extract public IP
            if ("PublicIpAddress" in instance)
                status.publicIp = instance["PublicIpAddress"].str;
            
            // Extract private IP
            if ("PrivateIpAddress" in instance)
                status.privateIp = instance["PrivateIpAddress"].str;
            
            // Extract launch time
            if ("LaunchTime" in instance)
            {
                try
                {
                    status.launchTime = SysTime.fromISOExtString(instance["LaunchTime"].str);
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
            structuredLog.warning("failed_to_parse_aws_status_json_").field("detail", "Failed to parse AWS status JSON: " ~ e.msg).emit();
            status.state = WorkerStatus.State.Failed;
        }
        
        return Ok!(WorkerStatus, BuildError)(status);
    }
}

