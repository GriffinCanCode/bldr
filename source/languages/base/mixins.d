module languages.base.mixins;

import std.conv : to;
import std.path : buildPath;
import std.array : split, empty;
import engine.caching.actions.action : ActionCache, ActionCacheConfig;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.logging.logger : Logger;

/// Generates ActionCache field, constructor, and destructor for a language handler
/// Usage: mixin CachingHandlerMixin!"python";
mixin template CachingHandlerMixin(string languageName)
{
    import engine.caching.actions.action : ActionCache, ActionCacheConfig;
    import engine.runtime.shutdown.shutdown : ShutdownCoordinator;
    
    private ActionCache actionCache;
    
    this()
    {
        auto cacheConfig = ActionCacheConfig.fromEnvironment();
        actionCache = new ActionCache(".builder-cache/actions/" ~ languageName, cacheConfig);
        
        // Note: BuildServices handles cache cleanup via shutdown coordinator
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
            catch (Throwable) {}
            actionCache = null;
        }
    }
    
    /// Get access to the action cache
    protected final ActionCache getCache() @system nothrow
    {
        return actionCache;
    }
}

/// Generates config parsing method with standardized error handling
/// Usage: mixin ConfigParsingMixin!(PyConfig, "parsePyConfig", ["python", "pyConfig"]);
mixin template ConfigParsingMixin(TConfig, string methodName, string[] configKeys)
{
    import std.json : parseJSON;
    
    mixin("private TConfig " ~ methodName ~ "(in Target target)
    {
        TConfig config;
        
        // Try each config key in order
        foreach (key; configKeys)
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = TConfig.fromJSON(json);
                    return config;
                }
                catch (Exception e)
                {
                    Logger.warning(\"Failed to parse \" ~ key ~ \" config, trying next or using defaults: \" ~ e.msg);
                }
            }
        }
        
        return config;
    }");
}

/// Generates standardized output path resolution
/// Usage: mixin OutputResolutionMixin!(RustConfig, "parseRustConfig");
mixin template OutputResolutionMixin(TConfig, string configParserName, string defaultExt = "")
{
    mixin("override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        auto langConfig = " ~ configParserName ~ "(target);
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(\":\")[$ - 1];
            string ext = \"" ~ defaultExt ~ "\";
            outputs ~= buildPath(config.options.outputDir, name ~ ext);
        }
        
        return outputs;
    }");
}

/// Generates build orchestration with target type dispatching
/// Usage: mixin BuildOrchestrationMixin!(PyConfig, "parsePyConfig", "string");
mixin template BuildOrchestrationMixin(TConfig, string configParserName, ContextType...)
{
    import std.conv : to;
    
    static if (ContextType.length == 0)
    {
        // No additional context needed
        protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
        {
            // Extract target and config from context for convenience
            auto target = context.target;
            auto config = context.config;
            
            LanguageBuildResult result;
            
            Logger.debugLog("Building " ~ target.language.to!string ~ " target: " ~ target.name);
            
            auto langConfig = mixin(configParserName ~ "(target)");
            enhanceConfigFromProject(langConfig, target, config);
            
            final switch (target.type)
            {
                case TargetType.Executable:
                    result = buildExecutable(target, config, langConfig);
                    break;
                case TargetType.Library:
                    result = buildLibrary(target, config, langConfig);
                    break;
                case TargetType.Test:
                    result = runTests(target, config, langConfig);
                    break;
                case TargetType.Custom:
                    result = buildCustom(target, config, langConfig);
                    break;
            }
            
            return result;
        }
        
        // Default implementations that can be overridden
        private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, TConfig langConfig)
        {
            LanguageBuildResult result;
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources);
            return result;
        }
        
        private void enhanceConfigFromProject(ref TConfig config, in Target target, in WorkspaceConfig wsConfig) {}
    }
    else
    {
        // With additional context (e.g., command string)
        protected override LanguageBuildResult buildImplWithContext(in BuildContext buildContext)
        {
            // Extract target and config from context for convenience
            auto target = buildContext.target;
            auto config = buildContext.config;
            
            LanguageBuildResult result;
            
            Logger.debugLog("Building " ~ target.language.to!string ~ " target: " ~ target.name);
            
            auto langConfig = mixin(configParserName ~ "(target)");
            enhanceConfigFromProject(langConfig, target, config);
            
            auto context = setupBuildContext(langConfig, config);
            
            final switch (target.type)
            {
                case TargetType.Executable:
                    result = buildExecutable(target, config, langConfig, context);
                    break;
                case TargetType.Library:
                    result = buildLibrary(target, config, langConfig, context);
                    break;
                case TargetType.Test:
                    result = runTests(target, config, langConfig, context);
                    break;
                case TargetType.Custom:
                    result = buildCustom(target, config, langConfig, context);
                    break;
            }
            
            return result;
        }
        
        // Default implementations that can be overridden
        private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, TConfig langConfig, ContextType[0] context)
        {
            LanguageBuildResult result;
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources);
            return result;
        }
        
        private void enhanceConfigFromProject(ref TConfig config, in Target target, in WorkspaceConfig wsConfig) {}
    }
}

/// Simplified orchestration for handlers without additional context
mixin template SimpleBuildOrchestrationMixin(TConfig, string configParserName)
{
    import std.conv : to;
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        Logger.debugLog("Building " ~ target.language.to!string ~ " target: " ~ target.name);
        
        auto langConfig = mixin(configParserName ~ "(target)");
        enhanceConfigFromProject(langConfig, target, config);
        
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, langConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, langConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, langConfig);
                break;
            case TargetType.Custom:
                result = buildCustom(target, config, langConfig);
                break;
        }
        
        return result;
    }
    
    // Default implementations that can be overridden
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, TConfig langConfig)
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private void enhanceConfigFromProject(ref TConfig config, in Target target, in WorkspaceConfig wsConfig) {}
}

