# Observability

**Modules:**
- `infrastructure.telemetry.distributed.tracing`
- `infrastructure.utils.logging.structured`
- `infrastructure.telemetry.visualization.flamegraph`
- `infrastructure.telemetry.debugging.replay`

## Overview

Builder provides observability through distributed tracing, structured logging, flamegraph generation, and build replay for debugging.

---

## Distributed Tracing

OpenTelemetry-compatible span tracking for build operations.

**Module:** `infrastructure.telemetry.distributed.tracing`

### Components

- **TraceId** - 128-bit trace identifier
- **SpanId** - 64-bit span identifier  
- **Span** - Single traced operation with attributes and events
- **TraceContext** - Propagates trace identity (W3C Trace Context compatible)
- **SpanExporter** - Interface for trace backends

### Usage

```d
import infrastructure.telemetry.distributed.tracing;

auto tracer = new Tracer(new JaegerSpanExporter());

// Start trace
tracer.startTrace();

// Create span
auto span = tracer.startSpan("build-target", SpanKind.Internal);
scope(exit) tracer.finishSpan(span);

// Add attributes
span.setAttribute("target.id", "//backend:api");
span.setAttribute("target.language", "Rust");

// Add event
span.addEvent("compilation-started");

// Handle errors
try {
    // build logic
} catch (Exception e) {
    span.recordException(e);
    span.setStatus(SpanStatus.Error, e.msg);
}
```

### Nested Spans

```d
auto buildSpan = tracer.startSpan("build-all");
{
    auto compileSpan = tracer.startSpan("compile", SpanKind.Internal, buildSpan);
    // compile...
    tracer.finishSpan(compileSpan);
    
    auto linkSpan = tracer.startSpan("link", SpanKind.Internal, buildSpan);
    // link...
    tracer.finishSpan(linkSpan);
}
tracer.finishSpan(buildSpan);
```

### Context Propagation

```d
auto ctxResult = tracer.currentContext();
if (ctxResult.isOk) {
    auto ctx = ctxResult.unwrap();
    string header = ctx.toTraceparent();  // W3C format
}

// Parse from header
auto ctx = TraceContext.fromTraceparent(header);
```

### Exporters

**Console:**
```d
auto exporter = new ConsoleSpanExporter();
```

**Jaeger:**
```d
auto exporter = new JaegerSpanExporter(".builder-cache/traces/jaeger.json");
```

### Configuration

```bash
export BUILDER_TRACING_ENABLED=1       # Enable (default)
export BUILDER_TRACING_EXPORTER=jaeger # jaeger or console
export BUILDER_TRACING_OUTPUT=.builder-cache/traces/jaeger.json
```

---

## Structured Logging

Thread-safe logging with context and structured fields.

**Module:** `infrastructure.utils.logging.structured`

### Log Levels

- `Trace` - Detailed debug information
- `Debug` - Debug messages
- `Info` - Informational messages
- `Warning` - Warning conditions
- `Error` - Error conditions
- `Critical` - Critical failures

### Usage

```d
import infrastructure.utils.logging.structured;

auto logger = new StructuredLogger(LogLevel.Info);

// Simple log
logger.info("Building target");

// With structured fields
string[string] fields;
fields["target"] = "//backend:api";
fields["language"] = "Rust";
logger.info("Starting compilation", fields);
```

### Thread Context

```d
LogContext ctx;
ctx.targetId = "//backend:api";
ctx.correlationId = "build-12345";
ctx.fields["worker"] = "worker-3";
setLogContext(ctx);

// All logs from this thread include context
logger.info("Processing");
```

### Scoped Context

```d
{
    auto ctx = ScopedLogContext("//backend:api");
    logger.info("Starting build");  // Includes target ID
}  // Context restored on scope exit
```

### Per-Target Buffering

Logs are buffered per target for organized output:

```d
auto targetLogsResult = logger.exportTargetJson("//backend:api");
```

### Statistics

```d
auto stats = logger.getStats();
writefln("Total entries: %d", stats.totalEntries);
writefln("Errors: %d", stats.errorCount);
writefln("Targets logged: %d", stats.targetsLogged);
```

---

## Flamegraph Generation

Visualize build performance as interactive SVG flamegraphs.

**Module:** `infrastructure.telemetry.visualization.flamegraph`

### Usage

```d
import infrastructure.telemetry.visualization.flamegraph;

auto builder = new FlameGraphBuilder();

// Add stack samples
builder.addStackSample("build;frontend;compile;typescript", dur!"msecs"(1200));
builder.addStackSample("build;frontend;bundle;webpack", dur!"msecs"(800));
builder.addStackSample("build;backend;compile;rust", dur!"msecs"(2300));

// Generate SVG
auto svgResult = builder.toSVG(1200, 800);
if (svgResult.isOk) {
    import std.file : write;
    write("flamegraph.svg", svgResult.unwrap());
}
```

