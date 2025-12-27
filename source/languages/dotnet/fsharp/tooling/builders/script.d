module languages.dotnet.fsharp.tooling.builders.script;

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

/// Builder for F# scripts (.fsx)
class ScriptBuilder : FSharpBuilder
{
    FSharpBuildResult build(in string[] sources, in FSharpConfig config, in Target target, in WorkspaceConfig workspaceConfig)
    {
        FSharpBuildResult result;
        auto sw = StopWatch(AutoStart.yes);
        
        // Find .fsx script file
        auto scriptFile = sources.find!(s => s.endsWith(".fsx"));
        
        if (scriptFile.empty)
        {
            result.error = "No .fsx script file found in sources";
            return result;
        }
        
        // Execute script with F# Interactive
        string[] cmd = ["dotnet", "fsi"];
        
        // Add FSI arguments
        cmd ~= config.fsi.arguments;
        
        // Add load scripts
        foreach (loadScript; config.fsi.loadScripts)
            cmd ~= ["--load:" ~ loadScript];
        
        // Add references
        foreach (ref_; config.fsi.references)
            cmd ~= ["--reference:" ~ ref_];
        
        // Add defines
        foreach (define; config.fsi.defines)
            cmd ~= ["--define:" ~ define];
        
        // Enable readline
        if (config.fsi.readline)
            cmd ~= ["--readline+"];
        
        // Add script file
        cmd ~= [scriptFile.front];
        
        auto res = execute(cmd);
        
        sw.stop();
        result.buildTime = sw.peek().total!"msecs";
        
        if (res.status != 0)
        {
            result.error = "Script execution failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        // Scripts don't produce output files, use source hash
        result.outputHash = FastHash.hashStrings(sources);
        
        structuredLog.info("script_executed_successfully").emit();
        structuredLog.debug_("output_").field("detail", "Output: " ~ res.output).emit();
        
        return result;
    }
    
    FSharpBuildMode getMode()
    {
        return FSharpBuildMode.Script;
    }
    
    bool isAvailable()
    {
        auto res = execute(["dotnet", "fsi", "--help"]);
        return res.status == 0;
    }
}

