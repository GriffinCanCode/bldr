# Persistent Worker Protocol

**Module:** `engine.workers`

## Overview

Persistent workers keep compiler processes running across builds to avoid startup overhead. Workers progress through warmth levels as JIT optimization takes effect.

## Problem

Compiler startup overhead dominates small compilation times:

| Compiler | Typical Startup |
|----------|-----------------|
| javac | ~800ms-2s |
| kotlinc | ~2s |
| scalac | ~1.5s |
| tsc | ~400ms |
| swc | ~50ms |

## Solution

Keep compiler processes warm:

```
Traditional:
  Start JVM (800ms) → Compile (50ms) → Exit
  Total: 850ms per invocation

Persistent Worker:
  JVM running continuously
  Compile 1 (50ms) → Compile 2 (45ms) → Compile 3 (48ms) → ...
```

## Warmth Levels

**Module:** `engine.workers.pool.recycler`

Workers progress through warmth levels:

| Level | Threshold | Description |
|-------|-----------|-------------|
| Cold | 0 requests | Just started, no JIT |
| Warming | 1+ requests | Initial JIT warmup |
| Warm | 5+ requests | Steady state |
| Hot | 50+ requests | Fully optimized |

**Thresholds:**
```d
struct WarmthThresholds
{
    uint coldToWarming = 1;
    uint warmingToWarm = 5;
    uint warmToHot = 50;
}
```

## Protocol

Bazel-compatible, newline-delimited JSON over stdin/stdout.

### WorkRequest (stdin)

```json
{
  "request_id": 1,
  "arguments": ["-d", "bin/", "-source", "17", "src/Main.java"],
  "inputs": [
    {"path": "src/Main.java", "digest": "abc123..."}
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
    {"path": "bin/Main.class", "digest": "789abc..."}
  ]
}
```

## Supported Languages

### JVM (`engine.workers.jvm`)

| Compiler | Worker Type |
|----------|-------------|
| javac | `jvm-javac` |
| kotlinc | `jvm-kotlinc` |
| scalac | `jvm-scalac` |
| groovyc | `jvm-groovyc` |

### TypeScript (`engine.workers.typescript`)

| Tool | Worker Type |
|------|-------------|
| tsc | `typescript-tsc` |
| swc | `typescript-swc` |
| esbuild | `typescript-esbuild` |
| bun | `typescript-bun` |

### Go (`engine.workers.go`)

| Command | Worker Type |
|---------|-------------|
| go build | `go-build` |
| go test | `go-test` |
| go vet | `go-vet` |
| go fmt | `go-fmt` |

### Rust (`engine.workers.rust`)

| Tool | Worker Type |
|------|-------------|
| cargo | `rust-cargo` |
| cargo check | `rust-check` |
| rustc | `rust-rustc` |
| clippy | `rust-clippy` |

### Python (`engine.workers.python`)

| Tool | Worker Type |
|------|-------------|
| mypy | `python-mypy` |
| ruff | `python-ruff` |
| pylint | `python-pylint` |
| black | `python-black` |

## Architecture

### Components

**WorkerPool** (`pool/manager.d`):
- Manages active workers
- Coordinates with recycler and memory monitor

**WorkerRecycler** (`pool/recycler.d`):
- Tracks warmth levels
- Makes eviction decisions
- Selects warmest available worker

**WorkerMemoryMonitor** (`pool/memory.d`):
- Monitors heap usage
- Detects OOM risk
- Triggers proactive restarts

**WorkerHealthMonitor** (`health.d`):
- Periodic health checks
- Auto-restart on failure
- Memory-aware recovery

## Configuration

### Pool Configuration

```d
struct WorkerPoolConfig
{
    size_t maxWorkersPerType = 4;
    Duration idleTimeout = minutes(10);
    Duration healthCheckInterval = seconds(30);
    size_t maxRequestsPerWorker = 10_000;
    size_t maxHeapMB = 2048;
    bool enableMetrics = true;
    bool enableRecycling = true;
    bool enableMemoryMonitor = true;
    bool persistAcrossBuilds = true;
    RecyclingPolicy recyclingPolicy;
    MemoryThresholds memoryThresholds;
}
```

### Recycling Policy

