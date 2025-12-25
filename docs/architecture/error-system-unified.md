# Unified Error System

## Overview

Builder uses a unified error system with a consistent hierarchy across the codebase. All errors implement the `BuildError` interface and extend `BaseBuildError`.

## Error Hierarchy

```d
BuildError (interface)
  └── BaseBuildError (abstract base class)
        ├── BuildFailureError
        ├── ParseError
        ├── AnalysisError
        ├── CacheError
        ├── IOError
        ├── GraphError
        ├── LanguageError
        ├── SystemError
        ├── InternalError
        ├── PluginError
        ├── LSPError
        ├── WatchError
        ├── ConfigError
        ├── NetworkError
        └── GenericError
```

## Error Categories

Errors are classified into 13 categories:

| Category | Description |
|----------|-------------|
| Build | Build execution errors |
| Parse | Configuration parsing errors |
| Analysis | Dependency analysis errors |
| Cache | Cache operation errors |
| IO | File system errors |
| Graph | Dependency graph errors |
| Language | Language handler errors |
| System | System-level errors |
| Internal | Internal/unexpected errors |
| Plugin | Plugin system errors |
| LSP | LSP server errors |
| Watch | Watch mode errors |
| Config | Configuration/validation errors |

## Recoverability Classification

Errors are classified by recoverability:

### Fatal
Cannot be recovered, must fail the build:
- Build failures
- Syntax errors
- Graph cycles
- Internal errors

### Transient
Temporary failures that can be retried:
- Build timeout
- Cache timeout
- Network errors
- Process timeout
- Repository fetch failures

### User
Incorrect configuration or usage:
- Parse errors
- Invalid configuration
- Target not found
- File not found
- Permission denied

## Error Code Ranges

| Range | Category |
|-------|----------|
| 0-999 | General errors |
| 1000-1999 | Build errors |
| 2000-2999 | Parse errors |
| 3000-3999 | Analysis errors |
| 4000-4499 | Cache errors |
| 4500-4599 | Repository errors |
| 5000-5999 | IO errors |
| 6000-6999 | Graph errors |
| 7000-7999 | Language errors |
| 8000-8999 | System errors |
| 9000-9999 | Internal errors |
| 10000-10999 | Telemetry errors |
| 11000-11999 | Tracing errors |
| 12000-12999 | Distributed build errors |
| 13000-13999 | Plugin errors |
| 14000-14999 | LSP errors |
| 15000-15999 | Watch mode errors |
| 16000-16999 | Configuration errors |
| 17000-17999 | Migration errors |

## Central Error Registry

**Location**: `source/infrastructure/errors/handling/codes.d`

```d
struct ErrorRegistryEntry
{
    ErrorCode code;
    ErrorCategory category;
    Recoverability recoverability;
    string message;
    string[] defaultSuggestions;
    string docsUrl;
}
```

## Design Principles

### 1. Single Base Implementation

All error types extend `BaseBuildError`, which provides:
- Automatic error code to category mapping
- Automatic recoverability determination
- Error context chains
- Suggestion management
- Consistent formatting

### 2. Derived Properties

Error types do not override `category()` or `recoverable()`. These are derived from the error code using optimized lookup tables in `codes.d`:

```d
ErrorCategory category() const pure nothrow
{
    return categoryOf(_code);
}

bool recoverable() const pure nothrow
{
    return isRecoverable(_code);
}
```

### 3. Builder Pattern

Fluent API for error construction:

```d
auto error = ErrorBuilder!ParseError.create(filePath, message)
    .withContext("parsing", "Builderfile")
    .withSuggestion("Check JSON syntax")
    .withDocs("See examples", "docs/user-guides/examples.md")
    .build();
```

### 4. Unified Factory

`Errors` struct provides entry point for all error construction:

```d
Errors.parse("file.txt", "Invalid syntax")
    .withContext("parsing config")
    .withDocs("See syntax guide", "docs/syntax.md")

Errors.cache("Cache corrupted", ErrorCode.CacheCorrupted)
    .withCommand("Clear cache", "bldr clean --cache")
```

## Usage

### Creating Errors

```d
// Simple error
auto error = new BuildFailureError("myTarget", "Compilation failed");

// Error with context
auto error = new ParseError("Builderfile", "Invalid JSON")
    .withContext(ErrorContext("parsing", "target 'build'"))
    .withSuggestion(ErrorSuggestion.command("Validate JSON", "jsonlint Builderfile"));

// Using builder pattern
auto error = ErrorBuilder!AnalysisError.create("myTarget", "Circular dependency")
    .withContext("dependency analysis", "resolving imports")
    .withSuggestion("Break the cycle by removing a dependency")
    .withDocs("See architecture guide", "docs/architecture/overview.md")
    .build();

// Smart constructors
auto error = fileNotFoundError("Builderfile");
auto error = targetNotFoundError("myTarget");
auto error = circularDependencyError(["A", "B", "C", "A"]);
```

### Error Handling

```d
// Using Result type
Result!(string, BuildError) parse(string file)
{
    if (!exists(file))
        return Err!(string, BuildError)(fileNotFoundError(file, "parsing"));
    
    try {
        auto content = readText(file);
        return Ok!(string, BuildError)(content);
    } catch (Exception e) {
        return Err!(string, BuildError)(
            fileReadError(file, e.msg, "parsing")
        );
    }
}

// Checking error properties
if (error.recoverable()) {
    retry(operation);
} else if (error.recoverability() == Recoverability.User) {
    showSuggestions(error.suggestions());
} else {
    abort(error);
}
```

### Query Error Metadata

```d
auto entry = lookupError(ErrorCode.BuildFailed);
writeln("Category: ", entry.category);
writeln("Recoverable: ", entry.recoverability);
writeln("Message: ", entry.message);
writeln("Docs: ", entry.docsUrl);
foreach (suggestion; entry.defaultSuggestions)
    writeln("  - ", suggestion);
```

## Implementation Files

| File | Purpose |
|------|---------|
| `infrastructure/errors/handling/codes.d` | Error codes, categories, recoverability |
| `infrastructure/errors/types/types.d` | Error type hierarchy and builders |
| `infrastructure/errors/types/context.d` | Error context and suggestions |
| `infrastructure/errors/types/network.d` | Network error specialization |
| `infrastructure/errors/helpers/builders.d` | Smart error constructors |
| `infrastructure/errors/helpers/manifests.d` | Manifest-specific errors |
| `infrastructure/errors/formatting/suggestions.d` | Suggestion generation |
