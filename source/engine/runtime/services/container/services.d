module engine.runtime.services.container.services;

import std.stdio : writeln, stdout;
import std.conv : to;
import engine.graph;
import engine.runtime.core.engine : ExecutionEngine;
import engine.runtime.services.registry : HandlerRegistry;
import engine.runtime.remote : IRemoteExecutionService, RemoteExecutionService, RemoteServiceBuilder, RemoteServiceConfig;
import engine.caching.targets.cache;
import engine.runtime.shutdown.shutdown : ShutdownCoordinator;
import engine.economics.integration : EconomicsIntegration;
import engine.economics.estimator : ExecutionHistory;
import infrastructure.telemetry;
import infrastructure.telemetry.distributed.tracing;
import infrastructure.telemetry.distributed.otlp : OtlpHttpExporter, OtlpConfig;
import infrastructure.utils.logging.structured;
import infrastructure.utils.logging;
import infrastructure.utils.simd.capabilities;
import infrastructure.config.schema.schema;
import infrastructure.config.parsing.parser;
import infrastructure.analysis.inference.analyzer;
import infrastructure.analysis.incremental.interface_;
import infrastructure.analysis.incremental.analyzer : IncrementalAnalyzer;
import infrastructure.analysis.caching.store : AnalysisCache;
import infrastructure.analysis.tracking.tracker : FileChangeTracker;
import frontend.cli.events.events;
import frontend.cli.display.render;
import infrastructure.errors;
import infrastructure.di : IServiceContainer;
import engine.workers : PersistentWorkerService, WorkerServiceConfig, initWorkerService, getWorkerService, shutdownWorkerService;
import engine.runtime.services.speculation : SpeculationService;
import infrastructure.utils.concurrency.parallel : shutdownSharedPool;

/// Service container for dependency injection
/// Implements IServiceContainer for formalized DI pattern.
/// 
/// Design Pattern: Service Locator + Dependency Injection
/// - Centralizes service creation and configuration
/// - Implements IServiceContainer for testability
/// - Enables testing with mock implementations
/// - Reduces coupling between command handlers and concrete types
/// 
/// Usage:
///   auto services = new BuildServices(config, options);
///   BuildContext ctx;
///   ctx.services = services;  // Inject container
final class BuildServices : IServiceContainer
{
    private WorkspaceConfig _config;
    private DependencyAnalyzer _analyzer;
    private BuildCache _cache;
    private EventPublisher _publisher;
    private Renderer _renderer;
    private TelemetryCollector _telemetryCollector;
    private TelemetryStorage _telemetryStorage;
    private RenderMode _renderMode;
    private bool _telemetryEnabled;
    private Tracer _tracer;
    private StructuredLogger _structuredLogger;
    private SIMDCapabilities _simdCapabilities;
    private HandlerRegistry _registry;
    private IRemoteExecutionService _remoteService;
    private ShutdownCoordinator _shutdownCoordinator;
    private EconomicsIntegration _economics;
    private IIncrementalAnalyzer _incrementalAnalyzer;
    private PersistentWorkerService _persistentWorkers;
    
