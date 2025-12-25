module engine.runtime.remote.providers.azure;

import engine.runtime.remote.providers.base;
import engine.distributed.protocol.protocol : WorkerId;
import infrastructure.errors;
import infrastructure.utils.logging.logger;
import std.process : execute;
import std.format : format;
import std.datetime : Clock;
import std.string : strip, split, indexOf;
import std.conv : to;
import std.uuid : randomUUID;

/// Azure VM provider implementation
/// 
/// Responsibility: Manage workers on Azure Virtual Machines
/// Uses: Azure CLI (az) for VM lifecycle management
final class AzureVmProvider : CloudProvider
{
    private string subscriptionId;
    private string resourceGroup;
    private string location;
    private string tenantId;
    private string clientId;
    private string clientSecret;
    
    this(
        string subscriptionId,
        string resourceGroup,
        string location = "eastus",
        string tenantId = "",
        string clientId = "",
        string clientSecret = ""
    ) @safe
    {
        this.subscriptionId = subscriptionId;
        this.resourceGroup = resourceGroup;
        this.location = location;
        this.tenantId = tenantId;
        this.clientId = clientId;
        this.clientSecret = clientSecret;
    }
    
    BuildResult!WorkerId provisionWorker(
        string instanceType,
        string imageId,
        string[string] tags
    ) @trusted
    {
        // Generate unique VM name
        immutable vmName = "builder-worker-" ~ randomUUID().toString()[0..13];
        
        // Build Azure CLI command
        string[] azArgs = [
            "az", "vm", "create",
            "--subscription", subscriptionId,
            "--resource-group", resourceGroup,
            "--name", vmName,
            "--location", location,
            "--size", instanceType,
            "--image", imageId,
            "--admin-username", "azureuser",
            "--generate-ssh-keys",
            "--public-ip-sku", "Standard",
            "--output", "json"
        ];
        
        // Add tags
        if (tags.length > 0)
        {
            string tagStr;
            size_t count = 0;
            foreach (key, value; tags)
            {
                if (count > 0)
                    tagStr ~= " ";
                tagStr ~= format("%s=%s", key, value);
                count++;
            }
            azArgs ~= ["--tags", tagStr];
        }
        
        // Set authentication environment if provided
        string[string] env;
        if (tenantId.length > 0 && clientId.length > 0 && clientSecret.length > 0)
        {
            env["AZURE_TENANT_ID"] = tenantId;
            env["AZURE_CLIENT_ID"] = clientId;
            env["AZURE_CLIENT_SECRET"] = clientSecret;
        }
        
        auto result = execute(azArgs, env);
        
        if (result.status != 0)
        {
            auto error = new SystemError(
                format("Failed to create Azure VM: %s", result.output),
                ErrorCode.NetworkError
            );
            return Err!(WorkerId, BuildError)(error);
        }
        
        // Parse VM ID from JSON output
        auto output = result.output;
        auto vmIdIdx = output.indexOf("\"id\":\"");
        if (vmIdIdx == -1)
        {
            auto error = new SystemError(
                "Failed to parse VM ID from Azure response",
                ErrorCode.NetworkError
            );
            return Err!(WorkerId, BuildError)(error);
        }
        
        auto idStart = vmIdIdx + 6; // Length of "\"id\":\""
        auto idEnd = output.indexOf("\"", idStart);
        immutable vmId = output[idStart..idEnd];
        
        // Convert string VM ID to WorkerId by hashing
        import std.digest.murmurhash : MurmurHash3;
        MurmurHash3!128 hasher;
        hasher.put(cast(ubyte[])vmId);
        auto hash = hasher.finish();
        ulong id = *cast(ulong*)&hash[0];
        
        Logger.info("Created Azure VM: " ~ vmName ~ " (ID: " ~ vmId ~ ")");
        return Ok!(WorkerId, BuildError)(WorkerId(id));
    }
    
