module infrastructure.errors.formatting.format;

import std.conv;
import std.algorithm;
import std.array;
import std.range;
import std.format : formattedWrite;
import infrastructure.errors.types.types;
import infrastructure.errors.codes;
import infrastructure.errors.types.context : ErrorSuggestion, ErrorContext;
import infrastructure.errors.formatting.colors : ColorFormatter, Color;
import infrastructure.errors.formatting.suggestions : SuggestionGenerator;

private import std.string : sformat = format;

/// Formatting options for error display
struct FormatOptions
{
    bool colors = true;        // Use ANSI colors
    bool showCode = true;      // Show error code
    bool showCategory = true;  // Show error category
    bool showContexts = true;  // Show context chain
    bool showSuggestions = true; // Show helpful suggestions
    bool showTimestamp = false; // Show timestamps
    size_t maxWidth = 80;      // Max line width
}

/// Format error for display
string format(const BuildError error, FormatOptions opts = FormatOptions.init)
{
    import std.array : appender;
    auto result = appender!string;
    result.reserve(256);
    auto colorFmt = ColorFormatter(opts.colors);
    
    // Header with category and code
    if (opts.showCategory)
    {
        result.put(colorFmt.error("["));
        result.put(error.category().to!string);
        if (opts.showCode)
        {
            result.put(":");
            result.put(error.code().to!string);
        }
        result.put("] ");
    }
    
    // Main message
    result.put(colorFmt.colored(error.message(), Color.Red));
    result.put("\n");
    
    // Context chain
    if (opts.showContexts)
        foreach (ctx; error.contexts())
        {
            result.put(colorFmt.muted("  → " ~ ctx.toString()));
            result.put("\n");
        }
    
    // Type-specific formatting
    result.put(formatSpecific(error, opts));
    
    // Add suggestions
    if (opts.showSuggestions)
    {
        auto suggestions = SuggestionGenerator.generate(error);
        if (!suggestions.empty)
        {
            result.put("\n");
            result.put(colorFmt.warning(colorFmt.bold("Suggestions:\n")));
            bool[string] seen;
            foreach (suggestion; suggestions)
            {
                string formatted = formatSuggestion(suggestion, opts);
                if (formatted !in seen)
                {
                    seen[formatted] = true;
                    result.put(formatted);
                }
            }
        }
    }
    
    return result.data;
}

/// Format a single suggestion with type-specific styling
string formatSuggestion(const ErrorSuggestion suggestion, FormatOptions opts)
{
    import std.array : appender;
    auto result = appender!string;
    auto colorFmt = ColorFormatter(opts.colors);
    
    result.put(colorFmt.warning("  • "));
    
    // Icon/prefix based on type
    final switch (suggestion.type)
    {
        case ErrorSuggestion.Type.Command: result.put(colorFmt.success("Run: ")); break;
        case ErrorSuggestion.Type.Documentation: result.put(colorFmt.info("Docs: ")); break;
        case ErrorSuggestion.Type.FileCheck: result.put(colorFmt.warning("Check: ")); break;
        case ErrorSuggestion.Type.Configuration: result.put(colorFmt.warning("Config: ")); break;
        case ErrorSuggestion.Type.General: break;
    }
    
    result.put(suggestion.message);
    
    // Detail (command, URL, etc.)
    if (!suggestion.detail.empty)
    {
        result.put("\n    ");
        final switch (suggestion.type)
        {
            case ErrorSuggestion.Type.Command: result.put(colorFmt.muted("$ " ~ suggestion.detail)); break;
            case ErrorSuggestion.Type.Documentation: result.put(colorFmt.muted("→ " ~ suggestion.detail)); break;
            case ErrorSuggestion.Type.FileCheck:
            case ErrorSuggestion.Type.Configuration:
            case ErrorSuggestion.Type.General: result.put(colorFmt.muted(suggestion.detail)); break;
        }
    }
    
    result.put("\n");
    return result.data;
}