```d
struct RecyclingPolicy
{
    Duration maxIdleTime = minutes(10);
    Duration minKeepWarmTime = minutes(2);
    Duration hotWorkerBonus = minutes(5);
    uint maxRequestsBeforeRecycle = 10_000;
    bool preferWarmWorkers = true;
    bool keepHotAcrossBuilds = true;
}
```

### Memory Thresholds

```d
struct MemoryThresholds
{
    float normalMax = 0.70f;    // < 70% normal
    float elevatedMax = 0.85f;  // 70-85% elevated
    float highMax = 0.95f;      // 85-95% high (restart)
                                // > 95% critical
}
```

### Worker Configuration

```d
struct PersistentWorkerConfig
{
    string executable;
    string[] baseArgs;
    Duration startupTimeout = seconds(30);
    Duration requestTimeout = seconds(300);
    Duration idleTimeout = seconds(60);
    size_t maxRequests = 1000;
    bool enableMultiplexing;
    string workDir;
    string[string] environment;
}
```

## Memory Pressure

| Level | Threshold | Action |
|-------|-----------|--------|
| Normal | < 70% | Continue |
| Elevated | 70-85% | Log warning |
| High | 85-95% | Trigger restart (warm deferred) |
| Critical | > 95% | Immediate restart |

## Warmth-Aware Recycling

### Eviction Priority

1. Cold workers evicted first
2. Hot workers get extended idle time (`hotWorkerBonus`)
3. Warm workers preserved for `minKeepWarmTime`

### Worker Selection

When selecting worker for new request:
1. If `preferWarmWorkers` enabled, select warmest available
2. Otherwise FIFO

## Usage

### Programmatic

```d
import engine.workers;

// Create service
auto config = WorkerPoolConfig.init;
auto service = new PersistentWorkerService(config);
service.start();

// Compile Java
auto result = service.compileJava(
    ["src/Main.java"],
    "bin/",
    ["lib/deps.jar"],
    ["-source", "17"]
);

if (result.isOk) {
    auto r = result.unwrap();
    writeln("Compiled in ", r.executionTimeMs, "ms");
}

// Shutdown
service.stop();
```

### Builderspace Configuration

```yaml
build:
  persistent_workers:
    enabled: true
    max_workers_per_type: 4
    idle_timeout: 10m
```

## Health Monitoring

**Module:** `engine.workers.health`

### Health Status

- `Healthy` - Responding normally
- `Degraded` - Slow but functioning
- `MemoryHigh` - Memory pressure detected
- `Unresponsive` - Not responding to pings
- `Dead` - Process died
- `Recovered` - Restarted successfully

### Configuration

```d
struct HealthMonitorConfig
{
    Duration checkInterval = seconds(10);
    Duration slowResponseThreshold = seconds(5);
    uint maxConsecutiveFailures = 3;
    bool autoRestartOnOOM = true;
    bool preferWarmRestart = true;
}
```

### Statistics

```d
auto summary = health.getSummary();
writeln("Health: ", summary.healthPercentage(), "%");
writeln("Avg response: ", summary.avgResponseTimeMs, "ms");
writeln("Restarts: ", summary.totalRestarts);
```

## Metrics

```d
auto stats = pool.getStats();
writeln("Active workers: ", stats.activeWorkers);
writeln("Total requests: ", stats.totalRequests);
writeln("Average latency: ", stats.avgLatencyMs, "ms");

auto recyclerStats = recycler.getStats();
writeln("Hot workers: ", recyclerStats.byLevel[WarmthLevel.Hot]);
writeln("Estimated speedup: ", recycler.estimatedSpeedup(), "x");
```

## Troubleshooting

### Workers Not Starting

1. Verify compiler available: `which javac`, `which tsc`
2. Check memory limits
3. Review startup timeout

### Poor Performance

1. Check warmth distribution
2. Increase `idle_timeout` to preserve warm workers
3. Ensure `persistAcrossBuilds = true`

### High Memory Usage

1. Reduce `maxWorkersPerType`
2. Lower `maxHeapMB`
3. Reduce `maxRequestsPerWorker`

### Frequent OOM Restarts

1. Lower `highMax` threshold
2. Reduce `maxRequestsPerWorker` for leak detection
3. Increase heap limits if RAM available

## See Also

- [Performance](performance.md)
- [Concurrency](concurrency.md)
- [Bazel Persistent Workers](https://bazel.build/remote/persistent)
