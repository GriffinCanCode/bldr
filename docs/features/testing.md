# Test Execution

## Overview

Builder's test framework provides intelligent test execution with:

- **Adaptive Sharding**: Content-based or historical execution time distribution
- **Result Caching**: Skip unchanged tests with hermetic environment verification
- **Flaky Detection**: Bayesian statistical modeling with automatic quarantine
- **Adaptive Retry**: Confidence-based retry counts with exponential backoff
- **Analytics**: Health metrics and performance insights

## Quick Start

### Initialize Configuration

```bash
bldr test --init-config
```

Creates `.buildertest` with defaults:

```json
{
  "parallel": true,
  "shard": true,
  "cache": true,
  "retry": true,
  "detectFlaky": true
}
```

### Run Tests

```bash
# Use default configuration
bldr test

# Override specific settings
bldr test --shards 8 --analytics

# Disable features
bldr test --no-cache --no-retry
```

## Configuration

### Configuration File (`.buildertest`)

```json
{
  "parallel": true,
  "jobs": 0,
  
  "shard": true,
  "shardCount": 0,
  "shardStrategy": "adaptive",
  
  "cache": true,
  "cacheDir": ".builder-cache/tests",
  "cacheMaxAge": 30,
  "hermetic": true,
  
  "retry": true,
  "maxRetries": 3,
  "detectFlaky": true,
  "quarantineFlaky": true,
  "skipQuarantined": false,
  
  "analytics": false,
  "verbose": false,
  "failFast": false,
  
  "junit": false,
  "junitPath": "test-results.xml"
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `parallel` | bool | true | Enable parallel execution |
| `jobs` | int | 0 | Parallel jobs (0 = auto-detect CPU count) |
| `shard` | bool | true | Enable test sharding |
| `shardCount` | int | 0 | Shard count (0 = auto-calculate) |
| `shardStrategy` | string | "adaptive" | Sharding algorithm |
| `cache` | bool | true | Enable result caching |
| `cacheDir` | string | ".builder-cache/tests" | Cache directory |
| `cacheMaxAge` | int | 30 | Cache expiry in days |
| `hermetic` | bool | true | Verify environment for cache validity |
| `retry` | bool | true | Enable automatic retry |
| `maxRetries` | int | 3 | Maximum retry attempts |
| `detectFlaky` | bool | true | Enable flaky test detection |
| `quarantineFlaky` | bool | true | Auto-quarantine flaky tests |
| `skipQuarantined` | bool | false | Skip quarantined tests |
| `analytics` | bool | false | Generate analytics report |
| `verbose` | bool | false | Verbose output |
| `failFast` | bool | false | Stop on first failure |
| `junit` | bool | false | Generate JUnit XML |
| `junitPath` | string | "test-results.xml" | JUnit output path |

### CLI Flags

CLI flags override config file settings:

```bash
bldr test -j 8                    # 8 parallel jobs
bldr test --shards 16             # 16 test shards
bldr test --no-shard              # Disable sharding
bldr test --no-cache              # Disable caching
bldr test --no-retry              # Disable retry
bldr test --analytics             # Generate analytics
bldr test --junit results.xml     # JUnit XML output
bldr test -v                      # Verbose output
```

## Test Sharding

Distributes tests across workers for parallel execution.

### Strategies

| Strategy | Description | Use Case |
|----------|-------------|----------|
| `adaptive` | Uses historical execution times, greedy bin-packing | Default, optimal load balance |
| `content` | BLAKE3-based consistent hashing | Deterministic, distributed caching |
| `round-robin` | Simple modulo distribution | Predictable, simple |
| `load` | Same as adaptive, work-stealing compatible | Dynamic rebalancing |

### Adaptive Algorithm

1. Retrieves historical test execution times (defaults to 1000ms if no history)
2. Sorts tests by duration descending
3. Uses greedy bin-packing: assigns each test to the shard with minimum current load
4. Computes load balance as `(maxDuration - minDuration) / avgDuration`

```d
// Implementation: source/frontend/testframework/sharding/strategy.d
foreach (test; tests.sortByDuration.descending)
{
    minLoadShard = findMinLoadShard(shardLoads);
    assign(test, minLoadShard);
    shardLoads[minLoadShard] += test.duration;
}
```

### Content-Based Sharding

For deterministic distribution across runs:

```json
{
  "shardStrategy": "content"
}
```

Uses BLAKE3 hash of test ID to consistently assign tests to shards. Useful for:
- Distributed caching (same test always on same shard)
- Debugging shard-specific issues
- Reproducible CI runs

## Test Result Caching

Skips tests whose inputs haven't changed.

### Cache Key Components

- Test source code hash (via `FastHash`)
- Dependencies
- Configuration
- Environment hash (if hermetic mode enabled)

### Cache Validation

```d
// Implementation: source/frontend/testframework/caching/cache.d
bool isCached(testId, contentHash, envHash)
{
    entry = entries[testId];
    if (entry.contentHash != contentHash) return false;
    if (config.hermetic && entry.envHash != envHash) return false;
    if (age > config.maxAge) return false;
    return true;
}
```

### Hermetic Verification

When `hermetic: true`, the cache validates that the environment hash matches. The environment hash includes:
- Relevant environment variables
- Tool versions

```d
static string computeEnvHash(envVars, toolVersions)
{
    // Sort env vars for deterministic hash
    keys = envVars.keys.sort();
    envString = keys.map!(k => k ~ "=" ~ envVars[k]).join("\n");
    return FastHash.hashString(envString ~ toolVersions);
}
```

### Cache Invalidation

Cache entries are invalidated when:
- Test source code changes
- Dependencies change
- Environment changes (if hermetic)
- Configuration changes
- Cache age exceeds `cacheMaxAge`

## Flaky Test Detection

Uses Bayesian statistical modeling to identify flaky tests.

### Flakiness Probability

Calculated using a Beta distribution with Jeffrey's prior (0.5, 0.5):

```d
// Implementation: source/frontend/testframework/flaky/detector.d
double probability()
{
    alpha = failures + 0.5;
    beta = (totalRuns - failures) + 0.5;
    return alpha / (alpha + beta);  // Expected value of Beta distribution
}
```

### Confidence Levels

| Level | Probability Range |
|-------|------------------|
| None | < 10% |
| Low | 10-30% |
| Medium | 30-60% |
| High | 60-85% |
| VeryHigh | > 85% |

### Quarantine Criteria

A test is automatically quarantined when:
- VeryHigh confidence (>85% probability)
- Medium+ confidence with ≥2 consecutive failures
- Medium+ confidence with ≥3 failures in <10 runs

### Temporal Pattern Detection

The detector analyzes failure intervals to identify patterns:

| Pattern | Detection |
|---------|-----------|
| TimeOfDay | ~24 hour failure intervals |
| DayOfWeek | ~168 hour failure intervals |
| LoadBased | High variance in failure intervals |

## Adaptive Retry

Retry count scales with flakiness confidence.

### Retry Strategy

| Flakiness Confidence | Max Attempts |
|---------------------|--------------|
| None (stable) | 1 (no retries) |
| Low | 2 |
| Medium | 3 |
| High | 4 |
| VeryHigh | 5 |

### Exponential Backoff

```d
// Implementation: source/frontend/testframework/flaky/retry.d
Duration getRetryDelay(attempt)
{
    multiplier = backoffMultiplier ^ attempt;  // default: 2.0
    delayMs = initialDelay.msecs * multiplier; // default: 100ms
    return min(delayMs, maxDelay);             // default max: 10s
}
```

Example delays with defaults:
- Attempt 1: 100ms
- Attempt 2: 200ms
- Attempt 3: 400ms
- Attempt 4: 800ms
- Attempt 5: 1600ms

## Test Analytics

Generate health metrics and performance insights.

```bash
bldr test --analytics
```

### Health Metrics

| Metric | Calculation |
|--------|-------------|
| Pass rate | passed / total |
| Stability | 1.0 - average flakiness score |
| Performance | cached / total |
| Overall health | (passRate + stability + performance) / 3 |

### Health Grades

| Grade | Overall Health |
|-------|---------------|
| A+ | ≥ 95% |
| A | ≥ 90% |
| B+ | ≥ 85% |
| B | ≥ 80% |
| C | ≥ 70% |
| D | < 70% |

### Performance Insights

- Total, average, median duration
- P95 and P99 duration
- Slow tests (> P95)
- Parallel efficiency
- Recommended shard count (based on duration variance)

### Sample Report

```
═══════════════════════════════════════════
           TEST ANALYTICS REPORT            
