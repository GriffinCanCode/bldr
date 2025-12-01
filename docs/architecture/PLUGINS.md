# Builder Plugin Architecture

**Date:** November 2, 2025  
**Version:** 1.0  
**Status:** Design Complete, Implementation In Progress

---

## Executive Summary

Builder's plugin system follows the **UNIX philosophy**: plugins are **standalone executables** that communicate with Builder via a **JSON-RPC protocol over stdin/stdout**. This design is superior to traditional dynamic library approaches for:

- **Language Agnostic**: Plugins can be written in any language
- **Zero Coupling**: Plugins and Builder are completely isolated
- **Fault Isolation**: Plugin crashes don't affect Builder
- **Simple Distribution**: Each plugin is a separate Homebrew formula
- **No ABI Issues**: No shared library compatibility problems
- **Easy Testing**: Plugins are just executables with stdin/stdout

---

## Architecture Philosophy

### Why Process-Based Plugins?

Traditional plugin systems use dynamic libraries (.so/.dylib/.dll), which have significant drawbacks:

| Aspect | Dynamic Libraries | Process-Based (Builder) |
|--------|-------------------|------------------------|
| **Language** | Must match host (D) | Any language |
| **Isolation** | Shared address space | Complete isolation |
| **Crashes** | Crash entire app | Isolated, recoverable |
| **ABI Compatibility** | Fragile, version-locked | Protocol-based, stable |
| **Distribution** | Complex (binary compat) | Simple (executables) |
| **Testing** | Requires host app | Standalone, simple |
| **Updates** | Must match Builder version | Independent updates |
| **Security** | Full process access | Sandboxable |

**Verdict**: Process-based plugins are **objectively superior** for Builder's use case.

---

## Plugin Discovery

### Naming Convention

Plugins are discovered by name prefix:
```bash
builder-plugin-docker   # Docker integration plugin
builder-plugin-sonar    # SonarQube plugin  
builder-plugin-notify   # Notification plugin
```

### Discovery Algorithm

```d
// plugins/discovery/scanner.d
1. Scan directories in order:
   - ~/.builder/plugins/
   - /usr/local/bin/
   - $PATH directories

2. Find executables matching: builder-plugin-*

3. Query each plugin for metadata:
   echo '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}' | builder-plugin-foo

4. Cache discovered plugins in ~/.builder/cache/plugins.json
```

### Plugin Metadata

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
    "capabilities": [
      "build.pre_hook",
      "build.post_hook",
      "target.custom_type",
      "artifact.processor"
    ],
    "minBuilderVersion": "1.0.0",
    "license": "MIT"
  }
}
```

---

## Plugin Protocol

### JSON-RPC 2.0 over stdin/stdout

All plugin communication uses [JSON-RPC 2.0](https://www.jsonrpc.org/specification):

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
      "cache_dir": ".builder-cache"
    },
    "env": {
      "BUILDER_VERSION": "1.0.0"
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
    "modified_target": null,
    "artifacts": [],
    "logs": ["Docker image pulled: python:3.11-slim"]
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
    "message": "Docker daemon not running",
    "data": {
      "suggestion": "Start Docker Desktop or run: sudo dockerd"
    }
  }
}
```

### Standard Error Codes

```d
enum PluginErrorCode {
    ParseError       = -32700,
    InvalidRequest   = -32600,
    MethodNotFound   = -32601,
    InvalidParams    = -32602,
    InternalError    = -32603,
    
    // Custom errors (Builder-specific)
    ToolNotFound     = -32000,
    InvalidConfig    = -32001,
    BuildFailed      = -32002,
    Timeout          = -32003
}
```

---

## Plugin Capabilities

### 1. Build Lifecycle Hooks

```json
// Pre-build hook
{
  "method": "build.pre_hook",
  "params": {
    "target": {...},
    "workspace": {...}
  }
}

// Post-build hook
{
  "method": "build.post_hook",
  "params": {
    "target": {...},
    "outputs": ["bin/app"],
    "success": true,
    "duration_ms": 1234
  }
}
```

### 2. Custom Target Types

