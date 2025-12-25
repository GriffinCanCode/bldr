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
| **Total** | **151** | Comprehensive distributed system coverage |

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
- [ ] Coordinator scheduler tests
- [ ] Worker sandbox tests
- [x] Protocol transport tests (gRPC)
- [ ] End-to-end integration tests
- [ ] Chaos/fault injection tests
- [ ] Performance regression tests
- [x] gRPC streaming tests (pure D implementation)
- [ ] REAPI compatibility tests

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