═══════════════════════════════════════════

OVERALL HEALTH: A (92.5%)

Test Results:
  Total tests:     248
  Passed:          242 (97.6%)
  Failed:          6
  From cache:      180

Health Metrics:
  Pass rate:       97.6%
  Stability:       94.2%
  Performance:     85.7%
  Flaky tests:     3
  Slow tests:      8

Performance:
  Total duration:  12,450 ms
  Avg duration:    50 ms
  Median:          32 ms
  P95:             180 ms
  P99:             450 ms
  Parallel eff:    78.5%
  Recommended shards: 6

Recommendations:
  • Fix or quarantine 3 flaky tests
  • Optimize 8 slow tests
  • Improve test parallelization
```

## Execution Modes

| Mode | Description |
|------|-------------|
| Sequential | Single-threaded, no parallelism |
| Parallel | Parallel execution using `std.parallelism` |
| Sharded | Explicit sharding with configurable strategy |
| Distributed | Reserved for future distributed execution |

## Best Practices

### Enable All Features

```json
{
  "shard": true,
  "cache": true,
  "retry": true,
  "detectFlaky": true,
  "analytics": true
}
```

### Hermetic Tests

Enable hermetic verification for reliable caching:

```json
{
  "hermetic": true
}
```

Ensure tests:
- Don't depend on external state
- Don't write to global locations
- Clean up after themselves

### CI/CD Configuration

```json
{
  "parallel": true,
  "shard": true,
  "cache": true,
  "skipQuarantined": true,
  "analytics": true,
  "junit": true
}
```

### Quarantine Workflow

1. Run with analytics to identify flaky tests
2. Enable `skipQuarantined` in CI to avoid blocking
3. Fix flaky tests separately
4. Release from quarantine after fixing

## Troubleshooting

### Tests Not Cached

Check:
1. Hermetic mode enabled but environment changed
2. Test sources modified
3. Dependencies changed
4. Cache age exceeded `cacheMaxAge`

Solution:
```bash
# Disable hermetic if environment varies
bldr test --hermetic=false

