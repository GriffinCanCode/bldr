module languages.scripting.elixir.tooling.builders.script;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import languages.scripting.elixir.tooling.builders.base;
import languages.scripting.elixir.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Script builder - for simple .ex/.exs files
class ScriptBuilder : ElixirBuilder
{
    private ActionCache actionCache;
    
    override void setActionCache(ActionCache cache)
    {
        this.actionCache = cache;
    }
    
    override ElixirBuildResult build(
        in string[] sources,
        in ElixirConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ElixirBuildResult result;
        
        structuredLog.debug_("building_elixir_script").emit();
        
        // For scripts, we just validate syntax
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
            {
                result.errors ~= "Source file not found: " ~ source;
                return result;
            }
            
            // Check syntax with elixir -c (compile but don't write output)
            auto cmd = ["elixir", "-c", source];
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.errors ~= "Syntax error in " ~ source ~ ": " ~ res.output;
                return result;
            }
        }
        
        result.success = true;
        result.outputs = sources.dup;
        // outputHash removed from ElixirBuildResult
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["elixir", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "Script";
    }
}

