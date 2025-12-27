module engine.runtime.remote.core.service;

import std.datetime : Duration, Clock, SysTime, seconds;
import std.algorithm : map, filter;
import std.array : array;
import std.conv : to;
import core.atomic;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import engine.graph : BuildGraph;
import engine.distributed.coordinator.coordinator;
import engine.economics.estimator : ExecutionHistory;
import engine.distributed.coordinator.registry;
import engine.distributed.protocol.protocol : ActionId, WorkerId;
import engine.runtime.remote.core.interface_ : IRemoteExecutionService, ServiceStatus;
import engine.runtime.remote.core.executor;
import engine.runtime.remote.pool.manager;
import engine.runtime.remote.protocol.reapi;
import engine.runtime.remote.providers.provisioner : WorkerProvisioner;
import engine.runtime.remote.providers.base : CloudProvider;
import engine.runtime.remote.providers.mock : MockCloudProvider;
import engine.runtime.remote.providers.aws : AwsEc2Provider;
import engine.runtime.remote.providers.gcp : GcpComputeProvider;
import engine.runtime.remote.providers.azure : AzureVmProvider;
import engine.runtime.remote.providers.kubernetes : KubernetesProvider;
import engine.runtime.remote.monitoring.health : RemoteServiceHealthMonitor;
import engine.runtime.remote.monitoring.metrics : RemoteServiceMetricsCollector, ServiceMetrics;
import engine.runtime.hermetic;
import engine.distributed.protocol.grpc.factory : UnifiedTransportFactory, TransportConfig, TransportType;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Cloud provider type
enum ProviderType
{
    Mock,        // Mock provider for testing
    AWS,         // AWS EC2
    GCP,         // Google Cloud Platform Compute Engine
    Kubernetes,  // Kubernetes Pods
    Azure        // Azure VMs
}

/// Provider-specific configuration
struct ProviderConfig
{
    ProviderType type = ProviderType.Mock;
    
    // AWS configuration
    string awsRegion = "us-east-1";
    string awsAccessKey = "";
    string awsSecretKey = "";
    
    // GCP configuration
    string gcpProject = "";
    string gcpZone = "us-central1-a";
    string gcpServiceAccountKey = "";
    
    // Azure configuration
    string azureSubscriptionId = "";
    string azureResourceGroup = "builder";
    string azureLocation = "eastus";
    string azureTenantId = "";
    string azureClientId = "";
    string azureClientSecret = "";
    
    // Kubernetes configuration
    string k8sNamespace = "builder";
    string k8sKubeconfig = "";
}

/// Transport type for remote communication
enum RemoteTransportType {
    Http,       // HTTP/1.1 (default, no external dependencies)
    Grpc,       // gRPC/HTTP2 (pure D, enables REAPI compatibility)
    Auto        // Auto-detect best available transport
}

/// Remote execution service configuration
struct RemoteServiceConfig
{
    // Coordinator settings
    string coordinatorHost = "0.0.0.0";
    ushort coordinatorPort = 9000;
    
    // Pool settings  
    PoolConfig poolConfig;
    
    // Executor settings
    RemoteExecutorConfig executorConfig;
    
    // Provider settings
    ProviderConfig providerConfig;
    
    // Transport settings
    RemoteTransportType transportType = RemoteTransportType.Auto;  // Transport layer
    bool enableTls = false;                 // Use TLS for transport?
    string tlsCertPath;                     // TLS certificate path
    string tlsKeyPath;                      // TLS key path
    string tlsCaPath;                       // TLS CA certificate path
    
    // Service settings
    bool enableReapi = true;                // Expose REAPI endpoint?
    ushort reapiPort = 9001;                // REAPI service port
    bool enableGrpcReapi = false;           // Use gRPC for true REAPI compatibility?
    
    Duration healthCheckInterval = 10.seconds;
    bool enableMetrics = true;
    
    // Profile-guided scheduling (uses economic estimator data for critical-path optimization)
    bool enableProfileGuidedScheduling = true;
    
    // Execution history for profile-guided scheduling (shared from economics integration)
    ExecutionHistory executionHistory = null;
    
    // Enable adaptive work-stealing thresholds (auto-tune based on success rates)
    bool enableAdaptiveStealThresholds = true;
    
    // Enable consistent hashing for affinity-based worker assignment
    // Workers assigned to same language/toolchain build warm caches
    bool enableAffinityRouting = true;
}

