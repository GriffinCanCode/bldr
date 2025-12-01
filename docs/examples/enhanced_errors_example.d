#!/usr/bin/env rdmd
/**
 * Enhanced Error Messages Example
 * 
 * This example demonstrates Builder's enhanced error handling features:
 * - File/line/column information on all parse errors
 * - Automatic code snippet extraction
 * - "Did you mean?" suggestions for typos
 * - Comprehensive error codes with documentation
 * 
 * Compile: dmd -I../../source enhanced_errors_example.d
 * Run: ./enhanced_errors_example
 */

import std.stdio;
import std.file;
import infrastructure.errors;

void main()
{
    writeln("=== Enhanced Error Messages Example ===\n");
    
    // Example 1: Parse error with file/line/column info
    demonstrateParseError();
    
    // Example 2: Unknown field with "did you mean?" suggestion
    demonstrateTypoDetection();
    
    // Example 3: Unknown target with fuzzy matching
    demonstrateTargetSuggestion();
    
    // Example 4: Error code documentation
    demonstrateErrorCodes();
}

void demonstrateParseError()
{
    writeln("Example 1: Parse Error with Location Info");
    writeln("-------------------------------------------");
    
    // Create a parse error with full location info
    auto error = new ParseError(
        "Builderfile",
        "Unexpected character '}' - unmatched closing brace",
        15,  // line
        3,   // column
        ErrorCode.ParseFailed
    );
    
    // Auto-extract snippet from file (if it exists)
    error.extractSnippet();
    
    // Add contextual suggestions
    error.addSuggestion(ErrorSuggestion.fileCheck("Check for matching opening brace"));
    error.addSuggestion(ErrorSuggestion.docs("Review syntax", "docs/user-guides/examples.md"));
    
    // Format and display
    writeln(format(error));
    writeln();
}

void demonstrateTypoDetection()
{
    writeln("Example 2: Typo Detection in Field Names");
    writeln("-----------------------------------------");
    
    // Simulate unknown field with similar valid fields
    const string[] validFields = [
        "language", "type", "sources", "deps", "output", "flags", "env"
    ];
    
    auto error = unknownFieldError(
        "Builderfile",
        "languag",  // typo: missing 'e'
        validFields,
        12,  // line
        5    // column
    );
    
    writeln(format(error));
    writeln();
}

void demonstrateTargetSuggestion()
{
    writeln("Example 3: Target Name Suggestions");
    writeln("-----------------------------------");
    
    // Simulate unknown target with similar targets
    const string[] availableTargets = [
        "my-app", "my-lib", "my-tests", "web-server", "api-client"
    ];
    
    auto error = unknownTargetError(
        "my-ap",  // typo: missing 'p'
        availableTargets,
        "Builderfile"
    );
    
    writeln(format(error));
    writeln();
}

void demonstrateErrorCodes()
{
    writeln("Example 4: Error Code Information");
    writeln("----------------------------------");
    
    // Show how error codes work
    writeln("Error Code: ", ErrorCode.ParseFailed);
    writeln("Category: ", ErrorCategory.Parse);
    writeln("Description: ", errorMessage(ErrorCode.ParseFailed));
    writeln();
    
    writeln("Error Code: ", ErrorCode.TargetNotFound);
    writeln("Category: ", ErrorCategory.Build);
    writeln("Description: ", errorMessage(ErrorCode.TargetNotFound));
    writeln();
    
    writeln("All error codes are documented in:");
    writeln("  docs/features/error-codes.md");
    writeln();
}

void demonstrateFuzzyMatching()
{
    writeln("Example 5: Fuzzy String Matching");
    writeln("---------------------------------");
    
    import infrastructure.errors.utils.fuzzy;
    
    // Test similarity scoring
    writeln("Similarity between 'language' and 'languag': ",
        similarityScore("language", "languag"));
    
    writeln("Similarity between 'my-app' and 'my-ap': ",
        similarityScore("my-app", "my-ap"));
    
    writeln("Similarity between 'test' and 'build': ",
        similarityScore("test", "build"));
    
    writeln();
    
    // Test finding similar strings
    const string[] candidates = ["executable", "library", "test", "custom"];
    auto similar = findSimilar("executble", candidates, 0.6, 3);  // typo: missing 'a'
    
    writeln("Finding matches for 'executble':");
    foreach (match; similar)
        writeln("  - ", match);
    
    writeln();
}

void demonstrateSnippetExtraction()
{
    writeln("Example 6: Code Snippet Extraction");
    writeln("-----------------------------------");
    
    import infrastructure.errors.utils.snippets;
    
    // Create a test file
    string testFile = "test_builderfile.json";
    std.file.write(testFile, `{
  "targets": [
    {
      "name": "my-app",
      "type": "executable",
      "languag": "python"
    }
  ]
}`);
    
    scope(exit) if (exists(testFile)) remove(testFile);
    
    // Extract snippet around line 6 (the typo)
    auto snippet = extractSnippet(testFile, 6, 2);
    writeln("Extracted snippet:");
    writeln(snippet);
    writeln();
    
    // Format with pointer
    auto formatted = formatSnippetWithPointer(snippet, 6, 15, 4);
    writeln("Formatted with pointer:");
    writeln(formatted);
}

/**
 * Example output:
 * 
 * Example 1: Parse Error with Location Info
 * -------------------------------------------
 * [Parse:ParseFailed] Unexpected character '}' - unmatched closing brace
 *   File: Builderfile:15:3
 * 
 *   13 |   "deps": [
 *   14 |     "core-lib"
 *   15 |   }}
 *        |   ^
 *   16 | }
 * 
 * Suggestions:
 *   - Check for matching opening brace
 *   - Review syntax: docs/user-guides/examples.md
 * 
 * Example 2: Typo Detection in Field Names
 * -----------------------------------------
 * [Parse:InvalidFieldValue] Unknown field 'languag'. Did you mean 'language'?
 *   File: Builderfile:12:5
 * 
 *   10 |   "name": "my-app",
 *   11 |   "type": "executable",
 *   12 |   "languag": "python"
 *        |   ^^^^^^^^
 * 
 * Suggestions:
 *   - See valid fields: docs/user-guides/examples.md
 * 
 * Example 3: Target Name Suggestions
 * -----------------------------------
 * [Build:TargetNotFound] Target 'my-ap' not found. Did you mean 'my-app'?
 * 
 * Suggestions:
 *   - List available targets: bldr query --targets
 *   - Check Builderfile for target definitions
 * 
 * Example 4: Error Code Information
 * ----------------------------------
 * Error Code: ParseFailed
 * Category: Parse
 * Description: Parse error
 * 
 * Error Code: TargetNotFound
 * Category: Build
 * Description: Target not found
 * 
 * All error codes are documented in:
 *   docs/features/error-codes.md
 */

