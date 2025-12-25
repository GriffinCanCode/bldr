# Circuit Breakers and Rate Limiting

**Status:** Implemented  
**Module:** `infrastructure.resilience`

## Overview

Builder includes circuit breakers and rate limiting to prevent cascading failures and resource exhaustion in distributed builds. These mechanisms are integrated at the transport layer for remote cache and distributed execution.

## Circuit Breakers

Circuit breakers detect unhealthy services and temporarily block requests to allow recovery:

```
    ┌────────────┐
    │   CLOSED   │ ← Normal operation
    │ (allowing) │
    └─────┬──────┘
          │ failures exceed threshold
          ↓
    ┌────────────┐
    │    OPEN    │ ← Failing, reject requests immediately
    │ (blocking) │
    └─────┬──────┘
          │ timeout elapsed
          ↓
    ┌────────────┐
    │ HALF_OPEN  │ ← Testing recovery
    │  (testing) │
    └─────┬──────┘
          │ recovery confirmed
          └───→ back to CLOSED
```

### Configuration

```d
struct BreakerConfig {
    float failureThreshold = 0.5;        // 50% failure rate opens circuit
    size_t minRequests = 10;             // Min requests before considering rate
    Duration windowSize = 30.seconds;    // Rolling window for tracking
    Duration timeout = 60.seconds;       // Time before testing recovery
    size_t halfOpenMaxRequests = 3;      // Test requests in HALF_OPEN
    float successThreshold = 0.8;        // 80% success to close circuit
    bool onlyCountNetworkErrors = true;  // Filter error types
}
```

### Usage

```d
import infrastructure.resilience.core.breaker;

auto breaker = new CircuitBreaker("my-service", config);

auto result = breaker.execute!Data(() {
    return Ok!Data(fetchFromService());
});

// Check state
auto state = breaker.getState();  // Closed, Open, or HalfOpen

// Get statistics
size_t total, failures;
float rate;
breaker.getStatistics(total, failures, rate);
```

## Rate Limiting

Token bucket rate limiter with priority support and adaptive control:

```
Token Bucket:
┌─────────────────┐
│ ●●●●●●●○○○      │ ← tokens (● = available, ○ = consumed)
│                 │
│ refill rate:    │
│ 100 tokens/sec  │
│                 │
│ burst capacity: │
│ 200 tokens max  │
└─────────────────┘

Request arrives → consume 1 token
No tokens? → wait or reject
```

### Configuration

```d
struct LimiterConfig {
    size_t ratePerSecond = 100;      // Base rate limit
    size_t burstCapacity = 200;      // Max tokens
    bool adaptive = true;            // Enable adaptive adjustment
    float minRate = 0.1;             // Min rate when throttled (fraction)
    float maxRate = 1.5;             // Max rate when healthy (fraction)
    float adjustmentSpeed = 0.05;    // Rate adjustment speed
    ubyte priorityThreshold = 200;   // High priority bypass threshold
}
```

### Priority Levels

```d
enum Priority : ubyte {
    Low = 0,       // Best effort, queued last
    Normal = 100,  // Standard operations
    High = 200,    // Important operations, bypass queue
    Critical = 255 // Emergency operations, highest preference
}
```

### Usage

```d
import infrastructure.resilience.core.limiter;

auto limiter = new RateLimiter("my-service", config);

// Acquire with priority
auto result = limiter.acquire(Priority.Normal, 10.seconds);

// Non-blocking check
bool acquired = limiter.tryAcquire(Priority.High);

// Execute with rate limiting
auto opResult = limiter.execute!Data(() => operation(), Priority.Normal, 10.seconds);

// Adaptive rate adjustment
limiter.adjustRate(0.8);  // 80% health → increase rate
limiter.adjustRate(0.3);  // 30% health → decrease rate
```

## Policy Presets

### Critical Services

For authentication, configuration, critical infrastructure:

```d
auto policy = PolicyPresets.critical();
```

- Failure threshold: 30%
- Min requests: 5
- Window: 15 seconds
- Timeout: 30 seconds
- Rate: 50 rps (burst: 75)

### Standard Services

For general services, most use cases:

```d
auto policy = PolicyPresets.standard();
```

- Failure threshold: 50%
- Min requests: 10
- Window: 30 seconds
- Timeout: 60 seconds
- Rate: 100 rps (burst: 200)

### Network Services

For remote cache, artifact stores, external services:

```d
auto policy = PolicyPresets.network();
```

- Failure threshold: 40%
- Only network errors counted
- Window: 20 seconds
- Timeout: 45 seconds
- Rate: 150 rps (burst: 300)

### High Throughput

For worker coordination, internal high-traffic services:

```d
auto policy = PolicyPresets.highThroughput();
```

- Failure threshold: 60%
- Min requests: 15
- Window: 45 seconds
- Timeout: 60 seconds
- Rate: 500 rps (burst: 1000)

### Relaxed

For monitoring, telemetry, best-effort services:

```d
auto policy = PolicyPresets.relaxed();
```

- Failure threshold: 70%
- Min requests: 20
- Window: 60 seconds
- Timeout: 120 seconds
- Rate: 200 rps (burst: 500)

## Resilience Service

Coordinates circuit breakers and rate limiters per endpoint:

```d
import infrastructure.resilience.coordination.network;

auto resilience = new NetworkResilience(PolicyPresets.network());

// Register endpoint with custom policy
resilience.registerEndpoint("cache-server", PolicyPresets.network());

// Execute with full resilience
auto result = resilience.execute!Data(
    "cache-server",
    () => fetchFromCache(),
    Priority.Normal,
    10.seconds
);

// Adjust rate based on health
resilience.adjustRate("cache-server", 0.8);
```

### Per-Endpoint Isolation

Each endpoint gets its own circuit breaker and rate limiter:

```
cache-server-1:
  Circuit: CLOSED
  Rate: 150 rps

cache-server-2:
  Circuit: OPEN  ← isolated failure
  Rate: 30 rps (throttled)

coordinator:
  Circuit: CLOSED
  Rate: 500 rps
```

Failure in one service doesn't affect others.

## Custom Policies

Build policies with the builder pattern:

```d
import infrastructure.resilience.policies.policy;

auto policy = PolicyBuilder.create()
    .withBreakerThreshold(0.35)
    .withBreakerWindow(25.seconds)
    .withBreakerTimeout(45.seconds)
    .withRateLimit(175)
    .withBurstCapacity(350)
    .adaptive(true)
    .build();

resilience.registerEndpoint("my-service", policy);
```

## Adaptive Rate Control

Rate automatically adjusts based on health:

```d
// Health score: 0.0 (unhealthy) to 1.0 (healthy)
resilience.adjustRate(endpoint, healthScore);
```

Effect (with default config):
- Health 1.0 → 150% of nominal rate
- Health 0.5 → ~80% of nominal rate
- Health 0.0 → 10% of nominal rate

**Automatic adjustment from circuit breaker state:**
- Circuit CLOSED → 100% rate
- Circuit HALF_OPEN → 50% rate
- Circuit OPEN → 20% rate

## Metrics

### Rate Limiter Metrics

```d
struct LimiterMetrics {
    size_t totalRequests;
    size_t accepted;
    size_t rejected;
    size_t highPriorityAccepted;
    Duration totalWaitTime;
    float currentRate;
    float avgWaitTimeMs;
    
    float acceptanceRate();  // accepted / totalRequests
    float rejectionRate();   // rejected / totalRequests
}

auto metrics = limiter.getMetrics();
```

### Circuit Breaker Statistics

```d
size_t total, failures;
float rate;
breaker.getStatistics(total, failures, rate);

writeln("Total requests: ", total);
writeln("Failures: ", failures);
writeln("Failure rate: ", rate * 100, "%");
```

## Error Handling

Circuit breaker returns errors when open:

```d
auto result = breaker.execute!Data(() => operation());

if (result.isErr) {
    auto error = result.unwrapErr();
    // Check if circuit breaker blocked the request
    if (error.code() == ErrorCode.NetworkError) {
        writeln("Circuit open, request blocked");
    }
}
```

Rate limiter returns errors when limit exceeded:

```d
auto result = limiter.acquire(Priority.Normal, Duration.zero);

if (result.isErr) {
    writeln("Rate limit exceeded");
}
```

## Performance

### Overhead

Per-request overhead:
- Circuit breaker check: ~50ns
- Rate limiter check: ~100ns
- Rolling window update: ~200ns
- **Total: ~350ns**

For typical network calls (1-100ms), this is negligible overhead.

### Memory

Per endpoint:
- Circuit breaker: ~2KB (rolling window buckets)
- Rate limiter: ~1KB (token bucket + metrics)
- **Total: ~3KB per endpoint**

## Troubleshooting

### Circuit keeps opening

**Cause:** Service is genuinely failing or threshold too sensitive.

**Diagnosis:**
```d
size_t total, failures;
float rate;
breaker.getStatistics(total, failures, rate);
writeln("Failure rate: ", rate * 100, "%");
```

**Solutions:**
1. Check if service is actually failing
2. Increase failure threshold if false positives
3. Increase minimum requests to reduce noise
4. Increase window size for smoother tracking

### Rate limiting too aggressive

**Cause:** Rate limit too low or burst capacity insufficient.

**Diagnosis:**
```d
auto metrics = limiter.getMetrics();
writeln("Rejection rate: ", metrics.rejectionRate() * 100, "%");
writeln("Avg wait: ", metrics.avgWaitTimeMs, "ms");
```

**Solutions:**
1. Increase rate per second
2. Increase burst capacity
3. Check health scores (may be throttled)
4. Use higher priority for critical requests

## See Also

- [Distributed Builds](./distributed.md)
- [Remote Execution](./remote-execution.md)
- [Remote Cache](./remotecache.md)
