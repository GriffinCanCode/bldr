# Observability & Debugging

Builder provides comprehensive observability and debugging tools for understanding, optimizing, and troubleshooting your builds.

## Table of Contents

- [Distributed Tracing](#distributed-tracing)
- [Structured Logging](#structured-logging)
- [Flamegraph Generation](#flamegraph-generation)
- [Build Replay](#build-replay)
- [Integration](#integration)
- [Best Practices](#best-practices)

---

## Distributed Tracing

Distributed tracing provides end-to-end visibility into build execution with OpenTelemetry-compatible spans.

### Features

- **W3C Trace Context**: Compatible with OpenTelemetry standard
- **Span Tracking**: Hierarchical tracking of build operations
- **Context Propagation**: Trace context flows across threads
- **Multiple Exporters**: Jaeger, Zipkin, Console
- **Zero Overhead**: Minimal performance impact when disabled

### Usage

#### Basic Tracing

```d
import core.telemetry.tracing;

// Get global tracer
auto tracer = getTracer();

// Start a trace
tracer.startTrace();

// Create a span
auto span = tracer.startSpan("build-target", SpanKind.Internal);
scope(exit) tracer.finishSpan(span);

// Add attributes
span.setAttribute("target.id", "//backend:api");
span.setAttribute("target.language", "Rust");

// Add events
span.addEvent("compilation-started");

// Record errors
try {
    // ... build logic ...
} catch (Exception e) {
    span.recordException(e);
    span.setStatus(SpanStatus.Error, e.msg);
}
```

#### Nested Spans

```d
auto buildSpan = tracer.startSpan("build-all");
{
    auto compileSpan = tracer.startSpan("compile", SpanKind.Internal, buildSpan);
    // ... compile ...
    tracer.finishSpan(compileSpan);
    
    auto linkSpan = tracer.startSpan("link", SpanKind.Internal, buildSpan);
    // ... link ...
    tracer.finishSpan(linkSpan);
}
tracer.finishSpan(buildSpan);
```

#### Context Propagation

```d
// Get current trace context
auto ctxResult = tracer.currentContext();
if (ctxResult.isOk) {
    auto ctx = ctxResult.unwrap();
    
    // Serialize for passing to child process
    string header = ctx.toTraceparent();
    // Pass via HTTP header or environment variable
}

// Parse from header
auto ctxResult = TraceContext.fromTraceparent(header);
if (ctxResult.isOk) {
    auto ctx = ctxResult.unwrap();
    // Continue trace in child process
}
```

### Exporters

#### Jaeger Exporter

```d
import core.telemetry.tracing;

auto exporter = new JaegerSpanExporter(".builder-cache/traces/jaeger.json");
auto tracer = new Tracer(exporter);
setTracer(tracer);
```

View traces in Jaeger UI:
```bash
# Start Jaeger
docker run -d -p 16686:16686 -p 14268:14268 jaegertracing/all-in-one:latest

# Open UI
open http://localhost:16686

# Import traces
# Jaeger UI > Upload > Select .builder-cache/traces/jaeger.json
```

#### Console Exporter

```d
auto exporter = new ConsoleSpanExporter();
auto tracer = new Tracer(exporter);
setTracer(tracer);
```

Output:
```
TRACE: a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6
  Span: build-target [1234567890abcdef]
  Duration: 2341ms
  Status: Ok
  Attributes:
    target.id: //backend:api
    target.language: Rust
  Events:
    [2025-10-27T14:23:15] compilation-started
```

### Configuration

```bash
# Enable tracing
export BUILDER_TRACING_ENABLED=1

# Set exporter
export BUILDER_TRACING_EXPORTER=jaeger  # jaeger, zipkin, console

# Set sampling rate (0.0 - 1.0)
export BUILDER_TRACING_SAMPLE_RATE=1.0
```

---

## Structured Logging

Structured logging provides thread-safe, context-aware logging for parallel builds.

### Features

- **Thread Context**: Automatic thread ID and target tracking
- **Structured Fields**: Key-value metadata
- **Per-Target Buffering**: Separate logs for each target
- **JSON Export**: Export logs for aggregation
- **Correlation IDs**: Track related operations

### Usage

#### Basic Logging

```d
import utils.logging.structured;

auto logger = getStructuredLogger();

// Simple log
logger.info("Building target");

// With structured fields
string[string] fields;
fields["target"] = "//backend:api";
fields["language"] = "Rust";
logger.info("Starting compilation", fields);

// Different levels
logger.trace("Detailed debug info");
logger.debug_("Debug information");
logger.warning("Performance warning");
logger.error("Build failed");
logger.critical("System error");
```

#### Scoped Context

```d
import utils.logging.structured;

auto logger = getStructuredLogger();

{
    // Set context for this scope
    auto ctx = ScopedLogContext("//backend:api");
    
    logger.info("Starting build");  // Automatically includes target ID
    logger.info("Compiling...");    // Same context
    
    // Context cleared when scope exits
}
```

#### Thread Context

```d
import utils.logging.structured;

// Set context for current thread
LogContext ctx;
ctx.targetId = "//backend:api";
ctx.correlationId = "build-12345";
ctx.fields["worker"] = "worker-3";
setLogContext(ctx);

// All logs from this thread include context
logger.info("Processing");  // [//backend:api:thread-123] Processing {worker=worker-3}
```

#### Exception Logging

```d
try {
    // ... build logic ...
} catch (Exception e) {
    logger.exception(e, "Compilation failed");
    // Automatically captures stack trace and exception details
}
```

### Export Logs

#### JSON Export

```d
// Export all logs
auto jsonResult = logger.exportJson();
if (jsonResult.isOk) {
    writeln(jsonResult.unwrap());
}

// Export logs for specific target
auto targetLogsResult = logger.exportTargetJson("//backend:api");
if (targetLogsResult.isOk) {
    writeln(targetLogsResult.unwrap());
}
```

#### Save to File

```d
// Save all logs
auto result = logger.saveLogs(".builder-cache/logs/build.json");

// Save target-specific logs
auto result = logger.saveTargetLogs("//backend:api", ".builder-cache/logs/api.json");
```

### Statistics

```d
auto stats = logger.getStats();
writefln("Total entries: %d", stats.totalEntries);
writefln("Errors: %d", stats.errorCount);
writefln("Targets logged: %d", stats.targetsLogged);
```

### Configuration

```bash
# Set minimum log level
export BUILDER_LOG_LEVEL=debug  # trace, debug, info, warning, error, critical

# Enable buffering
export BUILDER_LOG_BUFFER=1

# Set max buffer size
export BUILDER_LOG_MAX_BUFFER=10000
```

---

## Flamegraph Generation

Flamegraph generation visualizes build performance in an interactive SVG.

### Features

- **Hierarchical Visualization**: See build structure at a glance
- **SVG Output**: Interactive, zoomable flamegraphs
- **Folded Stack Format**: Compatible with flamegraph.pl
- **Target Dependencies**: Visualize dependency tree performance
- **Time Proportional**: Width represents time spent

### Usage

#### Generate from Telemetry

```d
import core.telemetry;

// Get build sessions
auto storage = new TelemetryStorage();
auto sessionsResult = storage.getRecent(10);

if (sessionsResult.isOk) {
    auto sessions = sessionsResult.unwrap();
    
    // Build flamegraph
    auto builderResult = buildFromSessions(sessions);
    if (builderResult.isOk) {
        auto builder = builderResult.unwrap();
        
        // Generate SVG
        auto svgResult = builder.toSVG(1200, 800);
        if (svgResult.isOk) {
            import std.file : write;
            write("flamegraph.svg", svgResult.unwrap());
        }
    }
}
```

#### Generate from Single Session

```d
import core.telemetry;

// Get latest session
auto collector = new TelemetryCollector();
auto sessionResult = collector.getSession();

if (sessionResult.isOk) {
    auto session = sessionResult.unwrap();
    
    // Build dependency flamegraph
    auto builderResult = buildDependencyFlame(session);
    if (builderResult.isOk) {
        auto builder = builderResult.unwrap();
        
        // Save SVG
        auto result = saveFlamegraphSVG(builder, "build-flame.svg");
    }
}
```

#### Custom Stack Samples

```d
import core.telemetry.flamegraph;

auto builder = new FlameGraphBuilder();

// Add custom stack samples
builder.addStackSample("build;frontend;compile;typescript", dur!"msecs"(1200));
builder.addStackSample("build;frontend;bundle;webpack", dur!"msecs"(800));
builder.addStackSample("build;backend;compile;rust", dur!"msecs"(2300));

// Generate
auto svgResult = builder.toSVG();
```

#### Export for flamegraph.pl

```d
// Export folded stacks
auto stacksResult = builder.toFoldedStacks();
if (stacksResult.isOk) {
    import std.file : write;
    write("stacks.folded", stacksResult.unwrap());
}
```

Use with flamegraph.pl:
```bash
# Generate flamegraph using Brendan Gregg's tool
cat stacks.folded | flamegraph.pl > flamegraph.svg

# Open in browser
open flamegraph.svg
```

### Statistics

```d
auto stats = builder.getStats();
writefln("Total samples: %d", stats.totalSamples);
writefln("Total duration: %d ms", stats.totalDuration.total!"msecs");
writefln("Unique frames: %d", stats.uniqueFrames);
writefln("Max depth: %d", stats.maxDepth);
```

### CLI Integration

```bash
# Generate flamegraph for last build
bldr telemetry flamegraph > flamegraph.svg

# Generate for multiple builds
bldr telemetry flamegraph --recent 10 > flamegraph.svg

# Export folded stacks
bldr telemetry flamegraph --format folded > stacks.folded
```

---

## Build Replay

Build replay enables deterministic reproduction and debugging of builds.

### Features

- **Complete Recording**: Capture inputs, outputs, environment
- **Deterministic Replay**: Reproduce builds exactly
- **Diff Analysis**: Compare recordings to find differences
- **CI/CD Debugging**: Debug flaky builds
- **Time-Travel**: Go back to any build

### Usage

#### Record a Build

```d
import core.telemetry.replay;

auto recorder = getRecorder();

// Start recording
recorder.startRecording(args);

// Record inputs
recorder.recordInput("src/main.rs");
recorder.recordInput("Cargo.toml");

// Build happens...

// Record outputs
recorder.recordOutput("target/release/app");

// Add metadata
recorder.addMetadata("commit", "abc123");
recorder.addMetadata("branch", "main");

// Stop and save
auto idResult = recorder.stopRecording();
if (idResult.isOk) {
    writefln("Recording saved: %s", idResult.unwrap());
}
```

#### Replay a Build

```d
import core.telemetry.replay;

auto engine = new ReplayEngine();

// Replay recording
auto result = engine.replay("recording-id-12345");
if (result.isOk) {
    auto replay = result.unwrap();
    
    if (replay.success) {
        writeln("Replay successful!");
    } else {
        writeln("Replay failed:");
        foreach (error; replay.errors) {
            writeln("  - ", error);
        }
    }
    
    // Check differences
    foreach (diff; replay.differences) {
        writefln("  %s: %s - %s", diff.path, diff.type, diff.description);
    }
}
```

#### List Recordings

```d
auto engine = new ReplayEngine();

auto listResult = engine.listRecordings();
if (listResult.isOk) {
    auto recordings = listResult.unwrap();
    
    writeln("Available recordings:");
    foreach (info; recordings) {
        writefln("  %s - %s [%s]", 
                 info.recordingId,
                 info.timestamp.toISOExtString(),
                 info.workingDirectory);
    }
}
```

### CLI Integration

```bash
# Record a build
bldr build --record

# List recordings
builder replay list

# Replay a specific build
builder replay <recording-id>

# Show differences
builder replay diff <recording-id-1> <recording-id-2>

# Clean old recordings
builder replay clean --older-than 30d
```

### Use Cases

#### Debug Flaky Builds

```bash
# Record multiple builds
for i in {1..10}; do
  bldr build --record
done

# Find the failed one
builder replay list | grep FAILED

# Replay and investigate
builder replay <failed-recording-id>
```

#### Reproduce CI Failures Locally

```bash
# On CI: Record the failing build
bldr build --record
builder replay export <recording-id> > build-recording.json

# Locally: Import and replay
builder replay import build-recording.json
builder replay <recording-id>
```

#### Performance Regression Analysis

```bash
# Record baseline
bldr build --record
mv .builder-cache/recordings/latest.json baseline.json

# Make changes...

# Record new build
bldr build --record
mv .builder-cache/recordings/latest.json current.json

# Compare
builder replay diff baseline.json current.json
```

---

## Integration

### Complete Example

```d
import core.telemetry;
import utils.logging.structured;

void buildWithObservability(Target target) {
    auto tracer = getTracer();
    auto logger = getStructuredLogger();
    auto recorder = getRecorder();
    
    // Start tracing
    tracer.startTrace();
    auto buildSpan = tracer.startSpan("build-target");
    scope(exit) tracer.finishSpan(buildSpan);
    
    buildSpan.setAttribute("target.id", target.id);
    
    // Set log context
    auto ctx = ScopedLogContext(target.id);
    
    // Start recording
    recorder.startRecording([target.id]);
    
    try {
        logger.info("Starting build");
        buildSpan.addEvent("build-started");
        
        // Compile phase
        auto compileSpan = tracer.startSpan("compile", SpanKind.Internal, buildSpan);
        {
            logger.info("Compiling sources");
            
            foreach (source; target.sources) {
                recorder.recordInput(source);
            }
            
            // ... compile ...
            
            logger.info("Compilation complete");
        }
        tracer.finishSpan(compileSpan);
        
        // Link phase
        auto linkSpan = tracer.startSpan("link", SpanKind.Internal, buildSpan);
        {
            logger.info("Linking binary");
            
            // ... link ...
            
            recorder.recordOutput(target.output);
            logger.info("Linking complete");
        }
        tracer.finishSpan(linkSpan);
        
        buildSpan.setStatus(SpanStatus.Ok);
        logger.info("Build successful");
        
    } catch (Exception e) {
        buildSpan.recordException(e);
        buildSpan.setStatus(SpanStatus.Error, e.msg);
        logger.exception(e, "Build failed");
        throw;
    } finally {
        // Save recording
        auto recordingId = recorder.stopRecording();
        if (recordingId.isOk) {
            logger.info("Recording saved", ["id": recordingId.unwrap()]);
        }
        
        // Flush traces
        tracer.flush();
    }
}
```

### Event-Driven Integration

```d
import cli.events.events;

class ObservabilitySubscriber : EventSubscriber {
    private Tracer tracer;
    private StructuredLogger logger;
    
    void onEvent(BuildEvent event) {
        final switch (event.type) {
            case EventType.BuildStarted:
                tracer.startTrace();
                logger.info("Build started");
                break;
                
            case EventType.TargetStarted:
                auto e = cast(TargetStartedEvent)event;
                auto span = tracer.startSpan(e.targetId);
                logger.info("Target started", ["target": e.targetId]);
                break;
                
            case EventType.TargetCompleted:
                auto e = cast(TargetCompletedEvent)event;
                logger.info("Target completed", [
                    "target": e.targetId,
                    "duration": e.duration.total!"msecs".to!string
                ]);
                break;
                
            case EventType.BuildCompleted:
                tracer.flush();
                logger.info("Build completed");
                break;
                
            // ... handle other events ...
        }
    }
}
```

---

## Best Practices

### 1. Minimize Overhead

```d
// Disable in production if not needed
auto tracer = getTracer();
tracer.setEnabled(false);

// Use sampling for high-volume builds
// Only trace 10% of builds
if (uniform(0.0, 1.0) < 0.1) {
    tracer.setEnabled(true);
}
```

### 2. Structured Logging Conventions

```d
// Use consistent field names
logger.info("Build started", [
    "target.id": targetId,
    "target.language": language,
    "build.mode": "release"
]);

// Use dot notation for namespaces
fields["cache.hit"] = "true";
fields["cache.size"] = "1024";
```

### 3. Span Naming

```d
// Use hierarchical names
auto span1 = tracer.startSpan("build");
auto span2 = tracer.startSpan("build.compile", SpanKind.Internal, span1);
auto span3 = tracer.startSpan("build.compile.sources", SpanKind.Internal, span2);

// Include target ID
auto span = tracer.startSpan(format("build:%s", targetId));
```

### 4. Error Handling

```d
auto span = tracer.startSpan("risky-operation");
try {
    // ... operation ...
    span.setStatus(SpanStatus.Ok);
} catch (RecoverableException e) {
    // Log but don't mark as error
    span.addEvent("retry", ["reason": e.msg]);
    logger.warning("Operation failed, retrying", ["error": e.msg]);
} catch (Exception e) {
    span.recordException(e);
    span.setStatus(SpanStatus.Error, e.msg);
    logger.exception(e);
    throw;
} finally {
    tracer.finishSpan(span);
}
```

### 5. Performance Profiling

```d
// Profile critical sections
auto span = tracer.startSpan("hot-path");
span.setAttribute("profiling", "enabled");

auto sw = StopWatch(AutoStart.yes);
// ... critical code ...
sw.stop();

span.setAttribute("duration_ns", sw.peek.total!"nsecs".to!string);
tracer.finishSpan(span);
```

### 6. CI/CD Integration

```yaml
# .github/workflows/build.yml
- name: Build with observability
  run: |
    export BUILDER_TRACING_ENABLED=1
    export BUILDER_LOG_LEVEL=debug
    bldr build --record
    
- name: Upload traces
  if: failure()
  uses: actions/upload-artifact@v3
  with:
    name: build-traces
    path: .builder-cache/traces/
    
- name: Upload logs
  if: failure()
  uses: actions/upload-artifact@v3
  with:
    name: build-logs
    path: .builder-cache/logs/
    
- name: Upload recording
  if: failure()
  uses: actions/upload-artifact@v3
  with:
    name: build-recording
    path: .builder-cache/recordings/
```

### 7. Flamegraph Analysis

```bash
# Generate weekly performance report
bldr telemetry flamegraph --since 7d > weekly-flame.svg

# Identify bottlenecks
grep "duration.*ms" weekly-flame.svg | sort -rn | head -10

# Compare before/after optimization
bldr telemetry flamegraph --before 2025-10-20 > before.svg
bldr telemetry flamegraph --after 2025-10-20 > after.svg
```

---

## Configuration Reference

### Environment Variables

```bash
# Tracing
export BUILDER_TRACING_ENABLED=1
export BUILDER_TRACING_EXPORTER=jaeger
export BUILDER_TRACING_SAMPLE_RATE=1.0
export BUILDER_TRACING_OUTPUT_DIR=.builder-cache/traces

# Logging
export BUILDER_LOG_LEVEL=info
export BUILDER_LOG_BUFFER=1
export BUILDER_LOG_MAX_BUFFER=10000
export BUILDER_LOG_OUTPUT_DIR=.builder-cache/logs

# Recording
export BUILDER_RECORD_ENABLED=0
export BUILDER_RECORD_DIR=.builder-cache/recordings
export BUILDER_RECORD_MAX_AGE_DAYS=30

# Flamegraph
export BUILDER_FLAMEGRAPH_WIDTH=1200
export BUILDER_FLAMEGRAPH_HEIGHT=800
```

### Performance Impact

| Feature | Overhead | Memory | Disk |
|---------|----------|--------|------|
| Tracing | < 1% | ~500 bytes/span | ~1KB/span |
| Structured Logging | < 0.5% | ~200 bytes/log | ~500 bytes/log |
| Recording | < 2% | ~10KB/target | ~50KB/target |
| Flamegraph | 0% (post-build) | N/A | ~100KB/SVG |

---

## Troubleshooting

### Traces Not Appearing

```bash
# Check if tracing is enabled
echo $BUILDER_TRACING_ENABLED

# Verify exporter is configured
ls -la .builder-cache/traces/

# Check for errors
builder --verbose build
```

### High Memory Usage

```bash
# Reduce log buffer size
export BUILDER_LOG_MAX_BUFFER=1000

# Disable recording
export BUILDER_RECORD_ENABLED=0

# Increase sampling (trace fewer builds)
export BUILDER_TRACING_SAMPLE_RATE=0.1
```

### Corrupted Recordings

```bash
# Validate recordings
builder replay validate <recording-id>

# Clean corrupted recordings
builder replay clean --corrupted

# Reset recordings directory
rm -rf .builder-cache/recordings
mkdir -p .builder-cache/recordings
```

---

## See Also

- [TELEMETRY.md](TELEMETRY.md) - Build telemetry and analytics
- [PERFORMANCE.md](PERFORMANCE.md) - Performance optimization guide
- [CONCURRENCY.md](CONCURRENCY.md) - Parallel build execution
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) - System architecture

