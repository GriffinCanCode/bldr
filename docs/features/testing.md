# Advanced Test Execution

## Overview

Builder provides enterprise-grade test execution with intelligent features that go beyond traditional build systems like Bazel:

- **Adaptive Test Sharding**: Content-based distribution with historical optimization
- **Multi-Level Caching**: Skip unchanged tests with hermetic environment verification
- **Bayesian Flaky Detection**: Statistical modeling with automatic quarantine
- **Smart Retry Logic**: Confidence-based adaptive retries
- **Test Analytics**: Health metrics and performance insights

## Quick Start

### 1. Initialize Configuration

```bash
bldr test --init-config
```

This creates `.buildertest` with sensible defaults:

```json
{
  "parallel": true,
  "shard": true,
  "cache": true,
  "retry": true,
  "detectFlaky": true
}
```

### 2. Run Tests

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

All test settings can be configured in `.buildertest` (JSON format):

```json
{
  // Execution
  "parallel": true,
  "jobs": 0,  // 0 = auto-detect
  
  // Sharding
  "shard": true,
  "shardCount": 0,  // 0 = optimal
  "shardStrategy": "adaptive",
  
  // Caching
  "cache": true,
  "cacheDir": ".builder-cache/tests",
  "cacheMaxAge": 30,
  "hermetic": true,
  
  // Retry & Flaky Detection
  "retry": true,
  "maxRetries": 3,
  "detectFlaky": true,
  "quarantineFlaky": true,
  "skipQuarantined": false,
  
  // Reporting
  "analytics": false,
  "verbose": false,
  "failFast": false,
  
  // Output
  "junit": false,
  "junitPath": "test-results.xml"
}
```

### Command-Line Flags

CLI flags override config file settings:

```bash
# Execution
bldr test -j 8                    # 8 parallel jobs
bldr test --shards 16             # 16 test shards
bldr test --no-shard              # Disable sharding

# Caching
bldr test --no-cache              # Disable caching
bldr test --no-retry              # Disable retry

# Output
bldr test --analytics             # Generate analytics
bldr test --junit results.xml     # JUnit XML output
bldr test -v                      # Verbose output
```

## Features

### 1. Test Sharding

Distribute tests across workers for optimal parallelism.

**Strategies:**

- **Adaptive** (default): Uses historical execution times for balanced distribution
- **Content**: BLAKE3-based consistent hashing (deterministic)
- **Round-Robin**: Simple distribution
- **Load**: Dynamic work-stealing

**Example:**

```bash
# Auto-detect optimal shards
bldr test

# Specify shard count
bldr test --shards 8

# Change strategy in .buildertest
{
  "shardStrategy": "content"  // deterministic sharding
}
```

**How it works:**
1. Analyzes historical test execution times
2. Uses greedy bin-packing algorithm to balance load
3. Distributes tests across workers
4. Supports work-stealing for dynamic rebalancing

### 2. Test Result Caching

Skip tests whose inputs haven't changed.

**Cache Keys:**
- Test source code (BLAKE3 hash)
- Dependencies
- Configuration
- Environment (hermetic verification)

**Example:**

```bash
# Enable caching (default)
bldr test

# Disable caching
bldr test --no-cache

# Configure in .buildertest
{
  "cache": true,
  "hermetic": true,  // verify environment
  "cacheMaxAge": 30  // cache for 30 days
}
```

**Cache Invalidation:**
- Test code changes
- Dependency changes
- Environment changes (if hermetic)
- Configuration changes
- Cache age exceeds maxAge

### 3. Flaky Test Detection

Bayesian statistical model identifies flaky tests.

**How it works:**
1. Tracks test pass/fail history
2. Calculates flakiness probability using Beta distribution
3. Confidence levels: None, Low, Medium, High, VeryHigh
4. Automatic quarantine for confirmed flaky tests

**Example:**

```bash
# Enable detection (default)
bldr test

# Skip quarantined tests
bldr test --skip-quarantined

# Configure in .buildertest
{
  "detectFlaky": true,
  "quarantineFlaky": true,
  "skipQuarantined": false
}
```

**Quarantine Criteria:**
- VeryHigh confidence (>85% probability)
- Medium+ confidence with multiple recent failures
- Temporal patterns detected

### 4. Smart Retry Logic

Adaptive retries based on flakiness confidence.

**Retry Strategy:**
- Stable tests: 1 attempt (no retries)
- Low flakiness: 2 attempts
- Medium flakiness: 3 attempts  
- High flakiness: 4 attempts
- Very high flakiness: 5 attempts

**Exponential Backoff:**
```
delay = initialDelay * (backoff ^ attempt)
```

**Example:**

```bash
# Enable retry (default)
bldr test

# Disable retry
bldr test --no-retry

# Configure in .buildertest
{
  "retry": true,
  "maxRetries": 3
}
```

