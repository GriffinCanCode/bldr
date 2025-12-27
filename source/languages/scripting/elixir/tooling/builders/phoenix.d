module languages.scripting.elixir.tooling.builders.phoenix;

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

/// Phoenix builder - web applications with asset compilation
class PhoenixBuilder : MixProjectBuilder
{
    override ElixirBuildResult build(
        in string[] sources,
        in ElixirConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ElixirBuildResult result;
        
        structuredLog.debug_("building_phoenix_application").emit();
        
        string workDir = workspace.root;
        if (!sources.empty)
            workDir = dirName(sources[0]);
        
        // Build standard Mix project first
        result = super.build(sources, config, target, workspace);
        
        if (!result.success)
            return result;
        
        // Compile assets if configured
        if (config.phoenix.enabled && config.phoenix.compileAssets)
        {
            structuredLog.info("compiling_phoenix_assets").emit();
            
            bool assetsCompiled = false;
            
            // Try esbuild (default for Phoenix 1.6+)
            if (config.phoenix.assetTool == "esbuild")
            {
                assetsCompiled = compileWithEsbuild(workDir);
            }
            // Try webpack
            else if (config.phoenix.assetTool == "webpack")
            {
                assetsCompiled = compileWithWebpack(workDir);
            }
            // Try vite
            else if (config.phoenix.assetTool == "vite")
            {
                assetsCompiled = compileWithVite(workDir);
            }
            
            if (!assetsCompiled)
            {
                result.warnings ~= "Asset compilation failed or skipped";
            }
        }
        
        // Digest assets for production
        if (config.phoenix.digestAssets && config.env == MixEnv.Prod)
        {
            structuredLog.info("digesting_phoenix_assets").emit();
            
            auto cmd = ["mix", "phx.digest"];
            auto res = execute(cmd, null, Config.none, size_t.max, workDir);
            
            if (res.status != 0)
            {
                result.warnings ~= "Asset digestion failed";
            }
        }
        
        // Run migrations if configured
        if (config.phoenix.runMigrations && config.phoenix.ecto)
        {
            structuredLog.info("running_ecto_migrations").emit();
            
            auto cmd = ["mix", "ecto.migrate"];
            auto res = execute(cmd, null, Config.none, size_t.max, workDir);
            
            if (res.status != 0)
            {
                result.warnings ~= "Database migrations failed: " ~ res.output;
            }
        }
        
        return result;
    }
    
    override string name() const
    {
        return "Phoenix";
    }
    
    /// Compile assets with esbuild
    private bool compileWithEsbuild(string workDir) @system
    {
        // Check if esbuild is configured in mix.exs
        string mixExsPath = buildPath(workDir, "mix.exs");
        if (!exists(mixExsPath))
            return false;
        
        auto content = readText(mixExsPath);
        if (!content.canFind(":esbuild"))
            return false;
        
        // Run esbuild via Mix
        auto cmd = ["mix", "assets.deploy"];
        auto res = execute(cmd, null, Config.none, size_t.max, workDir);
        
        return res.status == 0;
    }
    
    /// Compile assets with webpack
    private bool compileWithWebpack(string workDir) @system
    {
        string assetsDir = buildPath(workDir, "assets");
        if (!exists(assetsDir))
            return false;
        
        // Check for webpack config
        if (!exists(buildPath(assetsDir, "webpack.config.js")))
            return false;
        
        // Run npm/yarn build
        auto cmd = ["npm", "run", "deploy"];
        auto res = execute(cmd, null, Config.none, size_t.max, assetsDir);
        
        return res.status == 0;
    }
    
    /// Compile assets with vite
    private bool compileWithVite(string workDir) @system
    {
        string assetsDir = buildPath(workDir, "assets");
        if (!exists(assetsDir))
            return false;
        
        // Check for vite config
        if (!exists(buildPath(assetsDir, "vite.config.js")) && 
            !exists(buildPath(assetsDir, "vite.config.ts")))
            return false;
        
        // Run vite build
        auto cmd = ["npm", "run", "build"];
        auto res = execute(cmd, null, Config.none, size_t.max, assetsDir);
        
        return res.status == 0;
    }
}

