# Build Reproducibility Verification

## Overview

Builder implements automatic two-build comparison for determinism verification. This system goes beyond hermetic isolation to actively verify that builds produce bit-for-bit identical outputs across multiple runs.

## Architecture

### Components

The reproducibility verification system consists of four main components:

1. **DeterminismEnforcer** (`engine/runtime/hermetic/determinism/enforcer.d`)
   - Executes builds with determinism enforcement
   - Manages syscall interception for time(), random(), etc.
   - Supports multi-run verification with automatic comparison

2. **DeterminismVerifier** (`engine/runtime/hermetic/determinism/verifier.d`)
   - Compares build outputs across multiple runs
   - Multiple verification strategies: hash-based, bitwise, fuzzy, structural
   - Supports ELF, archive, and object file format awareness

3. **NonDeterminismDetector** (`engine/runtime/hermetic/determinism/detector.d`)
   - Analyzes compiler commands for potential non-determinism sources
   - Compiler-specific detection (GCC, Clang, Rust, Go, etc.)
   - Pattern matching for timestamps, UUIDs, and other sources

4. **RepairEngine** (`engine/runtime/hermetic/determinism/repair.d`)
   - Generates actionable repair suggestions
   - Compiler-specific flags and environment variable recommendations
   - Priority-based suggestions (critical, high, medium, low)

5. **DeterminismIntegration** (`engine/runtime/hermetic/determinism/integration.d`)
   - High-level integration layer for build system
   - Automatic two-build comparison
   - Report generation and persistence

## Usage

### Command-Line Interface

#### Quick Check (Static Analysis Only)

```bash
# Analyze command for potential issues without building
bldr verify //main:app --quick
```

This performs static analysis of the compiler command to identify potential non-determinism sources.

#### Full Verification (Two-Build Comparison)

```bash
# Build twice and compare outputs (default)
bldr verify //main:app

# Build N times and compare
bldr verify //main:app --iterations 5

# Strict mode (fail on non-determinism)
bldr verify //main:app --strict

# Different verification strategies
bldr verify //main:app --strategy bitwise
bldr verify //main:app --strategy fuzzy
bldr verify //main:app --strategy structural
```

### Configuration

#### In Builderfile

```d
// Enable automatic verification for all targets
determinism {
    enabled: true;
    verifyAutomatic: true;     // Automatic two-build comparison
    verifyIterations: 2;        // Number of builds to compare
    strictMode: false;          // Fail build if non-deterministic
    verifyStrategy: "hash";     // Verification strategy
    outputDir: ".builder-verify";
}

// Per-target configuration
target("myapp") {
    type: executable;
    sources: ["src/**/*.rs"];
    
    // Target-specific determinism settings
    determinism: {
        enabled: true;
        verifyAutomatic: true;
        verifyIterations: 3;
        strictMode: true;
    };
}
```

#### Environment Variables

```bash
# Enable determinism enforcement
export BUILDER_DETERMINISM=true

# Strict mode (fail on non-determinism)
export BUILDER_DETERMINISM=strict

# Number of verification iterations
export BUILDER_VERIFY_ITERATIONS=3

# Fixed build timestamp
export BUILD_TIMESTAMP=1640995200
export SOURCE_DATE_EPOCH=1640995200

# PRNG seed
export RANDOM_SEED=42
```

## Verification Strategies

### ContentHash (Default)

Fast verification using BLAKE3 hashing:
- Computes content hash of each output file
- Compares hashes across builds
- Memory efficient, good for large files
- **Best for**: Most builds, CI/CD pipelines

```bash
bldr verify //main:app --strategy hash
```

### BitwiseCompare

Thorough byte-by-byte comparison:
- Reads entire file contents
- Compares bit-for-bit
- Identifies first difference location
- **Best for**: Critical builds, security-sensitive code

```bash
bldr verify //main:app --strategy bitwise
```

### Fuzzy

Ignores metadata and timestamps:
- Strips ELF/archive metadata (timestamps, UIDs, build IDs)
- Compares content after normalization
- Useful for legacy builds
- **Best for**: Partially deterministic builds