/// Format type-specific error details
private string formatSpecific(const BuildError error, FormatOptions opts)
{
    import std.traits : hasMember;
    import std.array : appender;
    
    auto result = appender!string;
    result.reserve(128);
    
    // Try to cast to known types for additional formatting
    if (auto buildErr = cast(const BuildFailureError)error)
    {
        if (opts.colors)
            result.put(cast(string)Color.Gray);
        result.put("  Target: ");
        result.put(buildErr.targetId);
        result.put("\n");
        
        if (!buildErr.failedDeps.empty)
        {
            result.put("  Failed dependencies:\n");
            foreach (dep; buildErr.failedDeps)
            {
                result.put("    - ");
                result.put(dep);
                result.put("\n");
            }
        }
        
        if (opts.colors)
            result.put(cast(string)Color.Reset);
    }
    else if (auto parseErr = cast(const ParseError)error)
    {
        if (opts.colors)
            result.put(cast(string)Color.Gray);
        
        if (!parseErr.filePath.empty)
        {
            result.put("  File: ");
            result.put(parseErr.filePath);
            if (parseErr.line > 0)
            {
                result.put(":");
                result.put(parseErr.line.to!string);
            }
            if (parseErr.column > 0)
            {
                result.put(":");
                result.put(parseErr.column.to!string);
            }
            result.put("\n");
        }
        
        if (!parseErr.snippet.empty)
        {
            result.put("\n");
            result.put(formatCodeSnippet(parseErr.snippet, parseErr.line, opts));
            result.put("\n");
        }
        
        if (opts.colors)
            result.put(cast(string)Color.Reset);
    }
    else if (auto analysisErr = cast(const AnalysisError)error)
    {
        if (opts.colors)
            result.put(cast(string)Color.Gray);
        
        result.put("  Target: ");
        result.put(analysisErr.targetName);
        result.put("\n");
        
        if (!analysisErr.unresolvedImports.empty)
        {
            result.put("  Unresolved imports:\n");
            foreach (imp; analysisErr.unresolvedImports)
            {
                result.put("    - ");
                result.put(imp);
                result.put("\n");
            }
        }
        
        if (!analysisErr.cyclePath.empty)
        {
            result.put("  Dependency cycle:\n    ");
            result.put(analysisErr.cyclePath.join(" → "));
            result.put("\n");
        }
        
        if (opts.colors)
            result.put(cast(string)Color.Reset);
    }
    else if (auto langErr = cast(const LanguageError)error)
    {
        if (opts.colors)
            result.put(cast(string)Color.Gray);
        
        result.put("  Language: ");
        result.put(langErr.language);
        result.put("\n");
        
        if (!langErr.filePath.empty)
        {
            result.put("  File: ");
            result.put(langErr.filePath);
            if (langErr.line > 0)
            {
                result.put(":");
                result.put(langErr.line.to!string);
            }
            result.put("\n");
        }
        
        if (!langErr.compilerOutput.empty)
        {
            result.put("\n  Compiler output:\n");
            result.put(indent(langErr.compilerOutput, 4));
            result.put("\n");
        }
        
        if (opts.colors)
            result.put(cast(string)Color.Reset);
    }
    
    return result.data;
}

/// Format a code snippet with line numbers and highlighting
private string formatCodeSnippet(string code, size_t errorLine, FormatOptions opts)
{
    import std.array : appender;
    auto lines = code.split("\n");
    auto result = appender!string;
    result.reserve(code.length + lines.length * 20); // Reserve space for line numbers and formatting
    
    foreach (i, line; lines)
    {
        size_t lineNum = errorLine + i;
        
        if (opts.colors)
            result.put(cast(string)Color.Gray);
        
        result.put(sformat("%4d | ", lineNum));
        
        if (opts.colors && i == 0)
            result.put(cast(string)Color.Red);
        
        result.put(line);
        
        if (opts.colors)
            result.put(cast(string)Color.Reset);
        
        result.put("\n");
    }
    
    return result.data;
}

/// Indent text by N spaces
private string indent(string text, size_t spaces)
{
    import std.algorithm : map;
    import std.array : join;
    import std.range : repeat;
    auto prefix = " ".repeat(spaces).join();
    return text.split("\n").map!(line => prefix ~ line).join("\n");
}

/// Format multiple errors as a tree
string formatTree(const BuildError[] errors, FormatOptions opts = FormatOptions.init)
{
    if (errors.empty) return "";
    import std.array : appender;
    auto result = appender!string;
    
    if (opts.colors) result.put(cast(string)(Color.Bold ~ Color.Red));
    result.put("Build failed with ");
    result.put(errors.length.to!string);
    result.put(" error(s):\n\n");
    if (opts.colors) result.put(cast(string)Color.Reset);
    
    foreach (i, error; errors)
    {
        result.put(sformat("Error %d:\n", i + 1));
        result.put(indent(format(error, opts), 2));
        result.put("\n");
    }
    return result.data;
}

/// Create a summary of errors by category
string summarize(const BuildError[] errors)
{
    size_t[ErrorCategory] counts;
    
    foreach (error; errors)
        counts[error.category()]++;
    
    string result = "Error summary:\n";
    
    foreach (cat; counts.keys.sort())
    {
        result ~= sformat("  %s: %d\n", cat.to!string, counts[cat]);
    }
    
    return result;
}