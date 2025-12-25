# Distributed System Unit Tests

Comprehensive unit tests for Builder's distributed build system components.

## Test Files

### `protocol.d` - Protocol Types Tests
Tests for core protocol types and serialization:
- **MessageId**: Generation, equality, string conversion
- **WorkerId**: Creation, broadcast sentinel, string conversion
- **ActionId**: Creation, equality, hashing, hex string conversion
- **WorkerState**: Enum values and state machine
- **ResultStatus**: Result type enum values
- **Priority**: Priority levels and ordering
- **Capabilities**: Default values, custom configuration, serialization/deserialization
- **Compression**: Compression algorithm enum

**Test Count**: 19 unit tests

### `registry.d` - Coordinator Registry Tests
Tests for worker pool management on coordinator side:
- **Registration**: Worker registration with unique IDs, unregistration
- **Worker Info**: Get worker information, handle non-existent workers
- **Heartbeat**: Heartbeat updates, timeout detection, keep-alive behavior
- **Selection**: Worker selection (single, least-loaded, exclude unhealthy)
- **Load Calculation**: Worker load metrics
- **Concurrent Access**: Thread-safe operations

**Test Count**: 18 unit tests

### `peers.d` - Worker Peer Registry Tests
Tests for peer discovery and management on worker side:
- **Registration**: Peer registration, self-registration filtering, duplicates
- **Metrics**: Peer metrics updates, load factor tracking
- **Health**: Mark peers dead/alive, metrics-based revival
- **Stale Pruning**: Automatic removal of stale peers
- **Victim Selection**: Power-of-two-choices algorithm, load-aware selection
- **Concurrent Access**: Thread-safe peer operations

**Test Count**: 20 unit tests

### `steal.d` - Work-Stealing Engine Tests
Tests for distributed work-stealing protocol:
- **Configuration**: Strategy types, config values
- **Metrics**: Success rate calculation, attempt tracking
- **Steal Attempts**: Empty registry, no victims, failure tracking
- **Request Handling**: Threshold-based stealing, queue size checks
- **Strategies**: PowerOfTwo victim selection
- **Concurrent Access**: Parallel steal attempts

**Test Count**: 16 unit tests

### `storage.d` - Artifact Storage Tests
Tests for content-addressable artifact storage:
- **Basic Operations**: Put, get, has operations
- **Deduplication**: Content-addressable deduplication
- **Batch Operations**: Batch has/get with mixed results
- **Eviction**: LRU eviction on size limits
- **Large Artifacts**: 1MB+ artifact storage
- **Empty Artifacts**: Zero-length artifact handling
- **Persistence**: Storage persistence across instances
- **Concurrent Access**: Thread-safe operations

**Test Count**: 16 unit tests

### `memory.d` - Memory Management Tests
Tests for arena allocators and object pools:

#### Arena Tests
- **Creation**: Arena initialization, capacity tracking
- **Allocation**: Single and multiple allocations, alignment
- **Capacity Checks**: canAllocate predicate
- **Reset**: Arena reset and reuse
- **Arrays**: Typed array allocation

#### ArenaPool Tests
- **Pool Management**: Acquire, release, reuse
- **Statistics**: Pool state tracking
- **RAII**: ScopedArena automatic release

#### ObjectPool Tests
- **Pooling**: Generic object pooling with reset
- **Preallocation**: Pre-warm pool with objects
- **Size Limits**: Maximum pool size enforcement

#### BufferPool Tests
- **Buffer Management**: Specialized byte buffer pooling
- **Zeroing**: Security zeroing on release
- **Size Validation**: Reject wrong-sized buffers

**Test Count**: 22 unit tests

### `grpc.d` - gRPC Transport Tests
Tests for gRPC transport layer and protobuf codec:

#### GrpcConfig Tests
- **Insecure Creation**: Create insecure client config
- **Secure Creation**: Create TLS-enabled config
- **Default Values**: Verify default timeouts and settings

#### TransportConfig Tests
- **URL Parsing**: Parse grpc://, grpcs://, http://, https://
- **Factory Methods**: grpcInsecure, grpcSecure helpers
- **Transport Types**: Http, Grpc, Auto enum values

