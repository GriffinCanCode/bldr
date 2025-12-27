module languages.dotnet.fsharp.tooling.builders.executable;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.datetime.stopwatch;
import languages.dotnet.fsharp.tooling.builders.base;
import languages.dotnet.fsharp.config;
import languages.dotnet.fsharp.managers.dotnet;
import infrastructure.analysis.targets.types;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Builder for F# executables
class ExecutableBuilder : FSharpBuilder
{
    FSharpBuildResult build(in string[] sources, in FSharpConfig config, in Target target, in WorkspaceConfig workspaceConfig)
    {
        FSharpBuildResult result;
        auto sw = StopWatch(AutoStart.yes);
        
        auto fsprojFile = sources.find!(s => s.endsWith(".fsproj"));
        
        if (!fsprojFile.empty)
        {
            result = buildWithDotnet(fsprojFile.front, config, target, workspaceConfig);
        }
        else
        {
            result = buildWithFSC(sources, config, target, workspaceConfig);
        }
        
        sw.stop();
        result.buildTime = sw.peek().total!"msecs";
        
        return result;
    }
    
    FSharpBuildMode getMode()
    {
        return FSharpBuildMode.Executable;
    }
    
    bool isAvailable()
    {
        return DotnetOps.isAvailable();
    }
    
    private FSharpBuildResult buildWithDotnet(string projectFile, in FSharpConfig config, in Target target, in WorkspaceConfig workspaceConfig)
    {
        FSharpBuildResult result;
        
        string outputDir = workspaceConfig.options.outputDir;
        if (!config.dotnet.outputDir.empty)
            outputDir = config.dotnet.outputDir;
        
        bool success = DotnetOps.build(
            projectFile,
            config.dotnet.configuration,
            config.dotnet.framework.identifier,
            outputDir
        );
        
        if (!success)
        {
            result.error = "dotnet build failed";
            return result;
        }
        
        auto projectName = baseName(projectFile, ".fsproj");
        version(Windows)
            auto outputPath = buildPath(outputDir, projectName ~ ".exe");
        else
            auto outputPath = buildPath(outputDir, projectName);
        
        if (exists(outputPath))
        {
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
        }
        else
        {
            // Try with .dll extension (console apps on Linux)
            auto dllPath = buildPath(outputDir, projectName ~ ".dll");
            if (exists(dllPath))
            {
                result.success = true;
                result.outputs = [dllPath];
                result.outputHash = FastHash.hashFile(dllPath);
            }
            else
            {
                result.error = "Output file not found";
            }
        }
        
        return result;
    }
    
    private FSharpBuildResult buildWithFSC(in string[] sources, in FSharpConfig config, in Target target, in WorkspaceConfig workspaceConfig)
    {
        FSharpBuildResult result;
        
        auto outputDir = workspaceConfig.options.outputDir;
        auto outputName = target.name.split(":")[$ - 1];
        
        version(Windows)
            auto outputPath = buildPath(outputDir, outputName ~ ".exe");
        else
            auto outputPath = buildPath(outputDir, outputName);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        string[] cmd = ["fsc", "--target:exe", "--out:" ~ outputPath];
        
        if (config.optimize)
            cmd ~= ["--optimize+"];
        
        if (config.debug_)
            cmd ~= ["--debug+"];
        
        cmd ~= config.compilerFlags;
        cmd ~= sources.filter!(s => s.endsWith(".fs") || s.endsWith(".fsx")).array;
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "fsc compilation failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
}

