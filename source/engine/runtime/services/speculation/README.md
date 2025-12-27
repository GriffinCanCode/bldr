# Speculative Execution for Large Monorepo Optimization

This module implements **probability-based speculative execution** - a differentiating feature for large monorepos that predicts and pre-builds targets likely to be needed based on historical change patterns.

## Why Speculative Execution?

Traditional build systems wait for explicit dependencies to complete before starting work. In large monorepos with thousands of targets, this creates bottlenecks on the critical path.

Speculative execution breaks this constraint by:
1. **Predicting** which targets are likely to need rebuilding
2. **Pre-building** those targets on background workers
3. **Validating** results before use (abort if inputs changed)
4. **Learning** from past builds to improve predictions

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         SpeculationExecutor                              │
│                                                                          │
│  ┌────────────────────┐    ┌────────────────────┐    ┌───────────────┐ │
│  │ SpeculationService │───▶│ SpeculativeEngine  │───▶│  Background   │ │
│  │   - Policy         │    │   - Task Queue     │    │   Workers     │ │
│  │   - Candidates     │    │   - Results Cache  │    │   (N threads) │ │
│  │   - Abort logic    │    │   - Input Tracking │    └───────────────┘ │
│  └─────────┬──────────┘    └─────────┬──────────┘                      │
│            │                         │                                  │
│  ┌─────────▼──────────┐    ┌─────────▼──────────┐                      │
│  │  ChangePredictor   │    │   HistoryTracker   │                      │
│  │  ┌───────────────┐ │    │  ┌───────────────┐ │                      │
│  │  │Bayesian Model │ │    │  │ Persistence   │ │                      │
│  │  │ - Prior       │ │    │  │ - JSON store  │ │                      │
│  │  │ - Likelihood  │ │    │  │ - Sessions    │ │                      │
│  │  │ - Posterior   │ │    │  │ - Accuracy    │ │                      │
│  │  └───────────────┘ │    │  └───────────────┘ │                      │
│  │  ┌───────────────┐ │    │  ┌───────────────┐ │                      │
│  │  │Co-change      │ │    │  │ Correlations  │ │                      │
│  │  │ Matrix        │ │◀───│──│ Analysis      │ │                      │
│  │  └───────────────┘ │    │  └───────────────┘ │                      │
│  │  ┌───────────────┐ │    │                    │                      │
│  │  │Time Patterns  │ │    │                    │                      │
│  │  │ (24h buckets) │ │    │                    │                      │
│  │  └───────────────┘ │    │                    │                      │
│  └────────────────────┘    └────────────────────┘                      │
└─────────────────────────────────────────────────────────────────────────┘
```

## Components

### ChangePredictor (`predictor.d`)

Bayesian model that predicts probability of targets needing rebuild.

**Signals used:**
- **Historical frequency**: How often has this target needed rebuilding?
- **Recency decay**: Recent changes are more predictive (exponential decay)
- **Co-change correlation**: If file A changes, file B often needs rebuild
- **Time patterns**: Adapt to developer schedules (24-hour buckets)

**Bayesian update formula:**
```
P(rebuild|signal) ∝ P(signal|rebuild) × P(rebuild)
```

### HistoryTracker (`history.d`)

Persists learned patterns between build sessions.

**Tracked data:**
- Per-target change statistics (EWMA smoothed)
- Co-change relationships (sparse matrix)
- Time-of-day patterns (24 hourly buckets)
- Prediction accuracy (for feedback)

**Persistence:** JSON file in `.builder-cache/speculation/history.json`

### PredictorWarmer (`warmer.d`)

Pre-warms the Bayesian predictor at startup from persisted state.

**Features:**
- Async background loading (non-blocking startup)
- Pre-computes predictions for all known targets
- O(1) prediction lookups after warmup
- Warmup status monitoring

**Usage:**
```d
import engine.runtime.services.speculation;

// Option 1: Direct warmer usage
auto warmer = createWarmedPredictor(".builder-cache/speculation");
warmer.awaitReady(500.msecs);

// Get pre-computed predictions
auto top10 = warmer.topPredictions(10);
auto pred = warmer.getCachedPrediction(targetId);

// Option 2: Via SpeculationService
auto service = new SpeculationService(estimator, graph);
service.initializeWithWarmer();

// Non-blocking warmup check
if (service.isWarmed) {
    auto predictions = service.getTopWarmedPredictions(100);
}
```

### SpeculativeEngine (`engine.d`)

Background execution engine with dedicated worker threads.

**Features:**
- Priority queue based on prediction confidence
- Input hash tracking for validation
- Automatic abort on input changes
- Result caching until consumed

### SpeculationService (`service.d`)

Integration point with the build system.

**Candidate selection combines:**
1. Critical path cost (from economics module)
2. Fan-out score (nodes with many dependents)
3. Change probability (from predictor)
4. Cache hit probability (avoid redundant work)

## Usage

### Basic (Critical Path Only)

```d
import engine.runtime.services.speculation;

auto executor = createSpeculationExecutor(graph, scheduling);
executor.beginSpeculation();

// Build loop
foreach (node; readyNodes)
{
    if (auto result = executor.tryGetSpeculativeResult(node.id))
        applyResult(result.get());
    else
        buildNormally(node);
}

