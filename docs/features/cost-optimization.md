# Cost Optimization

## Overview

Builder provides cost-aware build planning through its economics module. While traditional build systems optimize exclusively for time, Builder computes Pareto-optimal build plans across the cost-time tradeoff space.

### Key Capabilities

- **Budget-constrained builds**: Find the fastest build within a specified budget
- **Time-constrained builds**: Find the cheapest build within a time limit
- **Multi-objective optimization**: Balance cost and time using Pareto frontier computation
- **Historical learning**: Improve estimates over time using execution history

## Quick Start

### CLI Usage

```bash
# Build within a budget (USD)
bldr build --budget=5.00

# Build within a time limit (seconds)
bldr build --time-limit=120

# Optimize for cost (ignores time)
bldr build --optimize=cost

# Optimize for time (ignores cost)
bldr build --optimize=time

# Balanced optimization (default)
bldr build --optimize=balanced
```

### Example Output

```
Computing optimal build plan...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Economic Build Plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Strategy: Distributed (4 workers, 16 cores)
Est. Cost: $4.87
Est. Time: 5m 20s
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Architecture

The economics module is located in `source/engine/economics/`:

```
economics/
├── pricing.d         # Resource pricing models (AWS, GCP, Azure, local)
├── strategies.d      # Execution strategies and Pareto frontier computation
├── optimizer.d       # Build plan optimization engine
├── estimator.d       # Cost/time estimation from historical data
├── tracking.d        # Historical execution tracking
├── integration.d     # BuildServices integration
└── README.md
```

### Core Types

**OptimizationObjective** (`optimizer.d`):
- `MinimizeCost` — Find cheapest build
- `MinimizeTime` — Find fastest build
- `Balanced` — Balance cost and time (α=0.5)
- `Budget` — Fastest within budget constraint
- `TimeLimit` — Cheapest within time constraint

**ExecutionStrategy** (`strategies.d`):
- `Local` — Execute on local machine ($0 cost)
- `Cached` — Cache hit (~$0.0001 cost)
- `Distributed` — Remote workers (variable cost)
- `Premium` — High-performance instances (2x cost, 1.5x speed)

## Optimization Algorithm

### Pareto Frontier Computation

A build plan P is **Pareto-optimal** if no other plan P' satisfies:
- `cost(P') ≤ cost(P)` AND `time(P') ≤ time(P)`
- with at least one strict inequality

The `ParetoFrontier` struct in `strategies.d` computes this:

```d
static ParetoFrontier compute(BuildPlan[] candidates) {
    BuildPlan[] frontier;
    foreach (candidate; candidates) {
        bool dominated = frontier.any!(p => p.dominates(candidate));
        if (!dominated) {
            frontier = frontier.filter!(p => !candidate.dominates(p)).array;
            frontier ~= candidate;
        }
    }
    return ParetoFrontier(frontier.sort!((a, b) => a.expectedCost() < b.expectedCost()).array);
}
```

### Plan Selection

From the Pareto frontier, the optimizer selects based on constraints:

- **Budget constraint**: Filter to plans where `cost ≤ budget`, select minimum time
- **Time constraint**: Filter to plans where `time ≤ limit`, select minimum cost
- **Balanced**: Minimize weighted objective `α·cost + (1-α)·time`

### Cost Model

For each target and strategy:

```
cost(t, s) = cpuCost + memoryCost + networkCost

cpuCost     = cores × duration × pricePerCoreHour
memoryCost  = memory × duration × pricePerGBHour
networkCost = transferSize × pricePerGB
```

Cache hits reduce expected cost:

```
expectedCost = (1 - cacheHitProbability) × computeCost + cacheHitProbability × ε
```

where `ε ≈ $0.0001` for cache lookup.

## Execution Strategies

The `StrategyEnumerator` generates candidate plans:

### Local Strategy
- Workers: 1 (local machine)
- Cost: $0.00
- Parallelism: Limited to local cores

### Cached Strategy
- Cost: ~$0.0001 (cache lookup only)
- Time: 5% of baseline (when cache hits)
- Requires: Prior successful build

### Distributed Strategy
- Workers: 4, 8, or 16 (enumerated)
- Cost: Scales with worker count and duration
- Speedup: Estimated via Amdahl's law approximation

```d
float estimateSpeedup(size_t workers) =>
    1.0f / (0.2f + 0.8f / workers);  // 20% sequential, 80% parallelizable
