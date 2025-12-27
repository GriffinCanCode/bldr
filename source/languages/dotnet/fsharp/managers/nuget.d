module languages.dotnet.fsharp.managers.nuget;

import std.process;
import std.file;
import std.path;
import std.string;
import std.array;
import std.algorithm;
import std.json;
import std.conv;
import infrastructure.utils.files.xml;
import infrastructure.utils.logging;

/// NuGet package manager operations
struct NuGetOps
{
    /// Restore packages using NuGet
    static bool restore(string projectPath = "", string configFile = "")
    {
        string[] cmd = ["dotnet", "restore"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        if (!configFile.empty)
            cmd ~= ["--configfile", configFile];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("nuget_restore_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Install a specific package
    static bool install(string packageId, string version_ = "", string targetFramework = "")
    {
        string[] cmd = ["dotnet", "add", "package", packageId];
        
        if (!version_.empty)
            cmd ~= ["--version", version_];
        
        if (!targetFramework.empty)
            cmd ~= ["--framework", targetFramework];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("nuget_install_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Remove a package
    static bool remove(string packageId)
    {
        auto res = execute(["dotnet", "remove", "package", packageId]);
        
        if (res.status != 0)
        {
            structuredLog.error("nuget_remove_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// List installed packages
    static string[] list(string projectPath = "")
    {
        string[] cmd = ["dotnet", "list", "package"];
        
        if (!projectPath.empty)
            cmd ~= [projectPath];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
            return [];
        
        return res.output.splitLines.filter!(l => l.canFind(">")).array;
    }
    
    /// Search for packages
    static string[] search(string searchTerm, int take = 20)
    {
        auto res = execute(["dotnet", "package", "search", searchTerm, "--take", take.to!string]);
        
        if (res.status != 0)
            return [];
        
        return res.output.splitLines.filter!(l => !l.empty).array;
    }
    
    /// Parse packages from packages.config
    static string[string] parsePackagesConfig(string configPath)
    {
        string[string] packages;
        
        if (!exists(configPath))
            return packages;
        
        try
        {
            auto content = readText(configPath);
            auto elements = extractElements(content, "package");
            
            foreach (elem; elements)
            {
                string id = elem.attr("id");
                string version_ = elem.attr("version");
                
                if (!id.empty && !version_.empty)
                {
                    packages[id] = version_;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_packagesconfig_").field("detail", "Failed to parse packages.config: " ~ e.msg).emit();
        }
        
        return packages;
    }
    
    /// Get package information
    static JSONValue getPackageInfo(string packageId)
    {
        auto url = "https://api.nuget.org/v3/registration5-semver1/" ~ packageId.toLower ~ "/index.json";
        
        // Note: This would require HTTP client implementation
        // For now, return empty JSON
        return parseJSON("{}");
    }
    
    /// Check if NuGet is configured
    static bool isConfigured()
    {
        return exists("nuget.config") || exists("NuGet.config") || exists("NuGet.Config");
    }
}

