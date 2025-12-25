# Persistent Worker Protocol

## Overview

Builder implements a Bazel-compatible persistent worker protocol that keeps compiler processes running between build actions. This eliminates startup overhead that typically dominates small compilation times, providing **10-50x speedup** for incremental builds.

## The Problem

Every compiler invocation has startup overhead:

| Compiler | Startup Overhead | Cause |
|----------|-----------------|-------|
| javac | ~800ms | JVM startup, class loading |
| kotlinc | ~2000ms | JVM + Kotlin compiler initialization |
| scalac | ~1500ms | JVM + Scala compiler initialization |
| tsc | ~400ms | Node.js startup, TypeScript program creation |
| swc | ~50ms | Process startup, WASM initialization |

For small source files that compile in milliseconds, this overhead dominates total build time.

## The Solution

Persistent workers keep compiler processes running:

```
Traditional Compilation:
┌────────────┐     ┌────────────┐     ┌────────────┐
│ Start JVM  │────▶│  Compile   │────▶│   Exit     │
│  (800ms)   │     │  (50ms)    │     │            │
└────────────┘     └────────────┘     └────────────┘
Total: 850ms per file

Persistent Worker:
┌─────────────────────────────────────────────────────┐
│              JVM (started once, reused)             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐ │
│  │Compile 1 │ │Compile 2 │ │Compile 3 │ │  ...   │ │
│  │  (50ms)  │ │  (45ms)  │ │  (48ms)  │ │        │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────┘ │
└─────────────────────────────────────────────────────┘
Total: 50ms per file (16x faster!)
```

## Performance Comparison

| Compiler | Cold Start | Warm Worker | Speedup |
|----------|------------|-------------|---------|
| javac    | ~800ms     | ~50ms       | **16x** |
| kotlinc  | ~2000ms    | ~100ms      | **20x** |
| scalac   | ~1500ms    | ~80ms       | **19x** |
| groovyc  | ~1200ms    | ~70ms       | **17x** |
| tsc      | ~400ms     | ~30ms       | **13x** |
| swc      | ~50ms      | ~5ms        | **10x** |
| esbuild  | ~30ms      | ~3ms        | **10x** |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Build System                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              PersistentWorkerService                     │ │
│  │  ┌───────────────┐  ┌────────────────┐  ┌─────────────┐ │ │
│  │  │  WorkerPool   │  │ HealthMonitor  │  │   Metrics   │ │ │
│  │  └───────┬───────┘  └────────────────┘  └─────────────┘ │ │
│  └──────────┼───────────────────────────────────────────────┘ │
│             │                                                  │
│  ┌──────────┴──────────────────────────────────────────────┐ │
│  │                    Worker Factories                       │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │ │
│  │  │ JVM Factory  │  │  TS Factory  │  │ Scala Factory│   │ │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │ │
│  └─────────┼─────────────────┼─────────────────┼───────────┘ │
└────────────┼─────────────────┼─────────────────┼─────────────┘
             │                 │                 │
     ┌───────▼───────┐ ┌───────▼───────┐ ┌───────▼───────┐
     │  javac/kotlinc│ │    tsc/swc    │ │    scalac     │
     │   (warm JVM)  │ │  (warm Node)  │ │  (warm JVM)   │
     └───────────────┘ └───────────────┘ └───────────────┘
```

## Protocol

The protocol is Bazel-compatible, using newline-delimited JSON over stdin/stdout.

### WorkRequest (stdin)

```json
{
  "request_id": 1,
  "arguments": ["-d", "bin/", "-source", "17", "src/Main.java"],
  "inputs": [
    {"path": "src/Main.java", "digest": "abc123..."},
    {"path": "src/Util.java", "digest": "def456..."}
  ],
  "sandbox_dir": "/tmp/sandbox-12345",
  "verbosity": 1,
  "cancel": false
}
```

### WorkResponse (stdout)

```json
{
  "request_id": 1,
  "exit_code": 0,
  "output": "Compiled 2 source files",
  "was_cached": false,
  "execution_time_ms": 45,
  "outputs": [
    {"path": "bin/Main.class", "digest": "789abc..."},
    {"path": "bin/Util.class", "digest": "012def..."}
  ]
}
```

## Usage

### Enabling Persistent Workers

Workers are enabled by default. Configure in `Builderspace`:

```yaml
build:
  persistent_workers:
    enabled: true
    max_workers_per_type: 4
    idle_timeout: 5m
```

### Programmatic Usage

```d
import engine.workers;

// Initialize at startup
initializePersistentWorkers();

// Compile Java
auto result = JavaWorkerIntegration.compile(
    ["src/Main.java"],
    "bin/",
    ["lib/deps.jar"],
    ["-source", "17"]
);

if (result.isOk) {
    auto r = result.unwrap();
    writeln("Compiled in ", r.executionTimeMs, "ms");
    writeln("Speedup: ", r.estimatedSpeedup(), "x");
}

// Compile TypeScript
auto tsResult = TypeScriptWorkerIntegration.compile(
    ["src/app.ts"],
    "dist/",
    TSWorkerCompileOptions(target: "ES2022", sourceMap: true)
);