    /// Create services with production configuration
    this(WorkspaceConfig config, BuildOptions options)
    {
        structuredLog.debug_("buildservices_starting_constructor").emit();
        this._config = config;
        this._renderMode = RenderMode.Auto;
        
        // Initialize SIMD capabilities early (detect hardware once)
        structuredLog.debug_("buildservices_initializing_simd").emit();
        this._initializeSIMD();
        
        // Initialize observability (tracing and structured logging)
        structuredLog.debug_("buildservices_initializing_observability").emit();
        this._initializeObservability();
        
        // Initialize shutdown coordinator (non-singleton, DI-based)
        structuredLog.debug_("buildservices_creating_shutdowncoordinat").emit();
        this._shutdownCoordinator = new ShutdownCoordinator();
        
        // Initialize event system (must be before cache service)
        structuredLog.debug_("buildservices_creating_eventpublisher").emit();
        this._publisher = new SimpleEventPublisher();
        
        // Initialize handler registry (handlers loaded lazily on-demand)
        structuredLog.debug_("buildservices_creating_handlerregistry").emit();
        this._registry = new HandlerRegistry();
        
        // Initialize cache (using coordinator for unified caching)
        import engine.runtime.services.caching : CacheService;
        structuredLog.debug_("buildservices_creating_cacheservice").emit();
        auto cacheService = new CacheService(options.cacheDir, this._publisher);
        this._cache = cacheService.getInternalCache();
        this._shutdownCoordinator.registerCache(this._cache);
        
        // Initialize incremental analyzer with dependency injection
        structuredLog.debug_("buildservices_creating_incrementalanalyz").emit();
        this._initializeIncrementalAnalyzer(config, options.cacheDir);
        
        // Initialize analyzer with injected incremental analyzer
        structuredLog.debug_("buildservices_creating_dependencyanalyze").emit();
        this._analyzer = new DependencyAnalyzer(config, this._incrementalAnalyzer, options.cacheDir);
        
        // Initialize economics (if enabled)
        structuredLog.debug_("buildservices_initializing_economics").emit();
        this._economics = new EconomicsIntegration(options.economics, options.cacheDir);
        
        // Initialize remote execution service (if enabled)
        structuredLog.debug_("buildservices_initializing_remote_execut").emit();
        this._initializeRemoteExecution(config, options);
        
        // Initialize persistent worker service for JVM/TypeScript compilation speedup
        structuredLog.debug_("buildservices_initializing_persistent_wo").emit();
        this._initializePersistentWorkers(options);
        
        // Initialize telemetry
        structuredLog.debug_("buildservices_initializing_telemetry").emit();
        auto telemetryConfig = TelemetryConfig.fromEnvironment();
        this._telemetryEnabled = telemetryConfig.enabled;
        if (this._telemetryEnabled)
        {
            this._telemetryCollector = new TelemetryCollector();
            this._telemetryStorage = new TelemetryStorage(".builder-cache/telemetry", telemetryConfig);
            this._publisher.subscribe(this._telemetryCollector);
        }
        
        // Log initialization (after _structuredLogger is initialized)
        if (this._structuredLogger !is null)
            this._structuredLogger.info("build_services_initialized").emit();
    }
    
    /// Initialize SIMD capabilities (hardware detection and dispatch)
    /// Called once at service initialization to eliminate repeated detection
    private void _initializeSIMD() @system
    {
        import std.process : environment;
        import std.parallelism : totalCPUs;
        
        try
        {
            // Check if SIMD should be disabled via environment
            auto simdDisabled = environment.get("BUILDER_SIMD_DISABLED", "0");
            if (simdDisabled == "1" || simdDisabled == "true")
            {
                // Create minimal capabilities (portable mode)
                this._simdCapabilities = SIMDCapabilities.createMock();
                return;
            }
            
            // Detect hardware and initialize SIMD dispatch
            // Thread pool size can be customized via environment
            auto poolSize = environment.get("BUILDER_SIMD_THREADS", "0");
            size_t threads = 0;
            if (poolSize.length > 0)
            {
                import std.conv : to;
                try { threads = poolSize.to!size_t; } catch (Exception) { threads = 0; }
            }
            
            this._simdCapabilities = SIMDCapabilities.detect(threads);
        }
        catch (Exception e)
        {
            // Fallback to mock capabilities if detection fails
            this._simdCapabilities = SIMDCapabilities.createMock();
        }
    }
    
    /// Initialize incremental analyzer with dependency injection
    /// Creates cache and tracker instances and wires them together
    private void _initializeIncrementalAnalyzer(WorkspaceConfig config, string cacheDir) @system
    {
        import std.path : buildPath;
        import std.process : environment;
        
        // Check if incremental analysis should be disabled
        auto incrementalDisabled = environment.get("BUILDER_INCREMENTAL_DISABLED", "0");
        if (incrementalDisabled == "1" || incrementalDisabled == "true")
        {
            this._incrementalAnalyzer = null;
            return;
        }
        
        try
        {
            // Create dependencies using DI pattern
            auto analysisCache = new AnalysisCache(buildPath(cacheDir, "analysis"));
            auto changeTracker = new FileChangeTracker();
            
            // Inject dependencies into analyzer
            this._incrementalAnalyzer = new IncrementalAnalyzer(config, analysisCache, changeTracker);
        }
        catch (Exception e)
        {
            // Fallback to null on initialization failure
            structuredLog.warning("failed_to_initialize_incremental_analyze").field("detail", "Failed to initialize incremental analyzer: " ~ e.msg).emit();
            this._incrementalAnalyzer = null;
        }
    }
    
