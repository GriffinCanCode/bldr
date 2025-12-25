# Dynamic Build Graphs

## Overview

Builder supports dynamic build graphs—the ability to discover and add new dependencies during build execution. This enables code generation scenarios where the outputs of one action determine the inputs of subsequent actions.

### Use Cases

- **Code generation**: Protobuf, GraphQL, template engines generating source files
- **Dynamic linking**: Discovering shared library dependencies at build time
- **Platform-specific dependencies**: Dependencies based on runtime detection
- **Test generation**: Creating test targets from generated test files

## Architecture

The dynamic graph system is in `source/engine/graph/dynamic/`:

```
graph/dynamic/
├── dynamic.d     # DynamicBuildGraph wrapper
├── discovery.d   # Discovery metadata and GraphExtension
└── package.d     # Public API
```

### Phases

```
Analysis Phase
  └── Builderfile → Static Graph (initial dependencies)
          │
          ▼
Discovery Phase
  └── Discoverable actions execute → Discovery Metadata
          │
          ▼
Extension Phase
  └── Graph extended with discovered targets/dependencies
          │
          ▼
Execution Phase
  └── Discovered targets built
```

## Core Types

### DiscoveryMetadata

Emitted by actions to declare discovered dependencies:

```d
struct DiscoveryMetadata {
    TargetId originTarget;           // Who discovered
    string[] discoveredOutputs;      // Generated files
    TargetId[] discoveredDependents; // Targets depending on this
    Target[] newTargets;             // New targets to create
    string[string] metadata;         // Additional info
}
```

### DiscoveryResult

Returned by discoverable actions:

```d
struct DiscoveryResult {
    bool success;
    bool hasDiscovery;
    DiscoveryMetadata discovery;
    string error;
}
```

### DiscoveryStatus

Per-node discovery state:

```d
enum DiscoveryStatus {
    None,       // No discovery expected
    Pending,    // Discovery action not yet run
    Discovered, // Discovery complete
    Applied     // Applied to graph
}
```

## Usage

### For Build Users

Dynamic graphs work automatically for supported target types. Define targets normally:

```json
{
  "targets": [
    {
      "name": "my-protos",
      "type": "library",
      "language": "protobuf",
      "sources": ["**/*.proto"],
      "protobuf": {
        "outputLanguage": "cpp",
        "outputDir": "generated"
      }
    }
  ]
}
```

Builder will:
1. Execute the protobuf compiler
2. Discover generated `.cc` and `.h` files
3. Create compile targets automatically
4. Build the generated code

### For Language Handler Authors

Implement the `DiscoverableAction` interface:

```d
interface DiscoverableAction {
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config);
}
```

Example implementation:

```d
class MyCodeGenHandler : BaseLanguageHandler, DiscoverableAction {
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config) {
        DiscoveryResult result;
        
        // 1. Execute code generation
        auto buildResult = generateCode(target, config);
        if (!buildResult.success) {
            result.error = buildResult.error;
            return result;
        }
        result.success = true;
        
        // 2. Check for generated files
        string[] generatedFiles = buildResult.outputs;
        if (generatedFiles.empty)
            return result;
        
        result.hasDiscovery = true;
        
        // 3. Create discovery metadata
        auto builder = DiscoveryBuilder.forTarget(target.id)
            .addOutputs(generatedFiles)
            .withMetadata("generator", "my-codegen");
        
        // 4. Create compile targets
        Target compileTarget = createCompileTarget(
            target.name ~ "-generated",
            generatedFiles,
            [target.id]
        );
        
        builder = builder.addTargets([compileTarget])
                        .addDependents([compileTarget.id]);
        
        result.discovery = builder.build();
        return result;
    }
}
```

### Programmatic API

```d
import engine.graph.dynamic;

// Create dynamic graph wrapping static graph
auto dynamicGraph = new DynamicBuildGraph(baseGraph);

// Mark target as discoverable
dynamicGraph.markDiscoverable(targetId);

// Record discovery from action
dynamicGraph.recordDiscovery(discovery);

// Apply discoveries and get new nodes
auto result = dynamicGraph.applyDiscoveries();
if (result.isOk) {
    auto newNodes = result.unwrap();
    // Schedule new nodes for execution
}

// Query discovery state
if (dynamicGraph.hasPendingDiscoveries()) {
    auto stats = dynamicGraph.getDiscoveryStats();
}
```

