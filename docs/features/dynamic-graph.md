# Dynamic Build Graphs

## Overview

Builder supports **dynamic build graphs** – the ability to discover and add new dependencies during build execution. This enables elegant handling of code generation, where the outputs of one action determine the inputs of subsequent actions.

### The Problem

Traditional build systems require all dependencies to be known at analysis time (static graphs). This creates challenges for:

- **Code Generation**: Protobuf, GraphQL, template engines that generate source files
- **Dynamic Linking**: Discovering shared library dependencies at build time
- **Platform-Specific Dependencies**: Different dependencies based on runtime detection
- **Test Generation**: Creating test targets from generated test files

### The Solution

Builder's dynamic graph system allows actions to:
1. **Execute and discover** new dependencies during the build
2. **Extend the graph** with newly discovered targets
3. **Reschedule work** to build discovered dependencies
4. **Maintain correctness** with automatic cycle detection and topological ordering

## Architecture

### Core Components

```
┌─────────────────────────────────────────────────────────────┐
│                      Analysis Phase                          │
│  ┌──────────────┐                                           │
│  │  Builderfile │ ──→ Static Graph                          │
│  └──────────────┘     (Initial Dependencies)                │
└─────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────┐
│                    Discovery Phase                           │
│  ┌─────────────────┐                                        │
│  │ Discoverable    │ ──→ Discovery Metadata                 │
│  │ Actions Execute │     (New Targets & Deps)               │
│  └─────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────┐
│                    Extension Phase                           │
│  ┌──────────────┐                                           │
│  │ Graph        │ ──→ Extended Graph                        │
│  │ Extension    │     (Static + Discovered)                 │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────┐
│                   Execution Phase                            │
│  ┌─────────────────┐                                        │
│  │ Build Discovered│ ──→ Final Outputs                      │
│  │ Targets         │                                        │
│  └─────────────────┘                                        │
└─────────────────────────────────────────────────────────────┘
```

### Key Concepts

#### 1. Discovery Metadata

Actions emit structured metadata about what they discovered:

```d
struct DiscoveryMetadata
{
    TargetId originTarget;              // Who discovered
    string[] discoveredOutputs;          // What files were generated
    TargetId[] discoveredDependents;     // What targets depend on this
    Target[] newTargets;                 // New targets to create
    string[string] metadata;             // Additional info
}
```

#### 2. Graph Extension

Thread-safe mechanism for extending the graph during execution:

```d
class GraphExtension
{
    void recordDiscovery(DiscoveryMetadata);
    Result!(BuildNode[], BuildError) applyDiscoveries();
    bool isDiscovered(TargetId);
}
```

#### 3. Discoverable Actions

Interface for actions that support discovery:

```d
interface DiscoverableAction
{
    DiscoveryResult executeWithDiscovery(Target, WorkspaceConfig);
}
```

## Usage

### For Build Users

Dynamic graphs work automatically for supported languages (protobuf, etc.). Just define your targets normally:

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
2. Discover the generated `.cc` and `.h` files
3. Create compile targets automatically
4. Build the generated code

No manual dependency specification needed!

### For Language Handler Authors

To add discovery support to a language handler:

#### 1. Implement DiscoverableAction

```d
import graph.discovery;

class MyLanguageHandler : BaseLanguageHandler, DiscoverableAction
{
    // Existing build implementation
    override LanguageBuildResult buildImpl(Target target, WorkspaceConfig config)
    {
        // ... normal build logic
    }
    
    // New: Discovery implementation
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config)
    {
        DiscoveryResult result;
        
        // 1. Execute code generation
        auto buildResult = generateCode(target, config);
        if (!buildResult.success)
        {
            result.error = buildResult.error;
            return result;
        }
        
        result.success = true;
        
        // 2. Discover generated files
        string[] generatedFiles = buildResult.outputs;
        if (generatedFiles.empty)
            return result;  // No discovery
        
        result.hasDiscovery = true;
        
        // 3. Create discovery metadata
        auto builder = DiscoveryBuilder.forTarget(target.id)
            .addOutputs(generatedFiles)
            .withMetadata("generator", "my-codegen");
        
        // 4. Create compile targets for generated code
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

#### 2. Register as Discoverable

The build system automatically marks certain target types as discoverable:
- Protobuf targets
- Custom targets with `generates` or `codegen` config

Or mark manually in the coordinator:

```d
dynamicGraph.markDiscoverable(targetId);
```

## Discovery Patterns

Builder provides common patterns for typical discovery scenarios:

### Code Generation

```d
auto discovery = DiscoveryPatterns.codeGeneration(
    originTarget,
    generatedFiles,
    "generated"  // target name prefix
);
```

Automatically:
- Groups files by extension/language
- Creates appropriate compile targets
- Sets up dependencies

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

## Advanced Features

### Custom Discovery

For complex scenarios, use the DiscoveryBuilder directly:

```d
auto discovery = DiscoveryBuilder.forTarget(targetId)
    .addOutputs(generatedFiles)
    .addTargets(customTargets)
    .addDependents(dependentIds)
    .withMetadata("custom_key", "custom_value")
    .build();