    /// Initialize observability infrastructure
    /// Tracing is ENABLED BY DEFAULT for comprehensive observability
    /// 
    /// Environment variables:
    ///   BUILDER_TRACING_ENABLED    - "1" (default) or "0" to disable
    ///   BUILDER_TRACING_EXPORTER   - "otlp", "jaeger", "console" (default: jaeger)
    ///   BUILDER_TRACING_OUTPUT     - File path for jaeger exporter
    ///   BUILDER_OTLP_ENDPOINT      - OTLP endpoint URL (default: http://localhost:4318/v1/traces)
    ///   BUILDER_SERVICE_NAME       - Service name for traces (default: builder)
    ///   BUILDER_SERVICE_VERSION    - Service version
    ///   BUILDER_SAMPLING_RATIO     - Sampling ratio 0.0-1.0 (default: 1.0)
    private void _initializeObservability()
    {
        import std.process : environment;
        import std.conv : ConvException;
        
        // Initialize structured logger (always enabled)
        auto verbose = environment.get("BUILDER_VERBOSE", "0");
        auto minLevel = (verbose == "1" || verbose == "true") ? LogLevel.Debug : LogLevel.Info;
        this._structuredLogger = new StructuredLogger(minLevel);
        
        // Initialize distributed tracing (ENABLED BY DEFAULT)
        // Set BUILDER_TRACING_ENABLED=0 to disable
        auto tracingEnabled = environment.get("BUILDER_TRACING_ENABLED", "1");
        if (tracingEnabled != "0" && tracingEnabled != "false")
        {
            // Build tracer configuration
            TracerConfig tracerCfg;
            tracerCfg.serviceName = environment.get("BUILDER_SERVICE_NAME", "builder");
            tracerCfg.serviceVersion = environment.get("BUILDER_SERVICE_VERSION", "");
            
            // Parse sampling ratio
            auto samplingStr = environment.get("BUILDER_SAMPLING_RATIO", "1.0");
            try { tracerCfg.samplingRatio = samplingStr.to!double; }
            catch (ConvException) { tracerCfg.samplingRatio = 1.0; }
            
            // Determine exporter type from environment
            auto exporterType = environment.get("BUILDER_TRACING_EXPORTER", "jaeger");
            auto outputFile = environment.get("BUILDER_TRACING_OUTPUT", ".builder-cache/traces/jaeger.json");
            
            SpanExporter exporter;
            string exporterInfo;
            
            if (exporterType == "otlp")
            {
                // OTLP/HTTP exporter for Jaeger, Tempo, Grafana Cloud, etc.
                OtlpConfig otlpCfg;
                otlpCfg.endpoint = environment.get("BUILDER_OTLP_ENDPOINT", "http://localhost:4318/v1/traces");
                otlpCfg.serviceName = tracerCfg.serviceName;
                otlpCfg.serviceVersion = tracerCfg.serviceVersion;
                
                // Optional auth header for cloud providers
                auto authToken = environment.get("BUILDER_OTLP_AUTH_TOKEN", "");
                if (authToken.length > 0)
                    otlpCfg.headers["Authorization"] = "Bearer " ~ authToken;
                
                exporter = new OtlpHttpExporter(otlpCfg);
                exporterInfo = otlpCfg.endpoint;
            }
            else if (exporterType == "console")
            {
                exporter = new ConsoleSpanExporter();
                exporterInfo = "console";
            }
            else  // Default to Jaeger JSON file exporter
            {
                exporter = new JaegerSpanExporter(outputFile);
                exporterInfo = outputFile;
            }
            
            this._tracer = new Tracer(exporter, tracerCfg);
            this._structuredLogger.debug_("Distributed tracing enabled")
                .field("exporter", exporterType)
                .field("output", exporterInfo)
                .field("service", tracerCfg.serviceName)
                .field("sampling", tracerCfg.samplingRatio.to!string)
                .field("simd.level", this._simdCapabilities !is null ? this._simdCapabilities.implName : "unknown")
                .emit();
        }
        else
        {
            // Create disabled tracer (user explicitly disabled)
            this._tracer = new Tracer(null);
            this._tracer.setEnabled(false);
            
            this._structuredLogger.debug_("Distributed tracing disabled by user");
        }
    }
    
