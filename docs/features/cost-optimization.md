# Cost Optimization

## Quick Start

### Basic Usage

```bash
# Optimize within budget
$ bldr build --budget=5.00

# Optimize within time limit (seconds)
$ bldr build --time-limit=120

# Optimize for cost
$ bldr build --optimize=cost

# Optimize for time
$ bldr build --optimize=time

# Balanced optimization
$ bldr build --optimize=balanced
```

### Example Output

```bash
$ bldr build --budget=5.00
Starting build...
Computing optimal build plan...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Economic Build Plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Strategy: Distributed (4 workers, 16 cores)
Est. Cost: $4.87
Est. Time: 5m 20s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Building 147 targets...
[████████████████████████████████████████] 147/147 (100%)

Build completed successfully!

Build Cost Summary:
  Total Cost:   $4.23
  Total Time:   5m 42s
  Executions:   147
  Cache Hits:   96 (65.3%)
  Avg Cost:     $0.029
```

## Why Cost Optimization?

### The Problem

Traditional build systems optimize for a single objective: **build time**. However, builds consume real resources with real costs:

- **CPU**: Remote workers charge by core-hour ($0.04-$0.10/hour)
- **Memory**: Larger instances cost more ($0.005-$0.01/GB-hour)
- **Network**: Data transfer has measurable cost ($0.08-$0.12/GB)
- **Storage**: Artifact storage and I/O operations

At scale, these costs compound:

| Scenario | Workers | Time | Cost |
|----------|---------|------|------|
| Aggressive | 32 | 2m | $12.30 |
| Balanced | 8 | 6m | $4.50 |
| Conservative | 2 | 18m | $1.20 |

**All three are valid** depending on your constraints!

### The Solution

Builder introduces **multi-objective optimization** that finds **Pareto-optimal** solutions:

> A build plan is Pareto-optimal if no other plan is strictly better in BOTH cost AND time

This enables:
- **Budget-Aware CI**: "Spend at most $5 per build"
- **Time-Critical Releases**: "Build in under 2 minutes"
- **Cost-Optimized Nightly**: "Minimize cost, time is flexible"

## Optimization Modes

### 1. Budget-Constrained

Find the **fastest build** within a budget:

```bash
$ bldr build --budget=5.00
```

**Use Cases**:
- CI/CD with cost quotas
- Startup/small teams with tight budgets
- Development builds (optimize for cost)

**Algorithm**:
```
1. Enumerate candidate strategies
2. Compute Pareto frontier
3. Filter plans where cost ≤ budget
4. Select plan with minimum time
```

### 2. Time-Constrained

Find the **cheapest build** within a time limit:

```bash
$ bldr build --time-limit=120  # 2 minutes
```

**Use Cases**:
- Release pipelines (must finish quickly)
- Pre-commit checks (developer waiting)
- Continuous deployment (fast feedback)

**Algorithm**:
```
1. Enumerate candidate strategies
2. Compute Pareto frontier
3. Filter plans where time ≤ limit
4. Select plan with minimum cost
```

### 3. Objective-Based

Optimize for a specific objective:

```bash
# Minimize cost (no time constraint)
$ bldr build --optimize=cost

# Minimize time (no cost constraint)
$ bldr build --optimize=time

# Balance cost and time (α=0.5)
$ bldr build --optimize=balanced
```

**Use Cases**:
- **Cost**: Nightly builds, batch jobs, non-urgent tasks
- **Time**: Hot fixes, production incidents, developer feedback
- **Balanced**: Regular CI/CD, default mode

## Execution Strategies

Builder evaluates 4 execution strategies:

### 1. Local (Free)

Execute on developer machine using local cores.

**Characteristics**:
- **Cost**: $0.00
- **Time**: Baseline (1x)
- **Parallelism**: Limited to local cores
- **Reliability**: 100% (always available)

**When Used**:
- `--optimize=cost` (always cheapest)
- Offline development
- No remote workers available

### 2. Cached (Near-Free)

Fetch results from cache (previous build).

