module languages.scripting.elixir.tooling.builders.escript;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import languages.scripting.elixir.tooling.builders.base;
import languages.scripting.elixir.tooling.builders.mix;
import languages.scripting.elixir.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Escript builder - standalone executables
class EscriptBuilder : MixProjectBuilder
{
    override ElixirBuildResult build(
        in string[] sources,
        in ElixirConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ElixirBuildResult result;
        
        structuredLog.debug_("building_escript").emit();
        
        string workDir = workspace.root;
        if (!sources.empty)
            workDir = dirName(sources[0]);
        
        // Build Mix project first
        result = super.build(sources, config, target, workspace);
        
        if (!result.success)
            return result;
        
        // Build escript
        structuredLog.info("creating_escript_executable").emit();
        
        auto cmd = ["mix", "escript.build"];
        auto res = execute(cmd, null, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.errors ~= "Escript build failed: " ~ res.output;
            result.success = false;
            return result;
        }
        
        // Find generated escript
        string escriptName = config.project.app.empty ? config.project.name : config.project.app;
        string escriptPath = buildPath(workDir, escriptName);
        
        if (exists(escriptPath))
        {
            // result.escriptPath = escriptPath; // Property doesn't exist in ElixirBuildResult
            result.outputs ~= escriptPath;
            structuredLog.info("escript_created_").field("detail", "Escript created: " ~ escriptPath).emit();
        }
        
        return result;
    }
    
    override string name() const
    {
        return "Escript";
    }
}

