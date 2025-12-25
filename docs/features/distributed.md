# Distributed Build System

## Overview

Builder's distributed build system enables parallel build execution across multiple worker machines. The system uses work-stealing for load balancing, consistent hashing for cache-friendly routing, and supports the Remote Execution API (REAPI) for compatibility with external services.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        BUILD CLIENT                          │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐          │
│  │   Graph    │──▶│ Coordinator│──▶│  Transport │          │
│  │  Analysis  │   │  Interface │   │   Layer    │          │
│  └────────────┘   └────────────┘   └──────┬─────┘          │
└────────────────────────────────────────────┼────────────────┘
                                              │
                            ┌─────────────────┴──────────────────┐
                            │                                     │
                            ▼                                     ▼
              ┌──────────────────────┐            ┌──────────────────────┐
              │    COORDINATOR       │            │     ARTIFACT STORE    │
              │  ┌────────────────┐  │            │  (Content-Addressed)  │
              │  │   Scheduler    │  │            │  - BLAKE3 keys       │
              │  │ (Work-Stealing)│  │            │  - Compression       │
              │  └────────────────┘  │            │  - Deduplication     │
              │  ┌────────────────┐  │            └──────────────────────┘
              │  │ Worker Registry│  │                       ▲
              │  └────────────────┘  │                       │
              └──────────┬───────────┘                       │
                         │                                   │
           ┌─────────────┼─────────────┐                    │
           ▼             ▼             ▼                    │
    ┌───────────┐ ┌───────────┐ ┌───────────┐              │
    │  WORKER 1 │ │  WORKER 2 │ │  WORKER N │              │
    │  ┌──────┐ │ │  ┌──────┐ │ │  ┌──────┐ │              │
    │  │Queue │ │ │  │Queue │ │ │  │Queue │ │              │
    │  └──┬───┘ │ │  └──┬───┘ │ │  └──┬───┘ │              │
    │  ┌──▼────┐│ │  ┌──▼────┐│ │  ┌──▼────┐│              │
    │  │Execute││ │  │Execute││ │  │Execute││              │
    │  └───────┘│ │  └───────┘│ │  └───────┘│              │
    └─────┬─────┘ └─────┬─────┘ └─────┬─────┘              │
          └─────────────┴─────────────┴────────────────────┘
```

## Module Structure

The distributed system is in `source/engine/distributed/`:

```
distributed/
├── coordinator/
│   ├── coordinator.d   # Main coordinator
│   ├── scheduler.d     # Action scheduling
│   ├── registry.d      # Worker registration
│   ├── health.d        # Health monitoring
│   ├── hash.d          # Affinity-based routing
│   ├── profile.d       # Profile-guided scheduling
│   ├── recover.d       # Failure recovery
│   └── messages.d      # Message handling
├── worker/
│   ├── worker.d        # Worker main loop
│   ├── steal.d         # Work-stealing engine
│   ├── adaptive.d      # Adaptive threshold tuning
│   ├── queue.d         # Local work queue
│   ├── execution.d     # Action execution
│   ├── sandbox.d       # Execution sandboxing
│   ├── peers.d         # Peer registry
│   └── lifecycle.d     # Lifecycle management
├── protocol/
│   ├── protocol.d      # Core protocol types
│   ├── messages.d      # Message definitions
│   ├── transport.d     # Transport abstraction
│   ├── grpc/           # gRPC/HTTP2 implementation
│   └── reapi_v2/       # REAPI compatibility
├── storage/
│   ├── store.d         # Artifact storage
│   └── artifacts.d     # Artifact management
└── memory/
    ├── pool.d          # Memory pooling
    └── arena.d         # Arena allocation
```

## Coordinator

### Configuration

```d
struct CoordinatorConfig {
    string host = "0.0.0.0";
    ushort port = 9000;
    size_t maxWorkers = 1000;
    Duration workerTimeout = 30.seconds;
    bool enableWorkStealing = true;
    Duration heartbeatInterval = 5.seconds;
    bool enableProfileGuidedScheduling = true;
    bool enableAdaptiveStealThresholds = true;
    bool enableAffinityRouting = true;
}
```

### Profile-Guided Scheduling

When enabled, the coordinator uses historical execution data to prioritize actions:

```d
// Scheduling score formula
score = criticalPathCost × 100 + dependentCount × 10 - depth × 1
```

This schedules expensive actions on the critical path first, maximizing parallelism.

```d
auto coordinator = new Coordinator(graph, config);
// Profile-guided scheduling enabled by default

