# Remote Execution Example

This example demonstrates Builder's remote execution system with intelligent autoscaling and native hermetic sandboxing.

## What This Demonstrates

1. **Distributed Builds**: Actions execute on remote workers
2. **Autoscaling**: Worker pool scales based on load
3. **Hermetic Execution**: Native OS sandboxing (no Docker required)
4. **Action Caching**: Automatic result reuse
5. **REAPI Compatibility**: Works with Bazel clients

## Architecture

```
┌──────────────┐
│ Build Client │
└──────┬───────┘
       │
       │ Submit Actions
       ▼
┌──────────────────────┐
│ Coordinator (port 9000)│
└──────┬───────────────┘
       │
       │ Schedule
       ▼
┌──────────────────────┐
│   Worker Pool         │
│   (Auto-scaling)      │
│                       │
│ ┌─────┐ ┌─────┐      │
│ │W1   │ │W2   │ ...  │
│ └─────┘ └─────┘      │
└───────────────────────┘
       │
       │ Execute hermetically
       ▼
   Build Artifacts
```

## Setup

### 1. Start Remote Execution Service

```bash
# Terminal 1: Start coordinator and worker pool
cd examples/remote-execution
builder serve --remote \
  --coordinator 0.0.0.0:9000 \
  --workers-min 2 \
  --workers-max 20 \
  --autoscale \
  --reapi 9001

# Output:
# [INFO] Remote execution service starting...
# [INFO]   Coordinator: 0.0.0.0:9000
# [INFO]   REAPI endpoint: 0.0.0.0:9001
# [INFO] Worker pool: 2 workers (autoscale enabled)
# [INFO] Remote execution service ready
```

### 2. Run Build

```bash
# Terminal 2: Build using remote execution
bldr build cpp_project --remote

# Output:
# [INFO] Using remote execution (coordinator: 0.0.0.0:9000)
# [INFO] Uploading inputs... (234 KB)
# [INFO] Executing on worker-1 (hermetic: namespaces+cgroup)
# [INFO] Build completed in 1.2s
# [INFO] Cache miss → stored for reuse
```

### 3. Watch Autoscaling

```bash
# Terminal 3: Monitor workers
builder remote status

# Output:
# Remote Execution Status
# ═══════════════════════
# Service: Running (uptime: 5m 32s)
# 
# Workers:
#   Total: 8
#   Idle: 2
#   Busy: 6
#   Utilization: 75%
# 
# Queue:
#   Pending: 12 actions
#   Executing: 6 actions
#   Completed: 234 actions
# 
# Autoscaling:
#   Predicted load: 82%
#   Trend: +0.15 (increasing)
#   Next action: Scale up (add 4 workers in 15s)
# 
# Metrics:
#   Success rate: 98.7%
#   Cache hit rate: 45.2%
#   Avg execution time: 850ms
```

## Files

- `Builderfile` - Build configuration with remote execution
- `src/main.cpp` - Example C++ application
- `src/math.cpp` - Math utilities
- `src/math.h` - Math headers
- `tests/test_math.cpp` - Unit tests

## Key Configuration

### Hermetic Sandboxing

```yaml
hermetic:
    max_memory: 2GiB      # Memory limit
    max_cpu: 2            # CPU cores
    timeout: 5m           # Execution timeout
```

This creates a `SandboxSpec` that's transmitted to workers, who execute using:
- **Linux**: namespaces + cgroups
- **macOS**: sandbox-exec + rusage
- **Windows**: job objects

**No Docker required!**

### Remote Execution

```yaml
remote: true              # Execute on worker pool
cache: true              # Enable action caching
parallelism: 8           # Max concurrent actions
```

## Testing Locally

You can test without a real worker pool:

```bash
# Use local worker (no coordinator)
bldr build cpp_project --remote=local

# This starts a single worker on localhost
# Useful for testing hermetic specs
```

## Cloud Deployment

### AWS EC2

```bash
# Configure AWS provider
builder remote configure --provider aws \
  --region us-east-1 \
  --instance-type c5.2xlarge \
  --image-id ami-builder-worker-v1

# Start with cloud workers
builder serve --remote --cloud aws
```

### Kubernetes

```bash
# Configure K8s provider
builder remote configure --provider k8s \
  --namespace builder \
  --pod-template worker-pod.yaml

# Start with K8s workers
builder serve --remote --cloud k8s
```

## Performance

### Baseline (Local Build)

```
$ time bldr build cpp_project
real    0m 5.234s
user    0m 4.891s
sys     0m 0.312s
```

### With Remote Execution (8 Workers)

```
$ time bldr build cpp_project --remote
real    0m 1.432s   # 3.7x faster
user    0m 0.123s   # 97% less CPU
sys     0m 0.045s
```

### With Caching

```
$ bldr build cpp_project --remote
[INFO] Cache hit: cpp_project (stored 2m ago)
[INFO] Build completed in 45ms   # 116x faster!
```

## Monitoring

### Real-time Metrics

```bash
# Stream metrics
builder remote watch

# Every 1s:
# ┌─────────────────────────────────┐
# │ Workers: 8 (6 busy, 2 idle)     │
# │ Queue: 12 pending               │
# │ Throughput: 45 actions/min      │
# │ Cache hit rate: 47%             │
# └─────────────────────────────────┘
```

### Prometheus Integration

```bash
# Expose metrics for Prometheus
builder serve --remote --metrics :9090

# Metrics endpoint: http://localhost:9090/metrics
```

## Troubleshooting

### "No workers available"

**Cause:** Worker pool empty or all busy

**Fix:**
```bash
# Increase max workers
builder serve --remote --workers-max 50

# Or manually scale
builder remote scale --workers 20
```

### "Action timeout"

**Cause:** Action exceeds timeout limit

**Fix:**
```yaml
# In Builderfile, increase timeout
hermetic:
    timeout: 10m  # Was 5m
```

### "Cache miss expected hit"

**Cause:** Non-hermetic build (filesystem pollution)

**Fix:**
```bash
# Enable audit mode to find violations
bldr build cpp_project --hermetic-audit

# Output shows what files were accessed outside spec
```

## Advanced Features

### Work Stealing

Workers steal work from each other when idle:

```bash
# Enable P2P work stealing
builder serve --remote --work-stealing

# Workers automatically balance load
```

### Priority Scheduling

```yaml
# In Builderfile
target critical_build:
    priority: high    # Executes before normal priority
    remote: true
```

### Spot Instances (Cost Optimization)

```bash
# Use spot instances for workers
builder remote configure --spot \
  --spot-max-price 0.10 \
  --on-demand-base 2  # Keep 2 on-demand for reliability
```

## See Also

- [Hermetic Builds](../../docs/features/hermetic.md)
- [Remote Caching](../../docs/features/remotecache.md)
- [Work Stealing](../../docs/features/workstealing.md)
- [Observability](../../docs/features/observability.md)

