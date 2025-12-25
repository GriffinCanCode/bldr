# Builder Test Suite

This directory contains the comprehensive test infrastructure for Builder.

## Quick Start

```bash
# Run all tests
dub test

# Run with verbose output
dub test -- --verbose

# Run specific tests
dub test -- --filter="glob"

# Run in parallel
dub test -- --parallel
```

## Structure

```
tests/
├── runner.d          # Test runner CLI
├── harness.d         # Assertions and test framework
├── fixtures.d        # Test fixtures (TempDir, MockWorkspace, etc.)
├── mocks.d           # Mock objects and spies
├── property.d        # Property-based testing utilities
├── adapters/         # Test adapters for build components
├── unit/             # Unit tests organized by module
│   ├── analysis/     # Dependency analysis tests
│   ├── caching/      # Cache system tests
│   ├── cli/          # CLI and rendering tests
│   ├── compilation/  # Incremental compilation tests
│   ├── config/       # DSL and configuration tests
│   ├── core/         # Core engine tests
│   │   ├── caching/  # Build cache tests
│   │   ├── distributed/ # Distributed build tests
│   │   ├── hermetic*.d  # Hermetic build tests
│   │   └── ...       # Other core tests
│   ├── errors/       # Error handling tests
│   ├── graph/        # Build graph tests
│   ├── languages/    # Language handler tests
│   ├── lsp/          # LSP implementation tests
│   ├── migration/    # Build system migration tests
│   ├── parsing/      # Parser and tree-sitter tests
│   ├── properties/   # Property-based invariant tests
│   ├── repository/   # Repository rules tests
│   ├── services/     # Build services tests
│   └── utils/        # Utility function tests
├── integration/      # End-to-end integration tests
│   ├── build.d       # Full build pipeline tests
│   ├── distributed_*.d  # Distributed system tests
│   ├── hermetic_*.d  # Hermetic integration tests
│   ├── *_chaos.d     # Chaos and stress tests
│   └── ...           # Various scenario tests
└── bench/            # Performance benchmarks
    ├── comparative/  # Comparative analysis vs other tools
    ├── *_bench.d     # Individual benchmark suites
    └── suite.d       # Benchmark framework
```

## Key Features

- **Modular Design**: Tests organized by domain
- **Strong Typing**: Type-safe assertions
- **Fixtures**: RAII-based test fixtures with automatic cleanup
- **Mocks**: Comprehensive mocking framework
- **Benchmarks**: Built-in performance testing
- **Parallel**: Parallel test execution support

## Writing Tests

See [docs/user-guides/TESTING.md](../docs/user-guides/TESTING.md) for comprehensive guide.

### Example

```d
module tests.unit.mymodule;

import tests.harness;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m mymodule - description");
    
    Assert.equal(2 + 2, 4);
    
    writeln("\x1b[32m  ✓ Test passed\x1b[0m");
}
```

## Components

### harness.d

Test framework providing:
- `Assert` - Type-safe assertions
- `TestHarness` - Test execution and reporting
- `TestResult` / `TestStats` - Test results tracking

### fixtures.d

Test fixtures:
- `TempDir` - Temporary directories with auto-cleanup
- `MockWorkspace` - Mock build workspaces
- `TargetBuilder` - Fluent API for building test targets
- `ScopedFixture` - RAII wrapper for fixtures

### mocks.d

Mock objects:
- `MockBuildNode` - Mock build graph nodes
- `MockLanguageHandler` - Mock language handlers
- `CallTracker` - Track method calls
- `Stub<T>` - Control return values

### runner.d

Test runner with CLI:
- Automatic unittest discovery
- Parallel execution
- Filtering by name
- Configurable verbosity
- Statistics reporting

## Best Practices

1. **One test per behavior** - Each unittest tests one thing
2. **Fast tests** - Unit tests should be < 100ms
3. **Isolated** - No shared state between tests
4. **Descriptive** - Clear test descriptions
5. **Use fixtures** - Don't duplicate setup code

## Examples

### Unit Test

```d
unittest
{
    auto tempDir = scoped(new TempDir());
    tempDir.createFile("test.txt", "content");
    Assert.isTrue(tempDir.hasFile("test.txt"));
}
```

### Integration Test

```d
unittest
{
    auto workspace = scoped(new MockWorkspace());
    workspace.createTarget("app", TargetType.Executable, 
                          ["main.py"], []);
    // Test full build pipeline
}
```