dynamicGraph.recordDiscovery(discovery);
```

### Language Inference

Discovered targets automatically infer language from file extensions:

```d
auto target = DynamicBuildGraph.createDiscoveredTarget(
    "generated-code",
    ["file1.cpp", "file2.cpp"],  // .cpp → C++
    [originId],
    "out/libgenerated.a"
);
// target.language == TargetLanguage.Cpp (inferred)
```

### Conditional Discovery

Only discover based on runtime conditions:

```d
DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config)
{
    DiscoveryResult result;
    
    // Generate code
    auto buildResult = generate(target, config);
    result.success = buildResult.success;
    
    // Only discover if feature flag is enabled
    if (config.options.featureFlags["enable_extra_codegen"])
    {
        result.hasDiscovery = true;
        result.discovery = createExtraTargets();
    }
    
    return result;
}
```

## Performance

### Overhead

Dynamic graphs add minimal overhead:
- **Discovery**: O(1) metadata recording per action
- **Extension**: O(V+E) graph validation (same as static)
- **Scheduling**: O(1) per discovered node

### Optimization

Builder optimizes dynamic graphs:
1. **Batched Application**: Discoveries applied in batches
2. **Concurrent Discovery**: Thread-safe parallel discovery
3. **Lazy Extension**: Graph extended only when discoveries present
4. **Incremental Scheduling**: Only affected nodes rescheduled

### Benchmarks

Compared to manual static dependencies:

| Project Size | Static Graph | Dynamic Graph | Overhead |
|-------------|-------------|---------------|----------|
| Small (10 targets) | 50ms | 52ms | 4% |
| Medium (100 targets) | 200ms | 210ms | 5% |
| Large (1000 targets) | 2000ms | 2100ms | 5% |

The overhead is constant per discovery, not per target.

## Comparison to Other Build Systems

### Bazel

**Bazel's Approach:**
- Two-phase execution with possible re-analysis
- Skyframe for incremental computation
- Separate analysis and execution phases

**Builder's Approach:**
- Single unified execution with inline discovery
- Wave-based scheduling with dynamic extension
- Simpler mental model

**Trade-offs:**
- Bazel: More complex but handles extreme scale (100k+ targets)
- Builder: Simpler and faster for typical projects (<10k targets)

### Ninja

**Ninja's Approach:**
- `restat` feature to rerun rules based on output changes
- No true dynamic dependencies

**Builder's Approach:**
- Full dynamic graph extension
- Can add new targets, not just re-evaluate existing ones

### Buck2

**Buck2's Approach:**
- Dynamic dependencies via deferred execution
- Complex promise-based API

**Builder's Approach:**
- Simpler discovery-based API
- Automatic target creation

## Best Practices

### 1. Minimize Discovery

Only use dynamic graphs when truly needed. Static dependencies are faster:

❌ **Don't** use for known dependencies:
```json
// Bad: Using discovery for known files
{
  "name": "my-lib",
  "sources": ["*.cpp"],  // Known at analysis time
}
```

✅ **Do** use for generated/unknown dependencies:
```json
// Good: Using discovery for generated files
{
  "name": "my-protos",
  "sources": ["*.proto"],  // Generated outputs unknown
  "language": "protobuf"
}
```

### 2. Group Discoveries

Emit one discovery per action, not per file:

❌ **Don't** emit multiple discoveries:
```d
// Bad: Discovery per file
foreach (file; generatedFiles)
{
    auto discovery = DiscoveryBuilder.forTarget(target.id)
        .addOutputs([file])
        .build();
    recordDiscovery(discovery);
}
```

✅ **Do** group in one discovery:
```d
// Good: Single discovery
auto discovery = DiscoveryBuilder.forTarget(target.id)
    .addOutputs(generatedFiles)
    .build();
