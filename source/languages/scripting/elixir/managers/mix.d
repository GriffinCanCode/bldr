module languages.scripting.elixir.managers.mix;

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

/// Mix project information
struct MixProjectInfo
{
    string name;
    string app;
    string version_;
    string elixirVersion;
    string[] deps;
    bool isValid;
}

/// Mix project parser - extracts information from mix.exs
class MixProjectParser
{
    /// Parse mix.exs file
    /// 
    /// Safety: This function is @system because:
    /// 1. File I/O (exists, isFile, readText) is inherently @system
    /// 2. Regex matching is memory-safe (std.regex is @system)
    /// 3. Exception handling converts failures to invalid result
    /// 4. Path validation via exists() and isFile()
    /// 
    /// Invariants:
    /// - File existence and type are checked before reading
    /// - Invalid or missing file returns default (invalid) info
    /// - Parsing failures are caught, logged, return invalid info
    /// - All string operations are memory-safe
    /// 
    /// What could go wrong:
    /// - File doesn't exist: checked with exists()
    /// - Not a regular file: checked with isFile()
    /// - Read fails: caught by exception handler
    /// - Malformed mix.exs: regex won't match, returns partial/invalid info (safe)
    static MixProjectInfo parse(string mixExsPath) @system
    {
        MixProjectInfo info;
        
        if (!exists(mixExsPath) || !isFile(mixExsPath))
            return info;
        
        try
        {
            auto content = readText(mixExsPath);
            
            // Extract project function
            auto projectMatch = content.matchFirst(regex(`def\s+project\s+do\s*\[(.*?)\]", "s`));
            if (!projectMatch.empty)
            {
                string projectDef = projectMatch[1];
                
                // Extract app name
                auto appMatch = projectDef.matchFirst(regex(`app:\s*:(\w+)`));
                if (!appMatch.empty)
                    info.app = appMatch[1];
                
                // Extract version
                auto versionMatch = projectDef.matchFirst(regex(`version:\s*"([^"]+)"`));
                if (!versionMatch.empty)
                    info.version_ = versionMatch[1];
                
                // Extract Elixir version
                auto elixirMatch = projectDef.matchFirst(regex(`elixir:\s*"([^"]+)"`));
                if (!elixirMatch.empty)
                    info.elixirVersion = elixirMatch[1];
            }
            
            // Extract dependencies
            auto depsMatch = content.matchFirst(regex(`defp?\s+deps\s+do\s*\[(.*?)\]", "s`));
            if (!depsMatch.empty)
            {
                string depsDef = depsMatch[1];
                auto depMatches = depsDef.matchAll(regex(`\{:(\w+)`));
                foreach (match; depMatches)
                {
                    info.deps ~= match[1];
                }
            }
            
            if (!info.app.empty)
            {
                info.name = info.app;
                info.isValid = true;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_mixexs_").field("detail", "Failed to parse mix.exs: " ~ e.msg).emit();
        }
        
        return info;
    }
}

/// Mix command executor
class MixRunner
{
    private string mixCmd;
    private string workDir;
    
    this(string mixCmd = "mix", string workDir = ".")
    {
        this.mixCmd = mixCmd;
        this.workDir = workDir;
    }
    
    /// Run mix task
    /// 
    /// Safety: This function is @system because:
    /// 1. execute() runs external processes (inherently @system)
    /// 2. Command arguments are validated by Mix tool itself
    /// 3. Uses array form of execute (no shell interpretation)
    /// 4. workDir and mixCmd are set in constructor (validated at creation)
    /// 
    /// Invariants:
    /// - mixCmd and workDir are set in constructor
    /// - Command is built from validated components
    /// - execute() uses array form (no shell injection)
    /// - Environment vars are optional, validated by execute()
    /// 
    /// What could go wrong:
    /// - Mix not installed: execute() fails, returns non-zero status
    /// - Invalid task: Mix reports error, returns non-zero status
    /// - Invalid workDir: execute() fails with exception
    /// - Command execution fails: reflected in return status (safe)
    auto runTask(string task, string[] args = [], string[string] env = null) @system
    {
        string[] cmd = [mixCmd, task] ~ args;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env, Config.none, size_t.max, workDir);
    }
    
    /// Compile project
    bool compile(string[] opts = [])
    {
        auto res = runTask("compile", opts);
        return res.status == 0;
    }
    
    /// Get dependencies
    bool depsGet()
    {
        auto res = runTask("deps.get");
        return res.status == 0;
    }
    
    /// Compile dependencies
    bool depsCompile()
    {
        auto res = runTask("deps.compile");
        return res.status == 0;
    }
    
    /// Clean project
    bool clean()
    {
        auto res = runTask("clean");
        return res.status == 0;
    }
    
    /// Run tests
    bool test(string[] opts = [])
    {
        auto res = runTask("test", opts);
        return res.status == 0;
    }
    
    /// Format code
    bool format(string[] files = [])
    {
        auto res = runTask("format", files);
        return res.status == 0;
    }
    
    /// Check if code is formatted
    bool formatCheck(string[] files = [])
    {
        auto res = runTask("format", ["--check-formatted"] ~ files);
        return res.status == 0;
    }
    
    /// Build release
    bool release(string releaseName = "")
    {
        string[] args;
        if (!releaseName.empty)
            args = [releaseName];
        
        auto res = runTask("release", args);
        return res.status == 0;
    }
    
    /// Build escript
    bool escript()
    {
        auto res = runTask("escript.build");
        return res.status == 0;
    }
}