```json
// Handler for custom target type
{
  "method": "target.build",
  "params": {
    "target": {
      "name": "//app:container",
      "type": "docker_image",  // Custom type
      "config": {
        "image": "myapp:latest",
        "dockerfile": "Dockerfile"
      }
    }
  }
}
```

### 3. Artifact Processing

```json
// Process build artifacts
{
  "method": "artifact.process",
  "params": {
    "artifacts": [
      {"path": "bin/app", "type": "executable"},
      {"path": "lib/libcore.a", "type": "static_library"}
    ],
    "config": {
      "upload_to_registry": true
    }
  }
}
```

### 4. Custom Commands

Plugins can add new CLI commands:

```bash
builder docker build    # Handled by builder-plugin-docker
builder sonar analyze   # Handled by builder-plugin-sonar
```

---

## Implementation

### Core Modules

```
source/plugins/
├── discovery/
│   ├── scanner.d       # Plugin discovery and caching
│   ├── validator.d     # Plugin validation and security
│   └── package.d
├── protocol/
│   ├── rpc.d           # JSON-RPC 2.0 implementation
│   ├── types.d         # Protocol message types
│   ├── codec.d         # Serialization/deserialization
│   └── package.d
├── manager/
│   ├── registry.d      # Plugin registry
│   ├── loader.d        # Plugin loading and execution
│   ├── lifecycle.d     # Hook lifecycle management
│   └── package.d
├── security/
│   ├── sandbox.d       # Plugin sandboxing (future)
│   ├── permissions.d   # Permission system (future)
│   └── package.d
├── sdk/
│   ├── template.d      # Plugin template generator
│   ├── testing.d       # Plugin testing utilities
│   └── package.d
└── package.d
```

### Key Type Signatures

```d
// plugins/protocol/types.d
struct PluginRequest {
    string jsonrpc = "2.0";
    long id;
    string method;
    JSONValue params;
}

struct PluginResponse {
    string jsonrpc = "2.0";
    long id;
    JSONValue result;
    PluginError* error;
}

struct PluginError {
    int code;
    string message;
    JSONValue data;
}

// plugins/discovery/scanner.d
struct PluginInfo {
    string name;
    string version_;
    string author;
    string description;
    string homepage;
    string[] capabilities;
    string minBuilderVersion;
    string license;
}

// plugins/manager/registry.d
interface IPluginRegistry {
    Result!(PluginInfo[], BuildError) discover();
    Result!(Plugin, BuildError) load(string name);
    Result!(void, BuildError) register(PluginInfo info);
    bool has(string name);
    PluginInfo[] list();
}
```

---

## Homebrew Distribution

### Tap Structure

```
homebrew-builder-plugins/
├── README.md
├── Formula/
│   ├── builder-plugin-docker.rb
│   ├── builder-plugin-sonar.rb
│   ├── builder-plugin-notify.rb
│   ├── builder-plugin-s3.rb
│   └── builder-plugin-grafana.rb
└── .github/
    └── workflows/
        └── ci.yml
```

### Plugin Formula Template

```ruby
class BuilderPluginDocker < Formula
  desc "Docker integration plugin for Builder"
  homepage "https://github.com/builder-plugins/docker"
  url "https://github.com/builder-plugins/docker/archive/v1.0.0.tar.gz"
  sha256 "..."
  license "MIT"

  depends_on "builder"  # Ensure Builder is installed

  def install
    bin.install "builder-plugin-docker"
  end

  test do
    # Test plugin responds to info request
    output = pipe_output("#{bin}/builder-plugin-docker", 
      '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}')
    assert_match "docker", output
  end
end
```

### Installation

```bash
# Add plugin tap
brew tap builder/plugins

# Install specific plugins
brew install builder-plugin-docker
brew install builder-plugin-sonar

# List available plugins
brew search builder-plugin-

# Update plugins
brew upgrade builder-plugin-docker
```

### Version Management

```bash
# Install specific version
brew install builder-plugin-docker@1.0.0

# Pin version
brew pin builder-plugin-docker

# Unpin and upgrade
brew unpin builder-plugin-docker
brew upgrade builder-plugin-docker
```

---

## Plugin SDK

### Template Generator

