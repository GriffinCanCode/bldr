# Deterministic Builds Beyond Hermeticity

## Overview

Deterministic builds ensure that the same source code always produces bit-for-bit identical outputs, regardless of when or where the build is performed. While hermetic builds provide isolation, they don't guarantee determinism. Builder goes beyond hermeticity with active determinism enforcement.

### Hermetic vs Deterministic

| Aspect | Hermetic | Deterministic |
|--------|----------|---------------|
| **Isolation** | ✅ Complete | ✅ Complete |
| **Same Inputs** | ✅ Controlled | ✅ Controlled |
| **Same Outputs** | ❌ Not guaranteed | ✅ Bit-for-bit identical |
| **Time handling** | System time | Fixed timestamp |
| **Random values** | System random | Seeded PRNG |
| **Thread scheduling** | Non-deterministic | Controlled/single-threaded |

## The Problem

Even with perfect hermetic isolation, builds can be non-deterministic due to:

1. **Timestamp Embedding**: Compilers embedding build timestamps in binaries
2. **Random UUIDs**: Code generators creating random identifiers
3. **Compiler Non-determinism**: Random register allocation, symbol ordering
4. **Thread Scheduling**: Parallel builds producing different file ordering
5. **Build Path Leakage**: Absolute paths embedded in debug information
6. **Pointer Addresses**: ASLR causing different memory layouts

## Architecture

Builder's determinism system consists of four components:

```
┌─────────────────────────────────────────────────────────┐
│                  DeterminismEnforcer                    │
│  ┌─────────────────────────────────────────────────┐   │
│  │         Syscall Interception Shim               │   │
│  │  • time() → fixed timestamp                     │   │
│  │  • random() → seeded PRNG                       │   │
│  │  • getpid() → fixed PID                        │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
  ┌──────────────┐                    ┌───────────────┐
  │   Detector   │                    │   Verifier    │
  │ (Automatic)  │                    │ (Hash-based)  │
  └──────────────┘                    └───────────────┘
         │                                    │
         └────────────┬───────────────────────┘
                      ▼
              ┌───────────────┐
              │ RepairEngine  │
              │ (Suggestions) │
              └───────────────┘
```

### Components

1. **DeterminismEnforcer** (`source/engine/runtime/hermetic/determinism/enforcer.d`)
   - Main enforcement engine
   - Integrates with HermeticExecutor
   - Configures syscall interception
   - Manages verification runs

2. **NonDeterminismDetector** (`source/engine/runtime/hermetic/determinism/detector.d`)
   - Automatic detection of non-determinism sources
   - Compiler-specific flag analysis
   - Build output analysis
   - Pattern matching for timestamps, UUIDs, etc.

3. **DeterminismVerifier** (`source/engine/runtime/hermetic/determinism/verifier.d`)
   - Build output comparison
   - Hash-based verification (fast)
   - Bit-for-bit comparison (thorough)
   - Per-file diff analysis

4. **RepairEngine** (`source/engine/runtime/hermetic/determinism/repair.d`)
   - Generates actionable repair suggestions
   - Compiler-specific flags
   - Environment variable recommendations
   - Priority-based suggestions

5. **Syscall Interception Shim** (`source/engine/runtime/hermetic/determinism/shim.c`)
   - LD_PRELOAD library for Linux
   - DYLD_INSERT_LIBRARIES for macOS
   - Intercepts time(), random(), etc.
   - Provides deterministic replacements

## Usage

### Basic Determinism Enforcement

```d
import engine.runtime.hermetic;
import engine.runtime.hermetic.determinism;

// Create hermetic executor
auto spec = HermeticSpecBuilder.forBuild(
    workspaceRoot: "/workspace",
    sources: ["main.c"],
    outputDir: "/workspace/bin",
    tempDir: "/tmp/build"
);

auto executor = HermeticExecutor.create(spec.unwrap());

// Add determinism enforcement
auto config = DeterminismConfig.defaults();
auto enforcer = DeterminismEnforcer.create(
    executor.unwrap(),
    config
);

// Execute with determinism
auto result = enforcer.unwrap().execute(
    ["gcc", "main.c", "-o", "main"],
    "/workspace"
);

if (result.isOk) {
    auto detResult = result.unwrap();
    writeln("Deterministic: ", detResult.deterministic);
    writeln("Output hash: ", detResult.outputHash);
}
```

