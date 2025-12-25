# Build System Migration Guide

Builder includes migration tools to convert existing build configurations from other systems into Builderfile format.

## Quick Start

### Interactive Migration (Recommended)

Run the interactive wizard to migrate from an existing build system:

```bash
bldr migrate
```

The wizard scans your project, detects build files, and guides you through the conversion process with explanations at each step.

### Non-Interactive Migration

For scripts or CI environments, use batch mode:

```bash
# Auto-detect build system
bldr migrate --auto BUILD
bldr migrate --auto CMakeLists.txt
bldr migrate --auto pom.xml

# Specify build system explicitly
bldr migrate --no-wizard --from=bazel --input=BUILD --output=Builderfile
bldr migrate --no-wizard --from=cmake --input=CMakeLists.txt
```

### Preview Before Writing

Use dry-run to see the output without creating files:

```bash
bldr migrate --auto BUILD --dry-run
```

## Supported Build Systems

| System | Files | Languages |
|--------|-------|-----------|
| Bazel | `BUILD`, `BUILD.bazel` | C/C++, Python, Go, Java, Rust, TypeScript |
| CMake | `CMakeLists.txt` | C/C++ |
| Maven | `pom.xml` | Java |
| Gradle | `build.gradle`, `build.gradle.kts` | Java, Kotlin, Groovy |
| Make | `Makefile`, `GNUmakefile` | C/C++ |
| Cargo | `Cargo.toml` | Rust |
| npm | `package.json` | JavaScript, TypeScript |
| Go Modules | `go.mod` | Go |
| DUB | `dub.json` | D |
| SBT | `build.sbt` | Scala |
| Meson | `meson.build` | C/C++ |

### Bazel

**Supported Features:**
- `cc_binary`, `cc_library` (C/C++)
- `py_binary`, `py_library` (Python)
- `go_binary`, `go_library` (Go)
- `java_binary`, `java_library` (Java)
- `rust_binary`, `rust_library` (Rust)
- `ts_project` (TypeScript)
- Dependencies (`deps`)
- Compiler flags (`copts`, `linkopts`)

**Limitations:**
- Complex Starlark macros require manual review
- Custom rules need manual conversion

### CMake

**Supported Features:**
- `add_executable()`
- `add_library()` (STATIC, SHARED, MODULE)
- `target_sources()`
- `target_link_libraries()`
- `target_include_directories()`
- `target_compile_options()`
- `set_target_properties()`

**Limitations:**
- Generator expressions not fully supported
- Custom commands need manual conversion

### Maven

**Supported Features:**
- Standard Maven project structure
- Dependencies
- Compiler configuration
- Packaging types (jar, war)

**Limitations:**
- Complex plugin configurations need review
- Multi-module projects require per-module migration

### Gradle

**Supported Features:**
- Java/Kotlin/Groovy projects
- Application and library plugins
- Dependencies
- Source sets

**Limitations:**
- Complex Gradle scripts require manual review
- Custom tasks need manual conversion

### Make

**Supported Features:**
- Simple compile targets
- Source file variables
- Compiler flags
- Target dependencies

**Limitations:**
- Complex Make functions require manual review
- Pattern rules need manual conversion
- Recursive Make requires restructuring

### Cargo

**Supported Features:**
- Binary targets `[[bin]]`
- Library targets `[lib]`
- Dependencies
- Dev dependencies

**Limitations:**
- Cargo features require manual configuration
- Build scripts (`build.rs`) need manual review

### npm

**Supported Features:**
- Main entry point
- Scripts (build, test, etc.)
- Dependencies
- TypeScript/JavaScript detection

**Limitations:**
- Complex bundler configs need manual review
- Monorepo workspaces require separate migration

### Go Modules

**Supported Features:**
- Module path detection
- Go version
- Dependencies

**Limitations:**
- Multiple main packages require manual target creation
- Replace directives converted to comments

### DUB

**Supported Features:**
- Package name and type
- Source paths
- Dependencies
- Build configurations

**Limitations:**
- SDL format requires conversion to JSON first
- Sub-packages need separate migration

### SBT

**Supported Features:**
- Project name and version
- Scala version
- Library dependencies

**Limitations:**
- Multi-project builds need per-project migration
- Complex SBT tasks require manual conversion

### Meson

**Supported Features:**
- `executable()` targets
- `library()` targets
- Source files
- Dependencies
- Include directories

**Limitations:**
- Complex Meson functions require manual review
- Custom targets need manual conversion

## CLI Reference

### Commands

```bash
bldr migrate                 # Interactive wizard (default)
bldr migrate --no-wizard     # Non-interactive batch mode
bldr migrate list            # List supported build systems
bldr migrate info <system>   # Show details about a build system
```

### Options

| Option | Description |
|--------|-------------|
| `--no-wizard` | Skip wizard, use non-interactive mode |
| `--from=<system>` | Source build system (bazel, cmake, etc.) |
| `--input=<file>` | Input build file to migrate |
| `--output=<file>` | Output Builderfile (default: Builderfile) |
| `--auto`, `-a` | Auto-detect build system from file |
| `--dry-run`, `-n` | Preview migration without writing files |

## Workflow

1. **Prepare**: Ensure your current build works and commit any changes
2. **Run**: `bldr migrate` (interactive) or `bldr migrate --auto <file>`
3. **Review**: Check the generated Builderfile for correctness
4. **Test**: Run `bldr build` to verify
5. **Iterate**: Adjust configuration as needed

## Common Patterns

### Dependencies

**Before (Bazel):**
```python
cc_library(
    name = "mylib",
    deps = ["//other:lib"],
)
```

**After (Builder):**
```
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
```
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
```
target("myapp") {
    type: executable;
    language: cpp;
    flags: ["-std=c++17", "-O2", "-Wall"];
}
```

## Troubleshooting

### Migration Fails

1. Verify the input file is valid for the source build system
2. Try auto-detection: `bldr migrate --auto <file>`
3. Check system-specific limitations: `bldr migrate info <system>`

### Missing Targets

1. Check if they use custom rules or macros
2. Add them manually to the Builderfile
3. Review warning messages for clues

### Dependencies Not Resolved

1. Verify dependency naming matches target names
2. Convert external dependencies to Builder format
3. Ensure all referenced targets exist

## Tips

- **Start small**: Migrate one component at a time in large projects
- **Use dry-run first**: Preview with `--dry-run` before committing changes
- **Keep original files**: Don't delete original build files until migration is complete
- **Review warnings**: Migration warnings often highlight important issues
- **Document changes**: Add comments explaining manual adjustments

## See Also

- `bldr wizard` - Interactive project setup
- `bldr init` - Initialize new project
- `bldr help migrate` - CLI help