```bash
builder plugin create my-plugin --language=d
# Creates:
# my-plugin/
# ├── source/
# │   └── app.d          # Main plugin entry point
# ├── dub.json           # D package configuration
# ├── README.md
# ├── LICENSE
# └── .github/
#     └── workflows/
#         └── ci.yml     # GitHub Actions CI
```

### D Plugin Template

```d
// source/app.d
import std.stdio;
import std.json;
import core.stdc.stdlib : exit;

struct PluginInfo {
    string name = "my-plugin";
    string version_ = "1.0.0";
    string author = "Griffin";
    string description = "My awesome Builder plugin";
    string homepage = "https://github.com/GriffinCanCode/builder-plugin-my-plugin";
    string[] capabilities = ["build.pre_hook", "build.post_hook"];
    string minBuilderVersion = "1.0.0";
    string license = "MIT";
}

void main(string[] args) {
    // Read JSON-RPC request from stdin
    string line;
    while ((line = readln()) !is null) {
        try {
            auto request = parseJSON(line);
            auto response = handleRequest(request);
            writeln(response.toJSON());
        } catch (Exception e) {
            writeError(e.msg);
        }
    }
}

JSONValue handleRequest(JSONValue request) {
    string method = request["method"].str;
    
    switch (method) {
        case "plugin.info":
            return handleInfo();
        case "build.pre_hook":
            return handlePreHook(request["params"]);
        case "build.post_hook":
            return handlePostHook(request["params"]);
        default:
            return errorResponse(-32601, "Method not found: " ~ method);
    }
}

JSONValue handleInfo() {
    auto info = PluginInfo();
    return JSONValue([
        "jsonrpc": "2.0",
        "id": 1,
        "result": info.toJSON()
    ]);
}

JSONValue handlePreHook(JSONValue params) {
    // Your pre-build logic here
    return JSONValue([
        "jsonrpc": "2.0",
        "id": params["id"].integer,
        "result": JSONValue([
            "success": true,
            "logs": ["Pre-build hook executed"]
        ])
    ]);
}

JSONValue handlePostHook(JSONValue params) {
    // Your post-build logic here
    return JSONValue([
        "jsonrpc": "2.0",
        "id": params["id"].integer,
        "result": JSONValue([
            "success": true,
            "logs": ["Post-build hook executed"]
        ])
    ]);
}

JSONValue errorResponse(int code, string message) {
    return JSONValue([
        "jsonrpc": "2.0",
        "error": JSONValue([
            "code": code,
            "message": message
        ])
    ]);
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
    "author": "Griffin",
    "description": "My awesome Builder plugin",
    "homepage": "https://github.com/GriffinCanCode/builder-plugin-my-plugin",
    "capabilities": ["build.pre_hook", "build.post_hook"],
    "minBuilderVersion": "1.0.0",
    "license": "MIT"
}

def handle_request(request):
    method = request["method"]
    
    if method == "plugin.info":
        return success_response(request["id"], PLUGIN_INFO)
    elif method == "build.pre_hook":
        return handle_pre_hook(request)
    elif method == "build.post_hook":
        return handle_post_hook(request)
    else:
        return error_response(-32601, f"Method not found: {method}")

def handle_pre_hook(request):
    # Your pre-build logic here
    return success_response(request["id"], {
        "success": True,
        "logs": ["Pre-build hook executed"]
    })

def handle_post_hook(request):
    # Your post-build logic here
    return success_response(request["id"], {
        "success": True,
        "logs": ["Post-build hook executed"]
    })

def success_response(req_id, result):
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": result
    }

def error_response(code, message):
    return {
        "jsonrpc": "2.0",
        "error": {
            "code": code,
            "message": message
        }
    }

def main():
    for line in sys.stdin:
        try:
            request = json.loads(line)
            response = handle_request(request)
            print(json.dumps(response))
            sys.stdout.flush()
        except Exception as e:
            print(json.dumps(error_response(-32603, str(e))))
            sys.stdout.flush()

if __name__ == "__main__":
    main()
```

---

## CLI Integration

### Plugin Command

