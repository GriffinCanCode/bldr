module engine.runtime.remote.providers.kubernetes;

import engine.runtime.remote.providers.base;
import engine.distributed.protocol.protocol : WorkerId;
import infrastructure.errors;
import infrastructure.utils.logging.logger;
import std.process : execute, pipeProcess, Redirect, wait;
import std.format : format;
import std.datetime : Clock, SysTime;
import std.string : strip, split, join;
import std.conv : to;
import std.uuid : randomUUID;
import std.algorithm : map;
import std.stdio : File;
import std.array : array;
import std.json : parseJSON, JSONValue, JSONException, JSONType;

/// Kubernetes provider implementation
/// 
/// Responsibility: Manage workers as Kubernetes Pods
/// Uses: kubectl CLI for Pod lifecycle management
final class KubernetesProvider : CloudProvider
{
    private string namespace;
    private string kubeconfig;
    private string[WorkerId] podNameMap;  // Maps WorkerId to Pod name
    
    this(string namespace, string kubeconfig) @safe
    {
        this.namespace = namespace;
        this.kubeconfig = kubeconfig;
    }
    
    BuildResult!WorkerId provisionWorker(
        string instanceType,
        string imageId,
        string[string] tags
    ) @trusted
    {
        // Generate unique pod name
        immutable podName = "builder-worker-" ~ randomUUID().toString()[0..8];
        
        // Build pod spec
        string podSpec = format(
            `apiVersion: v1
kind: Pod
metadata:
  name: %s
  namespace: %s
  labels:
    app: builder-worker
    instance-type: %s
spec:
  restartPolicy: Never
  containers:
  - name: worker
    image: %s
    resources:
      requests:
        memory: "%s"
        cpu: "%s"
      limits:
        memory: "%s"
        cpu: "%s"
`,
            podName,
            namespace,
            instanceType,
            imageId,
            getMemoryRequest(instanceType),
            getCpuRequest(instanceType),
            getMemoryLimit(instanceType),
            getCpuLimit(instanceType)
        );
        
        // Add tags as labels
        foreach (key, value; tags)
        {
            podSpec ~= format("    %s: %s\n", key, value);
        }
        
        // Apply pod using kubectl with piped input
        string[] kubectlArgs = [
            "kubectl",
            "--kubeconfig=" ~ kubeconfig,
            "apply",
            "-f",
            "-"
        ];
        
        try
        {
            auto pipes = pipeProcess(kubectlArgs, Redirect.stdin | Redirect.stdout | Redirect.stderr);
            pipes.stdin.write(podSpec);
            pipes.stdin.close();
            
            auto status = wait(pipes.pid);
            string output = pipes.stdout.byLine.map!(a => a.idup).join("\n");
            string errorOutput = pipes.stderr.byLine.map!(a => a.idup).join("\n");
            
            if (status != 0)
            {
                auto error = new SystemError(
                    format("Failed to create Kubernetes pod: %s", errorOutput),
                    ErrorCode.ProcessSpawnFailed
                );
                return Err!(WorkerId, BuildError)(error);
            }
        }
        catch (Exception e)
        {
            auto error = new SystemError(
                format("Failed to execute kubectl: %s", e.msg),
                ErrorCode.ProcessSpawnFailed
            );
            return Err!(WorkerId, BuildError)(error);
        }
        
        // Convert string pod name to WorkerId by hashing
        import std.digest.murmurhash : MurmurHash3;
        MurmurHash3!128 hasher;
        hasher.put(cast(ubyte[])podName);
        auto hash = hasher.finish();
        ulong id = *cast(ulong*)&hash[0];
        
        Logger.info("Created Kubernetes pod: " ~ podName);
        podNameMap[WorkerId(id)] = podName;
        return Ok!(WorkerId, BuildError)(WorkerId(id));
    }
    
    VoidBuildResult terminateWorker(WorkerId workerId) @trusted
    {
        // Lookup actual pod name
        auto podNamePtr = workerId in podNameMap;
        if (podNamePtr is null)
        {
            auto error = new SystemError(
                "Worker ID not found in pod map",
                ErrorCode.WorkerFailed
            );
            return VoidBuildResult.err(error);
        }
        
        string podName = *podNamePtr;
        
        string[] kubectlArgs = [
            "kubectl",
            "--kubeconfig=" ~ kubeconfig,
            "-n", namespace,
            "delete",
            "pod",
            podName,
            "--grace-period=30"
        ];
        
        auto result = execute(kubectlArgs);
        
        if (result.status != 0)
        {
            auto error = new SystemError(
                format("Failed to delete Kubernetes pod %s: %s", podName, result.output),
                ErrorCode.ProcessSpawnFailed
            );
            return VoidBuildResult.err(error);
        }
        
        Logger.info("Deleted Kubernetes pod: " ~ podName);
        podNameMap.remove(workerId);
        return Ok!BuildError();
    }
    
