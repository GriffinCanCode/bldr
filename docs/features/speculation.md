# Speculative Execution

Speculative execution pre-executes build targets on the critical path before their dependencies fully complete. This reduces build latency by 10-30% for builds with long critical paths.

## Overview

Traditional build systems wait for all dependencies to complete before starting a target. Builder's speculative execution breaks this constraint by:

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

## Policy Presets

| Policy | Max Concurrent | Min Cost | Confidence | Use Case |
|--------|---------------|----------|------------|----------|
| Conservative | 2 | 2000ms | 0.9 | Low risk, stable environments |
| Balanced | 4 | 500ms | 0.7 | General use (default) |
| Aggressive | 8 | 200ms | 0.5 | Fast iteration, high compute |

## Usage

### Basic Usage

```d
import engine.runtime.services.speculation;

// Create speculation service
auto speculation = createSpeculationService(graph, history);
speculation.setPolicy(SpeculationPolicy.balanced());
speculation.analyzeGraph(graph);
```

### During Build Loop

```d
// Check for valid speculative result before executing
if (auto result = speculation.getValidResult(targetId))
{
    applyResult(result);
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
// This automatically aborts affected speculations
```

## Statistics

The speculation service tracks:

| Metric | Description |
|--------|-------------|
| totalSpeculated | Total speculation attempts |
| successful | Speculations validated and used |
| aborted | Speculations cancelled (input changed) |
| wasted | Speculations completed but not used |
| effectiveness | successful / totalSpeculated |
| roi | timeSaved / timeWasted |

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

## Performance

| Scenario | Without Speculation | With Speculation | Savings |
|----------|---------------------|------------------|---------|
| 5-min critical path | 5m | 3.5-4.5m | 10-30% |
| High fan-out library | Serial dependents | Parallel start | Variable |

## Configuration

Environment variables:

- `BUILDER_SPECULATION_ENABLED=0|1` - Enable/disable speculation
- `BUILDER_SPECULATION_POLICY=conservative|balanced|aggressive` - Policy preset

## Related Features

- [Critical Path](critical-path.md) - Understand build bottlenecks
- [Cost Optimization](cost-optimization.md) - Economics-driven decisions
- [Watch Mode](watch.md) - Input change detection
- [Performance](performance.md) - Build optimization guide

## Implementation Details

Located in `source/engine/runtime/services/speculation/`:

- `service.d` - Core SpeculationService
- `executor.d` - Build loop integration
- `package.d` - Module exports
- `README.md` - Technical documentation

