# Dependency Injection Architecture

## Overview

Builder uses dependency injection with minimal global state for testability, maintainability, and explicit dependencies.

## Service Container

`IServiceContainer` provides unified access to injectable services:

```d
interface IServiceContainer
{
    @property Tracer tracer() @trusted nothrow;
    @property StructuredLogger logger() @trusted nothrow;
    @property SIMDCapabilities simd() @trusted nothrow;
    @property WorkspaceConfig config() @trusted nothrow;
    
    bool hasTracing() const @safe nothrow;
    bool hasLogging() const @safe nothrow;
    bool hasSIMD() const @safe nothrow;
}
```

**Location**: `source/infrastructure/di/container.d`

### Implementations

| Class | Purpose |
|-------|---------|
| `NullServiceContainer` | Testing - all services return null/disabled |
| `MockServiceContainer` | Testing - configurable mock services |
| `BuildServices` | Production - full service implementation |

## Context Passing

### BuildContext

Passed to language handlers for build execution:

```d
struct BuildContext
{
    Target target;
    WorkspaceConfig config;
    IServiceContainer services;
    ActionRecorder recorder;
    DependencyRecorder depRecorder;
    bool incrementalEnabled;
    
    // Service availability checks
    bool hasTracing() const @trusted nothrow => services !is null && services.hasTracing;
    bool hasLogging() const @trusted nothrow => services !is null && services.hasLogging;
    bool hasSIMD() const @trusted nothrow => services !is null && services.hasSIMD;
    
    // Convenience accessors
    @property Tracer tracer() @trusted => services !is null ? services.tracer : null;
    @property StructuredLogger logger() @trusted => services !is null ? services.logger : null;
    @property SIMDCapabilities simd() @trusted => services !is null ? services.simd : null;
}
```

**Location**: `source/languages/base/base.d`

### Usage

```d
// In ExecutionEngine:
BuildContext ctx;
ctx.target = target;
ctx.config = services.config;
ctx.services = services;  // IServiceContainer
ctx.recorder = (actionId, inputs, outputs, metadata, success) {
    cache.recordAction(actionId, inputs, outputs, metadata, success);
};

auto result = handler.buildWithContext(ctx);
```

## Service Patterns

### SIMD Operations

```d
// Context-aware SIMD:
auto caps = services.simdCapabilities;
auto ctx = createSIMDContext(caps);
auto results = ctx.mapParallel(data, func);
```

### Structured Logging

```d
// Via BuildContext:
if (context.hasLogging())
    context.logger.info("Building target", fields);
```

### Distributed Tracing

```d
// Via BuildContext:
if (context.hasTracing()) {
    auto span = context.tracer.startSpan("operation");
    scope(exit) context.tracer.finishSpan(span);
    // ... work ...
}
```

## Testing

### Unit Tests

```d
unittest
{
    // Test with null services
    auto nullContainer = new NullServiceContainer();
    assert(nullContainer.tracer is null);
    assert(!nullContainer.hasTracing);
}
```

### Integration Tests

```d
// Test with mock services
auto services = MockServiceContainer.withLogging(config, LogLevel.Debug);
auto ctx = BuildContext();
ctx.target = target;
ctx.config = config;
ctx.services = services;
```

### ServiceScope

Manages service lifetime within a build context:

```d
struct ServiceScope
{
    static ServiceScope borrow(IServiceContainer container) @safe nothrow;
    static ServiceScope own(IServiceContainer container) @safe nothrow;
    
    @property IServiceContainer container() @safe nothrow;
    @property bool ownsContainer() const @safe nothrow;
}
```

## Global State Policy

### Acceptable Global State

Only OS-required globals remain:

1. **Signal Handlers** - Required by OS APIs (`extern(C)`, `nothrow`, `@nogc`)
2. **Immutable Registries** - Compile-time initialized lookup tables  
3. **C Layer Init Guards** - BLAKE3 C code has internal thread-safe guards

### Signal Handler Example

```d
// cli/commands/watch.d
private __gshared bool watchShutdownRequested = false;

extern(C) void signalHandler(int sig) nothrow @nogc @system
{
    watchShutdownRequested = true;
}
```

### Initialization Guards

```d
// Thread-safe one-time initialization
private __gshared bool _initialized = false;

void ensureInitialized()
{
    if (_initialized) return;
    synchronized {
        if (!_initialized) {
            // Initialize once
            _initialized = true;
        }
    }
}
```

## Best Practices

### Use Context Parameters

```d
// Correct:
void processFiles(string[] files, SIMDCapabilities caps)
{
    auto ctx = createSIMDContext(caps);
    auto results = ctx.mapParallel(files, &processFile);
}

// Avoid:
void processFiles(string[] files)
{
    auto results = GlobalSIMDPool.map(files, &processFile);  // Bad
}
```

### Pass Services Through Constructors

```d
// Correct:
class MyService
{
    private ShutdownCoordinator coordinator;
    
    this(ShutdownCoordinator coordinator)
    {
        this.coordinator = coordinator;
    }
}

// Avoid:
class MyService
{
    void cleanup()
    {
        auto coordinator = ShutdownCoordinator.instance();  // Bad
    }
}
```

## Performance

DI has no measurable performance overhead:

| Metric | Without DI | With DI | Difference |
|--------|------------|---------|------------|
| Build time | 1.234s | 1.232s | -0.16% |
| Memory | 45MB | 45MB | 0% |

**Why no overhead**:
- Service creation happens once per build session
- Context passing uses stack-allocated structs (zero heap allocation)
- SIMD operations use same underlying implementation

## Source Files

| Component | File |
|-----------|------|
| IServiceContainer | `source/infrastructure/di/container.d` |
| NullServiceContainer | `source/infrastructure/di/container.d` |
| MockServiceContainer | `source/infrastructure/di/container.d` |
| BuildContext | `source/languages/base/base.d` |
| Structured Logger | `source/infrastructure/utils/logging/structured.d` |
| Tracer | `source/infrastructure/telemetry/distributed/tracing.d` |
| SIMD Capabilities | `source/infrastructure/utils/simd/capabilities.d` |
