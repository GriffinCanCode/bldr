# Speculative Execution for Critical Path Optimization

This module implements speculative execution to accelerate builds by pre-executing targets on the critical path before their dependencies complete.

## Overview

Traditional build systems wait for all dependencies to complete before starting a target. This module breaks that constraint by:

1. **Identifying the critical path** - The longest weighted path through the build graph
2. **Speculatively starting targets** - Begin execution before all inputs are ready
3. **Tracking input hashes** - Detect if inputs change during speculation
4. **Aborting invalid work** - Cancel speculation if inputs change

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│               SpeculationService                         │
│                                                          │
│  ┌──────────────────┐    ┌───────────────────────┐      │
│  │ ProfileGuided    │    │ SpeculativeTask      │      │
│  │ Scheduler        │───▶│ - inputHashes        │      │
│  │ - criticalPath   │    │ - status (atomic)    │      │
│  │ - economics      │    │ - resultHash         │      │
│  └──────────────────┘    └───────────────────────┘      │
│           │                        │                    │
│           ▼                        ▼                    │
│  ┌──────────────────┐    ┌───────────────────────┐      │
│  │ SpeculationPolicy│    │ InputValidator       │      │
│  │ - maxConcurrent  │    │ - hashTracking       │      │
│  │ - minCostMs      │    │ - abortOnChange      │      │
│  │ - confidence     │    └───────────────────────┘      │
│  └──────────────────┘                                   │
└─────────────────────────────────────────────────────────┘
```

## Key Components

### SpeculationPolicy

Controls when and how aggressively to speculate:

```d
// Conservative: minimal risk
auto policy = SpeculationPolicy.conservative();
// maxConcurrent = 2, minCostMs = 2000, confidence = 0.9

// Balanced: moderate speculation
auto policy = SpeculationPolicy.balanced();
// maxConcurrent = 4, minCostMs = 500, confidence = 0.7

// Aggressive: maximize speculation
auto policy = SpeculationPolicy.aggressive();
// maxConcurrent = 8, minCostMs = 200, confidence = 0.5
```

### SpeculativeTask

Tracks a single speculative execution:

- **inputHashes**: Hash of all inputs at speculation start
- **status**: Atomic status (Pending → Running → Completed/Aborted)
- **confidence**: Probability estimate that speculation will be valid
- **resultHash**: Hash of output if completed successfully

### SpeculationStats

Measures speculation effectiveness:

- **effectiveness**: Ratio of successful speculations (0.0 - 1.0)
- **roi**: Return on investment (timeSaved / timeWasted)
- **aborted**: Count of speculations cancelled due to input changes

## Usage

### Basic Usage

```d
import engine.runtime.services.speculation;

// Create speculation service
auto speculation = createSpeculationService(graph, executionHistory);
speculation.setPolicy(SpeculationPolicy.balanced());

// Start speculation during build
speculation.analyzeGraph(graph);
speculation.beginSpeculation();

// Check for valid speculative results before executing
if (auto result = speculation.getValidResult(targetId))
    useSpeculativeResult(result);
else
    executeNormally(targetId);

// Notify when inputs change
speculation.notifyInputChanged(path, newHash);

// Cleanup
speculation.shutdown();
```

### With SpeculationExecutor

```d
import engine.runtime.services.speculation;

auto executor = createSpeculationExecutor(graph, scheduling);
executor.beginSpeculation();

// During normal build loop
foreach (node; readyNodes)
{
    // Try speculation first
    if (auto result = executor.tryGetSpeculativeResult(node.id))
    {
        // Use speculative result
        applyResult(result.get());
    }
    else
    {
        // Execute normally
        execute(node);
    }
}

// Print statistics
auto stats = executor.getStats();
writefln("Speculation: %d hits, %d misses, %.1f%% hit rate",
    stats.hits, stats.misses, stats.hitRate * 100);
```

## Economics Integration

Speculation decisions use the existing economics module:

1. **Cost Estimation**: Only speculate on expensive targets (> minCostMs)
2. **Cache Hit Probability**: Avoid speculation when cache hit is likely
3. **Critical Path Cost**: Prioritize targets that would delay the build most
4. **Budget Fraction**: Limit total speculation to fraction of build budget

## Abort Semantics

Speculation is invalidated when:

1. **Input file changes**: Source file modified during speculation
2. **Dependency changes**: Upstream output differs from expected
3. **Build failure**: Any non-speculative build fails (abort all)

Invalid speculation results are discarded, not cached.

## Performance Characteristics

| Scenario | Benefit |
|----------|---------|
| Long critical path | 10-30% build time reduction |
| High cache hit rate | Minimal benefit (speculation redundant) |
| Frequent input changes | Negative (wasted work) |
| Expensive targets | High benefit per speculation |
| Cheap targets | Not worth overhead |

## Configuration

Environment variables:

- `BUILDER_SPECULATION_ENABLED=0|1` - Enable/disable speculation
- `BUILDER_SPECULATION_POLICY=conservative|balanced|aggressive` - Policy preset

## Testing

```bash
cd tests/unit/services
ldc2 -unittest -I ../../../source speculation.d
./speculation
```

## See Also

- `engine.economics` - Cost estimation and build economics
- `engine.distributed.coordinator.profile` - Profile-guided scheduling
- `engine.graph.core.incremental_topo` - Critical path calculation