/// Remote execution service
/// Central orchestrator for distributed build execution
///
/// Architecture:
/// ┌─────────────────────────────────────────────────┐
/// │         Remote Execution Service                 │
/// │                                                   │
/// │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
/// │  │  REAPI   │  │  Native  │  │ Metrics  │      │
/// │  │ Adapter  │  │   API    │  │ Exporter │      │
/// │  └────┬─────┘  └────┬─────┘  └──────────┘      │
/// │       │             │                            │
/// │       └─────┬───────┘                            │
/// │             │                                    │
/// │       ┌─────▼──────┐                            │
/// │       │ Coordinator │                            │
/// │       └─────┬──────┘                            │
/// │             │                                    │
/// │    ┌────────┴────────┐                          │
/// │    │   Worker Pool    │                          │
/// │    │  (Auto-scaling)  │                          │
/// │    └────────┬────────┘                          │
/// └─────────────┼──────────────────────────────────┘
///               │
///       ┌───────┴────────┐
///       │                │
///   ┌───▼───┐        ┌───▼───┐
///   │Worker1│        │Worker2│  (Native hermetic sandboxing)
///   └───────┘        └───────┘
///
final class RemoteExecutionService : IRemoteExecutionService
{
    private RemoteServiceConfig config;
    private Coordinator coordinator;
    private WorkerRegistry registry;
    private WorkerPool pool;
    private WorkerProvisioner provisioner;
    private RemoteExecutor executor;
    private ReapiAdapter reapiAdapter;
    private BuildGraph graph;
    private RemoteServiceHealthMonitor healthMonitor;
    private RemoteServiceMetricsCollector metricsCollector;
    
    private shared bool running;
    private Mutex mutex;
    
    this(RemoteServiceConfig config, BuildGraph graph) @trusted
    {
        this.config = config;
        this.graph = graph;
        this.mutex = new Mutex();
        atomicStore(running, false);
        
        // Initialize components
        initializeComponents();
    }
    
    /// Initialize service components
    private void initializeComponents() @trusted
    {
        // Worker registry with affinity routing support
        this.registry = new WorkerRegistry(config.poolConfig.workerStartTimeout, config.enableAffinityRouting);
        
        // Coordinator with profile-guided scheduling, adaptive thresholds, and affinity routing
        CoordinatorConfig coordConfig;
        coordConfig.host = config.coordinatorHost;
        coordConfig.port = config.coordinatorPort;
        coordConfig.workerTimeout = config.poolConfig.workerStartTimeout;
        coordConfig.enableWorkStealing = true;
        coordConfig.enableProfileGuidedScheduling = config.enableProfileGuidedScheduling;
        coordConfig.executionHistory = config.executionHistory;  // Share economics history
        coordConfig.enableAdaptiveStealThresholds = config.enableAdaptiveStealThresholds;
        coordConfig.enableAffinityRouting = config.enableAffinityRouting;
        
        this.coordinator = new Coordinator(graph, coordConfig);
        
        if (config.enableAffinityRouting)
            structuredLog.info("affinity_routing_enabled").emit();
        
        // Worker provisioner (SRP: separated from pool management)
        CloudProvider provider = createProvider(config.poolConfig);
        this.provisioner = new WorkerProvisioner(provider);
        
        // Worker pool with autoscaling (now delegating provisioning to provisioner)
        this.pool = new WorkerPool(config.poolConfig, registry, provisioner);
        
        // Remote executor
        this.executor = new RemoteExecutor(config.executorConfig);
        
        // REAPI adapter (if enabled)
        if (config.enableReapi)
        {
            // Build URL based on transport type
            string protocol = config.enableGrpcReapi ? "grpc" : "http";
            if (config.enableTls) protocol ~= "s";
            immutable remoteUrl = protocol ~ "://" ~ config.coordinatorHost ~ ":" ~ config.coordinatorPort.to!string;
            this.reapiAdapter = new ReapiAdapter(remoteUrl);
            
            // Log transport type
            if (config.transportType == RemoteTransportType.Grpc || config.enableGrpcReapi)
                structuredLog.info("grpc_transport_enabled").emit();
        }
        
        // Initialize dedicated monitoring components
        this.healthMonitor = new RemoteServiceHealthMonitor(
            coordinator,
            pool,
            config.healthCheckInterval,
            config.enableMetrics
        );
        
        this.metricsCollector = new RemoteServiceMetricsCollector(
            coordinator,
            pool
        );
        
        structuredLog.info("remote_execution_service_initialized").emit();
    }
    