```bash
# List installed plugins
builder plugin list
# Output:
# docker (1.0.0) - Docker integration
# sonar (2.1.0) - SonarQube analysis
# notify (1.2.0) - Build notifications

# Show plugin info
builder plugin info docker
# Output:
# Name:         docker
# Version:      1.0.0
# Author:       Griffin
# Description:  Docker container build integration
# Homepage:     https://github.com/builder-plugins/docker
# Capabilities: build.pre_hook, build.post_hook, target.custom_type
# License:      MIT

# Install plugin (delegates to Homebrew)
builder plugin install docker
# Runs: brew install builder-plugin-docker

# Uninstall plugin
builder plugin uninstall docker
# Runs: brew uninstall builder-plugin-docker

# Update all plugins
builder plugin update
# Runs: brew upgrade builder-plugin-*

# Validate plugin
builder plugin validate docker
# Checks: executable exists, responds to plugin.info, version compatibility

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
            version: ">=1.0.0";
            config: {
                registry: "docker.io";
                push_on_success: true;
            };
        },
        {
            name: "sonar";
            enabled: true;
            config: {
                server_url: "https://sonar.company.com";
                token: "${SONAR_TOKEN}";
            };
        }
    ];
}
```

### Per-Target Plugin Configuration

```d
// Builderfile
target("app") {
    type: executable;
    sources: ["src/**/*.py"];
    
    plugins: {
        docker: {
            image: "myapp:latest";
            dockerfile: "Dockerfile.app";
        };
        notify: {
            channels: ["#builds"];
            on_failure_only: true;
        };
    };
}
```

---

## Security Considerations

### Current: Trust-Based

In v1.0, plugins run with **full process privileges**. Users must trust plugins they install.

**Mitigation:**
- Official plugins are reviewed and signed
- Community plugins are clearly marked
- Plugin source code is open for inspection
- Homebrew provides provenance (git commits, checksums)

### Future: Sandboxing (v2.0)

```d
// Future: Plugin sandbox configuration
workspace("myproject") {
    plugins: [
        {
            name: "docker";
            sandbox: {
                network: true;         // Allow network access
                filesystem: {
                    read: ["src/", "Dockerfile"];
                    write: [".docker/"];
                };
                env: ["DOCKER_HOST"];  // Allowed env vars
            };
        }
    ];
}
```

**Sandboxing Technologies:**
- **Linux**: seccomp-bpf + namespaces
- **macOS**: sandbox-exec
- **Windows**: Job objects + AppContainer

---

## Performance

### Plugin Overhead

| Operation | Overhead | Mitigation |
|-----------|----------|-----------|
| Discovery | ~5-10ms | Cached in ~/.builder/cache/plugins.json |
| Load | ~20-50ms | Lazy loading, load only when needed |
| RPC Call | ~1-5ms | Batching, async execution |

### Optimization Strategies

1. **Lazy Loading**: Load plugins only when their capabilities are needed
2. **Caching**: Cache plugin discovery results
3. **Batching**: Batch multiple RPC calls into one invocation
4. **Async**: Run plugins concurrently where possible
5. **Keep-Alive**: Reuse plugin processes for multiple calls (future)

---

## Testing

### Unit Tests

```d
// tests/unit/plugins/protocol.d
unittest {
    // Test JSON-RPC encoding
    auto req = PluginRequest(1, "plugin.info", JSONValue(null));
    auto json = encodeRequest(req);
    auto decoded = decodeRequest(json);
    assert(decoded.id == 1);
    assert(decoded.method == "plugin.info");
}

// tests/unit/plugins/discovery.d
unittest {
    // Test plugin discovery
    auto scanner = new PluginScanner();
    auto plugins = scanner.discover(["/test/plugins"]);
    assert(plugins.length > 0);
}
```

### Integration Tests

```bash
# tests/integration/plugins/test-docker-plugin.sh
#!/bin/bash

# Test plugin responds to info
echo '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}' | \
  builder-plugin-docker | \
  jq -e '.result.name == "docker"'

# Test pre-hook
echo '{"jsonrpc":"2.0","id":2,"method":"build.pre_hook","params":{}}' | \
  builder-plugin-docker | \
  jq -e '.result.success == true'
```

### Mock Plugin for Testing

```bash
#!/bin/bash
# tests/fixtures/plugins/builder-plugin-mock

while read -r line; do
  method=$(echo "$line" | jq -r '.method')
  id=$(echo "$line" | jq -r '.id')
  
  case "$method" in
    "plugin.info")
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"name\":\"mock\",\"version\":\"1.0.0\"}}"
      ;;
    *)
      echo "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"success\":true}}"
      ;;
  esac
done
```

