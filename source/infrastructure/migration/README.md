# Migration System

Comprehensive build system migration framework for converting various build systems to Builder's DSL.

## Overview

The migration system provides automated conversion from popular build systems to Builderfile format. It follows a modular architecture with clear separation of concerns, type-safe error handling, and extensible design patterns.

## Architecture

The migration system is organized into four main modules:

```
migration/
├── core/              # Fundamental framework
│   ├── base.d        # Interface, abstract base class, and factory
│   ├── common.d      # Common types and intermediate representation
│   └── package.d     # Barrel exports
├── registry/          # Migrator discovery and registration
│   ├── registry.d    # Singleton registry (follows LanguageRegistry pattern)
│   └── package.d     # Barrel exports
├── emission/          # Code generation
│   ├── emitter.d     # Builderfile DSL code generation
│   └── package.d     # Barrel exports
├── systems/           # Individual migrator implementations
│   ├── bazel.d       # Bazel BUILD files
│   ├── cmake.d       # CMake CMakeLists.txt
│   ├── maven.d       # Maven pom.xml
│   ├── gradle.d      # Gradle build.gradle
│   ├── make.d        # Makefiles
│   ├── cargo.d       # Rust Cargo.toml
│   ├── npm.d         # npm package.json
│   ├── gomod.d       # Go go.mod
│   ├── dub.d         # D dub.json/dub.sdl
│   ├── sbt.d         # Scala build.sbt
│   ├── meson.d       # Meson build files
│   └── package.d     # Barrel exports
├── package.d          # Main module barrel export
└── README.md          # This file
```

## Module Responsibilities

### Core Module (`core/`)

**Purpose:** Foundation for the entire migration system

**Key Components:**
- `IMigrator` - Interface all migrators implement
- `BaseMigrator` - Abstract base class with common functionality
- `MigratorFactory` - Factory for creating and auto-detecting migrators
- `MigrationTarget` - Build system agnostic target representation
- `MigrationResult` - Container for migration results, warnings, and errors
- `MigrationWarning` - Structured warnings with severity levels

**Design Philosophy:**
- Build system agnostic intermediate representation
- Result-based error handling (no exceptions in normal flow)
- Type-safe with schema integration
- Composable and extensible

### Registry Module (`registry/`)

**Purpose:** Centralized migrator registration and discovery

**Key Components:**
- `MigratorRegistry` - Singleton registry managing all migrators
- `getMigratorRegistry()` - Convenience accessor

**Features:**
- Automatic registration on initialization
- Case-insensitive system name lookup
- Support status checking
- Enumeration of available migrators

### Emission Module (`emission/`)

**Purpose:** Generate clean, idiomatic Builderfile DSL

**Key Components:**
- `BuilderfileEmitter` - Main code generator

**Features:**
- Clean DSL generation with proper indentation
- Automatic comment generation for metadata
- Warning and error summary in generated output
- Type-safe enum to string conversion
- Structured array and map formatting

### Systems Module (`systems/`)

**Purpose:** Individual build system migrator implementations

**Supported Systems:**
- **Bazel** - Google's build system (BUILD, BUILD.bazel)
- **CMake** - Cross-platform build generator (CMakeLists.txt)
- **Maven** - Java project management (pom.xml)
- **Gradle** - JVM build automation (build.gradle)
- **Make** - Unix build automation (Makefile)
- **Cargo** - Rust package manager (Cargo.toml)
- **npm** - Node.js package manager (package.json)
- **Go Modules** - Go dependency management (go.mod)
- **DUB** - D package manager (dub.json, dub.sdl)
- **SBT** - Scala build tool (build.sbt)
- **Meson** - Fast build system (meson.build)

## Design Principles

### 1. Modular Organization
- Clear separation of concerns across modules
- Single responsibility per module
- Logical grouping of related functionality

### 2. Intermediate Representation
- Build system agnostic `MigrationTarget` type
- Decouples parsing from code generation
- Enables composability and testing

### 3. Result-Based Error Handling
- All operations return `BuildResult!T`
- No exceptions thrown in normal flow
- Rich error context and suggestions

### 4. Strong Typing
- Integration with schema types (`TargetType`, `TargetLanguage`)
- Type-safe enum conversions
- Explicit nullability

### 5. Registry Pattern
- Centralized registration follows `LanguageRegistry` pattern
- Extensible design for adding new migrators
- Auto-detection capabilities

### 6. Barrel Exports
- Clean API surface through `package.d` files
- Users can import entire modules with single import
- Internal organization hidden from consumers

## Usage

### Basic Migration

```d
import infrastructure.migration;

// Create migrator by name
auto migrator = MigratorFactory.create("bazel");
auto result = migrator.migrate("BUILD");

if (result.isOk()) {
    auto emitter = BuilderfileEmitter();
    string builderfile = emitter.emit(result.unwrap());
    writeln(builderfile);
}
```

### Auto-Detection

