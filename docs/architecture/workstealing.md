# Work-Stealing Implementation

**Status:** Implemented  
**Version:** 1.0

---

## Overview

Builder's distributed build system implements work-stealing for load balancing across workers. Workers autonomously steal work from peers when idle.

---

## Architecture

```
source/engine/distributed/
├── worker/
│   ├── worker.d       # Main worker loop
│   ├── steal.d        # StealEngine, StealConfig, StealStrategy
│   ├── adaptive.d     # AdaptiveThresholds with EWMA
│   ├── peers.d        # PeerRegistry for peer discovery
│   ├── queue.d        # DistributedQueue
│   └── lifecycle.d    # WorkerLifecycle, WorkerConfig
├── memory/
│   ├── arena.d        # Arena allocator
│   ├── pool.d         # Object pooling
│   └── buffer.d       # Buffer pooling
└── metrics/
    └── steal.d        # StealTelemetry
```

---

## Worker Loop

```d
// worker.d - mainLoop()
while (lifecycle.isRunning()) {
    // 1. Try local work first
    if (auto action = localQueue.pop()) {
        executeAction(action);
        continue;
    }
    
    // 2. Request work from coordinator
    if (auto action = communication.requestWork(id, transport)) {
        executeAction(action);
        continue;
    }
    
    // 3. Try stealing from peers
    if (config.enableWorkStealing && stealEngine !is null) {
        auto minLocal = stealEngine.getEffectiveMinLocalQueue();
        if (localQueue.size() < minLocal) {
            auto action = stealEngine.steal(transport);
            if (action !is null) {
                executeAction(action);
                continue;
            }
        }
    }
    
    // 4. Backoff
    lifecycle.backoff(++consecutiveIdle);
}
```

---

## Steal Strategies

```d
enum StealStrategy {
    Random,         // Random victim selection
    LeastLoaded,    // Target least loaded peer
    MostLoaded,     // Target most loaded peer (best victim)
    PowerOfTwo,     // Sample 2 random peers, pick best (default)
    Adaptive        // Dynamically adjust based on success rate
}
```

### Power-of-Two-Choices (Default)

1. Sample 2 random peers from alive pool
2. Calculate steal score: `score = queueDepth * 10.0 - loadFactor * 5.0`
3. Select peer with higher score
4. Reject if peer has <4 items

**Benefits:**
- O(1) selection time
- Near-optimal load balancing
- Low coordination overhead

---

## Configuration

### StealConfig

```d
struct StealConfig {
    StealStrategy strategy = StealStrategy.PowerOfTwo;
    Duration stealTimeout = 100.msecs;      // Max time for steal attempt
    Duration retryBackoff = 50.msecs;       // Backoff between retries
    size_t maxRetries = 3;                  // Max steal attempts
    size_t minLocalQueue = 2;               // Min local work before stealing
    float stealThreshold = 0.5;             // Load threshold to trigger steal
    bool enableAdaptive = false;            // Enable adaptive tuning
    AdaptiveConfig adaptiveConfig;          // Adaptive tuning settings
}
```

### WorkerConfig

```d
struct WorkerConfig {
    string coordinatorUrl;
    size_t maxConcurrentActions = 8;
    size_t localQueueSize = 256;
    bool enableSandboxing = true;
    bool enableWorkStealing = true;         // Default: true
    Duration heartbeatInterval = 5.seconds;
    Duration peerAnnounceInterval = 10.seconds;
    StealConfig stealConfig;                // Adaptive enabled by default
}
```

---

## Adaptive Threshold Tuning

When `enableAdaptive = true`, thresholds auto-adjust based on observed metrics.

### AdaptiveConfig

```d
struct AdaptiveConfig {
    float alpha = 0.15;                    // EWMA learning rate
    float lowSuccessThreshold = 0.20;      // Below this: increase minLocalQueue
    float highSuccessThreshold = 0.60;     // Above this: decrease minLocalQueue
    long highLatencyThresholdUs = 50_000;  // Above this: increase timeout
    long lowLatencyThresholdUs = 10_000;   // Below this: decrease timeout
    size_t evaluationWindow = 50;          // Samples before evaluation
    Duration adjustmentCooldown = 5.seconds;  // Prevent oscillation
    
    // Bounds
    size_t minLocalQueueLower = 1;
    size_t minLocalQueueUpper = 16;
    float stealThresholdLower = 0.2;
    float stealThresholdUpper = 0.8;
    Duration stealTimeoutLower = 25.msecs;
    Duration stealTimeoutUpper = 500.msecs;
}
```

### Adaptive Behavior

| Metric | Threshold | Action |
|--------|-----------|--------|
| Success rate < 20% | Low | Increase `minLocalQueue` |
| Success rate > 60% | High | Decrease `minLocalQueue` |
| Latency > 50ms | High | Increase `stealTimeout` |
| Latency < 10ms | Low | Decrease `stealTimeout` |
| Error rate > 30% | High | Increase `stealThreshold` |
| Error rate < 5% | Low | Decrease `stealThreshold` |

### ThresholdState