```bash
bldr verify //main:app --strategy fuzzy
```

### Structural

Format-aware structural comparison:
- Understands ELF, archive, Mach-O formats
- Compares logical structure, not raw bytes
- Strips timestamps, UUIDs, paths
- **Best for**: Debug builds with metadata

```bash
bldr verify //main:app --strategy structural
```

## Detection and Repair

### Automatic Detection

The system automatically detects common non-determinism sources:

1. **Timestamp Embedding**
   - Compiler macros (__DATE__, __TIME__)
   - Build timestamps in binaries
   - File modification times

2. **Random Values**
   - UUIDs and random identifiers
   - Non-seeded PRNGs
   - Compiler random seeds

3. **Build Path Leakage**
   - Absolute paths in debug info
   - Source file paths embedded
   - Working directory references

4. **Compiler Non-Determinism**
   - Random register allocation
   - Incremental compilation
   - Symbol ordering

5. **Thread Scheduling**
   - Parallel build ordering
   - Race conditions
   - Non-deterministic scheduling

### Repair Suggestions

When non-determinism is detected, the system generates actionable repair plans:

```
╔══════════════════════════════════════════════════════════════╗
║        Determinism Repair Plan                               ║
╚══════════════════════════════════════════════════════════════╝

Found 3 issues (2 critical)

Issue 1/3:
🔴 CRITICAL: Compiler Non-Determinism

  GCC uses random seeds for register allocation which can
  cause non-deterministic output.

  Compiler flags to add:
    -frandom-seed=42

  References:
    • https://reproducible-builds.org/docs/randomness/

────────────────────────────────────────────────────────────

Issue 2/3:
🟠 HIGH: Build Path Leakage

  Build paths may be embedded in debug info

  Compiler flags to add:
    -ffile-prefix-map=/workspace/=./
    -fdebug-prefix-map=/workspace/=./

────────────────────────────────────────────────────────────
```

## Integration with Build System

### Automatic Verification

Enable automatic verification in your build configuration:

```d
// Builderfile
workspace {
    options: {
        determinism: {
            enabled: true;
            verifyAutomatic: true;  // Enable automatic two-build comparison
            verifyIterations: 2;
        };
    };
}
```

When enabled, Builder will:
1. Build the target normally
2. Immediately rebuild with same inputs
3. Compare outputs using configured strategy
4. Report any differences
5. Generate repair plan if non-deterministic

### CI/CD Integration

```yaml
# .github/workflows/build.yml
- name: Build with determinism verification
  run: |
    bldr verify //main:app --strict --iterations 3
```

In CI/CD:
- Use `--strict` to fail on non-determinism
- Use `--iterations 3` or higher for confidence
- Archive verification reports for debugging

## Performance Considerations

### Overhead

- **Syscall Interception**: ~1-2% overhead via LD_PRELOAD
- **Hash Verification**: <100ms for typical build outputs
- **Multiple Runs**: Linear with iteration count (2x for 2 iterations)
- **Detection**: <10ms for static analysis

### Optimization Strategies

1. **Incremental Verification**
   - Only verify changed outputs
   - Reuse hashes from previous runs
   - **Speedup**: 10-100x for incremental builds

2. **Sampling Verification**
   - Verify random subset of outputs
   - Statistical confidence with fewer builds
   - **Speedup**: 10x with 95% confidence

3. **Parallel Verification**
   - Hash files concurrently
   - SIMD-accelerated hashing (BLAKE3)
   - **Speedup**: Nx (N = CPU cores)

4. **Cached Results**
   - Store verification results in action cache
   - Skip verification for cached actions
   - **Speedup**: Near-instant for cache hits

## Output Reports

Verification generates detailed JSON reports:

```json
{
  "deterministic": false,
  "violations": 2,
  "detections": 3,
  "timestamp": "2025-01-01T00:00:00Z",
  "duration_ms": 5432,
  "files": [
    {
      "path": "bin/main",
      "matches": false,
      "hash1": "abc123...",
      "hash2": "def456...",
      "differences": ["Content hash mismatch"]
    }
  ]
}
```