**Characteristics**:
- **Cost**: ~$0.0001 (cache lookup)
- **Time**: 100x faster (seconds vs minutes)
- **Hit Rate**: Depends on code stability
- **Reliability**: 100% if cache hit

**When Used**:
- Incremental builds (code hasn't changed)
- CI on stable branches
- High cache hit probability

### 3. Distributed (Variable)

Execute on remote worker pool with N workers.

**Characteristics**:
- **Cost**: Scales with worker count
- **Time**: Scales with parallelism (Amdahl's Law)
- **Workers**: 1-64 (configurable)
- **Reliability**: 99% (with retry)

**Scaling**:
```
Speedup = 1 / ((1-P) + P/N)

where P = parallelizable fraction (typically 0.9)
      N = worker count
```

**When Used**:
- Production builds
- CI/CD pipelines
- Balanced time/cost requirements

### 4. Premium (Expensive, Fast)

Execute on high-performance dedicated instances.

**Characteristics**:
- **Cost**: 2x standard pricing
- **Time**: 1.5x faster (better hardware)
- **Workers**: 16 premium instances
- **Reliability**: 99.9% (dedicated)

**When Used**:
- Time-critical releases
- Production incidents
- `--optimize=time` with tight deadlines

## Pricing Models

### Cloud Providers

Builder uses realistic pricing from major cloud providers:

#### AWS (Default)

```d
ResourcePricing(
    costPerCoreHour: 0.0416,  // t3.medium
    costPerGBHour: 0.0052,
    costPerNetworkGB: 0.09,    // First 10TB
    costPerDiskIOGB: 0.001
)
```

#### GCP

```d
ResourcePricing(
    costPerCoreHour: 0.0475,  // e2-medium
    costPerGBHour: 0.0064,
    costPerNetworkGB: 0.085,
    costPerDiskIOGB: 0.001
)
```

#### Azure

```d
ResourcePricing(
    costPerCoreHour: 0.042,   // B2s
    costPerGBHour: 0.0055,
    costPerNetworkGB: 0.087,
    costPerDiskIOGB: 0.001
)
```

#### Local (Developer Machine)

```d
ResourcePricing(
    costPerCoreHour: 0.0,
    costPerGBHour: 0.0,
    costPerNetworkGB: 0.0,
    costPerDiskIOGB: 0.0
)
```

### Pricing Tiers

Different instance types have different cost/performance tradeoffs:

| Tier | Cost Multiplier | Reliability | Speedup | Use Case |
|------|----------------|-------------|---------|----------|
| **Spot** | 0.3x | 85% | 1.0x | Batch jobs, cost-sensitive |
| **On-Demand** | 1.0x | 99% | 1.0x | Standard CI/CD |
| **Reserved** | 0.6x | 99% | 1.0x | Long-term committed |
| **Premium** | 2.0x | 99.9% | 1.5x | Time-critical, production |

Set via environment:
```bash
export BUILDER_PRICING_TIER=spot        # Cheapest
export BUILDER_PRICING_TIER=ondemand    # Default
export BUILDER_PRICING_TIER=premium     # Fastest
```

## Historical Tracking

Builder learns from past executions to improve estimates.

### Execution History

Stored in `.builder-cache/execution-history.json`:

```json
[
  {
    "target": "//src:main",
    "duration": 15000,
    "cores": 4,
    "memory": 2147483648,
    "network": 10485760,
    "diskIO": 104857600,
    "cacheHitRate": 0.65,
    "execCount": 23
  }
]
```

### Estimation Strategy

**Cold Start** (no history):
- Language-based heuristics (C++ = 30s, Python = 5s)
- Source count scaling (10+ files = longer)
- ±50% accuracy

**Warm Cache** (historical data):
- Exponential moving average (α=0.3)
- Actual vs estimated comparison
- ±20% accuracy

**Stable Workload** (5+ executions):
- Converges to actual patterns
- ±10% accuracy
- Accounts for cache hit rate

### Continuous Improvement

After each build:
```d
tracker.trackExecution(
    targetId: "//src:main",
    duration: 14500.msecs,
    usage: ResourceUsageEstimate(...),
    cost: 0.043,
    cacheHit: false
);
```

Updates history with exponential moving average:
```
newEstimate = 0.7 × oldEstimate + 0.3 × actual
```

## Configuration

### Environment Variables

```bash
# Enable cost optimization
export BUILDER_COST_OPTIMIZATION=true

# Set cloud provider
export BUILDER_CLOUD_PROVIDER=aws      # aws, gcp, azure, local

# Set pricing tier
export BUILDER_PRICING_TIER=ondemand   # spot, ondemand, reserved, premium

# Set default budget (USD)
export BUILDER_BUDGET=5.00

# Set default time limit (seconds)
export BUILDER_TIME_LIMIT=120

# Set optimization mode
export BUILDER_OPTIMIZE=balanced       # cost, time, balanced
```

### Builderspace Configuration

Add economics config to `Builderspace`:

```
workspace {
  economics {
    enabled: true
    provider: "aws"
    tier: "ondemand"
    budget: 5.00
    optimize: "balanced"
  }
}
```

## CLI Reference

### Flags

| Flag | Type | Description |
|------|------|-------------|
| `--budget` | float | Maximum budget in USD |
| `--time-limit` | float | Maximum time in seconds |
| `--optimize` | string | Optimization mode (cost, time, balanced) |

### Examples

```bash
# Budget-constrained build
bldr build --budget=5.00

# Time-constrained build
bldr build --time-limit=120

# Cost-optimized build
bldr build --optimize=cost

# Time-optimized build
bldr build --optimize=time

# Balanced build (default)
bldr build --optimize=balanced

# Combine with remote execution
bldr build --remote --budget=10.00

# Environment-based configuration
BUILDER_BUDGET=5.00 bldr build
```

## API Reference

See [`source/engine/economics/README.md`](../../source/engine/economics/README.md) for detailed API documentation.

## Performance Impact

Cost optimization adds **negligible overhead**:

| Operation | Time | Complexity |
|-----------|------|------------|
| Strategy enumeration | <1ms | O(10) |
| Pareto computation | <1ms | O(100) |
| Plan selection | <1ms | O(10) |
| **Total overhead** | **<5ms** | **O(100)** |

For a 5-minute build, this is **0.002%** overhead.

## Limitations

### Current Limitations

1. **Informational Only**: Economics currently computes optimal plans but doesn't automatically apply them to execution. Future work will integrate with RemoteExecutor to allocate workers based on selected plan.

2. **Estimation Accuracy**: Cold-start estimates can be ±50% off. Accuracy improves with historical data.

3. **Static Optimization**: Plans are computed before build, not dynamically adjusted during execution.

### Future Enhancements

1. **Dynamic Application**: Automatically allocate N workers based on selected plan
2. **Real-Time Adjustment**: Update strategy mid-build based on actual progress
3. **ML-Based Estimation**: Neural network for predicting build time
4. **Portfolio Optimization**: Optimize across entire dependency graph
5. **Spot Instance Support**: Use spot instances for cost savings

## Comparison with Other Build Systems

| Feature | Builder | Bazel | Buck2 | Pants |
|---------|---------|-------|-------|-------|
| Cost optimization | ✅ Yes | ❌ No | ❌ No | ❌ No |
| Budget constraints | ✅ Yes | ❌ No | ❌ No | ❌ No |
| Time constraints | ✅ Yes | ❌ No | ❌ No | ❌ No |
| Multi-objective | ✅ Pareto | ❌ Time only | ❌ Time only | ❌ Time only |
| Cost tracking | ✅ Yes | ❌ No | ❌ No | ❌ No |
| Historical learning | ✅ EMA | ⚠️ Partial | ⚠️ Partial | ⚠️ Partial |

**Builder is the only build system with economic awareness.**

## See Also

- [Economics README](../../source/engine/economics/README.md)
- [Remote Execution](remote-execution.md)
- [Distributed Builds](distributed.md)
- [Caching](caching.md)

---

*Innovation: Builder is the first build system to treat build resources as economic assets and optimize for cost, not just time.*