executor.shutdown();
```

### Predictive Mode (Recommended)

```d
import engine.runtime.services.speculation;

// Create with predictive engine
auto executor = createPredictiveSpeculationExecutor(
    graph, 
    scheduling,
    SpeculationPolicy.aggressive(),
    ".builder-cache/speculation"
);

// Set executor for background workers
executor.setNodeExecutor((node) @system {
    return buildAndReturnHash(node);
});

// Start background speculation
executor.startEngine();
executor.beginSpeculation();

// Build loop with speculation
foreach (node; topologicalOrder)
{
    executor.notifyBuildStarting(node.id);
    
    if (auto spec = executor.tryGetSpeculativeResult(node.id))
    {
        // Use speculative result
        applyResult(spec.get());
        continue;
    }
    
    // Build normally
    buildNormally(node);
}

// Saves learned patterns for next session
executor.shutdown();
```

### Watch Mode Integration

```d
// In watch mode, record file changes for learning
watchService.onFileChanged = (path) {
    auto affectedTargets = findAffectedTargets(path);
    foreach (target; affectedTargets)
        speculation.recordChange(target);
};

// Record co-change relationships
watchService.onMultipleFilesChanged = (paths) {
    auto targets = paths.map!(p => findTarget(p)).array;
    foreach (i, source; targets)
        foreach (target; targets[i+1 .. $])
            speculation.recordCoChange(source, target);
};
```

## Policies

### Conservative
```d
auto policy = SpeculationPolicy.conservative();
// maxConcurrent = 2
// minCostMs = 2000 (only expensive targets)
// confidenceThreshold = 0.9 (high confidence required)
// budgetFraction = 0.1 (10% of build budget)
```

### Balanced (Default)
```d
auto policy = SpeculationPolicy.balanced();
// maxConcurrent = 4
// minCostMs = 500
// confidenceThreshold = 0.7
// budgetFraction = 0.2 (20% of build budget)
```

### Aggressive
```d
auto policy = SpeculationPolicy.aggressive();
// maxConcurrent = 8
// minCostMs = 200 (even cheap targets)
// confidenceThreshold = 0.5 (lower threshold)
// budgetFraction = 0.4 (40% of build budget)
```

## Performance Characteristics

| Scenario | Expected Improvement |
|----------|---------------------|
| Large monorepo (1000+ targets) | 20-40% faster incremental |
| High change frequency | 30-50% faster critical path |
| Predictable patterns | Better accuracy over time |
| Cold start (no history) | Falls back to critical path |
| Random changes | Minimal benefit |

### Startup Performance (with Pre-warming)

| Operation | Cold Start | Warm Start |
|-----------|------------|------------|
| Load persisted state | N/A | ~5-50ms |
| Pre-compute predictions | N/A | ~10-100ms |
| First prediction lookup | ~50ms | <1ms (O(1)) |
| Warmup total | N/A | ~15-150ms |

Pre-warming runs asynchronously and doesn't block application startup. The predictor is fully functional before warmup completes - it falls back to on-demand computation until the cache is populated.

## Configuration

Environment variables:

| Variable | Values | Description |
|----------|--------|-------------|
| `BUILDER_SPECULATION_ENABLED` | `0`, `1` | Enable/disable speculation |
| `BUILDER_SPECULATION_POLICY` | `conservative`, `balanced`, `aggressive` | Policy preset |
| `BUILDER_SPECULATION_WORKERS` | `1-16` | Background worker count |
| `BUILDER_SPECULATION_CACHE` | path | Cache directory |

## Monitoring

### Statistics

```d
auto stats = executor.getStats();
writefln("Speculation: %d total, %d hits (%.1f%%), saved %dms",
    stats.totalSpeculated,
    stats.hits,
    stats.hitRate * 100,
    stats.timeSaved.total!"msecs"
);

// Predictor accuracy
auto predStats = predictor.getStats();
writefln("Predictor: %d targets, %.1f%% accuracy",
    predStats.trackedTargets,
    predStats.averageAccuracy * 100
);
```

### Logging

Speculation logs at `debugLog` level. Enable with:
```bash
BUILDER_LOG_LEVEL=debug bldr build
```

## Implementation Details

### Input Validation

Before using speculative results:
1. Snapshot input hashes at speculation start
2. Track file changes during speculation
3. Validate hashes before using result
4. Discard if any input changed

### Abort Semantics

When `notifyInputChanged` is called:
1. Check all in-progress speculations
2. Mark affected tasks as aborted
3. Remove from results cache
4. Don't cache aborted results

### Thread Safety

- `SpeculationService`: Protected by mutex
- `SpeculativeEngine`: Lock-free queues + mutex for results
- `ChangePredictor`: Protected by mutex
- Atomic counters for statistics

## Testing

```bash
# Run unit tests
cd source/engine/runtime/services/speculation
dmd -unittest -run predictor.d
dmd -unittest -run history.d
dmd -unittest -run engine.d
dmd -unittest -run service.d
dmd -unittest -run executor.d

# Integration tests
cd tests/unit/services
dmd -unittest -I ../../../source speculation_test.d
```

## See Also

- `engine.economics` - Cost estimation for candidate scoring
- `engine.distributed.coordinator.profile` - Critical path analysis
- `engine.caching.incremental` - Dependency tracking for validation
- `engine.runtime.watchmode` - File change detection integration
