module languages.scripting.lua.tooling.checkers.luacheck;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.regex;
import std.conv;
import std.string : strip;
import languages.scripting.lua.tooling.checkers.base;
import languages.scripting.lua.tooling.detection;
import languages.scripting.lua.core.config;
import infrastructure.utils.logging;

/// Luacheck linter - comprehensive static analyzer for Lua
class LuacheckLinter : Checker
{
    override CheckResult check(const string[] sources, LuaConfig config)
    {
        CheckResult result;
        
        if (!isAvailable())
        {
            result.error = "Luacheck is not installed";
            return result;
        }
        
        string[] cmd = ["luacheck"];
        
        // Add config file if specified
        if (!config.lint.configFile.empty && exists(config.lint.configFile))
        {
            cmd ~= "--config";
            cmd ~= config.lint.configFile;
        }
        else
        {
            // Add inline configuration options
            if (!config.lint.luacheck.std.empty)
            {
                cmd ~= "--std";
                cmd ~= config.lint.luacheck.std;
            }
            
            // Global variables
            if (!config.lint.luacheck.globals.empty)
            {
                cmd ~= "--globals";
                cmd ~= config.lint.luacheck.globals;
            }
            
            // Read-only globals
            if (!config.lint.luacheck.readGlobals.empty)
            {
                cmd ~= "--read-globals";
                cmd ~= config.lint.luacheck.readGlobals;
            }
            
            // Ignore specific warnings
            if (!config.lint.luacheck.ignore.empty)
            {
                cmd ~= "--ignore";
                cmd ~= config.lint.luacheck.ignore;
            }
            
            // Only check specific warnings
            if (!config.lint.luacheck.only.empty)
            {
                cmd ~= "--only";
                cmd ~= config.lint.luacheck.only;
            }
            
            // Max line length
            if (config.lint.luacheck.maxLineLength > 0)
            {
                cmd ~= "--max-line-length";
                cmd ~= config.lint.luacheck.maxLineLength.to!string;
            }
            
            // Max cyclomatic complexity
            if (config.lint.luacheck.maxComplexity > 0)
            {
                cmd ~= "--max-cyclomatic-complexity";
                cmd ~= config.lint.luacheck.maxComplexity.to!string;
            }
            
            // Warning flags
            if (!config.lint.luacheck.warnUnusedArgs)
            {
                cmd ~= "--no-unused-args";
            }
            
            if (!config.lint.luacheck.warnUnusedVars)
            {
                cmd ~= "--no-unused";
            }
            
            if (config.lint.luacheck.warnShadowing)
            {
                cmd ~= "--no-redefined";
            }
            
            if (!config.lint.luacheck.warnGlobals)
            {
                cmd ~= "--no-global";
            }
        }
        
        // Add formatter flag
        cmd ~= "--formatter";
        cmd ~= "plain";
        
        // Add source files
        cmd ~= sources;
        
        structuredLog.debug_("running_luacheck_").field("detail", "Running Luacheck: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        // Luacheck returns:
        // 0 - no warnings
        // 1 - warnings found
        // 2 - errors (syntax, IO, etc.)
        
        if (res.status == 2)
        {
            result.error = "Luacheck error:\n" ~ res.output;
            return result;
        }
        
        if (res.status == 1)
        {
            result.warnings = parseWarnings(res.output);
            
            if (config.lint.failOnWarning)
            {
                result.error = "Luacheck warnings found:\n" ~ res.output;
                return result;
            }
            else
            {
                structuredLog.warning("luacheck_warningsn").field("detail", "Luacheck warnings:\n" ~ res.output).emit();
            }
        }
        
        result.success = true;
        
        return result;
    }
    
    override bool isAvailable()
    {
        return isLuacheckAvailable();
    }
    
    override string name() const
    {
        return "Luacheck";
    }
    
    override string getVersion()
    {
        try
        {
            auto res = execute(["luacheck", "--version"]);
            if (res.status == 0)
            {
                auto output = res.output.strip;
                auto match = matchFirst(output, regex(`(\d+\.\d+\.\d+)`));
                if (!match.empty)
                {
                    return match[1];
                }
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : Logger;
            structuredLog.debug_("failed_to_get_luacheck_version_").field("detail", "Failed to get Luacheck version: " ~ e.msg).emit();
        }
        
        return "unknown";
    }
    
    private string[] parseWarnings(string output)
    {
        // Parse luacheck output for warnings
        string[] warnings;
        
        foreach (line; output.split("\n"))
        {
            auto trimmed = line.strip;
            if (!trimmed.empty && !trimmed.startsWith("Total:") && !trimmed.startsWith("Checking"))
            {
                warnings ~= trimmed;
            }
        }
        
        return warnings;
    }
}