# Clear cache
rm -rf .builder-cache/tests
```

### Poor Shard Balance

Symptoms: Some workers idle while others busy

Solution:
```json
{
  "shardStrategy": "adaptive",
  "shardCount": 16
}
```

### False Flaky Detection

Symptoms: Stable tests marked as flaky

Cause: Minimum 3 runs required for detection. Increase test runs to build confidence.

## API Reference

### TestExecutor

```d
final class TestExecutor
{
    this(TestExecutionConfig config);
    TestResult[] execute(Target[] targets, WorkspaceConfig ws, BuildServices services);
}
```

### FlakyDetector

```d
final class FlakyDetector
{
    void recordExecution(string testId, bool passed, SysTime timestamp);
    bool isFlaky(string testId);
    bool isQuarantined(string testId);
    FlakyRecord getRecord(string testId);
    FlakyRecord[] getFlakyTests();
}
```

### TestCache

```d
final class TestCache
{
    bool isCached(string testId, string contentHash, string envHash);
    TestResult get(string testId);
    void put(string testId, string contentHash, string envHash, TestResult result);
    void invalidate(string testId);
    void flush();
}
```

## See Also

- [User Guide: Testing](../user-guides/TESTING.md)
- [Hermetic Builds](hermetic.md)
- [Performance](performance.md)