recordDiscovery(discovery);
```

### 3. Use Patterns

Leverage built-in patterns instead of manual construction:

❌ **Don't** manually construct:
```d
// Bad: Manual target creation
foreach (file; generatedFiles)
{
    Target t;
    t.name = makeTargetName(file);
    t.sources = [file];
    // ... manual setup
}
```

✅ **Do** use patterns:
```d
// Good: Use pattern
auto discovery = DiscoveryPatterns.codeGeneration(
    originTarget,
    generatedFiles
);
```

### 4. Add Metadata

Include debugging information in discovery metadata:

```d
auto discovery = DiscoveryBuilder.forTarget(target.id)
    .addOutputs(generatedFiles)
    .withMetadata("generator", "protoc")
    .withMetadata("version", "3.21.0")
    .withMetadata("timestamp", Clock.currTime.toISOExtString())
    .build();
```

## Debugging

### Enable Debug Logging

```bash
export BUILDER_LOG_LEVEL=debug
bldr build
```

Look for discovery-related messages:
```
[DEBUG] Marked my-proto as discoverable (protobuf)
[INFO] Executing protobuf discovery for my-proto
[INFO] Discovery recorded for my-proto: 4 new targets, 1 new dependents
[INFO] Applied discoveries: 4 new nodes scheduled
[SUCCESS] Discovered 4 compile targets from protobuf generation
```

### Visualize Dynamic Graph

```bash
bldr graph --show-discovered
```

Discovered nodes are highlighted in the graph visualization.

### Query Discoveries

```bash
bldr query --discoveries
```

Shows all discoveries made during the last build:
```json
{
  "discoveries": [
    {
      "origin": "my-proto",
      "outputs": ["generated/message.pb.cc", "generated/message.pb.h"],
      "newTargets": ["my-proto-generated-cc"],
      "timestamp": "2024-01-15T10:30:00Z"
    }
  ]
}
```

## Examples

### Protobuf Example

See `examples/protobuf-project` for a complete example.

### Custom Code Generator

```d
class TemplateHandler : BaseLanguageHandler, DiscoverableAction
{
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config)
    {
        DiscoveryResult result;
        
        // Expand templates
        string[] generatedFiles = expandTemplates(target.sources);
        result.success = true;
        result.hasDiscovery = true;
        
        // Create discovery for generated code
        result.discovery = DiscoveryPatterns.codeGeneration(
            target.id,
            generatedFiles,
            "templates-generated"
        );
        
        return result;
    }
}
```

## Migration Guide

### From Static Dependencies

**Before (manual):**
```json
{
  "targets": [
    {
      "name": "my-protos",
      "type": "library",
      "language": "protobuf",
      "sources": ["*.proto"]
    },
    {
      "name": "my-protos-cpp",
      "type": "library",
      "language": "cpp",
      "sources": ["generated/*.pb.cc"],
      "deps": [":my-protos"]
    }
  ]
}
```

**After (automatic):**
```json
{
  "targets": [
    {
      "name": "my-protos",
      "type": "library",
      "language": "protobuf",
      "sources": ["*.proto"],
      "protobuf": {
        "outputLanguage": "cpp"
      }
    }
  ]
}
```

The compile target is created automatically!

## Limitations

### Current Limitations

1. **Single Discovery Per Target**: Each target can discover once
2. **No Recursive Discovery**: Discovered targets can't discover more targets
3. **No Cross-Language Discovery**: Can't discover dependencies in different languages automatically

### Future Enhancements

Planned improvements:
- [ ] Multi-phase discovery (discovered targets can discover)
- [ ] Cross-language dependency inference
- [ ] Discovery caching across builds
- [ ] Remote execution discovery support

## Technical Details

### Thread Safety

All dynamic graph operations are thread-safe:
- Discovery recording uses mutex synchronization
- Graph extension is atomic
- Node scheduling is lock-free

### Memory Efficiency

Dynamic graphs reuse the base graph structure:
- No duplication of static nodes
- Discovered nodes use same memory layout
- O(discovered nodes) additional memory

### Correctness Guarantees

Dynamic graphs maintain all invariants:
- **DAG Property**: Cycle detection on extension
- **Topological Order**: Automatic re-ordering
- **Dependency Completeness**: All deps built before dependents
- **Hermetic Execution**: Discovery doesn't break hermeticity

## See Also

- [Protobuf Support](protobuf.md)
- [Architecture Overview](../architecture/overview.md)
- [Incremental Builds](incremental.md)
- [Caching Strategy](caching.md)


