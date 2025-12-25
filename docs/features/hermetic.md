# Hermetic Builds

Hermetic builds ensure reproducibility and security by isolating build processes from the host system. Builder implements platform-specific sandboxing:

- **Linux**: Namespace isolation (mount, PID, network, IPC, UTS, user) + cgroup v2 resource control
- **macOS**: `sandbox-exec` with Sandbox Profile Language (SBPL)
- **Windows**: Job objects with resource limits and I/O accounting

## Architecture

**Location**: `source/engine/runtime/hermetic/`

```
hermetic/
├── core/
│   ├── executor.d      # HermeticExecutor - unified execution interface
│   └── spec.d          # SandboxSpec - set-theoretic specification
├── platforms/
│   ├── linux.d         # Linux namespace implementation
│   ├── macos.d         # macOS sandbox-exec implementation
│   ├── windows.d       # Windows job object implementation
│   └── capabilities.d  # Platform capability detection
├── monitoring/
│   ├── linux.d         # Linux cgroup v2 resource monitor
│   ├── macos.d         # macOS rusage monitor
│   └── windows.d       # Windows job object monitor
├── security/
│   ├── audit.d         # Violation logging
│   ├── seccomp.d       # Syscall filtering (Linux)
│   └── timeout.d       # Timeout enforcement
├── sandbox/
│   ├── namespaces.d    # Linux namespace sandbox
│   ├── cgroups.d       # Linux cgroup v2 integration
│   ├── darwin.d        # macOS Darwin sandbox
│   └── profiles.d      # SBPL profile generator
└── determinism/        # Determinism verification
```

### Set-Theoretic Specification

Hermetic builds are modeled using set theory:

- **Input Set (I)**: Paths that can be read
- **Output Set (O)**: Paths that can be written
- **Temp Set (T)**: Paths that can be read and written
- **Network Set (N)**: Allowed network operations
- **Environment Set (E)**: Allowed environment variables

**Hermeticity Invariants**:
1. `I ∩ O = ∅` (inputs and outputs are disjoint)
2. `N = ∅` for hermetic builds (no network access)
3. Same I → Same O (deterministic)

## Usage

### Basic Example

```d
import engine.runtime.hermetic;

// Create hermetic specification
auto specResult = SandboxSpecBuilder.create()
    .input("/workspace/src")
    .output("/workspace/bin")
    .temp("/tmp/build")
    .withNetwork(NetworkPolicy.hermetic())
    .env("PATH", "/usr/bin:/bin")
    .build();

if (specResult.isErr)
    return specResult.unwrapErr();

// Create executor
auto executorResult = HermeticExecutor.create(specResult.unwrap());
if (executorResult.isErr)
    return executorResult.unwrapErr();

// Execute hermetically
auto result = executorResult.unwrap().execute(
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

```d
// For builds
auto specResult = HermeticSpecBuilder.forBuild(
    workspaceRoot: "/workspace",
    sources: ["/workspace/src/main.d"],
    outputDir: "/workspace/bin",
    tempDir: "/tmp/build"
);

// For tests
auto specResult = HermeticSpecBuilder.forTest(
    workspaceRoot: "/workspace",
    testDir: "/workspace/tests",
    tempDir: "/tmp/test"
);
```

### Network Policy

```d
// Hermetic (no network)
.withNetwork(NetworkPolicy.hermetic())

// Allow specific hosts
.withNetwork(NetworkPolicy.allowHosts(["github.com", "api.example.com"]))
```

### Resource Limits

```d
// Default hermetic limits (4GB memory, 1 hour CPU, 128 processes)
.withResources(ResourceLimits.hermetic())

// Custom limits
auto limits = ResourceLimits();
limits.maxMemoryBytes = 2UL * 1024 * 1024 * 1024;  // 2GB
limits.maxCpuTimeMs = 30 * 60 * 1000;              // 30 minutes
limits.maxProcesses = 64;
.withResources(limits)
```

### Process Policy

```d
auto policy = ProcessPolicy.hermetic();
policy.maxChildren = 16;
policy.killOnParentExit = true;
.withProcess(policy)
```

## Resource Monitoring

```d
import engine.runtime.hermetic.monitoring;

// Create monitor
auto limits = ResourceLimits.hermetic();
auto monitor = createMonitor(limits);

monitor.start();

// Execute build...

// Get resource usage snapshot
auto usage = monitor.snapshot();
writeln("CPU time: ", usage.cpuTime);
writeln("Peak memory: ", usage.peakMemory);
writeln("Disk read: ", usage.diskRead);
writeln("Disk write: ", usage.diskWrite);