```

### Premium Strategy
- Workers: 4 or 8 premium instances
- Cost: 2x standard pricing
- Speedup: 1.5x faster hardware

## Pricing Configuration

### Cloud Providers

Defined in `pricing.d`:

**AWS (default)**:
- CPU: $0.0416/core-hour (t3.medium)
- Memory: $0.0052/GB-hour
- Network: $0.09/GB egress

**GCP**:
- CPU: $0.0475/core-hour (e2-medium)
- Memory: $0.0064/GB-hour
- Network: $0.085/GB egress

**Azure**:
- CPU: $0.042/core-hour (B2s)
- Memory: $0.0055/GB-hour
- Network: $0.087/GB bandwidth

**Local**:
- All costs: $0.00

### Pricing Profiles

- `standard` — Base pricing (1.0x multiplier)
- `spot` — 0.3x cost, 85% reliability
- `premium` — 2.0x cost, 99.9% reliability

## Environment Variables

```bash
# Enable cost optimization
export BUILDER_COST_OPTIMIZATION=true

# Cloud provider (aws, gcp, azure, local)
export BUILDER_CLOUD_PROVIDER=aws

# Pricing tier (spot, ondemand, reserved, premium)
export BUILDER_PRICING_TIER=ondemand

# Default budget (USD)
export BUILDER_BUDGET=5.00

# Default time limit (seconds)
export BUILDER_TIME_LIMIT=120

# Optimization mode (cost, time, balanced)
export BUILDER_OPTIMIZE=balanced
```

## Builderspace Configuration

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

## Historical Tracking

Execution history is stored in `.builder-cache/execution-history.json`:

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

### Estimation Accuracy

- **Cold start** (no history): ±50% accuracy, uses language-based heuristics
- **Warm cache** (some history): ±20% accuracy, exponential moving average
- **Stable workload** (5+ executions): ±10% accuracy

Update formula:
```
newEstimate = 0.7 × oldEstimate + 0.3 × actual
```

## Profile-Guided Scheduling

The economics module integrates with distributed scheduling through `ProfileGuidedScheduler`:

```d
// Economics integration exposes execution history
auto history = economics.getExecutionHistory();

// Profile scheduler uses history for cost estimates
auto profileScheduler = createProfiledScheduler(graph, history);

// Distributed scheduler uses profile data for priority
distScheduler.enableProfileGuidedScheduling(profileScheduler);
```

Scheduling priority formula:
```
score = criticalPathCost × 100 + dependentCount × 10 - depth × 1
```

This schedules expensive actions on the critical path first.

## Performance Overhead

| Operation | Time | Complexity |
|-----------|------|------------|
| Strategy enumeration | <1ms | O(10) |
| Pareto computation | <1ms | O(n²) |
| Plan selection | <1ms | O(n) |
| **Total overhead** | **<5ms** | — |

## Current Limitations

1. **Informational only**: Economics computes optimal plans but does not yet automatically apply them to execution. Worker allocation is manual.

2. **Static optimization**: Plans are computed before build execution, not adjusted dynamically during the build.

3. **Estimation accuracy**: Cold-start estimates rely on heuristics; accuracy improves with historical data.

## Planned Enhancements

- **Automatic worker allocation**: Apply computed plans to RemoteExecutor
- **Dynamic scaling**: Adjust workers mid-build based on progress
- **ML-based estimation**: Neural network for predicting build times
- **Real-time feedback**: Adjust strategy if exceeding budget

## Integration Example

```d
import engine.economics.optimizer;
import engine.economics.pricing;
import engine.economics.estimator;

auto history = new ExecutionHistory();
auto estimator = new CostEstimator(history);

PricingConfig pricingConfig;
pricingConfig.provider = CloudProvider.aws();
pricingConfig.profile = PricingProfile.onDemand;

auto optimizer = new CostOptimizer(estimator, pricingConfig);

auto constraints = OptimizationConstraints();
constraints.objective = OptimizationObjective.Budget;
constraints.budgetUSD = 5.00;

auto planResult = optimizer.optimize(graph, constraints);
if (planResult.isOk) {
    auto plan = planResult.unwrap();
    writeln(formatPlan(plan));
}
```

## See Also

- [Economics README](../../source/engine/economics/README.md)
- [Speculative Execution](speculation.md)
- [Remote Execution](remote-execution.md)
- [Distributed Builds](distributed.md)
- [Caching](caching.md)
