# Build System Migration Guide

Builder provides comprehensive migration tools to help you transition from other build systems. This guide covers the migration process, supported systems, and best practices.

## Quick Start

### Auto-Detect and Migrate

The simplest way to migrate is to let Builder auto-detect your build system:

```bash
bldr migrate --auto BUILD
bldr migrate --auto CMakeLists.txt
bldr migrate --auto pom.xml
```

### Specify Build System

For explicit control or when auto-detection isn't available:

```bash
bldr migrate --from=bazel --input=BUILD --output=Builderfile
bldr migrate --from=cmake --input=CMakeLists.txt
bldr migrate --from=maven --input=pom.xml
```

### Preview Before Writing

Use dry-run mode to see the migration output without creating files:

```bash
bldr migrate --auto BUILD --dry-run
```

## Supported Build Systems

### Bazel (Google's Build System)

**Files:** `BUILD`, `BUILD.bazel`

**Supported Features:**
- `cc_binary`, `cc_library` (C/C++)
- `py_binary`, `py_library` (Python)
- `go_binary`, `go_library` (Go)
- `java_binary`, `java_library` (Java)
- `rust_binary`, `rust_library` (Rust)
- `ts_project` (TypeScript)
- Dependencies (`deps`)
- Compiler flags (`copts`)
- Linker flags (`linkopts`)

**Example:**
```bash
bldr migrate --from=bazel --input=BUILD
```

**Limitations:**
- Complex Starlark macros require manual review
- Custom rules need manual conversion
- Aspect-based features not supported

### CMake

**Files:** `CMakeLists.txt`

**Supported Features:**
- `add_executable()`
- `add_library()` (STATIC, SHARED, MODULE)
- `target_sources()`
- `target_link_libraries()`
- `target_include_directories()`
- `target_compile_options()`
- `set_target_properties()`

**Example:**
```bash
bldr migrate --from=cmake --input=CMakeLists.txt
```

**Limitations:**
- Generator expressions not fully supported
- Custom commands need manual conversion
- External project integration requires adaptation

### Maven (Java Build Tool)

**Files:** `pom.xml`

**Supported Features:**
- Standard Maven project structure
- Dependencies
- Compiler configuration
- Packaging types (jar, war)

**Example:**
```bash
bldr migrate --from=maven --input=pom.xml
```

**Limitations:**
- Complex plugin configurations need review
- Multi-module projects require per-module migration

### Gradle (Flexible Build Tool)

**Files:** `build.gradle`, `build.gradle.kts`

**Supported Features:**
- Java/Kotlin/Groovy projects
- Application plugin
- Java library plugin
- Dependencies
- Source sets

**Example:**
```bash
bldr migrate --from=gradle --input=build.gradle
```

**Limitations:**
- Complex Gradle scripts require manual review
- Custom tasks need manual conversion

### Make (GNU Make)

**Files:** `Makefile`, `makefile`, `GNUmakefile`

**Supported Features:**
- Simple compile targets
- Source file variables
- Compiler flags
- Target dependencies

**Example:**
```bash
bldr migrate --from=make --input=Makefile
```

**Limitations:**
- Complex Make functions require manual review
- Pattern rules need manual conversion
- Recursive Make requires restructuring

### Cargo (Rust Package Manager)

**Files:** `Cargo.toml`

**Supported Features:**
- Binary targets `[[bin]]`
- Library targets `[lib]`
- Dependencies
- Dev dependencies

**Example:**
```bash
bldr migrate --from=cargo --input=Cargo.toml
```

**Limitations:**
- Cargo features require manual configuration
- Build scripts (build.rs) need manual review

### npm (Node Package Manager)

**Files:** `package.json`

**Supported Features:**
- Main entry point
- Scripts (build, test, etc.)
- Dependencies
- TypeScript/JavaScript detection

**Example:**
```bash
bldr migrate --from=npm --input=package.json
```

**Limitations:**
- Complex webpack/rollup configs need manual review
- Monorepo workspaces require separate migration

### Go Modules

**Files:** `go.mod`

**Supported Features:**
- Module path detection
- Go version
- Dependencies
- Standard project structure

**Example:**
```bash
bldr migrate --from=gomod --input=go.mod
```

**Limitations:**
- Multiple main packages require manual target creation
- Replace directives converted to comments

### DUB (D Package Manager)

**Files:** `dub.json`, `dub.sdl`

**Supported Features:**
- Package name and type
- Source paths
- Dependencies
- Build configurations

**Example:**
```bash
bldr migrate --from=dub --input=dub.json
```

**Limitations:**
- SDL format requires conversion to JSON first
- Sub-packages need separate migration

### SBT (Scala Build Tool)

**Files:** `build.sbt`

**Supported Features:**
- Project name and version
- Scala version
- Library dependencies
- Standard directory structure

**Example:**
```bash
bldr migrate --from=sbt --input=build.sbt
```

