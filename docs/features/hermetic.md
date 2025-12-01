# Hermetic Builds

**Status:** ✅ **PRODUCTION READY** - All platforms supported with resource monitoring

## Overview

Hermetic builds ensure reproducibility and security by isolating build processes from the host system. Builder implements platform-specific sandboxing to achieve true hermetic execution:

- **Linux**: Namespace-based isolation (mount, PID, network, IPC, UTS, user) + cgroup v2 resource monitoring
- **macOS**: `sandbox-exec` with Sandbox Profile Language (SBPL) + rusage resource monitoring
- **Windows**: Job objects with resource limits + I/O accounting

## Architecture

### Set-Theoretic Specification

Hermetic builds are modeled using set theory for provable correctness:

- **Input Set (I)**: Paths that can be read
- **Output Set (O)**: Paths that can be written
- **Temp Set (T)**: Paths that can be read and written
- **Network Set (N)**: Allowed network operations
- **Environment Set (E)**: Allowed environment variables

**Hermeticity Invariants:**
1. `I ∩ O = ∅` (inputs and outputs are disjoint)
2. `N = ∅` (no network access for hermetic builds)
3. `Same I → Same O` (deterministic builds)

### Components

```
hermetic/
├── spec.d          # Sandbox specification (set theory model)
├── executor.d      # Platform-agnostic execution interface
├── monitor.d       # Unified resource monitoring interface
├── timeout.d       # Timeout enforcement
├── audit.d         # Violation logging and tracking
├── linux.d         # Linux namespace implementation
├── macos.d         # macOS sandbox-exec implementation
├── windows.d       # Windows job object implementation
├── monitor/
│   ├── linux.d     # Linux cgroup v2 resource monitor
│   ├── macos.d     # macOS rusage resource monitor
│   └── windows.d   # Windows job object resource monitor
└── package.d       # Public API
```

## Usage

### Basic Example

```d
import core.execution.hermetic;

// Create hermetic specification
auto spec = SandboxSpecBuilder.create()
    .input("/workspace/src")        // Read source files
    .output("/workspace/bin")       // Write output files
    .temp("/tmp/build")             // Temp directory
    .withNetwork(NetworkPolicy.hermetic())  // No network
    .env("PATH", "/usr/bin:/bin")   // Minimal environment
    .build();

// Create executor
auto executor = HermeticExecutor.create(spec.unwrap());

// Execute hermetically
auto result = executor.unwrap().execute(
    ["gcc", "main.c", "-o", "main"],
    "/workspace/src"
);

if (result.isOk)
{
    auto output = result.unwrap();
    writeln("Exit code: ", output.exitCode);
    writeln("Hermetic: ", output.hermetic);
}
```

### Builder Helpers

For common scenarios, use pre-configured builders:

```d
// For builds
auto buildSpec = HermeticSpecBuilder.forBuild(
    workspaceRoot: "/workspace",
    sources: ["/workspace/src/main.d"],
    outputDir: "/workspace/bin",
    tempDir: "/tmp/build"
);

// For tests
auto testSpec = HermeticSpecBuilder.forTest(
    workspaceRoot: "/workspace",
    testDir: "/workspace/tests",
    tempDir: "/tmp/test"
);
```

### Advanced Configuration

#### Network Access

```d
// Completely hermetic (no network)
.withNetwork(NetworkPolicy.hermetic())

// Allow specific hosts
.withNetwork(NetworkPolicy.allowHosts(["github.com", "api.example.com"]))
```

#### Resource Limits

```d
// Hermetic defaults (4GB memory, 1 hour CPU, 128 processes)
.withResources(ResourceLimits.hermetic())

// Custom limits
auto limits = ResourceLimits();
limits.maxMemoryBytes = 2 * 1024 * 1024 * 1024;  // 2GB
limits.maxCpuTimeMs = 30 * 60 * 1000;  // 30 minutes
limits.maxProcesses = 64;

.withResources(limits)
```

#### Process Policy

```d
auto policy = ProcessPolicy.hermetic();
policy.maxChildren = 16;
policy.killOnParentExit = true;

.withProcess(policy)
```

### Resource Monitoring

Builder provides comprehensive resource monitoring across all platforms:

```d
import core.execution.hermetic;

// Create monitor
auto limits = ResourceLimits.hermetic();
auto monitor = createMonitor(limits);

// Start monitoring
monitor.start();

// Execute your build...

// Get resource usage snapshot
auto usage = monitor.snapshot();
writeln("CPU time: ", usage.cpuTime);
writeln("Peak memory: ", usage.peakMemory);
writeln("Disk read: ", usage.diskRead);
writeln("Disk write: ", usage.diskWrite);

// Stop monitoring and check violations
monitor.stop();
if (monitor.isViolated())
{
    foreach (violation; monitor.violations())
    {
        writeln("Violation: ", violation.message);
        writeln("  Actual: ", violation.actual);
        writeln("  Limit: ", violation.limit);
    }
}
```

### Timeout Enforcement

Prevent builds from hanging indefinitely:

```d
import core.execution.hermetic.timeout;

// Create timeout enforcer with PID
auto enforcer = createTimeoutEnforcer(processId);
enforcer.start(5.minutes);

// Execute build...

// Check if timeout occurred
if (enforcer.isTimedOut())
{
    writeln("Build timed out!");
}

enforcer.stop();
```

## Linux Implementation

### Namespace Isolation

Builder uses Linux namespaces for strong isolation:

1. **Mount Namespace**: Controls filesystem visibility
   - Creates minimal tmpfs root
   - Bind-mounts input paths (read-only)
   - Bind-mounts output paths (read-write)
   - Mounts essential directories (proc, dev, sys)

2. **PID Namespace**: Isolates process tree
   - Process sees only its own descendants
   - PID 1 is the build process

3. **Network Namespace**: Disables network access
   - No network interfaces (hermetic)
   - Complete network isolation

4. **IPC Namespace**: Isolates inter-process communication
   - No shared memory with host
   - No message queues accessible

5. **UTS Namespace**: Isolates hostname
   - Build sees custom hostname
   - Cannot query host identity

6. **User Namespace**: Maps root inside to non-root outside
   - No elevated privileges required
   - Safe execution as "root" inside namespace

### Cgroups Integration

Resource limits enforced via cgroups v2:

```
/sys/fs/cgroup/builder/<uuid>/
├── memory.max          # Memory limit
├── cpu.weight          # CPU shares
└── pids.max            # Process limit
```

### Example

```d
version(linux)
{
    import core.execution.hermetic.linux;
    
    auto sandbox = LinuxSandbox.create(spec, workDir);
    auto output = sandbox.unwrap().execute(command, workingDir);
}
```

## macOS Implementation

### Sandbox Profile Language (SBPL)

Builder generates SBPL profiles for `sandbox-exec`:

```scheme
(version 1)
(deny default)  ; Deny by default

; Allow reading inputs
(allow file-read*
  (subpath "/workspace/src"))

; Allow writing outputs
(allow file-write*
  (subpath "/workspace/bin"))

; Deny network (hermetic)
(deny network*)

; Allow essential operations
(allow process-fork)
(allow process-exec
  (literal "/usr/bin/gcc"))
```

### Features

- **Deny-by-default**: All operations denied unless explicitly allowed
- **Path matching**: Supports literal, subpath, and regex patterns
- **Network control**: Fine-grained network access control
- **Mach operations**: Controls IPC and system services

### Example

```d
version(OSX)
{
    import core.execution.hermetic.macos;
    
    auto sandbox = MacOSSandbox.create(spec);
    auto output = sandbox.unwrap().execute(command, workingDir);
}
```

## Security Guarantees

### Filesystem Isolation

- **Input Protection**: Source files are read-only, preventing accidental modification
- **Output Containment**: Build outputs confined to specified directories
- **No Temp Leaks**: Temporary files cleaned up automatically
- **Path Traversal Prevention**: Set membership checks prevent escaping

### Network Isolation

- **Hermetic Builds**: Complete network isolation (no outbound connections)
- **Dependency Poisoning Prevention**: Cannot fetch unexpected dependencies
- **Reproducibility**: Same inputs always produce same outputs

### Process Isolation

- **Resource Limits**: Prevents resource exhaustion (DoS)
- **Process Tree Containment**: Child processes cannot escape sandbox
- **Clean Termination**: All processes killed on parent exit