    /// Create services with explicit dependencies (for testing)
    /// Note: All dependencies must be properly injected - no defaults
    this(
        WorkspaceConfig config,
        DependencyAnalyzer analyzer,
        BuildCache cache,
        EventPublisher publisher,
        IIncrementalAnalyzer incrementalAnalyzer,
        Renderer renderer = null)
    {
        this._config = config;
        this._analyzer = analyzer;
        this._cache = cache;
        this._publisher = publisher;
        this._renderer = renderer;
        this._incrementalAnalyzer = incrementalAnalyzer;
        this._telemetryEnabled = false;
        
        // Initialize handler registry (handlers loaded lazily on-demand)
        this._registry = new HandlerRegistry();
        
        // Initialize SIMD and shutdown coordinator
        this._initializeSIMD();
        this._shutdownCoordinator = new ShutdownCoordinator();
    }
    
    // ========== IServiceContainer Interface Implementation ==========
    
    @trusted nothrow {
        /// Get distributed tracer (IServiceContainer)
        @property Tracer tracer() => _tracer;
        
        /// Get structured logger (IServiceContainer)
        @property StructuredLogger logger() => _structuredLogger;
        
        /// Get SIMD capabilities (IServiceContainer)
        @property SIMDCapabilities simd() => _simdCapabilities;
        
        /// Get workspace configuration (IServiceContainer)
        @property WorkspaceConfig config() => _config;
        
        /// Check if tracing is available (IServiceContainer)
        bool hasTracing() const => _tracer !is null;
        
        /// Check if structured logging is available (IServiceContainer)
        bool hasLogging() const => _structuredLogger !is null;
        
        /// Check if SIMD acceleration is available (IServiceContainer)
        bool hasSIMD() const => _simdCapabilities !is null && _simdCapabilities.active;
    }
    
    // ========== Additional Service Accessors ==========
    
    /// Get dependency analyzer
    @property DependencyAnalyzer analyzer() => _analyzer;
    
    /// Get build cache
    @property BuildCache cache() => _cache;
    
    /// Get event publisher
    @property EventPublisher publisher() => _publisher;
    
    /// Get telemetry collector (may be null if disabled)
    @property TelemetryCollector telemetryCollector() => _telemetryCollector;
    
    /// Get telemetry storage (may be null if disabled)
    @property TelemetryStorage telemetryStorage() => _telemetryStorage;
    
    /// Check if telemetry is enabled
    @property bool telemetryEnabled() => _telemetryEnabled;
    
    /// Get SIMD capabilities (legacy name, use `simd` for IServiceContainer)
    @property SIMDCapabilities simdCapabilities() => _simdCapabilities;
    
    /// Get handler registry
    @property HandlerRegistry registry() { return _registry; }
    
    /// Get shutdown coordinator
    @property ShutdownCoordinator shutdownCoordinator() { return _shutdownCoordinator; }
    
    /// Get economics integration
    @property EconomicsIntegration economics() { return _economics; }
    
    /// Create speculation service for critical path optimization
    /// Uses economics integration for cost estimation
    SpeculationService createSpeculationService(BuildGraph graph) @trusted
    {
        import engine.runtime.services.speculation;
        import engine.economics.estimator : CostEstimator;
        
        auto history = _economics !is null && _economics.isEnabled() 
            ? _economics.getExecutionHistory() 
            : new ExecutionHistory();
        auto estimator = new CostEstimator(history);
        auto service = new SpeculationService(estimator, graph);
        
        structuredLog.debug_("created_speculation_service_for_graph_wi").field("detail", "Created speculation service for graph with " ~ 
                       graph.nodes.length.to!string ~ " nodes").emit();
        return service;
    }
    
    /// Get incremental analyzer
    @property IIncrementalAnalyzer incrementalAnalyzer() { return _incrementalAnalyzer; }
    
    /// Set render mode for UI
    void setRenderMode(RenderMode mode)
    {
        this._renderMode = mode;
        // Recreate renderer if it exists
        if (this._renderer !is null)
        {
            this._renderer = RendererFactory.createWithPublisher(_publisher, mode);
        }
    }
    
