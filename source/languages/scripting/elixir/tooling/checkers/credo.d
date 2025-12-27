module languages.scripting.elixir.tooling.checkers.credo;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.scripting.elixir.config;
import infrastructure.utils.logging;

/// Credo result
struct CredoResult
{
    bool success;
    string error;
    string[] warnings;
    string[] errors;
    int issueCount;
    
    bool hasWarnings() const
    {
        return !warnings.empty;
    }
    
    bool hasErrors() const
    {
        return !errors.empty;
    }
}

/// Credo static code analyzer
class CredoChecker
{
    /// Run Credo analysis
    static CredoResult check(CredoConfig config, string mixCmd = "mix")
    {
        CredoResult result;
        
        string[] cmd = [mixCmd, "credo"];
        
        if (config.strict)
            cmd ~= "--strict";
        
        if (config.all)
            cmd ~= "--all";
        
        if (!config.minPriority.empty)
            cmd ~= ["--min-priority", config.minPriority];
        
        if (!config.format.empty)
            cmd ~= ["--format", config.format];
        
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["--config-file", config.configFile];
        
        // Add specific checks if configured
        if (!config.checks.empty)
        {
            foreach (check; config.checks)
            {
                cmd ~= ["--checks", check];
            }
        }
        
        // Add files if configured
        if (!config.files.empty)
            cmd ~= config.files;
        
        structuredLog.debug_("running_credo_").field("detail", "Running Credo: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        // Parse output
        auto parsed = parseCredoOutput(res.output);
        result.warnings = parsed.warnings;
        result.errors = parsed.errors;
        result.issueCount = cast(int)(result.warnings.length + result.errors.length);
        
        // Credo returns non-zero if it finds issues
        if (res.status != 0 && result.issueCount == 0)
        {
            result.error = "Credo analysis failed: " ~ res.output;
            result.success = false;
            return result;
        }
        
        result.success = true;
        
        return result;
    }
    
    /// Check if Credo is available
    static bool isAvailable(string mixCmd = "mix")
    {
        auto res = execute([mixCmd, "help", "credo"]);
        return res.status == 0;
    }
    
    /// Suggest Credo checks based on issues
    static string[] suggestChecks(CredoConfig config, string mixCmd = "mix")
    {
        auto res = execute([mixCmd, "credo", "suggest"]);
        
        if (res.status != 0)
            return [];
        
        // Parse suggested checks from output
        return parseSuggestedChecks(res.output);
    }
    
    /// Parse Credo output
    private static CredoResult parseCredoOutput(string output)
    {
        CredoResult result;
        
        import std.regex;
        
        // Parse Credo output format
        // Format variations:
        // [R] → Refactoring
        // [W] → Warning  
        // [C] → Consistency
        // [D] → Design
        // [F] → Readability
        
        auto issueRegex = regex(`^\s*\[([RWCDF])\]\s*→\s*(.+)$", "m`);
        
        foreach (match; output.matchAll(issueRegex))
        {
            string category = match[1];
            string message = match[2].strip;
            
            string full = "[" ~ category ~ "] " ~ message;
            
            // Treat as error if it's a critical design issue
            if (category == "D")
                result.errors ~= full;
            else
                result.warnings ~= full;
        }
        
        // Also look for summary line
        auto summaryRegex = regex(`(\d+)\s+(?:issues?|problems?)", "i`);
        auto summaryMatch = output.matchFirst(summaryRegex);
        if (!summaryMatch.empty)
        {
            result.issueCount = summaryMatch[1].to!int;
        }
        
        result.success = true;
        return result;
    }
    
    /// Parse suggested checks from credo suggest output
    private static string[] parseSuggestedChecks(string output)
    {
        string[] checks;
        
        import std.regex;
        
        // Look for check module names
        auto checkRegex = regex(`Credo\.Check\.[\w.]+", "g`);
        
        foreach (match; output.matchAll(checkRegex))
        {
            checks ~= match[0];
        }
        
        return checks;
    }
}

