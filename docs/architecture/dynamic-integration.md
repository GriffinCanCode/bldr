# Dynamic Build Graph Integration

## Overview

Dynamic build graphs enable runtime dependency discovery, allowing actions to extend the build graph during execution. This is used for code generation, template expansion, and other scenarios where dependencies are discovered at build time.

## Integration Points

### Core Graph System

**Files:**
- `source/engine/graph/dynamic/discovery.d` - Discovery metadata and protocols
- `source/engine/graph/dynamic/dynamic.d` - Dynamic graph extension

**Features:**
- Thread-safe graph extension
- Discovery metadata types
- Graph validation with cycle detection
- Discovery patterns for common scenarios

### Execution Engine

**Files:**
- `source/engine/runtime/core/engine/` - Engine with dynamic graph support

**Features:**
- Optional dynamic graph mode (enabled by default)
- Discovery phase integration
- Automatic rescheduling of discovered nodes
- Wave-based execution with inline discovery

**Usage:**
```d
auto engine = new ExecutionEngine(
    graph,
    config,
    services...,
    enableDynamicGraph: true  // Optional, default true
);
```

### Caching System

**File:** `source/engine/caching/targets/discovery.d`

**Features:**
- Caches discovery results
- Skips discovery if inputs unchanged
- Persistent discovery history
- JSON serialization

```d
auto cache = new DiscoveryCache(".builder-cache");
if (cache.isCached(targetId, inputHashes)) {
    auto discovery = cache.getCached(targetId);
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Interface Layer                      │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐            │
│  │ builder     │  │ builder      │  │ builder     │            │
│  │ build       │  │ discover     │  │ watch       │            │
│  └──────┬──────┘  └──────┬───────┘  └──────┬──────┘            │
└─────────┼─────────────────┼──────────────────┼──────────────────┘
          │                 │                  │
┌─────────▼─────────────────▼──────────────────▼──────────────────┐
│                     Execution Engine                             │
│  ┌────────────┐  ┌────────────┐  ┌──────────────────┐          │
│  │ Lifecycle  │  │ Coordinator│  │ Discovery        │          │
│  │            │  │ with       │  │ Executor         │          │
│  │            │  │ Discovery  │  │                  │          │
│  └────────────┘  └──────┬─────┘  └────────┬─────────┘          │
└─────────────────────────┼──────────────────┼────────────────────┘
                          │                  │
┌─────────────────────────▼──────────────────▼────────────────────┐
│                     Graph System                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐        │
│  │ BuildGraph   │  │ Dynamic      │  │ Discovery      │        │
│  │ (Static)     │  │ BuildGraph   │  │ Metadata       │        │
│  │              │  │ (Runtime)    │  │                │        │
│  └──────────────┘  └──────────────┘  └────────────────┘        │
└──────────────────────────────────────────────────────────────────┘
                             │
┌────────────────────────────▼─────────────────────────────────────┐
│                   Language Handlers                               │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────┐         │
│  │ Protobuf     │  │ Template     │  │ Others         │         │
│  │ +Discovery   │  │ +Discovery   │  │                │         │
│  └──────────────┘  └──────────────┘  └────────────────┘         │
└───────────────────────────────────────────────────────────────────┘
```

## Core Types

### DiscoveryMetadata

```d
struct DiscoveryMetadata
{
    TargetId originTarget;          // Target that performed discovery
    string[] discoveredOutputs;     // Newly discovered output files
    TargetId[] discoveredDependents; // New dependencies
    Target[] newTargets;            // New targets to create
    string[string] metadata;        // Additional metadata
}
```

### DiscoveryStatus

```d
enum DiscoveryStatus
{
    None,       // No discovery expected
    Pending,    // Discovery action not yet run
    Discovered, // Discovery complete
    Applied     // Discovery applied to graph
}
```

### DynamicBuildGraph

```d
final class DynamicBuildGraph
{
    // Create dynamic graph wrapping static base graph
    this(BuildGraph baseGraph);
    
    // Access underlying graph
    @property BuildGraph graph();
    
    // Mark node as having discovery capability
    void markDiscoverable(TargetId id);
    
    // Check if node has discovery capability
    bool isDiscoverable(TargetId id);
    
    // Record discovery from an action
    void recordDiscovery(DiscoveryMetadata discovery);
    
    // Apply pending discoveries and get newly scheduled nodes
    BuildResult!(BuildNode[]) applyDiscoveries();
    
    // Check for pending discoveries
    bool hasPendingDiscoveries();
}
```

### GraphExtension

Thread-safe graph mutation manager:

```d
final class GraphExtension
{
    // Record discovery metadata for processing
    void recordDiscovery(DiscoveryMetadata discovery);
    
    // Apply pending discoveries to graph
    BuildResult!(BuildNode[]) applyDiscoveries();
    
    // Get statistics
    auto getStats();
}
```

## Discovery Patterns

### Code Generation (Protobuf, etc.)

```d
static DiscoveryMetadata codeGeneration(
    TargetId originTarget,
    string[] generatedFiles,
    string targetNamePrefix = "generated"
);
```

Creates compile targets for generated source files, grouping by language.

### Library Discovery

```d
static DiscoveryMetadata libraryDiscovery(
    TargetId originTarget,
    string[] libraryPaths
);
```

Discovers shared libraries for linking.

### Test Discovery

```d
static DiscoveryMetadata testDiscovery(
    TargetId originTarget,
    string[] testFiles
);
```

Discovers test files and creates test targets.

### Builder Pattern

```d
auto builder = DiscoveryBuilder.forTarget(originTarget);
builder = builder.addOutputs(generatedFiles);
builder = builder.addTargets(newTargets);
builder = builder.addDependents(dependentIds);
builder = builder.withMetadata("type", "codegen");
auto discovery = builder.build();
```

## Data Flow

### Discovery Flow

1. **Analysis Phase** (Static)
   ```
   Builderfile → Parser → BuildGraph
   ```

2. **Discovery Phase** (Dynamic)
   ```
   Discoverable Action
       ↓
   Execute & Generate
       ↓
   Emit DiscoveryMetadata
       ↓
   Record in DynamicBuildGraph
   ```

3. **Extension Phase**
   ```
   Pending Discoveries
       ↓
   Apply to Graph (with validation)
       ↓
   Create New BuildNodes
       ↓
   Initialize Dependencies
   ```

4. **Execution Phase**
   ```
   Schedule Discovered Nodes
       ↓
   Build in Topological Order
   ```

## Target Creation

Language inference from file extensions:

```d
static Target createDiscoveredTarget(
    string name,
    string[] sources,
    TargetId[] deps,
    string outputPath = ""
);
```

| Extension | Language | Default Type |
|-----------|----------|--------------|
| `.d` | D | Library |
| `.cpp`, `.cc`, `.cxx` | C++ | Library |
| `.c` | C | Library |
| `.go` | Go | Library |
| `.rs` | Rust | Library |
| `.py` | Python | Library |
| `.ts` | TypeScript | Library |
| `.js` | JavaScript | Library |
| `.java` | Java | Library |
| Other | - | Custom |

## Performance

| Component | Overhead |
|-----------|----------|
| Discovery execution | ~2-3ms per discovery |
| Graph extension | O(V+E) one-time |
| Scheduling integration | O(1) per node |
| Caching | Negative (speeds up) |

### Optimization Techniques

- **Lazy Discovery**: Only runs when targets are built
- **Cached Results**: Discovery results cached across builds
- **Parallel Execution**: Discovery doesn't block other tasks
- **Batched Application**: Multiple discoveries applied at once
- **Incremental Updates**: Only affected portions re-discovered

## Design Principles

### Opt-In with Smart Defaults

Dynamic graphs enabled by default:
```d
auto engine = new ExecutionEngine(..., enableDynamicGraph: false);
```

### Backward Compatibility

- Existing language handlers work without modification
- Discovery is purely additive
- No breaking API changes

### Thread Safety

All discovery operations are thread-safe:
- Mutex-protected graph extension
- Atomic discovery recording
- Lock-free scheduling

### Composability

Discovery integrates with:
- Caching
- Remote execution
- Watch mode
- Observability/telemetry

## Comparison

### vs Bazel

| Feature | Bazel | Builder |
|---------|-------|---------|
| Dynamic deps | Yes (2-phase) | Yes (inline) |
| Complexity | High | Low |
| Performance | Excellent | Good |

### vs Buck2

| Feature | Buck2 | Builder |
|---------|-------|---------|
| Dynamic deps | Yes (deferred) | Yes (discovery) |
| API | Promise-based | Metadata-based |
| Learning curve | Steep | Gentle |

### vs Ninja

| Feature | Ninja | Builder |
|---------|-------|---------|
| Dynamic deps | Limited (restat) | Full |
| New targets | No | Yes |

## Source Files

| Component | File |
|-----------|------|
| Discovery Metadata | `source/engine/graph/dynamic/discovery.d` |
| Dynamic Graph | `source/engine/graph/dynamic/dynamic.d` |
| Discovery Cache | `source/engine/caching/targets/discovery.d` |
| Build Graph | `source/engine/graph/core/graph.d` |