### From Build Sessions

```d
auto builderResult = buildFromSessions(sessions);
if (builderResult.isOk) {
    auto builder = builderResult.unwrap();
    saveFlamegraphSVG(builder, "flamegraph.svg");
}
```

### Folded Stacks Export

Compatible with flamegraph.pl:

```d
auto stacksResult = builder.toFoldedStacks();
if (stacksResult.isOk) {
    write("stacks.folded", stacksResult.unwrap());
}
```

```bash
cat stacks.folded | flamegraph.pl > flamegraph.svg
```

### Statistics

```d
auto stats = builder.getStats();
writefln("Total samples: %d", stats.totalSamples);
writefln("Total duration: %d ms", stats.totalDuration.total!"msecs");
writefln("Unique frames: %d", stats.uniqueFrames);
writefln("Max depth: %d", stats.maxDepth);
```

---

## Build Replay

Record and replay builds for debugging.

**Module:** `infrastructure.telemetry.debugging.replay`

### Recording

```d
import infrastructure.telemetry.debugging.replay;

auto recorder = new BuildRecorder();

// Start recording
recorder.startRecording(args);

// Record inputs
recorder.recordInput("src/main.rs");
recorder.recordInput("Cargo.toml");

// Record outputs
recorder.recordOutput("target/release/app");

// Add metadata
recorder.addMetadata("commit", "abc123");

// Stop and save
auto idResult = recorder.stopRecording();
```

### Replay

```d
auto engine = new ReplayEngine();

auto result = engine.replay("recording-id");
if (result.isOk) {
    auto replay = result.unwrap();
    
    if (!replay.success) {
        foreach (error; replay.errors)
            writeln("  - ", error);
    }
    
    foreach (diff; replay.differences) {
        writefln("  %s: %s - %s", diff.path, diff.type, diff.description);
    }
}
```

### List Recordings

```d
auto listResult = engine.listRecordings();
if (listResult.isOk) {
    foreach (info; listResult.unwrap()) {
        writefln("  %s - %s", info.recordingId, info.timestamp.toISOExtString());
    }
}
```

### CLI

```bash
# Record build
bldr build --record

# List recordings
builder replay list

# Replay specific build
builder replay <recording-id>

# Compare recordings
builder replay diff <id1> <id2>
```

---

## Integration

### ObservabilityService

Unified interface for events, tracing, and logging:

```d
interface IObservabilityService
{
    void publishEvent(BuildEvent event);
    Span startSpan(string name, SpanKind kind, Span parent = null);
    void finishSpan(Span span);
    void logInfo(string message, string[string] fields = null);
    void logDebug(string message, string[string] fields = null);
    void logError(string message, string[string] fields = null);
    void logException(Exception e, string message = "");
    void flush();
    void startTrace();
    @property Tracer tracer();
    @property StructuredLogger logger();
}
```

### Complete Example

```d
void buildWithObservability(Target target) {
    auto tracer = getTracer();
    auto logger = getStructuredLogger();
    
    tracer.startTrace();
    auto buildSpan = tracer.startSpan("build-target");
    scope(exit) tracer.finishSpan(buildSpan);
    
    buildSpan.setAttribute("target.id", target.id);
    
    auto ctx = ScopedLogContext(target.id);
    
    try {
        logger.info("Starting build");
        buildSpan.addEvent("build-started");
        
        // Compile phase
        auto compileSpan = tracer.startSpan("compile", SpanKind.Internal, buildSpan);
        logger.info("Compiling sources");
        // ... compile ...
        tracer.finishSpan(compileSpan);
        
        buildSpan.setStatus(SpanStatus.Ok);
        logger.info("Build successful");
        
    } catch (Exception e) {
        buildSpan.recordException(e);
        buildSpan.setStatus(SpanStatus.Error, e.msg);
        logger.exception(e, "Build failed");
        throw;
    } finally {
        tracer.flush();
    }
}
```

---

## Configuration

### Environment Variables

```bash
# Tracing
BUILDER_TRACING_ENABLED=1
BUILDER_TRACING_EXPORTER=jaeger
BUILDER_TRACING_OUTPUT=.builder-cache/traces/jaeger.json

# Logging
BUILDER_LOG_LEVEL=info
BUILDER_LOG_BUFFER=1
BUILDER_LOG_MAX_BUFFER=10000

# Recording
BUILDER_RECORD_ENABLED=0
BUILDER_RECORD_DIR=.builder-cache/recordings
```

---

## See Also

- [Telemetry](./telemetry.md)
- [Performance](./performance.md)
- [Concurrency](./concurrency.md)
