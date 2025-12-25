# Distributed Build Tracing

Builder includes OpenTelemetry-compatible distributed tracing for comprehensive observability of build processes across distributed workers.

## Overview

The tracing system provides:

- **Span tracking** for every build phase (fetch, execute, upload)
- **Parent-child relationships** across coordinator and workers
- **W3C Trace Context** propagation for distributed builds
- **Multiple exporters**: OTLP/HTTP (Jaeger, Tempo, Grafana Cloud), Jaeger JSON, Console
- **Configurable sampling** for high-volume builds

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Coordinator                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ build-execute (root span)                            │   │
│  │   └─ action.schedule                                 │   │
│  │       └─ trace_context → ActionRequest              │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ Network (with traceparent)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                        Worker                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ action.execute (child of coordinator span)          │   │
│  │   ├─ action.fetch (input artifacts)                 │   │
│  │   ├─ action.sandbox.prepare                         │   │
│  │   ├─ action.exec (command execution)                │   │
│  │   └─ action.upload (output artifacts)               │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ OTLP/HTTP
                           ▼
┌─────────────────────────────────────────────────────────────┐
│           Observability Backend                             │
│  (Jaeger / Tempo / Grafana Cloud / Honeycomb)              │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILDER_TRACING_ENABLED` | `1` | Enable/disable tracing (`0` to disable) |
| `BUILDER_TRACING_EXPORTER` | `jaeger` | Exporter: `otlp`, `jaeger`, `console` |
| `BUILDER_TRACING_OUTPUT` | `.builder-cache/traces/jaeger.json` | Output file for jaeger exporter |
| `BUILDER_OTLP_ENDPOINT` | `http://localhost:4318/v1/traces` | OTLP endpoint URL |
| `BUILDER_OTLP_AUTH_TOKEN` | (none) | Bearer token for OTLP authentication |
| `BUILDER_SERVICE_NAME` | `builder` | Service name in traces |
| `BUILDER_SERVICE_VERSION` | (none) | Service version |
| `BUILDER_SAMPLING_RATIO` | `1.0` | Sampling ratio (0.0-1.0) |

### Using OTLP with Jaeger

```bash
# Start Jaeger with OTLP receiver
docker run -d --name jaeger \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:latest

# Build with OTLP tracing
export BUILDER_TRACING_EXPORTER=otlp
export BUILDER_OTLP_ENDPOINT=http://localhost:4318/v1/traces
export BUILDER_SERVICE_NAME=my-project

bldr build //...

# View traces at http://localhost:16686
```

### Using OTLP with Grafana Tempo

```bash
# Configure for Tempo
export BUILDER_TRACING_EXPORTER=otlp
export BUILDER_OTLP_ENDPOINT=http://tempo:4318/v1/traces
export BUILDER_SERVICE_NAME=my-monorepo

bldr build //...
```

### Using OTLP with Grafana Cloud

```bash
export BUILDER_TRACING_EXPORTER=otlp
export BUILDER_OTLP_ENDPOINT=https://otlp-gateway-prod-us-central-0.grafana.net/otlp/v1/traces
export BUILDER_OTLP_AUTH_TOKEN="your-instance-id:your-api-key"
export BUILDER_SERVICE_NAME=ci-builds

bldr build //...
```

### Reducing Trace Volume

For large builds, use sampling to reduce trace volume:

```bash
# Sample 10% of traces
export BUILDER_SAMPLING_RATIO=0.1

# Or disable tracing entirely for local development
export BUILDER_TRACING_ENABLED=0
```

## Span Attributes

Traces include semantic attributes following OpenTelemetry conventions:

### Build Span
- `builder.total_targets` - Number of targets in build
- `builder.max_parallelism` - Worker parallelism level

### Action Span
- `builder.action.id` - BLAKE3 hash of action
- `builder.action.command` - Command being executed
- `builder.action.priority` - Scheduling priority
- `builder.action.timeout_ms` - Execution timeout
- `builder.action.inputs` - Number of input artifacts
- `builder.action.outputs` - Number of output artifacts
- `builder.worker.name` - Executing worker name

### Phase Spans
- `builder.phase` - Phase name (input_fetch, execute, output_upload)
- `builder.artifact.id` - Artifact being fetched/uploaded
- `builder.command` - Actual command executed

## Programmatic Usage

```d
import infrastructure.telemetry.distributed;

// Create OTLP exporter
auto config = OtlpConfig.jaeger("localhost", 4318);
config.serviceName = "my-build-system";
config.serviceVersion = "1.0.0";

auto exporter = new OtlpHttpExporter(config);

// Create tracer with sampling
TracerConfig tracerCfg;
tracerCfg.serviceName = "my-build-system";
tracerCfg.samplingRatio = 0.5;  // 50% sampling

auto tracer = new Tracer(exporter, tracerCfg);

// Start trace and create spans
tracer.startTrace();
auto buildSpan = tracer.startSpan("build", SpanKind.Internal);
buildSpan.setAttribute("project", "my-project");

// ... perform build ...

buildSpan.setStatus(SpanStatus.Ok);
tracer.finishSpan(buildSpan);
tracer.flush();
```

### Worker Integration

```d
import engine.distributed.worker.tracing;
import infrastructure.telemetry.distributed.tracing;

// On worker, use propagated trace context
auto tracing = DistributedTracing(tracer);
auto actionSpan = tracing.startActionSpan(actionRequest, "worker-1");

// Create child spans for phases
auto fetchSpan = actionSpan.startFetchSpan(artifactId);
// ... fetch artifact ...
actionSpan.finishChild(fetchSpan);

auto execSpan = actionSpan.startExecuteSpan(command);
// ... execute command ...
actionSpan.finishChild(execSpan);

// Record result
if (success)
    actionSpan.recordSuccess(duration, outputCount);
else
    actionSpan.recordFailure("Command failed", exitCode);

actionSpan.finish();
```

## W3C Trace Context

Trace context is propagated using the W3C Trace Context standard (traceparent header format):

```
00-{traceId}-{parentSpanId}-{flags}
```

Example:
```
00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
```

This allows integration with any OpenTelemetry-compatible system.

## Best Practices

1. **Use OTLP for production** - The OTLP exporter is more efficient than file-based exporters
2. **Enable sampling for CI** - High-volume CI systems should use sampling (e.g., 10%)
3. **Add custom attributes** - Use span attributes to add context (PR number, branch, etc.)
4. **Monitor trace latency** - Watch for excessive spans affecting build performance

## Troubleshooting

### No traces appearing

1. Verify exporter is configured: `echo $BUILDER_TRACING_EXPORTER`
2. Check endpoint is reachable: `curl $BUILDER_OTLP_ENDPOINT`
3. Verify tracing is enabled: `echo $BUILDER_TRACING_ENABLED`

### Missing child spans

1. Ensure trace context is propagated in ActionRequest
2. Check sampling ratio isn't too low
3. Verify parent-based sampling is enabled

### High trace volume

1. Reduce sampling ratio: `export BUILDER_SAMPLING_RATIO=0.1`
2. Increase batch size in OTLP config
3. Consider using head-based sampling

