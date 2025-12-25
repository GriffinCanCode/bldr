# Builder Plugin Architecture

**Status:** Implemented  
**Version:** 1.0

---

## Overview

Builder's plugin system uses **process-based plugins** that communicate via **JSON-RPC 2.0 over stdin/stdout**. Plugins are standalone executables, providing:

- **Language agnostic**: Write plugins in any language
- **Process isolation**: Plugin crashes don't affect Builder
- **Simple distribution**: Each plugin is a separate executable
- **No ABI issues**: Protocol-based, version-independent communication

---

## Architecture

### Module Structure

```
source/infrastructure/plugins/
├── discovery/
│   ├── scanner.d       # Plugin discovery
│   └── validator.d     # Plugin validation
├── protocol/
│   ├── codec.d         # JSON-RPC encoding/decoding
│   └── types.d         # Protocol types (RPCRequest, RPCResponse)
├── manager/
│   ├── registry.d      # Plugin registry
│   ├── loader.d        # Plugin process execution
│   └── lifecycle.d     # Hook execution with circuit breaker
└── sdk/
    └── templates.d     # Plugin template generator
```

### Plugin Discovery

Plugins are discovered by name prefix `builder-plugin-*` in:

1. `~/.builder/plugins/`
2. `/usr/local/bin/`
3. `/opt/homebrew/bin/`
4. `$PATH` directories

Discovery queries each plugin for metadata:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}' | builder-plugin-docker
```

Results are cached in `.builder-cache/plugins.json`.

---

## Protocol

### JSON-RPC 2.0

**Request (Builder → Plugin):**
```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "method": "build.pre_hook",
  "params": {
    "target": {
      "name": "//app:main",
      "type": "executable",
      "language": "python",
      "sources": ["src/main.py"]
    },
    "workspace": {
      "root": "/path/to/project",
      "cacheDir": ".builder-cache"
    }
  }
}
```

**Response (Plugin → Builder):**
```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "success": true,
    "logs": ["Pre-build completed"]
  }
}
```

**Error Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "error": {
    "code": -32000,
    "message": "Docker daemon not running"
  }
}
```

### Error Codes

```d
enum RPCErrorCode {
    ParseError       = -32700,
    InvalidRequest   = -32600,
    MethodNotFound   = -32601,
    InvalidParams    = -32602,
    InternalError    = -32603,
    
    // Builder-specific
    ToolNotFound     = -32000,
    InvalidConfig    = -32001,
    BuildFailed      = -32002,
    Timeout          = -32003,
    PluginCrashed    = -32004
}
```

---

## Plugin Capabilities

### Build Lifecycle Hooks

```json
// Pre-build hook
{"method": "build.pre_hook", "params": {"target": {...}, "workspace": {...}}}

// Post-build hook  
{"method": "build.post_hook", "params": {"target": {...}, "outputs": ["bin/app"], "success": true, "durationMs": 1234}}
```

### Custom Target Types

Plugins can handle custom target types:

```json
{"method": "target.build", "params": {"target": {"type": "docker_image", "config": {...}}}}
```

### Artifact Processing

```json
{"method": "artifact.process", "params": {"artifacts": [{"path": "bin/app", "type": "executable"}]}}
```

---

## Health Tracking and Circuit Breaker

The `LifecycleManager` tracks plugin health with circuit breaker pattern:

**States:**
- `Healthy` - Normal operation
- `Degraded` - Some failures but still usable
- `Unhealthy` - Circuit open, requests blocked
- `Recovering` - Testing if plugin recovered

**Circuit Breaker:**
- Opens after 3 consecutive failures
- Resets after 30 seconds
- Half-open state allows limited test requests

**Fail Modes:**
- `Required` - Failure stops the build
- `Optional` - Log warning and continue
- `Silent` - Ignore failures silently

**Hot Reload:**
Plugin executables are monitored for changes. When modified, the plugin is automatically reloaded and its circuit breaker reset.

---

## Plugin Metadata

Each plugin must respond to `plugin.info`:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "name": "docker",
    "version": "1.0.0",
    "author": "Griffin",
    "description": "Docker container build integration",
    "homepage": "https://github.com/builder-plugins/docker",
    "capabilities": ["build.pre_hook", "build.post_hook", "target.custom_type"],
    "minBuilderVersion": "1.0.0",
    "license": "MIT"
  }
}
```

---

## CLI Commands

```bash
# List installed plugins
builder plugin list

# Show plugin info
builder plugin info docker

# Install plugin (via Homebrew)
builder plugin install docker