## Discovery Patterns

Helper patterns in `DiscoveryPatterns` for common scenarios:

### Code Generation

```d
auto discovery = DiscoveryPatterns.codeGeneration(
    originTarget,
    generatedFiles,
    "generated"  // Target name prefix
);
```

Groups files by extension, creates compile targets, sets up dependencies.

### Library Discovery

```d
auto discovery = DiscoveryPatterns.libraryDiscovery(
    originTarget,
    libraryPaths
);
```

For dynamic linking scenarios.

### Test Discovery

```d
auto discovery = DiscoveryPatterns.testDiscovery(
    originTarget,
    testFiles
);
```

Creates test targets for generated test files.

## DiscoveryBuilder

Fluent API for creating discovery metadata:

```d
auto discovery = DiscoveryBuilder.forTarget(targetId)
    .addOutputs(generatedFiles)
    .addTargets(newTargets)
    .addDependents(dependentIds)
    .withMetadata("key", "value")
    .build();
```

## Language Inference

`DynamicBuildGraph.createDiscoveredTarget` infers language from extensions:

```d
auto target = DynamicBuildGraph.createDiscoveredTarget(
    "generated-code",
    ["file1.cpp", "file2.cpp"],
    [originId],
    "out/libgenerated.a"
);
// target.language == TargetLanguage.Cpp (inferred)
```

Supported inferences:
- `.d` → D
- `.cpp`, `.cc`, `.cxx` → C++
- `.c` → C
- `.go` → Go
- `.rs` → Rust
- `.py` → Python
- `.ts` → TypeScript
- `.js` → JavaScript
- `.java` → Java

## Thread Safety

All dynamic graph operations are thread-safe:

- `recordDiscovery()` uses mutex synchronization
- `applyDiscoveries()` is atomic
- Multiple workers can record discoveries concurrently

## Performance

| Operation | Overhead |
|-----------|----------|
| Discovery recording | O(1) per action |
| Graph extension | O(V+E) validation |
| Node scheduling | O(1) per discovered node |

Discoveries are batched and applied together.

## Debugging

### Enable Debug Logging

```bash
export BUILDER_LOG_LEVEL=debug
bldr build
```

Look for discovery messages:
```
[DEBUG] Marked my-proto as discoverable (protobuf)
[INFO] Executing protobuf discovery for my-proto
[INFO] Discovery recorded: 4 new targets, 1 new dependents
[INFO] Applied discoveries: 4 new nodes scheduled
```

### Visualize Graph

```bash
bldr graph --show-discovered
```

Discovered nodes are highlighted in the visualization.

### Query Discoveries

```bash
bldr query --discoveries
```

## Best Practices

### Minimize Discovery

Only use dynamic graphs when dependencies are truly unknown at analysis time:

**Do use** for generated outputs:
```json
{
  "name": "my-protos",
  "language": "protobuf",
  "sources": ["*.proto"]
}
```

**Don't use** for known dependencies:
```json
{
  "name": "my-lib",
  "sources": ["*.cpp"]  // Known at analysis time
}
```

### Group Discoveries

Emit one discovery per action, not per file:

```d
// Good: Single discovery with all files
auto discovery = DiscoveryBuilder.forTarget(target.id)
    .addOutputs(generatedFiles)
    .build();
recordDiscovery(discovery);
```

### Use Patterns

Prefer built-in patterns over manual construction:

```d
// Good: Use pattern
auto discovery = DiscoveryPatterns.codeGeneration(
    originTarget,
    generatedFiles
);
```

### Include Metadata

Add debugging information:

```d
auto discovery = DiscoveryBuilder.forTarget(target.id)
    .addOutputs(generatedFiles)
    .withMetadata("generator", "protoc")
    .withMetadata("version", "3.21.0")
    .build();
```

## Limitations

1. **Single discovery per target**: Each target can discover once per build
2. **No recursive discovery**: Discovered targets cannot themselves discover
3. **DAG maintained**: Cycles are detected and rejected

## See Also

- [Repository Rules](repository-rules.md) (external dependencies and code generation)
- [Incremental Builds](incremental.md)
- [Caching](caching.md)
- [Architecture Overview](../architecture/overview.md)