---

## Example Plugins

### 1. Docker Plugin

**Features:**
- Build Docker images as target types
- Push to registry on success
- Multi-stage builds
- BuildKit integration

```bash
bldr build //app:container --plugin docker
```

### 2. SonarQube Plugin

**Features:**
- Code quality analysis
- Security scanning
- Technical debt tracking
- PR decoration

```bash
bldr build //app:main --plugin sonar
```

### 3. Notification Plugin

**Features:**
- Slack/Discord notifications
- Email alerts
- Build status updates
- Custom webhooks

```bash
bldr build //app:main --plugin notify
```

### 4. S3 Upload Plugin

**Features:**
- Upload artifacts to S3
- CloudFront invalidation
- Versioned artifacts
- Access control

```bash
bldr build //app:release --plugin s3
```

### 5. Grafana Plugin

**Features:**
- Send build metrics to Grafana
- Custom dashboards
- Performance tracking
- Historical trends

```bash
bldr build //app:main --plugin grafana
```

---

## Roadmap

### Phase 1: Core Infrastructure (Weeks 1-2)
- [x] Design plugin protocol
- [ ] Implement JSON-RPC codec
- [ ] Create plugin discovery system
- [ ] Build plugin registry
- [ ] Add CLI commands

### Phase 2: SDK & Templates (Weeks 3-4)
- [ ] Plugin template generator
- [ ] D SDK library
- [ ] Python SDK library
- [ ] Documentation
- [ ] Example plugins

### Phase 3: Homebrew Integration (Week 5)
- [ ] Create homebrew-builder-plugins tap
- [ ] Write formula templates
- [ ] Setup CI/CD for plugins
- [ ] Publishing workflow

### Phase 4: Official Plugins (Weeks 6-8)
- [ ] Docker plugin
- [ ] Notification plugin
- [ ] S3 upload plugin
- [ ] Grafana plugin

### Phase 5: Advanced Features (Future)
- [ ] Plugin sandboxing
- [ ] Keep-alive mode (persistent plugins)
- [ ] Plugin marketplace
- [ ] Signed plugins
- [ ] Plugin dependencies

---

## Comparison with Other Build Systems

| Feature | Builder | Bazel | Gradle | Buck2 |
|---------|---------|-------|--------|-------|
| Plugin Model | Process-based | Starlark rules | JVM plugins | Starlark rules |
| Language | Any | Starlark only | JVM only | Starlark only |
| Isolation | Full process | None | ClassLoader | None |
| Distribution | Homebrew | Bazel registry | Maven Central | GitHub |
| ABI Stability | N/A (protocol) | Fragile | JVM stable | Rust ABI |
| Testing | Standalone | Requires Bazel | Requires Gradle | Requires Buck2 |

**Verdict**: Builder's process-based approach is **more flexible and more maintainable** than competitors.

---

## FAQ

**Q: Why not use shared libraries like traditional plugin systems?**  
A: Shared libraries have ABI compatibility issues, require matching the host language (D), and crash the entire process on failure. Process-based plugins are isolated, language-agnostic, and more robust.

**Q: Isn't JSON-RPC slow?**  
A: For typical plugin operations (a few per build), the overhead is negligible (1-5ms). We can optimize with batching and keep-alive mode if needed.

**Q: Can plugins modify Builder's behavior?**  
A: Yes, through well-defined hooks. Plugins can run before/after builds, add custom target types, process artifacts, and extend CLI commands.

**Q: How do I write a plugin?**  
A: Use `bldr plugin create my-plugin` to generate a template, implement the JSON-RPC handlers, and build/test. See the SDK section above.

**Q: Are plugins secure?**  
A: In v1.0, plugins run with full privileges (like any CLI tool). Future versions will add sandboxing. Only install plugins you trust.

**Q: Can plugins depend on other plugins?**  
A: Not in v1.0. Future versions may add plugin dependency resolution.

---

**Document Version:** 1.0  
**Last Updated:** November 2, 2025  
**Next Review:** December 1, 2025  
**Status:** Design Complete, Implementation In Progress

