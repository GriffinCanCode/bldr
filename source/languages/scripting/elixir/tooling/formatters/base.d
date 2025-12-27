module languages.scripting.elixir.tooling.formatters.base;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import languages.scripting.elixir.config;
import infrastructure.utils.logging;

/// Format result
struct FormatResult
{
    bool success;
    string error;
    string[] issues;
    bool formatted;
    
    bool hasIssues() const
    {
        return !issues.empty;
    }
}

/// Elixir formatter (mix format)
class Formatter
{
    /// Format files
    static FormatResult format(
        FormatConfig config,
        const string[] files,
        string mixCmd = "mix",
        bool checkOnly = false
    )
    {
        FormatResult result;
        
        string[] cmd = [mixCmd, "format"];
        
        if (checkOnly)
            cmd ~= "--check-formatted";
        
        // Use inputs from config if no files specified
        if (files.empty && !config.inputs.empty)
        {
            cmd ~= config.inputs;
        }
        else if (!files.empty)
        {
            cmd ~= files;
        }
        
        structuredLog.debug_("running_formatter_").field("detail", "Running formatter: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            if (checkOnly)
            {
                // Parse unformatted files from output
                result.issues = parseUnformattedFiles(res.output);
                result.success = false;
                result.error = "Files are not properly formatted";
            }
            else
            {
                result.success = false;
                result.error = "Formatting failed: " ~ res.output;
            }
            return result;
        }
        
        result.success = true;
        result.formatted = !checkOnly;
        
        return result;
    }
    
    /// Check if mix format is available
    static bool isAvailable(string mixCmd = "mix")
    {
        auto res = execute([mixCmd, "help", "format"]);
        return res.status == 0;
    }
    
    /// Parse unformatted files from mix format --check-formatted output
    private static string[] parseUnformattedFiles(string output)
    {
        string[] files;
        
        import std.regex;
        import std.string : strip;
        
        // Match file paths in format output
        auto fileRegex = regex(`^\*\*\s+(.+\.exs?)$", "m`);
        
        foreach (match; output.matchAll(fileRegex))
        {
            files ~= match[1].strip;
        }
        
        return files;
    }
}