### Verification Across Multiple Runs

```d
// Execute and verify determinism across 3 runs
auto result = enforcer.unwrap().executeAndVerify(
    ["gcc", "main.c", "-o", "main"],
    "/workspace",
    iterations: 3
);

if (!result.unwrap().deterministic) {
    writeln("Build is non-deterministic!");
    foreach (violation; result.unwrap().violations) {
        writeln("  - ", violation.description);
        writeln("    Suggestion: ", violation.suggestion);
    }
}
```

### Automatic Detection and Repair

```d
import engine.runtime.hermetic.determinism;

// Analyze compiler command
auto command = ["gcc", "main.c", "-o", "main"];
auto detections = NonDeterminismDetector.analyzeCompilerCommand(
    command,
    CompilerType.GCC
);

// Generate repair suggestions
auto suggestions = RepairEngine.generateSuggestions(detections);

foreach (suggestion; suggestions) {
    writeln(suggestion.format());
}

// Or generate complete repair plan
auto plan = RepairEngine.generateRepairPlan(detections, []);
writeln(plan);
```

## Configuration

### DeterminismConfig

```d
struct DeterminismConfig {
    ulong fixedTimestamp = 1640995200;  // 2022-01-01 00:00:00 UTC
    uint prngSeed = 42;                 // Fixed PRNG seed
    bool normalizeTimestamps = true;    // Normalize file timestamps
    bool deterministicThreading = true; // Single-threaded execution
    string sourceEpoch;                 // SOURCE_DATE_EPOCH override
    bool strictMode = false;            // Fail on non-determinism
}

// Default configuration (warnings only)
auto config = DeterminismConfig.defaults();

// Strict mode (fails on violations)
auto config = DeterminismConfig.strict();
```

### Environment Variables

The determinism shim reads configuration from environment variables:

```bash
# Fixed build timestamp (Unix epoch)
export BUILD_TIMESTAMP=1640995200

# PRNG seed for deterministic random numbers
export RANDOM_SEED=42

# SOURCE_DATE_EPOCH (standard)
export SOURCE_DATE_EPOCH=1640995200
```

## Compiler-Specific Flags

### GCC / G++

```bash
# Random seed for register allocation
-frandom-seed=42

# Strip build paths from debug info
-ffile-prefix-map=/workspace/=./
-fdebug-prefix-map=/workspace/=./

# Reproducible compilation
-frandom-seed=<hash-of-input>
```

### Clang / Clang++

```bash
# Strip build paths
-fdebug-prefix-map=/workspace/=./

# Reproducible build
-Wno-builtin-macro-redefined
-D__DATE__="Jan 01 2022"
-D__TIME__="00:00:00"
-D__TIMESTAMP__="Sat Jan 01 00:00:00 2022"
```

### Rust (rustc / cargo)

```bash
# Strip build paths
cargo build --release --config env.RUSTFLAGS="-Cembed-bitcode=yes"

# Disable incremental compilation
-Cincremental=false

# Or via Cargo.toml:
[profile.release]
codegen-units = 1
strip = "symbols"
```

### Go

```bash
# Strip build paths
go build -trimpath

# Disable race detector (non-deterministic)
go build -race=false

# Reproducible builds
go build -buildmode=default -trimpath
```

### D (DMD / LDC / GDC)

```bash
# Use SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH=1640995200

# LDC specific
ldc2 -d-version=Deterministic

# GDC follows GCC flags
gdc -frandom-seed=42 -ffile-prefix-map=/workspace/=./
```

## Integration with Action Cache

Determinism verification integrates with Builder's action-level cache:

```d
// Action cache tracks determinism
ActionEntry entry;
entry.actionId = actionId;
entry.executionHash = deterministicHash;  // Hash includes determinism config

// Cache hit requires:
// 1. Input hash match
// 2. Metadata match (flags, env)
// 3. Determinism config match
```

## Verification Strategies

### 1. Content Hash (Default)

Fastest verification using BLAKE3 hashing:

```d
auto verifier = DeterminismVerifier.create(
    VerificationStrategy.ContentHash
);
```

### 2. Bit-for-Bit Comparison

Thorough byte-by-byte comparison:

```d
auto verifier = DeterminismVerifier.create(
    VerificationStrategy.BitwiseCompare
);
```

### 3. Fuzzy Comparison

Ignores timestamps and metadata:

