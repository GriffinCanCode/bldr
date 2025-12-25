# REAPI v2 Compatibility Layer

Wire-format compatible adapter for Bazel's Remote Execution API v2 (`build.bazel.remote.execution.v2`).

## Overview

This module enables Builder to:

1. **Connect to REAPI servers** (BuildBuddy, BuildBarn, Google RBE, etc.)
2. **Expose Builder as REAPI endpoint** (serve Bazel, other REAPI clients)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    REAPI v2 Layer                           │
├─────────────────────────────────────────────────────────────┤
│  types.d      │ REAPI type definitions (Digest, Action...)  │
│  codec.d      │ Protobuf wire format encoder/decoder        │
│  hash.d       │ BLAKE3 ↔ SHA256 hash translation            │
│  adapter.d    │ Builder ↔ REAPI type conversions            │
│  services.d   │ Service implementations (Execution, CAS...) │
├─────────────────────────────────────────────────────────────┤
│                Builder Native Protocol                       │
│  (protocol.d, transport.d, messages.d)                      │
└─────────────────────────────────────────────────────────────┘
```

## Usage

### As Client (Connect to REAPI Server)

```d
import engine.distributed.protocol.reapi_v2;

// Connect to remote execution server
auto client = new ReapiV2Client("buildbarn.example.com:8980");

// Execute Builder action remotely
auto result = client.execute(builderActionRequest);
if (result.isOk) {
    auto actionResult = result.unwrap();
    writeln("Exit code: ", actionResult.exitCode);
}

// Get server capabilities
auto caps = client.getCapabilities();
if (caps.isOk) {
    writeln("Supported hash: ", caps.unwrap().executionCapabilities.digestFunction);
}

// Direct CAS access
auto blobData = client.downloadBlob(digest);
client.uploadBlob(digest, data);
```

### As Server (Expose Builder to REAPI Clients)

```d
import engine.distributed.protocol.reapi_v2;

// Create service bundle with execution handler
auto services = new ReapiServiceBundle((request) {
    // Execute action using Builder's executor
    return builderCoordinator.execute(request);
});

// Create request router
auto router = ReapiRouter(services);

// Handle incoming requests
auto response = router.route("POST", "/v2/default/actions:execute", requestBody);
```

### Hash Translation

Builder uses BLAKE3, REAPI typically uses SHA256. The hash translator maintains bidirectional mappings:

```d
auto translator = new HashTranslator();

// Register content (computes both hashes)
translator.registerContent(fileBytes);

// Convert between formats
auto reapiDigest = translator.actionIdToDigest(builderActionId, size);
auto actionId = translator.digestToActionId(reapiDigest);
```

## Supported Services

| Service | Description | Status |
|---------|-------------|--------|
| Execution | Remote action execution | ✅ Full |
| ActionCache | Cached action results | ✅ Full |
| ContentAddressableStorage | Blob storage | ✅ Full |
| Capabilities | Server capability reporting | ✅ Full |

## Wire Format

The codec implements protobuf-compatible binary encoding without requiring the protobuf library:

- Varint encoding for integers
- Length-delimited strings/bytes
- Packed repeated fields
- Standard field tags

This ensures wire-level compatibility with:
- Bazel Remote Execution clients
- BuildBuddy
- BuildBarn  
- BuildGrid
- Buildfarm
- Google Remote Build Execution

## Hash Functions

| Function | Builder Support | REAPI Default |
|----------|----------------|---------------|
| BLAKE3 | ✅ Native | Optional |
| SHA256 | ✅ Translation | ✅ Default |
| SHA1 | ⚠️ Legacy only | Deprecated |

## Configuration

Enable REAPI v2 support in your build:

```d
// dub.json
{
    "versions": ["EnableReapiV2"]
}
```

Or via command line:

```bash
dub build --d-versions=EnableReapiV2
```

## Endpoints

Standard REAPI v2 endpoint paths:

```
POST /v2/{instance}/actions:execute
GET  /v2/{instance}/actionResults/{hash}/{size}
PUT  /v2/{instance}/actionResults/{hash}/{size}
POST /v2/{instance}/blobs:findMissing
POST /v2/{instance}/blobs:batchUpdate
POST /v2/{instance}/blobs:batchRead
GET  /v2/{instance}/blobs/{hash}/{size}
PUT  /v2/{instance}/blobs/{hash}/{size}
GET  /v2/{instance}/capabilities
GET  /v2/operations/{name}
DELETE /v2/operations/{name}
```

## Integration Examples

### With BuildBuddy

```d
auto client = new ReapiV2Client(
    "remote.buildbuddy.io:443",
    "my-instance"
);
```

### With BuildBarn

```d
auto client = new ReapiV2Client(
    "scheduler.buildbarn.example.com:8980",
    ""
);
```

### With Google RBE

```d
auto client = new ReapiV2Client(
    "remotebuildexecution.googleapis.com:443",
    "projects/my-project/instances/default"
);
```

## Performance Notes

- Zero-copy where possible
- Streaming support for large blobs
- Connection pooling recommended for production
- Hash translation table grows with unique content

## See Also

- `proto/reapi_compat.proto` - REAPI protocol definition
- `proto/builder_remote.proto` - Builder native protocol
- [REAPI Specification](https://github.com/bazelbuild/remote-apis)

