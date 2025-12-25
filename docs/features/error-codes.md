# Error Codes Reference

Builder uses a structured error code system for programmatic error handling. Each error includes:

- **Error Code**: Numeric identifier (e.g., `2000`)
- **Error Category**: Classification (Build, Parse, Analysis, etc.)
- **Recoverability**: Fatal, Transient (retryable), or User (configuration issue)
- **Message**: Human-readable description
- **File/Line Info**: Location when available
- **Code Snippet**: Context showing the error location
- **Suggestions**: Actionable resolution steps
- **"Did you mean?" hints**: Fuzzy matching for typos in field names and targets

## Error Code Ranges

| Range | Category | Description |
|-------|----------|-------------|
| 0-999 | General | Unknown/unexpected errors |
| 1000-1999 | Build | Build execution errors |
| 2000-2999 | Parse | Configuration parsing errors |
| 3000-3999 | Analysis | Dependency analysis errors |
| 4000-4599 | Cache | Cache and repository errors |
| 5000-5999 | IO | File system errors |
| 6000-6999 | Graph | Dependency graph errors |
| 7000-7999 | Language | Language handler errors |
| 8000-8999 | System | System-level errors |
| 9000-9999 | Internal | Internal/unexpected errors |
| 10000-10999 | Telemetry | Telemetry errors |
| 11000-11999 | Tracing | Distributed tracing errors |
| 12000-12999 | Distributed | Distributed build errors |
| 13000-13999 | Plugin | Plugin system errors |
| 14000-14999 | LSP | Language Server Protocol errors |
| 15000-15999 | Watch | Watch mode errors |
| 16000-16999 | Config | Configuration/validation errors |
| 17000-17999 | Migration | Migration errors |

---

## Build Errors (1000-1999)

### `1000` - BuildFailed

Build execution failed.

```
[Build:BuildFailed] Build failed for target 'my-app'
  File: Builderfile
  Target: my-app
  Failed dependencies: core-lib

Suggestions:
  - Run with verbose output: bldr build --verbose
  - Check for compilation errors in source files
```

### `1001` - BuildTimeout

Build exceeded configured timeout.

```
[Build:BuildTimeout] Build timed out after 300 seconds for target 'slow-build'
  Target: slow-build
  Timeout: 300s

Suggestions:
  - Increase timeout in configuration
  - Check for infinite loops or blocking operations
```

**Recoverability**: Transient (can retry with longer timeout)

### `1002` - BuildCancelled

Build was cancelled (e.g., user interrupt).

### `1003` - TargetNotFound

Referenced target doesn't exist.

```
[Build:TargetNotFound] Target 'my-ap' not found. Did you mean 'my-app'?

Suggestions:
  - List available targets: bldr query --targets
  - Check target name spelling
```

**Recoverability**: User (fix target name)

### `1004` - HandlerNotFound

No language handler for the specified language.

```
[Build:HandlerNotFound] No handler found for language 'fortran'

Suggestions:
  - List supported languages: bldr query --languages
  - Check 'language' field spelling
```

### `1005` - OutputMissing

Expected build output not found after execution.

---

## Parse Errors (2000-2999)

### `2000` - ParseFailed

Failed to parse configuration file.

```
[Parse:ParseFailed] Unexpected character '}' in Builderfile
  File: Builderfile:15:3

  13 |   "deps": [
  14 |     "core-lib"
  15 |   }}
     |   ^
  16 | }

Suggestions:
  - Check for missing commas, brackets, or quotes
  - Validate syntax: docs/user-guides/examples.md
```

### `2001` - InvalidJson

JSON syntax error.

```
[Parse:InvalidJson] Invalid JSON: trailing comma
  File: package.json:8:5

   6 |     "name": "my-project",
   7 |     "version": "1.0.0",
   8 |   },
     |    ^

Suggestions:
  - Validate JSON: python3 -m json.tool < file.json
  - Remove trailing commas
```

### `2002` - InvalidBuildFile

Builderfile structure invalid or missing required fields.

### `2003` - MissingField

Required configuration field missing.

```
[Parse:MissingField] Missing required field 'name' in target definition
  File: Builderfile:10:1

Suggestions:
  - Add the required field
  - See configuration schema: docs/architecture/dsl.md
```

### `2004` - InvalidFieldValue

Field value doesn't match expected type or has typo.

```
[Parse:InvalidFieldValue] Unknown field 'languag'. Did you mean 'language'?
  File: Builderfile:12:3

  11 |   "name": "my-app",
  12 |   "languag": "python",
      |   ^^^^^^^^
```

