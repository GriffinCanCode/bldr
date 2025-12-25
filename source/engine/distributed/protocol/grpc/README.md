# gRPC Transport for Remote Execution

High-performance gRPC transport layer for Builder's distributed execution system, enabling true Bazel REAPI compatibility and interoperability with existing remote execution infrastructure.

## Overview

The gRPC module provides an alternative transport implementation that complements Builder's existing HTTP transport. It enables:

- **True REAPI Compatibility**: Wire-compatible with Bazel Remote Execution API
- **Streaming**: Bidirectional streaming for progress updates and large artifacts
- **Automatic Retry**: Built-in retry with exponential backoff
- **Deadline Propagation**: Timeouts flow through the entire call chain
- **Interoperability**: Works with BuildBuddy, BuildBarn, Buildfarm, and other RE implementations

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 Builder Protocol Types                    │
│           (ActionRequest, ActionResult, etc.)             │
└────────────────────────┬────────────────────────────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│HttpTransport│  │GrpcTransport│  │MockTransport│
│  (HTTP/1.1) │  │ (gRPC/H2)   │  │  (Testing)  │
└──────┬──────┘  └──────┬──────┘  └─────────────┘
       │                │
       │                ▼
       │         ┌─────────────┐
       │         │ GrpcCodec   │
       │         │ (Protobuf)  │
       │         └──────┬──────┘
       │                │
       ▼                ▼
   std.socket      grpc-core (C)
```

## Components

### Proto Definitions

- `proto/builder_remote.proto` - Builder's native protocol in protobuf format
- `proto/reapi_compat.proto` - Bazel REAPI wire-compatible definitions

### D Modules

- `bindings.d` - C FFI bindings to grpc-core
- `codec.d` - Protobuf wire format encoder/decoder
- `transport.d` - GrpcTransport implementing Transport interface
- `server.d` - gRPC server for hosting REAPI-compatible services
- `factory.d` - Unified transport factory with auto-detection

## Usage

### Client: Connecting to Remote Coordinator

```d
import engine.distributed.protocol.grpc;

// Simple insecure connection
auto config = GrpcConfig.insecure("coordinator:9000");
auto transport = new GrpcTransport(config);

// Execute action
auto request = new ActionRequest(...);
auto result = transport.execute(request);

// With streaming progress
transport.executeStream(request, (progress) {
    writeln("Progress: ", progress.stage, " - ", progress.progress * 100, "%");
});
```

### Client: Using the Factory

```d
import engine.distributed.protocol.grpc;

// Auto-detect from URL
auto result = UnifiedTransportFactory.createFromUrl("grpc://coordinator:9000");
if (result.isOk) {
    auto transport = result.unwrap();
    // Use transport...
}

// With explicit configuration
auto config = TransportConfig.grpcSecure("coordinator:9000", rootCerts);
config.callTimeout = 120.seconds;
config.enableRetry = true;
auto transport = UnifiedTransportFactory.create(config);
```

### Server: Hosting REAPI-Compatible Service

```d
import engine.distributed.protocol.grpc;

// Create server
auto server = GrpcServerBuilder.create()
    .listenOn("0.0.0.0:9000")
    .withService(new CoordinatorServiceHandler(&executeAction))
    .withService(new ReapiExecutionHandler(&executeAction))
    .build();

// Start serving
server.start();

// ... later
server.stop();
```

### Configuration Options

```d
// Transport config
TransportConfig config;
config.type = TransportType.Grpc;
config.endpoint = "coordinator:9000";
config.useTls = true;
config.rootCerts = readText("ca.pem");
config.clientCert = readText("client.pem");
config.clientKey = readText("client-key.pem");
config.connectTimeout = 30.seconds;
config.callTimeout = 60.seconds;
config.maxRetries = 3;

// gRPC-specific
config.maxMessageSize = 16 * 1024 * 1024;  // 16MB
config.enableRetry = true;
```

## Installation

### Dependencies

The gRPC module requires the grpc-core C library:

**macOS (Homebrew):**
```bash
brew install grpc
```

**Ubuntu/Debian:**
```bash
sudo apt install libgrpc-dev libgrpc++-dev
```

**From source:**
```bash
git clone https://github.com/grpc/grpc.git
cd grpc
git submodule update --init
mkdir build && cd build
cmake ..
make -j$(nproc)
sudo make install
```

### Linking

Add to your `dub.json`:
```json
{
    "libs": ["grpc", "gpr"],
    "lflags-linux": ["-L/usr/local/lib"],
    "lflags-osx": ["-L/opt/homebrew/lib"]
}
```

Or compile with:
```bash
dmd -L-lgrpc -L-lgpr your_app.d
```

## Protocol Compatibility

### Builder Native Protocol

The Builder native protocol (`builder_remote.proto`) provides:

- Efficient binary encoding optimized for build actions
- Support for work stealing between workers
- Native priority scheduling
- Full hermetic sandbox specification

### Bazel REAPI Compatibility

The REAPI adapter (`reapi_compat.proto`) provides wire-level compatibility with:

- `build.bazel.remote.execution.v2.Execution`
- `build.bazel.remote.execution.v2.ActionCache`
- `build.bazel.remote.execution.v2.ContentAddressableStorage`
- `build.bazel.remote.execution.v2.Capabilities`

This enables Builder to:
- Act as a Bazel remote execution backend
- Connect to existing RE infrastructure (BuildBuddy, BuildBarn, etc.)
- Use standard REAPI tooling for debugging

## Transport Selection Strategy

The `UnifiedTransportFactory` supports different strategies:

| Strategy | Description |
|----------|-------------|
| `PreferGrpc` | Use gRPC if available, fall back to HTTP |
| `PreferHttp` | Use HTTP if available, fall back to gRPC |
| `GrpcOnly` | Only use gRPC (fail if unavailable) |
| `HttpOnly` | Only use HTTP |
| `RoundRobin` | Alternate between transports |

## Performance Characteristics

| Metric | HTTP/1.1 | gRPC/HTTP2 |
|--------|----------|------------|
| Connection reuse | Limited | Full multiplexing |
| Streaming | Not supported | Bidirectional |
| Header compression | None | HPACK |
| Binary framing | Custom | Standard |
| Retry | Manual | Automatic |
| Deadline propagation | Manual | Built-in |

## When to Use Each Transport

### Use HTTP Transport When:
- Simple deployments without external dependencies
- Internal communication within a single datacenter
- No need for streaming or REAPI compatibility
- Minimal binary footprint required

### Use gRPC Transport When:
- REAPI compatibility is required
- Connecting to external RE infrastructure
- Large artifact streaming needed
- Cross-datacenter communication
- Need automatic retry and deadline propagation

## Troubleshooting

### "Failed to create channel"
- Check that grpc-core is installed
- Verify the target address is correct
- Check network connectivity

### "SSL handshake failed"
- Verify certificate paths
- Check certificate validity
- Ensure CA is trusted

### "Deadline exceeded"
- Increase `callTimeout`
- Check network latency
- Verify server is responsive

## See Also

- [Distributed Build System](../../README.md)
- [Remote Execution](../../../runtime/remote/README.md)
- [REAPI Adapter](../../../runtime/remote/protocol/reapi.d)
- [Bazel Remote Execution API](https://github.com/bazelbuild/remote-apis)