// Check status
if (coordinator.isProfileGuidedEnabled()) {
    auto stats = coordinator.getProfileScheduler().getStats();
}
```

### Affinity-Based Routing

Workers are assigned actions based on language/toolchain affinity using consistent hashing (Jump Hash). This improves cache hit rates by keeping similar builds on the same workers.

```d
struct AffinityKey {
    string language;   // e.g., "Rust", "D", "TypeScript"
    string toolchain;  // e.g., "rustc-1.75", "dmd", "tsc-5.0"
}

// Affinity extracted from commands:
// "dmd -O main.d"      → AffinityKey("D", "dmd")
// "cargo build"        → AffinityKey("Rust", "")
// "go build ./..."     → AffinityKey("Go", "")
```

Workers assigned to the same affinity build warm caches, reducing build times for repeated builds.

## Work Stealing

### Steal Strategies

Defined in `worker/steal.d`:

| Strategy | Description |
|----------|-------------|
| `Random` | Uniform random victim selection |
| `LeastLoaded` | Target peer with lowest load |
| `MostLoaded` | Target peer with most work (best victim) |
| `PowerOfTwo` | Power-of-two-choices (default) |
| `Adaptive` | Switch strategy based on success rate |

### Configuration

```d
struct StealConfig {
    StealStrategy strategy = StealStrategy.PowerOfTwo;
    Duration stealTimeout = 100.msecs;
    Duration retryBackoff = 50.msecs;
    size_t maxRetries = 3;
    size_t minLocalQueue = 2;
    float stealThreshold = 0.5;
    bool enableAdaptive = false;
    AdaptiveConfig adaptiveConfig;
}
```

### Adaptive Threshold Tuning

When enabled, thresholds auto-tune based on observed metrics:

```d
config.enableAdaptive = true;
config.adaptiveConfig.lowSuccessThreshold = 0.20;   // Below 20%, increase minLocalQueue
config.adaptiveConfig.highLatencyThresholdUs = 50_000;  // Above 50ms, increase timeout
config.adaptiveConfig.evaluationWindow = 50;        // Samples before adjustment

auto engine = new StealEngine(selfId, peers, config);

// Monitor adaptive state
auto state = engine.getAdaptiveState();
writeln("minLocalQueue: ", state.minLocalQueue);
writeln("stealTimeout: ", state.stealTimeout.total!"msecs", "ms");

auto stats = engine.getAdaptiveStats();
writeln("Success rate: ", stats.successRate * 100, "%");
```

**Tuned parameters**:
- `minLocalQueue` — Increases when success rate < 20%, decreases when > 60%
- `stealTimeout` — Scales with observed network latency
- `retryBackoff` — Adjusts alongside timeout
- `stealThreshold` — Adjusts based on network error and timeout rates

### Metrics

```d
struct StealMetrics {
    shared size_t attempts;
    shared size_t successes;
    shared size_t failures;
    shared size_t timeouts;
    shared size_t networkErrors;
    
    float successRate() const;
}
```

## Protocol

### Transport Options

| Transport | Use Case |
|-----------|----------|
| **gRPC/HTTP2** | REAPI backends (BuildBuddy, BuildBarn) |
| **HTTP/1.1** | Builder-native communication |
| **Unix Socket** | Local workers (zero-copy) |

The gRPC implementation (`protocol/grpc/`) is pure D with full HTTP/2 framing and HPACK compression.

### Core Messages

```d
struct ActionRequest {
    ActionId id;
    string command;
    string[string] env;
    InputSpec[] inputs;
    OutputSpec[] outputs;
    Capabilities capabilities;
    Priority priority;
    Duration timeout;
}

struct ActionResult {
    ActionId id;
    ResultStatus status;
    Duration duration;
    ArtifactId[] outputs;
    string stdout;
    string stderr;
    int exitCode;
    ResourceUsage resources;
}

struct StealRequest {
    WorkerId thief;
    WorkerId victim;
    Priority minPriority;
}

