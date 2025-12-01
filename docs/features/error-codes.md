# Error Codes Reference

Builder uses a comprehensive error code system to help you quickly identify and resolve issues. Each error includes:

- **Error Code**: A unique numeric identifier (e.g., `2000`)
- **Error Category**: High-level classification (e.g., `Parse`)
- **Message**: Human-readable description
- **File/Line Info**: Exact location of the error (when available)
- **Code Snippet**: Context showing the problematic code
- **Suggestions**: Actionable steps to resolve the issue
- **"Did you mean?" hints**: Automatic typo detection for field names and targets

## Error Code Ranges

- **0-999**: General errors
- **1000-1999**: Build execution errors
- **2000-2999**: Parse/configuration errors
- **3000-3999**: Dependency analysis errors
- **4000-4999**: Cache and repository errors
- **5000-5999**: I/O and filesystem errors
- **6000-6999**: Graph-related errors
- **7000-7999**: Language handler errors
- **8000-8999**: System-level errors
- **9000-9999**: LSP and watch mode errors

---

## General Errors (0-999)

### `0` - UnknownError

**Description**: An unexpected error occurred that doesn't fit into any specific category.

**Example**:
```
[Internal:UnknownError] An unexpected error occurred
```

**Suggestions**:
- Run with `--verbose` for more details
- Check system logs
- Report as a bug with reproduction steps

---

## Build Errors (1000-1999)

### `1000` - BuildFailed

**Description**: A target failed to build successfully.

**Example**:
```
[Build:BuildFailed] Build failed for target 'my-app'
  File: Builderfile
  Target: my-app
  Failed dependencies: core-lib

Suggestions:
  - Run with verbose output: bldr build --verbose
  - Check for compilation errors in source files
  - Verify all dependencies are properly configured
```

**Resolution**:
- Check compiler/tool output for specific errors
- Verify all source files compile individually
- Ensure dependencies are built successfully

---

### `1001` - BuildTimeout

**Description**: Build process exceeded the configured timeout.

**Example**:
```
[Build:BuildTimeout] Build timed out after 300 seconds for target 'slow-build'
  Target: slow-build
  Timeout: 300s

Suggestions:
  - Increase timeout in configuration: timeout: 600
  - Check for infinite loops or blocking operations
```

**Resolution**:
- Increase timeout value in Builderfile
- Profile build to identify bottlenecks
- Break large targets into smaller ones

---

### `1003` - TargetNotFound

**Description**: Referenced target doesn't exist in the build configuration.

**Example**:
```
[Build:TargetNotFound] Target 'my-ap' not found. Did you mean 'my-app'?

Suggestions:
  - Check if the target name is spelled correctly (typos detected automatically)
  - List available targets: bldr query --targets
  - Check target name spelling in Builderfile
```

**Resolution**:
- Check for typos in target name
- Verify target is defined in Builderfile
- Use `bldr query --targets` to list valid targets

---

### `1004` - HandlerNotFound

**Description**: No language handler available for the specified language.

**Example**:
```
[Build:HandlerNotFound] No handler found for language 'fortran'

Suggestions:
  - Verify language handler is installed for this file type
  - List supported languages: bldr query --languages
```

**Resolution**:
- Check if language is supported by Builder
- Install required language plugin
- Verify language name is correct

---

## Parse Errors (2000-2999)

### `2000` - ParseFailed

**Description**: Failed to parse build configuration file.

**Example**:
```
[Parse:ParseFailed] Unexpected character '}' in Builderfile
  File: Builderfile:15:3

  13 |   "deps": [
  14 |     "core-lib"
  15 |   }}
     |   ^
  16 | }

Suggestions:
  - Review Builderfile syntax documentation: docs/user-guides/examples.md
  - Check for missing commas, brackets, or quotes
  - Check for typos in field names or keywords
```

**Resolution**:
- Check for syntax errors at indicated line
- Ensure all brackets/braces are balanced
- Validate JSON/TOML syntax

---

### `2001` - InvalidJson

**Description**: JSON syntax error in configuration file.

**Example**:
```
[Parse:InvalidJson] Invalid JSON: trailing comma after last element
  File: package.json:8:5

   6 |     "name": "my-project",
   7 |     "version": "1.0.0",
   8 |   },
     |    ^

Suggestions:
  - Validate JSON syntax: cat package.json | python3 -m json.tool
  - Check for trailing commas (not allowed in JSON)
  - Verify all strings are properly quoted
```

**Resolution**:
- Remove trailing commas
- Use a JSON validator
- Check quote matching

---

### `2002` - InvalidBuildFile

**Description**: Builderfile structure is invalid or missing required fields.

**Example**:
```
[Parse:InvalidBuildFile] Builderfile is missing required 'targets' field

Suggestions:
  - Create a valid Builderfile: bldr init
  - See Builderfile examples: docs/user-guides/examples.md
  - Check for required fields: targets array
```

**Resolution**:
- Initialize with `bldr init`
- Review Builderfile structure in documentation
- Ensure all required fields are present

