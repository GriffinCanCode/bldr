module languages.scripting.elixir.tooling.builders.umbrella;

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

/// Umbrella builder - multi-app projects
class UmbrellaBuilder : MixProjectBuilder
{
    override ElixirBuildResult build(
        in string[] sources,
        in ElixirConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ElixirBuildResult result;
        
        structuredLog.debug_("building_umbrella_project").emit();
        
        string workDir = workspace.root;
        if (!sources.empty)
            workDir = dirName(sources[0]);
        
        // Build umbrella root
        result = super.build(sources, config, target, workspace);
        
        if (!result.success)
            return result;
        
        // Build individual apps if specified
        if (!config.umbrella.buildAll)
        {
            structuredLog.info("building_individual_umbrella_apps").emit();
            
            string appsDir = buildPath(workDir, config.umbrella.appsDir);
            
            foreach (app; config.umbrella.apps)
            {
                if (config.umbrella.excludeApps.canFind(app))
                {
                    structuredLog.debug_("skipping_excluded_app_").field("detail", "Skipping excluded app: " ~ app).emit();
                    continue;
                }
                
                structuredLog.info("building_app_").field("detail", "Building app: " ~ app).emit();
                
                string appDir = buildPath(appsDir, app);
                if (!exists(appDir))
                {
                    result.warnings ~= "App directory not found: " ~ app;
                    continue;
                }
                
                auto cmd = ["mix", "compile"];
                auto res = execute(cmd, null, Config.none, size_t.max, appDir);
                
                if (res.status != 0)
                {
                    result.warnings ~= "Failed to build app " ~ app ~ ": " ~ res.output;
                }
            }
        }
        
        return result;
    }
    
    override string name() const
    {
        return "Umbrella";
    }
}

