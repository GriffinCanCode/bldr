module languages.compiled.haskell.tooling.stack;

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

/// Stack build tool wrapper with action-level caching
struct StackWrapper
{
    /// Check if Stack is available
    static bool isAvailable() nothrow
    {
        try
        {
            auto result = execute(["stack", "--version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Get Stack version
    static string getVersion()
    {
        try
        {
            auto result = execute(["stack", "--version"]);
            if (result.status == 0)
            {
                // Output format: "Version X.Y.Z, Git revision ..."
                auto lines = result.output.lineSplitter.front;
                auto parts = lines.split(",");
                if (parts.length >= 1)
                {
                    return parts[0].replace("Version ", "").strip;
                }
                return lines;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_get_stack_version_").field("detail", "Failed to get Stack version: " ~ e.msg).emit();
        }
        return "unknown";
    }
    
    /// Build with Stack with action-level caching
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
            result.error = "Stack not found";
            return result;
        }
        
        // Ensure we have a stack.yaml
        string stackFile = hsConfig.stackFile.empty ? 
                          buildPath(config.root, "stack.yaml") : 
                          hsConfig.stackFile;
        
        if (!exists(stackFile))
        {
            result.error = "No stack.yaml found. Run 'stack init' to create one.";
            return result;
        }
        
        structuredLog.debug_("using_stack_file_").field("detail", "Using Stack file: " ~ stackFile).emit();
        
        // Gather input files for action caching
        string[] inputFiles = target.sources.dup;
        inputFiles ~= stackFile;
        
        // Add stack.yaml.lock if it exists
        string stackLock = buildPath(config.root, "stack.yaml.lock");
        if (exists(stackLock))
            inputFiles ~= stackLock;
        
        // Add package.yaml if it exists (hpack)
        string packageYaml = buildPath(config.root, "package.yaml");
        if (exists(packageYaml))
            inputFiles ~= packageYaml;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["stackVersion"] = getVersion();
        metadata["mode"] = hsConfig.mode.to!string;
        metadata["resolver"] = hsConfig.resolver;
        metadata["parallel"] = hsConfig.parallel.to!string;
        metadata["jobs"] = hsConfig.jobs.to!string;
        metadata["ghcOptions"] = hsConfig.ghcOptions.join(" ");
        
        // Create action ID for Stack build
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "stack-build";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // For stack, we check if build succeeded and output exists
        string stackWorkDir = buildPath(config.root, ".stack-work");
        
        // Check if build is cached
        if (actionCache !is null && actionCache.isCached(actionId, inputFiles, metadata) && exists(stackWorkDir))
        {
            structuredLog.debug_("__cached_stack_build").emit();
            result.success = true;
            result.outputs = findBuiltExecutables(stackWorkDir);
            if (!result.outputs.empty)
                result.outputHash = FastHash.hashFile(result.outputs[0]);
            return result;
        }
        
        // Build command based on mode
        string[] args = ["stack"];
        
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
        
        // Resolver (LTS version)
        if (!hsConfig.resolver.empty)
        {
            args ~= "--resolver";
            args ~= hsConfig.resolver;
        }
        
        // Parallel jobs
        if (hsConfig.parallel && hsConfig.jobs > 0)
        {
            args ~= "--jobs";
            args ~= hsConfig.jobs.to!string;
        }
        
        // GHC options
        if (!hsConfig.ghcOptions.empty)
        {
            args ~= "--ghc-options";
            args ~= hsConfig.ghcOptions.join(" ");
        }
        
        // Test options (for test mode)
        if (hsConfig.mode == HaskellBuildMode.Test)
        {
            args ~= hsConfig.testOptions;
        }
        
        // Execute build
        structuredLog.debug_("building_with_stack").emit();
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
                if (exists(stackWorkDir))
                {
                    result.outputs = findBuiltExecutables(stackWorkDir);
                }
                
                if (!result.outputs.empty && exists(result.outputs[0]))
                {
                    result.outputHash = FastHash.hashFile(result.outputs[0]);
                }
                
                if (!execResult.output.empty)
                {
                    structuredLog.debug_("stack_output_").field("detail", "Stack output: " ~ execResult.output).emit();
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
                structuredLog.error("stack_build_failed").emit();
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
            result.error = "Stack execution failed: " ~ e.msg;
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
    
    /// Find built executables in .stack-work directory
    private static string[] findBuiltExecutables(string stackWorkDir)
    {
        string[] executables;
        
        try
        {
            // Look in .stack-work/dist/*/build/*/
            foreach (entry; dirEntries(stackWorkDir, SpanMode.depth))
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