### `2005` - InvalidGlob

Glob pattern syntax error.

```
[Parse:InvalidGlob] Invalid glob pattern: 'src/[*.d'

Suggestions:
  - Check glob pattern syntax (e.g., src/**/*.d)
  - Test pattern: ls -d src/**/*.d
```

### `2006` - InvalidConfiguration

General configuration error.

---

## Analysis Errors (3000-3999)

### `3000` - AnalysisFailed

Dependency analysis failed.

### `3001` - ImportResolutionFailed

Unable to resolve an import.

```
[Analysis:ImportResolutionFailed] Cannot resolve import './util/helpers'
  Target: web-app
  Unresolved imports:
    - ./util/helpers

Suggestions:
  - Verify imported file exists
  - Check import path syntax
```

### `3002` - CircularDependency

Circular dependency detected.

```
[Analysis:CircularDependency] Circular dependency detected
  Dependency cycle:
    app → lib-a → lib-b → app

Suggestions:
  - Visualize graph: bldr query --graph
  - Break the cycle by refactoring
```

### `3003` - MissingDependency

Referenced dependency not defined.

### `3004` - InvalidImport

Invalid import statement syntax.

---

## Cache Errors (4000-4999)

### `4000` - CacheLoadFailed

Failed to load from cache.

**Recoverability**: Transient

### `4001` - CacheSaveFailed

Failed to save to cache.

### `4002` - CacheCorrupted

Cache data corrupted.

```
Suggestions:
  - Clear cache: bldr clean --cache
  - Rebuild from clean state
```

### `4007` - NetworkError (4013)

Network error during remote cache operation.

**Recoverability**: Transient

### Repository Errors (4500-4599)

- `4500` - RepositoryError
- `4501` - RepositoryNotFound
- `4502` - RepositoryFetchFailed (Transient)
- `4503` - RepositoryVerificationFailed
- `4504` - VerificationFailed
- `4505` - RepositoryInvalid
- `4506` - RepositoryTimeout (Transient)
- `4507` - RepositoryAlreadyAdded

---

## IO Errors (5000-5999)

### `5000` - FileNotFound

File does not exist.

```
[IO:FileNotFound] File not found: 'src/main.go'

Suggestions:
  - Verify file path: ls -la
  - Check for typos
```

### `5001` - FileReadFailed

Failed to read file.

### `5002` - FileWriteFailed

Failed to write file.

### `5003` - FileDeleteFailed

Failed to delete file.

### `5004` - DirectoryNotFound

Directory does not exist.

### `5005` - PermissionDenied

Insufficient permissions.

```
Suggestions:
  - Check permissions: ls -l <file>
  - Add permission: chmod +x <file>
```

---

## Graph Errors (6000-6999)

### `6000` - GraphCycle

Cycle detected in dependency graph.

### `6001` - GraphInvalid

Invalid graph structure.

### `6002` - NodeNotFound

Graph node not found.

### `6003` - EdgeInvalid

Invalid graph edge.

---

## Language Errors (7000-7999)

### `7000` - SyntaxError

Source file syntax error.

### `7001` - CompilationFailed

Compilation failed.

### `7002` - ValidationFailed

Code validation failed.

### `7003` - UnsupportedLanguage

Language not supported.

### `7004` - MissingCompiler

Required compiler not found.

### `7005` - MacroExpansionFailed

Macro expansion failed.

### `7006` - MacroLoadFailed

Failed to load macro.

---

## System Errors (8000-8999)

### `8000` - ProcessSpawnFailed

Failed to spawn process.

```
[System:ProcessSpawnFailed] Failed to execute command 'gcc'
  Command: gcc -o app main.c
  Exit code: 127

Suggestions:
  - Check if tool is installed: which gcc
  - Verify PATH configuration
```

### `8001` - ProcessTimeout

Process exceeded timeout.

**Recoverability**: Transient

### `8002` - ProcessCrashed

Process crashed.

### `8003` - OutOfMemory

Memory allocation failed.

### `8004` - ThreadPoolError

Thread pool error.

---

## Plugin Errors (13000-13999)

### `13000` - PluginError

General plugin error.

### `13001` - PluginNotFound

Plugin not found.

### `13002` - PluginLoadFailed

Failed to load plugin.

### `13003` - PluginCrashed

Plugin crashed during execution.

### `13004` - PluginTimeout

Plugin operation timed out.

**Recoverability**: Transient

### `13005` - PluginInvalidResponse