```d
struct ThresholdState {
    size_t minLocalQueue = 2;
    float stealThreshold = 0.5;
    Duration stealTimeout = 100.msecs;
    Duration retryBackoff = 50.msecs;
}
```

### EWMA Statistics

Metrics are tracked using Exponentially Weighted Moving Average:

```d
struct EwmaStat {
    float value = 0;
    float variance = 0;
    size_t samples = 0;
    
    void update(float observation, float alpha);
    float stddev() const;
}
```

### AdaptiveStats

```d
struct AdaptiveStats {
    float successRate;
    float successStddev;
    float avgLatencyUs;
    float latencyStddev;
    float networkErrorRate;
    float timeoutRate;
    size_t totalSamples;
    size_t samplesSinceAdjust;
}
```

---

## Usage

### Basic Configuration

```d
WorkerConfig config;
config.enableWorkStealing = true;
config.stealConfig.strategy = StealStrategy.PowerOfTwo;

auto worker = new Worker(config);
```

### With Adaptive Tuning

```d
WorkerConfig config;
config.stealConfig.enableAdaptive = true;
config.stealConfig.adaptiveConfig.alpha = 0.15;
config.stealConfig.adaptiveConfig.evaluationWindow = 30;

auto worker = new Worker(config);
```

### Monitoring

```d
// Get adaptive state
auto state = stealEngine.getAdaptiveState();
writeln("Current minLocalQueue: ", state.minLocalQueue);

// Get statistics
auto stats = stealEngine.getAdaptiveStats();
writeln("Success rate: ", stats.successRate * 100, "%");
writeln("Avg latency: ", stats.avgLatencyUs / 1000, "ms");
```

---

## Telemetry

### StealTelemetry

```d
auto telemetry = new StealTelemetry();

// Record attempts
telemetry.recordAttempt(victimId, latency, success);
telemetry.recordTimeout(victimId);
telemetry.recordNetworkError(victimId);
telemetry.recordRejection(victimId);

// Get statistics
auto stats = telemetry.getStats();
writeln("Success rate: ", stats.successRate * 100, "%");
writeln("Avg latency: ", stats.avgLatencyUs / 1000.0, "ms");
```

### Metrics

| Metric | Description |
|--------|-------------|
| `attempts` | Total steal attempts |
| `successes` | Successful steals |
| `failures` | Failed steals |
| `timeouts` | Timeout count |
| `networkErrors` | Network error count |
| `rejections` | Rejection count |
| `avgLatencyUs` | Average latency |

---

## Memory Optimizations

### Arena Allocator

Fast batch allocation for temporary data:

```d
auto arena = new Arena(64 * 1024);  // 64KB arena
auto ptr = arena.make!ActionRequest(...);
auto buffer = arena.makeArray!ubyte(4096);
arena.reset();  // Free all at once
```

### Object Pooling

Reuse expensive allocations:

```d
auto pool = new ObjectPool!ActionRequest(256);
auto req = pool.acquire();
// Use request...
pool.release(req);
```

### Buffer Pooling

Specialized for network I/O:

```d
auto bufferPool = new BufferPool(64 * 1024, 128);
bufferPool.preallocate(16);
auto buffer = bufferPool.acquire();
bufferPool.release(buffer);
```

---

## Tuning Guidelines

### Low Latency Network (<1ms)

```d
config.stealTimeout = 50.msecs;
config.retryBackoff = 20.msecs;
config.maxRetries = 5;
```

### High Latency Network (>10ms)

```d
config.stealTimeout = 500.msecs;
config.retryBackoff = 100.msecs;
config.maxRetries = 2;
```

### CPU-Bound Tasks

```d
config.minLocalQueue = 4;
config.stealThreshold = 0.3;  // Steal earlier
```

### I/O-Bound Tasks

```d
config.minLocalQueue = 1;
config.stealThreshold = 0.7;  // Steal later
```

---

## Troubleshooting

### High Steal Failures (Success rate <30%)

**Causes:**
- Network issues
- Peers overloaded
- Poor victim selection

**Solutions:**
1. Enable adaptive tuning
2. Switch to Adaptive strategy
3. Check network latency
4. Increase worker capacity

### High Latency (>5ms)

**Causes:**
- Network congestion
- Coordinator bottleneck
- Lock contention

**Solutions:**
1. Use P2P steal (bypass coordinator)
2. Increase `retryBackoff`
3. Reduce concurrent steals

---

## Performance

| Workers | Speedup | Efficiency | Steal Rate |
|---------|---------|------------|------------|
| 10 | ~9x | 92% | 5% |
| 50 | ~44x | 88% | 12% |
| 100 | ~85x | 85% | 18% |

### Overhead

| Component | Overhead |
|-----------|----------|
| Peer discovery | 10s interval, <2 KB/msg |
| Steal attempt | <100μs typical |
| Memory | ~5 MB per worker |
| CPU | <1% idle, <5% stealing |

---

## Related Documentation

- [StealEngine](../../source/engine/distributed/worker/steal.d)
- [AdaptiveThresholds](../../source/engine/distributed/worker/adaptive.d)
- [PeerRegistry](../../source/engine/distributed/worker/peers.d)
- [Distributed README](../../source/engine/distributed/README.md)