    /// Get or create renderer
    Renderer getRenderer()
    {
        if (this._renderer is null)
        {
            this._renderer = RendererFactory.createWithPublisher(_publisher, _renderMode);
        }
        return this._renderer;
    }
    
    /// Create execution engine with modular service architecture
    /// 
    /// Parameters:
    ///   graph = Build graph to execute
    ///   maxParallelism = Maximum parallel tasks (0 = auto)
    ///   enableCheckpoints = Enable checkpoint/resume functionality
    ///   enableRetries = Enable automatic retry on failure
    ///   useWorkStealing = Use work-stealing scheduler (default: true for better load balancing)
    ExecutionEngine createEngine(
        BuildGraph graph,
        size_t maxParallelism = 0,
        bool enableCheckpoints = true,
        bool enableRetries = true,
        bool useWorkStealing = true)
    {
        import engine.runtime.core.engine;
        import engine.runtime.services;
        
        // Create scheduling service - work-stealing provides better load balancing
        auto schedulingMode = useWorkStealing ? SchedulingMode.WorkStealing : SchedulingMode.ThreadPool;
        auto scheduling = new SchedulingService(schedulingMode);
        
        structuredLog.debug_("engine_scheduling_mode")
            .field("mode", useWorkStealing ? "work_stealing" : "thread_pool")
            .emit();
        
        // Create cache service
        auto cacheService = new CacheService(".builder-cache");
        
        // Create observability service
        auto observability = new ObservabilityService(_publisher, _tracer, _structuredLogger);
        
        // Create resilience service
        auto resilience = new ResilienceService(enableRetries, enableCheckpoints, ".");
        
        // Get speculation settings from config
        bool enableSpeculation = _config.options.enableSpeculation;
        size_t speculationThreshold = _config.options.speculationThreshold;
        
        // Create execution engine with service container and speculation config
        return new ExecutionEngine(
            graph,
            scheduling,
            cacheService,
            observability,
            resilience,
            _registry,
            this,  // Pass self as IServiceContainer
            true,  // enableDynamicGraph
            enableSpeculation,
            speculationThreshold
        );
    }
    
    /// Persist telemetry data (if enabled)
    void saveTelemetry()
    {
        if (!_telemetryEnabled || _telemetryCollector is null || _telemetryStorage is null)
            return;
        
        auto sessionResult = _telemetryCollector.getSession();
        if (sessionResult.isOk)
        {
            auto session = sessionResult.unwrap();
            auto appendResult = _telemetryStorage.append(session);
            
            if (appendResult.isErr)
            {
                import infrastructure.utils.logging;
                structuredLog.warning("failed_to_persist_telemetry_").field("detail", "Failed to persist telemetry: " ~ appendResult.unwrapErr().toString()).emit();
            }
        }
    }
    
    /// Flush any pending output
    void flush()
    {
        if (_renderer !is null)
        {
            _renderer.flush();
        }
    }
    
    /// Cleanup and shutdown services
    /// Explicitly flushes all caches and persists state before termination
    void shutdown() @trusted
    {
        structuredLog.debug_("shutting_down_services").emit();
        
        // Stop persistent worker service (saves metrics)
        if (_persistentWorkers !is null)
        {
            structuredLog.debug_("shutting_down_persistent_workers").emit();
            shutdownWorkerService();  // Stops the global service
            _persistentWorkers = null;
        }
        
        // Stop remote execution service
        if (_remoteService !is null)
        {
            _remoteService.stop();
        }
        
        // Shutdown economics (save history, display summary)
        if (_economics !is null)
        {
            auto econResult = _economics.shutdown();
            if (econResult.isErr)
            {
                structuredLog.warning("economics_shutdown_failed_").field("detail", "Economics shutdown failed: " ~ econResult.unwrapErr().message()).emit();
            }
        }
        
        // Shutdown coordinator handles all cache cleanup
        if (_shutdownCoordinator !is null)
        {
            _shutdownCoordinator.shutdown();
        }
        
        // Persist telemetry
        saveTelemetry();
        
        // Flush renderer
        flush();
        
        // Shutdown SIMD capabilities
        if (_simdCapabilities !is null)
            _simdCapabilities.shutdown();
        
        // Shutdown shared thread pool
        shutdownSharedPool();
        
        structuredLog.debug_("services_shutdown_complete").emit();
    }
    
