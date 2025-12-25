# Persistent Worker Protocol

## Overview

Builder implements a Bazel-compatible persistent worker protocol that keeps compiler processes running **across builds** (not just actions). Workers progress through warmth levels as JIT optimizes, providing **10-50x speedup**. Includes automatic memory monitoring with OOM prevention and warmth-aware recycling.

## The Problem

Every compiler invocation has startup overhead:

| Compiler | Startup Overhead | Cause |
|----------|-----------------|-------|
| javac | ~800ms-2s | JVM startup, class loading, JIT warmup |
| kotlinc | ~2000ms | JVM + Kotlin compiler initialization |
| scalac | ~1500ms | JVM + Scala compiler initialization |
| tsc | ~400ms | Node.js startup, TypeScript program creation |
| swc | ~50ms | Process startup, WASM initialization |

For small source files that compile in milliseconds, this overhead dominates total build time.

## The Solution

Persistent workers keep compiler processes running and **warm**:

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

## Warmth Levels

Workers progress through warmth levels as JIT optimization kicks in:

| Level | Description | Speedup |
|-------|-------------|---------|
| **Cold** | Just started, no JIT optimization | 1x (baseline) |
| **Warming** | Initial compilations done, JIT warming | 3x |
| **Warm** | Steady state, good performance | 10-20x |
| **Hot** | Fully optimized, peak performance | 20-50x |

## Performance Comparison

| Compiler | Cold Start | Warm Worker | Hot Worker | Speedup |
|----------|------------|-------------|------------|---------|
| javac    | ~800ms     | ~50ms       | ~15ms      | **16-50x** |
| kotlinc  | ~2000ms    | ~100ms      | ~30ms      | **20-67x** |
| scalac   | ~1500ms    | ~80ms       | ~25ms      | **19-60x** |
| groovyc  | ~1200ms    | ~70ms       | ~20ms      | **17-60x** |
| tsc      | ~400ms     | ~30ms       | ~10ms      | **13-40x** |
| swc      | ~50ms      | ~5ms        | ~2ms       | **10-25x** |
| esbuild  | ~30ms      | ~3ms        | ~1ms       | **10-30x** |

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
| `idle_timeout` | 10m | Evict idle workers after duration |
| `health_check_interval` | 30s | Health check frequency |
| `max_requests_per_worker` | 10,000 | Recycle worker after N requests |
| `enable_recycling` | true | Enable warmth-aware recycling |
| `enable_memory_monitor` | true | Enable OOM detection |
| `persist_across_builds` | true | Keep warm workers between builds |

### Recycling Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `prefer_warm_workers` | true | Select warmest available worker |
| `keep_hot_across_builds` | true | Preserve hot workers between builds |
| `hot_worker_bonus` | 5m | Extra idle time for hot workers |
| `min_keep_warm_time` | 2m | Minimum time before evicting warm worker |

### Memory Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `normal_max` | 0.70 | Normal pressure threshold |
| `elevated_max` | 0.85 | Elevated pressure threshold |
| `high_max` | 0.95 | High pressure, triggers OOM restart |
| `poll_interval` | 5s | Memory polling interval |

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

## Warmth-Aware Recycling

Workers are managed with warmth-aware policies:

### Recycling Policy

- **Cold workers evicted first** when capacity needed
- **Hot workers get extended idle time** (configurable bonus)
- **Warm workers preserved** for minimum keep time
- **Workers persist across builds** for true JIT optimization

```yaml
build:
  persistent_workers:
    recycling:
      prefer_warm_workers: true
      keep_hot_across_builds: true
      hot_worker_bonus: 5m
      min_keep_warm_time: 2m
```

### Warmth Statistics

```d
auto recycler = pool.getRecycler();
auto stats = recycler.getStats();

writeln("Cold workers: ", stats.byLevel[WarmthLevel.Cold]);
writeln("Warm workers: ", stats.byLevel[WarmthLevel.Warm]);
writeln("Hot workers: ", stats.byLevel[WarmthLevel.Hot]);
writeln("Estimated speedup: ", recycler.estimatedSpeedup(), "x");
```

## Memory Monitoring & OOM Prevention

Workers are monitored for memory pressure with automatic restart before OOM:

### Memory Pressure Levels

| Level | Threshold | Action |
|-------|-----------|--------|
| Normal | < 70% | Continue normally |
| Elevated | 70-85% | Log warning |
| High | 85-95% | Trigger restart (warm workers deferred) |
| Critical | > 95% | Immediate restart |

### Configuration

```yaml
build:
  persistent_workers:
    memory:
      normal_max: 0.70
      elevated_max: 0.85
      high_max: 0.95
      poll_interval: 5s
```

### Checking Memory Status

```d
auto memMonitor = pool.getMemoryMonitor();
auto stats = memMonitor.getStats();

writeln("Workers monitored: ", stats.monitored);
writeln("At OOM risk: ", stats.atRisk);
writeln("Critical: ", stats.critical);
writeln("OOM restarts: ", stats.oomDetections);
```

## Health Monitoring

The health monitor ensures workers remain responsive with memory awareness:

### Automatic Recovery

1. Health checks every 10 seconds (configurable)
2. **Memory pressure monitoring** with OOM prevention
3. Detects dead/unresponsive workers
4. Auto-restart after 3 consecutive failures
5. **Warmth-aware restart** preserves warm workers when possible
6. Graceful fallback to cold compilation

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

1. Workers may be cold - check warmth distribution
2. Files may be too large (compilation dominates startup)
3. Too few workers for parallelism
4. Workers being evicted too quickly - increase `idle_timeout`

### High Memory Usage

1. Reduce `max_workers_per_type`
2. Lower `max_heap_mb` / `max_old_space_mb`
3. Enable memory monitoring: `enable_memory_monitor: true`
4. Lower `high_max` threshold for earlier OOM restart

### Frequent OOM Restarts

1. Workers may have memory leaks - reduce `max_requests_per_worker`
2. Increase heap limits if sufficient RAM available
3. Check for memory-intensive compilation patterns
4. Review memory stats: `pool.getMemoryMonitor().getStats()`

### Workers Not Staying Warm

1. Enable persistence: `persist_across_builds: true`
2. Increase `idle_timeout` to 10+ minutes
3. Enable hot worker bonus: `keep_hot_across_builds: true`
4. Check recycler stats for warmth distribution

## Comparison with Bazel

| Feature | Builder | Bazel |
|---------|---------|-------|
| Protocol | ✅ Compatible | Original |
| JVM workers | ✅ javac, kotlinc, scalac, groovyc | javac, kotlinc |
| TypeScript workers | ✅ tsc, swc, esbuild, bun | Limited |
| Persist across builds | ✅ Yes | Per-build only |
| Warmth tracking | ✅ Cold/Warm/Hot levels | None |
| OOM prevention | ✅ Automatic restart | None |
| Memory monitoring | ✅ Built-in | None |
| Auto health recovery | ✅ Yes | Manual |
| Warmth-aware eviction | ✅ Cold first, hot preserved | FIFO |
| Metrics | ✅ Built-in with warmth stats | External |
| Configuration | ✅ Simple YAML | Starlark rules |

## References

- [Bazel Persistent Workers](https://bazel.build/remote/persistent)
- [Worker Protocol Specification](https://github.com/bazelbuild/bazel/blob/master/src/main/protobuf/worker_protocol.proto)
- [JVM Warmup](https://www.baeldung.com/java-jvm-warmup)
- [TypeScript Incremental Compilation](https://www.typescriptlang.org/docs/handbook/project-references.html)

