module infrastructure.di.container;

import infrastructure.telemetry.distributed.tracing : Tracer, Span, SpanKind, SpanStatus;
import infrastructure.utils.logging.structured : StructuredLogger, LogLevel;
import infrastructure.utils.simd.capabilities : SIMDCapabilities;
import infrastructure.config.schema.schema : WorkspaceConfig;
import infrastructure.errors;

/// Service Container Interface
/// Provides unified access to all injectable services for build execution.
/// This interface enables:
/// - Dependency injection throughout the build system
/// - Easy mocking for unit tests
/// - Explicit service dependencies
/// - Consistent service access pattern
interface IServiceContainer
{
    /// Get distributed tracer (may return null if tracing disabled)
    @property Tracer tracer() @trusted nothrow;
    
    /// Get structured logger (may return null if logging disabled)
    @property StructuredLogger logger() @trusted nothrow;
    
    /// Get SIMD capabilities (may return null if SIMD disabled)
    @property SIMDCapabilities simd() @trusted nothrow;
    
    /// Get workspace configuration
    @property WorkspaceConfig config() @trusted nothrow;
    
    /// Check if tracing is available
    bool hasTracing() const @safe nothrow;
    
    /// Check if structured logging is available  
    bool hasLogging() const @safe nothrow;
    
    /// Check if SIMD acceleration is available
    bool hasSIMD() const @safe nothrow;
}

/// Null service container for testing - all services return null/disabled
final class NullServiceContainer : IServiceContainer
{
    private WorkspaceConfig _config;
    
    this(WorkspaceConfig config = WorkspaceConfig.init) { _config = config; }
    
    @trusted nothrow {
        @property Tracer tracer() => null;
        @property StructuredLogger logger() => null;
        @property SIMDCapabilities simd() => null;
        @property WorkspaceConfig config() => _config;
    }
    
    @safe nothrow {
        bool hasTracing() const => false;
        bool hasLogging() const => false;
        bool hasSIMD() const => false;
    }
}

/// Configurable mock service container for testing
/// Allows injection of mock/stub services with configurable behavior
final class MockServiceContainer : IServiceContainer
{
    private Tracer _tracer;
    private StructuredLogger _logger;
    private SIMDCapabilities _simd;
    private WorkspaceConfig _config;
    
    /// Create mock container with optional services
    this(
        WorkspaceConfig config = WorkspaceConfig.init,
        Tracer tracer = null,
        StructuredLogger logger = null,
        SIMDCapabilities simd = null
    ) {
        _config = config;
        _tracer = tracer;
        _logger = logger;
        _simd = simd;
    }
    
    /// Create container with all services enabled (for integration tests)
    static MockServiceContainer withAllServices(WorkspaceConfig config = WorkspaceConfig.init) @trusted
    {
        auto container = new MockServiceContainer(config);
        container._logger = new StructuredLogger(LogLevel.Debug);
        container._simd = SIMDCapabilities.createMock();
        // Tracer requires exporter, leave null for mock
        return container;
    }
    
    /// Create container with logging only
    static MockServiceContainer withLogging(
        WorkspaceConfig config = WorkspaceConfig.init,
        LogLevel level = LogLevel.Debug
    ) @trusted {
        auto container = new MockServiceContainer(config);
        container._logger = new StructuredLogger(level);
        return container;
    }
    
    @trusted nothrow {
        @property Tracer tracer() => _tracer;
        @property StructuredLogger logger() => _logger;
        @property SIMDCapabilities simd() => _simd;
        @property WorkspaceConfig config() => _config;
        bool hasTracing() const => _tracer !is null;
        bool hasLogging() const => _logger !is null;
        bool hasSIMD() const => _simd !is null && _simd.active;
    }
    
    /// Builder methods for fluent configuration
    MockServiceContainer withTracer(Tracer t) { _tracer = t; return this; }
    MockServiceContainer withLogger(StructuredLogger l) { _logger = l; return this; }
    MockServiceContainer withSIMD(SIMDCapabilities s) { _simd = s; return this; }
    MockServiceContainer withConfig(WorkspaceConfig c) { _config = c; return this; }
}

/// Service scope - manages service lifetime within a build context
/// Ensures proper cleanup and prevents service leaks
struct ServiceScope
{
    private IServiceContainer _container;
    private bool _ownsContainer;
    private bool _initialized;
    
    @disable this();
    
    /// Private constructor for factory methods
    private this(IServiceContainer container, bool owns) @safe nothrow
    {
        _container = container;
        _ownsContainer = owns;
        _initialized = true;
    }
    
    /// Create scope with borrowed container (caller owns lifetime)
    static ServiceScope borrow(IServiceContainer container) @safe nothrow
    {
        return ServiceScope(container, false);
    }
    
    /// Create scope with owned container (scope manages lifetime)
    static ServiceScope own(IServiceContainer container) @safe nothrow
    {
        return ServiceScope(container, true);
    }
    
    /// Access the container
    @property IServiceContainer container() @safe nothrow => _container;
    
    /// Check if scope owns container
    @property bool ownsContainer() const @safe nothrow => _ownsContainer;
}

/// Unit tests
unittest
{
    // Test NullServiceContainer
    auto nullContainer = new NullServiceContainer();
    assert(nullContainer.tracer is null);
    assert(nullContainer.logger is null);
    assert(nullContainer.simd is null);
    assert(!nullContainer.hasTracing);
    assert(!nullContainer.hasLogging);
    assert(!nullContainer.hasSIMD);
}

unittest
{
    // Test MockServiceContainer builder pattern
    auto config = WorkspaceConfig.init;
    auto container = new MockServiceContainer(config);
    
    assert(container.tracer is null);
    assert(!container.hasTracing);
    
    // Test withLogging factory
    auto loggingContainer = MockServiceContainer.withLogging(config, LogLevel.Info);
    assert(loggingContainer.logger !is null);
    assert(loggingContainer.hasLogging);
}

unittest
{
    // Test ServiceScope borrowing
    auto container = new NullServiceContainer();
    auto scope_ = ServiceScope.borrow(container);
    
    assert(scope_.container is container);
    assert(!scope_.ownsContainer);
}

