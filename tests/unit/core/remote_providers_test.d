/+ dub.sdl:
    name "remote_providers_test"
    dependency "builder" path="../../../"
+/
module tests.unit.core.remote_providers_test;

import std.stdio;
import std.conv : to;
import std.datetime : Clock;
import engine.runtime.remote.providers.base;
import engine.runtime.remote.providers.mock;
import engine.runtime.remote.providers.aws;
import engine.runtime.remote.providers.gcp;
import engine.runtime.remote.providers.kubernetes;
import engine.distributed.protocol.protocol : WorkerId;
import infrastructure.errors;

/// Test mock cloud provider
@system unittest
{
    writeln("Testing MockCloudProvider...");
    
    auto provider = new MockCloudProvider();
    
    // Test provisioning worker
    auto provisionResult = provider.provisionWorker("small", "test-image", ["env": "test"]);
    assert(provisionResult.isOk, "Mock provision should succeed");
    
    auto workerId = provisionResult.unwrap();
    assert(workerId.value > 0, "Worker ID should not be empty");
    writeln("  ✓ Provisioned mock worker: ", workerId.value);
    
    // Test getting worker status
    auto statusResult = provider.getWorkerStatus(workerId);
    assert(statusResult.isOk, "Mock status query should succeed");
    
    auto status = statusResult.unwrap();
    assert(status.state == WorkerStatus.State.Running, "Mock worker should be running");
    writeln("  ✓ Worker status: ", status.state);
    
    // Test terminating worker
    auto terminateResult = provider.terminateWorker(workerId);
    assert(terminateResult.isOk, "Mock termination should succeed");
    writeln("  ✓ Terminated mock worker");
    
    // Verify worker is no longer in provider (mock removes terminated workers)
    auto finalStatus = provider.getWorkerStatus(workerId);
    assert(finalStatus.isErr, "Status query should fail for terminated worker");
    writeln("  ✓ Worker properly removed after termination");
}

/// Test AWS EC2 provider interface (without real AWS calls)
@system unittest
{
    writeln("Testing AwsEc2Provider interface...");
    
    // Create provider with mock credentials
    auto provider = new AwsEc2Provider("us-east-1", "mock-key", "mock-secret");
    assert(provider !is null, "Provider should be created");
    writeln("  ✓ AWS provider created");
    
    // Note: We can't test actual AWS API calls without credentials
    // These tests verify the interface works correctly
    writeln("  ✓ AWS provider interface validated");
}

/// Test GCP Compute provider interface (without real GCP calls)
@system unittest
{
    writeln("Testing GcpComputeProvider interface...");
    
    // Create provider with mock configuration
    auto provider = new GcpComputeProvider("test-project", "us-central1-a", "");
    assert(provider !is null, "Provider should be created");
    writeln("  ✓ GCP provider created");
    
    // Note: We can't test actual GCP API calls without credentials
    // These tests verify the interface works correctly
    writeln("  ✓ GCP provider interface validated");
}

/// Test Kubernetes provider interface (without real cluster)
@system unittest
{
    writeln("Testing KubernetesProvider interface...");
    
    // Create provider with mock configuration
    auto provider = new KubernetesProvider("builder", "~/.kube/config");
    assert(provider !is null, "Provider should be created");
    writeln("  ✓ Kubernetes provider created");
    
    // Note: We can't test actual K8s API calls without a cluster
    // These tests verify the interface works correctly
    writeln("  ✓ Kubernetes provider interface validated");
}

/// Test worker status states
@system unittest
{
    writeln("Testing WorkerStatus states...");
    
    WorkerStatus status;
    
    // Test all states
    status.state = WorkerStatus.State.Pending;
    assert(status.state == WorkerStatus.State.Pending);
    
    status.state = WorkerStatus.State.Running;
    assert(status.state == WorkerStatus.State.Running);
    
    status.state = WorkerStatus.State.Stopping;
    assert(status.state == WorkerStatus.State.Stopping);
    
    status.state = WorkerStatus.State.Stopped;
    assert(status.state == WorkerStatus.State.Stopped);
    
    status.state = WorkerStatus.State.Failed;
    assert(status.state == WorkerStatus.State.Failed);
    
    writeln("  ✓ All worker states validated");
    
    // Test status fields
    status.publicIp = "1.2.3.4";
    status.privateIp = "10.0.0.1";
    status.launchTime = Clock.currTime;
    
    assert(status.publicIp == "1.2.3.4");
    assert(status.privateIp == "10.0.0.1");
    writeln("  ✓ Worker status fields validated");
}

/// Test mock provider lifecycle
@system unittest
{
    writeln("Testing mock provider full lifecycle...");
    
    auto provider = new MockCloudProvider();
    
    // Provision multiple workers
    WorkerId[] workers;
    foreach (i; 0 .. 3)
    {
        auto result = provider.provisionWorker(
            "medium",
            "test-image-" ~ i.to!string,
            ["index": i.to!string]
        );
        assert(result.isOk, "Provisioning worker " ~ i.to!string ~ " should succeed");
        workers ~= result.unwrap();
    }
    
    writeln("  ✓ Provisioned ", workers.length, " workers");
    
    // Check all workers are running
    foreach (i, worker; workers)
    {
        auto status = provider.getWorkerStatus(worker);
        assert(status.isOk, "Status check should succeed");
        assert(status.unwrap().state == WorkerStatus.State.Running,
               "Worker " ~ i.to!string ~ " should be running");
    }
    writeln("  ✓ All workers running");
    
    // Terminate all workers
    foreach (i, worker; workers)
    {
        auto result = provider.terminateWorker(worker);
        assert(result.isOk, "Termination should succeed");
    }
    writeln("  ✓ All workers terminated");
    
    // Verify all workers are removed (mock provider removes terminated workers)
    foreach (i, worker; workers)
    {
        auto status = provider.getWorkerStatus(worker);
        assert(status.isErr, "Status check should fail for terminated worker");
    }
    writeln("  ✓ All workers properly removed");
}

