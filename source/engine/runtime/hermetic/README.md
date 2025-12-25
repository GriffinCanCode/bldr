# Hermetic Execution System

The hermetic execution system provides platform-specific sandboxing for reproducible builds and secure process execution.

## Overview

This module implements a cross-platform abstraction for hermetic execution, ensuring builds are:

- **Reproducible**: Same inputs → Same outputs
- **Isolated**: Controlled filesystem, network, and process access
- **Secure**: Sandboxed execution with resource limits
- **Auditable**: Comprehensive logging of violations

## Architecture

The module is organized into four main components:

### 1. Core (`core/`)

Core abstractions and coordination logic:

- **`executor.d`**: Main `HermeticExecutor` interface and unified execution API
- **`spec.d`**: `SandboxSpec` definition using set theory for formal hermeticity guarantees

The spec models allowed operations as mathematical sets:
- Input set I (read-only)
- Output set O (write-only)  
- Temp set T (read-write)
- Network set N (allowed hosts)
- Environment set E (allowed vars)

Hermeticity constraint: I ∩ O = ∅ (disjoint input/output)

### 2. Platforms (`platforms/`)

Platform-specific sandbox implementations:

- **`linux.d`**: Linux namespace-based isolation (mount, PID, network, IPC, UTS, user namespaces + cgroup v2)
- **`macos.d`**: macOS sandbox-exec with SBPL (Sandbox Profile Language) profiles
- **`windows.d`**: Windows job objects with resource limits and I/O accounting

Each platform provides strong isolation guarantees appropriate for the OS.

### 3. Monitoring (`monitoring/`)

Resource usage monitoring and enforcement:

- **`package.d`**: Platform-agnostic `ResourceMonitor` interface
- **`linux.d`**: Linux cgroup-based monitoring
- **`macos.d`**: macOS rusage and Mach task_info monitoring
- **`windows.d`**: Windows job object accounting

Monitors track CPU time, memory usage, I/O operations, and enforce limits.

### 4. Security (`security/`)

Security and compliance features:

- **`audit.d`**: Audit logging for sandbox violations (filesystem, network, process creation)
- **`timeout.d`**: Timeout enforcement to prevent hanging builds
- **`seccomp.d`**: Seccomp-BPF syscall filtering (Linux only)

## Usage

### Basic Example

```d
import engine.runtime.hermetic;

// Create sandbox specification
auto spec = HermeticSpecBuilder.forBuild(
    workspaceRoot: "/workspace",
    sources: ["/workspace/src"],
    outputDir: "/workspace/bin",
    tempDir: "/tmp/build"
).unwrap();

// Create executor
auto executor = HermeticExecutor.create(spec).unwrap();

// Execute command hermetically
auto result = executor.execute(["gcc", "main.c", "-o", "main"]).unwrap();

if (result.success()) {
    writeln("Build succeeded!");
    writeln("Output: ", result.stdout);
}
```

### With Monitoring

```d
import engine.runtime.hermetic;

auto spec = HermeticSpecBuilder.forBuild(...).unwrap();
auto executor = HermeticExecutor.create(spec).unwrap();

// Create monitor
auto monitor = createMonitor(spec.resources);
monitor.start();

// Execute
auto result = executor.execute(["make", "all"]).unwrap();

// Get resource usage
auto usage = monitor.snapshot();
writeln("Peak memory: ", usage.peakMemory);
writeln("CPU time: ", usage.cpuTime);

monitor.stop();
```

### With Timeout

```d
import engine.runtime.hermetic;
import std.datetime : seconds;

auto spec = HermeticSpecBuilder.forBuild(...).unwrap();
auto executor = HermeticExecutor.create(spec).unwrap();

// Execute with 60-second timeout
auto result = executor.executeWithTimeout(
    ["long-running-command"],
    60.seconds
).unwrap();
```

### Custom Sandbox Specification

```d
import engine.runtime.hermetic;

// Build custom spec
auto builder = SandboxSpecBuilder.create()
    .input("/usr/lib")           // Read-only access
    .output("/workspace/output")  // Write-only access
    .temp("/tmp/scratch")         // Read-write temp
    .env("PATH", "/usr/bin:/bin")
    .env("LANG", "C.UTF-8")
    .withNetwork(NetworkPolicy.hermetic())  // No network
    .withResources(ResourceLimits.hermetic());

auto spec = builder.build().unwrap();
```

## Platform Support

| Platform | Isolation | Resource Limits | Network Isolation | Syscall Filter | Status |
|----------|-----------|-----------------|-------------------|----------------|--------|
| Linux    | Namespaces + cgroups v2 | ✅ Memory, CPU, Processes | ✅ Full | ✅ seccomp-BPF | Production |
| macOS    | sandbox-exec (SBPL) | ⚠️ Via rusage | ✅ Full | ❌ N/A | Production |
| Windows  | Job Objects | ✅ Memory, CPU, Processes | ❌ Partial | ❌ N/A | Beta |

### Seccomp-BPF Filtering (Linux)

On Linux, the sandbox includes seccomp-BPF syscall filtering to prevent sandbox escapes:

| Category | Blocked Syscalls | Risk Mitigated |
|----------|------------------|----------------|
| Process manipulation | `ptrace`, `process_vm_readv/writev` | Escape via debugging |
| Mount operations | `mount`, `umount2`, `pivot_root` | Filesystem namespace escape |
| Execution domain | `personality` | Bypass ASLR, change ABI |
| Namespace escape | `setns`, `unshare` | Namespace juggling attacks |
| Kernel modules | `init_module`, `finit_module`, `delete_module` | Kernel compromise |
| System control | `reboot`, `kexec_load` | Full system access |
| Clock manipulation | `clock_settime`, `settimeofday` | Break determinism |
| BPF manipulation | `bpf` | Modify/bypass our filter |

Violations result in immediate `SIGKILL` - the process is terminated without the ability to catch the signal.

## Design Principles

1. **Deny by Default**: All operations are denied unless explicitly allowed
2. **Formal Verification**: Specs use set theory for provable correctness
3. **Platform Abstraction**: Unified API across all platforms
4. **Defense in Depth**: Multiple layers (filesystem, network, process, resources)
5. **Fail Secure**: Violations cause immediate termination
6. **Zero Trust**: Even within sandbox, minimal privileges

## Testing

The hermetic system includes comprehensive unit tests:

```bash
# Run hermetic tests
cd tests/unit
dmd -unittest -main hermetic_test.d
./hermetic_test
```

## Related Documentation

- [Hermetic Build Architecture](../../../../docs/architecture/hermetic.md)
- [Security Design](../../../../docs/security/security.md)
- [Testing Guide](../../../../docs/user-guides/testing.md)

## Contributing

When adding new features:

1. Maintain platform parity where possible
2. Add unit tests for new functionality
3. Update this README with new capabilities
4. Follow the Result pattern for error handling
5. Document security implications

## License

See LICENSE file in project root.