struct StealResponse {
    WorkerId victim;
    WorkerId thief;
    bool hasWork;
    ActionRequest action;
}
```

## REAPI Compatibility

The `protocol/reapi_v2/` module provides compatibility with Remote Execution API v2:

### Implemented Services

**Content Addressable Storage (CAS)**:
- `FindMissingBlobs` — Identify which blobs need uploading
- `BatchUpdateBlobs` — Batch blob uploads
- `BatchReadBlobs` — Batch blob downloads
- `ByteStream API` — Streaming for large blobs (>1MB)

**Action Cache**:
- `GetActionResult` — Retrieve cached results
- `UpdateActionResult` — Store results

**Execution**:
- `Execute` — Submit actions
- `WaitExecution` — Long-running operation polling

**Capabilities**:
- Digest functions: BLAKE3, SHA256
- Compression: Identity, Zstd
- Batch size limits

### Usage

```d
import engine.distributed.protocol.grpc;

auto config = GrpcConfig.insecure("buildbuddy:8980");
auto transport = new GrpcTransport(config);

if (transport.connect().isOk) {
    auto result = transport.execute(actionRequest);
}
```

## Worker Sandboxing

Workers execute actions in isolated sandboxes:

```d
struct Capabilities {
    bool network;
    bool write_home;
    bool write_tmp;
    string[] read_paths;
    string[] write_paths;
}
```

On Linux, sandboxing uses namespaces (mount, network, PID) and cgroups for resource limits.

## Artifact Store

Content-addressed storage with tiered caching:

```d
final class TieredArtifactStore : ArtifactStore {
    private LocalCache l1;    // Worker-local (SSD)
    private SharedCache l2;   // LAN-shared (NFS)
    private RemoteCache l3;   // WAN-remote (S3/GCS)
    
    Result!(ubyte[], DistributedError) get(ArtifactId id) {
        // Check L1 → L2 → L3, populate lower tiers on hit
    }
}
```

## Health Monitoring

The `HealthMonitor` tracks worker status:

- **Heartbeat interval**: Configurable (default 5s)
- **Heartbeat timeout**: Workers marked failed after timeout (default 30s)
- **Degradation detection**: High CPU (>95%) or memory (>90%) marks worker degraded
- **Recovery**: Failed workers have their work reassigned

## CLI Usage

### Coordinator

```bash
bldr coordinator \
  --host 0.0.0.0 \
  --port 9000 \
  --max-workers 100 \
  --work-stealing
```

### Worker

```bash
bldr worker \
  --coordinator http://coordinator:9000 \
  --parallelism 8 \
  --sandbox hermetic
```

### Client

```bash
# Distributed build
bldr build --distributed

# Explicit coordinator
bldr build --coordinator http://coordinator:9000

# Mixed local + distributed
bldr build --distributed --local-workers 4
```

## Implementation Status

### Completed

- [x] Protocol definitions and message serialization
- [x] gRPC/HTTP2 transport (pure D implementation)
- [x] REAPI v2 compatibility layer
- [x] Work-stealing protocol and strategies
- [x] Adaptive threshold tuning
- [x] Affinity-based worker routing
- [x] Profile-guided scheduling
- [x] Coordinator and worker scaffolding
- [x] Health monitoring framework
- [x] Peer discovery protocol

### In Progress

- [ ] Full coordinator/worker integration
- [ ] Hermetic sandbox execution
- [ ] End-to-end action execution
- [ ] Artifact upload/download

### Planned

- [ ] Docker images
- [ ] Kubernetes operator
- [ ] Monitoring dashboards
- [ ] Production hardening

## Configuration Reference

### Environment Variables

```bash
# Coordinator
export BUILDER_COORDINATOR_HOST=0.0.0.0
export BUILDER_COORDINATOR_PORT=9000

# Worker
export BUILDER_COORDINATOR_URL=http://coordinator:9000
export BUILDER_WORKER_PARALLELISM=8

# Artifacts
export BUILDER_LOCAL_CACHE=.builder-cache
export BUILDER_SHARED_CACHE_URL=
export BUILDER_REMOTE_CACHE_URL=
```

## See Also

- [Remote Execution](remote-execution.md)
- [Cost Optimization](cost-optimization.md)
- [Caching](caching.md)
- [Hermetic Builds](hermetic.md)
