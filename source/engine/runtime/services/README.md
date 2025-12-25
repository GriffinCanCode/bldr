# Runtime Services

This module provides the core service infrastructure for the Builder build system. It implements a modular, dependency-injection based architecture that decouples components and enables testing.

## Architecture

The services module follows a **Service Locator + Dependency Injection** pattern:
- Centralizes service creation and configuration
- Enables testing with mock implementations
- Reduces coupling between command handlers and concrete types
- Provides lifecycle management for all core components

## Module Organization

```
services/
├── container/          # Service container and factory
│   ├── services.d     # BuildServices - main DI container
│   ├── factory.d      # ServiceFactory - creation methods
│   └── package.d      # Barrel exports
│
├── caching/           # Cache service abstraction
│   ├── service.d      # Unified cache interface
│   └── package.d      # Barrel exports
│
├── observability/     # Observability infrastructure
│   ├── service.d      # Events, tracing, and logging
│   └── package.d      # Barrel exports
│
├── resilience/        # Resilience patterns
│   ├── service.d      # Retry and checkpoint/resume
│   └── package.d      # Barrel exports
│
├── registry/          # Language handler registry
│   ├── handler.d      # Handler lookup and lifecycle
│   └── package.d      # Barrel exports
│
├── scheduling/        # Task scheduling
│   ├── service.d      # Work-stealing and thread-pool scheduling
│   └── package.d      # Barrel exports
│
├── speculation/       # Speculative execution
│   ├── service.d      # Critical path speculation service
│   ├── executor.d     # Speculation executor integration
│   ├── README.md      # Speculation documentation
│   └── package.d      # Barrel exports
│
├── package.d          # Root barrel export
└── README.md          # This file
```

## Core Services

### Container (`container/`)

The **BuildServices** container is the main dependency injection container. It manages the lifecycle of all core components:

```d
import engine.runtime.services;

auto services = ServiceFactory.createProduction(config, options);

// Access configured services
auto cache = services.cache;
auto analyzer = services.analyzer;
auto registry = services.registry;

// Create execution engine with services
auto engine = services.createEngine(graph);
```

### Caching (`caching/`)

The **CacheService** provides a unified interface to the caching subsystem:

- Target-level caching (BuildCache)
- Action-level caching (ActionCache)
- Remote caching via CacheCoordinator
- Unified statistics and metrics

```d
auto cacheService = new CacheService(".builder-cache");

if (cacheService.isCached(targetId, sources, deps))
{
    // Skip build
}
else
{
    // Build and update cache
    cacheService.update(targetId, sources, deps, outputHash);
}
```

### Observability (`observability/`)

The **ObservabilityService** unifies three observability pillars:

1. **Events** - Build lifecycle events
2. **Tracing** - Distributed tracing (OpenTelemetry-compatible)
3. **Logging** - Structured logging with context

```d
auto obs = new ObservabilityService(publisher, tracer, logger);

auto span = obs.startSpan("build-target", SpanKind.Internal);
obs.logInfo("Building target", ["target": targetId]);
obs.finishSpan(span);
```

### Resilience (`resilience/`)

The **ResilienceService** provides fault-tolerance patterns:

- **Retry logic** - Exponential backoff with policies
- **Checkpointing** - Save build progress
- **Resume** - Continue from checkpoint after failure

```d
auto resilience = new ResilienceService(enableRetries: true, enableCheckpoints: true);

auto result = resilience.withRetryString(targetId, () {
    return buildTarget(targetId);
}, policy);

if (resilience.hasCheckpoint())
{
    auto plan = resilience.planResume(graph);
}
```

### Registry (`registry/`)

The **HandlerRegistry** manages language-specific build handlers:

- Lazy initialization (handlers created on-demand)
- Support for 25+ languages
- Dynamic registration for plugins

```d
auto registry = new HandlerRegistry();
registry.initialize();

auto handler = registry.get(TargetLanguage.Python);
if (handler !is null)
{
    BuildContext context;
    context.target = target;
    context.config = config;
    context.services = services;  // IServiceContainer (DI)
    auto result = handler.buildWithContext(context);
}
```

### Scheduling (`scheduling/`)

The **SchedulingService** provides parallel task execution:

- **Work-stealing scheduler** - Load balancing across workers
- **Thread-pool scheduler** - Simple parallelism
- **Adaptive mode** - Dynamic strategy selection

```d
auto scheduler = new SchedulingService(SchedulingMode.WorkStealing);
scheduler.initialize(maxParallelism: 8);

scheduler.submit(node, Priority.High);
auto results = scheduler.executeBatch(nodes, executor);
```

### Speculation (`speculation/`)

The **SpeculationService** provides speculative execution for critical path optimization:

- **Critical path analysis** - Identify the longest weighted path
- **Speculative execution** - Pre-execute likely-needed targets
- **Abort semantics** - Cancel speculation if inputs change
- **Economics integration** - Use cost estimation for decisions

```d
auto speculation = createSpeculationService(graph, executionHistory);
speculation.setPolicy(SpeculationPolicy.balanced());
speculation.analyzeGraph(graph);

// During build loop
if (auto result = speculation.getValidResult(targetId))
    useSpeculativeResult(result);  // Use pre-computed result
else
    executeNormally(targetId);

// Notify on input change
speculation.notifyInputChanged(path, newHash);  // Aborts affected speculation
```

See `speculation/README.md` for detailed documentation.

## Usage Patterns

### Production Use

