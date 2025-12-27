module languages.compiled.nim.tooling.tools;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import infrastructure.utils.logging;

/// Nim tooling utilities and version detection
class NimTools
{
    private static bool nimChecked = false;
    private static bool nimAvailable = false;
    private static string nimVersionCache;
    
    private static bool nimbleChecked = false;
    private static bool nimbleAvailable = false;
    private static string nimbleVersionCache;
    
    /// Check if nim compiler is available
    static bool isNimAvailable()
    {
        if (nimChecked)
            return nimAvailable;
        
        nimChecked = true;
        
        try
        {
            auto res = execute(["nim", "--version"]);
            nimAvailable = res.status == 0;
            
            if (nimAvailable && nimVersionCache.empty)
            {
                nimVersionCache = parseNimVersion(res.output);
            }
        }
        catch (Exception e)
        {
            nimAvailable = false;
        }
        
        return nimAvailable;
    }
    
    /// Get Nim compiler version
    static string getNimVersion()
    {
        if (!nimVersionCache.empty)
            return nimVersionCache;
        
        if (!isNimAvailable())
            return "unknown";
        
        try
        {
            auto res = execute(["nim", "--version"]);
            if (res.status == 0)
            {
                nimVersionCache = parseNimVersion(res.output);
                return nimVersionCache;
            }
        }
        catch (Exception e)
        {
            // Fallback
        }
        
        return "unknown";
    }
    
    /// Check if nimble is available
    static bool isNimbleAvailable()
    {
        if (nimbleChecked)
            return nimbleAvailable;
        
        nimbleChecked = true;
        
        try
        {
            auto res = execute(["nimble", "--version"]);
            nimbleAvailable = res.status == 0;
            
            if (nimbleAvailable && nimbleVersionCache.empty)
            {
                nimbleVersionCache = parseNimbleVersion(res.output);
            }
        }
        catch (Exception e)
        {
            nimbleAvailable = false;
        }
        
        return nimbleAvailable;
    }
    
    /// Get Nimble version
    static string getNimbleVersion()
    {
        if (!nimbleVersionCache.empty)
            return nimbleVersionCache;
        
        if (!isNimbleAvailable())
            return "unknown";
        
        try
        {
            auto res = execute(["nimble", "--version"]);
            if (res.status == 0)
            {
                nimbleVersionCache = parseNimbleVersion(res.output);
                return nimbleVersionCache;
            }
        }
        catch (Exception e)
        {
            // Fallback
        }
        
        return "unknown";
    }
    
    /// Check if nimpretty is available
    static bool isNimprettyAvailable()
    {
        try
        {
            auto res = execute(["nimpretty", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Check if nimsuggest is available
    static bool isNimsuggestAvailable()
    {
        try
        {
            auto res = execute(["nimsuggest", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Check if nimgrep is available
    static bool isNimgrepAvailable()
    {
        try
        {
            auto res = execute(["nimgrep", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Format Nim source code
    static FormatResult format(
        string[] sources,
        bool checkOnly = false,
        size_t indent = 2,
        size_t maxLineLen = 80
    )
    {
        FormatResult result;
        
        if (!isNimprettyAvailable())
        {
            result.error = "nimpretty not available";
            return result;
        }
        
        foreach (source; sources)
        {
            if (!exists(source))
            {
                result.error = "Source file not found: " ~ source;
                return result;
            }
            
            string[] cmd = ["nimpretty"];
            
            cmd ~= "--indent:" ~ indent.to!string;
            cmd ~= "--maxLineLen:" ~ maxLineLen.to!string;
            
            if (checkOnly)
            {
                // Check mode (doesn't modify file)
                // nimpretty doesn't have a check-only mode, so we format to temp
                import std.uuid : randomUUID;
                string tempFile = "/tmp/nimpretty_" ~ randomUUID().toString() ~ ".nim";
                
                try
                {
                    std.file.copy(source, tempFile);
                    cmd ~= tempFile;
                    
                    auto res = execute(cmd);
                    
                    if (res.status != 0)
                    {
                        result.warnings ~= "Formatting issues in " ~ source;
                        result.hasIssues = true;
                    }
                    
                    // Clean up
                    if (exists(tempFile))
                        remove(tempFile);
                }
                catch (Exception e)
                {
                    result.error = "Failed to check format: " ~ e.msg;
                    return result;
                }
            }
            else
            {
                // Format in place
                cmd ~= source;
                
                auto res = execute(cmd);
                
                if (res.status != 0)
                {
                    result.error = "Formatting failed for " ~ source ~ ": " ~ res.output;
                    return result;
                }
                
                result.formatted ~= source;
            }
        }
        
        result.success = true;
        return result;
    }
    
    /// Run Nim check command
    static CheckResult check(string[] sources)
    {
        CheckResult result;
        
        if (!isNimAvailable())
        {
            result.error = "Nim compiler not available";
            return result;
        }
        
        foreach (source; sources)
        {
            string[] cmd = ["nim", "check", source];
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.errors ~= "Check failed for " ~ source;
                result.success = false;
            }
            
            // Parse warnings
            auto warningRegex = regex(`Warning:.*$", "m`);
            foreach (match; matchAll(res.output, warningRegex))
            {
                result.warnings ~= match.hit;
            }
        }
        
        result.success = result.errors.empty;
        return result;
    }
    
    /// Search for pattern using nimgrep
    static GrepResult grep(string pattern, string[] paths, bool regex = false)
    {
        GrepResult result;
        
        if (!isNimgrepAvailable())
        {
            result.error = "nimgrep not available";
            return result;
        }
        
        string[] cmd = ["nimgrep"];
        
        if (regex)
            cmd ~= "--regex";
        
        cmd ~= pattern;
        cmd ~= paths;
        
        auto res = execute(cmd);
        
        if (res.status == 0 || res.status == 1) // 1 = no matches found
        {
            result.success = true;
            result.matches = res.output.split("\n").filter!(l => !l.empty).array;
        }
        else
        {
            result.error = "nimgrep failed: " ~ res.output;
        }
        
        return result;
    }
    
    private static string parseNimVersion(string output)
    {
        // Parse version from output like:
        // "Nim Compiler Version 2.0.0 [Linux: amd64]"
        auto versionRegex = regex(`Nim Compiler Version (\d+\.\d+\.\d+)`);
        auto match = matchFirst(output, versionRegex);
        
        if (!match.empty)
            return match[1];
        
        // Fallback: try to find any version pattern
        auto simpleVersion = regex(`(\d+\.\d+\.\d+)`);
        match = matchFirst(output, simpleVersion);
        
        if (!match.empty)
            return match[1];
        
        return "unknown";
    }
    
    private static string parseNimbleVersion(string output)
    {
        // Parse version from output like:
        // "nimble v0.14.2 compiled at ..."
        auto versionRegex = regex(`nimble v?(\d+\.\d+\.\d+)`);
        auto match = matchFirst(output, versionRegex);
        
        if (!match.empty)
            return match[1];
        
        // Fallback
        auto simpleVersion = regex(`(\d+\.\d+\.\d+)`);
        match = matchFirst(output, simpleVersion);
        
        if (!match.empty)
            return match[1];
        
        return "unknown";
    }
}

/// Format operation result
struct FormatResult
{
    bool success;
    string error;
    string[] formatted;
    string[] warnings;
    bool hasIssues;
}

/// Check operation result
struct CheckResult
{
    bool success;
    string error;
    string[] errors;
    string[] warnings;
}

/// Grep operation result
struct GrepResult
{
    bool success;
    string error;
    string[] matches;
}