### Threat Model

**Mitigated Threats:**
- Supply chain attacks (network isolation)
- Resource exhaustion (cgroups limits)
- Privilege escalation (user namespace mapping)
- Filesystem tampering (mount namespace isolation)

**Residual Risks:**
- Kernel vulnerabilities (relies on kernel sandbox)
- Side-channel attacks (timing, speculation)
- Resource-based side channels

## Performance

### Overhead

- **Linux Namespaces**: ~5-10ms overhead per build
- **macOS sandbox-exec**: ~20-30ms overhead per build
- **Fallback (no sandbox)**: 0ms overhead

### Optimization Strategies

1. **Lazy Mounting**: Only mount required paths
2. **Shared Namespaces**: Reuse namespaces across builds (future)
3. **Cached Profiles**: Cache SBPL profiles for macOS (future)
4. **Minimal Environment**: Reduce environment variable copying

## Integration

### Execution Engine

Hermetic execution integrates with the build graph:

```d
// In ExecutionEngine
auto sandbox = createSandbox(hermetic: true);
auto env = sandbox.prepare(request, inputs);
auto result = env.unwrap().execute(command, envVars, timeout);
```

### Language Handlers

Language handlers can opt into hermetic builds:

```d
// In language handler
auto spec = HermeticSpecBuilder.forBuild(
    config.root,
    target.sources,
    outputDir,
    tempDir
);

auto executor = HermeticExecutor.create(spec.unwrap());
auto result = executor.unwrap().execute(buildCommand);
```

## Configuration

### Environment Variables

```bash
# Enable hermetic builds (default: true on Linux/macOS)
BUILDER_HERMETIC=true

# Force disable hermetic builds
BUILDER_HERMETIC=false

# Set resource limits
BUILDER_HERMETIC_MEMORY=2G
BUILDER_HERMETIC_CPU_TIME=1800s
BUILDER_HERMETIC_PROCESSES=64
```

### Builderfile

```d
target("myapp") {
    type: executable;
    sources: ["src/**/*.d"];
    
    // Hermetic configuration
    hermetic: {
        enabled: true;
        network: false;
        memory: "4G";
        timeout: "1h";
    }
}
```

## Debugging

### Check Platform Support

```d
writeln("Platform: ", HermeticExecutor.platform());
writeln("Supported: ", HermeticExecutor.isSupported());
```

### Verify Isolation

```bash
# Linux: Check namespaces
ls /proc/self/ns/

# macOS: Check sandbox-exec availability
which sandbox-exec

# Test network isolation
bldr build --hermetic --verbose
```

### Troubleshooting

**Build fails with "Permission denied":**
- Ensure input paths are readable
- Check that output directory exists and is writable

**Build fails with "Namespace not supported":**
- Verify `/proc/self/ns/user` exists (Linux)
- Check kernel supports user namespaces
- Try `sudo sysctl kernel.unprivileged_userns_clone=1`

**macOS builds fail with "sandbox-exec not found":**
- Install Xcode Command Line Tools
- Verify `sandbox-exec` is in PATH

## Future Enhancements

### Planned Features

1. **Windows Support**: Job objects + AppContainer
2. **Shared Namespaces**: Reuse namespaces for faster builds
3. **Network Whitelisting**: Allow specific hosts/ports
4. **Capability-based Security**: Fine-grained permission model
5. **Audit Logging**: Track all sandbox violations

### Research Areas

- **Formal Verification**: Prove hermeticity guarantees
- **Zero-Trust Builds**: Cryptographic verification of inputs
- **Hardware Isolation**: SGX/TrustZone support
- **Content-Addressable Storage**: Deduplicate inputs/outputs

## References

- [Linux Namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- [Cgroups v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [macOS Sandbox](https://developer.apple.com/library/archive/documentation/Security/Conceptual/AppSandboxDesignGuide/)
- [Bazel Remote Execution](https://docs.bazel.build/versions/main/remote-execution.html)
- [Nix Store Model](https://nixos.org/manual/nix/stable/#sec-nix-store)

## See Also

- [Security Documentation](../security/security.md)
- [Distributed Builds](distributed.md)
- [Caching System](caching.md)

