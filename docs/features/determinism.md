# Deterministic Builds

## Overview

Deterministic builds ensure that the same source code produces bit-for-bit identical outputs, regardless of when or where the build runs. Builder provides determinism enforcement on top of hermetic isolation.

### Hermetic vs Deterministic

| Aspect | Hermetic | Deterministic |
|--------|----------|---------------|
| **Isolation** | Complete | Complete |
| **Same Inputs** | Controlled | Controlled |
| **Same Outputs** | Not guaranteed | Bit-for-bit identical |
| **Time handling** | System time | Fixed timestamp |
| **Random values** | System random | Seeded PRNG |
| **Thread scheduling** | Non-deterministic | Controlled |

## Common Non-Determinism Sources

Even with hermetic isolation, builds can produce different outputs due to:

1. **Timestamp embedding**: Compilers embedding build timestamps in binaries
2. **Random UUIDs**: Code generators creating random identifiers
3. **Compiler non-determinism**: Random register allocation, symbol ordering
4. **Thread scheduling**: Parallel builds producing different file ordering
5. **Build path leakage**: Absolute paths embedded in debug information
6. **Pointer addresses**: ASLR causing different memory layouts

## Architecture

The determinism module is located in `source/engine/runtime/hermetic/determinism/`:

```
determinism/
├── enforcer.d    # Main enforcement engine
├── detector.d    # Non-determinism source detection
├── verifier.d    # Output comparison and verification
├── repair.d      # Repair suggestion generation
├── integration.d # Build system integration
├── shim.c        # Syscall interception library
└── Makefile      # Shim library build
```

### Core Components

**DeterminismEnforcer** (`enforcer.d`):
- Wraps HermeticExecutor with determinism environment
- Sets fixed timestamps via SOURCE_DATE_EPOCH
- Configures single-threaded execution when needed
- Loads syscall interception shim via LD_PRELOAD

**NonDeterminismDetector** (`detector.d`):
- Analyzes compiler commands for missing determinism flags
- Detects timestamp and UUID patterns in output
- Supports GCC, Clang, Rust, Go, D, Java, Scala compilers

**Syscall Interception Shim** (`shim.c`):
- LD_PRELOAD library (Linux) / DYLD_INSERT_LIBRARIES (macOS)
- Intercepts `time()`, `random()`, `getpid()` syscalls
- Returns deterministic values based on environment variables

## Configuration

### DeterminismConfig

```d
struct DeterminismConfig {
    ulong fixedTimestamp = 1640995200;  // 2022-01-01 00:00:00 UTC
    uint prngSeed = 42;                 // Fixed PRNG seed
    bool normalizeTimestamps = true;    // Normalize output file timestamps
    bool deterministicThreading = true; // Force single-threaded execution
    string sourceEpoch;                 // SOURCE_DATE_EPOCH override
    bool strictMode = false;            // Fail on detected non-determinism
}
```

**Mode presets**:
- `DeterminismConfig.defaults()` — Warnings only
- `DeterminismConfig.strict()` — Fails on violations

### Environment Variables Set by Enforcer

```bash
SOURCE_DATE_EPOCH=1640995200   # Fixed timestamp
BUILD_TIMESTAMP=1640995200    # Alternative timestamp var
RANDOM_SEED=42                # PRNG seed

# Single-threaded execution (when deterministicThreading=true)
MAKEFLAGS=-j1
CARGO_BUILD_JOBS=1
GOMAXPROCS=1
```

## Usage

### Basic Enforcement

```d
import engine.runtime.hermetic.determinism.enforcer;
import engine.runtime.hermetic.core.executor;

// Create hermetic executor
auto spec = SandboxSpecBuilder.create()
    .input("/workspace/src")
    .output("/workspace/bin")
    .build();
auto executor = HermeticExecutor.create(spec.unwrap());

// Add determinism enforcement
auto config = DeterminismConfig.defaults();
auto enforcerResult = DeterminismEnforcer.create(executor.unwrap(), config);

// Execute with determinism
auto result = enforcerResult.unwrap().execute(
    ["gcc", "main.c", "-o", "main"],
    "/workspace"
);

if (result.isOk) {
    auto detResult = result.unwrap();
    writeln("Deterministic: ", detResult.deterministic);
    writeln("Output hash: ", detResult.outputHash);
}
```

### Multi-Run Verification

```d
// Execute and verify across multiple runs
auto result = enforcer.executeAndVerify(
    ["gcc", "main.c", "-o", "main"],
    "/workspace",
    iterations: 3
);

if (!result.unwrap().deterministic) {
    writeln("Build is non-deterministic");
    foreach (v; result.unwrap().violations)
        writeln("  - ", v.description);
}
```

### Compiler Command Analysis

