# C# Example Project

A demonstration of modern C# features and Builder integration.

## Features Demonstrated

- **Modern C# syntax**: Records, pattern matching, nullable reference types
- **LINQ**: Powerful query operations
- **Collections**: Lists and dictionaries
- **Native AOT**: Optional native compilation target

## Building

### Standard Build
```bash
bldr build csharp-app
```

### Native AOT Build (requires .NET 8+)
```bash
bldr build csharp-app-aot
```

### Run
```bash
./bin/csharp-app
```

## C# Features Used

- **Records** (C# 9): Immutable data types
- **Pattern Matching** (C# 8+): Switch expressions
- **Nullable Reference Types** (C# 8+): Null safety
- **Range and Index** (C# 8+): Slice syntax
- **With Expressions** (C# 9): Non-destructive mutation
- **Init-only Properties** (C# 9): Object initialization
- **LINQ**: Query expressions
- **Generics**: Type-safe collections and methods

## Requirements

- .NET 8.0 SDK or later
- For Native AOT: Additional dependencies may be required on Linux/macOS

