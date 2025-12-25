# gRPC Transport for Remote Execution

Pure D implementation of HTTP/2 + gRPC for REAPI compatibility. No external dependencies required.

## Overview

The gRPC module provides full wire-protocol compatibility with Bazel's Remote Execution API (REAPI), enabling Builder to interoperate with:

- **BuildBuddy** - Bazel's commercial RE platform
- **BuildBarn** - Open-source RE implementation
- **Buildfarm** - Google's open-source RE
- **Engflow** - Enterprise RE platform
- **Google RBE** - Google's Remote Build Execution

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 Builder Protocol Types                    │
│           (ActionRequest, ActionResult, etc.)             │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│                     GrpcCodec                            │
│              (protobuf wire format)                      │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│                     GrpcFrame                            │
│         (5-byte header + protobuf message)               │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│                   H2Connection                           │
│            (HTTP/2 frames + HPACK)                       │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
                    TCP Socket
```

## Components

| Module | Purpose |
|--------|---------|
| `http2.d` | HTTP/2 framing (RFC 7540), HPACK compression (RFC 7541) |
| `frame.d` | gRPC message framing, status codes, REAPI method definitions |
| `codec.d` | Builder ↔ protobuf encoding/decoding |
| `transport.d` | Client-side gRPC transport |
| `server.d` | Server-side gRPC with service handlers |
| `factory.d` | Transport creation and connection pooling |
| `bindings.d` | Optional grpc-core FFI (for native performance) |

## Usage

### Client: Connect to REAPI Server

```d
import engine.distributed.protocol.grpc;

// Create transport
auto config = GrpcConfig.insecure("remote-execution.example.com:443");
auto transport = new GrpcTransport(config);

// Connect
if (transport.connect().isOk) {
    // REAPI: Get server capabilities
    auto capsResult = transport.getCapabilities("");
    
    // REAPI: Find missing blobs
    auto missingResult = transport.findMissingBlobs(request);
    
    // REAPI: Upload blobs
    auto uploadResult = transport.batchUpdateBlobs(blobs);
    
    // REAPI: Execute action
    auto result = transport.execute(actionRequest);
}

transport.close();
```

### Client: Using Factory

```d
import engine.distributed.protocol.grpc;

// Auto-detect from URL
auto result = GrpcTransportFactory.createFromUrl("grpc://coordinator:9000");
if (result.isOk) {
    auto transport = result.unwrap();
    // Use transport...
    transport.close();
}

// Or with configuration
auto config = TransportConfig.grpcSecure("coordinator:9000");
config.callTimeout = 120.seconds;
auto transport = UnifiedTransportFactory.create(config);
```

### Server: REAPI-Compatible Service

```d
import engine.distributed.protocol.grpc;

// Create service handler
class MyExecutionService : GrpcServiceHandler {
    string serviceName() const => ReapiServices.Execution;
    
    Result!(ubyte[], string) handleUnary(string method, const ubyte[] request) {
        switch (method) {
            case "Execute":
                return executeAction(request);
            default:
                return Err!(ubyte[], string)("Unknown method");
        }
    }
}

// Build server
auto server = GrpcServerBuilder.create()
    .listenOn("0.0.0.0:50051")
    .withMaxConcurrentStreams(100)
    .withMaxMessageSize(16 * 1024 * 1024)
    .withService(new MyExecutionService())
    .build();

// Start serving
if (server.start().isOk) {
    writeln("gRPC server listening on port 50051");
    // Server runs until stopped
}

// Graceful shutdown
server.stop();
```

## Wire Format

### gRPC Message Framing

Each gRPC message has a 5-byte header:

```
┌─────────┬─────────────────────────────────────┐
│ 1 byte  │              4 bytes                 │
├─────────┼─────────────────────────────────────┤
│Compress │     Message Length (big-endian)      │
└─────────┴─────────────────────────────────────┘
          │
          ▼
