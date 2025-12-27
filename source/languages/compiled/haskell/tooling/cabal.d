module languages.compiled.haskell.tooling.cabal;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.haskell.core.config;
import infrastructure.config.schema.schema;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionId, ActionType;
import infrastructure.utils.files.hash : FastHash;

/// Cabal build tool wrapper with action-level caching
struct CabalWrapper
{
    /// Check if Cabal is available
    static bool isAvailable() nothrow
    {
        try
        {
            auto result = execute(["cabal", "--version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Get Cabal version
    static string getVersion()
    {
        try
        {
            auto result = execute(["cabal", "--version"]);
            if (result.status == 0)
            {
                // Output format: "cabal-install version X.Y.Z.W ..."
                auto lines = result.output.lineSplitter.front;
                auto parts = lines.split;
                if (parts.length >= 3)
                {
                    return parts[2];
                }
                return lines;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_get_cabal_version_").field("detail", "Failed to get Cabal version: " ~ e.msg).emit();
        }
        return "unknown";
    }
    
    /// Build with Cabal with action-level caching
    static LanguageBuildResult build(
        in Target target,
        in WorkspaceConfig config,
        const HaskellConfig hsConfig,
        ActionCache actionCache = null
    )
    {
        LanguageBuildResult result;
        
        if (!isAvailable())
        {
            result.error = "Cabal not found";
            return result;
        }
        
        // Ensure we have a cabal file
        string cabalFile = hsConfig.cabalFile;
        if (cabalFile.empty)
        {
            // Look for *.cabal in project root
            auto cabalFiles = dirEntries(config.root, "*.cabal", SpanMode.shallow).array;
            if (cabalFiles.empty)
            {
                result.error = "No .cabal file found. Run 'cabal init' to create one.";
                return result;
            }
            cabalFile = cabalFiles[0].name;
        }
        
        structuredLog.debug_("using_cabal_file_").field("detail", "Using Cabal file: " ~ cabalFile).emit();
        
        // Gather input files for action caching
        string[] inputFiles = target.sources.dup;
        inputFiles ~= cabalFile;
        
        // Add cabal.project files if they exist
        string cabalProject = buildPath(config.root, "cabal.project");
        if (exists(cabalProject))
            inputFiles ~= cabalProject;
        
        string cabalProjectLocal = buildPath(config.root, "cabal.project.local");
        if (exists(cabalProjectLocal))
            inputFiles ~= cabalProjectLocal;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["cabalVersion"] = getVersion();
        metadata["mode"] = hsConfig.mode.to!string;
        metadata["optLevel"] = hsConfig.optLevel.to!string;
        metadata["parallel"] = hsConfig.parallel.to!string;
        metadata["jobs"] = hsConfig.jobs.to!string;
        metadata["ghcOptions"] = hsConfig.ghcOptions.join(" ");
        
        // Create action ID for Cabal build
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "cabal-build";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // For cabal, we check if build succeeded and output exists
        string distDir = buildPath(config.root, "dist-newstyle");
        
        // Check if build is cached
        if (actionCache !is null && actionCache.isCached(actionId, inputFiles, metadata) && exists(distDir))
        {
            structuredLog.debug_("__cached_cabal_build").emit();
            result.success = true;
            result.outputs = findBuiltExecutables(distDir);
            if (!result.outputs.empty)
                result.outputHash = FastHash.hashFile(result.outputs[0]);
            return result;
        }
        
        // Update dependencies
        if (!updateDependencies(config.root))
        {
            structuredLog.warning("failed_to_update_cabal_dependencies").emit();
        }
        
        // Build command based on mode
        string[] args = ["cabal"];
        
        final switch (hsConfig.mode)
        {
            case HaskellBuildMode.Compile:
            case HaskellBuildMode.Library:
                args ~= "build";
                break;
            case HaskellBuildMode.Test:
                args ~= "test";
                break;
            case HaskellBuildMode.Doc:
                args ~= "haddock";
                break;
            case HaskellBuildMode.REPL:
                result.error = "REPL mode not supported in build";
                return result;
            case HaskellBuildMode.Custom:
                args ~= "build";
                break;
        }
        
        // Parallel jobs
        if (hsConfig.parallel && hsConfig.jobs > 0)
        {
            args ~= "-j" ~ hsConfig.jobs.to!string;
        }
        else if (hsConfig.parallel)
        {
            args ~= "-j";
        }
        
        // Optimization
        final switch (hsConfig.optLevel)
        {
            case GHCOptLevel.O0: args ~= "--ghc-options=-O0"; break;
            case GHCOptLevel.O1: args ~= "--ghc-options=-O1"; break;
            case GHCOptLevel.O2: args ~= "--ghc-options=-O2"; break;
        }
        
        // Additional GHC options
        foreach (opt; hsConfig.ghcOptions)
        {
            args ~= "--ghc-options=" ~ opt;
        }
        
        // Test options (for test mode)
        if (hsConfig.mode == HaskellBuildMode.Test)
        {
            args ~= hsConfig.testOptions;
        }
        
        // Execute build
        structuredLog.debug_("building_with_cabal").emit();
        structuredLog.debug_("__command_").field("detail", "  Command: " ~ args.join(" ")).emit();
        
        bool success = false;
        
        try
        {
            auto execResult = execute(args, null, Config.none, size_t.max, config.root);
            
            success = (execResult.status == 0);
            
            if (success)
            {
                result.success = true;
                
                // Find output executables
                if (exists(distDir))
                {
                    result.outputs = findBuiltExecutables(distDir);
                }
                
                if (!result.outputs.empty && exists(result.outputs[0]))
                {
                    result.outputHash = FastHash.hashFile(result.outputs[0]);
                }
                
                if (!execResult.output.empty)
                {
                    structuredLog.debug_("cabal_output_").field("detail", "Cabal output: " ~ execResult.output).emit();
                }
                
                // Update cache with success
                if (actionCache !is null)
                {
                    actionCache.update(
                        actionId,
                        inputFiles,
                        result.outputs,
                        metadata,
                        true
                    );
                }
            }
            else
            {
                result.error = execResult.output;
                structuredLog.error("cabal_build_failed").emit();
                structuredLog.error("log_event").field("message", execResult.output).emit();
                
                // Update cache with failure
                if (actionCache !is null)
                {
                    actionCache.update(
                        actionId,
                        inputFiles,
                        [],
                        metadata,
                        false
                    );
                }
            }
        }
        catch (Exception e)
        {
            result.error = "Cabal execution failed: " ~ e.msg;
            structuredLog.error("log_event").field("message", result.error).emit();
            
            // Update cache with failure
            if (actionCache !is null)
            {
                actionCache.update(
                    actionId,
                    inputFiles,
                    [],
                    metadata,
                    false
                );
            }
        }
        
        return result;
    }
    
    /// Update Cabal dependencies
    static bool updateDependencies(string projectRoot)
    {
        try
        {
            auto result = execute(["cabal", "update"], null, Config.none, size_t.max, projectRoot);
            return result.status == 0;
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_update_cabal_dependencies_").field("detail", "Failed to update Cabal dependencies: " ~ e.msg).emit();
            return false;
        }
    }
    
    /// Find built executables in dist directory
    private static string[] findBuiltExecutables(string distDir)
    {
        string[] executables;
        
        try
        {
            // Look in dist-newstyle/build/*/ghc-*/package-*/x/executable/build/executable/
            foreach (entry; dirEntries(distDir, SpanMode.depth))
            {
                if (entry.isFile)
                {
                    // Check if file is executable (has execute permissions)
                    version (Posix)
                    {
                        import core.sys.posix.sys.stat;
                        stat_t statbuf;
                        if (stat(entry.name.toStringz, &statbuf) == 0)
                        {
                            if ((statbuf.st_mode & S_IXUSR) != 0)
                            {
                                executables ~= entry.name;
                            }
                        }
                    }
                    else
                    {
                        // On Windows, check for .exe extension
                        if (extension(entry.name) == ".exe")
                        {
                            executables ~= entry.name;
                        }
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_find_executables_").field("detail", "Failed to find executables: " ~ e.msg).emit();
        }
        
        return executables;
    }
}

