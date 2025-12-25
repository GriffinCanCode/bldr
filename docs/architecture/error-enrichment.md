# Error Message Enrichment

## Overview

Builder provides a comprehensive error enrichment system that automatically adds context, file locations, and actionable suggestions to error messages. This helps users diagnose and resolve issues efficiently.

## Components

### SuggestionGenerator

**Location**: `source/infrastructure/errors/formatting/suggestions.d`

Generates contextual suggestions based on error codes:

- **IO Errors** (5000-5999): File operation failures with permission and path guidance
- **Parse Errors** (2000-2999): Syntax validation with format-specific help
- **Analysis Errors** (3000-3999): Dependency resolution with graph commands
- **Build Errors** (1000-1999): Compilation failures with debugging commands
- **Cache Errors** (4000-4999): Cache operation issues with cleanup commands
- **System Errors** (8000-8999): Process and memory errors with resource tips
- **Language Errors** (7000-7999): Compiler errors with toolchain guidance
- **Plugin/LSP/Watch Errors**: Subsystem-specific suggestions

### Error Builder Helpers

**Location**: `source/infrastructure/errors/helpers/builders.d`

Smart error constructors that automatically add:

- **Source location tracking**: Captures file and line where error was created
- **Operation context**: What was being attempted when error occurred
- **File-type specific suggestions**: Different guidance based on file being processed

Available helpers:

```d
// Parse errors with file-type specific suggestions
auto error = createParseError(filePath, message, code);

// File operations with existence checks
auto error = createFileReadError(filePath, context);

// Analysis errors with dependency-specific guidance
auto error = createAnalysisError(targetName, message, code);

// Build failures with compiler-specific help
auto error = createBuildError(targetId, message, code);

// Language errors with toolchain detection
auto error = createLanguageError(language, message, code);

// Cache errors with path and cleanup guidance
auto error = createCacheError(message, code, cachePath);

// System errors with resource management tips
auto error = createSystemError(message, code);
```

### Manifest-Specific Helpers

**Location**: `source/infrastructure/errors/helpers/manifests.d`

Ecosystem integration errors with package-manager specific guidance:

```d
// Manifest not found (suggests initialization commands)
manifestNotFoundError(path, "npm|cargo|go|python|composer");

// Parse failures (format-specific validation)
manifestParseError(path, type, parseError);

// Missing fields (shows expected format)
manifestMissingFieldError(path, type, fieldName);

// Invalid values (explains correct format)
manifestInvalidFieldError(path, type, field, value, expected);

// Dependency resolution (package manager commands)
manifestDependencyError(path, type, depName, reason);

// Version mismatches (upgrade guidance)
manifestVersionError(path, type, current, supported);

// Tool missing (installation instructions)
ecosystemToolMissingError(tool, type);
```

## Error Context Chain

Errors include a context chain showing the operation stack:

```
[Parse:ParseFailed] Failed to parse package.json: Invalid JSON
  → during: parsing configuration file (package.json) at npm.d:60
  → during: loading project manifests

Suggestions:
  • Run: Validate JSON syntax
    $ cat package.json | python3 -m json.tool
  • Check for trailing commas (not allowed in JSON)
  • Docs: See package.json examples
    → docs/features/ecosystem-integration.md
```

## File-Type Specific Suggestions

The system recognizes file types and provides targeted help:

| File | Suggestions |
|------|-------------|
| `package.json` | JSON validation, npm commands, trailing comma detection |
| `Cargo.toml` | TOML syntax validation, cargo check commands |
| `go.mod` | go mod tidy commands, module path verification |
| `pyproject.toml` / `setup.py` | pip install validation, packaging guides |
| `composer.json` | composer validate commands |
| `Builderfile` | DSL syntax documentation, field validation |

## Automatic Location Tracking

Error helpers capture:
- Source file where error was created
- Line number in source
- Function/operation context

This enables precise error tracking for debugging.

## Usage

### Before (Basic Error)

```d
auto error = new ParseError(filePath, "Parse error: " ~ e.msg, ErrorCode.ParseFailed);
return Result.err(error);
```

Output:
```
[Parse:ParseFailed] Parse error: unexpected token
  File: package.json
```

### After (Enriched Error)

```d
return Result.err(manifestParseError(filePath, "npm", "Invalid JSON: " ~ e.msg));
```

Output:
```
[Parse:ParseFailed] Failed to parse npm manifest: Invalid JSON: unexpected token
  → during: parsing npm manifest at npm.d:60
  File: package.json

Suggestions:
  • Run: Validate JSON syntax
    $ cat package.json | python3 -m json.tool
  • Check for trailing commas (not allowed in JSON)
  • Docs: See package.json examples
    → docs/features/ecosystem-integration.md
```

## Integration Points

### Manifest Parsers
- `npm.d` - Node.js package.json
- `cargo.d` - Rust Cargo.toml
- `go.d` - Go go.mod
- `python.d` - Python pyproject.toml/setup.py
- `composer.d` - PHP composer.json

### Build Pipeline
- `parser.d` - Configuration parsing
- `analyzer.d` - Incremental analysis
- `cas.d` - Cache operations

## Formatting Options

```d
FormatOptions opts;
opts.colors = true;           // ANSI colors in terminal
opts.showCode = true;         // Show error code
opts.showCategory = true;     // Show category
opts.showContexts = true;     // Show context chain
opts.showSuggestions = true;  // Show suggestions
opts.showTimestamp = false;   // Show when error occurred
opts.maxWidth = 80;           // Wrap long lines

string formatted = format(error, opts);
```

## Suggestion Types

- **Command**: Runnable CLI commands
- **Documentation**: Links to relevant docs
- **FileCheck**: File/permission validation steps
- **Configuration**: Config file changes
- **General**: General advice

## Migration Guide

To adopt enriched errors:

1. Import helpers:
   ```d
   import infrastructure.errors.helpers;
   ```

2. Replace basic error construction:
   ```d
   // Before
   auto error = new ParseError(path, msg, code);
   
   // After
   auto error = createParseError(path, msg, code);
   ```

3. Add custom context if needed:
   ```d
   error.addContext(ErrorContext("operation", "details"));
   error.addSuggestion(ErrorSuggestion.command("desc", "cmd"));
   ```

4. For manifest errors, use specialized helpers:
   ```d
   manifestNotFoundError(path, "npm");
   manifestParseError(path, "cargo", msg);
   manifestDependencyError(path, "python", dep, reason);
   ```

## Testing

```d
// Trigger parse error with invalid JSON
auto result = parser.parse("invalid.json");
assert(result.isErr);

auto error = result.unwrapErr();
assert(error.suggestions().length > 0);
assert(error.contexts().length > 0);

// Verify JSON-specific suggestions
bool hasJSONValidation = false;
foreach (s; error.suggestions())
    if (s.message.canFind("JSON"))
        hasJSONValidation = true;
assert(hasJSONValidation);
```
