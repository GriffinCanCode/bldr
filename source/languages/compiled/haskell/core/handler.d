module languages.compiled.haskell.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import languages.base.base;
import languages.base.mixins;
import languages.compiled.haskell.core.config;
import languages.compiled.haskell.tooling.ghc;
import languages.compiled.haskell.tooling.cabal;
import languages.compiled.haskell.tooling.stack;
import languages.compiled.haskell.analysis.cabal : parseCabalFile;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import engine.caching.actions.action : ActionCache, ActionCacheConfig;

/// Haskell build handler with GHC, Cabal, and Stack support and action-level caching
class HaskellHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"haskell";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        Logger.debugLog("Building Haskell target: " ~ target.name);
        
        // Parse Haskell configuration
        HaskellConfig hsConfig = parseHaskellConfig(target, config);
        
        // Auto-detect build tool if needed
        if (hsConfig.buildTool == HaskellBuildTool.Auto)
        {
            hsConfig.buildTool = detectBuildTool(config.root);
        }
        
        // Validate sources
        if (target.sources.empty && hsConfig.entry.empty)
        {
            result.error = "No Haskell source files specified";
            return result;
        }
        
        // Run HLint if requested
        if (hsConfig.hlint && GHCWrapper.isHLintAvailable())
        {
            Logger.debugLog("Running HLint...");
            auto lintResult = runHLint(target, hsConfig);
            if (lintResult.hadHLintIssues)
            {
                Logger.warning("HLint found issues:");
                foreach (issue; lintResult.hlintIssues)
                {
                    Logger.warning("  " ~ issue);
                }
            }
        }
        
        // Run formatter if requested
        if (hsConfig.ormolu && GHCWrapper.isOroluAvailable())
        {
            Logger.debugLog("Running Ormolu...");
            runOrmolu(target, hsConfig);
        }
        else if (hsConfig.fourmolu && GHCWrapper.isFourmoluAvailable())
        {
            Logger.debugLog("Running Fourmolu...");
            runFourmolu(target, hsConfig);
        }
        
        // Build based on target type and build tool
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, hsConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, hsConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, hsConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, hsConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        HaskellConfig hsConfig = parseHaskellConfig(target, config);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(config.options.outputDir, name);
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = parseHaskellImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                Logger.warning("Failed to analyze imports in " ~ source ~ ": " ~ e.msg);
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target, 
        in WorkspaceConfig config, 
        HaskellConfig hsConfig
    )
    {
        LanguageBuildResult result;
        
        // Auto-detect entry point if not specified
        if (hsConfig.entry.empty && !target.sources.empty)
        {
            hsConfig.entry = findMainFile(target.sources);
        }
        
        final switch (hsConfig.buildTool)
        {
            case HaskellBuildTool.Auto:
                // Should not reach here, already resolved
                result.error = "Build tool not resolved";
                break;
            case HaskellBuildTool.GHC:
                result = buildWithGHC(target, config, hsConfig);
                break;
            case HaskellBuildTool.Cabal:
                result = buildWithCabal(target, config, hsConfig);
                break;
            case HaskellBuildTool.Stack:
                result = buildWithStack(target, config, hsConfig);
                break;
        }
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(
        in Target target, 
        in WorkspaceConfig config, 
        HaskellConfig hsConfig
    )
    {
        LanguageBuildResult result;
        hsConfig.mode = HaskellBuildMode.Library;
        
        // Libraries typically use Cabal or Stack
        if (hsConfig.buildTool == HaskellBuildTool.GHC)
        {
            Logger.warning("Direct GHC compilation for libraries is limited. Consider using Cabal or Stack.");
        }
        
        final switch (hsConfig.buildTool)
        {
            case HaskellBuildTool.Auto:
                result.error = "Build tool not resolved";
                break;
            case HaskellBuildTool.GHC:
                result = buildWithGHC(target, config, hsConfig);
                break;
            case HaskellBuildTool.Cabal:
                result = buildWithCabal(target, config, hsConfig);
                break;
            case HaskellBuildTool.Stack:
                result = buildWithStack(target, config, hsConfig);
                break;
        }
        
        return result;
    }
    
    private LanguageBuildResult runTests(
        in Target target, 
        in WorkspaceConfig config, 
        HaskellConfig hsConfig
    )
    {
        LanguageBuildResult result;
        hsConfig.mode = HaskellBuildMode.Test;
        
        final switch (hsConfig.buildTool)
        {
            case HaskellBuildTool.Auto:
                result.error = "Build tool not resolved";
                break;
            case HaskellBuildTool.GHC:
                result = buildWithGHC(target, config, hsConfig);
                break;
            case HaskellBuildTool.Cabal:
                result = buildWithCabal(target, config, hsConfig);
                break;
            case HaskellBuildTool.Stack:
                result = buildWithStack(target, config, hsConfig);
                break;
        }
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(
        in Target target, 
        in WorkspaceConfig config, 
        HaskellConfig hsConfig
    )
    {
        LanguageBuildResult result;
        hsConfig.mode = HaskellBuildMode.Custom;
        
        // For custom targets, use the configured build tool
        final switch (hsConfig.buildTool)
        {
            case HaskellBuildTool.Auto:
                result.error = "Build tool not resolved";
                break;
            case HaskellBuildTool.GHC:
                result = buildWithGHC(target, config, hsConfig);
                break;
            case HaskellBuildTool.Cabal:
                result = buildWithCabal(target, config, hsConfig);
                break;
            case HaskellBuildTool.Stack:
                result = buildWithStack(target, config, hsConfig);
                break;
        }
        
        return result;
    }
    
    private LanguageBuildResult buildWithGHC(
        in Target target,
        in WorkspaceConfig config,
        const HaskellConfig hsConfig
    )
    {
        if (!GHCWrapper.isAvailable())
        {
            LanguageBuildResult result;
            result.error = "GHC not found. Install from: https://www.haskell.org/ghcup/";
            return result;
        }
        
        Logger.debugLog("Using GHC: " ~ GHCWrapper.getVersion());
        return GHCWrapper.compile(target, config, hsConfig, actionCache);
    }
    
    private LanguageBuildResult buildWithCabal(
        in Target target,
        in WorkspaceConfig config,
        const HaskellConfig hsConfig
    )
    {
        if (!CabalWrapper.isAvailable())
        {
            LanguageBuildResult result;
            result.error = "Cabal not found. Install from: https://www.haskell.org/ghcup/";
            return result;
        }
        
        Logger.debugLog("Using Cabal: " ~ CabalWrapper.getVersion());
        return CabalWrapper.build(target, config, hsConfig, actionCache);
    }
    
    private LanguageBuildResult buildWithStack(
        in Target target,
        in WorkspaceConfig config,
        const HaskellConfig hsConfig
    )
    {
        if (!StackWrapper.isAvailable())
        {
            LanguageBuildResult result;
            result.error = "Stack not found. Install from: https://docs.haskellstack.org/";
            return result;
        }
        
        Logger.debugLog("Using Stack: " ~ StackWrapper.getVersion());
        return StackWrapper.build(target, config, hsConfig, actionCache);
    }
    
    private HaskellConfig parseHaskellConfig(in Target target, in WorkspaceConfig workspace)
    {
        HaskellConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("haskell" in target.langConfig)
            configKey = "haskell";
        else if ("hs" in target.langConfig)
            configKey = "hs";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = HaskellConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                Logger.warning("Failed to parse Haskell config, using defaults: " ~ e.msg);
            }
        }
        
        // Set default output directory if not specified
        if (config.outputDir.empty)
        {
            config.outputDir = workspace.options.outputDir;
        }
        
        return config;
    }
    
    private HaskellBuildTool detectBuildTool(string projectRoot)
    {
        // Check for stack.yaml
        if (exists(buildPath(projectRoot, "stack.yaml")))
        {
            Logger.debugLog("Detected Stack project (stack.yaml found)");
            return HaskellBuildTool.Stack;
        }
        
        // Check for *.cabal files
        if (!dirEntries(projectRoot, "*.cabal", SpanMode.shallow).empty)
        {
            Logger.debugLog("Detected Cabal project (*.cabal file found)");
            return HaskellBuildTool.Cabal;
        }
        
        // Default to GHC for simple projects
        Logger.debugLog("No build tool detected, using GHC directly");
        return HaskellBuildTool.GHC;
    }
    
    private string findMainFile(in string[] sources)
    {
        // Look for Main.hs or files with "main" in the name
        foreach (source; sources)
        {
            string base = baseName(source);
            if (base == "Main.hs" || base == "main.hs")
                return source;
        }
        
        // Look for any file with Main module
        foreach (source; sources)
        {
            if (extension(source) == ".hs" && hasMainModule(source))
                return source;
        }
        
        // Fallback to first .hs file
        foreach (source; sources)
        {
            if (extension(source) == ".hs")
                return source;
        }
        
        return sources.length > 0 ? sources[0] : "";
    }
    
    private bool hasMainModule(string filepath)
    {
        if (!exists(filepath))
            return false;
        
        try
        {
            auto content = readText(filepath);
            import std.regex;
            auto mainModuleRe = regex(r"^\s*module\s+Main\s", "m");
            return !content.matchFirst(mainModuleRe).empty;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    private HaskellCompileResult runHLint(in Target target, const HaskellConfig config)
    {
        HaskellCompileResult result;
        
        if (!GHCWrapper.isHLintAvailable())
        {
            result.success = true;
            return result;
        }
        
        string[] sources = target.sources.filter!(s => extension(s) == ".hs").array.dup;
        if (sources.empty)
        {
            result.success = true;
            return result;
        }
        
        auto lintResult = GHCWrapper.runHLint(sources);
        result.success = lintResult.success;
        result.hadHLintIssues = !lintResult.hlintIssues.empty;
        result.hlintIssues = lintResult.hlintIssues.dup;
        
        return result;
    }
    
    private void runOrmolu(in Target target, const HaskellConfig config)
    {
        string[] sources = target.sources.filter!(s => extension(s) == ".hs").array.dup;
        if (sources.empty)
            return;
        
        GHCWrapper.runOrmolu(sources);
    }
    
    private void runFourmolu(in Target target, const HaskellConfig config)
    {
        string[] sources = target.sources.filter!(s => extension(s) == ".hs").array.dup;
        if (sources.empty)
            return;
        
        GHCWrapper.runFourmolu(sources);
    }
    
    private Import[] parseHaskellImports(string filepath, string content)
    {
        Import[] imports;
        
        import std.regex;
        
        // Match: import qualified? ModuleName (as Alias)? (hiding? (...))?
        auto importRe = regex(r"^\s*import\s+(?:qualified\s+)?([A-Z][A-Za-z0-9._]*)", "m");
        
        size_t lineNum = 1;
        foreach (line; content.lineSplitter)
        {
            auto match = line.matchFirst(importRe);
            if (!match.empty && match.length >= 2)
            {
                Import imp;
                imp.moduleName = match[1];
                imp.kind = ImportKind.External; // Haskell imports are module-based
                imp.location = SourceLocation(filepath, lineNum, 0);
                imports ~= imp;
            }
            lineNum++;
        }
        
        return imports;
    }
}