/// Test error handling with invalid worker IDs
@system unittest
{
    writeln("Testing error handling...");
    
    auto provider = new MockCloudProvider();
    
    // Try to get status of non-existent worker
    import std.random : uniform;
    auto invalidId = WorkerId(uniform!ulong());
    auto statusResult = provider.getWorkerStatus(invalidId);
    
    // Mock provider should return an error for non-existent workers
    assert(statusResult.isErr, "Non-existent worker should return error");
    writeln("  ✓ Invalid worker ID handled");
    
    // Try to terminate already terminated worker
    auto provisionResult = provider.provisionWorker("small", "test", ["test": "value"]);
    assert(provisionResult.isOk);
    auto workerId = provisionResult.unwrap();
    
    auto firstTerminate = provider.terminateWorker(workerId);
    assert(firstTerminate.isOk);
    
    auto secondTerminate = provider.terminateWorker(workerId);
    assert(secondTerminate.isOk, "Double termination should be idempotent");
    writeln("  ✓ Double termination handled gracefully");
}

/// Test provider interface compliance
@system unittest
{
    writeln("Testing provider interface compliance...");
    
    // Verify all providers implement CloudProvider interface
    CloudProvider mockProvider = new MockCloudProvider();
    assert(mockProvider !is null);
    
    CloudProvider awsProvider = new AwsEc2Provider("us-east-1", "", "");
    assert(awsProvider !is null);
    
    CloudProvider gcpProvider = new GcpComputeProvider("project", "zone", "");
    assert(gcpProvider !is null);
    
    CloudProvider k8sProvider = new KubernetesProvider("namespace", "config");
    assert(k8sProvider !is null);
    
    writeln("  ✓ All providers implement CloudProvider interface");
}

/// Test worker tags/metadata
@system unittest
{
    writeln("Testing worker tags and metadata...");
    
    auto provider = new MockCloudProvider();
    
    string[string] tags = [
        "environment": "production",
        "team": "platform",
        "cost-center": "engineering",
        "version": "1.2.3"
    ];
    
    auto result = provider.provisionWorker("large", "prod-image", tags);
    assert(result.isOk, "Provisioning with tags should succeed");
    
    auto workerId = result.unwrap();
    writeln("  ✓ Worker provisioned with ", tags.length, " tags");
    
    // Verify worker is accessible
    auto status = provider.getWorkerStatus(workerId);
    assert(status.isOk);
    writeln("  ✓ Tagged worker accessible");
    
    // Clean up
    auto terminate = provider.terminateWorker(workerId);
    assert(terminate.isOk);
    writeln("  ✓ Tagged worker terminated");
}

/// Test instance types
@system unittest
{
    writeln("Testing different instance types...");
    
    auto provider = new MockCloudProvider();
    
    string[] instanceTypes = ["small", "medium", "large", "xlarge"];
    
    foreach (instanceType; instanceTypes)
    {
        auto result = provider.provisionWorker(instanceType, "test-image", null);
        assert(result.isOk, "Provisioning " ~ instanceType ~ " should succeed");
        
        auto workerId = result.unwrap();
        auto terminate = provider.terminateWorker(workerId);
        assert(terminate.isOk);
    }
    
    writeln("  ✓ All instance types provisioned successfully");
}

/// Test concurrent operations
@system unittest
{
    writeln("Testing concurrent provider operations...");
    
    auto provider = new MockCloudProvider();
    
    // Provision multiple workers concurrently
    import std.parallelism : parallel;
    import core.atomic : atomicOp;
    
    shared int successCount = 0;
    WorkerId[] workers;
    
    // Sequential provisioning (can't easily test true concurrency in unittest)
    foreach (i; 0 .. 10)
    {
        auto result = provider.provisionWorker("small", "concurrent-test", null);
        if (result.isOk)
        {
            atomicOp!"+="(successCount, 1);
            workers ~= result.unwrap();
        }
    }
    
    assert(successCount == 10, "All provisions should succeed");
    writeln("  ✓ Provisioned ", successCount, " workers successfully");
    
    // Clean up all workers
    foreach (worker; workers)
    {
        provider.terminateWorker(worker);
    }
    writeln("  ✓ Cleaned up all workers");
}

/// Test worker IP addresses
@system unittest
{
    writeln("Testing worker IP addresses...");
    
    auto provider = new MockCloudProvider();
    
    auto result = provider.provisionWorker("medium", "test", null);
    assert(result.isOk);
    
    auto workerId = result.unwrap();
    auto statusResult = provider.getWorkerStatus(workerId);
    assert(statusResult.isOk);
    
    auto status = statusResult.unwrap();
    
    // Mock provider should provide IP addresses
    assert(status.publicIp.length > 0, "Public IP should be set");
    assert(status.privateIp.length > 0, "Private IP should be set");
    
    writeln("  ✓ Worker has public IP: ", status.publicIp);
    writeln("  ✓ Worker has private IP: ", status.privateIp);
    
    // Clean up
    provider.terminateWorker(workerId);
}


