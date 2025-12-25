module languages.compiled.nim.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import languages.base.base;
import languages.base.mixins;
import languages.compiled.nim.core.config;
import languages.compiled.nim.builders;
import languages.compiled.nim.tooling.tools;
import languages.compiled.nim.analysis.nimble;
import languages.compiled.nim.managers.nimble;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import engine.caching.actions.action : ActionCache, ActionCacheConfig;

/// Comprehensive Nim build handler with multi-backend support and action-level caching
class NimHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"nim";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        Logger.debugLog("Building Nim target: " ~ target.name);
        
        // Parse Nim configuration
        NimConfig nimConfig = parseNimConfig(target);
        
        // Auto-detect and enhance configuration from project
        enhanceConfigFromProject(nimConfig, target, config);
        
        // Run formatter if requested
        if (nimConfig.runFormat)
        {
            auto fmtResult = formatCode(target.sources.dup, nimConfig);
            if (fmtResult.hasIssues)
            {
                Logger.info("Formatting issues found:");
                foreach (warning; fmtResult.warnings)
                {
                    Logger.warning("  " ~ warning);
                }
            }
        }
        
        // Run check if requested
        if (nimConfig.runCheck)
        {
            auto checkResult = NimTools.check(target.sources.dup);
            if (!checkResult.success)
            {
                Logger.warning("Check found issues:");
                foreach (error; checkResult.errors)
                {
                    Logger.warning("  " ~ error);
                }
            }
        }
        
        // Install dependencies if requested
        if (nimConfig.nimble.enabled && nimConfig.nimble.installDeps)
        {
            string projectDir = target.sources.empty ? "." : dirName(target.sources[0]);
            NimbleManager.installDependencies(
                projectDir,
                nimConfig.nimble.devMode,
                nimConfig.verbose
            );
        }
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, nimConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, nimConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, nimConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, nimConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        NimConfig nimConfig = parseNimConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            string outputDir = nimConfig.outputDir.empty ? 
                              config.options.outputDir : 
                              nimConfig.outputDir;
            
            // Add extension based on app type and platform
            string extension = getOutputExtension(nimConfig);
            
            outputs ~= buildPath(outputDir, name ~ extension);
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Nim);
        if (spec is null)
            return [];
        
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = spec.scanImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                Logger.warning("Failed to analyze imports in " ~ source);
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        NimConfig nimConfig
    )
    {
        LanguageBuildResult result;
        
        // Ensure app type is appropriate for executable
        if (nimConfig.appType != AppType.Console && nimConfig.appType != AppType.Gui)
        {
            nimConfig.appType = AppType.Console;
        }
        
        // Auto-detect entry point
        if (nimConfig.entry.empty && !target.sources.empty)
        {
            // Look for main.nim first
            foreach (source; target.sources)
            {
                if (baseName(source) == "main.nim")
                {
                    nimConfig.entry = source;
                    break;
                }
            }
            
            // Fallback to first source
            if (nimConfig.entry.empty)
                nimConfig.entry = target.sources[0];
        }
        
        // Build with selected builder
        return compileTarget(target, config, nimConfig);
    }
    
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        NimConfig nimConfig
    )
    {
        LanguageBuildResult result;
        
        // Set app type to library
        if (nimConfig.appType != AppType.StaticLib && nimConfig.appType != AppType.DynamicLib)
        {
            nimConfig.appType = AppType.StaticLib; // Default to static
        }
        
        // Auto-detect entry point
        if (nimConfig.entry.empty && !target.sources.empty)
        {
            // Look for lib.nim or packagename.nim
            string nimbleFile = NimbleParser.findNimbleFile(".");
            if (!nimbleFile.empty)
            {
                auto nimbleData = NimbleParser.parseNimbleFile(nimbleFile);
                if (!nimbleData.name.empty)
                {
                    string libFile = nimbleData.name ~ ".nim";
                    foreach (source; target.sources)
                    {
                        if (baseName(source) == libFile || baseName(source) == "lib.nim")
                        {
                            nimConfig.entry = source;
                            break;
                        }
                    }
                }
            }
            
            // Fallback to first source
            if (nimConfig.entry.empty)
                nimConfig.entry = target.sources[0];
        }
        
        return compileTarget(target, config, nimConfig);
    }
    
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        NimConfig nimConfig
    )
    {
        LanguageBuildResult result;
        
        // Set mode to test
        if (nimConfig.mode != NimBuildMode.Test)
            nimConfig.mode = NimBuildMode.Test;
        
        return compileTarget(target, config, nimConfig);
    }
    
    private LanguageBuildResult buildCustom(
        in Target target,
        in WorkspaceConfig config,
        NimConfig nimConfig
    )
    {
        LanguageBuildResult result;
        
        nimConfig.mode = NimBuildMode.Custom;
        
        return compileTarget(target, config, nimConfig);
    }
    
    private LanguageBuildResult compileTarget(
        in Target target,
        in WorkspaceConfig config,
        NimConfig nimConfig
    )
    {
        LanguageBuildResult result;
        
        // Create builder and pass actionCache
        auto builder = NimBuilderFactory.create(nimConfig.builder, nimConfig, actionCache);
        
        if (!builder.isAvailable())
        {
            result.error = "Nim compiler not available. Install from: https://nim-lang.org/install.html";
            return result;
        }
        
        Logger.debugLog("Using Nim builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")");
        
        // Compile (with action-level caching)
        auto compileResult = builder.build(target.sources, nimConfig, target, config);
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report warnings
        if (compileResult.hadWarnings && !compileResult.warnings.empty)
        {
            Logger.warning("Compilation warnings:");
            import std.algorithm : min;
            foreach (warn; compileResult.warnings[0 .. min(5, $)])
            {
                Logger.warning("  " ~ warn);
            }
            if (compileResult.warnings.length > 5)
            {
                import std.conv : to;
                Logger.warning("  ... and " ~ (compileResult.warnings.length - 5).to!string ~ " more warnings");
            }
        }
        
        result.success = true;
        result.outputs = compileResult.outputs ~ compileResult.artifacts;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    private NimConfig parseNimConfig(in Target target)
    {
        NimConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("nim" in target.langConfig)
            configKey = "nim";
        else if ("nimConfig" in target.langConfig)
            configKey = "nimConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = NimConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                Logger.warning("Failed to parse Nim config, using defaults: " ~ e.msg);
            }
        }
        
        // Apply target flags to config if not in langConfig
        if (!target.flags.empty && configKey.empty)
        {
            config.compilerFlags ~= target.flags;
        }
        
        return config;
    }
    
    private void enhanceConfigFromProject(
        ref NimConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        // Auto-detect nimble file
        if (config.builder == NimBuilderType.Auto || config.nimble.enabled)
        {
            string nimbleFile = NimbleParser.findNimbleFile(sourceDir);
            if (!nimbleFile.empty)
            {
                Logger.debugLog("Detected nimble file: " ~ nimbleFile);
                config.nimble.nimbleFile = nimbleFile;
                
                // Parse nimble file for project info
                auto nimbleData = NimbleParser.parseNimbleFile(nimbleFile);
                if (!nimbleData.name.empty)
                {
                    Logger.debugLog("Package: " ~ nimbleData.name ~ 
                                 (nimbleData.version_.empty ? "" : " v" ~ nimbleData.version_));
                    
                    // Set backend from nimble file if specified
                    if (!nimbleData.backend.empty && config.backend == NimBackend.C)
                    {
                        import std.uni : toLower;
                        switch (nimbleData.backend.toLower)
                        {
                            case "cpp": case "c++":
                                config.backend = NimBackend.Cpp;
                                break;
                            case "js": case "javascript":
                                config.backend = NimBackend.Js;
                                break;
                            case "objc": case "objective-c":
                                config.backend = NimBackend.ObjC;
                                break;
                            default:
                                break;
                        }
                    }
                }
            }
        }
        
        // Auto-detect entry point if not specified
        if (config.entry.empty && !target.sources.empty)
        {
            // Priority: main.nim > lib.nim > package name.nim > first source
            string[] candidates = ["main.nim", "lib.nim"];
            
            foreach (candidate; candidates)
            {
                foreach (source; target.sources)
                {
                    if (baseName(source) == candidate)
                    {
                        config.entry = source;
                        break;
                    }
                }
                if (!config.entry.empty)
                    break;
            }
            
            // Fallback to first source
            if (config.entry.empty)
                config.entry = target.sources[0];
        }
    }
    
    private FormatResult formatCode(in string[] sources, NimConfig config)
    {
        return NimTools.format(
            sources.dup,
            config.formatCheck,
            config.formatIndent,
            config.formatMaxLineLen
        );
    }
    
    private string getOutputExtension(NimConfig config)
    {
        // For JavaScript backend
        if (config.backend == NimBackend.Js)
            return ".js";
        
        // For libraries
        if (config.appType == AppType.StaticLib)
        {
            version(Windows)
                return ".lib";
            else
                return ".a";
        }
        
        if (config.appType == AppType.DynamicLib)
        {
            version(Windows)
                return ".dll";
            else version(OSX)
                return ".dylib";
            else
                return ".so";
        }
        
        // For executables
        version(Windows)
            return ".exe";
        else
            return "";
    }
}

