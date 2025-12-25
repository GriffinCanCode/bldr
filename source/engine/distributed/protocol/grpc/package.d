module engine.distributed.protocol.grpc;

/**
 * gRPC Transport Layer
 * 
 * Provides gRPC-based transport for Builder's distributed execution system.
 * Enables true Bazel REAPI compatibility and interoperability with existing
 * remote execution infrastructure.
 * 
 * ## Architecture
 * 
 * ```
 * Builder Protocol Types (protocol.d)
 *         ↓
 *    GrpcCodec (codec.d)
 *         ↓ protobuf wire format
 *    GrpcTransport (transport.d)
 *         ↓ grpc-core FFI
 *    grpc-core C library
 * ```
 * 
 * ## Usage
 * 
 * ### Client (connect to remote coordinator)
 * 
 * ```d
 * import engine.distributed.protocol.grpc;
 * 
 * // Insecure connection
 * auto config = GrpcConfig.insecure("coordinator:9000");
 * auto transport = new GrpcTransport(config);
 * 
 * // Execute action
 * auto result = transport.execute(actionRequest);
 * 
 * // Or use the factory
 * auto transportResult = GrpcTransportFactory.createFromUrl("grpc://coordinator:9000");
 * ```
 * 
 * ### Server (REAPI-compatible)
 * 
 * ```d
 * import engine.distributed.protocol.grpc;
 * 
 * auto server = new GrpcServer(GrpcServerConfig("0.0.0.0:9000"));
 * server.registerService(coordinatorService);
 * server.start();
 * ```
 * 
 * ## Proto Definitions
 * 
 * See `proto/builder_remote.proto` for Builder's native protocol definition
 * and `proto/reapi_compat.proto` for Bazel REAPI wire compatibility.
 * 
 * ## Dependencies
 * 
 * Requires grpc-core library:
 * - macOS: `brew install grpc`
 * - Linux: `apt install libgrpc-dev`
 * - Link with: `-lgrpc -lgpr`
 * 
 * ## Features
 * 
 * - **Streaming**: Bidirectional streaming for progress updates
 * - **Automatic Retry**: Configurable retry with exponential backoff
 * - **Deadline Propagation**: Timeouts propagated through call chain
 * - **TLS Support**: Secure channels with mutual TLS
 * - **REAPI Compatible**: Works with Bazel, BuildBuddy, BuildBarn, etc.
 */

public import engine.distributed.protocol.grpc.transport;
public import engine.distributed.protocol.grpc.codec;
public import engine.distributed.protocol.grpc.server;
public import engine.distributed.protocol.grpc.factory;
public import engine.distributed.protocol.grpc.types;

// Re-export common types
public import engine.distributed.protocol.grpc.transport : 
    GrpcConfig, 
    GrpcTransport, 
    GrpcTransportFactory;

public import engine.distributed.protocol.grpc.types :
    ExecutionProgress,
    RegisterWorkerResponse,
    CoordinatorCommand;

public import engine.distributed.protocol.grpc.factory :
    TransportType,
    TransportConfig,
    UnifiedTransportFactory,
    TransportStrategy,
    TransportPool;
