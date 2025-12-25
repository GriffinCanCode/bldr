# Speculative Execution

## Overview

Speculative execution pre-executes build targets on the critical path before their dependencies fully complete. This can reduce build latency for builds with long critical paths by overlapping execution.

**Module**: `engine.runtime.services.speculation`

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│               SpeculationService                            │
│                                                             │
│  ┌──────────────────┐    ┌───────────────────────┐         │
│  │ ProfileGuided    │    │ SpeculativeTask       │         │
│  │ Scheduler        │───▶│ - inputHashes         │         │
│  │ - criticalPath   │    │ - status (atomic)     │         │
│  │ - economics      │    │ - resultHash          │         │
│  └──────────────────┘    └───────────────────────┘         │
│           │                        │                        │
│           ▼                        ▼                        │
│  ┌──────────────────┐    ┌───────────────────────┐         │
│  │ SpeculationPolicy│    │ InputValidator        │         │
│  │ - maxConcurrent  │    │ - hashTracking        │         │
│  │ - minCostMs      │    │ - abortOnChange       │         │
│  │ - confidence     │    └───────────────────────┘         │
│  └──────────────────┘                                      │
└─────────────────────────────────────────────────────────────┘
```

## Policy Presets

| Policy | maxConcurrent | minCostMs | confidenceThreshold | budgetFraction |
|--------|---------------|-----------|---------------------|----------------|
| `conservative()` | 2 | 2000ms | 0.9 | 0.1 |
| `balanced()` | 4 | 500ms | 0.7 | 0.2 |
| `aggressive()` | 8 | 200ms | 0.5 | 0.4 |

### Policy Configuration

```d
struct SpeculationPolicy
{
    size_t maxConcurrent = 4;         // Max concurrent speculative tasks
    size_t minCostMs = 500;           // Min estimated cost to speculate (ms)
    float confidenceThreshold = 0.7f; // Min probability to speculate
    float budgetFraction = 0.2f;      // Fraction of build budget for speculation
    bool enableCriticalPath = true;   // Speculate on critical path
    bool enableFanOut = true;         // Speculate on high-fanout nodes
    bool abortOnInputChange = true;   // Abort speculation if inputs change
}
```

## Usage

### Basic Setup

```d
import engine.runtime.services.speculation;
import engine.economics.estimator : ExecutionHistory;

// Create speculation service from build graph and history
auto speculation = createSpeculationService(graph, history);
speculation.setPolicy(SpeculationPolicy.balanced());
speculation.analyzeGraph(graph);
```

### During Build Loop

```d
// Check for valid speculative result before executing
if (auto result = speculation.getValidResult(targetId))
{
    applyResult(result.get());
    speculation.promote(targetId);
}
else
{
    executeTarget(targetId);
}
```

### Input Change Notification

```d
// When file changes detected (watch mode, etc.)
speculation.notifyInputChanged(filePath, newHash);
// Automatically aborts affected speculations
```

### Predictive Mode

```d
// Enable change prediction for smarter speculation
speculation.initializePredictive(".builder-cache/speculation");

// Record changes for learning
speculation.recordChange(targetId);
speculation.recordNoChange(targetId);
```

## Statistics

The speculation service tracks effectiveness:

| Metric | Description |
|--------|-------------|
| `totalSpeculated` | Total speculation attempts |
| `successful` | Speculations validated and used |
| `aborted` | Speculations cancelled (input changed) |
| `wasted` | Speculations completed but not used |
| `effectiveness` | `successful / totalSpeculated` |
| `roi` | `timeSaved / timeWasted` |

```d
auto stats = speculation.getStats();
writefln("Effectiveness: %.1f%%, ROI: %.2fx", 
    stats.effectiveness * 100, stats.roi);
```

## When to Use

### Effective Scenarios
- Long critical paths (>30 seconds)
- Expensive targets (>500ms each)
- High fan-out dependencies
- Stable input files (low change rate)
- Remote execution (hide latency)

### Ineffective Scenarios
- Short builds (<10 seconds)
- High cache hit rates (>80%)
- Frequently changing inputs
- Cheap targets (<100ms each)
- Resource-constrained environments

## Implementation

Located in `source/engine/runtime/services/speculation/`:

| File | Purpose |
|------|---------|
| `service.d` | Core `SpeculationService` and `ISpeculationService` interface |
| `executor.d` | `SpeculationExecutor` for build loop integration |
| `engine.d` | `SpeculativeEngine` for background async execution |
| `predictor.d` | `ChangePredictor` for probability-based candidate selection |
| `history.d` | `HistoryTracker` for learning from past patterns |
| `package.d` | Module exports |

## See Also

- [Critical Path](critical-path.md) - Build bottleneck analysis
- [Cost Optimization](cost-optimization.md) - Economics-driven decisions
- [Watch Mode](../user-guides/WATCH.md) - Input change detection
- [Performance](performance.md) - Build optimization guide