Plugin returned invalid response.

### `13006` - PluginProtocolError

Plugin protocol violation.

### `13007` - PluginVersionMismatch

Plugin version incompatible.

### `13008` - PluginCapabilityMissing

Plugin missing required capability.

---

## LSP Errors (14000-14999)

### `14000` - LSPError

General LSP error.

### `14001` - LSPInitializationFailed

LSP server failed to initialize.

### `14002` - LSPInvalidRequest

Invalid LSP request.

### `14003` - LSPMethodNotFound

LSP method not found.

### `14004` - LSPInvalidParams

Invalid LSP parameters.

### `14005` - LSPDocumentNotFound

Document not found in LSP workspace.

### `14006` - LSPParseError

LSP parse error.

### `14007` - LSPServerCrashed

LSP server crashed.

### `14008` - LSPTimeout

LSP operation timed out.

**Recoverability**: Transient

### `14009` - LSPInvalidPosition

Invalid position in document.

### `14010` - LSPWorkspaceNotInitialized

LSP workspace not initialized.

---

## Watch Errors (15000-15999)

### `15000` - WatchError

General watch mode error.

### `15001` - WatcherInitFailed

Failed to initialize file watcher.

### `15002` - WatcherNotSupported

File watcher not supported on platform.

### `15003` - WatcherCrashed

File watcher crashed.

**Recoverability**: Transient

### `15004` - FileWatchFailed

Failed to watch specific file.

**Recoverability**: Transient

### `15005` - DebounceError

Watch debounce error.

### `15006` - TooManyWatchTargets

Too many files to watch.

---

## Config Errors (16000-16999)

### `16000` - ConfigError

General configuration error.

### `16001` - InvalidWorkspace

Invalid workspace configuration.

### `16002` - InvalidTarget

Invalid target configuration.

### `16003` - InvalidInput

Invalid input.

### `16004` - SchemaValidationFailed

Schema validation failed.

### `16005` - DeprecatedField

Deprecated field used.

### `16006` - RequiredFieldMissing

Required field missing.

### `16007` - DuplicateTarget

Duplicate target name.

### `16008` - ConfigConflict

Configuration conflict.

---

## Migration Errors (17000-17999)

### `17000` - MigrationFailed

Migration from another build system failed.

---

## Recoverability Classification

Errors are classified by recoverability:

| Classification | Description | Action |
|----------------|-------------|--------|
| **Fatal** | Cannot recover, build fails | Fix configuration or code |
| **Transient** | Temporary, can retry | Automatic retry with backoff |
| **User** | Configuration/usage error | User must fix |

### Transient Errors (Auto-Retry)

```
BuildTimeout, CacheLoadFailed, CacheTimeout, NetworkError,
ProcessTimeout, CoordinatorTimeout, WorkerTimeout,
ArtifactTransferFailed, PluginTimeout, LSPTimeout,
WatcherCrashed, FileWatchFailed, RepositoryFetchFailed,
RepositoryTimeout
```

### User Errors (Fix Required)

```
ParseFailed, InvalidJson, InvalidBuildFile, MissingField,
InvalidFieldValue, TargetNotFound, FileNotFound,
CircularDependency, MissingDependency, SyntaxError,
UnsupportedLanguage, MissingCompiler
```

---

## Programmatic Error Handling

```d
import infrastructure.errors;

auto result = parse("Builderfile");
if (result.isErr)
{
    auto error = result.unwrapErr();
    
    switch (error.code())
    {
        case ErrorCode.FileNotFound:
            // Handle missing file
            break;
        case ErrorCode.ParseFailed:
            // Handle parse error
            break;
        default:
            if (error.recoverable())
                // Retry operation
            break;
    }
}
```

---

## Fuzzy Matching ("Did You Mean?")

Builder uses Levenshtein distance to suggest corrections for typos:

```d
import infrastructure.errors.utils.fuzzy : didYouMean, findSimilar;

// Find similar strings
auto matches = findSimilar("executble", ["executable", "library"]);
// Returns: ["executable"]

// Create suggestion message
auto message = didYouMean("languag", ["language", "type", "sources"]);
// Returns: "Did you mean 'language'?"
```

---

## Tips for Resolution

1. **Read full error message**: Includes file, line, and column
2. **Check code snippets**: Shows exact error location
3. **Follow suggestions**: Actionable steps provided
4. **Use fuzzy hints**: Automatic typo detection
5. **Enable verbose output**: `bldr build --verbose`
6. **Check documentation**: Links included in suggestions
