# Builder Plugin Examples

This directory contains comprehensive example plugins demonstrating Builder's plugin capabilities.

## Available Plugins

### 1. **builder-plugin-demo** (Python)
Simple demonstration plugin showing:
- JSON-RPC 2.0 protocol implementation
- Pre-build and post-build hooks
- Plugin metadata and logging
- Artifact processing

### 2. **builder-plugin-cache** (D)
Intelligent cache warming and optimization:
- Predictive cache warming based on build patterns
- Dependency graph analysis
- Cache hit rate optimization
- Automatic cache eviction

### 3. **builder-plugin-metrics** (Go)
Advanced build metrics and analytics:
- Real-time metrics collection
- Historical trend analysis
- Performance insights and regression detection
- Build statistics tracking

### 4. **builder-plugin-security** (Rust)
Dependency vulnerability scanner:
- Multi-language dependency scanning
- CVE detection and reporting
- Severity classification (CRITICAL, HIGH, MEDIUM, LOW)
- Actionable security recommendations

### 5. **builder-plugin-notify** (Python)
Smart build notifications:
- Slack, Discord, and email support
- Context-aware messaging (branch, commit, duration)
- Configurable notification thresholds
- Rich formatting with build metadata

### Test the Demo Plugin

```bash
# Make executable
chmod +x builder-plugin-demo

# Test info request
echo '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}' | ./builder-plugin-demo

# Test pre-hook
echo '{"jsonrpc":"2.0","id":2,"method":"build.pre_hook","params":{"target":{"name":"//app:main","type":"executable","language":"python"}}}' | ./builder-plugin-demo

# Test post-hook
echo '{"jsonrpc":"2.0","id":3,"method":"build.post_hook","params":{"target":{"name":"//app:main"},"success":true,"duration_ms":1234,"outputs":["bin/app"]}}' | ./builder-plugin-demo
```

### Install Locally

```bash
# Copy to PATH
sudo cp builder-plugin-demo /usr/local/bin/
sudo chmod +x /usr/local/bin/builder-plugin-demo

# Verify installation
builder plugin list
builder plugin info demo
```

## Plugin SDK

We provide SDK libraries to simplify plugin development:

### Python SDK (`sdk/python/builder_plugin_sdk.py`)

```python
from builder_plugin_sdk import Plugin, pre_hook, post_hook, success

plugin = Plugin(name="myplugin", version="1.0.0")

@pre_hook
def before_build(target, workspace):
    return success(["Pre-build complete"])

@post_hook
def after_build(target, workspace, outputs, success, duration_ms):
    return success(["Post-build complete"])

plugin.register("build.pre_hook", before_build)
plugin.register("build.post_hook", after_build)

if __name__ == "__main__":
    plugin.run()
```

See `sdk/python/README.md` for full documentation.

## Testing Utilities (`sdk/testing/`)

Comprehensive testing tools for plugin development:

```python
from plugin_test_utils import PluginTester

tester = PluginTester("./builder-plugin-myplugin")
tester.assert_info(name="myplugin", version="1.0.0")
result = tester.test_pre_hook()
tester.assert_hook_success(result)
```

See `sdk/testing/README.md` for full documentation.

## Creating Your Own Plugin

### 1. Use the Template Generator

```bash
builder plugin create myplugin --language=python
cd builder-plugin-myplugin
```

### 2. Implement with SDK

```bash
# Copy SDK to your plugin
cp examples/plugins/sdk/python/builder_plugin_sdk.py .

# Implement your plugin using the SDK
# See sdk/python/example_plugin.py for reference
```

### 3. Test Your Plugin

```bash
# Copy testing utilities
cp examples/plugins/sdk/testing/plugin_test_utils.py tests/

# Write tests
python3 tests/test_myplugin.py

# Quick smoke test
python3 -c "from plugin_test_utils import quick_test; quick_test('./builder-plugin-myplugin')"
```

### 4. Create Homebrew Formula

```bash
# See distribution/homebrew/plugins/ for formula examples
cp distribution/homebrew/plugins/Formula/builder-plugin-example.rb \
   distribution/homebrew/plugins/Formula/builder-plugin-myplugin.rb

# Edit the formula for your plugin
```

## Plugin Capabilities

Plugins can implement various capabilities:

- **build.pre_hook**: Execute before build starts
- **build.post_hook**: Execute after build completes
- **artifact.process**: Process build artifacts
- **target.custom_type**: Handle custom target types
- **test.runner**: Custom test execution
- **package.publisher**: Publish packages
- **deployment.handler**: Deploy artifacts

## Plugin Ideas (Beyond Examples)

- **Docker Integration**: ✅ Example available (can be enhanced)
- **Kubernetes Deployment**: Deploy to K8s clusters
- **AWS S3 Upload**: Artifact upload to S3
- **GitHub Actions Integration**: CI/CD automation
- **Terraform Deployment**: Infrastructure as code
- **Code Signing**: Sign binaries and packages
- **Documentation Generation**: Auto-generate docs
- **Performance Profiling**: CPU/memory profiling
- **Coverage Analysis**: Code coverage tracking
- **Dependency Updates**: Auto-update dependencies

## Resources

- **Architecture**: [Plugin Architecture Documentation](../../docs/architecture/PLUGINS.md)
- **Distribution**: [Homebrew Formulas](../../distribution/homebrew/plugins/)
- **SDK**: [Python SDK](sdk/python/) | [Testing Utils](sdk/testing/)
- **Examples**: All plugins in this directory
- **Builder Docs**: [Main Documentation](../../docs/)

## Installation

### Via Homebrew (Recommended)

```bash
# Add Builder plugin tap
brew tap builder/plugins

# Install plugins
brew install builder-plugin-demo
brew install builder-plugin-cache
brew install builder-plugin-metrics
brew install builder-plugin-security
brew install builder-plugin-notify

# List installed plugins
builder plugin list
```

### Manual Installation

```bash
# Copy plugin to PATH
sudo cp builder-plugin-demo /usr/local/bin/
sudo chmod +x /usr/local/bin/builder-plugin-demo

# Verify installation
builder plugin validate demo
```

## License

All example plugins are licensed under MIT.

