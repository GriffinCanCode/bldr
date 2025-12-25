# Hermetic Builds

## Overview

Builder implements hermetic builds using a set-theoretic specification system with platform-native sandboxing:

- **Formal Specification**: Mathematical model ensures hermeticity via set operations
- **Platform Optimization**: OS-specific isolation (Linux namespaces, macOS sandbox-exec)
- **Deny-by-Default**: No network access unless explicitly allowed
- **Composable Policies**: First-class values that can be combined

## Design

### Set-Theoretic Model

Builder specifies build isolation using mathematical sets:

```
Given:
  I = Input paths (read-only)
  O = Output paths (write-only)
  T = Temp paths (read-write)
  N = Network operations

Hermeticity requires:
  1. I ∩ O = ∅           (inputs and outputs disjoint)
  2. N = ∅               (no network access for hermetic builds)
  3. ∀ i ∈ I: f(i) ∈ O   (deterministic mapping)
```

This model enables:
- Compile-time validation of sandbox specs
- Set operations (union, intersection) for policy composition
- Automated testing via property-based testing

### Declarative Specification

**Location**: `source/engine/runtime/hermetic/core/spec.d`

```d
auto spec = SandboxSpecBuilder.create()
    .input("/workspace/src")   // I ∪ {/workspace/src}
    .output("/workspace/bin")  // O ∪ {/workspace/bin}
    .temp("/tmp/build")        // T ∪ {/tmp/build}
    .withNetwork(NetworkPolicy.hermetic());  // N = ∅

// Automatic validation: I ∩ O = ∅
auto validated = spec.build();  // Returns Result with validation
```

### Platform Abstraction

**Location**: `source/engine/runtime/hermetic/core/executor.d`

```d
auto executor = HermeticExecutor.create(spec);
auto result = executor.execute(command);

// Backend selection:
// Linux   -> namespaces
// macOS   -> sandbox-exec
// Windows -> job objects (process isolation only)
// Fallback -> validation only
```

## Implementation

### Core Types

**SandboxSpec** (`spec.d`):
```d
struct SandboxSpec
{
    PathSet inputs;          // Read-only paths
    PathSet outputs;         // Write-only paths
    PathSet temps;           // Read-write paths
    NetworkPolicy network;   // Network access control
    EnvSet environment;      // Environment variables
    ResourceLimits resources;// Memory, CPU, process limits
    ProcessPolicy process;   // Fork/exec restrictions
}
```

**PathSet**:
```d
struct PathSet
{
    string[] paths;
    
    bool contains(string path);     // Prefix matching
    PathSet union_(PathSet other);
    PathSet intersection(PathSet other);
    bool disjoint(PathSet other);
}
```

**NetworkPolicy**:
```d
struct NetworkPolicy
{
    bool isHermetic;      // Fully hermetic (no network)
    bool allowHttp;       // Allow HTTP
    bool allowHttps;      // Allow HTTPS
    bool allowDns;        // Allow DNS lookups
    string[] allowedHosts;// Whitelist of hosts
    
    static NetworkPolicy hermetic();
    static NetworkPolicy allowHosts(string[] hosts);
}
```

**ResourceLimits**:
```d
struct ResourceLimits
{
    ulong maxMemoryBytes;   // Memory limit
    ulong maxCpuTimeMs;     // CPU time limit
    uint maxProcesses;      // Process limit
    ulong maxFileSize;      // File size limit
    uint cpuShares;         // CPU weight
    uint maxOpenFiles;      // File descriptor limit
    
    static ResourceLimits hermetic();  // 4GB, 1 hour, 128 processes
}
```

### Linux: Namespace-Based Isolation

**Location**: `source/engine/runtime/hermetic/platforms/linux.d`

Namespace stack:
- User namespace: Maps UID 0 inside to current UID outside
- Mount namespace: Private mount tree with tmpfs root
- PID namespace: Process is PID 1 inside
- Network namespace: No network interfaces (hermetic)
- IPC namespace: Isolated shared memory
- UTS namespace: Custom hostname

Mount strategy:
1. Create minimal root (tmpfs)
2. Bind input paths (read-only)
3. Bind output paths (read-write)
4. Mount essential dirs (`/proc`, `/dev`, `/sys`)
5. Pivot root atomically

Seccomp-BPF filters block dangerous syscalls:
- `ptrace`, `process_vm_readv/writev` - Debug escape
- `mount`, `umount2`, `pivot_root` - Filesystem escape
- `setns`, `unshare` - Namespace escape
- `init_module`, `finit_module` - Kernel modules
- `reboot`, `kexec_load` - System takeover

### macOS: Sandbox Profile Language

**Location**: `source/engine/runtime/hermetic/platforms/macos.d`

Generates SBPL profiles dynamically:

```scheme
(version 1)
(deny default)

; Allow reading inputs
(allow file-read*
  (subpath "/workspace/src"))

; Allow writing outputs
(allow file-write*
  (subpath "/workspace/bin"))

; Allow system libraries
(allow file-read*
  (subpath "/usr/lib")
  (subpath "/System/Library"))

; Deny network (hermetic)
(deny network*)

; Allow process operations
(allow process-fork)
(allow process-exec
  (literal "/usr/bin/gcc"))
```

### Windows: Job Objects

**Location**: `source/engine/runtime/hermetic/platforms/windows.d`

Provides process-level isolation:
- `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` - Guaranteed cleanup
- `BREAKAWAY_OK` disabled - No process escape
- Memory/CPU/process limits
- UI restrictions

Note: Does not provide filesystem/network isolation like Linux namespaces.

## Usage

### Build Specification

```d
auto specResult = HermeticSpecBuilder.forBuild(
    "/workspace",           // Workspace root
    ["/workspace/src"],     // Sources
    "/workspace/bin",       // Output directory
    "/tmp/build"            // Temp directory
);

auto executor = HermeticExecutor.create(specResult.unwrap());
auto result = executor.execute(["gcc", "-o", "main", "main.c"]);

if (result.isOk && result.unwrap().success)
    writeln("Build succeeded");
```

### Test Specification

```d
auto specResult = HermeticSpecBuilder.forTest(
    "/workspace",           // Workspace root
    "/workspace/tests",     // Test directory
    "/tmp/test"             // Temp directory
);
```

### Custom Policies

```d
// Base hermetic policy
auto hermetic = SandboxSpecBuilder.create()
    .withNetwork(NetworkPolicy.hermetic())
    .withResources(ResourceLimits.hermetic());

// Extend for specific needs
auto buildPolicy = hermetic
    .input(workspaceRoot)
    .output(buildDir);

// Allow specific hosts for tests
auto testPolicy = hermetic
    .input(workspaceRoot)
    .temp(testDir)
    .withNetwork(NetworkPolicy.allowHosts(["api.test.com"]));
```

## Performance

Overhead breakdown:

| Operation | Linux | macOS | Fallback |
|-----------|-------|-------|----------|
| Spec creation | ~1μs | ~1μs | ~1μs |
| Spec validation | ~10μs | ~10μs | ~10μs |
| Executor creation | ~100μs | ~500μs | ~10μs |
| Namespace creation | ~2-5ms | N/A | N/A |
| Profile generation | N/A | ~5-10ms | N/A |
| Process execution | ~3-5ms | ~10-20ms | ~1ms |
| **Total overhead** | **5-10ms** | **20-30ms** | **<1ms** |

For typical builds:
- 100 C++ files: <1% overhead
- 1000 TypeScript files: <2.5% overhead

Overhead scales sub-linearly due to amortization.

## Security

### Threat Model

Assets protected:
- Source code (confidentiality)
- Build outputs (integrity)
- Host system (isolation)

Mitigations:

| Threat | Mitigation | Mechanism |
|--------|-----------|-----------|
| Network exfiltration | Network namespace | No interfaces |
| Filesystem read | Mount namespace | Read-only binds |
| Filesystem write | Mount namespace | Restricted writes |
| Resource exhaustion | cgroups | Configurable limits |
| Privilege escalation | User namespace + seccomp | No real root |
| Process escape | PID namespace + seccomp | ptrace blocked |

### Limitations

1. Relies on kernel namespace implementation
2. Timing/cache side channels not addressed
3. Metadata (file sizes, timestamps) visible
4. No guarantees on CPU/memory scheduling fairness

## Platform Support

| Platform | Status | Isolation Level |
|----------|--------|-----------------|
| Linux | Full | Filesystem + Network + Process |
| macOS | Full | Filesystem + Network + Process |
| Windows | Partial | Process only |
| Other | Fallback | Validation only |

Check support at runtime:
```d
if (HermeticExecutor.isSupported())
    writeln("Platform: ", HermeticExecutor.platform());
```

## Testing

Unit tests:
- Spec validation and hermeticity constraints
- Set operations (union, intersection, disjoint)
- Path containment (exact, prefix, negative)

Integration tests:
- Execution succeeds
- Network/filesystem access denied
- Resource limits enforced
- Graceful error handling

Property-based tests:
```d
@property
void testHermeticityInvariant(PathSet inputs, PathSet outputs)
{
    assume(inputs.disjoint(outputs));
    auto spec = SandboxSpecBuilder.create()
        .inputs(inputs)
        .outputs(outputs)
        .build();
    assert(spec.isOk);
}
```

## References

- [Linux Namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- [cgroups v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
- [macOS Sandbox](https://developer.apple.com/library/archive/documentation/Security/Conceptual/AppSandboxDesignGuide/)
