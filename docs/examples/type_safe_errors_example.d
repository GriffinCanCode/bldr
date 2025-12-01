#!/usr/bin/env dub
/+ dub.sdl:
    name "type_safe_errors_example"
    dependency "bldr" path="../.."
+/

/**
 * Example demonstrating Builder's type-safe error handling system
 * 
 * This shows how to create strongly-typed errors with structured suggestions
 * instead of using loose "ANY" types.
 */

module examples.type_safe_errors;

import std.stdio;
import std.file;
import errors;
import errors.types.context : ErrorSuggestion;

void main()
{
    writeln("=== Type-Safe Error Handling Examples ===\n");
    
    // Example 1: Using smart constructors
    demonstrateSmartConstructors();
    
    // Example 2: Using the builder pattern
    demonstrateBuilderPattern();
    
    // Example 3: Custom typed suggestions
    demonstrateTypedSuggestions();
    
    // Example 4: Error formatting
    demonstrateFormatting();
}

/// Example 1: Smart constructors automatically add appropriate suggestions
void demonstrateSmartConstructors()
{
    writeln("Example 1: Smart Constructors");
    writeln("------------------------------");
    
    // File not found - automatically includes helpful suggestions
    auto fileError = fileNotFoundError("Builderfile");
    writeln("File Not Found Error:");
    writeln(format(fileError));
    writeln();
    
    // Parse error - includes syntax checking suggestions
    auto parseError = parseErrorWithContext(
        "Builderspace", 
        "Unexpected token at line 15", 
        15,
        "parsing workspace configuration"
    );
    writeln("Parse Error:");
    writeln(format(parseError));
    writeln();
}

/// Example 2: Builder pattern for fluent error construction
void demonstrateBuilderPattern()
{
    writeln("Example 2: Builder Pattern");
    writeln("--------------------------");
    
    // Build a complex error with multiple suggestions using fluent API
    auto error = ErrorBuilder!BuildFailureError
        .create("myapp", "Compilation failed: undefined reference to 'main'")
        .withContext("compiling main.d", "using dmd compiler")
        .withFileCheck("Ensure main.d defines a main() function")
        .withCommand("Check for compilation errors", "dmd -c main.d")
        .withDocs("See D language documentation", "https://dlang.org/spec/function.html")
        .withCommand("Build with verbose output", "bldr build --verbose")
        .build();
    
    writeln("Build Error with Builder Pattern:");
    writeln(format(error));
    writeln();
}

/// Example 3: Creating custom typed suggestions
void demonstrateTypedSuggestions()
{
    writeln("Example 3: Typed Suggestions");
    writeln("----------------------------");
    
    auto error = new LanguageError("D", "Compiler not found", ErrorCode.CompilationFailed);
    
    // Different types of suggestions
    error.addSuggestion(ErrorSuggestion.command(
        "Install D compiler",
        "brew install dmd"
    ));
    
    error.addSuggestion(ErrorSuggestion.fileCheck(
        "Check if dmd is in PATH"
    ));
    
    error.addSuggestion(ErrorSuggestion.config(
        "Set compiler path in Builderspace",
        "compiler_path: \"/usr/local/bin/dmd\""
    ));
    
    error.addSuggestion(ErrorSuggestion.docs(
        "See D installation guide",
        "https://dlang.org/download.html"
    ));
    
    writeln("Language Error with Typed Suggestions:");
    writeln(format(error));
    writeln();
}

/// Example 4: Different formatting options
void demonstrateFormatting()
{
    writeln("Example 4: Error Formatting");
    writeln("---------------------------");
    
    auto error = buildFailureError(
        "webapp",
        "Build failed: test suite returned non-zero exit code",
        ["unit-tests", "integration-tests"]
    );
    
    // Format with colors (default)
    writeln("Formatted with colors:");
    writeln(format(error));
    writeln();
    
    // Format without colors
    auto opts = FormatOptions.init;
    opts.colors = false;
    writeln("Formatted without colors:");
    writeln(format(error, opts));
    writeln();
}

/// Example demonstrating Result type with type-safe errors
Result!(string, BuildError) processFile(string path)
{
    if (!exists(path))
    {
        auto error = fileNotFoundError(path, "processing file");
        return Err!(string, BuildError)(error);
    }
    
    try
    {
        string content = readText(path);
        return Ok!(string, BuildError)(content);
    }
    catch (FileException e)
    {
        auto error = fileReadError(path, e.msg, "processing file");
        return Err!(string, BuildError)(error);
    }
}

/// Example showing how NOT to do it (anti-patterns)
void antiPatterns()
{
    // ❌ BAD: Using vague, untyped errors
    // auto error = new GenericError("Something went wrong");
    
    // ❌ BAD: No context or suggestions
    // auto error = new IOError("", "Failed");
    
    // ❌ BAD: String-based suggestions without structure
    // error.addSuggestion("Try: bldr clean");
    
    // ✅ GOOD: Structured, typed suggestions
    auto error = buildFailureError("myapp", "Build failed");
    error.addSuggestion(ErrorSuggestion.command("Clear cache", "bldr clean"));
    error.addContext(ErrorContext("building target", "using cached dependencies"));
}

