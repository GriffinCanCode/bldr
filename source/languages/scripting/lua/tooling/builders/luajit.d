module languages.scripting.lua.tooling.builders.luajit;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.format;
import languages.scripting.lua.tooling.builders.base;
import languages.scripting.lua.tooling.detection : isAvailable;
import std.conv : to;
import languages.scripting.lua.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// LuaJIT builder - uses LuaJIT for JIT compilation or bytecode generation
class LuaJITBuilder : LuaBuilder
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
        
        // Get LuaJIT path
        string luajitCmd = config.luajit.jitPath;
        
        if (!.isAvailable(luajitCmd))
        {
            result.error = "LuaJIT not found: " ~ luajitCmd;
            return result;
        }
        
        if (config.luajit.bytecode)
        {
            // Generate LuaJIT bytecode
            return compileBytecode(sources, config, target, workspace, luajitCmd);
        }
        else
        {
            // Create wrapper script for JIT execution
            return createJITWrapper(sources, config, target, workspace, luajitCmd);
        }
    }
    
    override bool isAvailable()
    {
        return .isAvailable("luajit");
    }
    
    override string name() const
    {
        return "LuaJIT";
    }
    
    private BuildResult compileBytecode(
        const string[] sources,
        const LuaConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string luajitCmd
    )
    {
        BuildResult result;
        
        // Get output path
        string outputPath;
        if (!config.bytecode.outputFile.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, config.bytecode.outputFile);
        }
        else if (!target.outputPath.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name ~ ".ljbc");
        }
        
        // Create output directory
        auto outputDir = dirName(outputPath);
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        // Build LuaJIT bytecode command: luajit -b input output
        string[] cmd = [luajitCmd, "-b"];
        
        // Add custom bytecode flags
        if (!config.luajit.bytecodeFlags.empty)
        {
            cmd ~= config.luajit.bytecodeFlags;
        }
        else
        {
            // Default flags based on optimization level
            if (config.luajit.optLevel >= 2)
            {
                cmd ~= "-O" ~ config.luajit.optLevel.to!string;
            }
            
            // Strip debug info
            if (config.bytecode.stripDebug)
            {
                cmd ~= "-s";
            }
        }
        
        // Add input file (main source)
        cmd ~= sources[0];
        
        // Add output file
        cmd ~= outputPath;
        
        // Compile bytecode
        structuredLog.debug_("compiling_luajit_bytecode_").field("detail", "Compiling LuaJIT bytecode: " ~ cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "LuaJIT bytecode compilation failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashStrings(sources);
        
        return result;
    }
    
    private BuildResult createJITWrapper(
        const string[] sources,
        const LuaConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string luajitCmd
    )
    {
        BuildResult result;
        
        // Validate syntax
        auto res = execute([luajitCmd, "-bl", sources[0]]);
        if (res.status != 0)
        {
            result.error = "Syntax error in " ~ sources[0] ~ ": " ~ res.output;
            return result;
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
        createWrapper(sources[0], outputPath, config, luajitCmd);
        
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
    
    private void createWrapper(string mainScript, string outputPath, const LuaConfig config, string luajitCmd)
    {
        string wrapper = "#!/usr/bin/env " ~ luajitCmd ~ "\n";
        
        // Add JIT options
        if (!config.luajit.jitOptions.empty)
        {
            wrapper ~= "-- LuaJIT options\n";
            foreach (opt; config.luajit.jitOptions)
            {
                wrapper ~= "jit." ~ opt ~ "\n";
            }
            wrapper ~= "\n";
        }
        
        // Set optimization level
        if (config.luajit.optLevel > 0)
        {
            wrapper ~= format("-- Set optimization level to %d\n", config.luajit.optLevel);
            wrapper ~= format("jit.opt.start(%d)\n\n", config.luajit.optLevel);
        }
        
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
        
        // Disable FFI if requested
        if (!config.luajit.enableFFI)
        {
            wrapper ~= "-- Disable FFI\n";
            wrapper ~= "jit.off(true, true)\n\n";
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

