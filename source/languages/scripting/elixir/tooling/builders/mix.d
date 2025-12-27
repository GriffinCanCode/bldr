module languages.scripting.elixir.tooling.builders.mix;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import languages.scripting.elixir.tooling.builders.base;
import languages.scripting.elixir.config;
import languages.scripting.elixir.managers.mix;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Mix project builder - standard OTP applications and libraries with action-level caching
class MixProjectBuilder : ElixirBuilder
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
    ) @system
    {
        ElixirBuildResult result;
        
        structuredLog.debug_("building_mix_project").emit();
        
        string workDir = workspace.root;
        if (!sources.empty)
            workDir = dirName(sources[0]);
        
        // Check for mix.exs
        string mixExsPath = buildPath(workDir, config.project.mixExsPath);
        if (!exists(mixExsPath))
        {
            result.errors ~= "mix.exs not found at: " ~ mixExsPath;
            return result;
        }
        
        // Setup environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        // Set MIX_ENV
        string mixEnv = envToString(config.env);
        if (config.env == MixEnv.Custom && !config.customEnv.empty)
            mixEnv = config.customEnv;
        env["MIX_ENV"] = mixEnv;
        
        // Merge custom environment variables
        // Skip env_ - property doesn't exist
        // foreach (key, value; config.env_)
        //     env[key] = value;
        
        // Gather source files for cache validation
        string[] inputFiles = [mixExsPath];
        string[] moduleFiles;
        string libDir = buildPath(workDir, "lib");
        if (exists(libDir))
        {
            foreach (entry; dirEntries(libDir, "*.ex", SpanMode.depth))
            {
                inputFiles ~= entry.name;
                moduleFiles ~= entry.name;
            }
            foreach (entry; dirEntries(libDir, "*.exs", SpanMode.depth))
            {
                inputFiles ~= entry.name;
                moduleFiles ~= entry.name;
            }
        }
        
        // Per-module compilation caching for granular incremental builds
        bool anyModuleChanged = false;
        foreach (modFile; moduleFiles)
        {
            string[string] modMetadata;
            modMetadata["mixEnv"] = mixEnv;
            modMetadata["debugInfo"] = config.build.debugInfo.to!string;
            
            ActionId modActionId;
            modActionId.targetId = baseName(workDir);
            modActionId.type = ActionType.Compile;
            modActionId.subId = modFile.baseName;
            modActionId.inputHash = FastHash.hashFile(modFile);
            
            if (!actionCache || !actionCache.isCached(modActionId, [modFile], modMetadata))
            {
                anyModuleChanged = true;
                structuredLog.debug_("__changed_module_").field("detail", "  [Changed] Module: " ~ modFile.baseName).emit();
            }
            else
            {
                structuredLog.debug_("__cached_module_").field("detail", "  [Cached] Module: " ~ modFile.baseName).emit();
            }
        }
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["mixEnv"] = mixEnv;
        metadata["verbose"] = config.build.verbose.to!string;
        metadata["warningsAsErrors"] = config.build.warningsAsErrors.to!string;
        metadata["debugInfo"] = config.build.debugInfo.to!string;
        metadata["compilerOpts"] = config.build.compilerOpts.join(",");
        
        // Determine output paths
        string buildDir = config.project.buildPath;
        string outputDir = buildPath(buildDir, mixEnv, "lib");
        
        // Create action ID for Mix compile
        ActionId actionId;
        actionId.targetId = baseName(workDir);
        actionId.type = ActionType.Compile;
        actionId.subId = "mix_compile";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if compilation is cached
        if (actionCache && actionCache.isCached(actionId, inputFiles, metadata) && exists(outputDir))
        {
            structuredLog.info("__cached_mix_compilation_").field("detail", "  [Cached] Mix compilation: " ~ workDir).emit();
            result.success = true;
            result.outputs ~= outputDir;
            // result.outputHash = FastHash.hashStrings(sources);
            return result;
        }
        
        // Build Mix command
        string[] cmd = ["mix", "compile"];
        
        if (config.build.verbose)
            cmd ~= "--verbose";
        
        if (config.build.warningsAsErrors)
            cmd ~= "--warnings-as-errors";
        
        if (!config.build.debugInfo)
            cmd ~= "--no-debug-info";
        
        // Add compiler options
        if (!config.build.compilerOpts.empty)
        {
            cmd ~= "--erl-opts";
            cmd ~= config.build.compilerOpts.join(" ");
        }
        
        structuredLog.info("compiling_mix_project_").field("detail", "Compiling Mix project: " ~ cmd.join(" ")).emit();
        
        // Execute compilation
        auto res = execute(cmd, env, Config.none, size_t.max, workDir);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.errors ~= "Compilation failed: " ~ res.output;
            
            // Parse warnings from output
            result.warnings = parseCompilerWarnings(res.output);
            
            // Update cache with failure
            if (actionCache)
            {
                actionCache.update(actionId, inputFiles, [], metadata, false);
            }
            
            return result;
        }
        
        // Parse warnings even on success
        result.warnings = parseCompilerWarnings(res.output);
        
        // Collect outputs
        string[] outputs;
        if (exists(outputDir))
        {
            outputs ~= outputDir;
            result.outputs ~= outputDir;
        }
        
        result.success = true;
        // result.outputHash = FastHash.hashStrings(sources);
        
        // Update cache with success
        if (actionCache)
        {
            actionCache.update(actionId, inputFiles, outputs, metadata, true);
            
            // Update per-module caches on successful compilation
            foreach (modFile; moduleFiles)
            {
                string[string] modMetadata;
                modMetadata["mixEnv"] = mixEnv;
                modMetadata["debugInfo"] = config.build.debugInfo.to!string;
                
                ActionId modActionId;
                modActionId.targetId = baseName(workDir);
                modActionId.type = ActionType.Compile;
                modActionId.subId = modFile.baseName;
                modActionId.inputHash = FastHash.hashFile(modFile);
                
                // Determine module output (BEAM file)
                string beamDir = buildPath(buildDir, mixEnv, "lib", baseName(workDir), "ebin");
                string beamFile = buildPath(beamDir, modFile.baseName.stripExtension ~ ".beam");
                string[] modOutputs;
                if (exists(beamFile))
                    modOutputs ~= beamFile;
                
                actionCache.update(modActionId, [modFile], modOutputs, modMetadata, true);
            }
        }
        
        // Compile protocols if requested
        if (config.build.compileProtocols)
        {
            structuredLog.info("consolidating_protocols").emit();
            auto protCmd = ["mix", "compile.protocols"];
            auto protRes = execute(protCmd, env, Config.none, size_t.max, workDir);
            
            if (protRes.status != 0)
            {
                result.warnings ~= "Protocol consolidation failed";
            }
        }
        
        return result;
    }
    
    override bool isAvailable() @system
    {
        auto res = execute(["mix", "--version"]);
        return res.status == 0;
    }
    
    override string name() const @system pure nothrow
    {
        return "Mix Project";
    }
    
    /// Parse compiler warnings from output
    private string[] parseCompilerWarnings(string output) @system
    {
        string[] warnings;
        
        import std.regex;
        import std.string : strip;
        
        // Match Elixir compiler warnings
        // Format: warning: message
        //         lib/file.ex:line
        auto warningRegex = regex(`warning:.*?(?=\n\n|\n[^[:space:]]|$)", "s`);
        
        foreach (match; output.matchAll(warningRegex))
        {
            warnings ~= match[0].strip;
        }
        
        return warnings;
    }
    
    /// Convert MixEnv to string
    private string envToString(MixEnv env) @system pure nothrow
    {
        final switch (env)
        {
            case MixEnv.Dev: return "dev";
            case MixEnv.Test: return "test";
            case MixEnv.Prod: return "prod";
            case MixEnv.Custom: return "custom";
        }
    }
}

