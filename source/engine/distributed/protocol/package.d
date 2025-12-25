module engine.distributed.protocol;

/**
 * Distributed Protocol Layer
 *
 * Provides communication protocols for Builder's distributed execution system.
 *
 * ## Transports
 *
 * - **HTTP/1.1**: Default, no dependencies (engine.distributed.protocol.transport)
 * - **gRPC/HTTP2**: Pure D implementation, full REAPI compat (engine.distributed.protocol.grpc)
 *
 * ## REAPI v2
 *
 * Wire-format compatibility with Bazel Remote Execution API v2.
 * Works with BuildBuddy, BuildBarn, Buildfarm, Google RBE, etc.
 */

public import engine.distributed.protocol.protocol;
public import engine.distributed.protocol.transport;
public import engine.distributed.protocol.messages;
public import engine.distributed.protocol.schema;

// gRPC transport (pure D HTTP/2 + gRPC implementation)
public import engine.distributed.protocol.grpc;

// REAPI v2 compatibility layer
// Provides wire-format compatibility with Bazel Remote Execution API v2
public import engine.distributed.protocol.reapi_v2;
