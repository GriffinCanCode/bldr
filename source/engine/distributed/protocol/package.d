module engine.distributed.protocol;

public import engine.distributed.protocol.protocol;
public import engine.distributed.protocol.transport;
public import engine.distributed.protocol.messages;
public import engine.distributed.protocol.schema;

// gRPC transport (optional, requires grpc-core library)
// Import explicitly: import engine.distributed.protocol.grpc;
version (EnableGrpc) {
    public import engine.distributed.protocol.grpc;
}
