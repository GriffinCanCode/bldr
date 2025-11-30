module languages.web.javascript.core.handler;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv : to;
import languages.base.base;
import languages.base.mixins;
import languages.web.javascript.bundlers;
import languages.web.javascript.core.config;
import languages.web.shared_.utils;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import infrastructure.utils.process.checker : isCommandAvailable;
// SECURITY: Use secure execute with automatic path validation
import infrastructure.utils.security : execute;
import std.process : Config;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// JavaScript/TypeScript build handler with bundler support and action-level caching
class JavaScriptHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"javascript";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        try
        {
            // Extract target and config from context for convenience
            auto target = context.target;
            auto config = context.config;
            
            LanguageBuildResult result;
            
            Logger.debugLog("Building JavaScript target: " ~ target.name);
            
            // Parse JavaScript configuration
            JSConfig jsConfig = parseJSConfig(target);
            
            // Validate: JavaScript handler should only process .js/.jsx files, not TypeScript
            bool hasTypeScript = target.sources.any!(s => s.endsWith(".ts") || s.endsWith(".tsx") || s.endsWith(".mts") || s.endsWith(".cts"));
            if (hasTypeScript)
            {
                result.error = "JavaScript handler received TypeScript files (.ts/.tsx). " ~
                              "Please use language: typescript for this target. " ~
                              "Files: " ~ target.sources.filter!(s => s.endsWith(".ts") || s.endsWith(".tsx")).join(", ");
                return result;
            }
            
            // Detect JSX/React (only .jsx for JavaScript, not .tsx)
            bool hasJSX = target.sources.any!(s => s.endsWith(".jsx"));
            if (hasJSX && !jsConfig.jsx)
            {
                Logger.debugLog("Detected JSX sources, enabling JSX support");
                jsConfig.jsx = true;
            }
            
            final switch (target.type)
            {
                case TargetType.Executable:
                    result = buildExecutable(target, config, jsConfig);
                    break;
                case TargetType.Library:
                    result = buildLibrary(target, config, jsConfig);
                    break;
                case TargetType.Test:
                    result = runTests(target, config, jsConfig);
                    break;
                case TargetType.Custom:
                    result = buildCustom(target, config, jsConfig);
                    break;
            }
            
            return result;
        }
        catch (Throwable e)
        {
            LanguageBuildResult result;
            result.success = false;
            result.error = "Internal error in JavaScript handler: " ~ e.msg;
            return result;
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        JSConfig jsConfig = parseJSConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            string ext = ".js";
            
            // Adjust extension based on format
            if (jsConfig.format == OutputFormat.ESM)
                ext = ".mjs";
            
            outputs ~= buildPath(config.options.outputDir, name ~ ext);
            
            if (jsConfig.sourcemap)
            {
                outputs ~= buildPath(config.options.outputDir, name ~ ext ~ ".map");
            }
        }
        
        return outputs;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, JSConfig jsConfig)
    {
        LanguageBuildResult result;
        
        // Check for empty sources
        if (target.sources.length == 0)
        {
            result.success = false;
            result.error = "No source files specified for target"; // Removed concatenation
            return result;
        }
        
        // Auto-detect mode if not specified
        if (jsConfig.mode == JSBuildMode.Node && jsConfig.bundler == BundlerType.Auto)
        {
            // Check if package.json exists to determine if bundling is needed
            string packageJsonPath = buildPath(dirName(target.sources[0]), "package.json");
            if (exists(packageJsonPath))
            {
                jsConfig.mode = detectModeFromPackageJson(packageJsonPath);
            }
        }
        
        // For Node.js scripts without bundling, just validate
        if (jsConfig.mode == JSBuildMode.Node && jsConfig.bundler == BundlerType.None)
        {
            return validateOnly(target, config);
        }
        
        // Use bundler
        return bundleTarget(target, config, jsConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, JSConfig jsConfig)
    {
        LanguageBuildResult result;
        
        // Check for empty sources
        if (target.sources.length == 0)
        {
            result.success = false;
            result.error = "No source files specified for target " ~ target.name;
            return result;
        }
        
        // Libraries should use library mode (but respect explicit "none" bundler)
        if (jsConfig.mode == JSBuildMode.Node)
        {
            jsConfig.mode = JSBuildMode.Library;
        }
        
        // If bundler is "none", just validate and copy sources
        if (jsConfig.bundler == BundlerType.None)
        {
            return validateOnly(target, config);
        }
        
        // Let BundlerFactory.createAuto() handle bundler selection for Auto
        // It has proper fallback logic for when preferred bundlers aren't available
        return bundleTarget(target, config, jsConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, JSConfig jsConfig)
    {
        LanguageBuildResult result;
        
        // Check for empty sources
        if (target.sources.length == 0)
        {
            result.success = false;
            result.error = "No source files specified for target " ~ target.name;
            return result;
        }
        
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
            // Try common test runners
            if (isCommandAvailable("jest"))
                cmd = ["jest"];
            else if (isCommandAvailable("mocha"))
                cmd = ["mocha"];
            else if (isCommandAvailable("vitest"))
                cmd = ["vitest", "run"];
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
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, JSConfig jsConfig)
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Bundle target using configured bundler with action-level caching
    private LanguageBuildResult bundleTarget(in Target target, in WorkspaceConfig config, JSConfig jsConfig)
    {
        LanguageBuildResult result;
        
        // Install dependencies first if requested (before checking bundler availability)
        if (jsConfig.installDeps)
        {
            languages.web.shared_.utils.installDependencies(target.sources, jsConfig.packageManager);
        }
        
        // Create bundler
        auto bundler = BundlerFactory.create(jsConfig.bundler, jsConfig);
        
        if (!bundler.isAvailable())
        {
            result.error = "Bundler '" ~ bundler.name() ~ "' is not available. " ~
                          "Please install it or set bundler to 'auto' for fallback.";
            return result;
        }
        
        Logger.debugLog("Using bundler: " ~ bundler.name() ~ " (" ~ bundler.getVersion() ~ ")");
        
        // Prepare inputs: sources + config files
        string[] inputFiles = target.sources.dup;
        
        // Add config files if they exist
        if (!target.sources.empty)
        {
            string baseDir = dirName(target.sources[0]);
            
            string[] configFiles = [
                buildPath(baseDir, "package.json"),
                buildPath(baseDir, "package-lock.json"),
                buildPath(baseDir, "yarn.lock"),
                buildPath(baseDir, "pnpm-lock.yaml"),
                buildPath(baseDir, "tsconfig.json"),
                buildPath(baseDir, "jsconfig.json"),
                buildPath(baseDir, "webpack.config.js"),
                buildPath(baseDir, "rollup.config.js"),
                buildPath(baseDir, "vite.config.js"),
                buildPath(baseDir, "esbuild.config.js"),
                buildPath(baseDir, ".babelrc"),
                buildPath(baseDir, ".babelrc.json"),
                buildPath(baseDir, "babel.config.js")
            ];
            
            foreach (cf; configFiles)
            {
                if (exists(cf))
                    inputFiles ~= cf;
            }
        }
        
        // Add custom config file if specified
        if (!jsConfig.configFile.empty && exists(jsConfig.configFile))
        {
            inputFiles ~= jsConfig.configFile;
        }
        
        // Determine expected outputs
        string[] expectedOutputs = getOutputs(target, config);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["bundler"] = bundler.name();
        metadata["bundlerVersion"] = bundler.getVersion();
        metadata["bundlerType"] = jsConfig.bundler.to!string;
        metadata["mode"] = jsConfig.mode.to!string;
        metadata["platform"] = jsConfig.platform.to!string;
        metadata["format"] = jsConfig.format.to!string;
        metadata["minify"] = jsConfig.minify.to!string;
        metadata["sourcemap"] = jsConfig.sourcemap.to!string;
        metadata["target"] = jsConfig.target;
        metadata["jsx"] = jsConfig.jsx.to!string;
        metadata["jsxFactory"] = jsConfig.jsxFactory;
        
        if (!jsConfig.entry.empty)
            metadata["entry"] = jsConfig.entry;
        if (!jsConfig.external.empty)
            metadata["external"] = jsConfig.external.join(",");
        if (!jsConfig.packageManager.empty)
            metadata["packageManager"] = jsConfig.packageManager;
        
        // Create action ID for bundling
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;  // Bundling is a packaging operation
        actionId.subId = "bundle";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if bundling is cached
        if (actionCache.isCached(actionId, inputFiles, metadata))
        {
            bool allOutputsExist = expectedOutputs.all!(o => exists(o));
            if (allOutputsExist)
            {
                Logger.debugLog("  [Cached] JavaScript bundle: " ~ target.name);
                result.success = true;
                result.outputs = expectedOutputs;
                result.outputHash = FastHash.hashStrings(expectedOutputs);
                return result;
            }
        }
        
        // Bundle
        auto bundleResult = bundler.bundle(target.sources, jsConfig, target, config);
        
        bool success = bundleResult.success;
        
        // Update cache with result
        actionCache.update(
            actionId,
            inputFiles,
            bundleResult.outputs,
            metadata,
            success
        );
        
        if (!success)
        {
            result.error = bundleResult.error;
            return result;
        }
        
        result.success = true;
        result.outputs = bundleResult.outputs;
        result.outputHash = bundleResult.outputHash;
        
        return result;
    }
    
    /// Validate JavaScript syntax without bundling
    private LanguageBuildResult validateOnly(in Target target, in WorkspaceConfig config)
    {
        LanguageBuildResult result;
        
        foreach (source; target.sources)
        {
            // JavaScript handler should only validate .js/.jsx files
            // TypeScript files should be handled by TypeScript handler
            if (source.endsWith(".ts") || source.endsWith(".tsx") || source.endsWith(".mts") || source.endsWith(".cts"))
            {
                result.error = "JavaScript handler cannot validate TypeScript files. " ~
                              "Use language: typescript for file: " ~ source;
                return result;
            }
            
            // Validate JavaScript with Node.js
            auto cmd = ["node", "--check", source];
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.error = "JavaScript validation failed in " ~ source ~ ": " ~ res.output;
                return result;
            }
        }
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    /// Parse JavaScript configuration from target
    private JSConfig parseJSConfig(in Target target)
    {
        JSConfig config;
        
        // Try language-specific keys (javascript, jsConfig for backward compat)
        string configKey = "";
        if ("javascript" in target.langConfig)
            configKey = "javascript";
        else if ("jsConfig" in target.langConfig)
            configKey = "jsConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = JSConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                Logger.warning("Failed to parse JavaScript config, using defaults: " ~ e.msg);
            }
        }
        
        // Auto-detect entry point if not specified
        if (config.entry.empty && !target.sources.empty)
        {
            config.entry = target.sources[0];
        }
        
        return config;
    }
    
    /// Detect build mode from package.json
    private JSBuildMode detectModeFromPackageJson(string packageJsonPath)
    {
        try
        {
            auto content = readText(packageJsonPath);
            auto json = parseJSON(content);
            
            // Check for browser field
            if ("browser" in json)
                return JSBuildMode.Bundle;
            
            // Check for module field (ESM library)
            if ("module" in json)
                return JSBuildMode.Library;
            
            // Check for dependencies that suggest bundling
            if ("dependencies" in json)
            {
                auto deps = json["dependencies"].object;
                if ("react" in deps || "vue" in deps || "svelte" in deps)
                    return JSBuildMode.Bundle;
            }
        }
        catch (Exception e)
        {
            Logger.warning("Failed to parse package.json: " ~ e.msg);
        }
        
        return JSBuildMode.Node;
    }
    
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.JavaScript);
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
