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
import infrastructure.telemetry;
import infrastructure.telemetry.distributed.tracing;
import infrastructure.utils.logging.structured;
import infrastructure.utils.logging.logger;
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

/// Service container for dependency injection
/// Manages the lifecycle and wiring of core build system components
/// 
/// Design Pattern: Service Locator + Dependency Injection
/// - Centralizes service creation and configuration
/// - Enables testing with mock implementations
/// - Reduces coupling between command handlers and concrete types
final class BuildServices
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
    
    /// Create services with production configuration
    this(WorkspaceConfig config, BuildOptions options)
    {
        Logger.debugLog("BuildServices: Starting constructor");
        this._config = config;
        this._renderMode = RenderMode.Auto;
        
        // Initialize SIMD capabilities early (detect hardware once)
        Logger.debugLog("BuildServices: Initializing SIMD");
        this._initializeSIMD();
        
        // Initialize observability (tracing and structured logging)
        Logger.debugLog("BuildServices: Initializing observability");
        this._initializeObservability();
        
        // Initialize shutdown coordinator (non-singleton, DI-based)
        Logger.debugLog("BuildServices: Creating ShutdownCoordinator");
        this._shutdownCoordinator = new ShutdownCoordinator();
        
        // Initialize event system (must be before cache service)
        Logger.debugLog("BuildServices: Creating EventPublisher");
        this._publisher = new SimpleEventPublisher();
        
        // Initialize handler registry (handlers loaded lazily on-demand)
        Logger.debugLog("BuildServices: Creating HandlerRegistry");
        this._registry = new HandlerRegistry();
        
        // Initialize cache (using coordinator for unified caching)
        import engine.runtime.services.caching : CacheService;
        Logger.debugLog("BuildServices: Creating CacheService");
        auto cacheService = new CacheService(options.cacheDir, this._publisher);
        this._cache = cacheService.getInternalCache();
        this._shutdownCoordinator.registerCache(this._cache);
        
        // Initialize incremental analyzer with dependency injection
        Logger.debugLog("BuildServices: Creating IncrementalAnalyzer with DI");
        this._initializeIncrementalAnalyzer(config, options.cacheDir);
        
        // Initialize analyzer with injected incremental analyzer
        Logger.debugLog("BuildServices: Creating DependencyAnalyzer");
        this._analyzer = new DependencyAnalyzer(config, this._incrementalAnalyzer, options.cacheDir);
        
        // Initialize economics (if enabled)
        Logger.debugLog("BuildServices: Initializing economics");
        this._economics = new EconomicsIntegration(options.economics, options.cacheDir);
        
        // Initialize remote execution service (if enabled)
        Logger.debugLog("BuildServices: Initializing remote execution");
        this._initializeRemoteExecution(config, options);
        
        // Initialize telemetry
        Logger.debugLog("BuildServices: Initializing telemetry");
        auto telemetryConfig = TelemetryConfig.fromEnvironment();
        this._telemetryEnabled = telemetryConfig.enabled;
        if (this._telemetryEnabled)
        {
            this._telemetryCollector = new TelemetryCollector();
            this._telemetryStorage = new TelemetryStorage(".builder-cache/telemetry", telemetryConfig);
            this._publisher.subscribe(this._telemetryCollector);
        }
        
        // Log initialization (after _structuredLogger is initialized)
        Logger.debugLog("BuildServices: Finalizing constructor");
        if (this._structuredLogger !is null)
            this._structuredLogger.info("Build services initialized", [
                "cache_dir": options.cacheDir,
                "telemetry_enabled": this._telemetryEnabled.to!string
            ]);
        Logger.debugLog("BuildServices: Constructor complete");
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
            Logger.warning("Failed to initialize incremental analyzer: " ~ e.msg);
            this._incrementalAnalyzer = null;
        }
    }
    
    /// Initialize observability infrastructure
    /// Tracing is ENABLED BY DEFAULT for comprehensive observability
    private void _initializeObservability()
    {
        import std.process : environment;
        import std.conv : to;
        
        // Initialize structured logger (always enabled)
        auto verbose = environment.get("BUILDER_VERBOSE", "0");
        auto minLevel = (verbose == "1" || verbose == "true") ? LogLevel.Debug : LogLevel.Info;
        this._structuredLogger = new StructuredLogger(minLevel);
        
        // Initialize distributed tracing (ENABLED BY DEFAULT)
        // Set BUILDER_TRACING_ENABLED=0 to disable
        auto tracingEnabled = environment.get("BUILDER_TRACING_ENABLED", "1");
        if (tracingEnabled != "0" && tracingEnabled != "false")
        {
            // Determine exporter type from environment
            auto exporterType = environment.get("BUILDER_TRACING_EXPORTER", "jaeger");
            auto outputFile = environment.get("BUILDER_TRACING_OUTPUT", ".builder-cache/traces/jaeger.json");
            
            SpanExporter exporter;
            if (exporterType == "console")
            {
                exporter = new ConsoleSpanExporter();
            }
            else  // Default to Jaeger
            {
                exporter = new JaegerSpanExporter(outputFile);
            }
            
            this._tracer = new Tracer(exporter);
            this._structuredLogger.debug_("Distributed tracing enabled (default)", [
                "exporter": exporterType,
                "output": (exporterType == "console") ? "console" : outputFile,
                "simd.level": this._simdCapabilities !is null ? this._simdCapabilities.implName : "unknown"
            ]);
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
    
    /// Get workspace configuration
    @property WorkspaceConfig config() { return _config; }
    
    /// Get dependency analyzer
    @property DependencyAnalyzer analyzer() { return _analyzer; }
    
    /// Get build cache
    @property BuildCache cache() { return _cache; }
    
    /// Get event publisher
    @property EventPublisher publisher() { return _publisher; }
    
    /// Get telemetry collector (may be null if disabled)
    @property TelemetryCollector telemetryCollector() { return _telemetryCollector; }
    
    /// Get telemetry storage (may be null if disabled)
    @property TelemetryStorage telemetryStorage() { return _telemetryStorage; }
    
    /// Check if telemetry is enabled
    @property bool telemetryEnabled() { return _telemetryEnabled; }
    
    /// Get SIMD capabilities
    @property SIMDCapabilities simdCapabilities() { return _simdCapabilities; }
    
    /// Get handler registry
    @property HandlerRegistry registry() { return _registry; }
    
    /// Get shutdown coordinator
    @property ShutdownCoordinator shutdownCoordinator() { return _shutdownCoordinator; }
    
    /// Get economics integration
    @property EconomicsIntegration economics() { return _economics; }
    
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
    ///   useWorkStealing = Use work-stealing scheduler (vs simple thread pool)
    ExecutionEngine createEngine(
        BuildGraph graph,
        size_t maxParallelism = 0,
        bool enableCheckpoints = true,
        bool enableRetries = true,
        bool useWorkStealing = false)
    {
        import engine.runtime.core.engine;
        import engine.runtime.services;
        
        // Create scheduling service
        auto schedulingMode = useWorkStealing ? SchedulingMode.WorkStealing : SchedulingMode.ThreadPool;
        auto scheduling = new SchedulingService(schedulingMode);
        
        // Create cache service
        auto cacheService = new CacheService(".builder-cache");
        
        // Create observability service
        auto observability = new ObservabilityService(_publisher, _tracer, _structuredLogger);
        
        // Create resilience service
        auto resilience = new ResilienceService(enableRetries, enableCheckpoints, ".");
        
        // Use existing handler registry (already initialized in constructor)
        // No need to create/initialize again - avoids duplicate handler registration
        
        // Create execution engine with SIMD capabilities
        return new ExecutionEngine(
            graph,
            _config,
            scheduling,
            cacheService,
            observability,
            resilience,
            _registry,
            _simdCapabilities
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
                import infrastructure.utils.logging.logger;
                Logger.warning("Failed to persist telemetry: " ~ appendResult.unwrapErr().toString());
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
        Logger.debugLog("Shutting down services...");
        
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
                Logger.warning("Economics shutdown failed: " ~ econResult.unwrapErr().message());
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
        
        Logger.debugLog("Services shutdown complete");
    }
    
    /// Initialize remote execution service (if enabled)
    private void _initializeRemoteExecution(WorkspaceConfig config, BuildOptions options) @trusted
    {
        import std.process : environment;
        
        // Check if remote execution is enabled
        immutable distConfig = options.distributed;
        if (!distConfig.remoteExecution)
        {
            Logger.debugLog("Remote execution disabled");
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
                Logger.warning("Failed to start remote execution service: " ~
                             startResult.unwrapErr().message());
                _remoteService = null;
            }
            else
            {
                Logger.debugLog("Remote execution service started");
                Logger.debugLog("  Coordinator: " ~ distConfig.coordinatorUrl);
                Logger.debugLog("  Workers: " ~ distConfig.minWorkers.to!string ~
                          "-" ~ distConfig.maxWorkers.to!string ~
                          " (autoscale: " ~ distConfig.enableAutoScale.to!string ~ ")");
            }
        }
        catch (Exception e)
        {
            Logger.error("Failed to initialize remote execution: " ~ e.msg);
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
}