    /// Create worker provider based on configuration
    /// 
    /// Responsibility: Factory method for provider selection
    private CloudProvider createProvider(PoolConfig poolConfig) @trusted
    {
        auto providerConfig = config.providerConfig;
        
        final switch (providerConfig.type)
        {
            case ProviderType.Mock:
                structuredLog.info("cloud_provider").field("type", "mock").emit();
                return new MockCloudProvider();
            
            case ProviderType.AWS:
                structuredLog.info("cloud_provider").field("type", "aws_ec2").field("region", providerConfig.awsRegion).emit();
                return new AwsEc2Provider(
                    providerConfig.awsRegion,
                    providerConfig.awsAccessKey,
                    providerConfig.awsSecretKey
                );
            
            case ProviderType.GCP:
                structuredLog.info("cloud_provider").field("type", "gcp_compute").field("project", providerConfig.gcpProject).emit();
                return new GcpComputeProvider(
                    providerConfig.gcpProject,
                    providerConfig.gcpZone,
                    providerConfig.gcpServiceAccountKey
                );
            
            case ProviderType.Kubernetes:
                structuredLog.info("cloud_provider").field("type", "kubernetes").field("namespace", providerConfig.k8sNamespace).emit();
                return new KubernetesProvider(
                    providerConfig.k8sNamespace,
                    providerConfig.k8sKubeconfig
                );
            
            case ProviderType.Azure:
                structuredLog.info("cloud_provider").field("type", "azure_vm").field("subscription", providerConfig.azureSubscriptionId).emit();
                return new AzureVmProvider(
                    providerConfig.azureSubscriptionId,
                    providerConfig.azureResourceGroup,
                    providerConfig.azureLocation,
                    providerConfig.azureTenantId,
                    providerConfig.azureClientId,
                    providerConfig.azureClientSecret
                );
        }
    }
    
