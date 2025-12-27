module languages.scripting.elixir.tooling.builders.nerves;

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
import infrastructure.utils.logging;

/// Nerves builder - embedded systems firmware
class NervesBuilder : MixProjectBuilder
{
    override ElixirBuildResult build(
        in string[] sources,
        in ElixirConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ElixirBuildResult result;
        
        structuredLog.debug_("building_nerves_firmware").emit();
        
        string workDir = workspace.root;
        if (!sources.empty)
            workDir = dirName(sources[0]);
        
        // Setup Nerves environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        if (!config.nerves.target.empty)
        {
            env["MIX_TARGET"] = config.nerves.target;
            structuredLog.info("building_for_nerves_target_").field("detail", "Building for Nerves target: " ~ config.nerves.target).emit();
        }
        
        // Build Mix project first
        result = super.build(sources, config, target, workspace);
        
        if (!result.success)
            return result;
        
        // Build firmware
        structuredLog.info("creating_nerves_firmware").emit();
        
        auto cmd = ["mix", "firmware"];
        auto res = execute(cmd, env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.errors ~= "Firmware build failed: " ~ res.output;
            result.success = false;
            return result;
        }
        
        // Find firmware file
        string fwPath = buildPath(workDir, "_build", config.nerves.target, "nerves", "images");
        if (exists(fwPath))
        {
            // Look for .fw file
            foreach (entry; dirEntries(fwPath, "*.fw", SpanMode.shallow))
            {
                result.outputs ~= entry.name;
                structuredLog.info("firmware_created_").field("detail", "Firmware created: " ~ entry.name).emit();
            }
        }
        
        return result;
    }
    
    override string name() const
    {
        return "Nerves";
    }
}

