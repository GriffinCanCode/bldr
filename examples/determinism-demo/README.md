# Deterministic Build Demo

This example demonstrates Builder's determinism enforcement capabilities beyond hermetic isolation.

## Overview

Demonstrates how Builder achieves bit-for-bit reproducible builds by:
- Intercepting non-deterministic syscalls (time, random, etc.)
- Enforcing deterministic compiler flags
- Verifying outputs across multiple builds
- Detecting and suggesting fixes for non-determinism

## Files

- `main.c` - Deterministic build example
- `non_deterministic.c` - Non-deterministic build example (for comparison)
- `Builderfile` - Build configuration with determinism settings

## Building

### Deterministic Build

```bash
# Build with determinism enforcement
bldr build //demo-app:demo-app

# The build will use:
# - Fixed timestamp (SOURCE_DATE_EPOCH=1640995200)
# - Seeded PRNG (RANDOM_SEED=42)
# - Deterministic compiler flags
# - Syscall interception via libdetshim
```

### Non-Deterministic Build (for comparison)

```bash
# Build without determinism
bldr build //demo-app:non-deterministic-app

# This build will vary between runs
```

## Verification

### Verify Determinism Across Multiple Runs

```bash
# Build 3 times and verify outputs match
bldr verify-determinism //demo-app:demo-app --iterations=3
```

### Expected Output

```
Verifying determinism across 3 builds...
Build 1/3: hash=abc123...
Build 2/3: hash=abc123...
Build 3/3: hash=abc123...
✓ Build is deterministic: all outputs match
```

### Manual Verification

```bash
# Build twice
bldr build //demo-app:demo-app -o bin/app1
bldr clean
bldr build //demo-app:demo-app -o bin/app2

# Compare outputs
sha256sum bin/app1 bin/app2
# Hashes should be identical

# Or bit-for-bit comparison
cmp bin/app1 bin/app2 && echo "Identical!"
```

## Detection and Repair

### Detect Non-Determinism Sources

```bash
# Analyze compiler command for non-determinism
builder detect-non-determinism //demo-app:demo-app
```

Expected output:

```
Analyzing build for non-determinism...

Found 2 potential issues:

🟠 HIGH PRIORITY
───────────────────────────────────────────────────────────
Missing compiler flag for random seed

  GCC uses random seeds for register allocation which can
  cause non-deterministic output.

  Suggested fixes:
    1. Add compiler flag: -frandom-seed=42
       Add to compiler command

  References:
    • https://reproducible-builds.org/docs/randomness/
    • https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html
```

### Generate Repair Plan

```bash
# Generate comprehensive repair suggestions
builder repair-plan //demo-app:demo-app
```

## Integration Example

### D Language Example

```d
import engine.runtime.hermetic;
import engine.runtime.hermetic.determinism;
import std.stdio;

void main() {
    // Create hermetic executor
    auto spec = HermeticSpecBuilder.forBuild(
        "/workspace",
        ["main.c"],
        "/workspace/bin",
        "/tmp/build"
    ).unwrap();
    
    auto executor = HermeticExecutor.create(spec).unwrap();
    
    // Add determinism enforcement
    auto config = DeterminismConfig.defaults();
    auto enforcer = DeterminismEnforcer.create(executor, config).unwrap();
    
    // Execute with verification
    auto result = enforcer.executeAndVerify(
        ["gcc", "main.c", "-o", "main", "-frandom-seed=42"],
        "/workspace",
        3  // Verify across 3 runs
    );
    
    if (result.isErr) {
        writeln("Build failed: ", result.unwrapErr().message);
        return;
    }
    
    auto detResult = result.unwrap();
    
    if (detResult.deterministic) {
        writeln("✓ Build is deterministic!");
        writeln("  Output hash: ", detResult.outputHash);
    } else {
        writeln("✗ Build is non-deterministic!");
        writeln("Violations:");
        foreach (violation; detResult.violations) {
            writeln("  - ", violation.description);
            writeln("    Suggestion: ", violation.suggestion);
        }
    }
}
```