// Check violations
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

```d
import engine.runtime.hermetic.security.timeout;

auto enforcer = createTimeoutEnforcer(processId);
enforcer.start(5.minutes);

// Execute build...

if (enforcer.isTimedOut())
    writeln("Build timed out!");

enforcer.stop();
```

## Linux Implementation

### Namespace Isolation

Uses Linux namespaces via `clone()`:

1. **Mount Namespace** (CLONE_NEWNS): Filesystem isolation
   - Creates minimal tmpfs root
   - Bind-mounts input paths (read-only)
   - Bind-mounts output paths (read-write)
   - Mounts essential directories (proc, dev, sys)

2. **PID Namespace** (CLONE_NEWPID): Process isolation
   - Process sees only its descendants
   - PID 1 is the build process

3. **Network Namespace** (CLONE_NEWNET): Network isolation
   - No network interfaces for hermetic builds

4. **IPC Namespace** (CLONE_NEWIPC): IPC isolation
   - No shared memory with host

5. **UTS Namespace** (CLONE_NEWUTS): Hostname isolation

6. **User Namespace** (CLONE_NEWUSER): Privilege isolation
   - Maps root inside to non-root outside
   - No elevated privileges required

### Cgroups v2

Resource limits via cgroups:

```
/sys/fs/cgroup/builder/<uuid>/
├── memory.max          # Memory limit
├── cpu.weight          # CPU shares
└── pids.max            # Process limit
```

## macOS Implementation

### Sandbox Profile Language (SBPL)

Generates SBPL profiles for `sandbox-exec`:

```scheme
(version 1)
(deny default)

; Allow reading inputs
(allow file-read*
  (subpath "/workspace/src"))

; Allow writing outputs
(allow file-write*
  (subpath "/workspace/bin"))

; Deny network
(deny network*)

; Allow process operations
(allow process-fork)
(allow process-exec
  (literal "/usr/bin/gcc"))
```

Features:
- Deny-by-default
- Path matching: literal, subpath, regex
- Fine-grained network control
- Mach operation control

## Windows Implementation

Uses Windows Job Objects:

- `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`: Guaranteed cleanup
- `BREAKAWAY_OK` disabled: No process escape
- Memory/CPU/process limits
- UI restrictions (clipboard, desktop isolation)
- CPU rate limiting (Windows 8+)

Note: Does not provide filesystem/network isolation like Linux namespaces.

## Security Guarantees

### Filesystem Isolation
- Input files read-only
- Output containment to specified directories
- Temp files cleaned up
- Path traversal prevention via set membership

### Network Isolation
- Complete network isolation for hermetic builds
- Prevents dependency poisoning
- Ensures reproducibility

### Process Isolation
- Resource limits prevent DoS
- Child processes cannot escape sandbox
- Clean termination on parent exit

## Performance

| Platform | Overhead |
|----------|----------|
| Linux Namespaces | ~5-10ms |
| macOS sandbox-exec | ~20-30ms |
| Fallback (validation only) | 0ms |

## Configuration

### Environment Variables

```bash
# Enable hermetic builds (default: true on Linux/macOS)
BUILDER_HERMETIC=true

# Force disable
BUILDER_HERMETIC=false

# Resource limits
BUILDER_HERMETIC_MEMORY=2G
BUILDER_HERMETIC_CPU_TIME=1800s
BUILDER_HERMETIC_PROCESSES=64
```

### Builderfile

```d
target("myapp") {
    type: executable;
    sources: ["src/**/*.d"];
    
    hermetic: {
        enabled: true;
        network: false;
        memory: "4G";
        timeout: "1h";
    }
}
```

## Platform Detection

```d
writeln("Platform: ", HermeticExecutor.platform());
writeln("Supported: ", HermeticExecutor.isSupported());
```

Returns:
- `"linux-namespaces"` on Linux
- `"macos-sandbox"` on macOS
- `"windows-job"` on Windows
- `"fallback"` otherwise

## Troubleshooting

**Permission denied**:
- Ensure input paths are readable
- Check output directory exists and is writable

**Namespace not supported (Linux)**:
- Verify `/proc/self/ns/user` exists
- Enable user namespaces: `sudo sysctl kernel.unprivileged_userns_clone=1`

**sandbox-exec not found (macOS)**:
- Install Xcode Command Line Tools

## Related Documentation

- [Security](../security/security.md)
- [Distributed Builds](distributed.md)
- [Caching](caching.md)
- [Build Provenance](provenance.md)