---

### `2003` - MissingField

**Description**: A required configuration field is missing.

**Example**:
```
[Parse:MissingField] Missing required field 'name' in target definition
  File: Builderfile:10:1

   9 | {
  10 |   "type": "executable",
  11 |   "language": "go"
  12 | }

Suggestions:
  - Add the required field to your configuration
  - See configuration schema: docs/architecture/dsl.md
```

**Resolution**:
- Add the missing field
- Check documentation for required fields
- Review similar examples

---

### `2004` - InvalidFieldValue

**Description**: Field value doesn't match expected type or enum.

**Example**:
```
[Parse:InvalidFieldValue] Unknown field 'languag'. Did you mean 'language'?
  File: Builderfile:12:3

  11 |   "name": "my-app",
  12 |   "languag": "python",
      |   ^^^^^^^^
  13 |   "type": "executable"

Suggestions:
  - Check the field value against allowed types/enums
  - Review field requirements: docs/architecture/dsl.md
  - Check for typos in field names
```

**Resolution**:
- Fix typo in field name
- Check allowed values for the field
- Verify field type matches schema

---

### `2005` - InvalidGlob

**Description**: Glob pattern syntax is invalid.

**Example**:
```
[Parse:InvalidGlob] Invalid glob pattern: 'src/[*.d'
  File: Builderfile:15:15

  14 |   "sources": [
  15 |     "src/[*.d"
      |          ^^^^^

Suggestions:
  - Check glob pattern syntax (e.g., src/**/*.d)
  - Test glob pattern: ls -d src/**/*.d
```

**Resolution**:
- Fix glob pattern syntax
- Test pattern in shell
- Use standard glob wildcards: `*`, `**`, `?`, `[...]`

---

## Analysis Errors (3000-3999)

### `3000` - AnalysisFailed

**Description**: Dependency analysis failed for a target.

**Example**:
```
[Analysis:AnalysisFailed] Failed to analyze imports for target 'web-app'
  Target: web-app

Suggestions:
  - Run with verbose output: bldr build --verbose
  - Check for syntax errors in source files
```

**Resolution**:
- Check source file syntax
- Verify import paths
- Review language-specific requirements

---

### `3001` - ImportResolutionFailed

**Description**: Unable to resolve an imported module or file.

**Example**:
```
[Analysis:ImportResolutionFailed] Cannot resolve import './util/helpers'
  Target: web-app
  Unresolved imports:
    - ./util/helpers

Suggestions:
  - Verify imported file exists
  - Check import paths in configuration
  - Ensure dependencies are properly declared
```

**Resolution**:
- Check file exists at import path
- Verify import path syntax
- Add missing dependencies

---

### `3002` - CircularDependency

**Description**: Circular dependency detected in build graph.

**Example**:
```
[Analysis:CircularDependency] Circular dependency detected
  Dependency cycle:
    app → lib-a → lib-b → app

Suggestions:
  - Visualize dependency graph to identify cycle: bldr query --graph
  - Break the cycle by removing or refactoring dependencies
```

**Resolution**:
- Identify the cycle in dependency chain
- Refactor to remove circular dependency
- Extract common code to a new module

---

### `3003` - MissingDependency

**Description**: Referenced dependency is not defined.

**Example**:
```
[Analysis:MissingDependency] Dependency 'utils-lib' not found for target 'app'
  Target: app
  Missing dependency: utils-lib

Suggestions:
  - Add missing dependency to target configuration
  - Check available targets: bldr query --targets
```

**Resolution**:
- Define the missing target
- Check dependency name for typos
- Ensure target is in workspace

---

## Cache Errors (4000-4999)

### `4000` - CacheLoadFailed

**Description**: Failed to load data from cache.

**Example**:
```
[Cache:CacheLoadFailed] Failed to load cached build for 'my-app'

Suggestions:
  - Clear cache and retry: bldr clean --cache
  - Check cache directory permissions
```

**Resolution**:
- Clear cache with `bldr clean --cache`
- Check filesystem permissions
- Verify cache directory is not corrupted

---

### `4002` - CacheCorrupted

**Description**: Cache data is corrupted or invalid.

**Example**:
```
[Cache:CacheCorrupted] Cache entry corrupted for target 'my-lib'

Suggestions:
  - Clear the corrupted cache: bldr clean --cache
  - Rebuild from clean state
```

**Resolution**:
- Delete cache directory
- Rebuild from scratch
- Check for disk errors

---

### `4007` - NetworkError

**Description**: Network error during remote cache operation.

**Example**:
```
[Cache:NetworkError] Failed to fetch from remote cache: connection timeout

Suggestions:
  - Check network connectivity
  - Verify proxy settings if behind a firewall
  - Test network access: curl -v <cache-url>
```

**Resolution**:
- Check internet connection
- Verify cache server is accessible
- Configure proxy if needed

---

## I/O Errors (5000-5999)

### `5000` - FileNotFound