    VoidBuildResult terminateWorker(WorkerId workerId) @trusted
    {
        string[] azArgs = [
            "az", "vm", "delete",
            "--subscription", subscriptionId,
            "--resource-group", resourceGroup,
            "--name", workerId.toString(),
            "--yes",
            "--no-wait"
        ];
        
        // Set authentication environment if provided
        string[string] env;
        if (tenantId.length > 0 && clientId.length > 0 && clientSecret.length > 0)
        {
            env["AZURE_TENANT_ID"] = tenantId;
            env["AZURE_CLIENT_ID"] = clientId;
            env["AZURE_CLIENT_SECRET"] = clientSecret;
        }
        
        auto result = execute(azArgs, env);
        
        if (result.status != 0)
        {
            auto error = new SystemError(
                format("Failed to delete Azure VM %s: %s", workerId.toString(), result.output),
                ErrorCode.NetworkError
            );
            return VoidBuildResult.err(error);
        }
        
        Logger.info("Deleted Azure VM: " ~ workerId.toString());
        return Ok!BuildError();
    }
    
    BuildResult!WorkerStatus getWorkerStatus(WorkerId workerId) @trusted
    {
        string[] azArgs = [
            "az", "vm", "show",
            "--subscription", subscriptionId,
            "--resource-group", resourceGroup,
            "--name", workerId.toString(),
            "--show-details",
            "--output", "json"
        ];
        
        // Set authentication environment if provided
        string[string] env;
        if (tenantId.length > 0 && clientId.length > 0 && clientSecret.length > 0)
        {
            env["AZURE_TENANT_ID"] = tenantId;
            env["AZURE_CLIENT_ID"] = clientId;
            env["AZURE_CLIENT_SECRET"] = clientSecret;
        }
        
        auto result = execute(azArgs, env);
        
        if (result.status != 0)
        {
            auto error = new SystemError(
                format("Failed to describe Azure VM %s: %s", workerId.toString(), result.output),
                ErrorCode.NetworkError
            );
            return Err!(WorkerStatus, BuildError)(error);
        }
        
        // Parse JSON output
        WorkerStatus status;
        auto output = result.output;
        
        // Extract power state (VM starting, VM running, VM stopping, VM stopped, VM deallocated)
        if (output.indexOf("\"powerState\":\"VM starting\"") != -1)
            status.state = WorkerStatus.State.Pending;
        else if (output.indexOf("\"powerState\":\"VM running\"") != -1)
            status.state = WorkerStatus.State.Running;
        else if (output.indexOf("\"powerState\":\"VM stopping\"") != -1 || 
                 output.indexOf("\"powerState\":\"VM deallocating\"") != -1)
            status.state = WorkerStatus.State.Stopping;
        else if (output.indexOf("\"powerState\":\"VM stopped\"") != -1 || 
                 output.indexOf("\"powerState\":\"VM deallocated\"") != -1)
            status.state = WorkerStatus.State.Stopped;
        else
            status.state = WorkerStatus.State.Failed;
        
        // Extract public IP
        auto publicIpIdx = output.indexOf("\"publicIps\":\"");
        if (publicIpIdx != -1)
        {
            auto ipStart = publicIpIdx + 13; // Length of "\"publicIps\":\""
            auto ipEnd = output.indexOf("\"", ipStart);
            if (ipEnd != -1)
                status.publicIp = output[ipStart..ipEnd];
        }
        
        // Extract private IP
        auto privateIpIdx = output.indexOf("\"privateIps\":\"");
        if (privateIpIdx != -1)
        {
            auto ipStart = privateIpIdx + 14; // Length of "\"privateIps\":\""
            auto ipEnd = output.indexOf("\"", ipStart);
            if (ipEnd != -1)
                status.privateIp = output[ipStart..ipEnd];
        }
        
        status.launchTime = Clock.currTime; // Would extract from VM metadata
        
        return Ok!(WorkerStatus, BuildError)(status);
    }
}

