# Deterministic Builds Architecture

## Overview

Builder implements deterministic builds through syscall interception, automatic non-determinism detection, and build output verification to ensure reproducible outputs for supply chain security and distributed build verification.

## Comparison with Existing Systems

| Feature | Bazel | Builder |
|---------|-------|---------|
| Hermetic Isolation | Sandboxfs/Docker | Native namespaces/sandbox-exec |
| Determinism | Partial (env vars) | Active enforcement via syscall interception |
| Detection | Manual | Automatic detection + repair suggestions |
| Verification | Manual comparison | Integrated multi-run verification |
| Compiler Flags | Manual config | Auto-detection + suggestions |

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                    HermeticExecutor                           │
│  ┌─────────────────────────────────────────────────────┐     │
│  │              SandboxSpec                             │     │
│  │  • Input paths (I)                                  │     │
│  │  • Output paths (O)                                 │     │
│  │  • Network policy (N)                               │     │
│  │  • Environment (E)                                  │     │
│  └─────────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌───────────────────────────────────────────────────────────────┐
│                 DeterminismEnforcer                           │
│  ┌─────────────────────────────────────────────────────┐     │
│  │         Determinism Configuration                    │     │
│  │  • Fixed timestamp (SOURCE_DATE_EPOCH)              │     │
│  │  • PRNG seed                                        │     │
│  │  • Thread determinism                               │     │
│  │  • Strict mode                                      │     │
│  └─────────────────────────────────────────────────────┘     │
│                                                               │
│  ┌─────────────────────────────────────────────────────┐     │
│  │         Syscall Interception Shim                    │     │
│  │  • LD_PRELOAD: libdetshim.so (Linux)                │     │
│  │  • DYLD_INSERT_LIBRARIES: libdetshim.dylib (macOS)  │     │
│  │  • Intercepts: time, random, getpid                 │     │
│  └─────────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
  ┌──────────────┐                    ┌──────────────┐
  │   Detector   │                    │   Verifier   │
  │              │                    │              │
  │ • Compiler   │                    │ • Hash-based │
  │   analysis   │                    │ • Bitwise    │
  │ • Pattern    │                    │ • Fuzzy      │
  │   matching   │                    │ • Structural │
  └──────────────┘                    └──────────────┘
```

## Core Types

### DeterminismConfig

```d
struct DeterminismConfig
{
    ulong fixedTimestamp = 1640995200;  // 2022-01-01 00:00:00 UTC
    uint prngSeed = 42;
    bool normalizeTimestamps = true;
    bool deterministicThreading = true;
    string sourceEpoch;
    bool strictMode = false;  // Fail on detected non-determinism
    
    static DeterminismConfig defaults() @safe pure nothrow;
    static DeterminismConfig strict() @safe pure nothrow;
}
```

### DeterminismEnforcer

```d
struct DeterminismEnforcer
{
    static BuildResult!DeterminismEnforcer create(
        HermeticExecutor executor,
        DeterminismConfig config = DeterminismConfig.defaults()
    );
    
    BuildResult!DeterminismResult execute(
        string[] command,
        string workingDir = ""
    );
    
    BuildResult!DeterminismResult executeAndVerify(
        string[] command,
        string workingDir = "",
        uint iterations = 3
    );
}
```

### NonDeterminismDetector

Analyzes compiler commands and build output for non-determinism sources:

```d
struct NonDeterminismDetector
{
    // Analyze compiler command
    static Detection[] analyzeCompilerCommand(
        string[] command,
        CompilerType compilerType = CompilerType.Unknown
    );
    
    // Analyze build output
    static Detection[] analyzeBuildOutput(string stdout, string stderr);
    
    // Compare outputs
    static Detection[] compareBuildOutputs(
        string hash1, string hash2, string[] files
    );
}
```

**Non-Determinism Sources**:
- `Timestamp` - Embedded timestamps
- `RandomValue` - Random values/UUIDs
- `ThreadScheduling` - Thread scheduling variations
- `BuildPath` - Absolute build paths
- `CompilerNonDet` - Compiler-specific issues
- `FileOrdering` - File system ordering
- `PointerAddress` - ASLR/pointer addresses
- `OutputMismatch` - Output hash mismatch

**Supported Compilers**: GCC, Clang, Rustc, Go, DMD, LDC, GDC, Javac, Scalac

### DeterminismVerifier

```d
struct DeterminismVerifier
{
    static DeterminismVerifier create(
        VerificationStrategy strategy = VerificationStrategy.ContentHash
    );
    
    BuildResult!VerificationResult verify(
        string[] outputPaths1,
        string[] outputPaths2
    );
    
    BuildResult!VerificationResult verifyDirectory(
        string dir1, string dir2
    );
    
