module languages.web.javascript.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv : to;
import std.string : toLower;
import languages.base;
import languages.web.base;
import languages.web.javascript.bundlers;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process.checker : isCommandAvailable;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// JavaScript build handler - leverages BaseWebHandler for common functionality
class JavaScriptHandler : BaseWebHandler
{
    private JSBuildMode jsMode = JSBuildMode.Node;
    private BundlerType bundlerType = BundlerType.Auto;
    
    override protected string languageId() const pure nothrow => "javascript";
    override protected TargetLanguage languageEnum() const pure nothrow => TargetLanguage.JavaScript;
    override protected string[] configKeys() const pure nothrow => ["javascript", "jsConfig"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "Node.js not found. Install from: https://nodejs.org/";
    
    override protected string validateSources(const(string[]) sources, WebConfig config) const
    {
        if (sources.any!(s => s.endsWith(".ts") || s.endsWith(".tsx") || s.endsWith(".mts") || s.endsWith(".cts")))
            return "JavaScript handler received TypeScript files. Use language: typescript instead.";
        return "";
    }
    
    override protected string detectToolkit(WebConfig config) => isCommandAvailable("node") ? "node" : "";
    
    override protected LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath)
    {
        if (target.sources.empty)
        {
            LanguageBuildResult result;
            result.error = "No source files specified for target";
            return result;
        }
        
        if (jsMode == JSBuildMode.Node && bundlerType == BundlerType.Auto)
        {
            string pkg = buildPath(dirName(target.sources[0]), "package.json");
            if (exists(pkg)) jsMode = detectModeFromPackageJson(pkg);
        }
        
        if (jsMode == JSBuildMode.Node && bundlerType == BundlerType.None)
            return validateOnly(target, config);
        
        return bundleTarget(target, config, webConfig);
    }
    
