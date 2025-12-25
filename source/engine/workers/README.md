# Persistent Worker Protocol

Implements a Bazel-compatible persistent worker protocol for JVM and TypeScript compilation, reducing per-action overhead by **10-50x** for warm compilers.

## Overview

Persistent workers keep compiler processes running **across builds** (not just actions), avoiding startup overhead that typically dominates small compilation times:

| Compiler | Cold Start | Warm Worker | Hot Worker | Speedup |
|----------|------------|-------------|------------|---------|
| javac    | ~800ms     | ~50ms       | ~15ms      | **16-50x** |
| kotlinc  | ~2000ms    | ~100ms      | ~30ms      | **20-67x** |
| scalac   | ~1500ms    | ~80ms       | ~25ms      | **19-60x** |
| tsc      | ~400ms     | ~30ms       | ~10ms      | **13-40x** |
| swc      | ~50ms      | ~5ms        | ~2ms       | **10-25x** |

### Warmth Levels

Workers progress through warmth levels as they process requests:

- **Cold**: Just started, no JIT optimization
- **Warming**: Initial compilations done, JIT warming up
- **Warm**: Steady state, good performance (10-20x speedup)
- **Hot**: Fully optimized, peak performance (20-50x speedup)

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                       Build System                                │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                PersistentWorkerService                       │ │
│  │  ┌─────────────┐  ┌──────────────┐  ┌──────────────────────┐│ │
│  │  │ WorkerPool  │  │HealthMonitor│  │      Metrics         ││ │
│  │  │ ┌─────────┐ │  │ (memory-    │  │ (warmth tracking)    ││ │
│  │  │ │Recycler │ │  │  aware)     │  │                      ││ │
│  │  │ │(warmth) │ │  └──────────────┘  └──────────────────────┘│ │
│  │  │ ├─────────┤ │                                            │ │
│  │  │ │ Memory  │ │  SOC: Each component has single concern    │ │
│  │  │ │ Monitor │ │  - recycler.d: warmth tracking only        │ │
│  │  │ └─────────┘ │  - memory.d: OOM detection only            │ │
│  │  └──────┬──────┘  - manager.d: coordination only            │ │
│  └─────────┼────────────────────────────────────────────────────┘ │
│            │                                                       │
│  ┌─────────┴────────────────────────────────────────────────────┐ │
│  │                     Worker Factories                          │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │ │
│  │  │ JVM Factory  │  │  TS Factory  │  │ Scala Factory│        │ │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘        │ │
│  └─────────┼─────────────────┼─────────────────┼────────────────┘ │
└────────────┼─────────────────┼─────────────────┼─────────────────┘
             │                 │                 │
     ┌───────▼───────┐ ┌───────▼───────┐ ┌───────▼───────┐
     │  javac/kotlinc│ │    tsc/swc    │ │    scalac     │
     │  (warm JVM)   │ │  (warm V8)    │ │   (warm JVM)  │
     │  Hot: 50x ⚡  │ │  Hot: 40x ⚡  │ │   Hot: 60x ⚡ │
     └───────────────┘ └───────────────┘ └───────────────┘
```

## Protocol

Workers communicate via stdin/stdout using newline-delimited JSON (Bazel-compatible):

### WorkRequest (stdin)

```json
{
  "request_id": 1,
  "arguments": ["-d", "bin/", "src/Main.java"],
  "inputs": [{"path": "src/Main.java", "digest": "abc123..."}],
  "sandbox_dir": "/tmp/sandbox",
  "verbosity": 1,
  "cancel": false
}
```

### WorkResponse (stdout)

```json
{
  "request_id": 1,
  "exit_code": 0,
  "output": "Compiled 1 source file",
  "was_cached": false,
  "execution_time_ms": 45,
  "outputs": [{"path": "bin/Main.class", "digest": "def456..."}]
}
```

## Usage

### Basic Usage

```d
import engine.workers;

// Initialize workers at build system startup
initializePersistentWorkers();

// Compile Java with warm worker (16x faster)
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