**Description**: Specified file does not exist.

**Example**:
```
[IO:FileNotFound] File not found: 'src/main.go'

Suggestions:
  - Verify the file path is correct and the file exists
  - Check current directory contents: ls -la
```

**Resolution**:
- Check file path is correct
- Verify file exists in filesystem
- Check for typos in path

---

### `5001` - FileReadFailed

**Description**: Failed to read file contents.

**Example**:
```
[IO:FileReadFailed] Failed to read file: 'config.toml': Permission denied

Suggestions:
  - Check file read permissions: ls -l config.toml
  - Add read permission: chmod +r config.toml
```

**Resolution**:
- Check file permissions
- Verify file is not locked
- Ensure sufficient access rights

---

### `5004` - PermissionDenied

**Description**: Insufficient permissions for operation.

**Example**:
```
[IO:PermissionDenied] Permission denied: cannot execute './build.sh'

Suggestions:
  - Check file permissions: ls -l ./build.sh
  - Add execute permission: chmod +x ./build.sh
  - Try running with appropriate user/group ownership
```

**Resolution**:
- Add required permissions with `chmod`
- Run with appropriate user
- Check ownership with `ls -l`

---

## System Errors (8000-8999)

### `8000` - ProcessSpawnFailed

**Description**: Failed to spawn subprocess.

**Example**:
```
[System:ProcessSpawnFailed] Failed to execute command 'gcc'
  Command: gcc -o app main.c
  Exit code: 127

Suggestions:
  - Check if required tool is installed and in PATH: which gcc
  - Verify command permissions and PATH
  - Run command manually to debug: gcc -o app main.c
```

**Resolution**:
- Install required tool
- Add tool to PATH
- Verify tool is executable

---

## LSP Errors (9000-9999)

### `9001` - LSPInitializationFailed

**Description**: Language Server Protocol initialization failed.

**Example**:
```
[LSP:LSPInitializationFailed] Failed to initialize LSP server

Suggestions:
  - Check LSP server configuration
  - Verify workspace is initialized
  - Restart editor/IDE
```

**Resolution**:
- Restart LSP server
- Check logs for detailed errors
- Verify workspace setup

---

## Error Code Summary Table

| Code | Name | Category | Common Causes |
|------|------|----------|---------------|
| 0 | UnknownError | Internal | Unexpected conditions |
| 1000 | BuildFailed | Build | Compilation errors |
| 1001 | BuildTimeout | Build | Slow builds, infinite loops |
| 1003 | TargetNotFound | Build | Typos, missing targets |
| 1004 | HandlerNotFound | Build | Unsupported language |
| 2000 | ParseFailed | Parse | Syntax errors |
| 2001 | InvalidJson | Parse | JSON syntax errors |
| 2002 | InvalidBuildFile | Parse | Missing required fields |
| 2003 | MissingField | Parse | Configuration incomplete |
| 2004 | InvalidFieldValue | Parse | Wrong type or typo |
| 2005 | InvalidGlob | Parse | Invalid pattern syntax |
| 3000 | AnalysisFailed | Analysis | Source file errors |
| 3001 | ImportResolutionFailed | Analysis | Missing imports |
| 3002 | CircularDependency | Analysis | Dependency cycle |
| 3003 | MissingDependency | Analysis | Undefined dependency |
| 4000 | CacheLoadFailed | Cache | Cache read errors |
| 4002 | CacheCorrupted | Cache | Corrupted cache data |
| 4007 | NetworkError | Cache | Network issues |
| 5000 | FileNotFound | IO | Missing files |
| 5001 | FileReadFailed | IO | Permission issues |
| 5004 | PermissionDenied | IO | Access denied |
| 8000 | ProcessSpawnFailed | System | Tool not found |
| 9001 | LSPInitializationFailed | LSP | LSP setup issues |

---

## Using Error Codes Programmatically

Error codes can be caught and handled programmatically:

```d
import infrastructure.errors;

auto result = parse("Builderfile");
if (result.isErr)
{
    auto error = result.unwrapErr();
    
    // Check error code
    switch (error.code())
    {
        case ErrorCode.FileNotFound:
            // Handle missing file
            break;
        case ErrorCode.ParseFailed:
            // Handle parse error
            break;
        default:
            // Generic handling
            break;
    }
}
```

---

## Tips for Error Resolution

1. **Read the full error message**: Error codes include file, line, and column information
2. **Check code snippets**: The context shows exactly where the issue is
3. **Follow suggestions**: Actionable steps are provided for each error
4. **Use "did you mean?" hints**: Automatic typo detection helps catch common mistakes
5. **Enable verbose output**: Run with `--verbose` for more details
6. **Check documentation**: Links to relevant docs are included in suggestions

---

## Reporting Issues

If you encounter an error that:
- Has unclear messaging
- Provides incorrect suggestions
- Should include typo detection but doesn't

Please report it with:
- Full error output
- Builderfile content
- Steps to reproduce

This helps us improve error messages for everyone!