    BuildResult!bool verifyFile(string path1, string path2);
}
```

**Verification Strategies**:

| Strategy | Description | Use Case |
|----------|-------------|----------|
| `ContentHash` | BLAKE3 hash comparison | Default, fast |
| `BitwiseCompare` | Byte-by-byte comparison | Debugging |
| `Fuzzy` | Ignore timestamps/metadata | Legacy builds |
| `Structural` | Archive/ELF-aware comparison | Debug builds |

## Compiler-Specific Rules

### GCC/GDC

```bash
-frandom-seed=<seed>          # Deterministic register allocation
-ffile-prefix-map=<old>=<new>  # Strip build paths from debug info
-fdebug-prefix-map=<old>=<new>
```

### Clang

```bash
-fdebug-prefix-map=<old>=<new>
-Wno-builtin-macro-redefined
-D__DATE__="Jan 01 2022"
-D__TIME__="00:00:00"
```

### Rust

```bash
-Cincremental=false       # Disable incremental compilation
-Cembed-bitcode=yes       # Improves determinism
```

### Go

```bash
-trimpath                 # Strip build paths from binaries
```

## Syscall Interception Shim

C library intercepting non-deterministic syscalls:

```c
// Override time() with fixed timestamp
time_t time(time_t *tloc) {
    static time_t fixed_time = 1640995200;  // From BUILD_TIMESTAMP env
    if (tloc) *tloc = fixed_time;
    return fixed_time;
}

// Override random() with seeded PRNG
long random(void) {
    static unsigned long state = 42;  // From RANDOM_SEED env
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    return state;
}

// Override getpid() with fixed PID
pid_t getpid(void) {
    return 12345;
}
```

**Loading** (Linux):
```bash
LD_PRELOAD=/path/to/libdetshim.so \
BUILD_TIMESTAMP=1640995200 \
RANDOM_SEED=42 \
./compiler main.c -o main
```

**Loading** (macOS):
```bash
DYLD_INSERT_LIBRARIES=/path/to/libdetshim.dylib \
BUILD_TIMESTAMP=1640995200 \
RANDOM_SEED=42 \
./compiler main.c -o main
```

## Environment Variables

The enforcer sets these environment variables automatically:

| Variable | Default | Purpose |
|----------|---------|---------|
| `SOURCE_DATE_EPOCH` | `1640995200` | Standard reproducible timestamp |
| `BUILD_TIMESTAMP` | `1640995200` | Build time for shim |
| `RANDOM_SEED` | `42` | PRNG seed for shim |
| `MAKEFLAGS` | `-j1` | Single-threaded make (if enabled) |
| `CARGO_BUILD_JOBS` | `1` | Single-threaded Cargo |
| `GOMAXPROCS` | `1` | Single-threaded Go |

## Metadata Stripping

The verifier can strip metadata from binary files for fuzzy comparison:

### ELF Files
- GNU build ID notes zeroed
- Debug section timestamps normalized

### Archive Files (.a)
- Timestamps zeroed (bytes 16-27)
- UID/GID zeroed (bytes 28-39)

### Mach-O Files
- LC_UUID zeroed
- LC_BUILD_VERSION timestamps zeroed
- LC_SOURCE_VERSION zeroed

### COFF/PE Files
- File header timestamp zeroed
- Optional header checksum zeroed

## Performance Overhead

| Operation | Overhead |
|-----------|----------|
| Syscall Interception | ~1-2% |
| Hash Verification | <100ms |
| Multi-run (3x) | 3x build time |
| Detection | <10ms |

## Security Considerations

**Protected Against**:
- Non-deterministic builds via syscall enforcement
- Build-time tampering via verification
- Compromised workers via cross-verification

**Not Protected Against**:
- Compiler backdoors
- Source code tampering
- Side-channel attacks

## Usage Example

```d
// Create hermetic executor
auto spec = HermeticSpecBuilder.forBuild(inputs, outputs).build().unwrap();
auto executor = HermeticExecutor.create(spec).unwrap();

// Create enforcer
auto config = DeterminismConfig.defaults();
auto enforcer = DeterminismEnforcer.create(executor, config).unwrap();

// Execute with verification
auto result = enforcer.executeAndVerify(
    ["gcc", "main.c", "-o", "main", "-frandom-seed=42"],
    workDir,
    3  // iterations
);

if (result.isOk && result.unwrap().deterministic)
    writeln("Build is deterministic");
```

## Source Files

| Component | File |
|-----------|------|
| Enforcer | `source/engine/runtime/hermetic/determinism/enforcer.d` |
| Detector | `source/engine/runtime/hermetic/determinism/detector.d` |
| Verifier | `source/engine/runtime/hermetic/determinism/verifier.d` |
| Repair | `source/engine/runtime/hermetic/determinism/repair.d` |
| Shim (C) | `source/engine/runtime/hermetic/determinism/shim.c` |

## References

- [Reproducible Builds](https://reproducible-builds.org/)
- [SOURCE_DATE_EPOCH Spec](https://reproducible-builds.org/specs/source-date-epoch/)
- [diffoscope](https://diffoscope.org/) - In-depth comparison tool
- [reprotest](https://salsa.debian.org/reproducible-builds/reprotest) - Reproducibility testing