// Compile TypeScript with warm worker (13x faster)
auto tsResult = TypeScriptWorkerIntegration.compile(
    ["src/app.ts"],
    "dist/",
    TSWorkerCompileOptions(target: "ES2022", sourceMap: true)
);

// Cleanup at shutdown
shutdownPersistentWorkers();
```

### Advanced Configuration

```d
WorkerServiceConfig config;
config.poolConfig.maxWorkersPerType = 4;
config.poolConfig.idleTimeout = minutes(10);
config.enableJVMWorkers = true;
config.enableTSWorkers = true;

// JVM-specific config
config.jvmConfig.maxHeapMB = 4096;
config.jvmConfig.jvmArgs = ["-XX:+UseG1GC"];

// TypeScript-specific config
config.tsConfig.incremental = true;
config.tsConfig.maxOldSpaceMB = 8192;

initWorkerService(config);
```

### Health Monitoring

```d
// Setup health alerts
auto service = getWorkerService();
auto health = new WorkerHealthMonitor(service.pool);

health.setAlertHandler((alert) {
    if (alert.severity >= AlertSeverity.Warning)
        Logger.warn(alert.message);
});

health.start();

// Check health status
auto summary = health.getSummary();
writeln("Worker health: ", summary.healthPercentage(), "%");
writeln("Avg response time: ", summary.avgResponseTimeMs, "ms");
```

## Components

### Protocol (`protocol/`)
- `types.d` - WorkRequest, WorkResponse, InputFile, OutputFile types
- `transport.d` - Stdio transport for worker communication

### Pool (`pool/`)
- `manager.d` - Worker pool coordination (integrates recycler + memory)
- `recycler.d` - Warmth tracking and recycling policy (SOC)
- `memory.d` - Memory metrics and OOM detection (SOC)

### JVM Workers (`jvm/`)
- `worker.d` - JVM worker factory for javac, kotlinc, scalac, groovyc

### TypeScript Workers (`typescript/`)
- `worker.d` - TypeScript worker factory for tsc, swc, esbuild, bun

### Service (`service.d`)
- High-level service integrating all components

### Integration (`integration.d`)
- Drop-in replacements for language handlers

### Health (`health.d`)
- Health monitoring with memory-aware automatic recovery

## Persistent Recycling

Workers persist across builds with intelligent recycling:

### Warmth-Aware Eviction

```d
// Cold workers evicted first, hot workers preserved
config.recyclingPolicy.preferWarmWorkers = true;
config.recyclingPolicy.keepHotAcrossBuilds = true;
config.recyclingPolicy.hotWorkerBonus = minutes(5);  // Extra idle time for hot workers
```

### Memory Monitoring & OOM Prevention

```d
// Automatic restart when memory pressure detected
config.enableMemoryMonitor = true;
config.memoryThresholds.highMax = 0.95f;  // Restart at 95% heap

// Check memory status
auto memStats = pool.getMemoryMonitor().getStats();
writeln("Workers at OOM risk: ", memStats.atRisk);
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

## Performance Tips

1. **Worker Count**: Set `maxWorkersPerType` based on CPU cores and typical parallelism
2. **Memory**: Increase `maxHeapMB` for large projects (JVM) or `maxOldSpaceMB` (Node)
3. **Idle Timeout**: Use longer timeouts (10+ min) to keep workers warm across builds
4. **Hot Workers**: Enable `keepHotAcrossBuilds` for continuous development
5. **OOM Prevention**: Enable memory monitoring for large heap allocations

## Compatibility

- **Bazel Protocol**: Compatible with Bazel's persistent worker protocol
- **JVM**: Works with OpenJDK 11+, GraalVM
- **Node.js**: Requires Node.js 16+ (uses ES modules)
- **TypeScript**: Works with tsc 4.0+, SWC 1.0+, esbuild 0.14+

## Metrics

Track performance with built-in metrics:

```d
auto metrics = getWorkerPerformanceMetrics();
writeln(metrics.toString());
// Output: "Persistent Workers: 142 compilations, 98% success, 14.2x avg speedup, 87s total saved"
```

