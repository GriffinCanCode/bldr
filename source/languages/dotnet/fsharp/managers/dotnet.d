module languages.dotnet.fsharp.managers.dotnet;

import std.process;
import std.file;
import std.path;
import std.string;
import std.array;
import std.algorithm;
import std.json;
import infrastructure.utils.logging;

/// .NET CLI operations for F# projects
struct DotnetOps
{
    /// Build a .NET project
    static bool build(string projectPath, string configuration = "Release", string framework = "", string output = "")
    {
        string[] cmd = ["dotnet", "build"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        cmd ~= ["--configuration", configuration];
        
        if (!framework.empty)
            cmd ~= ["--framework", framework];
        
        if (!output.empty)
            cmd ~= ["--output", output];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("dotnet_build_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Restore dependencies
    static bool restore(string projectPath = "")
    {
        string[] cmd = ["dotnet", "restore"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("dotnet_restore_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Clean build artifacts
    static bool clean(string projectPath = "")
    {
        string[] cmd = ["dotnet", "clean"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("dotnet_clean_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run tests
    static bool test(string projectPath = "", string framework = "")
    {
        string[] cmd = ["dotnet", "test"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        if (!framework.empty)
            cmd ~= ["--framework", framework];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("dotnet_test_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Publish application
    static bool publish(string projectPath, string configuration, string runtime, string output, bool selfContained = false)
    {
        string[] cmd = ["dotnet", "publish"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        cmd ~= ["--configuration", configuration];
        
        if (!runtime.empty)
            cmd ~= ["--runtime", runtime];
        
        if (!output.empty)
            cmd ~= ["--output", output];
        
        if (selfContained)
            cmd ~= ["--self-contained"];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("dotnet_publish_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Pack NuGet package
    static bool pack(string projectPath, string output = "")
    {
        string[] cmd = ["dotnet", "pack"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        if (!output.empty)
            cmd ~= ["--output", output];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("dotnet_pack_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Get dotnet version
    static string getVersion()
    {
        auto res = execute(["dotnet", "--version"]);
        
        if (res.status != 0)
            return "";
        
        return res.output.strip;
    }
    
    /// Check if dotnet is available
    static bool isAvailable()
    {
        auto res = execute(["dotnet", "--version"]);
        return res.status == 0;
    }
    
    /// List installed SDKs
    static string[] listSDKs()
    {
        auto res = execute(["dotnet", "--list-sdks"]);
        
        if (res.status != 0)
            return [];
        
        return res.output.splitLines.filter!(l => !l.empty).array;
    }
    
    /// List installed runtimes
    static string[] listRuntimes()
    {
        auto res = execute(["dotnet", "--list-runtimes"]);
        
        if (res.status != 0)
            return [];
        
        return res.output.splitLines.filter!(l => !l.empty).array;
    }
}