    /// Start service
    VoidBuildResult start() @trusted
    {
        synchronized (mutex)
        {
            if (atomicLoad(running))
                return Ok!BuildError();
            
            structuredLog.info("remote_execution_service_starting").emit();
            
            // Start coordinator
            auto coordResult = coordinator.start();
            if (coordResult.isErr)
            {
                return VoidBuildResult.err(
                    Errors.generic("Failed to start coordinator: " ~ coordResult.unwrapErr().message(), Internal.InitializationFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            // Start worker pool
            auto poolResult = pool.start();
            if (poolResult.isErr)
            {
                coordinator.stop();
                return poolResult;
            }
            
            // Start health monitoring (delegated to dedicated monitor)
            auto healthResult = healthMonitor.start();
            if (healthResult.isErr)
            {
                pool.stop();
                coordinator.stop();
                return healthResult;
            }
            
            atomicStore(running, true);
            structuredLog.info("remote_execution_service_started")
                .field("coordinator_host", config.coordinatorHost)
                .field("coordinator_port", config.coordinatorPort)
                .emit();
            
            if (config.enableReapi)
            {
                structuredLog.info("reapi_endpoint").field("port", config.reapiPort).emit();
            }
            
            return Ok!BuildError();
        }
    }
    
    /// Stop service
    void stop() @trusted
    {
        structuredLog.info("remote_execution_service_stopping").emit();
        
        atomicStore(running, false);
        
        // Stop health monitor (delegated to dedicated monitor)
        if (healthMonitor !is null)
            healthMonitor.stop();
        
        // Stop pool
        if (pool !is null)
            pool.stop();
        
        // Stop coordinator
        if (coordinator !is null)
            coordinator.stop();
        
        // Log final statistics
        logFinalStats();
        
        structuredLog.info("remote_execution_service_stopped").emit();
    }
    
    /// Execute action remotely
    BuildResult!RemoteExecutionResult execute(
        ActionId actionId,
        SandboxSpec spec,
        string[] command,
        string workDir
    ) @trusted
    {
        if (!atomicLoad(running))
        {
            return Err!(RemoteExecutionResult, BuildError)(
                Errors.generic("Service not running", Internal.NotInitialized)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        return executor.execute(actionId, spec, command, workDir);
    }
    
    /// Execute via REAPI (Bazel compatibility)
    BuildResult!ExecuteResponse executeReapi(
        Action action,
        bool skipCacheLookup = false
    ) @trusted
    {
        if (!config.enableReapi || reapiAdapter is null)
        {
            return Err!(ExecuteResponse, BuildError)(
                Errors.generic("REAPI not enabled", Internal.NotSupported)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        return reapiAdapter.execute(action, skipCacheLookup);
    }
    
    /// Get service status
    ServiceStatus getStatus() @trusted
    {
        ServiceStatus status;
        status.running = atomicLoad(running);
        status.coordinatorStats = coordinator.getStats();
        status.poolStats = pool.getStats();
        status.metrics = metricsCollector.collect();
        
        return status;
    }
    
    /// Get service metrics (delegated to dedicated collector)
    ServiceMetrics getMetrics() @trusted
    {
        return metricsCollector.collect();
    }
    
    /// Log final statistics
    private void logFinalStats() @trusted
    {
        try
        {
            auto metrics = getMetrics();
            
            structuredLog.info("execution_statistics")
                .field("total", metrics.totalExecutions)
                .field("successful", metrics.successfulExecutions)
                .field("failed", metrics.failedExecutions)
                .field("cached", metrics.cachedExecutions)
                .emit();
            
            if (metrics.totalExecutions > 0)
            {
                immutable successRate = 
                    (cast(float)metrics.successfulExecutions / metrics.totalExecutions) * 100;
                immutable cacheHitRate = 
                    (cast(float)metrics.cachedExecutions / metrics.totalExecutions) * 100;
                
                structuredLog.info("execution_rates")
                    .field("success_rate_pct", successRate)
                    .field("cache_hit_rate_pct", cacheHitRate)
                    .emit();
            }
        }
        catch (Exception e)
        {
            structuredLog.error("stats_logging_failed").field("error", e.msg).emit();
        }
    }
}

/// Service builder for convenient configuration
struct RemoteServiceBuilder
{
    private RemoteServiceConfig config;
    
    /// Create builder with defaults
    static RemoteServiceBuilder create() pure nothrow @safe @nogc
    {
        RemoteServiceBuilder builder;
        builder.config = RemoteServiceConfig();
        return builder;
    }
    
    /// Set coordinator address
    ref RemoteServiceBuilder coordinator(string host, ushort port) return pure nothrow @safe @nogc
    {
        config.coordinatorHost = host;
        config.coordinatorPort = port;
        return this;
    }
    
    /// Set pool configuration
    ref RemoteServiceBuilder pool(PoolConfig poolConfig) return pure nothrow @safe @nogc
    {
        config.poolConfig = poolConfig;
        return this;
    }
    
    /// Set executor configuration
    ref RemoteServiceBuilder executor(RemoteExecutorConfig executorConfig) return pure nothrow @safe @nogc
    {
        config.executorConfig = executorConfig;
        return this;
    }
    
    /// Enable REAPI
    ref RemoteServiceBuilder enableReapi(ushort port = 9001) return pure nothrow @safe @nogc
    {
        config.enableReapi = true;
        config.reapiPort = port;
        return this;
    }
    
    /// Enable metrics
    ref RemoteServiceBuilder enableMetrics(bool enabled = true) return pure nothrow @safe @nogc
    {
        config.enableMetrics = enabled;
        return this;
    }
    
    /// Set transport type (Http, Grpc, or Auto)
    ref RemoteServiceBuilder transport(RemoteTransportType type) return pure nothrow @safe @nogc
    {
        config.transportType = type;
        return this;
    }
    
    /// Enable gRPC transport (shorthand)
    ref RemoteServiceBuilder useGrpc() return pure nothrow @safe @nogc
    {
        config.transportType = RemoteTransportType.Grpc;
        config.enableGrpcReapi = true;
        return this;
    }
    
    /// Enable TLS for transport
    ref RemoteServiceBuilder enableTls(string certPath, string keyPath, string caPath = "") return pure nothrow @safe
    {
        config.enableTls = true;
        config.tlsCertPath = certPath;
        config.tlsKeyPath = keyPath;
        config.tlsCaPath = caPath;
        return this;
    }
    
    /// Enable profile-guided scheduling with execution history from economics
    ref RemoteServiceBuilder withProfileScheduling(ExecutionHistory history) return @safe nothrow @nogc
    {
        config.enableProfileGuidedScheduling = true;
        config.executionHistory = history;
        return this;
    }
    
    /// Enable/disable adaptive work-stealing thresholds
    ref RemoteServiceBuilder adaptiveStealing(bool enabled = true) return pure nothrow @safe @nogc
    {
        config.enableAdaptiveStealThresholds = enabled;
        return this;
    }
    
    /// Build service
    RemoteExecutionService build(BuildGraph graph) @trusted
    {
        return new RemoteExecutionService(config, graph);
    }
}

