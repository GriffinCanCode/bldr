# Migration Examples

This directory contains example build files from various build systems to demonstrate Builder's migration capabilities.

## Quick Test

Try migrating any of these examples:

```bash
# Bazel
cd bazel-example
bldr migrate --auto BUILD

# CMake
cd cmake-example
bldr migrate --auto CMakeLists.txt

# Or use explicit system specification
bldr migrate --from=bazel --input=BUILD --output=Builderfile
```

## Examples

- **bazel-example/** - Bazel BUILD file with C++ and Python targets
- **cmake-example/** - CMake project with executable and library
- **maven-example/** - (Add pom.xml example)
- **npm-example/** - (Add package.json example)
- **cargo-example/** - (Add Cargo.toml example)

## Testing Migrations

After migrating, test the build:

```bash
bldr build
```

Compare with original build system to ensure correctness.

## Contributing

Have an interesting migration example? Add it here with:
1. Original build file(s)
2. Expected Builderfile
3. Any special notes or gotchas