```d
import engine.runtime.hermetic.determinism.detector;

auto command = ["gcc", "main.c", "-o", "main"];
auto detections = NonDeterminismDetector.analyzeCompilerCommand(
    command,
    CompilerType.GCC
);

foreach (d; detections) {
    writeln("Issue: ", d.description);
    writeln("  Flags: ", d.compilerFlags);
}
```

## Compiler-Specific Flags

### GCC / G++

```bash
# Random seed for register allocation
-frandom-seed=42

# Strip build paths from debug info
-ffile-prefix-map=/workspace/=./
-fdebug-prefix-map=/workspace/=./
```

### Clang / Clang++

```bash
# Strip build paths
-fdebug-prefix-map=/workspace/=./

# Override timestamp macros
-Wno-builtin-macro-redefined
-D__DATE__="Jan 01 2022"
-D__TIME__="00:00:00"
-D__TIMESTAMP__="Sat Jan 01 00:00:00 2022"
```

### Rust (rustc / cargo)

```bash
# Disable incremental compilation
-Cincremental=false

# Enable bitcode embedding
-Cembed-bitcode=yes
```

Or via `Cargo.toml`:
```toml
[profile.release]
codegen-units = 1
incremental = false
```

### Go

```bash
# Strip build paths
go build -trimpath
```

### D (DMD / LDC / GDC)

```bash
# Set SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH=1640995200

# GDC follows GCC flags
gdc -frandom-seed=42 -ffile-prefix-map=/workspace/=./
```

## Verification Strategies

The verifier supports multiple comparison methods:

| Strategy | Description | Use Case |
|----------|-------------|----------|
| `ContentHash` | BLAKE3 hash comparison (default) | Fast verification |
| `BitwiseCompare` | Byte-by-byte comparison | Thorough analysis |
| `Fuzzy` | Ignores timestamps/metadata | Known-variable outputs |
| `Structural` | Compares structure (ELF, archives) | Binary format analysis |

## Detection Capabilities

The `NonDeterminismDetector` identifies:

| Source | Description | Compilers |
|--------|-------------|-----------|
| `Timestamp` | Embedded timestamps | All |
| `RandomValue` | Random values/UUIDs | All |
| `CompilerNonDet` | Compiler-specific issues | GCC, Clang, Rust |
| `BuildPath` | Embedded build paths | GCC, Clang, Go |
| `ThreadScheduling` | Thread order dependency | All parallel builds |
| `OutputMismatch` | Hash mismatch across runs | N/A (detected by verifier) |

## Performance

| Operation | Overhead |
|-----------|----------|
| Syscall interception (shim) | ~1-2% |
| Hash verification | <100ms typical |
| Multi-run verification | Linear with iteration count |

## CLI Commands

```bash
# Build with determinism enforcement
bldr build --determinism=strict //main:app

# Verify determinism across runs
bldr verify-determinism //main:app --iterations=5
```

## Shim Library Installation

The syscall interception shim must be built:

```bash
cd source/engine/runtime/hermetic/determinism/
make
make install  # Installs to bin/

# Verify
ls bin/libdetshim.so   # Linux
ls bin/libdetshim.dylib  # macOS
```

If the shim is unavailable, enforcement continues with limited capability (environment variables only).

## Troubleshooting

### Outputs differ across runs

1. Run detector analysis:
   ```bash
   bldr detect-non-determinism //target:name
   ```

2. Check common issues:
   - Missing `-frandom-seed` (GCC)
   - Missing `-trimpath` (Go)
   - Incremental compilation enabled (Rust)
   - Parallel build ordering (`MAKEFLAGS=-j1`)

3. Set SOURCE_DATE_EPOCH for timestamp issues:
   ```bash
   export SOURCE_DATE_EPOCH=1640995200
   ```

### Shim library not found

The enforcer logs a warning but continues:
```
Determinism shim library not available: Shim library not found in search paths
Determinism enforcement will be limited
```

Build the shim per instructions above, or rely on environment variables.

## Limitations

1. **Shim platform support**: Currently Linux (LD_PRELOAD) and macOS (DYLD_INSERT_LIBRARIES) only
2. **Static builds**: Statically-linked binaries don't load the shim
3. **Compiler coverage**: Not all compiler non-determinism sources are detected

## See Also

- [Hermetic Builds](hermetic.md)
- [Action-Level Caching](caching.md)
- [Remote Execution](remote-execution.md)
- [Build Provenance](provenance.md)

## References

- [Reproducible Builds](https://reproducible-builds.org/)
- [SOURCE_DATE_EPOCH Spec](https://reproducible-builds.org/specs/source-date-epoch/)
- [diffoscope](https://diffoscope.org/) — Binary comparison tool
