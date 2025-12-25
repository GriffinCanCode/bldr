module engine.distributed.protocol.reapi_v2;

/**
 * Bazel Remote Execution API v2 Compatibility Layer
 * 
 * Provides wire-format compatibility with REAPI v2 (build.bazel.remote.execution.v2)
 * enabling Builder to integrate with existing remote execution infrastructure:
 * - BuildBuddy, BuildBarn, BuildGrid, Buildfarm
 * - Cloud providers (Google RBE, Engflow, etc.)
 * - Custom RE implementations
 * 
 * ## Architecture
 * 
 * ```
 * REAPI Client (Bazel, etc.)
 *         ↓ protobuf wire format
 *    ReapiV2Codec (codec.d)
 *         ↓ 
 *    ReapiV2Adapter (adapter.d)
 *         ↓ translates types
 *    Builder Protocol (protocol.d)
 * ```
 * 
 * ## Key Features
 * 
 * - **Wire Compatibility**: Binary-compatible with REAPI protobuf messages
 * - **Hash Translation**: Bidirectional BLAKE3 ↔ SHA256 mapping
 * - **Service Parity**: Execution, ActionCache, CAS, Capabilities
 * - **Streaming**: Long-running operation support via Operation API
 * - **Zero gRPC Dependency**: Pure binary protocol, no external libraries
 * 
 * ## Usage
 * 
 * ### As Client (connect to REAPI server)
 * 
 * ```d
 * import engine.distributed.protocol.reapi_v2;
 * 
 * auto client = new ReapiV2Client("remote-execution.example.com:443");
 * auto result = client.execute(builderAction);
 * ```
 * 
 * ### As Server (expose Builder as REAPI endpoint)
 * 
 * ```d
 * auto server = new ReapiV2Server(builderCoordinator);
 * server.serve("0.0.0.0:50051");
 * ```
 */

public import engine.distributed.protocol.reapi_v2.types;
public import engine.distributed.protocol.reapi_v2.codec;
public import engine.distributed.protocol.reapi_v2.adapter;
public import engine.distributed.protocol.reapi_v2.services;
public import engine.distributed.protocol.reapi_v2.hash;
public import engine.distributed.protocol.reapi_v2.stream;
public import engine.distributed.protocol.reapi_v2.client;

// Re-export common types for convenience
public import engine.distributed.protocol.reapi_v2.types :
    ReapiDigest,
    ReapiPlatform,
    ReapiCommand,
    ReapiAction,
    ReapiActionResult,
    ReapiDirectory,
    ReapiFileNode,
    ReapiOutputFile,
    DigestFunction,
    Compressor;

public import engine.distributed.protocol.reapi_v2.adapter :
    ReapiV2Adapter,
    ReapiV2Client,
    ReapiV2Server;

public import engine.distributed.protocol.reapi_v2.hash :
    HashTranslator,
    HashFormat;

public import engine.distributed.protocol.reapi_v2.stream :
    ByteStreamService,
    ByteStreamCodec,
    ByteStreamReadRequest,
    ByteStreamWriteRequest,
    ResourceName;

public import engine.distributed.protocol.reapi_v2.client :
    StreamingCasClient,
    CasUploader,
    BlobData;