### 5. Test Analytics

Comprehensive test suite health analysis.

**Metrics:**
- Overall health score (A+ to D)
- Pass rate
- Stability (inverse of flakiness)
- Performance score
- Flaky test count
- Slow test identification

**Example:**

```bash
# Generate analytics report
bldr test --analytics
```

**Output:**

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

## Comparison with Bazel

| Feature | Builder | Bazel |
|---------|---------|-------|
| **Test Sharding** | ✅ Adaptive (historical) | ✅ Static |
| **Test Caching** | ✅ Multi-level + hermetic | ✅ Basic |
| **Flaky Detection** | ✅ Bayesian inference | ✅ Basic (after N runs) |
| **Retry Logic** | ✅ Adaptive (confidence-based) | ✅ Fixed count |
| **Analytics** | ✅ Comprehensive insights | ❌ None |
| **Work Stealing** | ✅ Dynamic rebalancing | ❌ Static assignment |
| **Configuration** | ✅ .buildertest file | ❌ Command-line only |

### Advantages Over Bazel

1. **Smarter Sharding**: Uses historical execution times, not just file count
2. **Hermetic Caching**: Verifies environment hasn't changed
3. **Statistical Flaky Detection**: Bayesian model vs. simple threshold
4. **Adaptive Retries**: Retry count based on flakiness confidence
5. **Built-in Analytics**: No external tools needed
6. **Config File**: Reusable, version-controlled settings

## Best Practices

### 1. Enable All Features

Let Builder's intelligent systems work for you:

```.buildertest
{
  "shard": true,
  "cache": true,
  "retry": true,
  "detectFlaky": true,
  "analytics": true
}
```

### 2. Use Hermetic Tests

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

### 3. Monitor Analytics

Regular run analytics to identify issues:

```bash
bldr test --analytics
```

Act on recommendations:
- Fix or quarantine flaky tests
- Optimize slow tests (P95+)
- Adjust shard count if efficiency < 70%

### 4. Version Control Config

Commit `.buildertest` to share settings:

```bash
git add .buildertest
git commit -m "Add test configuration"
```

### 5. CI/CD Integration

Optimize for CI environments:

```json
{
  "parallel": true,
  "shard": true,
  "cache": true,
  "skipQuarantined": true,  // Skip known flaky tests
  "analytics": true,
  "junit": true
}
```

## Advanced Usage

### Custom Shard Strategy

For deterministic sharding (same tests always go to same shard):

```json
{
  "shardStrategy": "content"
}
```

Useful for:
- Distributed caching
- Shard-specific resource allocation
- Debugging shard-specific issues

### Quarantine Workflow

1. **Detect flaky tests:**
```bash
bldr test --analytics
```

2. **Skip quarantined in CI:**
```json
{
  "skipQuarantined": true
}
```

3. **Fix and release:**
```bash
# Run only quarantined tests
bldr query 'attr(quarantined, 1, tests(//...))'
```

### Performance Tuning

Experiment with shard count:

```bash
# Try different shard counts
bldr test --shards 4
bldr test --shards 8
bldr test --shards 16

# Check analytics for optimal setting
bldr test --shards 8 --analytics
```

Look for:
- Parallel efficiency > 70%
- Low load balance score
- Minimal idle time

## Troubleshooting

### Tests Not Cached

**Check:**
1. Hermetic mode enabled but environment changed
2. Test sources modified
3. Dependencies changed
4. Cache age exceeded

**Solution:**
```bash
# Disable hermetic if environment varies
bldr test --hermetic=false

# Clear cache
rm -rf .builder-cache/tests
```

### False Flaky Detection

**Symptoms:** Stable tests marked as flaky

**Solution:**
Increase detection threshold in custom code or run more iterations to build confidence.

### Poor Shard Balance

**Symptoms:** Some workers idle while others busy

**Solution:**
```bash
# Use adaptive strategy
# In .buildertest:
{
  "shardStrategy": "adaptive"
}

# Increase shard count
bldr test --shards 16
```

## API Reference

See [Test API Documentation](../api/testing.md) for programmatic usage.

## Migration Guide

### From Basic Test Command

Old:
```bash
bldr test --verbose --fail-fast
```

New:
```bash
bldr test --init-config
bldr test -v --fail-fast
```

### From Bazel

Old (`BUILD.bazel`):
```python
test(
    name = "my_test",
    shard_count = 4,
)
```

New (`.buildertest`):
```json
{
  "shard": true,
  "shardCount": 4,
  "shardStrategy": "adaptive"
}
```

Then:
```bash
bldr test
```

## Future Enhancements

Planned features:
- Distributed test execution
- Test impact analysis
- Coverage-guided test selection
- ML-based test prioritization
- Real-time test result streaming

