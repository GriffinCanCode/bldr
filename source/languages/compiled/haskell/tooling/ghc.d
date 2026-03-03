module languages.compiled.haskell.tooling.ghc;

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
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;
import infrastructure.utils.files.hash : FastHash;
import engine.linking.incremental;

// Module-level incremental linker for GHC (lazy initialized)
private __gshared IncrementalLinker ghcIncLinker;
private __gshared bool ghcIncLinkerInitialized;

/// GHC compiler wrapper with action-level caching and incremental linking
struct GHCWrapper
{
    /// Get or initialize the incremental linker for GHC
    private static IncrementalLinker getIncLinker(ActionCache actionCache) @system
    {
        if (!ghcIncLinkerInitialized)
        {
            ghcIncLinker = new IncrementalLinker(".builder-cache/linking/haskell", actionCache);
            ghcIncLinkerInitialized = true;
            
            if (ghcIncLinker.isIncrementalAvailable())
                structuredLog.debug_("haskell_incremental_link_enabled")
                    .field("linker", ghcIncLinker.getLinkerConfig().type.to!string)
                    .emit();
        }
        return ghcIncLinker;
    }
    /// Check if GHC is available
    static bool isAvailable() nothrow
    {
        try
        {
            auto result = execute(["ghc", "--version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Get GHC version
    static string getVersion()
    {
        try
        {
            auto result = execute(["ghc", "--version"]);
            if (result.status == 0)
            {
                // Output format: "The Glorious Glasgow Haskell Compilation System, version X.Y.Z"
                auto lines = result.output.strip;
                auto parts = lines.split(",");
                if (parts.length >= 2)
                {
                    return parts[$ - 1].strip.replace("version ", "");
                }
                return lines;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_get_ghc_version_").field("detail", "Failed to get GHC version: " ~ e.msg).emit();
        }
        return "unknown";
    }
    
    /// Check if HLint is available
    static bool isHLintAvailable() nothrow
    {
        try
        {
            auto result = execute(["hlint", "--version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Check if Ormolu is available
    static bool isOroluAvailable() nothrow
    {
        try
        {
            auto result = execute(["ormolu", "--version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Check if Fourmolu is available
    static bool isFourmoluAvailable() nothrow
    {
        try
        {
            auto result = execute(["fourmolu", "--version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Compile with GHC with action-level caching and incremental linking
    static LanguageBuildResult compile(
        in Target target,
        in WorkspaceConfig config,
        const HaskellConfig hsConfig,
        ActionCache actionCache = null
    )
    {
        LanguageBuildResult result;
        
        if (!isAvailable())
        {
            result.error = "GHC not found";
            return result;
        }
        
        // Gather input files for action caching
        string[] inputFiles = target.sources.dup;
        
        // Add config files that affect compilation
        foreach (cabalFile; dirEntries(config.root, "*.cabal", SpanMode.shallow))
            inputFiles ~= cabalFile.name;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["ghcVersion"] = getVersion();
        metadata["optLevel"] = hsConfig.optLevel.to!string;
        metadata["standard"] = hsConfig.standard.to!string;
        metadata["extensions"] = hsConfig.extensions.join(",");
        metadata["warnings"] = hsConfig.warnings.to!string;
        metadata["werror"] = hsConfig.werror.to!string;
        metadata["profiling"] = hsConfig.profiling.to!string;
        metadata["threaded"] = hsConfig.threaded.to!string;
        metadata["static"] = hsConfig.static_.to!string;
        metadata["dynamic"] = hsConfig.dynamic.to!string;
        metadata["ghcOptions"] = hsConfig.ghcOptions.join(" ");
        metadata["customFlags"] = hsConfig.customFlags.join(" ");
        metadata["packages"] = hsConfig.packages.join(",");
        
        // Determine output path
        string outputDir = hsConfig.outputDir.empty ? config.options.outputDir : hsConfig.outputDir;
        string outputName = target.name.split(":")[$ - 1];
        string outputPath = buildPath(outputDir, outputName);
        
        // Create action ID for GHC compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "ghc-compile";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if compilation is cached
        if (actionCache !is null && actionCache.isCached(actionId, inputFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_ghc_compilation_").field("detail", "  [Cached] GHC compilation: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Initialize incremental linker
        auto incLinker = getIncLinker(actionCache);
        bool useIncrementalLink = incLinker !is null && incLinker.isIncrementalAvailable();
        
        // Analyze for incremental linking
        string linkerFlagsStr = hsConfig.ghcOptions.join(" ") ~ " " ~ hsConfig.customFlags.join(" ");
        auto linkAnalysis = incLinker.analyze(outputPath, inputFiles, hsConfig.packages, linkerFlagsStr);
        bool doIncremental = useIncrementalLink && linkAnalysis.canIncrementalLink();
        
        if (doIncremental)
            structuredLog.info("haskell_incremental_link")
                .field("output", baseName(outputPath))
                .field("changed", linkAnalysis.changedObjects.length)
                .field("total", inputFiles.length)
                .emit();
        
        string[] args = ["ghc"];
        
        // Optimization level
        final switch (hsConfig.optLevel)
        {
            case GHCOptLevel.O0: args ~= "-O0"; break;
            case GHCOptLevel.O1: args ~= "-O1"; break;
            case GHCOptLevel.O2: args ~= "-O2"; break;
        }
        
        // Language standard
        final switch (hsConfig.standard)
        {
            case HaskellStandard.Haskell98: args ~= "-XHaskell98"; break;
            case HaskellStandard.Haskell2010: args ~= "-XHaskell2010"; break;
        }
        
        // Language extensions
        foreach (ext; hsConfig.extensions)
            args ~= "-X" ~ ext;
        
        // Warnings
        if (hsConfig.warnings)
            args ~= "-Wall";
        if (hsConfig.werror)
            args ~= "-Werror";
        
        // Profiling
        if (hsConfig.profiling)
        {
            args ~= "-prof";
            args ~= "-fprof-auto";
        }
        
        // Threaded runtime
        if (hsConfig.threaded)
            args ~= "-threaded";
        
        // Static linking
        if (hsConfig.static_)
            args ~= "-static";
        
        // Dynamic linking
        if (hsConfig.dynamic)
            args ~= "-dynamic";
        
        // Include directories
        foreach (dir; hsConfig.includeDirs)
            args ~= "-i" ~ dir;
        
        // Library directories
        foreach (dir; hsConfig.libDirs)
            args ~= "-L" ~ dir;
        
        // Packages
        foreach (pkg; hsConfig.packages)
        {
            args ~= "-package";
            args ~= pkg;
        }
        
        // Add incremental linker flags via -optl (GHC passes to linker)
        if (doIncremental)
        {
            auto incFlags = incLinker.getLinkerFlags(linkAnalysis);
            foreach (flag; incFlags)
                args ~= "-optl" ~ flag;
        }
        
        // GHC options
        args ~= hsConfig.ghcOptions;
        
        // Custom flags
        args ~= hsConfig.customFlags;
        
        // Output directory
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        args ~= "-o";
        args ~= outputPath;
        
        // Mode-specific options
        final switch (hsConfig.mode)
        {
            case HaskellBuildMode.Compile:
                break;
            case HaskellBuildMode.Library:
                structuredLog.warning("library_compilation_with_ghc_directly_is").emit();
                break;
            case HaskellBuildMode.Test:
                break;
            case HaskellBuildMode.Doc:
                result.error = "Documentation generation requires Cabal or Haddock";
                return result;
            case HaskellBuildMode.REPL:
                result.error = "REPL mode not supported in build";
                return result;
            case HaskellBuildMode.Custom:
                break;
        }
        
        // Add source files
        string mainFile = hsConfig.entry.empty ? "" : hsConfig.entry;
        if (mainFile.empty && !target.sources.empty)
        {
            foreach (src; target.sources)
            {
                if (extension(src) == ".hs")
                {
                    mainFile = src;
                    break;
                }
            }
        }
        
        if (mainFile.empty)
        {
            result.error = "No Haskell source file specified";
            return result;
        }
        
        args ~= mainFile;
        
        // Execute compilation
        structuredLog.debug_("compiling_with_ghc_").field("detail", "Compiling with GHC: " ~ mainFile).emit();
        structuredLog.debug_("__command_").field("detail", "  Command: " ~ args.join(" ")).emit();
        
        try
        {
            auto execResult = execute(args, null, Config.none, size_t.max, config.root);
            bool success = (execResult.status == 0);
            
            if (success)
            {
                result.success = true;
                result.outputs = [outputPath];
                
                if (exists(outputPath))
                    result.outputHash = FastHash.hashFile(outputPath);
                
                if (!execResult.output.empty)
                    structuredLog.debug_("ghc_output_").field("detail", "GHC output: " ~ execResult.output).emit();
                
                // Update caches
                if (actionCache !is null)
                    actionCache.update(actionId, inputFiles, [outputPath], metadata, true);
                incLinker.recordLink(outputPath, inputFiles, hsConfig.packages, linkerFlagsStr, doIncremental);
            }
            else
            {
                result.error = execResult.output;
                structuredLog.error("ghc_compilation_failed").emit();
                structuredLog.error("log_event").field("message", execResult.output).emit();
                
                if (actionCache !is null)
                    actionCache.update(actionId, inputFiles, [], metadata, false);
                incLinker.invalidate(outputPath);
            }
        }
        catch (Exception e)
        {
            result.error = "GHC execution failed: " ~ e.msg;
            structuredLog.error("log_event").field("message", result.error).emit();
            
            if (actionCache !is null)
                actionCache.update(actionId, inputFiles, [], metadata, false);
        }
        
        return result;
    }
    
    /// Run HLint on sources
    static HaskellCompileResult runHLint(in string[] sources)
    {
        HaskellCompileResult result;
        result.success = true;
        
        if (!isHLintAvailable())
        {
            return result;
        }
        
        string[] args = ["hlint"] ~ sources.dup;
        
        try
        {
            auto execResult = execute(args);
            
            if (execResult.status != 0 && !execResult.output.empty)
            {
                // HLint found suggestions
                result.hadHLintIssues = true;
                result.hlintIssues = execResult.output.lineSplitter.array;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("hlint_execution_failed_").field("detail", "HLint execution failed: " ~ e.msg).emit();
        }
        
        return result;
    }
    
    /// Run Ormolu formatter
    static void runOrmolu(in string[] sources)
    {
        if (!isOroluAvailable())
        {
            structuredLog.warning("ormolu_not_available").emit();
            return;
        }
        
        foreach (source; sources)
        {
            string[] args = ["ormolu", "--mode", "inplace", source];
            
            try
            {
                auto execResult = execute(args);
                if (execResult.status == 0)
                {
                    structuredLog.debug_("formatted_").field("detail", "Formatted: " ~ source).emit();
                }
                else
                {
                    structuredLog.warning("ormolu_failed_for_").field("detail", "Ormolu failed for " ~ source ~ ": " ~ execResult.output).emit();
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("ormolu_execution_failed_").field("detail", "Ormolu execution failed: " ~ e.msg).emit();
            }
        }
    }
    
    /// Run Fourmolu formatter
    static void runFourmolu(in string[] sources)
    {
        if (!isFourmoluAvailable())
        {
            structuredLog.warning("fourmolu_not_available").emit();
            return;
        }
        
        foreach (source; sources)
        {
            string[] args = ["fourmolu", "--mode", "inplace", source];
            
            try
            {
                auto execResult = execute(args);
                if (execResult.status == 0)
                {
                    structuredLog.debug_("formatted_").field("detail", "Formatted: " ~ source).emit();
                }
                else
                {
                    structuredLog.warning("fourmolu_failed_for_").field("detail", "Fourmolu failed for " ~ source ~ ": " ~ execResult.output).emit();
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("fourmolu_execution_failed_").field("detail", "Fourmolu execution failed: " ~ e.msg).emit();
            }
        }
    }
}

