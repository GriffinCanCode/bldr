module languages.scripting.lua.tooling.builders.bytecode;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import languages.scripting.lua.tooling.builders.base;
import languages.scripting.lua.tooling.detection : isAvailable, getCompilerCommand;
import languages.scripting.lua.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionId, ActionType;

/// Bytecode builder with action-level caching - compiles Lua to bytecode using luac
class BytecodeBuilder : LuaBuilder
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
        
        // Get Lua compiler
        string luacCmd = getCompilerCommand(config.runtime);
        
        if (!.isAvailable(luacCmd))
        {
            result.error = "Lua compiler not found: " ~ luacCmd;
            return result;
        }
        
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
            outputPath = buildPath(workspace.options.outputDir, name ~ ".luac");
        }
        
        // Create output directory
        auto outputDir = dirName(outputPath);
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        // Per-file bytecode caching for granular incremental builds
        string[] perFileOutputs;
        bool usePerFile = (sources.length > 1);
        
        if (usePerFile)
        {
            // Compile each source file individually with caching
            structuredLog.debug_("compiling_lua_sources_to_bytecode_indivi").emit();
            
            foreach (source; sources)
            {
                // Build metadata for per-file cache
                string[string] fileMetadata;
                fileMetadata["compiler"] = luacCmd;
                fileMetadata["optLevel"] = config.bytecode.optLevel.to!string;
                fileMetadata["stripDebug"] = config.bytecode.stripDebug.to!string;
                
                // Create per-file action ID
                ActionId fileActionId;
                fileActionId.targetId = target.name;
                fileActionId.type = ActionType.Compile;
                fileActionId.subId = baseName(source);
                fileActionId.inputHash = FastHash.hashFile(source);
                
                string fileOutput = buildPath(outputDir, baseName(source).stripExtension ~ ".luac");
                
                // Check if per-file compilation is cached
                if (actionCache && actionCache.isCached(fileActionId, [source], fileMetadata) && exists(fileOutput))
                {
                    structuredLog.debug_("__cached_bytecode_").field("detail", "  [Cached] Bytecode: " ~ baseName(source)).emit();
                    perFileOutputs ~= fileOutput;
                    continue;
                }
                
                // Compile this file
                string[] cmd = [luacCmd, "-o", fileOutput];
                
                if (config.bytecode.optLevel == BytecodeOptLevel.Full && config.bytecode.stripDebug)
                    cmd ~= "-s";
                
                cmd ~= source;
                
                structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ source).emit();
                auto res = execute(cmd);
                bool success = (res.status == 0);
                
                if (!success)
                {
                    result.error = "Bytecode compilation failed for " ~ source ~ ": " ~ res.output;
                    if (actionCache)
                        actionCache.update(fileActionId, [source], [], fileMetadata, false);
                    return result;
                }
                
                perFileOutputs ~= fileOutput;
                
                // Update per-file cache
                if (actionCache)
                    actionCache.update(fileActionId, [source], [fileOutput], fileMetadata, true);
            }
            
            result.success = true;
            result.outputs = perFileOutputs;
            result.outputHash = FastHash.hashStrings(sources);
            return result;
        }
        
        // Batch bytecode compilation (original behavior)
        // Build metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = luacCmd;
        metadata["optLevel"] = config.bytecode.optLevel.to!string;
        metadata["stripDebug"] = config.bytecode.stripDebug.to!string;
        metadata["listDeps"] = config.bytecode.listDeps.to!string;
        
        // Create action ID for bytecode compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "bytecode";
        actionId.inputHash = FastHash.hashStrings(sources);
        
        // Check if compilation is cached
        if (actionCache && actionCache.isCached(actionId, sources, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_bytecode_compilation_").field("detail", "  [Cached] Bytecode compilation: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Build luac command
        string[] cmd = [luacCmd];
        
        // Add flags based on configuration
        cmd ~= "-o";
        cmd ~= outputPath;
        
        // Optimization flags
        final switch (config.bytecode.optLevel)
        {
            case BytecodeOptLevel.None:
                // No optimization flags
                break;
            case BytecodeOptLevel.Basic:
                // Default luac behavior
                break;
            case BytecodeOptLevel.Full:
                // Strip debug info for smaller bytecode
                if (config.bytecode.stripDebug)
                {
                    cmd ~= "-s";
                }
                break;
        }
        
        // List dependencies
        if (config.bytecode.listDeps)
        {
            cmd ~= "-l";
        }
        
        // Add source files
        cmd ~= sources;
        
        // Compile bytecode
        structuredLog.debug_("compiling_bytecode_").field("detail", "Compiling bytecode: " ~ cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Bytecode compilation failed: " ~ res.output;
            
            // Update cache with failure
            if (actionCache)
            {
                actionCache.update(actionId, sources, [], metadata, false);
            }
            
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashStrings(sources);
        
        // Update cache with success
        if (actionCache)
        {
            actionCache.update(actionId, sources, [outputPath], metadata, true);
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        return .isAvailable("luac") || .isAvailable("luac5.4") ||
               .isAvailable("luac5.3") || .isAvailable("luac5.2") ||
               .isAvailable("luac5.1");
    }
    
    override string name() const
    {
        return "Bytecode";
    }
}

