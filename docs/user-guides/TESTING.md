# Test Command Guide

## Overview

The `bldr test` command provides a unified interface for running tests across all supported languages. It automatically discovers test targets, executes them in parallel, and provides comprehensive reporting with CI/CD integration.

## Features

### Core Capabilities

- **Automatic Test Discovery**: Finds all targets with `type: test`
- **Pattern Matching**: Filter tests by name or path patterns
- **Parallel Execution**: Runs tests concurrently for better performance
- **Result Caching**: Skips unchanged tests for faster iteration
- **Multi-Language Support**: Works with any language handler that implements test execution
- **JUnit XML Export**: Compatible with Jenkins, GitHub Actions, GitLab CI, etc.
- **Comprehensive Reporting**: Detailed statistics and failure analysis

### Test Discovery

Builder discovers tests in several ways:

1. **Explicit Test Targets**: Targets with `type: test` in Builderfile
2. **Convention-Based**: Files matching test patterns (test_*.py, *_test.go, etc.)
3. **Zero-Config**: Automatic detection in projects without Builderfile

## Usage

### Basic Usage

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

### Filtering Tests

```bash
# Filter by pattern
bldr test --filter unit

# Filter by path
bldr test --filter "//core"

# Run specific test type
bldr test --filter integration
```

### Test Execution Control

```bash
# Stop on first failure
bldr test --fail-fast

# Show passed tests
bldr test --show-passed

# Combine options
bldr test --verbose --fail-fast --filter unit
```

### CI/CD Integration

```bash
# Generate JUnit XML report
bldr test --junit test-results.xml

# Use with custom path
bldr test --junit reports/junit.xml

# CI-friendly output
bldr test --mode plain --junit results.xml
```

## Output Format

### Standard Output

```
=== Running Tests ===
Found 5 test target(s)

✓ //core:unit-tests (123 ms)
✓ //api:integration-tests (456 ms) [cached]
✗ //services:load-tests (789 ms)
  Error: Test assertion failed
  ✗ test_high_load
    Expected: 1000, Got: 850

=== Test Summary ===

Test Targets:  5
  Passed:  4
  Failed:  1
  Cached: 1

Test Cases:    45
  Passed:  44
  Failed:  1

Duration:      2.3s

Tests failed!
```

### Verbose Output

Shows individual test cases:

```bash
bldr test --verbose
```

```
✓ //core:unit-tests (123 ms)
  ✓ test_parser_basic
  ✓ test_parser_complex
  ✓ test_parser_error_handling
  ...
```

## JUnit XML Format

The JUnit XML export is compatible with:

- **Jenkins**: Native support
- **GitHub Actions**: Use with test reporters
- **GitLab CI**: JUnit test reports
- **Azure Pipelines**: Test results publishing
- **CircleCI**: Test metadata

### Example Integration

#### GitHub Actions

```yaml
- name: Run tests
  run: bldr test --junit test-results.xml

- name: Publish test results
  uses: EnricoMi/publish-unit-test-result-action@v2
  if: always()
  with:
    files: test-results.xml
```

#### GitLab CI

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

```python
target(
    name = "unit-tests",
    type = "test",
    language = "python",
    sources = [
        "tests/test_*.py",
    ],
    deps = [
        "//src:mylib",
    ],
    env = {
        "PYTEST_ARGS": "-v",
    },
)

target(
    name = "integration-tests",
    type = "test",
    language = "go",
    sources = [
        "tests/integration/*_test.go",
    ],
    deps = [
        "//internal:server",
    ],
)
```

### Language-Specific Configuration

Each language handler can configure its test framework:

#### Python (pytest, unittest)
```python
target(
    name = "tests",
    type = "test",
    language = "python",
    sources = ["tests/"],
    config = {
        "test": {
            "framework": "pytest",
            "args": ["-v", "--cov=src"],
        },
    },
)
```

#### Go (go test)
```python
target(
    name = "tests",
    type = "test",
    language = "go",
    sources = ["**/*_test.go"],
    config = {
        "test": {
            "args": ["-race", "-cover"],
        },
    },
)
```

#### JavaScript (Jest, Mocha)
```python
target(
    name = "tests",
    type = "test",
    language = "javascript",
    sources = ["tests/**/*.test.js"],
    config = {
        "test": {
            "framework": "jest",
            "config": "jest.config.js",
        },
    },
)
```