Reports are saved to `.builder-verify/report.json` by default.

## Compiler-Specific Guidance

### GCC / G++

```bash
# Required flags for determinism
-frandom-seed=42
-ffile-prefix-map=/workspace/=./
-fdebug-prefix-map=/workspace/=./
```

### Clang / Clang++

```bash
# Required flags
-fdebug-prefix-map=/workspace/=./
-Wno-builtin-macro-redefined
-D__DATE__="Jan 01 2022"
-D__TIME__="00:00:00"
```

### Rust (rustc / cargo)

```toml
[profile.release]
codegen-units = 1
strip = "symbols"

[env]
RUSTFLAGS = "-Cembed-bitcode=yes -Cincremental=false"
```

### Go

```bash
go build -trimpath -buildmode=default
```

### D (DMD / LDC / GDC)

```bash
# Set SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH=1640995200

# GDC follows GCC flags
gdc -frandom-seed=42 -ffile-prefix-map=/workspace/=./
```

## Troubleshooting

### Build Produces Different Outputs

1. **Run Quick Check**
   ```bash
   bldr verify //target:name --quick
   ```

2. **Check Common Issues**
   - Timestamps embedded (add SOURCE_DATE_EPOCH)
   - Random values (check for UUID generation)
   - Parallel builds (force single-threaded)
   - Build paths (add -ffile-prefix-map)

3. **Generate Repair Plan**
   ```bash
   bldr verify //target:name
   ```
   The repair plan will show exact flags to add.

### False Positives

If builds are deterministic but verification fails:

1. **Try Fuzzy Strategy**
   ```bash
   bldr verify //target:name --strategy fuzzy
   ```

2. **Check File Timestamps**
   ```bash
   # Normalize timestamps
   touch -t 202201010000 output/*
   ```

3. **Review Metadata**
   Use `readelf`, `objdump`, or `strings` to inspect binaries.

## Security Considerations

### Supply Chain Security

Deterministic builds are critical for supply chain security:

1. **Verify Distributed Builds**
   - Build on multiple machines
   - Compare outputs cryptographically
   - Detect compromised build workers

2. **Reproducible Releases**
   - Anyone can verify official releases
   - Build from source and compare
   - Cryptographic proof of authenticity

3. **Byzantine Fault Tolerance**
   - Majority voting across build workers
   - Detect tampered outputs
   - Trustless verification

### Threat Model

**Protected Against:**
- Non-deterministic builds (timestamps, randomness)
- Build-time tampering (detected via verification)
- Compromised workers (cross-verification)

**Not Protected Against:**
- Compiler backdoors (still trust compiler)
- Source code tampering (no source verification)
- Side channels (timing, cache attacks)

## Future Enhancements

### Planned Features

1. **Distributed Verification Network**
   - Cross-verify builds across multiple machines
   - Byzantine consensus protocol
   - Cryptographic proof of determinism

2. **Binary Analysis**
   - Deep inspection of binaries
   - Extract embedded timestamps
   - Suggest binary patches

3. **ML-Based Detection**
   - Learn non-determinism patterns
   - Predict likely sources
   - Auto-generate fixes

4. **Formal Verification**
   - SMT-based proofs of determinism
   - Model checking for builds
   - Correctness guarantees

## References

### Standards

- [Reproducible Builds](https://reproducible-builds.org/)
- [SOURCE_DATE_EPOCH Spec](https://reproducible-builds.org/specs/source-date-epoch/)

### Tools

- [diffoscope](https://diffoscope.org/) - In-depth binary comparison
- [reprotest](https://salsa.debian.org/reproducible-builds/reprotest) - Test reproducibility

### Academic Papers

- [Reproducible Builds: Increasing the Integrity of Software Supply Chains](https://arxiv.org/abs/2104.06020)

## See Also

- [Deterministic Builds Architecture](../architecture/determinism.md)
- [Hermetic Builds](hermetic.md)
- [Action-Level Caching](caching.md)
- [Remote Execution](remote-execution.md)

