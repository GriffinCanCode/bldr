module languages.web.typescript.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import languages.base.base;
import languages.base.mixins;
import languages.web.typescript.core.config;
import languages.web.typescript.tooling.checker;
import languages.web.typescript.tooling.bundlers;
import languages.web.shared_.utils;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import infrastructure.utils.process.checker : isCommandAvailable;
import engine.caching.actions.action;

/// TypeScript build handler with action-level caching for separate compile + bundle steps
class TypeScriptHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"typescript";
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        Logger.debugLog("Building TypeScript target: " ~ target.name);
        
        // Validate sources
        if (target.sources.empty)
        {
            result.error = "No source files provided for TypeScript target";
            return result;
        }
        
        // Parse TypeScript configuration
        TSConfig tsConfig = parseTSConfig(target);
        
        // Validate: TypeScript handler should process .ts/.tsx files
        // Allow .js/.jsx only if allowJs is explicitly enabled
        bool hasPlainJS = target.sources.any!(s => 
            (s.endsWith(".js") || s.endsWith(".jsx") || s.endsWith(".mjs") || s.endsWith(".cjs")) &&
            !s.endsWith(".d.ts")  // Declaration files are okay
        );
        
        if (hasPlainJS && !tsConfig.allowJs)
        {
            result.error = "TypeScript handler received JavaScript files (.js/.jsx) but allowJs is not enabled. " ~
                          "Either use language: javascript for this target, or enable allowJs in config. " ~
                          "Files: " ~ target.sources.filter!(s => 
                              (s.endsWith(".js") || s.endsWith(".jsx")) && !s.endsWith(".d.ts")
                          ).join(", ");
            return result;
        }
        
        // Detect JSX/TSX
        bool hasTSX = target.sources.any!(s => s.endsWith(".tsx"));
        if (hasTSX && tsConfig.jsx == TSXMode.React)
        {
            Logger.debugLog("Detected TSX sources");
        }
        
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, tsConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, tsConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, tsConfig);
                break;
            case TargetType.Custom:
                result = buildCustom(target, config, tsConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        TSConfig tsConfig = parseTSConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            string ext = ".js";
            
            // Adjust extension based on module format
            if (tsConfig.moduleFormat == TSModuleFormat.ESM)
                ext = ".mjs";
            
            outputs ~= buildPath(config.options.outputDir, name ~ ext);
            
            if (tsConfig.sourceMap)
            {
                outputs ~= buildPath(config.options.outputDir, name ~ ext ~ ".map");
            }
            
            if (tsConfig.declaration)
            {
                outputs ~= buildPath(config.options.outputDir, name ~ ".d.ts");
                if (tsConfig.declarationMap)
                    outputs ~= buildPath(config.options.outputDir, name ~ ".d.ts.map");
            }
        }
        
        return outputs;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, TSConfig tsConfig)
    {
        LanguageBuildResult result;
        
        // For type check only mode
        if (tsConfig.mode == TSBuildMode.Check)
        {
            return typeCheckOnly(target, config, tsConfig);
        }
        
        // Install dependencies if requested
        if (tsConfig.installDeps)
        {
            languages.web.shared_.utils.installDependencies(target.sources, tsConfig.packageManager);
        }
        
        // Compile/bundle with selected compiler
        return compileTarget(target, config, tsConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, TSConfig tsConfig)
    {
        // Libraries should use library mode
        if (tsConfig.mode != TSBuildMode.Library)
        {
            tsConfig.mode = TSBuildMode.Library;
        }
        
        // Libraries should generate declarations
        if (!tsConfig.declaration)
        {
            Logger.warning("Library target should generate declarations, enabling");
            tsConfig.declaration = true;
        }
        
        // Prefer tsc for libraries (best declaration generation)
        if (tsConfig.compiler == TSCompiler.Auto)
        {
            tsConfig.compiler = TSCompiler.TSC;
        }
        
        return compileTarget(target, config, tsConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, TSConfig tsConfig)
    {
        LanguageBuildResult result;
        
        // Run tests with configured test runner
        string[] cmd;
        
        // Try to detect test framework from package.json
        string packageJsonPath = findPackageJson(target.sources);
        if (exists(packageJsonPath))
        {
            auto testCmd = detectTestCommand(packageJsonPath);
            if (!testCmd.empty)
            {
                cmd = testCmd;
            }
        }
        
        // Fallback test commands
        if (cmd.empty)
        {
            // Try common TypeScript test runners
            if (isCommandAvailable("vitest"))
                cmd = ["vitest", "run"];
            else if (isCommandAvailable("jest"))
                cmd = ["jest"];
            else if (isCommandAvailable("ts-node"))
                cmd = ["ts-node", target.sources[0]];
            else
                cmd = ["npm", "test"];
        }
        
        Logger.debugLog("Running tests: " ~ cmd.join(" "));
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, TSConfig tsConfig)
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Compile/bundle target using configured compiler with action-level caching
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config, TSConfig tsConfig)
    {
        LanguageBuildResult result;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = tsConfig.compiler.to!string;
        metadata["mode"] = tsConfig.mode.to!string;
        metadata["target"] = tsConfig.target.to!string;
        metadata["moduleFormat"] = tsConfig.moduleFormat.to!string;
        metadata["outDir"] = tsConfig.outDir;
        metadata["declaration"] = tsConfig.declaration.to!string;
        metadata["sourceMap"] = tsConfig.sourceMap.to!string;
        metadata["strict"] = tsConfig.strict.to!string;
        
        // Add tsconfig.json as input if it exists
        string[] inputFiles = target.sources.dup;
        if (!tsConfig.tsconfig.empty && exists(tsConfig.tsconfig))
        {
            inputFiles ~= tsConfig.tsconfig;
        }
        
        // Create action ID for TypeScript compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "typescript_compile";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Create compiler/bundler for TypeScript compilation
        auto bundler = TSBundlerFactory.create(tsConfig.compiler, tsConfig, actionCache);
        
        if (!bundler.isAvailable())
        {
            result.error = "TypeScript compiler '" ~ bundler.name() ~ "' is not available. " ~
                          "Install it or set compiler to 'auto' for fallback.";
            return result;
        }
        
        Logger.debugLog("Using TypeScript compiler: " ~ bundler.name() ~ " (" ~ bundler.getVersion() ~ ")");
        
        // Compile
        auto compileResult = bundler.compile(target.sources, tsConfig, target, config);
        
        bool success = compileResult.success;
        
        if (!success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report type errors even if compilation succeeded
        if (compileResult.hadTypeErrors)
        {
            foreach (err; compileResult.typeErrors)
                Logger.warning("  " ~ err);
        }
        
        result.success = true;
        result.outputs = compileResult.outputs.dup;
        if (compileResult.declarations.length > 0)
            result.outputs ~= compileResult.declarations;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    /// Type check without compilation
    private LanguageBuildResult typeCheckOnly(in Target target, in WorkspaceConfig config, TSConfig tsConfig)
    {
        LanguageBuildResult result;
        
        auto checkResult = TypeChecker.check(target.sources, tsConfig, config.root);
        
        if (!checkResult.success)
        {
            result.error = "Type check failed:\n" ~ checkResult.errors.join("\n");
            return result;
        }
        
        if (checkResult.hasWarnings)
        {
            Logger.warning("Type check warnings:");
            foreach (warn; checkResult.warnings)
            {
                Logger.warning("  " ~ warn);
            }
        }
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    /// Parse TypeScript configuration from target
    private TSConfig parseTSConfig(in Target target)
    {
        TSConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("typescript" in target.langConfig)
            configKey = "typescript";
        else if ("tsConfig" in target.langConfig)
            configKey = "tsConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = TSConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                Logger.warning("Failed to parse TypeScript config, using defaults: " ~ e.msg);
            }
        }
        
        // Try to load from tsconfig.json if specified
        if (!config.tsconfig.empty && exists(config.tsconfig))
        {
            auto fileConfig = TypeChecker.loadFromTSConfig(config.tsconfig);
            // Merge file config with explicit config (explicit takes precedence)
            config = mergeTSConfigs(fileConfig, config);
        }
        else
        {
            // Look for tsconfig.json in project directory
            string tsconfigPath = findTSConfig(target.sources);
            if (!tsconfigPath.empty)
            {
                auto fileConfig = TypeChecker.loadFromTSConfig(tsconfigPath);
                config = mergeTSConfigs(fileConfig, config);
                config.tsconfig = tsconfigPath;
            }
        }
        
        // Auto-detect entry point if not specified
        if (config.entry.empty && !target.sources.empty)
        {
            config.entry = target.sources[0];
        }
        
        return config;
    }
    
    /// Merge two TSConfig structs (second takes precedence)
    private TSConfig mergeTSConfigs(TSConfig base, TSConfig override_)
    {
        // For now, just return override if it has values, else base
        // This is simplified; could be more sophisticated
        TSConfig result = base;
        
        if (override_.mode != TSBuildMode.Compile) result.mode = override_.mode;
        if (override_.compiler != TSCompiler.Auto) result.compiler = override_.compiler;
        if (!override_.entry.empty) result.entry = override_.entry;
        if (!override_.outDir.empty) result.outDir = override_.outDir;
        if (override_.target != TSTarget.ES2020) result.target = override_.target;
        if (override_.moduleFormat != TSModuleFormat.CommonJS) result.moduleFormat = override_.moduleFormat;
        if (override_.declaration) result.declaration = true;
        if (override_.sourceMap) result.sourceMap = true;
        if (override_.strict) result.strict = true;
        
        return result;
    }
    
    /// Find tsconfig.json in source tree
    private string findTSConfig(const(string[]) sources)
    {
        if (sources.empty)
            return "";
        
        string dir = dirName(sources[0]);
        
        while (dir != "/" && dir.length > 1)
        {
            string tsconfigPath = buildPath(dir, "tsconfig.json");
            if (exists(tsconfigPath))
                return tsconfigPath;
            
            dir = dirName(dir);
        }
        
        return "";
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.TypeScript);
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
}