### Benchmark

```d
unittest
{
    auto suite = new BenchmarkSuite();
    suite.bench("operation", 1000, {
        expensiveOperation();
    });
}
```

## Hermetic Build Tests

Comprehensive test coverage for hermetic builds and deterministic execution:

### Unit Tests (`unit/core/`)

#### `hermetic_builds.d` - Core Hermetic Build Testing
- **Determinism**: Simple C program reproducibility
- **Isolation**: Network blocking, filesystem constraints
- **Reproducibility**: Multiple runs with identical outputs
- **Resource Limits**: Memory, CPU, process limits enforcement
- **Environment**: Variable isolation and control
- **Path Remapping**: Debug path handling for determinism
- **Compiler Detection**: All major compilers (GCC, Clang, Go, Rust, D, etc.)
- **Non-determinism Detection**: Timestamp and UUID detection
- **Spec Validation**: Path overlap detection
- **Set Operations**: PathSet union, intersection, disjoint checks
- **Language-specific Flags**: Rust, D, Go compiler flag analysis
- **Multi-file Builds**: Complex project structures
- **Error Handling**: Invalid configurations
- **Helper Functions**: forBuild(), forTest() convenience methods
- **Platform Detection**: Linux, macOS, Windows capability detection
- **Determinism Config**: Presets and customization
- **Output Comparison**: Hash-based verification

**Coverage**: 20 test cases covering all hermetic build features

#### `hermetic_advanced.d` - Advanced Scenarios & Edge Cases
- **Edge Cases**: Empty paths, nested paths, special characters
- **Resource Limits**: Zero, extreme, and custom limits
- **Network Policy**: Partial access, localhost, specific hosts
- **Environment**: Variable overriding, empty values
- **Determinism**: Custom epochs, strict vs relaxed modes
- **Path Set Operations**: Union/intersection of many sets
- **Compiler Detection**: Path variations, version suffixes
- **Violation Detection**: Multiple non-determinism sources
- **Fluent API**: Method chaining validation
- **Performance**: Large path set handling
- **Timestamp Formats**: Comprehensive format detection
- **Resource Monitoring**: Interface validation

**Coverage**: 20 test cases for edge cases and advanced features

### Integration Tests (`integration/`)

#### `hermetic_real_world.d` - Real-World Build Scenarios
- **C Project**: Full build with headers, source files, linking
- **Go Module**: Go module build with proper GOPATH/GOCACHE
- **Rust Cargo**: Cargo project with dependencies
- **D Project**: Dub-based project build
- **Mixed Language**: C/C++ interop projects
- **Network Isolation**: Build failure without network
- **Reproducibility**: Identical runs verification
- **Large Projects**: Stress testing with 20+ files
- **Temp Isolation**: Temporary directory constraints
- **Compiler Flags**: Comprehensive flag analysis across compilers

**Coverage**: 10 integration tests for real-world scenarios

### Running Hermetic Tests

```bash
# Run all hermetic tests
dub test -- --filter="hermetic"

# Run specific hermetic test suites
dub test -- --filter="hermetic_builds"
dub test -- --filter="hermetic_advanced"
dub test -- --filter="hermetic_real_world"

# Run with verbose output
dub test -- --filter="hermetic" --verbose
```

### Test Coverage Summary

Total hermetic build tests: **50 test cases**
- Unit tests: 40 (hermetic_builds.d + hermetic_advanced.d)
- Integration tests: 10 (hermetic_real_world.d)

**Features Tested:**
- ✅ Hermetic execution isolation
- ✅ Deterministic builds across runs
- ✅ Network access control
- ✅ Filesystem sandboxing
- ✅ Resource limit enforcement
- ✅ Environment variable control
- ✅ Path remapping for reproducibility
- ✅ Compiler-specific determinism flags
- ✅ Non-determinism detection
- ✅ Multi-language support (C, C++, Go, Rust, D)
- ✅ Real-world build scenarios
- ✅ Edge cases and error handling

## Contributing

When adding tests:
1. Place unit tests in `unit/` mirroring `source/` structure
2. Place integration tests in `integration/`
3. Place benchmarks in `bench/`
4. Follow existing patterns
5. Maintain > 80% coverage
6. For hermetic tests, ensure:
   - Test both success and failure cases
   - Cover all supported platforms where applicable
   - Include compiler-specific test cases
   - Test edge cases and boundary conditions