#### GrpcCodec Tests
- **HeartBeat Encoding**: Encode worker heartbeat messages
- **StealRequest Encoding**: Encode work-stealing requests
- **StealResponse Encoding**: Encode steal responses with actions
- **ActionRequest Encoding**: Full action request with inputs/outputs
- **Capabilities Encoding**: Path lists, resource limits
- **Varint Encoding**: Small and large number encoding
- **Decode Edge Cases**: Empty data, malformed input handling

#### GrpcServer Tests
- **Server Creation**: Create server instances
- **Start/Stop**: Server lifecycle management
- **Configuration**: Verify bound address, TLS settings

#### Transport Pool Tests
- **Pool Creation**: Create with different strategies
- **Endpoint Management**: Add multiple endpoints
- **Error Handling**: Empty pool returns error

**Test Count**: 40 unit tests

### `scheduler.d` - Coordinator Scheduler Tests
Tests for distributed scheduler with lock striping:
- **Creation**: Scheduler initialization, shutdown
- **Scheduling**: Action scheduling, duplicate handling, multiple actions
- **Priority**: Priority ordering, critical-first dequeue
- **Dequeue**: Empty queue handling, state transitions
- **Assignment**: Worker assignment, non-existent action handling
- **Completion**: Action completion, stats update
- **Failure Handling**: Retry logic, permanent failure after max retries
- **Worker Failure**: Action reassignment on worker failure
- **Stats**: Accuracy verification across states
- **Concurrency**: Parallel scheduling, parallel dequeue
- **Sharding**: Distribution across 32 shards

**Test Count**: 18 unit tests

### `sandbox.d` - Worker Sandbox Tests
Tests for isolated execution environment:
- **Factory**: Hermetic and non-hermetic sandbox creation
- **NoSandbox**: Prepare, execute simple commands, environment variables, failing commands
- **ExecutionOutput**: Structure, empty output handling
- **Environment**: Work directory setup
- **Capabilities**: Default values, network, resource limits, path restrictions
- **Input Artifacts**: Structure validation
- **Timeout**: Configuration and enforcement
- **Output Specs**: File and directory specifications
- **Concurrency**: Parallel preparation and execution

**Test Count**: 20 unit tests

### `integration.d` - End-to-End Integration Tests
Tests for complete distributed system workflows:
- **Coordinator Lifecycle**: Creation, config defaults
- **Worker Registration Flow**: Registration, heartbeat updates
- **Action Execution Flow**: Schedule → dequeue → assign → complete
- **Multi-Worker**: Distribution across worker pool
- **Load Balancing**: Load-based worker selection
- **Artifact Storage Flow**: Put and get operations
- **Health Check Flow**: Timeout detection, recovery
- **Retry Flow**: Failure and retry mechanics
- **Concurrency**: Parallel scheduling and completion
- **Full Simulation**: Complete build workflow simulation

**Test Count**: 14 unit tests

### `chaos.d` - Chaos/Fault Injection Tests
Tests for system resilience under failure conditions:
- **Worker Failure Injection**: Random failures, all workers fail
- **Action Failure Injection**: Random failures, cascading failures
- **Heartbeat Failures**: Timeout during execution, intermittent heartbeats
- **Storage Failures**: Memory pressure, concurrent eviction
- **Race Conditions**: Concurrent schedule/complete, registration/selection
- **Network Partition**: Simulated datacenter partition
- **Stress Tests**: High action churn, worker state thrashing

**Test Count**: 14 unit tests

### `performance.d` - Performance Regression Tests
Benchmark tests with throughput and latency assertions:
- **Scheduling Performance**: Throughput (>5000/sec), concurrent scheduling
- **Worker Registry**: Registration, selection, heartbeat update throughput
- **Storage Performance**: Put and get throughput
- **Concurrent Performance**: Parallel scheduling and dequeue
- **Latency Tests**: Scheduling latency (<1ms avg), selection latency (<500µs)
- **Memory Efficiency**: Storage eviction under pressure
- **Scalability**: Linear scaling verification (100→10000 actions)

**Test Count**: 12 unit tests

