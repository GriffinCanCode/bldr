# Errors Package

The errors package provides a sophisticated, type-safe error handling system with Result types, error codes, and rich formatting.

## Modules

### Core Modules
- **result.d** - Result<T, E> monad for error handling
- **codes.d** - Error code definitions
- **types.d** - Error type hierarchy
- **context.d** - Error context chains
- **format.d** - Rich error formatting with colors
- **recovery.d** - Error recovery strategies
- **aggregate.d** - Multiple error aggregation

### Utility Modules
- **utils/snippets.d** - Code snippet extraction for error context
- **utils/fuzzy.d** - Fuzzy string matching for "did you mean?" suggestions

## Usage

### Basic Error Handling

```d
import errors;

BuildResult!string parse(string file) {
    try {
        auto content = readText(file);
        return Ok!(string, BuildError)(content);
    } catch (Exception e) {
        return Err!(string, BuildError)(ioError(file, e.msg));
    }
}

auto result = parse("Builderfile")
    .map(content => parseJson(content))
    .andThen(json => validate(json));

if (result.isErr) {
    writeln(format(result.unwrapErr()));
}
```

### Creating Enhanced Parse Errors

```d
import errors;

// Create parse error with full location info
auto error = new ParseError(
    "Builderfile",
    "Unexpected token",
    line: 15,
    column: 3,
    ErrorCode.ParseFailed
);

// Auto-extract code snippet from file
error.extractSnippet();

// Add helpful suggestions
error.addSuggestion(ErrorSuggestion.docs("See syntax guide", "docs/user-guides/examples.md"));
```

### Using "Did You Mean?" Suggestions

```d
import errors;

// Unknown field with typo detection
const string[] validFields = ["language", "type", "sources", "deps"];
auto error = unknownFieldError(
    "Builderfile",
    "languag",  // typo
    validFields,
    line: 12,
    column: 5
);
// Output: Unknown field 'languag'. Did you mean 'language'?

// Unknown target with fuzzy matching
const string[] targets = ["my-app", "my-lib", "my-tests"];
auto error = unknownTargetError("my-ap", targets);
// Output: Target 'my-ap' not found. Did you mean 'my-app'?
```

### Manual Fuzzy Matching

```d
import infrastructure.errors.utils.fuzzy;

// Calculate similarity between strings (0.0 to 1.0)
auto score = similarityScore("language", "languag");  // ~0.875

// Find similar strings from candidates
const string[] candidates = ["executable", "library", "test"];
auto matches = findSimilar("executble", candidates);  // ["executable"]

// Create suggestion message
auto message = didYouMean("languag", validFields);
// "Did you mean 'language'?"
```

### Extracting Code Snippets

```d
import infrastructure.errors.utils.snippets;

// Extract context lines around an error
auto snippet = extractSnippet("Builderfile", line: 15, contextLines: 2);

// Format with line numbers and pointer
auto formatted = formatSnippetWithPointer(snippet, errorLine: 15, column: 3);
// Output:
//   13 | {
//   14 |   "name": "app",
//   15 |   "languag": "go"
//      |   ^^^^^^^^
//   16 | }
```

## Key Features

- Type-safe Result monad (no exceptions)
- Hierarchical error types with codes
- Error context chains for debugging
- Rich formatting with colors and suggestions
- Recovery strategies for transient errors
- Multiple error aggregation
- **File/line/column information on all parse errors**
- **Automatic code snippet extraction**
- **"Did you mean?" suggestions for typos** (fuzzy matching)
- **Comprehensive error code documentation**

