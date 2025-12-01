# Hermetic Builds - User Guide

## Quick Start

### Enable Hermetic Builds

Hermetic builds are enabled by default on Linux and macOS. To verify:

```bash
bldr build --verbose
```

Look for output like:
```
[INFO] Hermetic builds: enabled (linux-namespaces)
```

### Disable Hermetic Builds

If you need to disable hermetic builds:

```bash
# One-time
BUILDER_HERMETIC=false bldr build

# Permanently (add to .builderrc)
echo 'BUILDER_HERMETIC=false' >> .builderrc
```

## Common Scenarios

### Building with External Dependencies

If your build needs to download dependencies, temporarily allow network:

```bash
# Not recommended for production
BUILDER_HERMETIC_NETWORK=true bldr build
```

Better approach: Pre-download dependencies and add to inputs:

```d
target("myapp") {
    type: executable;
    sources: ["src/**/*.d"];
    deps: ["//third_party:libs"];
}
```

### Custom Build Scripts

For custom build scripts that need specific paths:

```d
target("custom") {
    type: custom;
    sources: ["build.sh"];
    
    hermetic: {
        inputs: ["/usr/local/bin", "/opt/mytools"];
        outputs: ["dist/"];
    }
}
```

### Debugging Build Failures

If hermetic builds fail:

1. **Check available paths:**
   ```bash
   bldr build --hermetic-debug
   ```

2. **Run without sandbox:**
   ```bash
   BUILDER_HERMETIC=false bldr build
   ```

3. **Compare outputs:**
   - If it works without hermetic, you're accessing unspecified paths
   - Check error messages for "Permission denied" or "No such file"

4. **Add missing paths:**
   ```d
   hermetic: {
       inputs: ["/missing/path"];
   }
   ```

## Platform-Specific Notes

### Linux

**Requirements:**
- Kernel 3.8+ (for user namespaces)
- `/proc/self/ns/user` must exist

**Enable unprivileged user namespaces:**
```bash
sudo sysctl kernel.unprivileged_userns_clone=1

# Make permanent
echo 'kernel.unprivileged_userns_clone = 1' | sudo tee -a /etc/sysctl.conf
```

**Common issues:**
- **"Operation not permitted"**: User namespaces disabled
- **"No space left on device"**: Too many mount points (increase `fs.mount-max`)

### macOS

**Requirements:**
- Xcode Command Line Tools
- `sandbox-exec` in PATH

**Install requirements:**
```bash
xcode-select --install
```

**Common issues:**
- **"sandbox-exec not found"**: Install Command Line Tools
- **"Operation not permitted"**: Check System Integrity Protection (SIP)

### Windows

Windows support is planned but not yet implemented. Builds will use fallback mode (validation only).

## Configuration Options

### Builderfile

```d
target("myapp") {
    hermetic: {
        // Enable/disable (default: true)
        enabled: true;
        
        // Additional input paths (read-only)
        inputs: ["/opt/tools", "/usr/local/lib"];
        
        // Output paths (write-only)
        outputs: ["dist/", "artifacts/"];
        
        // Temp paths (read-write)
        temps: ["/tmp/build-cache"];
        
        // Network policy
        network: {
            enabled: false;  // hermetic
            // OR
            allowHosts: ["github.com", "api.npmjs.org"];
        };
        
        // Resource limits
        resources: {
            memory: "4G";
            cpuTime: "1h";
            processes: 128;
        };
        
        // Process policy
        process: {
            maxChildren: 32;
            killOnParentExit: true;
        };
    }
}
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BUILDER_HERMETIC` | `true` | Enable/disable hermetic builds |
| `BUILDER_HERMETIC_NETWORK` | `false` | Allow network access |
| `BUILDER_HERMETIC_MEMORY` | `4G` | Memory limit |
| `BUILDER_HERMETIC_CPU_TIME` | `1h` | CPU time limit |
| `BUILDER_HERMETIC_PROCESSES` | `128` | Process limit |
| `BUILDER_HERMETIC_DEBUG` | `false` | Enable debug output |

## Best Practices

### 1. Minimize Inputs

Only add paths that are actually needed:

```d
// BAD: Too broad
inputs: ["/usr"];

// GOOD: Specific
inputs: ["/usr/lib/gcc", "/usr/include"];
```

### 2. Separate Inputs and Outputs

Never overlap input and output paths:

```d
// BAD: Overlapping paths
inputs: ["/workspace"];
outputs: ["/workspace/bin"];  // INVALID

// GOOD: Disjoint paths
inputs: ["/workspace/src"];
outputs: ["/workspace/bin"];
```

### 3. Use Temp Directories

For intermediate files, use temp paths:

```d
temps: ["/tmp/build"];  // Cleaned up automatically
```

### 4. Pre-fetch Dependencies

Don't rely on network during builds:

```bash
# Fetch dependencies first
builder deps fetch

# Then build hermetically
bldr build
```

### 5. Verify Reproducibility

Test that builds are truly reproducible:

```bash
# Build twice
bldr clean && bldr build
bldr clean && bldr build

# Compare outputs
diff -r bin-1/ bin-2/
```

## Advanced Usage

### Custom Sandbox Specs

For programmatic control:

```d
import core.execution.hermetic;

auto spec = SandboxSpecBuilder.create()
    .input(workspaceRoot)
    .output(outputDir)
    .temp(tempDir)
    .withNetwork(NetworkPolicy.hermetic())
    .withResources(ResourceLimits.hermetic())
    .build();

auto executor = HermeticExecutor.create(spec.unwrap());
auto result = executor.unwrap().execute(command);
```

### Multiple Build Stages

For multi-stage builds:

```d
target("stage1") {
    hermetic: {
        outputs: ["stage1/"];
    }
}

target("stage2") {
    deps: ["//stage1"];
    hermetic: {
        inputs: ["stage1/"];  // Output from stage1
        outputs: ["stage2/"];
    }
}
```

### Testing Hermetic Isolation

Verify that builds are truly isolated:

```d
import core.execution.hermetic;

unittest
{
    auto spec = /* ... */;
    auto executor = HermeticExecutor.create(spec.unwrap());
    
    // This should fail (no network)
    auto result = executor.unwrap().execute(["curl", "https://example.com"]);
    assert(result.isErr || !result.unwrap().success());
}
```

## Troubleshooting

### Build works locally but fails in CI

**Cause**: CI environment has stricter sandboxing

**Solution**: Test locally with same sandbox settings:
```bash
BUILDER_HERMETIC=true bldr build --verbose
```

### "Permission denied" errors

**Cause**: Missing input paths

**Solution**: Add required paths to `hermetic.inputs`:
```d
hermetic: {
    inputs: ["/usr/lib/missing-lib"];
}
```

### Slow builds with hermetic enabled

**Cause**: Namespace creation overhead

**Solutions:**
- Use caching (enabled by default)
- Pre-build dependencies
- Consider shared namespaces (future feature)

### Network errors during build

**Cause**: Hermetic builds block network by default

**Solutions:**
1. Pre-fetch dependencies: `bldr deps fetch`
2. Add dependencies to inputs
3. For testing only: `BUILDER_HERMETIC_NETWORK=true`

## FAQ

**Q: Do I need root privileges?**  
A: No, Builder uses user namespaces which don't require root.

**Q: Will hermetic builds slow down my builds?**  
A: Overhead is typically 5-30ms per build. Caching more than compensates for this.

**Q: Can I mix hermetic and non-hermetic targets?**  
A: Yes, configure per-target in Builderfile.

**Q: How does this compare to Docker?**  
A: Lighter weight (no image layers), faster startup (~10ms vs ~100ms), but less isolation.

**Q: Can I debug inside the sandbox?**  
A: Use `--hermetic-shell` to spawn an interactive shell inside the sandbox:
```bash
builder shell --hermetic
```

**Q: Are hermetic builds deterministic?**  
A: Yes, given the same inputs, you'll get the same outputs. But note:
- Timestamps may vary (use `SOURCE_DATE_EPOCH`)
- Random number generation needs seeding
- Concurrent execution may affect ordering

## See Also

- [Hermetic Builds Technical Documentation](../features/hermetic.md)
- [Security Best Practices](../security/security.md)
- [Distributed Builds](../features/distributed.md)
- [Caching System](../features/caching.md)