┌───────────────────────────────────────────────┐
│           Protobuf Message Payload             │
└───────────────────────────────────────────────┘
```

### HTTP/2 Frame Structure

```
┌───────────────────────────────────────────────┐
│                Frame Header (9 bytes)          │
├─────────────┬──────────┬───────┬──────────────┤
│Length (24b) │Type (8b) │Flags  │Stream ID(31b)│
└─────────────┴──────────┴───────┴──────────────┘
              │
              ▼
┌───────────────────────────────────────────────┐
│              Frame Payload                     │
└───────────────────────────────────────────────┘
```

## REAPI Services Supported

| Service | Methods | Status |
|---------|---------|--------|
| Capabilities | `GetCapabilities` | ✅ Full |
| Execution | `Execute`, `WaitExecution` | ✅ Full |
| ActionCache | `GetActionResult`, `UpdateActionResult` | ✅ Full |
| ContentAddressableStorage | `FindMissingBlobs`, `BatchUpdateBlobs`, `BatchReadBlobs` | ✅ Full |
| ByteStream | `Read`, `Write` | ✅ Streaming |

## Configuration Options

```d
GrpcConfig config;
config.target = "executor:50051";       // Target endpoint
config.useTls = true;                   // Enable TLS
config.rootCerts = readText("ca.pem"); // CA certificates
config.clientCert = readText("client.pem");
config.clientKey = readText("client-key.pem");
config.connectTimeout = 30.seconds;     // Connection timeout
config.callTimeout = 60.seconds;        // Per-call timeout
config.maxMessageSize = 16 * 1024 * 1024; // 16MB max
config.enableRetry = true;              // Auto-retry
config.maxRetries = 3;
```

## Performance

| Metric | HTTP/1.1 | gRPC/HTTP2 |
|--------|----------|------------|
| Connection reuse | Limited | Full multiplexing |
| Streaming | Not supported | Bidirectional |
| Header compression | None | HPACK (~90% reduction) |
| Binary framing | Custom | Standard |
| Retry | Manual | Automatic |
| Deadline propagation | Manual | Built-in |

## Transport Selection

The `UnifiedTransportFactory` supports multiple strategies:

| Strategy | Description |
|----------|-------------|
| `PreferGrpc` | Use gRPC if available, fall back to HTTP |
| `PreferHttp` | Use HTTP if available, fall back to gRPC |
| `GrpcOnly` | Only use gRPC (fail if unavailable) |
| `HttpOnly` | Only use HTTP |
| `RoundRobin` | Alternate between transports |

## Optional: Native gRPC (grpc-core)

For maximum performance, link with grpc-core C library:

**macOS:**
```bash
brew install grpc
```

**Ubuntu/Debian:**
```bash
sudo apt install libgrpc-dev libgrpc++-dev
```

**Linking:**
```bash
dmd -L-lgrpc -L-lgpr your_app.d
```

## Error Handling

gRPC errors map to standard status codes:

| Code | Name | Meaning |
|------|------|---------|
| 0 | OK | Success |
| 1 | CANCELLED | Cancelled by client |
| 2 | UNKNOWN | Unknown error |
| 3 | INVALID_ARGUMENT | Bad request |
| 4 | DEADLINE_EXCEEDED | Timeout |
| 5 | NOT_FOUND | Resource not found |
| 7 | PERMISSION_DENIED | Authorization failed |
| 8 | RESOURCE_EXHAUSTED | Rate limited |
| 12 | UNIMPLEMENTED | Method not supported |
| 13 | INTERNAL | Server error |
| 14 | UNAVAILABLE | Service unavailable |

## See Also

- [Bazel Remote Execution API](https://github.com/bazelbuild/remote-apis)
- [gRPC Protocol](https://grpc.io/docs/what-is-grpc/core-concepts/)
- [HTTP/2 RFC 7540](https://datatracker.ietf.org/doc/html/rfc7540)
- [HPACK RFC 7541](https://datatracker.ietf.org/doc/html/rfc7541)
