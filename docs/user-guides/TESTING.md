# Test Command Guide

## Overview

The `bldr test` command runs test targets with support for parallel execution, result caching, retry logic, and CI/CD integration.

## Basic Usage

```bash
# Run all tests
bldr test

# Run specific test target
bldr test //path/to:test-target

# Run with verbose output
bldr test --verbose

# Run tests quietly (errors only)
bldr test --quiet
```

## Configuration

### Configuration File

Create a `.buildertest` configuration file for persistent settings:

```bash
bldr test --init-config
```

This generates a JSON config file. Command-line flags override config file settings.

### CLI Options

**Output Control:**
```bash
bldr test -v, --verbose      # Detailed output
bldr test -q, --quiet        # Minimal output
bldr test --show-passed      # Show passed tests
```

**Execution Control:**
```bash
bldr test --fail-fast        # Stop on first failure
bldr test -j, --jobs N       # Number of parallel jobs (0 = auto)
bldr test --shards N         # Number of test shards
bldr test --no-shard         # Disable test sharding
```

**Caching & Retry:**
```bash
bldr test --no-cache         # Disable test result caching
bldr test --no-retry         # Disable automatic retry
bldr test --max-retries N    # Maximum retry attempts
```

**Reporting:**
```bash
bldr test --analytics        # Generate analytics report
bldr test --junit [PATH]     # Generate JUnit XML report
bldr test --mode MODE        # Render mode: auto, interactive, plain
```

## Test Discovery

Builder discovers tests in several ways:

1. **Explicit Test Targets**: Targets with `type: test` in Builderfile
2. **Convention-Based**: Files matching test patterns (`test_*.py`, `*_test.go`, etc.)
3. **Zero-Config**: Automatic detection in projects without Builderfile

## Output Format

```
Discovering tests...
Found 3 test targets

✓ //core:unit-tests (123 ms)
✓ //api:integration-tests (456 ms) [cached]
✗ //services:load-tests (789 ms)
  Error: Test assertion failed
  ✗ test_high_load
    Expected: 1000, Got: 850

Test Summary:
  Passed: 2
  Failed: 1
  Cached: 1

Total execution time: 1368ms
```

## JUnit XML Export

Generate JUnit-compatible XML for CI/CD systems:

```bash
bldr test --junit test-results.xml
```

### GitHub Actions

```yaml
- name: Run tests
  run: bldr test --junit test-results.xml

- name: Publish test results
  uses: EnricoMi/publish-unit-test-result-action@v2
  if: always()
  with:
    files: test-results.xml
```

### GitLab CI

```yaml
test:
  script:
    - bldr test --junit test-results.xml
  artifacts:
    reports:
      junit: test-results.xml
```

## Test Target Configuration

### Builderfile Example

```
target("unit-tests") {
    type: test;
    language: python;
    sources: ["tests/test_*.py"];
    deps: ["//src:mylib"];
}

target("integration-tests") {
    type: test;
    language: go;
    sources: ["tests/integration/*_test.go"];
    deps: ["//internal:server"];
}
```

### Language-Specific Configuration

**Python:**
```
target("tests") {
    type: test;
    language: python;
    sources: ["tests/"];
}
```

Builder auto-detects pytest, unittest, or nose based on project configuration.

**Go:**
```
target("tests") {
    type: test;
    language: go;
    sources: ["**/*_test.go"];
}
```

**JavaScript/TypeScript:**
```
target("tests") {
    type: test;
    language: javascript;
    sources: ["tests/**/*.test.js"];
}
```

Builder auto-detects Jest, Mocha, Vitest, or falls back to `npm test`.

## Test Caching

Builder caches test results based on:

- Test source files
- Source code under test
- Test configuration
- External dependencies

Tests are re-run when any of these change.

### Cache Behavior

- **Cache Hit**: Test skipped, previous result reported
- **Cache Miss**: Test executed normally
- **Force Rerun**: Use `--no-cache`

## Language Support

| Language | Test Frameworks |
|----------|-----------------|
| Python | pytest, unittest, nose |
| JavaScript | Jest, Mocha, Vitest |
| TypeScript | Jest, Mocha, Vitest |
| Go | go test |
| Rust | cargo test |
| Java | JUnit, TestNG |
| C++ | Google Test, Catch2 |
| C# | NUnit, xUnit, MSTest |
| F# | Expecto, NUnit, xUnit |
| Ruby | RSpec, Minitest, Cucumber |
| PHP | PHPUnit, Pest, Codeception |
| Elixir | ExUnit |
| Lua | Busted, LuaUnit |
| R | testthat, tinytest |
| Perl | Test::More, Prove |
| Scala | ScalaTest, Specs2 |
| Kotlin | JUnit, kotest |

## Exit Codes

- `0`: All tests passed
- `1`: One or more tests failed

## Examples

### Development Workflow

```bash
# Run all tests with full reporting
bldr test --verbose --junit test-results.xml

# Quick unit test run
bldr test --fail-fast

# Run specific target
bldr test //tests:unit
```

### CI Pipeline

```bash
# CI-friendly: plain output, JUnit export
bldr test --mode plain --junit results.xml
```

### With Analytics

```bash
# Generate performance analytics
bldr test --analytics
```

## Troubleshooting

### Tests Not Discovered

1. Check target type: `type: test`
2. Verify source patterns match files
3. Use `bldr infer` to see auto-detection
4. Check `.builderignore` isn't excluding tests

### Tests Always Re-run

1. Check if test files have timestamps changing
2. Verify dependencies are stable
3. Look for random/time-dependent tests
4. Check environment variables

### Flaky Tests

1. Use `--fail-fast` to stop on first failure
2. Check for race conditions in parallel tests
3. Review test isolation
4. Use `--analytics` to identify patterns

## See Also

- [CLI Guide](./CLI.md) - General command-line usage
- [Examples](./examples.md) - Example projects