```d
auto verifier = DeterminismVerifier.create(
    VerificationStrategy.Fuzzy
);
```

### 4. Structural Comparison

Compares structure, not exact bytes (for archives, ELF, etc.):

```d
auto verifier = DeterminismVerifier.create(
    VerificationStrategy.Structural
);
```

## Performance

### Overhead

- **Syscall Interception**: ~1-2% overhead via LD_PRELOAD
- **Hash Verification**: <100ms for typical build outputs
- **Multiple Runs**: Linear with iteration count

### Optimization Strategies

1. **Single-Pass Verification**: Verify during normal build
2. **Sampling**: Verify subset of outputs for large projects
3. **Cached Hashes**: Reuse hashes from action cache
4. **Parallel Verification**: Verify multiple files concurrently

## Examples

### Example 1: Simple C Project

```bash
# Build with determinism enforcement
bldr build --determinism=strict //main:app

# Verify manually
bldr verify-determinism //main:app --iterations=5
```

### Example 2: Rust Project with Cargo

```d
// In Builderfile
target("myapp") {
    type: executable;
    language: rust;
    sources: ["src/**/*.rs"];
    
    // Enable determinism
    determinism: {
        enabled: true;
        strict: true;
        verify_iterations: 3;
    };
    
    // Rust-specific flags
    rustflags: [
        "-Cembed-bitcode=yes",
        "-Cincremental=false"
    ];
}
```

### Example 3: Distributed Verification

```d
// Build locally
auto localHash = buildAndHash("//app:main");

// Build remotely
auto remoteHash = buildAndHashRemote("//app:main");

// Verify they match
assert(localHash == remoteHash, "Builds are not deterministic!");
```

## Troubleshooting

### Build Produces Different Outputs

1. **Run Detector**:
   ```bash
   builder detect-non-determinism //target:name
   ```

2. **Check Common Issues**:
   - Timestamps embedded (add SOURCE_DATE_EPOCH)
   - Random values (check for UUID generation)
   - Parallel builds (force single-threaded)
   - Build paths (add -ffile-prefix-map)

3. **Generate Repair Plan**:
   ```bash
   builder repair-plan //target:name
   ```

### Shim Library Not Found

```bash
# Build shim library
cd source/engine/runtime/hermetic/determinism/
make
make install

# Verify installation
ls -la bin/libdetshim.so  # Linux
ls -la bin/libdetshim.dylib  # macOS
```

### False Positives

If builds are deterministic but verification fails:

1. Check for metadata differences (timestamps on files)
2. Use `VerificationStrategy.Fuzzy`
3. Normalize timestamps: `touch -t 202201010000 output/*`

## Future Enhancements

### Planned Features

1. **Distributed Verification Network**: Cross-verify builds across multiple machines
2. **Cryptographic Signing**: Sign deterministic builds for supply chain security
3. **Build Forensics**: Detailed diff analysis for non-deterministic outputs
4. **Compiler Patch Generation**: Auto-generate patches for non-deterministic compilers
5. **Hardware Determinism**: SGX/TrustZone for provable determinism

### Research Areas

- **Formal Verification**: Prove determinism properties using SMT solvers
- **Side-Channel Resistance**: Timing-independent execution
- **Quantum-Safe Hashing**: Future-proof output verification
- **ML-Based Detection**: Learn non-determinism patterns automatically

## References

### Standards

- [Reproducible Builds](https://reproducible-builds.org/)
- [SOURCE_DATE_EPOCH](https://reproducible-builds.org/specs/source-date-epoch/)
- [DWARF Standardization](https://dwarfstd.org/)

### Tools

- [diffoscope](https://diffoscope.org/) - In-depth binary comparison
- [reprotest](https://salsa.debian.org/reproducible-builds/reprotest) - Test reproducibility
- [strip-nondeterminism](https://reproducible-builds.org/tools/) - Strip non-deterministic info

### Academic Papers

- [Reproducible Builds: Increasing the Integrity of Software Supply Chains](https://arxiv.org/abs/2104.06020)
- [Detecting and Localizing Non-Determinism in Concurrent Programs](https://dl.acm.org/doi/10.1145/3293882.3330574)

## See Also

- [Hermetic Builds](hermetic.md)
- [Action-Level Caching](caching.md)
- [Remote Execution](remote-execution.md)
- [Security](../security/security.md)

