module languages.dotnet.fsharp.tooling.packagers.nuget;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.dotnet.fsharp.tooling.packagers.base;
import languages.dotnet.fsharp.config;
import languages.dotnet.fsharp.managers.dotnet;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// NuGet packager implementation
class NuGetPackager : FSharpPackager
{
    PackageResult pack(string projectFile, FSharpPackagingConfig config)
    {
        PackageResult result;
        
        if (!exists(projectFile))
        {
            result.error = "Project file not found: " ~ projectFile;
            return result;
        }
        
        string[] cmd = ["dotnet", "pack", projectFile];
        
        // Output directory
        auto outputDir = "bin/packages";
        cmd ~= ["--output", outputDir];
        
        // Configuration
        cmd ~= ["--configuration", "Release"];
        
        // Include symbols
        if (config.includeSymbols)
            cmd ~= ["-p:IncludeSymbols=true"];
        
        // Include source
        if (config.includeSource)
            cmd ~= ["-p:IncludeSource=true"];
        
        // Version
        if (!config.version_.empty)
            cmd ~= ["-p:PackageVersion=" ~ config.version_];
        
        // Execute pack
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "dotnet pack failed: " ~ res.output;
            return result;
        }
        
        // Find generated package
        if (exists(outputDir))
        {
            auto nupkgFiles = dirEntries(outputDir, "*.nupkg", SpanMode.shallow)
                .filter!(e => !e.name.canFind(".symbols."))
                .array;
            
            if (!nupkgFiles.empty)
            {
                result.success = true;
                result.packageFile = nupkgFiles[0].name;
                result.packageHash = FastHash.hashFile(result.packageFile);
                
                structuredLog.info("package_created_").field("detail", "Package created: " ~ result.packageFile).emit();
            }
            else
            {
                result.error = "Package file not found after packing";
            }
        }
        else
        {
            result.error = "Output directory not found: " ~ outputDir;
        }
        
        return result;
    }
    
    string getName()
    {
        return "NuGet";
    }
    
    bool isAvailable()
    {
        return DotnetOps.isAvailable();
    }
}