```d
import engine.runtime.services;

// Create production services with auto-configuration
auto servicesResult = ServiceFactory.createFromWorkspace(".", options);
if (servicesResult.isErr)
    return servicesResult.unwrapErr();

auto services = servicesResult.unwrap();

// Build with services
auto engine = services.createEngine(graph);
auto result = engine.execute();

// Cleanup
services.shutdown();
```

### Testing

```d
import engine.runtime.services;

// Create services with mocks
auto mockAnalyzer = new MockDependencyAnalyzer();
auto mockCache = new MockBuildCache();
auto mockPublisher = new MockEventPublisher();

auto services = ServiceFactory.createForTesting(
    config, mockAnalyzer, mockCache, mockPublisher
);

// Test with mocked dependencies
auto engine = services.createEngine(graph);
```

### Custom Service Configuration

```d
import engine.runtime.services;

// Create custom service instances
auto scheduling = new SchedulingService(SchedulingMode.Adaptive);
auto caching = new CacheService(customCacheDir);
auto observability = new ObservabilityService(publisher, tracer, logger);
auto resilience = new ResilienceService(enableRetries: false);

// Wire together manually
auto engine = new ExecutionEngine(
    graph, config, scheduling, caching, 
    observability, resilience, registry, simd
);
```

## Design Principles

### 1. Interface-Based Design

Each service defines an interface (`IXxxService`) and a concrete implementation:

```d
interface ICacheService { ... }
final class CacheService : ICacheService { ... }
```

This enables:
- Mock implementations for testing
- Alternative implementations (e.g., `NullCacheService`)
- Runtime strategy selection

### 2. Dependency Injection

Services receive dependencies via constructor injection:

```d
this(EventPublisher publisher, Tracer tracer, StructuredLogger logger)
{
    this.publisher = publisher;
    this.tracer = tracer;
    this.logger = logger;
}
```

Benefits:
- Explicit dependencies (no hidden global state)
- Testability (inject mocks)
- Flexibility (swap implementations)

### 3. Lifecycle Management

The `BuildServices` container manages service lifecycles:

```d
// Initialize in correct order
this(WorkspaceConfig config, BuildOptions options)
{
    _initializeSIMD();           // Hardware detection first
    _initializeObservability();  // Logging/tracing second
    _initializeCache();          // Cache with observability
    _initializeRemote();         // Remote execution last
}

// Shutdown in reverse order
void shutdown()
{
    _remoteService.stop();
    flush();
    _shutdownCoordinator.shutdown();
    saveTelemetry();
    _simdCapabilities.shutdown();
}
```

### 4. Modular Organization

Each service is in its own folder with:
- `service.d` - Implementation
- `package.d` - Barrel export
- Additional files as needed

### 5. Fail-Safe Defaults

Services provide sensible defaults and graceful degradation:

```d
// Tracing enabled by default
auto tracingEnabled = environment.get("BUILDER_TRACING_ENABLED", "1");

// Null services for disabled features
final class NullObservabilityService : IObservabilityService { ... }
```

## Extension Points

### Adding a New Service

1. Create service folder: `services/myservice/`
2. Define interface: `interface IMyService { ... }`
3. Implement service: `final class MyService : IMyService { ... }`
4. Create barrel export: `services/myservice/package.d`
5. Export from root: `services/package.d`
6. Wire in container: `container/services.d`

### Custom Language Handler

```d
import engine.runtime.services.registry;

class MyLanguageHandler : LanguageHandler
{
    override BuildResult!string build(Target target, WorkspaceConfig config)
    {
        // Custom build logic
    }
}

// Register with registry
registry.register(TargetLanguage.Custom, new MyLanguageHandler());
```

## Best Practices

1. **Always use interfaces** - Program to interfaces, not implementations
2. **Inject dependencies** - Avoid global state and singletons
3. **Manage lifecycles** - Properly initialize and shutdown services
4. **Use barrel exports** - Import from module root, not individual files
5. **Test with mocks** - Use null/mock services for testing
6. **Handle errors** - All service methods return `Result` types
7. **Log appropriately** - Use observability service for all logging

## Testing

Each service provides null/mock implementations for testing:

```d
import engine.runtime.services;

// Use null services for unit testing
auto nullCache = new NullCacheService();
auto nullObs = new NullObservabilityService();
auto nullResilience = new NullResilienceService();

// Test in isolation
auto scheduler = new SchedulingService();
unittest
{
    scheduler.initialize(4);
    assert(scheduler.workerCount == 4);
}
```

## Performance Considerations

- **Lazy initialization** - Services initialized on-demand (e.g., HandlerRegistry)
- **SIMD optimization** - Hardware-accelerated hashing via SIMDCapabilities
- **Work-stealing** - Optimal load balancing for parallel builds
- **Lock-free queues** - Minimal contention in scheduling
- **Unified caching** - Single coordinator reduces overhead

## Migration Guide

### From Old Structure

Old imports:
```d
import engine.runtime.services.services;
import engine.runtime.services.cache;
import engine.runtime.services.observability;
```

New imports:
```d
import engine.runtime.services;  // Everything in one import
// Or specific modules:
import engine.runtime.services.caching;
import engine.runtime.services.observability;
```

All public APIs remain the same, only module paths changed.

## See Also

- [Architecture Overview](../../../docs/architecture/overview.md)
- [Dependency Injection](../../../docs/architecture/dependency-injection.md)
- [Testing Guide](../../../docs/user-guides/testing.md)
- [Caching Design](../../../docs/architecture/cachedesign.md)