## Compiler-Specific Examples

### GCC/G++

```bash
# Full deterministic flags
gcc main.c -o main \
    -frandom-seed=42 \
    -ffile-prefix-map=$(pwd)=. \
    -fdebug-prefix-map=$(pwd)=. \
    -D__DATE__="Jan 01 2022" \
    -D__TIME__="00:00:00"
```

### Clang/Clang++

```bash
# Deterministic build with Clang
clang main.c -o main \
    -fdebug-prefix-map=$(pwd)=. \
    -Wno-builtin-macro-redefined \
    -D__DATE__="Jan 01 2022" \
    -D__TIME__="00:00:00" \
    -D__TIMESTAMP__="Sat Jan 01 00:00:00 2022"
```

### Rust (via Cargo)

```bash
# Deterministic Rust build
RUSTFLAGS="-Cembed-bitcode=yes -Cincremental=false" \
SOURCE_DATE_EPOCH=1640995200 \
cargo build --release
```

### Go

```bash
# Deterministic Go build
CGO_ENABLED=0 \
SOURCE_DATE_EPOCH=1640995200 \
go build -trimpath -buildmode=default
```

## Testing Determinism

### 1. Build Multiple Times

```bash
#!/bin/bash
# Build 10 times and verify all outputs match

HASHES=()
for i in {1..10}; do
    bldr clean //demo-app:demo-app
    bldr build //demo-app:demo-app
    HASH=$(sha256sum bin/demo-app | cut -d' ' -f1)
    HASHES+=("$HASH")
    echo "Build $i: $HASH"
done

# Check all hashes are identical
UNIQUE=$(printf '%s\n' "${HASHES[@]}" | sort -u | wc -l)
if [ "$UNIQUE" -eq 1 ]; then
    echo "✓ All builds produced identical output!"
else
    echo "✗ Builds differ!"
    exit 1
fi
```

### 2. Distributed Verification

```bash
# Build on machine A
ssh machineA "cd project && bldr build //demo-app:demo-app"
scp machineA:project/bin/demo-app /tmp/demo-app-A

# Build on machine B
ssh machineB "cd project && bldr build //demo-app:demo-app"
scp machineB:project/bin/demo-app /tmp/demo-app-B

# Verify they match
cmp /tmp/demo-app-A /tmp/demo-app-B && echo "Builds match!"
```

## Troubleshooting

### Build Still Non-Deterministic

1. **Check shim library is loaded:**
   ```bash
   LD_PRELOAD=./bin/libdetshim.so ./bin/demo-app
   ```

2. **Enable debug mode:**
   ```bash
   export DETSHIM_DEBUG=1
   bldr build //demo-app:demo-app
   ```

3. **Analyze differences:**
   ```bash
   # Build twice
   bldr build //demo-app:demo-app -o bin/app1
   bldr clean && bldr build //demo-app:demo-app -o bin/app2
   
   # Use diffoscope for detailed comparison
   diffoscope bin/app1 bin/app2
   ```

### Common Issues

**Issue**: Timestamps still embedded
- **Solution**: Ensure SOURCE_DATE_EPOCH is set
- **Check**: `strings bin/app | grep -E '\d{4}-\d{2}-\d{2}'`

**Issue**: Random values differ
- **Solution**: Verify shim library is loaded
- **Check**: `ldd bin/app | grep detshim`

**Issue**: Build paths embedded
- **Solution**: Add `-ffile-prefix-map` flag
- **Check**: `strings bin/app | grep /workspace`

## References

- [Builder Determinism Documentation](../../docs/features/determinism.md)
- [Reproducible Builds Project](https://reproducible-builds.org/)
- [SOURCE_DATE_EPOCH Specification](https://reproducible-builds.org/specs/source-date-epoch/)
- [GCC Reproducible Builds](https://gcc.gnu.org/onlinedocs/gcc/Environment-Variables.html)

