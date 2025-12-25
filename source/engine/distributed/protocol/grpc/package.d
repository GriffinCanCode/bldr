module engine.distributed.protocol.grpc;

/**
 * gRPC Transport Layer for REAPI Compatibility
 * 
 * Provides full HTTP/2 + gRPC wire protocol support for Builder's distributed
 * execution system. Enables true Bazel REAPI compatibility and interoperability
 * with existing remote execution infrastructure.
 * 
 * ## Features
 * 
 * - **Pure D Implementation**: No external dependencies required
 * - **HTTP/2 Framing**: Full RFC 7540 frame support
 * - **HPACK Compression**: Header compression (RFC 7541)
 * - **gRPC Wire Format**: Length-prefixed messages
 * - **REAPI Compatible**: Works with BuildBuddy, BuildBarn, Buildfarm
 * - **Streaming**: Unary, server-streaming, and bidirectional support
 * 
 * ## Architecture
 * 
 * ```
 * Builder Protocol Types (protocol.d)
 *         ↓
 *    GrpcCodec (codec.d)
 *         ↓ protobuf wire format
 *    GrpcFrame (frame.d)
 *         ↓ gRPC length-prefixed framing
 *    H2Connection (http2.d)
 *         ↓ HTTP/2 frames
 *    TCP Socket
 * ```
 * 
 * ## Usage
 * 
 * ### Client (connect to REAPI server)
 * 
 * ```d
 * import engine.distributed.protocol.grpc;
 * 
 * // Insecure connection
 * auto config = GrpcConfig.insecure("coordinator:9000");
 * auto transport = new GrpcTransport(config);
 * 
 * if (transport.connect().isOk) {
 *     // Execute action
 *     auto result = transport.execute(actionRequest);
 *     
 *     // REAPI calls
 *     auto caps = transport.getCapabilities("");
 * }
 * 
 * // Or use factory
 * auto result = GrpcTransportFactory.createFromUrl("grpc://coordinator:9000");
 * ```
 * 
 * ### Server (REAPI-compatible)
 * 
 * ```d
 * import engine.distributed.protocol.grpc;
 * 
 * auto server = GrpcServerBuilder.create()
 *     .listenOn("0.0.0.0:50051")
 *     .withMaxConcurrentStreams(100)
 *     .withService(new MyServiceHandler())
 *     .build();
 * 
 * server.start();
 * // ... server runs until stopped
 * server.stop();
 * ```
 * 
 * ## Proto Definitions
 * 
 * See `proto/builder_remote.proto` for Builder's native protocol and
 * `proto/reapi_compat.proto` for Bazel REAPI wire compatibility.
 * 
 * ## Dependencies
 * 
 * **None** - Pure D implementation using std.socket.
 * 
 * For optional grpc-core FFI (higher performance):
 * - macOS: `brew install grpc`
 * - Linux: `apt install libgrpc-dev`
 * - Link with: `-lgrpc -lgpr`
 */

public import engine.distributed.protocol.grpc.http2;
public import engine.distributed.protocol.grpc.frame;
public import engine.distributed.protocol.grpc.codec;
public import engine.distributed.protocol.grpc.transport;
public import engine.distributed.protocol.grpc.server;
public import engine.distributed.protocol.grpc.factory;
public import engine.distributed.protocol.grpc.types;
public import engine.distributed.protocol.grpc.bindings;
public import engine.distributed.protocol.grpc.cas;

// Re-export key types for convenience
public import engine.distributed.protocol.grpc.transport : 
    GrpcConfig, 
    GrpcTransport, 
    GrpcTransportFactory;

public import engine.distributed.protocol.grpc.server :
    GrpcServerConfig,
    GrpcServer,
    GrpcServerBuilder,
    GrpcServiceHandler,
    ReapiServiceHandler;

public import engine.distributed.protocol.grpc.http2 :
    H2Connection,
    H2Settings,
    H2Response,
    FrameType,
    FrameFlags,
    H2ErrorCode;

public import engine.distributed.protocol.grpc.frame :
    GrpcFrame,
    GrpcStatusCode,
    GrpcMethod,
    GrpcHeaders,
    ReapiServices;

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

public import engine.distributed.protocol.grpc.cas :
    GrpcCasTransport,
    GrpcCasFactory;

public import engine.distributed.protocol.grpc.connection :
    GrpcConnectionPool,
    GrpcConnection,
    ClientStream,
    BidiStream;