    override protected LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath)
    {
        if (target.sources.empty)
        {
            LanguageBuildResult result;
            result.error = "No source files specified for target";
            return result;
        }
        
        if (jsMode == JSBuildMode.Node) jsMode = JSBuildMode.Library;
        return bundlerType == BundlerType.None ? validateOnly(target, config) : bundleTarget(target, config, webConfig);
    }
    
    override protected string getOutputName(string name, WebConfig config) const pure nothrow
        => config.format == WebModuleFormat.ESM ? name ~ ".mjs" : name ~ ".js";
    
    /// Run JavaScript tests
    override protected LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            result.error = "No source files specified for test target";
            return result;
        }
        
        // Install dependencies if needed
        if (webConfig.installDeps)
            installDependencies(target.sources, webConfig.packageManager);
        
        string[] cmd;
        
        // Try to detect test framework from package.json
        string packageJsonPath = findPackageJson(target.sources);
        if (!packageJsonPath.empty && exists(packageJsonPath))
        {
            auto testCmd = detectTestCommand(packageJsonPath);
            if (!testCmd.empty) cmd = testCmd;
        }
        
        // Fallback test runners
        if (cmd.empty)
        {
            if (isCommandAvailable("vitest")) cmd = ["vitest", "run"];
            else if (isCommandAvailable("jest")) cmd = ["jest"];
            else if (isCommandAvailable("mocha")) cmd = ["mocha"];
            else if (isCommandAvailable("npx")) cmd = ["npx", "vitest", "run"];
            else if (isCommandAvailable("node")) cmd = ["node", "--test"];  // Node.js built-in test runner
        }
        
        if (cmd.empty)
        {
            result.error = "No test runner found. Install vitest, jest, or mocha.";
            return result;
        }
        
        structuredLog.info("running_tests_with_").field("detail", cmd[0]).emit();
        
        auto testResult = execute(cmd);
        
        if (testResult.status != 0)
        {
            result.error = "Tests failed:\n" ~ testResult.output;
            return result;
        }
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        structuredLog.info("tests_passed").emit();
        return result;
    }
    
    override protected void parseLanguageSpecificConfig(ref WebConfig config, JSONValue json)
    {
        if (auto v = "mode" in json)
        {
            string s = (*v).str.toLower;
            jsMode = s == "bundle" ? JSBuildMode.Bundle : s == "library" ? JSBuildMode.Library : JSBuildMode.Node;
        }
        
        if (auto v = "bundler" in json)
        {
            string s = (*v).str.toLower;
            bundlerType = s == "esbuild" ? BundlerType.ESBuild :
                         s == "webpack" ? BundlerType.Webpack :
                         s == "rollup" ? BundlerType.Rollup :
                         s == "vite" ? BundlerType.Vite :
                         s == "none" ? BundlerType.None : BundlerType.Auto;
        }
    }
    
    private LanguageBuildResult bundleTarget(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
        auto bundler = BundlerFactory.create(bundlerType, toJSConfig(webConfig));
        if (!bundler.isAvailable())
        {
            result.error = "Bundler '" ~ bundler.name() ~ "' not available. Install it or set bundler to 'auto'.";
            return result;
        }
        
        structuredLog.debug_("using_bundler").field("detail", bundler.name() ~ " (" ~ bundler.getVersion() ~ ")").emit();
        
        string[] inputFiles = collectInputFiles(target.sources, webConfig);
        addBundlerConfigs(inputFiles, target.sources);
        
        string[] expectedOutputs = getOutputs(target, config);
        string[string] metadata = buildCacheMetadata(webConfig, bundler.name());
        metadata["bundler"] = bundler.name();
        metadata["bundlerVersion"] = bundler.getVersion();
        
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = "bundle";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        if (getCache().isCached(actionId, inputFiles, metadata) && expectedOutputs.all!(o => exists(o)))
        {
            structuredLog.debug_("cached_js_bundle").field("detail", "[Cached] " ~ target.name).emit();
            result.success = true;
            result.outputs = expectedOutputs;
            result.outputHash = FastHash.hashStrings(expectedOutputs);
            return result;
        }
        
        auto bundleResult = bundler.bundle(target.sources, toJSConfig(webConfig), target, config);
        getCache().update(actionId, inputFiles, bundleResult.outputs, metadata, bundleResult.success);
        
        if (!bundleResult.success)
        {
            result.error = bundleResult.error;
            return result;
        }
        
        result.success = true;
        result.outputs = bundleResult.outputs;
        result.outputHash = bundleResult.outputHash;
        return result;
    }
    
    private LanguageBuildResult validateOnly(in Target target, in WorkspaceConfig config)
    {
        LanguageBuildResult result;
        foreach (source; target.sources)
        {
            if (source.endsWith(".ts") || source.endsWith(".tsx"))
            {
                result.error = "JavaScript handler cannot validate TypeScript. Use language: typescript";
                return result;
            }
            auto res = execute(["node", "--check", source]);
            if (res.status != 0)
            {
                result.error = "Validation failed in " ~ source ~ ": " ~ res.output;
                return result;
            }
        }
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private JSBuildMode detectModeFromPackageJson(string path)
    {
        try
        {
            auto json = parseJSON(readText(path));
            if ("browser" in json) return JSBuildMode.Bundle;
            if ("module" in json) return JSBuildMode.Library;
            if ("dependencies" in json)
            {
                auto deps = json["dependencies"].object;
                if ("react" in deps || "vue" in deps || "svelte" in deps)
                    return JSBuildMode.Bundle;
            }
        }
        catch (Exception) {}
        return JSBuildMode.Node;
    }
    
    private void addBundlerConfigs(ref string[] inputs, const(string[]) sources)
    {
        if (sources.empty) return;
        string baseDir = dirName(sources[0]);
        foreach (cf; ["webpack.config.js", "rollup.config.js", "vite.config.js", "esbuild.config.js", ".babelrc", ".babelrc.json", "babel.config.js"])
            if (exists(buildPath(baseDir, cf))) inputs ~= buildPath(baseDir, cf);
    }
    
    private JSConfig toJSConfig(WebConfig config)
    {
        JSConfig c;
        c.entry = config.entry;
        c.minify = config.minify;
        c.sourcemap = config.sourcemap;
        c.target = config.target;
        c.jsx = config.jsx;
        c.jsxFactory = config.jsxFactory;
        c.external = config.external;
        c.mode = jsMode;
        c.bundler = bundlerType;
        c.format = config.format == WebModuleFormat.ESM ? OutputFormat.ESM : OutputFormat.CommonJS;
        c.platform = config.platform == WebPlatform.Browser ? Platform.Browser : Platform.Node;
        c.packageManager = pmToString(config.packageManager);
        c.installDeps = config.installDeps;
        c.configFile = config.configFile;
        return c;
    }
    
    private string pmToString(PackageManager pm)
    {
        final switch (pm)
        {
            case PackageManager.NPM: return "npm";
            case PackageManager.Yarn: return "yarn";
            case PackageManager.PNPM: return "pnpm";
            case PackageManager.Bun: return "bun";
            case PackageManager.Auto: return "npm";
        }
    }
}
