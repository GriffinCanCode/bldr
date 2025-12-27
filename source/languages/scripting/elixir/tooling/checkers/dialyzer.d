module languages.scripting.elixir.tooling.checkers.dialyzer;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.elixir.config;
import infrastructure.utils.logging;

/// Dialyzer result
struct DialyzerResult
{
    bool success;
    string error;
    string[] warnings;
    string[] errors;
    
    bool hasWarnings() const
    {
        return !warnings.empty;
    }
    
    bool hasErrors() const
    {
        return !errors.empty;
    }
}

/// Dialyzer type checker
class DialyzerChecker
{
    /// Run Dialyzer type analysis
    static DialyzerResult check(DialyzerConfig config, string mixCmd = "mix") @system
    {
        DialyzerResult result;
        
        // Check if dialyxir is available (recommended wrapper)
        bool useDialyxir = isDialyxirAvailable(mixCmd);
        
        string[] cmd;
        if (useDialyxir)
        {
            cmd = [mixCmd, "dialyzer"];
            
            if (!config.format.empty)
                cmd ~= ["--format", config.format];
            
            if (config.listUnusedFilters)
                cmd ~= "--list-unused-filters";
        }
        else
        {
            // Use bare dialyzer
            cmd = ["dialyzer"];
            
            if (!config.pltFile.empty)
                cmd ~= ["--plt", config.pltFile];
            
            cmd ~= config.flags;
        }
        
        // Add paths
        if (!config.paths.empty)
            cmd ~= config.paths;
        
        structuredLog.debug_("running_dialyzer_").field("detail", "Running Dialyzer: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        // Parse output
        auto parsed = parseDialyzerOutput(res.output, useDialyxir);
        result.warnings = parsed.warnings;
        result.errors = parsed.errors;
        
        // Dialyzer returns non-zero if it finds issues
        if (res.status != 0 && !result.hasWarnings())
        {
            result.error = "Dialyzer analysis failed: " ~ res.output;
            result.success = false;
            return result;
        }
        
        result.success = true;
        
        return result;
    }
    
    /// Build/update PLT
    static bool buildPLT(DialyzerConfig config, string mixCmd = "mix") @system
    {
        structuredLog.info("building_dialyzer_plt").emit();
        
        bool useDialyxir = isDialyxirAvailable(mixCmd);
        
        string[] cmd;
        if (useDialyxir)
        {
            cmd = [mixCmd, "dialyzer", "--plt"];
        }
        else
        {
            cmd = ["dialyzer", "--build_plt"];
            
            if (!config.pltFile.empty)
                cmd ~= ["--output_plt", config.pltFile];
            
            if (!config.pltApps.empty)
            {
                cmd ~= "--apps";
                cmd ~= config.pltApps;
            }
        }
        
        auto res = execute(cmd);
        return res.status == 0;
    }
    
    /// Check if Dialyxir is available
    static bool isDialyxirAvailable(string mixCmd = "mix") @system
    {
        auto res = execute([mixCmd, "help", "dialyzer"]);
        return res.status == 0;
    }
    
    /// Check if bare Dialyzer is available
    static bool isDialyzerAvailable() @system
    {
        auto res = execute(["dialyzer", "--version"]);
        return res.status == 0;
    }
    
    /// Parse Dialyzer output
    private static DialyzerResult parseDialyzerOutput(string output, bool isDialyxir) @system
    {
        DialyzerResult result;
        
        import std.regex;
        
        if (isDialyxir)
        {
            // Parse dialyxir format
            // Format: lib/file.ex:line: warning: message
            auto warningRegex = regex(`^([^:]+:\d+:)\s*(warning|error):\s*(.+)$", "m`);
            
            foreach (match; output.matchAll(warningRegex))
            {
                string location = match[1];
                string type = match[2];
                string message = match[3];
                
                string full = location ~ " " ~ type ~ ": " ~ message;
                
                if (type == "error")
                    result.errors ~= full;
                else
                    result.warnings ~= full;
            }
        }
        else
        {
            // Parse bare Dialyzer output
            // Each warning is on its own line
            foreach (line; output.splitLines())
            {
                if (line.strip.empty)
                    continue;
                
                if (line.canFind("Warning:") || line.canFind("warning:"))
                    result.warnings ~= line.strip;
                else if (line.canFind("Error:") || line.canFind("error:"))
                    result.errors ~= line.strip;
            }
        }
        
        result.success = true;
        return result;
    }
}