    /// Initialize remote execution service (if enabled)
    private void _initializeRemoteExecution(WorkspaceConfig config, BuildOptions options) @trusted
    {
        import std.process : environment;
        
        // Check if remote execution is enabled
        immutable distConfig = options.distributed;
        if (!distConfig.remoteExecution)
        {
            structuredLog.debug_("remote_execution_disabled").emit();
            return;
        }
        
        try
        {
            import engine.runtime.remote;
            
            // Build remote service configuration
            auto poolConfig = PoolConfig(
                minWorkers: distConfig.minWorkers,
                maxWorkers: distConfig.maxWorkers,
                enableAutoScale: distConfig.enableAutoScale
            );
            
            auto executorConfig = RemoteExecutorConfig(
                coordinatorUrl: distConfig.coordinatorUrl,
                artifactStoreUrl: distConfig.artifactStoreUrl,
                enableCaching: true,
                enableCompression: true
            );
            
            // Get build graph (would be passed from build context)
            // For now, create minimal graph - actual graph passed during execution
            auto graph = new BuildGraph();
            
            // Build remote service with profile-guided scheduling (shares economics history)
            auto builder = RemoteServiceBuilder.create()
                .coordinator("0.0.0.0", 9000)  // Default coordinator
                .pool(poolConfig)
                .executor(executorConfig)
                .enableReapi(9001)
                .enableMetrics(true);
            
            // Enable profile-guided scheduling if economics is available
            if (_economics !is null && _economics.isEnabled())
                builder.withProfileScheduling(_economics.getExecutionHistory());
            
            _remoteService = builder.build(graph);
            
            // Start service
            auto startResult = _remoteService.start();
            if (startResult.isErr)
            {
                structuredLog.warning("failed_to_start_remote_execution_service").field("detail", "Failed to start remote execution service: " ~
                             startResult.unwrapErr().message()).emit();
                _remoteService = null;
            }
            else
            {
                structuredLog.debug_("remote_execution_service_started").emit();
                structuredLog.debug_("__coordinator_").field("detail", "  Coordinator: " ~ distConfig.coordinatorUrl).emit();
                structuredLog.debug_("__workers_").field("detail", "  Workers: " ~ distConfig.minWorkers.to!string ~
                          "-" ~ distConfig.maxWorkers.to!string ~
                          " (autoscale: " ~ distConfig.enableAutoScale.to!string ~ ")").emit();
            }
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_initialize_remote_execution_").field("detail", "Failed to initialize remote execution: " ~ e.msg).emit();
            _remoteService = null;
        }
    }
    
    /// Get remote execution service (if available)
    IRemoteExecutionService remoteService() @property
    {
        return _remoteService;
    }
    
    /// Check if remote execution is available
    bool hasRemoteExecution() const @property
    {
        return _remoteService !is null;
    }
    
    /// Initialize persistent worker service for multi-language compilation
    /// Provides 3-50x speedup by keeping compilers warm
    private void _initializePersistentWorkers(BuildOptions options) @trusted
    {
        import std.process : environment;
        import core.time : minutes;
        
        // Check if persistent workers should be disabled via environment
        auto workersDisabled = environment.get("BUILDER_WORKERS_DISABLED", "0");
        if (workersDisabled == "1" || workersDisabled == "true")
        {
            structuredLog.debug_("persistent_workers_disabled_via_environm").emit();
            return;
        }
        
        try
        {
            import std.parallelism : totalCPUs;
            
            WorkerServiceConfig config;
            config.poolConfig.maxWorkersPerType = totalCPUs > 4 ? 4 : 2;
            config.poolConfig.idleTimeout = minutes(5);
            
            // Enable language-specific workers (can be overridden by env vars)
            config.enableJVMWorkers = environment.get("BUILDER_JVM_WORKERS", "1") != "0";
            config.enableTSWorkers = environment.get("BUILDER_TS_WORKERS", "1") != "0";
            config.enableRustWorkers = environment.get("BUILDER_RUST_WORKERS", "1") != "0";
            config.enableGoWorkers = environment.get("BUILDER_GO_WORKERS", "1") != "0";
            config.enablePythonWorkers = environment.get("BUILDER_PYTHON_WORKERS", "1") != "0";
            
            // Initialize global service (used by integration layer)
            initWorkerService(config);
            _persistentWorkers = getWorkerService();
            
            structuredLog.debug_("persistent_workers_initialized_jvmtsrust").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_initialize_persistent_workers_").field("detail", "Failed to initialize persistent workers: " ~ e.msg).emit();
            _persistentWorkers = null;
        }
    }
    