```d
import infrastructure.migration;

// Auto-detect build system from file
auto migrator = MigratorFactory.autoDetect("BUILD");
if (migrator !is null) {
    auto result = migrator.migrate("BUILD");
    // ... process result
}
```

### Check Available Systems

```d
import infrastructure.migration;

// Get all available migrator names
string[] systems = MigratorFactory.availableSystems();
writeln("Supported systems: ", systems);

// Check if system is supported
auto registry = getMigratorRegistry();
if (registry.isSupported("bazel")) {
    writeln("Bazel migration is supported");
}
```

### Error Handling

```d
import infrastructure.migration;

auto migrator = MigratorFactory.create("cmake");
auto result = migrator.migrate("CMakeLists.txt");

if (result.isErr()) {
    auto error = result.unwrapErr();
    writeln("Migration failed: ", error.message);
    foreach (suggestion; error.suggestions) {
        writeln("  Suggestion: ", suggestion);
    }
} else {
    auto migration = result.unwrap();
    
    // Check for warnings
    if (migration.hasWarnings()) {
        writeln("Migration succeeded with warnings:");
        foreach (warning; migration.warnings) {
            writeln("  ", warning.message);
        }
    }
    
    // Generate Builderfile
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(migration);
}
```

## Adding New Migrators

To add support for a new build system:

1. **Create the migrator class** in `systems/` directory:

```d
module infrastructure.migration.systems.mysystem;

import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

final class MySystemMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe {
        return "mysystem";
    }
    
    override string[] defaultFileNames() const pure nothrow @safe {
        return ["myfile.build"];
    }
    
    override bool canMigrate(string filePath) const @safe {
        import std.path : baseName;
        return baseName(filePath) == "myfile.build";
    }
    
    override string description() const pure nothrow @safe {
        return "Migrates MySystem build files";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe {
        return ["Feature 1", "Feature 2"];
    }
    
    override string[] limitations() const pure nothrow @safe {
        return ["Limitation 1"];
    }
    
    override BuildResult!MigrationResult migrate(string inputPath) @system {
        // Parse input file
        auto contentResult = readInputFile(inputPath);
        if (contentResult.isErr())
            return BuildResult!MigrationResult.err(contentResult.unwrapErr());
        
        string content = contentResult.unwrap();
        
        // Parse and convert to MigrationTarget[]
        MigrationTarget[] targets;
        // ... parsing logic ...
        
        return createResult(targets);
    }
}
```

2. **Register the migrator** in `registry/registry.d`:

```d
private void registerMigrators()
{
    // ... existing registrations ...
    register(new MySystemMigrator());
}
```

3. **Export from systems module** in `systems/package.d`:

```d
public import infrastructure.migration.systems.mysystem;
```

## Testing

Each migrator should have comprehensive unit tests covering:

- **Parsing** - Correct extraction of targets, dependencies, flags
- **Error Handling** - Invalid syntax, missing files, malformed input
- **Edge Cases** - Empty files, unusual configurations, large files
- **Code Generation** - Correct Builderfile DSL output
- **Warnings** - Unsupported features generate appropriate warnings

Example test structure:

```d
unittest
{
    import infrastructure.migration;
    
    auto migrator = MigratorFactory.create("mysystem");
    assert(migrator !is null);
    
    // Test basic migration
    auto result = migrator.migrate("testdata/simple.build");
    assert(result.isOk());
    
    auto migration = result.unwrap();
    assert(migration.targets.length == 1);
    assert(migration.targets[0].name == "myapp");
}
```

## Integration Points

The migration system integrates with:

- **Error System** (`infrastructure.errors`) - Rich error reporting
- **Config Schema** (`infrastructure.config.schema`) - Target type definitions
- **CLI** (frontend) - User-facing migration commands
- **Wizard** (frontend) - Interactive project setup

## Best Practices

### For Migrator Implementers

1. **Use Intermediate Representation** - Convert to `MigrationTarget` for consistency
2. **Provide Rich Warnings** - Help users understand what was migrated and what wasn't
3. **Document Limitations** - Be explicit about unsupported features
4. **Preserve Metadata** - Store system-specific data in `metadata` field
5. **Test Thoroughly** - Cover common and edge cases

### For Users

1. **Review Generated Files** - Auto-migration is a starting point, not final product
2. **Check Warnings** - Important information about unsupported features
3. **Validate Behavior** - Test that migrated builds work correctly
4. **Iterate** - Migration is often an iterative process

## Future Enhancements

Potential areas for expansion:

- **Workspace-level Migration** - Multi-target projects with shared config
- **Incremental Migration** - Gradually migrate parts of large projects
- **Custom Plugins** - User-defined migration rules
- **Migration Analytics** - Statistics and insights about migrations
- **Bidirectional Migration** - Export Builder back to other formats
- **Web Service** - HTTP API for migration as a service

## See Also

- [Architecture Documentation](../../docs/architecture/migration.md)
- [CLI User Guide](../../docs/user-guides/migration.md)
- [Error System](../errors/README.md)
- [Config Schema](../config/schema/README.md)

