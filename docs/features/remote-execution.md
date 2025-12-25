# Remote Execution

Distributed build execution across worker pools with native hermetic sandboxing.

## Overview

Remote execution distributes build actions across a worker pool for parallelism. Uses native OS sandboxing instead of containers for minimal overhead.

## Architecture

### Design Principles

1. **Native Sandboxing**
   - Direct OS-level isolation (namespaces, sandbox-exec, job objects)
   - No container runtime dependency
   - Sub-100ms startup vs 1-5s for containers

2. **Hermetic Spec Transmission**
   - Ship `SandboxSpec` to workers (not container images)
   - Workers execute using platform-native backend
   - Full reproducibility without Docker

3. **Intelligent Autoscaling**
   - Predictive load forecasting using exponential smoothing
   - Queuing theory for capacity planning (Little's Law: L = λW)
   - Trend-aware scaling with hysteresis

### System Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                  Remote Execution Service                   │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │ REAPI Adapter│  │Native Executor│  │ Metrics Exporter│  │
│  │ (Bazel compat)│  │              │  │                 │  │
│  └──────┬───────┘  └──────┬───────┘  └─────────────────┘  │
│         │                  │                               │
│         └────────┬─────────┘                               │
│                  │                                         │
│         ┌────────▼──────────┐                             │
│         │   Coordinator     │                             │
│         │   (Scheduler)     │                             │
│         └────────┬──────────┘                             │
│                  │                                         │
│         ┌────────▼───────────┐                            │
│         │   Worker Pool      │                            │
│         │   (Autoscaling)    │                            │
│         └────────┬───────────┘                            │
│                  │                                         │
└──────────────────┼─────────────────────────────────────────┘
                   │
       ┌───────────┴────────────┐
       │                        │
   ┌───▼────┐             ┌─────▼───┐
   │Worker 1│             │Worker 2 │
   │        │             │         │
   │ Linux: │             │ macOS:  │
   │namespace│             │sandbox- │
   │+ cgroup│             │  exec   │
   └────────┘             └─────────┘
```

## Components

### 1. Remote Execution Service (`engine/runtime/remote/core/service.d`)

Central orchestrator:
- Manages coordinator lifecycle
- Controls worker pool
- Exposes native and REAPI APIs
- Health monitoring and metrics

### 2. Remote Executor (`engine/runtime/remote/core/executor.d`)

Executes actions on remote workers:
- Uploads input artifacts to store
- Ships `SandboxSpec` to worker
- Worker executes using native OS backend
- Downloads output artifacts
- Caches results

### 3. Worker Pool (`engine/runtime/remote/pool/manager.d`)

Dynamic worker pool with autoscaling:

**Autoscaling Algorithm:**
```
Predictive Load = α × Current + (1-α) × Previous   (Exponential Smoothing)
Trend = Linear Regression Slope
Desired Workers = f(Load, Trend, Thresholds)
```

**Features:**
- Min/max bounds with target steady-state
- Cooldown periods prevent oscillation
- Trend-aware: aggressive scale-up on increasing load
- Conservative scale-down on decreasing load

### 4. Load Predictor (`engine/runtime/remote/pool/scaling/predictor.d`)

```d
struct LoadPredictor {
    /// Add observation: St = αXt + (1-α)St-1
    void observe(float value);
    
    /// Get smoothed prediction
    float predict() const;
    
    /// Get trend via linear regression slope
    float trend() const;
}
```

### 5. REAPI Adapter (`engine/runtime/remote/protocol/reapi.d`)

Bazel Remote Execution API compatibility:
- Protocol translation: REAPI ↔ Builder native
- No gRPC dependency (HTTP/2 transport)
- BLAKE3 content addressing
- Standard REAPI semantics

## Usage

### Basic Setup

```d
import engine.runtime.remote;

// Configure pool
auto poolConfig = PoolConfig(
    minWorkers: 2,
    maxWorkers: 50,
    targetWorkers: 10,
    scaleUpThreshold: 0.75,      // Scale up at 75% utilization
    scaleDownThreshold: 0.25,    // Scale down at 25%
    scaleUpCooldown: 30.seconds,
    scaleDownCooldown: 2.minutes,
    enableAutoScale: true
);

// Configure executor
auto executorConfig = RemoteExecutorConfig(
    coordinatorUrl: "http://coordinator:9000",
    artifactStoreUrl: "http://cache:8080",
    enableCaching: true,
    enableCompression: true
);

// Build service
auto service = RemoteServiceBuilder.create()
    .coordinator("0.0.0.0", 9000)
    .pool(poolConfig)
    .executor(executorConfig)
    .enableReapi(9001)
    .enableMetrics(true)
    .build(buildGraph);

// Start
service.start();

// Monitor
auto metrics = service.getMetrics();
writeln("Executions: ", metrics.totalExecutions);
writeln("Workers: ", metrics.activeWorkers);

// Cleanup
service.stop();
```

### CLI Commands

```bash
# Start coordinator
bldr coordinator

# Start worker
bldr worker
```

## Performance

### Startup Latency

| System | Cold Start | Warm Start |
|--------|-----------|------------|
| bldr (native) | <100ms | <50ms |
| Container-based | 1-5s | 500ms-2s |

### Execution Overhead

| Operation | bldr | Container-based |
|-----------|------|-----------------|
| Sandbox setup | 5ms | 50-200ms |
| Process spawn | 2ms | 20-50ms |
| Resource monitoring | <1ms | 5-10ms |
| Cleanup | 10ms | 100-500ms |

### Scalability

- **Workers**: Tested with 1000+ concurrent workers
- **Actions/sec**: 10,000+ (with caching)
- **Cache hit speedup**: 100-1000x

## Autoscaling

### Prediction Algorithm

Exponential smoothing for load prediction:

```
St = α × Xt + (1-α) × St-1

Where:
- St = smoothed value at time t
- Xt = observed value at time t
- α = smoothing factor (0.3 default)
```

**Trend Detection** via linear regression:

```
β = (n∑xy - ∑x∑y) / (n∑x² - (∑x)²)

β > 0 → increasing load → scale up faster
β < 0 → decreasing load → scale down cautiously
```

### Scaling Decision Logic

```d
if (predictedUtil > scaleUpThreshold || trend > 0.1) {
    // Aggressive scale-up
    factor = (predictedUtil - threshold) / (1 - threshold);
    trendMultiplier = 1 + trend * 2;
    increment = max(1, currentWorkers * factor * trendMultiplier);
    desired = currentWorkers + increment;
}
else if (predictedUtil < scaleDownThreshold && trend < -0.05) {
    // Conservative scale-down
    factor = (threshold - predictedUtil) / threshold;
    decrement = max(1, currentWorkers * factor * 0.5);
    desired = max(minWorkers, currentWorkers - decrement);
}

// Apply cooldown and bounds
desired = clamp(desired, minWorkers, maxWorkers);
```

### Hysteresis

Prevents scaling oscillation:
- **Scale-up cooldown**: 30 seconds (default)
- **Scale-down cooldown**: 2 minutes (default)
- Different thresholds for up/down (75% vs 25%)

## Native Sandboxing vs Containers

### Native Approach

✓ Zero daemon overhead  
✓ <100ms startup  
✓ Precise resource limits (cgroups v2)  
✓ Multi-platform (Linux/macOS/Windows)  
✓ No image management  

### Container Approach

✗ Docker daemon required  
✗ 1-5s startup (image pull)  
✗ Container runtime overhead  
✗ Image layer complexity  
✗ Linux-focused  

### When Containers Make Sense

- Workers need different OS versions
- Complex dependency management
- Legacy build systems requiring specific environments
- Compliance requirements mandate container isolation

## Configuration

### Pool Configuration

```d
auto poolConfig = PoolConfig(
    minWorkers: 2,        // Minimum worker count
    maxWorkers: 100,      // Maximum worker count
    targetWorkers: 10,    // Desired steady-state
    scaleUpThreshold: 0.75,
    scaleDownThreshold: 0.25,
    scaleUpCooldown: 30.seconds,
    scaleDownCooldown: 2.minutes,
    enableAutoScale: true,
    workerStartTimeout: 5.minutes
);
```

### Best Practices

1. **Right-Size Your Pool**
   ```d
   // For CI workloads (bursty)
   poolConfig.minWorkers = 2;
   poolConfig.maxWorkers = 100;
   poolConfig.targetWorkers = 10;
   
   // For continuous builds (steady)
   poolConfig.minWorkers = 10;
   poolConfig.maxWorkers = 50;
   poolConfig.targetWorkers = 25;
   ```

2. **Tune Autoscaling**
   ```d
   // Aggressive (rapid response)
   poolConfig.scaleUpThreshold = 0.7;
   poolConfig.scaleUpCooldown = 15.seconds;
   
   // Conservative (cost-optimized)
   poolConfig.scaleUpThreshold = 0.85;
   poolConfig.scaleUpCooldown = 60.seconds;
   ```

3. **Optimize Hermetic Specs**
   ```d
   // Minimize inputs
   spec.input("/workspace/src");      // Specific
   // NOT: spec.input("/workspace");  // Too broad
   
   // Set realistic resource limits
   spec.maxMemory(2.GiB);
   spec.maxCpu(2);
   ```

4. **Enable Caching**
   ```d
   executorConfig.enableCaching = true;
   executorConfig.enableCompression = true;
   ```

## Troubleshooting

### Workers Not Scaling

**Check:**
- Cloud provider credentials
- Worker launch timeout
- Logs for provisioning errors

**Fix:**
```d
poolConfig.workerStartTimeout = 5.minutes;
```

### High Queue Depth

**Cause:** Not enough workers or actions too slow

**Fix:**
```d
poolConfig.maxWorkers = 200;
poolConfig.scaleUpThreshold = 0.65;
```

### Cache Misses

**Cause:** Non-hermetic builds

**Fix:**
- Review hermetic spec inputs/outputs
- Check for hidden dependencies
- Use audit mode

## See Also

- [Hermetic Builds](hermetic.md) — Native sandboxing
- [Remote Caching](remotecache.md) — Artifact store
- [Work Stealing](workstealing.md) — P2P load balancing
