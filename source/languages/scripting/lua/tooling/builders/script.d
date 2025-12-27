module languages.scripting.lua.tooling.builders.script;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import languages.scripting.lua.tooling.builders.base;
import languages.scripting.lua.tooling.detection : isAvailable, getRuntimeCommand;
import languages.scripting.lua.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Script builder - creates executable wrappers for Lua scripts
class ScriptBuilder : LuaBuilder
{
    private ActionCache actionCache;
    
    override void setActionCache(ActionCache cache)
    {
        this.actionCache = cache;
    }
    
    override BuildResult build(
        in string[] sources,
        in LuaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        BuildResult result;
        
        if (sources.empty)
        {
            result.error = "No sources provided";
            return result;
        }
        
        // Get Lua interpreter
        string luaCmd = getRuntimeCommand(config.runtime);
        
        if (!.isAvailable(luaCmd))
        {
            result.error = "Lua interpreter not found: " ~ luaCmd;
            return result;
        }
        
        // Validate syntax for all sources
        foreach (source; sources)
        {
            if (!validateSyntax(source, luaCmd))
            {
                result.error = "Syntax error in " ~ source;
                return result;
            }
        }
        
        // Get output path
        string outputPath;
        if (!target.outputPath.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name);
        }
        
        // Create output directory
        auto outputDir = dirName(outputPath);
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        // Create wrapper script
        if (config.wrapper.create)
        {
            createWrapper(sources[0], outputPath, config, luaCmd);
        }
        else
        {
            // Just copy the main script
            if (sources[0] != outputPath)
            {
                copy(sources[0], outputPath);
            }
        }
        
        // Make executable on Unix
        version(Posix)
        {
            makeExecutable(outputPath);
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashStrings(sources);
        
        return result;
    }
    
    override bool isAvailable()
    {
        // Check if any Lua interpreter is available
        return .isAvailable("lua") || .isAvailable("luajit") ||
               .isAvailable("lua5.4") || .isAvailable("lua5.3") ||
               .isAvailable("lua5.2") || .isAvailable("lua5.1");
    }
    
    override string name() const
    {
        return "Script";
    }
    
    private bool validateSyntax(string source, string luaCmd)
    {
        try
        {
            // Use -p flag to parse only (syntax check)
            auto res = execute([luaCmd, "-p", source]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_validate_syntax_").field("detail", "Failed to validate syntax: " ~ e.msg).emit();
            return false;
        }
    }
    
    private void createWrapper(string mainScript, string outputPath, const LuaConfig config, string luaCmd)
    {
        import std.format : format;
        
        string wrapper = config.wrapper.shebang ~ "\n";
        
        // Add custom setup code
        foreach (setup; config.wrapper.setupCode)
        {
            wrapper ~= setup ~ "\n";
        }
        
        // Set up package paths if specified
        if (!config.moduleConfig.packagePath.empty)
        {
            wrapper ~= "-- Custom package paths\n";
            foreach (path; config.moduleConfig.packagePath)
            {
                wrapper ~= format("package.path = package.path .. ';%s'\n", path);
            }
        }
        
        if (!config.moduleConfig.cPackagePath.empty)
        {
            wrapper ~= "-- Custom C package paths\n";
            foreach (path; config.moduleConfig.cPackagePath)
            {
                wrapper ~= format("package.cpath = package.cpath .. ';%s'\n", path);
            }
        }
        
        // Add main script execution
        wrapper ~= "\n-- Determine script directory\n";
        wrapper ~= "local script_dir = arg[0]:match('(.*/)')\n";
        wrapper ~= "if not script_dir then script_dir = './' end\n\n";
        
        wrapper ~= "-- Execute main script\n";
        wrapper ~= format("dofile(script_dir .. '../%s')\n", mainScript);
        
        std.file.write(outputPath, wrapper);
    }
    
    private void makeExecutable(string path)
    {
        try
        {
            execute(["chmod", "+x", path]);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_make_executable_").field("detail", "Failed to make executable: " ~ e.msg).emit();
        }
    }
}