**Limitations:**
- Multi-project builds need per-project migration
- Complex SBT tasks require manual conversion

### Meson (Fast Build System)

**Files:** `meson.build`

**Supported Features:**
- `executable()` targets
- `library()` targets
- Source files
- Dependencies
- Include directories

**Example:**
```bash
bldr migrate --from=meson --input=meson.build
```

**Limitations:**
- Complex Meson functions require manual review
- Custom targets need manual conversion

## Migration Workflow

### 1. Prepare Your Project

Before migrating:
- Ensure your current build works correctly
- Commit any uncommitted changes
- Back up important files

### 2. Run Migration

```bash
# Auto-detect (recommended)
bldr migrate --auto <build-file>

# Or specify explicitly
bldr migrate --from=<system> --input=<file>
```

### 3. Review Generated Builderfile

Open the generated `Builderfile` and review:
- Target names and types
- Source file patterns
- Dependencies
- Build flags
- Warning comments

### 4. Test the Build

```bash
bldr build
```

### 5. Iterate and Refine

Based on test results:
- Adjust source patterns
- Fix dependency references
- Configure language-specific options
- Handle warnings

## Common Migration Patterns

### Handling Dependencies

**Before (Bazel):**
```python
cc_library(
    name = "mylib",
    deps = ["//other:lib"],
)
```

**After (Builder):**
```d
target("mylib") {
    type: library;
    language: cpp;
    deps: ["other:lib"];
}
```

### Source Patterns

**Before (CMake):**
```cmake
add_executable(myapp
    src/main.cpp
    src/utils.cpp
)
```

**After (Builder):**
```d
target("myapp") {
    type: executable;
    language: cpp;
    sources: ["src/**/*.cpp"];
}
```

### Compiler Flags

**Before (Make):**
```makefile
CXXFLAGS = -std=c++17 -O2 -Wall
```

**After (Builder):**
```d
target("myapp") {
    type: executable;
    language: cpp;
    flags: ["-std=c++17", "-O2", "-Wall"];
}
```

## Troubleshooting

### Migration Fails

If migration fails:

1. Check the input file is valid for the source build system
2. Try auto-detection: `bldr migrate --auto <file>`
3. Review error messages for specific issues
4. Check system-specific limitations: `bldr migrate info <system>`

### Missing Targets

If some targets are missing:

1. Check if they use custom rules or macros
2. Add them manually to the Builderfile
3. Review warning messages for clues

### Incorrect Language Detection

If the language is incorrectly detected:

1. Manually specify in the Builderfile
2. Check file extensions match expected patterns
3. Ensure source files are in standard locations

### Dependencies Not Resolved

If dependencies aren't working:

1. Check dependency naming matches target names
2. Convert external dependencies to Builder format
3. Ensure all referenced targets exist

## Best Practices

### 1. Start Small

Migrate one component or module at a time, especially in large projects.

### 2. Use Dry-Run First

Always preview with `--dry-run` before committing changes.

### 3. Keep Original Files

Don't delete original build files until migration is complete and tested.

### 4. Review Warnings

Pay attention to migration warnings—they often highlight important issues.

### 5. Test Incrementally

Test each migrated target individually before moving to the next.

### 6. Document Custom Changes

Add comments in your Builderfile explaining manual adjustments.

### 7. Version Control

Commit the Builderfile and test it with your CI/CD pipeline.

## Advanced Features

### Custom Metadata

Migration preserves system-specific metadata as comments:

```d
target("myapp") {
    type: executable;
    language: cpp;
    sources: ["src/**/*.cpp"];
    
    // Additional metadata:
    // linkopts: -pthread -ldl
    // features: c++17
}
```

Review these comments and convert to Builder equivalents.

### Multi-Target Projects

For projects with multiple targets:

```bash
# Migrate main build file
bldr migrate --auto BUILD

# Review and test each target
bldr build //component1:lib
bldr build //component2:app
```

### Language-Specific Configuration

Some languages support additional configuration:

```d
target("go-app") {
    type: executable;
    language: go;
    sources: ["*.go"];
    
    go: {
        "modMode": "on",
        "trimpath": "true"
    };
}
```

Refer to language-specific documentation for available options.

## Getting Help

### List All Systems

```bash
bldr migrate list
```

### Get System Info

```bash
bldr migrate info bazel
bldr migrate info cmake
```

### General Help

```bash
bldr migrate --help
```

### Community Support

- GitHub Issues: Report migration problems
- Documentation: Check language-specific guides
- Examples: Review `examples/` directory

## Next Steps

After successful migration:

1. **Optimize:** Use Builder's incremental compilation features
2. **Integrate:** Set up CI/CD with Builder
3. **Explore:** Try Builder's advanced features (caching, distributed builds)
4. **Contribute:** Share feedback and improvements

---

**Note:** Migration is a best-effort process. Complex build logic may require manual adjustment. Always review and test the generated Builderfile before using in production.