### `reapi.d` - REAPI v2 Compatibility Tests
Tests for Bazel Remote Execution API compatibility:
- **Digest**: Creation, hash string, equality
- **Adapter**: Creation with SHA256/BLAKE3, capabilities/platform conversion, priority conversion
- **Hash Translator**: ActionId ↔ Digest conversion
- **Codec**: Varint encoding, digest/action result/execute response encoding
- **Server Capabilities**: Build capabilities, supported digest functions, compressors
- **Status**: OK and error status handling
- **Client/Server**: Creation, handler registration, capabilities endpoint
- **Action Conversion**: Request/result bidirectional conversion
- **Wire Format**: Tag creation, execute request encoding
- **Error Handling**: Null requests, invalid digests, unknown endpoints

**Test Count**: 33 unit tests

## Running Tests

### Run All Distributed Tests
```bash
dub test -- tests.unit.core.distributed
```

### Run Specific Test Module
```bash
dub test -- tests.unit.core.distributed.protocol
dub test -- tests.unit.core.distributed.registry
dub test -- tests.unit.core.distributed.peers
dub test -- tests.unit.core.distributed.steal
dub test -- tests.unit.core.distributed.storage
dub test -- tests.unit.core.distributed.memory
dub test -- tests.unit.core.distributed.grpc
dub test -- tests.unit.core.distributed.scheduler
dub test -- tests.unit.core.distributed.sandbox
dub test -- tests.unit.core.distributed.integration
dub test -- tests.unit.core.distributed.chaos
dub test -- tests.unit.core.distributed.performance
dub test -- tests.unit.core.distributed.reapi
```

## Test Coverage

| Component | Tests | Coverage Areas |
|-----------|-------|----------------|
| Protocol | 19 | Message types, serialization, enums |
| Registry | 18 | Worker management, heartbeat, selection |
| Peers | 20 | Peer discovery, victim selection |
| Steal | 16 | Work-stealing strategies, metrics |
| Storage | 16 | Content-addressable storage, eviction |
| Memory | 22 | Arenas, object pools, buffers |
| gRPC | 40 | Transport, codec, server, config |
| Scheduler | 18 | Distributed scheduler, sharding, priorities |
| Sandbox | 20 | Execution isolation, capabilities |
| Integration | 14 | End-to-end workflows, multi-worker |
| Chaos | 14 | Fault injection, resilience |
| Performance | 12 | Throughput, latency, scalability |
| REAPI | 33 | Bazel Remote Execution API compatibility |
| **Total** | **262** | Comprehensive distributed system coverage |

## Test Patterns

### Thread Safety
All components include concurrent access tests to verify thread-safety:
```d
unittest
{
    import std.parallelism : parallel;
    import std.range : iota;
    
    foreach (i; parallel(iota(100)))
    {
        // Concurrent operations
    }
}
```

### Error Handling
Tests verify proper error handling for edge cases:
- Non-existent resources
- Invalid parameters
- Timeout conditions
- Capacity limits

### RAII
Tests verify proper resource cleanup:
```d
{
    auto scoped = ScopedArena(pool);
    // Use arena
} // Automatically released
```

### Metrics Tracking
Tests verify metrics collection:
```d
auto metrics = engine.getMetrics();
Assert.equal(atomicLoad(metrics.attempts), expected);
```

## Integration with CI/CD

These tests run as part of the Builder test suite:
- Executed on every commit
- Required to pass for merge
- Performance benchmarks tracked
- Code coverage monitored

## Future Test Additions

Planned test expansions:
- [x] Coordinator scheduler tests
- [x] Worker sandbox tests
- [x] Protocol transport tests (gRPC)
- [x] End-to-end integration tests
- [x] Chaos/fault injection tests
- [x] Performance regression tests
- [x] gRPC streaming tests (pure D implementation)
- [x] REAPI compatibility tests

## Contributing

When adding new distributed features:
1. Add corresponding unit tests
2. Follow existing test patterns
3. Include concurrent access tests
4. Update test count in this README
5. Run full test suite before submitting

## Notes

- Tests use `TempDir` fixture for filesystem isolation
- Concurrent tests may show warnings on single-core systems
- Some eviction tests have loose assertions due to timing
- All tests must be deterministic and reproducible

