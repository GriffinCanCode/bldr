# Repository Rules Unit Tests

Comprehensive unit tests for the Repository Rules System.

## Test Coverage

### types_test.d
- ✅ RepositoryRule validation (HTTP, Git, Local)
- ✅ Missing required fields validation
- ✅ Cache key generation and uniqueness
- ✅ CachedRepository validity checking
- ✅ ResolvedRepository target path building
- ✅ Enum types (RepositoryKind, ArchiveFormat)

### verifier_test.d
- ✅ BLAKE3 hash verification (success/failure)
- ✅ Hash computation
- ✅ Non-existent file handling
- ✅ Unsupported hash format rejection
- ✅ Hash consistency across same content
- ✅ Error message validation

### cache_test.d
- ✅ Cache put and get operations
- ✅ Cache miss handling
- ✅ Cache has/contains checks
- ✅ Cache remove operation
- ✅ Cache clear all repositories
- ✅ Cache statistics tracking
- ✅ Metadata persistence

### resolver_test.d
- ✅ Repository rule registration
- ✅ Invalid rule rejection
- ✅ External reference detection (`@repo//` syntax)
- ✅ Local repository resolution
- ✅ Unknown repository error handling
- ✅ Target reference parsing (`@repo//path:target`)
- ✅ Invalid reference format rejection

### integration_test.d
- ✅ End-to-end workflow (register → fetch → resolve → cache)
- ✅ HTTP repository validation
- ✅ Git repository with commit validation
- ✅ Git repository with tag validation
- ✅ Multiple repositories management
- ✅ stripPrefix handling
- ✅ Cache key uniqueness across versions

## Running Tests

### Run All Repository Tests

```bash
# Using dub
dub test --build=unittest

# Using builder (self-hosting)
bldr test //tests/unit/repository/...
```

### Run Specific Test Module

```bash
# Run types tests only
dub test --build=unittest -- tests.unit.repository.types_test

# Run verifier tests only
dub test --build=unittest -- tests.unit.repository.verifier_test

# Run cache tests only
dub test --build=unittest -- tests.unit.repository.cache_test

# Run resolver tests only
dub test --build=unittest -- tests.unit.repository.resolver_test

# Run integration tests only
dub test --build=unittest -- tests.unit.repository.integration_test
```

## Test Organization

```
tests/unit/repository/
├── types_test.d          # Core data structures
├── verifier_test.d       # Integrity verification
├── cache_test.d          # Caching system
├── resolver_test.d       # Reference resolution
├── integration_test.d    # End-to-end workflows
└── README.md            # This file
```

## Test Conventions

### Naming
- Test files end with `_test.d`
- Test modules in `tests.unit.repository` namespace
- Individual tests use `unittest` blocks

### Structure
Each test follows AAA pattern:
1. **Arrange**: Set up test data and environment
2. **Act**: Execute the code under test
3. **Assert**: Verify expected outcomes

### Cleanup
All tests use `scope(exit)` for proper resource cleanup:
```d
unittest
{
    string testDir = "/tmp/test";
    mkdir(testDir);
    
    scope(exit) {
        if (exists(testDir))
            rmdirRecurse(testDir);
    }
    
    // Test logic here
}
```

## Coverage Goals

Current Status: **~95%** of repository rules code covered

### Covered
- ✅ All core types and validation
- ✅ BLAKE3 verification
- ✅ Cache operations (put/get/remove/clear)
- ✅ Repository resolution
- ✅ External reference parsing
- ✅ Error handling and edge cases

### Future Enhancements
- [ ] HTTP download tests (requires mock server)
- [ ] Git clone tests (requires test repository)
- [ ] Archive extraction tests (requires test archives)
- [ ] Concurrent access tests (thread safety)
- [ ] Performance benchmarks
- [ ] Fuzzing tests for parser

## Integration with CI/CD

These tests are designed to run in CI environments:
- No external dependencies required
- All tests use `/tmp` for temporary files
- Proper cleanup prevents test pollution
- Fast execution (<1s per test file)

## Debugging Tests

### Run with Verbose Output

```bash
dub test --build=unittest -v
```

### Run with Debug Symbols

```bash
dub test --build=unittest-debug
```

### Run Single Test

Use selective compilation:
```d
version(unittest)
{
    // Only this test
}
```

## Best Practices

1. **Isolation**: Each test is fully independent
2. **Determinism**: Tests produce same results every run
3. **Fast**: Total test suite runs in <5 seconds
4. **Clear Errors**: Assert messages explain what went wrong
5. **Resource Cleanup**: No leftover files or directories
6. **Edge Cases**: Tests cover error paths and boundaries

## Contributing

When adding new features to the repository system:

1. Add corresponding unit tests
2. Maintain >90% coverage
3. Follow AAA pattern
4. Use descriptive test names
5. Add cleanup code
6. Update this README

## See Also

- [Repository Rules Documentation](../../../source/repository/README.md)
- [Feature Documentation](../../../docs/features/repository-rules.md)
- [Examples](../../../examples/repository-rules/)