# Uninstall plugin
builder plugin uninstall docker

# Validate plugin responds correctly
builder plugin validate docker

# Create new plugin from template
builder plugin create my-plugin --language=d
```

---

## Configuration

### Workspace Configuration

```d
// Builderspace
workspace("myproject") {
    plugins: [
        {
            name: "docker";
            config: {
                registry: "docker.io";
            };
        }
    ];
}
```

### Per-Target Configuration

```d
// Builderfile
target("app") {
    type: executable;
    sources: ["src/**/*.py"];
    
    plugins: {
        docker: {
            image: "myapp:latest";
        };
    };
}
```

---

## Writing a Plugin

### D Plugin Template

```d
import std.stdio;
import std.json;

void main() {
    foreach (line; stdin.byLine) {
        try {
            auto request = parseJSON(line);
            auto response = handleRequest(request);
            writeln(response.toString());
            stdout.flush();
        } catch (Exception e) {
            writeln(`{"jsonrpc":"2.0","error":{"code":-32603,"message":"` ~ e.msg ~ `"}}`);
            stdout.flush();
        }
    }
}

JSONValue handleRequest(JSONValue request) {
    string method = request["method"].str;
    long id = request["id"].integer;
    
    switch (method) {
        case "plugin.info":
            return JSONValue([
                "jsonrpc": "2.0",
                "id": id,
                "result": JSONValue([
                    "name": "my-plugin",
                    "version": "1.0.0",
                    "capabilities": JSONValue(["build.pre_hook"])
                ])
            ]);
        case "build.pre_hook":
            // Plugin logic here
            return JSONValue([
                "jsonrpc": "2.0",
                "id": id,
                "result": JSONValue(["success": true, "logs": JSONValue(["Done"])])
            ]);
        default:
            return JSONValue([
                "jsonrpc": "2.0",
                "error": JSONValue(["code": -32601, "message": "Method not found"])
            ]);
    }
}
```

### Python Plugin Template

```python
#!/usr/bin/env python3
import json
import sys

PLUGIN_INFO = {
    "name": "my-plugin",
    "version": "1.0.0",
    "capabilities": ["build.pre_hook", "build.post_hook"]
}

def handle_request(request):
    method = request["method"]
    req_id = request.get("id", 0)
    
    if method == "plugin.info":
        return {"jsonrpc": "2.0", "id": req_id, "result": PLUGIN_INFO}
    elif method == "build.pre_hook":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"success": True}}
    else:
        return {"jsonrpc": "2.0", "error": {"code": -32601, "message": f"Unknown: {method}"}}

if __name__ == "__main__":
    for line in sys.stdin:
        try:
            request = json.loads(line)
            response = handle_request(request)
            print(json.dumps(response))
            sys.stdout.flush()
        except Exception as e:
            print(json.dumps({"jsonrpc": "2.0", "error": {"code": -32603, "message": str(e)}}))
            sys.stdout.flush()
```

---

## Homebrew Distribution

### Formula Template

```ruby
class BuilderPluginDocker < Formula
  desc "Docker integration plugin for Builder"
  homepage "https://github.com/builder-plugins/docker"
  url "https://github.com/builder-plugins/docker/archive/v1.0.0.tar.gz"
  sha256 "..."
  license "MIT"

  depends_on "builder"

  def install
    bin.install "builder-plugin-docker"
  end

  test do
    output = pipe_output("#{bin}/builder-plugin-docker", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    assert_match "docker", output
  end
end
```

### Installation

```bash
brew tap builder/plugins
brew install builder-plugin-docker
```

---

## Performance

| Operation | Typical Time | Notes |
|-----------|--------------|-------|
| Discovery | ~5-10ms | Cached after first scan |
| Load | ~20-50ms | Process spawn + info query |
| RPC Call | ~1-5ms | JSON encode/decode + stdin/stdout |

---

## Security

### Current Model

Plugins run with full process privileges. Users should:
- Only install plugins from trusted sources
- Review plugin source code
- Use Homebrew checksums for verification

### Future Sandboxing

Planned sandbox configuration:
```d
plugins: [
    {
        name: "docker";
        sandbox: {
            network: true;
            filesystem: {read: ["src/"], write: [".docker/"]};
        };
    }
]
```

---

## Related Documentation

- [Plugin SDK](../../source/infrastructure/plugins/sdk/)
- [Protocol Types](../../source/infrastructure/plugins/protocol/types.d)
- [Lifecycle Manager](../../source/infrastructure/plugins/manager/lifecycle.d)