// Shutdown at exit
shutdownPersistentWorkers();
```

### Metrics

```d
auto metrics = getWorkerPerformanceMetrics();
writeln(metrics.toString());
// Output: "Persistent Workers: 142 compilations, 98% success, 14.2x avg speedup, 87s total saved"
```

## Configuration

### Pool Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `max_workers_per_type` | 4 | Max concurrent workers per compiler |
| `idle_timeout` | 5m | Evict idle workers after duration |
| `health_check_interval` | 30s | Health check frequency |
| `max_requests_per_worker` | 5000 | Restart worker after N requests |

### JVM Worker Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `max_heap_mb` | 2048 | JVM max heap size |
| `jvm_args` | [] | Additional JVM arguments |
| `java_home` | auto | Override JAVA_HOME |
| `startup_timeout` | 30s | Worker startup timeout |
| `request_timeout` | 5m | Request timeout |

### TypeScript Worker Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `max_old_space_mb` | 4096 | Node.js max old space |
| `incremental` | true | Enable incremental compilation |
| `node_path` | auto | Override Node.js path |
| `startup_timeout` | 15s | Worker startup timeout |
| `request_timeout` | 5m | Request timeout |

## Health Monitoring

The health monitor ensures workers remain responsive:

### Automatic Recovery

1. Health checks every 10 seconds (configurable)
2. Detects dead/unresponsive workers
3. Auto-restart after 3 consecutive failures
4. Graceful fallback to cold compilation

### Alerts

```d
auto health = new WorkerHealthMonitor(pool);

health.setAlertHandler((alert) {
    final switch (alert.severity) {
        case AlertSeverity.Info:
            log.info(alert.message);
            break;
        case AlertSeverity.Warning:
            log.warn(alert.message);
            break;
        case AlertSeverity.Critical:
            log.error(alert.message);
            alertOps(alert);
            break;
    }
});

health.start();
```

### Health Summary

```d
auto summary = health.getSummary();
writeln("Worker health: ", summary.healthPercentage(), "%");
writeln("Avg response time: ", summary.avgResponseTimeMs, "ms");
writeln("Total restarts: ", summary.totalRestarts);
```

## Supported Compilers

### JVM

| Compiler | Status | Notes |
|----------|--------|-------|
| javac | ✅ Full | OpenJDK 11+ |
| kotlinc | ✅ Full | Kotlin 1.5+ |
| scalac | ✅ Full | Scala 2.12+ / Scala 3 |
| groovyc | ✅ Full | Groovy 3.0+ |

### TypeScript/JavaScript

| Compiler | Status | Notes |
|----------|--------|-------|
| tsc | ✅ Full | TypeScript 4.0+ |
| swc | ✅ Full | SWC 1.0+ |
| esbuild | ✅ Full | esbuild 0.14+ |
| bun | ✅ Full | Bun 1.0+ |

## Best Practices

### 1. Tune Worker Count

```yaml
# For CI with high parallelism
persistent_workers:
  max_workers_per_type: 8

# For local development
persistent_workers:
  max_workers_per_type: 2
```

### 2. Set Appropriate Timeouts

```yaml
# For large projects
persistent_workers:
  idle_timeout: 10m  # Keep workers longer
  request_timeout: 10m  # Allow long compilations
```

### 3. Monitor Metrics

Track speedup over time to verify benefits:

```bash
bldr build --verbose 2>&1 | grep "Worker speedup"
```

### 4. Handle Fallback Gracefully

Workers automatically fall back to cold compilation if:
- Worker process dies
- Worker is unresponsive
- Max workers reached

This is transparent - builds still succeed.

## Troubleshooting

### Workers Not Starting

1. Check compiler is available: `which javac` / `which tsc`
2. Verify sufficient memory for workers
3. Check logs for startup errors

### Poor Speedup

1. Files may be too large (compilation dominates startup)
2. Too few workers for parallelism
3. Workers being evicted too quickly

### High Memory Usage

1. Reduce `max_workers_per_type`
2. Lower `max_heap_mb` / `max_old_space_mb`
3. Reduce `idle_timeout` to evict faster

## Comparison with Bazel

| Feature | Builder | Bazel |
|---------|---------|-------|
| Protocol | ✅ Compatible | Original |
| JVM workers | ✅ javac, kotlinc, scalac | javac, kotlinc |
| TypeScript workers | ✅ tsc, swc, esbuild, bun | Limited |
| Auto health recovery | ✅ Yes | Manual |
| Metrics | ✅ Built-in | External |
| Configuration | ✅ Simple YAML | Starlark rules |

## References

- [Bazel Persistent Workers](https://bazel.build/remote/persistent)
- [Worker Protocol Specification](https://github.com/bazelbuild/bazel/blob/master/src/main/protobuf/worker_protocol.proto)
- [JVM Warmup](https://www.baeldung.com/java-jvm-warmup)
- [TypeScript Incremental Compilation](https://www.typescriptlang.org/docs/handbook/project-references.html)