## Test Caching

Builder caches test results based on:

1. **Test source files**: Hash of all test files
2. **Source dependencies**: Hash of code under test
3. **Test configuration**: Test framework and flags
4. **External dependencies**: Package versions

### Cache Behavior

- **Cache Hit**: Test skipped, previous result reported
- **Cache Miss**: Test executed normally
- **Force Rerun**: Use `bldr clean` then `bldr test`

### Cache Invalidation

Tests are re-run when:
- Test source files change
- Source code under test changes
- Dependencies are updated
- Test configuration changes

## Exit Codes

- `0`: All tests passed
- `1`: One or more tests failed
- Other: Build/execution error

## Advanced Usage

### Watch Mode

Combine with watch mode for continuous testing:

```bash
bldr watch test
```

### Query Test Targets

List all test targets:

```bash
bldr query 'kind(test, //...)'
```

Find tests that depend on a library:

```bash
bldr query 'rdeps(//lib:mylib) intersect kind(test, //...)'
```

### Parallel Execution

Tests run in parallel automatically based on available CPU cores. The execution engine respects test dependencies and topological ordering.

## Language Support

The following languages have test execution support:

| Language   | Test Frameworks                    |
|------------|-----------------------------------|
| Python     | pytest, unittest, nose            |
| JavaScript | Jest, Mocha, Jasmine              |
| TypeScript | Jest, Mocha, Jasmine              |
| Go         | go test                           |
| Rust       | cargo test                        |
| Java       | JUnit, TestNG                     |
| C++        | Google Test, Catch2               |
| C#         | NUnit, xUnit, MSTest              |
| Ruby       | RSpec, Minitest                   |
| PHP        | PHPUnit, Pest, Codeception        |
| Elixir     | ExUnit                            |
| Lua        | Busted, LuaUnit                   |
| R          | testthat, tinytest                |
| Perl       | Test::More, Prove                 |
| Scala      | ScalaTest, Specs2                 |

## Best Practices

### 1. Test Organization

```
project/
  src/
    module.py
  tests/
    unit/
      test_module.py
    integration/
      test_api.py
    e2e/
      test_workflow.py
```

### 2. Target Naming

Use descriptive, hierarchical names:

```python
target(name = "unit-tests")
target(name = "integration-tests")
target(name = "e2e-tests")
```

### 3. Test Dependencies

Explicitly declare dependencies:

```python
target(
    name = "tests",
    type = "test",
    deps = [
        "//src:lib",
        "//testutils:fixtures",
    ],
)
```

### 4. CI/CD Integration

Always generate JUnit XML in CI:

```bash
bldr test --junit test-results.xml --mode plain
```

## Troubleshooting

### Tests Not Discovered

1. Check target type: `type = "test"`
2. Verify source patterns match files
3. Use `bldr infer` to see auto-detection
4. Check `.builderignore` isn't excluding tests

### Tests Always Re-run (Cache Miss)

1. Check if test files have timestamps changing
2. Verify dependencies are stable
3. Look for random/time-dependent tests
3. Check environment variables

### Flaky Tests

1. Use `--fail-fast` to stop on first failure
2. Check for race conditions in parallel tests
3. Review test isolation
4. Check for order dependencies

### Performance Issues

1. Split large test suites into multiple targets
2. Use `--filter` for incremental testing
3. Check test parallelization
4. Profile slow tests

## Examples

### Full Test Suite

```bash
# Run all tests with full reporting
bldr test --verbose --junit test-results.xml
```

### Quick Smoke Test

```bash
# Run only unit tests, fast fail
bldr test --filter unit --fail-fast
```

### CI Pipeline

```bash
# CI-friendly: plain output, JUnit export
bldr test --mode plain --junit results.xml
```

### Development Workflow

```bash
# Watch mode with filter
bldr watch "test --filter unit"
```

## Coverage Support (Future)

The `--coverage` flag is reserved for future coverage reporting:

```bash
# Future: Generate coverage report
bldr test --coverage

# Future: Coverage with specific format
bldr test --coverage --coverage-format html
```

## See Also

- [CLI Guide](CLI.md) - General command-line usage
- [Builderfile Syntax](../architecture/DSL.md) - Target configuration
- [Language Support](../README.md) - Supported languages
- [Examples](EXAMPLES.md) - Example projects

