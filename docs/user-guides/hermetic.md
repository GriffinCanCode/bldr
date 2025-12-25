# Hermetic Builds

## Overview

Hermetic builds ensure reproducibility by isolating builds from the host environment. Builder provides platform-specific sandboxing:

- **Linux**: Namespace isolation (mount, PID, network, IPC, UTS, user) + cgroups v2
- **macOS**: sandbox-exec with SBPL profiles
- **Windows**: Fallback mode (validation only, sandboxing planned)

## Quick Start

Hermetic builds are enabled by default on Linux and macOS.

```bash
bldr build --verbose
# Look for: [INFO] Hermetic builds: enabled (linux-namespaces)
```

### Disable Hermetic Builds

```bash
# One-time
BUILDER_HERMETIC=false bldr build

# Permanently
echo 'BUILDER_HERMETIC=false' >> .builderrc
```

## Configuration

### Builderfile

```d
target("myapp") {
    hermetic: {
        // Enable/disable (default: true)
        enabled: true;
        
        // Input paths (read-only)
        inputs: ["/opt/tools", "/usr/local/lib"];
        
        // Output paths (write-only)
        outputs: ["dist/", "artifacts/"];
        
        // Temp paths (read-write, cleaned on completion)
        temps: ["/tmp/build-cache"];
        
        // Network policy
        network: {
            enabled: false;  // hermetic (default)
            // OR for non-hermetic:
            // allowHosts: ["github.com", "api.npmjs.org"];
        };
        
        // Resource limits
        resources: {
            memory: "4G";
            cpuTime: "1h";
            processes: 128;
            openFiles: 512;
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
| `BUILDER_HERMETIC` | `true` | Enable hermetic builds |
| `BUILDER_HERMETIC_DEBUG` | `false` | Enable debug output |

## Platform Details

### Linux

**Requirements:**
- Kernel 3.8+ (user namespaces)
- Kernel 3.5+ (seccomp-BPF)

**Isolation layers:**
- Namespace isolation (mount, PID, network, IPC, UTS, user)
- Cgroups v2 resource limits
- Seccomp-BPF syscall filtering

**Enable unprivileged user namespaces:**
```bash
sudo sysctl kernel.unprivileged_userns_clone=1

# Permanent
echo 'kernel.unprivileged_userns_clone = 1' | sudo tee -a /etc/sysctl.conf
```

**Common issues:**
- "Operation not permitted" — User namespaces disabled
- "No space left on device" — Too many mount points (increase `fs.mount-max`)

### macOS

**Requirements:**
- Xcode Command Line Tools
- `sandbox-exec` available

**Install requirements:**
```bash
xcode-select --install
```

**Common issues:**
- "sandbox-exec not found" — Install Command Line Tools
- "Operation not permitted" — Check System Integrity Protection (SIP)

### Windows

Windows sandboxing is planned. Currently uses fallback mode with validation only.

## Programmatic Usage

```d
import engine.runtime.hermetic;

// Build spec using fluent API
auto spec = SandboxSpecBuilder.create()
    .input(workspaceRoot)
    .output(outputDir)
    .temp(tempDir)
    .withNetwork(NetworkPolicy.hermetic())
    .env("PATH", "/usr/bin:/bin")
    .build();

// Create executor
auto executor = HermeticExecutor.create(spec.unwrap());
if (executor.isErr)
{
    writeln("Error: ", executor.unwrapErr());
    return;
}

// Execute command
auto result = executor.unwrap().execute(["gcc", "main.c", "-o", "main"]);
if (result.isOk)
{
    auto output = result.unwrap();
    writeln("Exit code: ", output.exitCode);
    writeln("Hermetic: ", output.hermetic);
}
```

### Sandbox Specification Types

**PathSet** — Read/write path sets with prefix matching:
- `inputs` — Read-only paths
- `outputs` — Write-only paths  
- `temps` — Read-write paths

**NetworkPolicy**:
```d
NetworkPolicy.hermetic()              // No network access
NetworkPolicy.allowHosts(["host"])    // Whitelist specific hosts
```

**ResourceLimits**:
```d
ResourceLimits limits;
limits.maxMemoryBytes = 4UL * 1024 * 1024 * 1024;  // 4GB
limits.maxCpuTimeMs = 60 * 60 * 1000;              // 1 hour
limits.maxProcesses = 128;
limits.maxOpenFiles = 512;
```

**ProcessPolicy**:
```d
ProcessPolicy policy;
policy.maxChildren = 32;
policy.killOnParentExit = true;
```

## Best Practices

### 1. Minimize Inputs

Only add necessary paths:

```d
// Avoid
inputs: ["/usr"];

// Prefer
inputs: ["/usr/lib/gcc", "/usr/include"];
```

### 2. Separate Inputs and Outputs

Never overlap input and output paths:

```d
// Invalid (paths overlap)
inputs: ["/workspace"];
outputs: ["/workspace/bin"];

// Valid (disjoint paths)
inputs: ["/workspace/src"];
outputs: ["/workspace/bin"];
```

### 3. Use Temp Directories

For intermediate files:

```d
temps: ["/tmp/build"];  // Cleaned automatically
```

### 4. Pre-fetch Dependencies

Don't rely on network during builds:

```bash
bldr deps fetch    # Fetch first
bldr build         # Then build hermetically
```

### 5. Verify Reproducibility

```bash
bldr clean && bldr build
mv bin bin-1

bldr clean && bldr build
mv bin bin-2

diff -r bin-1 bin-2
```

## Debugging

### Check Available Paths

```bash
bldr build --hermetic-debug
```

### Run Without Sandbox

```bash
BUILDER_HERMETIC=false bldr build
```

If it works without hermetic mode, you're accessing unspecified paths. Check error messages for "Permission denied" or "No such file".

## FAQ

**Q: Do I need root privileges?**  
A: No, Builder uses user namespaces which don't require root.

**Q: Will hermetic builds slow down my builds?**  
A: Overhead is typically 5-30ms per build. Caching compensates for this.

**Q: Can I mix hermetic and non-hermetic targets?**  
A: Yes, configure per-target in Builderfile.

**Q: How does this compare to Docker?**  
A: Lighter weight (no image layers), faster startup (~10ms vs ~100ms), but less isolation.

**Q: Are hermetic builds deterministic?**  
A: Yes, given the same inputs. Note:
- Timestamps may vary (use `SOURCE_DATE_EPOCH`)
- Random number generation needs seeding
- Concurrent execution may affect ordering

## See Also

- [Hermetic Architecture](../architecture/hermetic.md)
- [Reproducibility Verification](../features/reproducibility-verification.md)
