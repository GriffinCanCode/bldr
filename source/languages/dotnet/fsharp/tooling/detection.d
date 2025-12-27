module languages.dotnet.fsharp.tooling.detection;

import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import infrastructure.utils.logging;

/// Tool information structure
struct ToolInfo
{
    /// Tool name
    string name;
    
    /// Tool version
    string version_;
    
    /// Tool path
    string path;
    
    /// Is available
    bool available = false;
}

/// F# tooling detection and version management
struct FSharpDetection
{
    /// Detect dotnet CLI
    static ToolInfo detectDotnet()
    {
        ToolInfo info;
        info.name = "dotnet";
        
        auto res = execute(["dotnet", "--version"]);
        
        if (res.status == 0)
        {
            info.available = true;
            info.version_ = res.output.strip;
            info.path = findToolPath("dotnet");
        }
        
        return info;
    }
    
    /// Detect F# compiler
    static ToolInfo detectFSC()
    {
        ToolInfo info;
        info.name = "fsc";
        
        auto res = execute(["fsc", "--version"]);
        
        if (res.status == 0 || res.status == 1) // fsc returns 1 sometimes
        {
            info.available = true;
            info.version_ = res.output.strip;
            info.path = findToolPath("fsc");
        }
        
        return info;
    }
    
    /// Detect F# Interactive
    static ToolInfo detectFSI()
    {
        ToolInfo info;
        info.name = "fsi";
        
        auto res = execute(["dotnet", "fsi", "--help"]);
        
        if (res.status == 0)
        {
            info.available = true;
            info.path = findToolPath("dotnet");
            
            // Try to extract version
            auto versionRes = execute(["dotnet", "--version"]);
            if (versionRes.status == 0)
                info.version_ = versionRes.output.strip;
        }
        
        return info;
    }
    
    /// Detect FAKE
    static ToolInfo detectFAKE()
    {
        ToolInfo info;
        info.name = "fake";
        
        auto res = execute(["dotnet", "fake", "--version"]);
        
        if (res.status == 0)
        {
            info.available = true;
            info.version_ = res.output.strip;
            info.path = findToolPath("dotnet");
        }
        
        return info;
    }
    
    /// Detect Paket
    static ToolInfo detectPaket()
    {
        ToolInfo info;
        info.name = "paket";
        
        auto res = execute(["dotnet", "paket", "--version"]);
        
        if (res.status == 0)
        {
            info.available = true;
            info.version_ = res.output.strip;
            info.path = findToolPath("dotnet");
        }
        
        return info;
    }
    
    /// Detect Fantomas
    static ToolInfo detectFantomas()
    {
        ToolInfo info;
        info.name = "fantomas";
        
        auto res = execute(["dotnet", "fantomas", "--version"]);
        
        if (res.status == 0)
        {
            info.available = true;
            info.version_ = res.output.strip;
            info.path = findToolPath("dotnet");
        }
        
        return info;
    }
    
    /// Detect FSharpLint
    static ToolInfo detectFSharpLint()
    {
        ToolInfo info;
        info.name = "fsharplint";
        
        auto res = execute(["dotnet", "fsharplint", "--version"]);
        
        if (res.status == 0)
        {
            info.available = true;
            info.version_ = res.output.strip;
            info.path = findToolPath("dotnet");
        }
        
        return info;
    }
    
    /// Detect Fable
    static ToolInfo detectFable()
    {
        ToolInfo info;
        info.name = "fable";
        
        auto res = execute(["dotnet", "fable", "--version"]);
        
        if (res.status == 0)
        {
            info.available = true;
            info.version_ = res.output.strip;
            info.path = findToolPath("dotnet");
        }
        
        return info;
    }
    
    /// Detect all F# tools
    static ToolInfo[string] detectAll()
    {
        ToolInfo[string] tools;
        
        tools["dotnet"] = detectDotnet();
        tools["fsc"] = detectFSC();
        tools["fsi"] = detectFSI();
        tools["fake"] = detectFAKE();
        tools["paket"] = detectPaket();
        tools["fantomas"] = detectFantomas();
        tools["fsharplint"] = detectFSharpLint();
        tools["fable"] = detectFable();
        
        return tools;
    }
    
    /// Find tool path in system PATH
    private static string findToolPath(string toolName)
    {
        version(Windows)
        {
            auto pathEnv = environment.get("PATH", "");
            auto paths = pathEnv.split(";");
            
            foreach (p; paths)
            {
                auto toolPath = buildPath(p, toolName ~ ".exe");
                if (exists(toolPath))
                    return toolPath;
            }
        }
        else
        {
            auto res = execute(["which", toolName]);
            if (res.status == 0)
                return res.output.strip;
        }
        
        return "";
    }
    
    /// Check if .NET SDK version meets minimum requirement
    static bool checkDotNetVersion(string minVersion)
    {
        auto info = detectDotnet();
        
        if (!info.available)
            return false;
        
        try
        {
            auto currentParts = info.version_.split(".");
            auto minParts = minVersion.split(".");
            
            for (size_t i = 0; i < minParts.length && i < currentParts.length; i++)
            {
                auto current = currentParts[i].to!int;
                auto min = minParts[i].to!int;
                
                if (current > min)
                    return true;
                if (current < min)
                    return false;
            }
            
            return true;
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_net_version_").field("detail", "Failed to parse .NET version: " ~ e.msg).emit();
            return false;
        }
    }
    
    /// Get installed .NET SDKs
    static string[] getInstalledSDKs()
    {
        auto res = execute(["dotnet", "--list-sdks"]);
        
        if (res.status != 0)
            return [];
        
        return res.output.splitLines.filter!(l => !l.empty).array;
    }
    
    /// Get installed .NET runtimes
    static string[] getInstalledRuntimes()
    {
        auto res = execute(["dotnet", "--list-runtimes"]);
        
        if (res.status != 0)
            return [];
        
        return res.output.splitLines.filter!(l => !l.empty).array;
    }
}