    BuildResult!WorkerStatus getWorkerStatus(WorkerId workerId) @trusted
    {
        // Lookup actual pod name
        auto podNamePtr = workerId in podNameMap;
        if (podNamePtr is null)
        {
            auto error = new SystemError(
                "Worker ID not found in pod map",
                ErrorCode.WorkerFailed
            );
            return Err!(WorkerStatus, BuildError)(error);
        }
        
        string podName = *podNamePtr;
        
        string[] kubectlArgs = [
            "kubectl",
            "--kubeconfig=" ~ kubeconfig,
            "-n", namespace,
            "get",
            "pod",
            podName,
            "-o", "json"
        ];
        
        auto result = execute(kubectlArgs);
        
        if (result.status != 0)
        {
            auto error = new SystemError(
                format("Failed to get pod status for %s: %s", podName, result.output),
                ErrorCode.ProcessSpawnFailed
            );
            return Err!(WorkerStatus, BuildError)(error);
        }
        
        // Parse JSON output properly
        WorkerStatus status;
        
        try
        {
            JSONValue podJson = parseJSON(result.output);
            
            // Extract pod phase from status.phase
            if (auto statusObj = "status" in podJson)
            {
                if (statusObj.type == JSONType.object)
                {
                    if (auto phaseVal = "phase" in *statusObj)
                    {
                        string phase = phaseVal.str;
                        switch (phase)
                        {
                            case "Pending":
                                status.state = WorkerStatus.State.Pending;
                                break;
                            case "Running":
                                status.state = WorkerStatus.State.Running;
                                break;
                            case "Succeeded":
                                status.state = WorkerStatus.State.Stopped;
                                break;
                            case "Failed":
                            case "Unknown":
                                status.state = WorkerStatus.State.Failed;
                                break;
                            default:
                                status.state = WorkerStatus.State.Pending;
                        }
                    }
                    
                    // Extract pod IP from status.podIP
                    if (auto podIpVal = "podIP" in *statusObj)
                    {
                        status.publicIp = podIpVal.str;
                        status.privateIp = status.publicIp; // In K8s, typically same
                    }
                    
                    // Extract host IP from status.hostIP
                    if (auto hostIpVal = "hostIP" in *statusObj)
                    {
                        status.privateIp = hostIpVal.str;
                    }
                    
                    // Extract start time from status.startTime
                    if (auto startTimeVal = "startTime" in *statusObj)
                    {
                        status.launchTime = parseK8sTimestamp(startTimeVal.str);
                    }
                    else
                    {
                        status.launchTime = Clock.currTime;
                    }
                }
            }
            
            // Extract metadata.creationTimestamp as fallback
            if (status.launchTime == SysTime.init)
            {
                if (auto metadataObj = "metadata" in podJson)
                {
                    if (metadataObj.type == JSONType.object)
                    {
                        if (auto creationTime = "creationTimestamp" in *metadataObj)
                        {
                            status.launchTime = parseK8sTimestamp(creationTime.str);
                        }
                    }
                }
            }
        }
        catch (JSONException e)
        {
            auto error = new SystemError(
                format("Failed to parse pod JSON: %s", e.msg),
                ErrorCode.ParseFailed
            );
            return Err!(WorkerStatus, BuildError)(error);
        }
        
        return Ok!(WorkerStatus, BuildError)(status);
    }

private:
    
    /// Parse Kubernetes ISO 8601 timestamp (e.g., "2023-11-22T10:30:00Z")
    static SysTime parseK8sTimestamp(string timestamp) @trusted
    {
        import std.datetime : DateTime, UTC;
        import std.string : replace;
        
        try
        {
            // K8s uses ISO 8601: "2023-11-22T10:30:00Z"
            // Simple parser for this specific format
            if (timestamp.length < 19)
                return Clock.currTime;
            
            int year = timestamp[0..4].to!int;
            int month = timestamp[5..7].to!int;
            int day = timestamp[8..10].to!int;
            int hour = timestamp[11..13].to!int;
            int minute = timestamp[14..16].to!int;
            int second = timestamp[17..19].to!int;
            
            auto dt = DateTime(year, month, day, hour, minute, second);
            return SysTime(dt, UTC());
        }
        catch (Exception)
        {
            return Clock.currTime;
        }
    }
    
    /// Get memory request for instance type
    string getMemoryRequest(string instanceType) const pure @safe
    {
        switch (instanceType)
        {
            case "small": return "512Mi";
            case "medium": return "2Gi";
            case "large": return "4Gi";
            case "xlarge": return "8Gi";
            default: return "2Gi";
        }
    }
    
    /// Get CPU request for instance type
    string getCpuRequest(string instanceType) const pure @safe
    {
        switch (instanceType)
        {
            case "small": return "500m";
            case "medium": return "2";
            case "large": return "4";
            case "xlarge": return "8";
            default: return "2";
        }
    }
    
    /// Get memory limit for instance type
    string getMemoryLimit(string instanceType) const pure @safe
    {
        switch (instanceType)
        {
            case "small": return "1Gi";
            case "medium": return "4Gi";
            case "large": return "8Gi";
            case "xlarge": return "16Gi";
            default: return "4Gi";
        }
    }
    
    /// Get CPU limit for instance type
    string getCpuLimit(string instanceType) const pure @safe
    {
        switch (instanceType)
        {
            case "small": return "1";
            case "medium": return "4";
            case "large": return "8";
            case "xlarge": return "16";
            default: return "4";
        }
    }
}