    /// Get persistent worker service (if available)
    PersistentWorkerService persistentWorkers() @property
    {
        return _persistentWorkers;
    }
    
    /// Check if persistent workers are available
    bool hasPersistentWorkers() const @property
    {
        return _persistentWorkers !is null;
    }
    
    /// Analyze build graph and emit persistent worker recommendations
    /// Call after graph analysis to suggest optimizations based on detected languages
    void emitWorkerRecommendations(BuildGraph graph) @trusted
    {
        import std.process : environment;
        import std.algorithm : canFind, filter, map;
        import std.array : array;
        
        if (graph is null) return;
        
        // Language-specific speedup info for recommendations
        static immutable struct WorkerInfo { string lang; string envVar; string speedup; size_t startupMs; }
        static immutable WorkerInfo[] workerInfos = [
            WorkerInfo("Java", "BUILDER_JVM_WORKERS", "16-53x", 800),
            WorkerInfo("Kotlin", "BUILDER_JVM_WORKERS", "20-67x", 2000),
            WorkerInfo("Scala", "BUILDER_JVM_WORKERS", "15-30x", 1500),
            WorkerInfo("TypeScript", "BUILDER_TS_WORKERS", "13-40x", 400),
            WorkerInfo("Go", "BUILDER_GO_WORKERS", "2-5x", 100),
            WorkerInfo("Python", "BUILDER_PYTHON_WORKERS", "15-50x", 1500),
        ];
        
        // Collect unique languages from graph
        TargetLanguage[] detectedLangs;
        foreach (node; graph.nodes.values)
        {
            if (!detectedLangs.canFind(node.target.language))
                detectedLangs ~= node.target.language;
        }
        
        // Check for languages that benefit from persistent workers
        bool hasRecommendations = false;
        
        foreach (info; workerInfos)
        {
            bool langDetected = false;
            switch (info.lang)
            {
                case "Java": langDetected = detectedLangs.canFind(TargetLanguage.Java); break;
                case "Kotlin": langDetected = detectedLangs.canFind(TargetLanguage.Kotlin); break;
                case "Scala": langDetected = detectedLangs.canFind(TargetLanguage.Scala); break;
                case "TypeScript": langDetected = detectedLangs.canFind(TargetLanguage.TypeScript); break;
                case "Go": langDetected = detectedLangs.canFind(TargetLanguage.Go); break;
                case "Python": langDetected = detectedLangs.canFind(TargetLanguage.Python); break;
                default: break;
            }
            
            if (!langDetected) continue;
            
            // Check if workers are disabled for this language
            auto envVal = environment.get(info.envVar, "1");
            if (envVal == "0" || envVal == "false")
            {
                structuredLog.info("persistent_worker_recommendation")
                    .field("language", info.lang)
                    .field("speedup", info.speedup)
                    .field("startup_ms", info.startupMs)
                    .field("action", "enable " ~ info.envVar ~ "=1")
                    .emit();
                hasRecommendations = true;
            }
            else if (_persistentWorkers is null)
            {
                // Workers configured but service failed to initialize
                structuredLog.warning("persistent_worker_unavailable")
                    .field("language", info.lang)
                    .field("potential_speedup", info.speedup)
                    .emit();
            }
        }
        
        // Log remote cache recommendation if not configured
        auto remoteUrl = environment.get("BUILDER_REMOTE_CACHE_URL", "");
        if (remoteUrl.length == 0 && graph.nodes.length > 20)
        {
            structuredLog.info("optimization_recommendation")
                .field("type", "remote_cache")
                .field("benefit", "team-wide cache sharing, 70-85% faster CI builds")
                .field("action", "set BUILDER_REMOTE_CACHE_URL=http://cache:8080")
                .emit();
        }
    }
}

