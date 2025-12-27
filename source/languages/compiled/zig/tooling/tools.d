module languages.compiled.zig.tooling.tools;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import infrastructure.utils.logging;
import infrastructure.utils.process : isCommandAvailable;

/// Result of running a Zig tool
struct ToolResult
{
    bool success;
    string output;
    string[] warnings;
    string[] errors;
    
    /// Check if tool found issues
    bool hasIssues() const pure nothrow
    {
        return !warnings.empty || !errors.empty;
    }
}

/// Zig tooling wrapper - integrates zig fmt, ast-check, zen, and other tools
class ZigTools
{
    /// Check if zig command is available
    static bool isZigAvailable()
    {
        auto res = execute(["zig", "version"]);
        return res.status == 0;
    }
    
    /// Get Zig version
    static string getZigVersion()
    {
        auto res = execute(["zig", "version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Get Zig targets (supported cross-compilation targets)
    static string[] listTargets()
    {
        auto res = execute(["zig", "targets"]);
        if (res.status != 0)
            return [];
        
        // Parse JSON output and extract target triples
        // For simplicity, return raw output for now
        return [res.output];
    }
    
    /// Format Zig source files with zig fmt
    static ToolResult format(string[] sources, bool check = false, bool writeInPlace = true, string exclude = "")
    {
        ToolResult result;
        result.success = true;
        
        if (!isZigAvailable())
        {
            result.warnings ~= "zig not available";
            return result;
        }
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            // Skip if matches exclude pattern
            if (!exclude.empty && source.canFind(exclude))
                continue;
            
            string[] cmd = ["zig", "fmt"];
            
            if (check)
                cmd ~= "--check";
            
            cmd ~= source;
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                if (check)
                {
                    result.warnings ~= source ~ " needs formatting";
                }
                else
                {
                    result.success = false;
                    result.errors ~= "zig fmt failed on " ~ source ~ ": " ~ res.output;
                }
            }
        }
        
        return result;
    }
    
    /// Check AST of Zig source files
    static ToolResult astCheck(string[] sources)
    {
        ToolResult result;
        result.success = true;
        
        if (!isZigAvailable())
        {
            result.warnings ~= "zig not available";
            return result;
        }
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string[] cmd = ["zig", "ast-check", source];
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.success = false;
                result.errors ~= "ast-check failed on " ~ source ~ ": " ~ res.output;
            }
        }
        
        return result;
    }
    
    /// Run zig build (for build.zig projects)
    static ToolResult build(
        string buildZigPath = "build.zig",
        string[] steps = [],
        string[string] options = null,
        string prefix = "",
        string workDir = "."
    )
    {
        ToolResult result;
        
        if (!isZigAvailable())
        {
            result.errors ~= "zig not available";
            result.success = false;
            return result;
        }
        
        if (!exists(buildPath(workDir, buildZigPath)))
        {
            result.errors ~= "build.zig not found at: " ~ buildPath(workDir, buildZigPath);
            result.success = false;
            return result;
        }
        
        string[] cmd = ["zig", "build"];
        
        // Add prefix if specified
        if (!prefix.empty)
        {
            cmd ~= "--prefix";
            cmd ~= prefix;
        }
        
        // Add build options
        foreach (key, value; options)
        {
            cmd ~= "-D" ~ key ~ "=" ~ value;
        }
        
        // Add steps to execute
        cmd ~= steps;
        
        structuredLog.debug_("running_zig_build_").field("detail", "Running zig build: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, workDir);
        
        result.output = res.output;
        
        if (res.status != 0)
        {
            result.success = false;
            result.errors ~= "zig build failed: " ~ res.output;
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
    
    /// Translate C code to Zig
    static ToolResult translateC(
        string cFile,
        string outputFile,
        string[] includes = [],
        string[] defines = [],
        string target = ""
    )
    {
        ToolResult result;
        
        if (!isZigAvailable())
        {
            result.errors ~= "zig not available";
            result.success = false;
            return result;
        }
        
        string[] cmd = ["zig", "translate-c"];
        
        // Add target if specified
        if (!target.empty)
        {
            cmd ~= "-target";
            cmd ~= target;
        }
        
        // Add include directories
        foreach (inc; includes)
        {
            cmd ~= "-I" ~ inc;
        }
        
        // Add defines
        foreach (def; defines)
        {
            cmd ~= "-D" ~ def;
        }
        
        // Add input file
        cmd ~= cFile;
        
        structuredLog.info("translating_c_to_zig_").field("detail", "Translating C to Zig: " ~ cFile).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.success = false;
            result.errors ~= "translate-c failed: " ~ res.output;
        }
        else
        {
            result.success = true;
            result.output = res.output;
            
            // Write output if file specified
            if (!outputFile.empty)
            {
                try
                {
                    std.file.write(outputFile, res.output);
                    structuredLog.info("translation_written_to_").field("detail", "Translation written to: " ~ outputFile).emit();
                }
                catch (Exception e)
                {
                    result.warnings ~= "Failed to write output: " ~ e.msg;
                }
            }
        }
        
        return result;
    }
    
    /// Show Zig Zen (philosophy)
    static string zen()
    {
        if (!isZigAvailable())
            return "";
        
        auto res = execute(["zig", "zen"]);
        if (res.status == 0)
            return res.output.strip;
        return "";
    }
    
    /// Run zig init to create a new project
    static ToolResult init(string path = ".", string name = "")
    {
        ToolResult result;
        
        if (!isZigAvailable())
        {
            result.errors ~= "zig not available";
            result.success = false;
            return result;
        }
        
        string[] cmd = ["zig", "init"];
        
        structuredLog.info("initializing_zig_project_in_").field("detail", "Initializing Zig project in: " ~ path).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, path);
        
        result.output = res.output;
        
        if (res.status != 0)
        {
            result.success = false;
            result.errors ~= "zig init failed: " ~ res.output;
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
    
    /// Fetch dependencies (zig fetch)
    static ToolResult fetch(string url, string hash = "", string workDir = ".")
    {
        ToolResult result;
        
        if (!isZigAvailable())
        {
            result.errors ~= "zig not available";
            result.success = false;
            return result;
        }
        
        string[] cmd = ["zig", "fetch"];
        
        if (!hash.empty)
        {
            cmd ~= "--hash";
            cmd ~= hash;
        }
        
        cmd ~= url;
        
        structuredLog.info("fetching_zig_dependency_").field("detail", "Fetching Zig dependency: " ~ url).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, workDir);
        
        result.output = res.output;
        
        if (res.status != 0)
        {
            result.success = false;
            result.errors ~= "zig fetch failed: " ~ res.output;
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
    
    /// Run zig env to get environment information
    static string[string] getEnv()
    {
        string[string] env;
        
        if (!isZigAvailable())
            return env;
        
        auto res = execute(["zig", "env"]);
        if (res.status != 0)
            return env;
        
        // Parse JSON output
        import std.json;
        try
        {
            auto json = parseJSON(res.output);
            foreach (string key, value; json.object)
            {
                if (value.type == JSONType.string)
                    env[key] = value.str;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_zig_env_output_").field("detail", "Failed to parse zig env output: " ~ e.msg).emit();
        }
        
        return env;
    }
    
    /// Get Zig library path
    static string getLibPath()
    {
        auto env = getEnv();
        return env.get("lib_dir", "");
    }
    
    /// Get Zig standard library path
    static string getStdPath()
    {
        auto env = getEnv();
        return env.get("std_dir", "");
    }
    
    /// Get global cache directory
    static string getGlobalCacheDir()
    {
        auto env = getEnv();
        return env.get("global_cache_dir", "");
    }
    
}


