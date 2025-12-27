module languages.dotnet.fsharp.tooling.builders.fable;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.datetime.stopwatch;
import languages.dotnet.fsharp.tooling.builders.base;
import languages.dotnet.fsharp.config;
import infrastructure.analysis.targets.types;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Builder for Fable (F# to JavaScript/TypeScript)
class FableBuilder : FSharpBuilder
{
    FSharpBuildResult build(in string[] sources, in FSharpConfig config, in Target target, in WorkspaceConfig workspaceConfig)
    {
        FSharpBuildResult result;
        auto sw = StopWatch(AutoStart.yes);
        
        if (!isAvailable())
        {
            result.error = "Fable is not installed. Run: npm install -g fable-compiler";
            return result;
        }
        
        auto outputDir = buildPath(workspaceConfig.options.outputDir, config.fable.outDir);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build command
        string[] cmd = ["dotnet", "fable"];
        
        // Find .fsproj file
        auto fsprojFile = sources.find!(s => s.endsWith(".fsproj"));
        if (!fsprojFile.empty)
            cmd ~= [fsprojFile.front];
        
        // Output directory
        cmd ~= ["--outDir", config.fable.outDir];
        
        // Module system
        cmd ~= ["--lang", config.fable.language];
        
        // TypeScript output
        if (config.fable.typescript)
            cmd ~= ["--typescript"];
        
        // Source maps
        if (config.fable.sourceMaps)
            cmd ~= ["--sourceMaps"];
        
        // Optimization
        if (config.fable.optimize)
            cmd ~= ["--optimize"];
        
        // Defines
        foreach (define; config.fable.defines)
            cmd ~= ["--define", define];
        
        // Watch mode
        if (config.fable.watch)
            cmd ~= ["--watch"];
        
        // Run after compilation
        if (!config.fable.runAfter.empty)
            cmd ~= ["--run", config.fable.runAfter];
        
        // Execute Fable
        auto res = execute(cmd);
        
        sw.stop();
        result.buildTime = sw.peek().total!"msecs";
        
        if (res.status != 0)
        {
            result.error = "Fable compilation failed: " ~ res.output;
            return result;
        }
        
        // Find generated files
        string[] outputs;
        auto ext = config.fable.typescript ? ".ts" : ".js";
        
        try
        {
            foreach (entry; dirEntries(outputDir, SpanMode.depth))
            {
                if (entry.name.endsWith(ext))
                    outputs ~= entry.name;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_enumerate_output_files_").field("detail", "Failed to enumerate output files: " ~ e.msg).emit();
        }
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(sources);
        
        structuredLog.info("fable_compilation_successful").emit();
        
        return result;
    }
    
    FSharpBuildMode getMode()
    {
        return FSharpBuildMode.Fable;
    }
    
    bool isAvailable()
    {
        auto res = execute(["dotnet", "fable", "--version"]);
        return res.status == 0;
    }
}

