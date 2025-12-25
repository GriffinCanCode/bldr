module languages.web.css.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import languages.base.base;
import languages.web.css.core.config;
import languages.web.css.processors;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// CSS/SCSS/PostCSS build handler with action-level caching
class CSSHandler : BaseLanguageHandler
{
    private ActionCache actionCache;
    
    this()
    {
        auto cacheConfig = ActionCacheConfig.fromEnvironment();
        actionCache = new ActionCache(".builder-cache/actions/css", cacheConfig);
    }
    
    ~this()
    {
        import core.memory : GC;
        if (actionCache && !GC.inFinalizer())
        {
            try
            {
                actionCache.close();
            }
            catch (Exception) {}
        }
    }
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        Logger.debugLog("Building CSS target: " ~ target.name);
        
        // Parse CSS configuration
        CSSConfig cssConfig = parseCSSConfig(target);
        
        // Auto-detect processor from file extensions
        if (cssConfig.processor == CSSProcessorType.Auto)
        {
            cssConfig.processor = detectProcessor(target.sources);
        }
        
        final switch (target.type)
        {
            case TargetType.Executable:
            case TargetType.Library:
                result = compileCSS(target, config, cssConfig);
                break;
            case TargetType.Test:
                // CSS doesn't have tests, just validate
                result = validateCSS(target, config, cssConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = compileCSS(target, config, cssConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        CSSConfig cssConfig = parseCSSConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else if (!cssConfig.output.empty)
        {
            outputs ~= buildPath(config.options.outputDir, cssConfig.output);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(config.options.outputDir, name ~ ".css");
        }
        
        if (cssConfig.sourcemap)
        {
            outputs ~= outputs[0] ~ ".map";
        }
        
        return outputs;
    }
    
    private LanguageBuildResult compileCSS(in Target target, in WorkspaceConfig config, CSSConfig cssConfig)
    {
        LanguageBuildResult result;
        
        // Check for empty sources
        if (target.sources.length == 0)
        {
            result.success = false;
            result.error = "No source files specified for target " ~ target.name;
            return result;
        }
        
        // Production mode enables minification
        if (cssConfig.mode == CSSBuildMode.Production)
        {
            cssConfig.minify = true;
        }
        
        // Create processor
        auto processor = CSSProcessorFactory.create(cssConfig.processor);
        
        if (!processor.isAvailable())
        {
            // Fallback to no processing for pure CSS
            if (cssConfig.processor != CSSProcessorType.None)
            {
                Logger.warning("Processor '" ~ processor.name() ~ "' not available, using pure CSS");
                processor = CSSProcessorFactory.create(CSSProcessorType.None);
            }
        }
        
        Logger.debugLog("Using CSS processor: " ~ processor.name());
        
        // Prepare inputs: sources + config files
        string[] inputFiles = target.sources.dup;
        
        // Add processor config files if they exist
        if (!target.sources.empty)
        {
            string baseDir = dirName(target.sources[0]);
            
            // PostCSS configs
            string[] configFiles = [
                buildPath(baseDir, "postcss.config.js"),
                buildPath(baseDir, "postcss.config.json"),
                buildPath(baseDir, ".postcssrc"),
                buildPath(baseDir, "tailwind.config.js"),
                buildPath(baseDir, ".browserslistrc")
            ];
            
            // SCSS config
            if (cssConfig.processor == CSSProcessorType.SCSS)
            {
                configFiles ~= buildPath(baseDir, "sass-options.json");
            }
            
            foreach (cf; configFiles)
            {
                if (exists(cf))
                    inputFiles ~= cf;
            }
        }
        
        // Add explicit tailwind config if specified
        if (!cssConfig.tailwindConfig.empty && exists(cssConfig.tailwindConfig))
        {
            inputFiles ~= cssConfig.tailwindConfig;
        }
        
        // Determine expected outputs
        string[] expectedOutputs = getOutputs(target, config);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["processor"] = processor.name();
        metadata["processorVersion"] = processor.getVersion();
        metadata["processorType"] = cssConfig.processor.to!string;
        metadata["minify"] = cssConfig.minify.to!string;
        metadata["sourcemap"] = cssConfig.sourcemap.to!string;
        metadata["autoprefix"] = cssConfig.autoprefix.to!string;
        metadata["purge"] = cssConfig.purge.to!string;
        metadata["framework"] = cssConfig.framework.to!string;
        
        if (!cssConfig.output.empty)
            metadata["output"] = cssConfig.output;
        if (!cssConfig.targets.empty)
            metadata["targets"] = cssConfig.targets.join(",");
        if (!cssConfig.postcssPlugins.empty)
            metadata["postcssPlugins"] = cssConfig.postcssPlugins.join(",");
        if (!cssConfig.includePaths.empty)
            metadata["includePaths"] = cssConfig.includePaths.join(",");
        if (!cssConfig.contentPaths.empty)
            metadata["contentPaths"] = cssConfig.contentPaths.join(",");
        
        // Create action ID for CSS processing
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Transform;  // CSS processing is a transformation
        actionId.subId = "css-compile";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, inputFiles, metadata))
        {
            bool allOutputsExist = expectedOutputs.all!(o => exists(o));
            if (allOutputsExist)
            {
                Logger.debugLog("  [Cached] CSS compilation: " ~ target.name);
                result.success = true;
                result.outputs = expectedOutputs;
                result.outputHash = FastHash.hashStrings(expectedOutputs);
                return result;
            }
        }
        
        // Compile
        auto compileResult = processor.compile(target.sources, cssConfig, target, config);
        
        bool success = compileResult.success;
        
        // Update cache with result
        actionCache.update(
            actionId,
            inputFiles,
            compileResult.outputs,
            metadata,
            success
        );
        
        if (!success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        result.success = true;
        result.outputs = compileResult.outputs;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    private LanguageBuildResult validateCSS(in Target target, in WorkspaceConfig config, CSSConfig cssConfig)
    {
        LanguageBuildResult result;
        
        // Simple validation - check files exist and are readable
        foreach (source; target.sources)
        {
            if (!exists(source) || !isFile(source))
            {
                result.error = "CSS file not found: " ~ source;
                return result;
            }
            
            try
            {
                readText(source);
            }
            catch (Exception e)
            {
                result.error = "Failed to read CSS file " ~ source ~ ": " ~ e.msg;
                return result;
            }
        }
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    /// Parse CSS configuration from target
    private CSSConfig parseCSSConfig(in Target target)
    {
        CSSConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("css" in target.langConfig)
            configKey = "css";
        else if ("cssConfig" in target.langConfig)
            configKey = "cssConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = CSSConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                Logger.warning("Failed to parse CSS config, using defaults: " ~ e.msg);
            }
        }
        
        // Auto-detect entry point if not specified
        if (config.entry.empty && !target.sources.empty)
        {
            config.entry = target.sources[0];
        }
        
        return config;
    }
    
    /// Detect processor from file extensions
    private CSSProcessorType detectProcessor(const(string[]) sources)
    {
        foreach (source; sources)
        {
            string ext = extension(source);
            switch (ext)
            {
                case ".scss":
                case ".sass":
                    return CSSProcessorType.SCSS;
                case ".less":
                    return CSSProcessorType.Less;
                case ".styl":
                case ".stylus":
                    return CSSProcessorType.Stylus;
                default:
                    break;
            }
        }
        
        // Check for PostCSS config files
        if (!sources.empty)
        {
            string dir = dirName(sources[0]);
            if (exists(buildPath(dir, "postcss.config.js")) ||
                exists(buildPath(dir, "postcss.config.json")) ||
                exists(buildPath(dir, ".postcssrc")))
            {
                return CSSProcessorType.PostCSS;
            }
        }
        
        // Default to pure CSS
        return CSSProcessorType.None;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        // CSS imports are typically @import statements
        // For now, return empty - could be enhanced
        return [];
    }
}

