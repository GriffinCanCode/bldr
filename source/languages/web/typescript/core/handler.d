module languages.web.typescript.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import languages.base;
import languages.web.base;
import languages.web.typescript.tooling.checker;
import languages.web.typescript.tooling.bundlers;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process.checker : isCommandAvailable;
import engine.caching.actions.action;

// ============================================================================
// TypeScript-specific enums
// ============================================================================

/// TypeScript build modes
enum TSBuildMode { Check, Compile, Bundle, Library }

/// TypeScript compiler selection
enum TSCompiler { Auto, TSC, SWC, ESBuild, Webpack, Rollup, Vite, None }

/// JSX compilation mode
enum TSXMode { Preserve, React, ReactJSX, ReactJSXDev, ReactNative }

/// Target ECMAScript version
enum TSTarget { ES3, ES5, ES6, ES2015, ES2016, ES2017, ES2018, ES2019, ES2020, ES2021, ES2022, ES2023, ESNext }

/// Module resolution strategy
enum TSModuleResolution { Classic, Node, Node16, NodeNext, Bundler }

// ============================================================================
// TypeScript Config Extension
// ============================================================================

/// TypeScript-specific configuration (extends WebConfig)
struct TSConfig
{
    // Base web config fields are parsed via parseWebConfig
    TSBuildMode tsMode = TSBuildMode.Compile;
    TSCompiler compiler = TSCompiler.Auto;
    TSTarget tsTarget = TSTarget.ES2020;
    TSModuleResolution moduleResolution = TSModuleResolution.Node;
    TSXMode jsx = TSXMode.React;
    
    // TypeScript-specific flags
    bool strict = true;
    bool allowJs = false;
    bool checkJs = false;
    bool esModuleInterop = true;
    bool skipLibCheck = true;
    bool isolatedModules = false;
    bool experimentalDecorators = false;
    bool emitDecoratorMetadata = false;
    
    // Paths
    string tsconfig;
    string rootDir;
    string[] typeRoots;
    string[] types;
    string baseUrl;
    string[string] paths;
}

// ============================================================================
// TypeScript Handler
// ============================================================================

/// TypeScript build handler - leverages BaseWebHandler for common functionality
class TypeScriptHandler : BaseWebHandler
{
    private TSConfig tsConfig;
    
    override protected string languageId() const pure nothrow => "typescript";
    override protected TargetLanguage languageEnum() const pure nothrow => TargetLanguage.TypeScript;
    override protected string[] configKeys() const pure nothrow => ["typescript", "tsConfig"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "TypeScript compiler not found. Install via: npm install -g typescript";
    
    /// Validate sources - TypeScript handler should process .ts/.tsx files
    override protected string validateSources(const(string[]) sources, WebConfig config) const
    {
        bool hasPlainJS = sources.any!(s => 
            (s.endsWith(".js") || s.endsWith(".jsx") || s.endsWith(".mjs") || s.endsWith(".cjs")) &&
            !s.endsWith(".d.ts"));
        
        if (hasPlainJS && !tsConfig.allowJs)
            return "TypeScript handler received JavaScript files but allowJs not enabled. " ~
                   "Use language: javascript or enable allowJs.";
        return "";
    }
    
    /// Detect tsc/node from PATH
    override protected string detectToolkit(WebConfig config)
    {
        // TSC via npx or global
        if (isCommandAvailable("tsc")) return "tsc";
        if (isCommandAvailable("npx")) return "npx";
        // Node.js for running transpiled output
        if (isCommandAvailable("node")) return "node";
        return "";
    }
    
    /// Build executable TypeScript target
    override protected LanguageBuildResult buildExecutable(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    )
    {
        // Type check only mode
        if (tsConfig.tsMode == TSBuildMode.Check)
            return typeCheckOnly(target, config);
        
        // Install dependencies if requested
        if (webConfig.installDeps)
            installDependencies(target.sources, webConfig.packageManager);
        
        // Detect TSX sources
        if (target.sources.any!(s => s.endsWith(".tsx")) && tsConfig.jsx == TSXMode.React)
            structuredLog.debug_("detected_tsx_sources").emit();
        
        return compileTarget(target, config, webConfig);
    }
    
    /// Run TypeScript tests
    override protected LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
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
        }
        
        if (cmd.empty)
        {
            result.error = "No test runner found. Install vitest, jest, or mocha.";
            return result;
        }
        
        structuredLog.info("running_tests_with_").field("detail", cmd[0]).emit();
        
        import infrastructure.utils.security : execute;
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
    
    /// Build TypeScript library
    override protected LanguageBuildResult buildLibrary(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    )
    {
        // Libraries should generate declarations
        if (!webConfig.declaration)
        {
            structuredLog.warning("library_target_should_generate_declarati").emit();
            webConfig.declaration = true;
        }
        
        // Prefer tsc for libraries (best declaration generation)
        if (tsConfig.compiler == TSCompiler.Auto)
            tsConfig.compiler = TSCompiler.TSC;
        
        tsConfig.tsMode = TSBuildMode.Library;
        return compileTarget(target, config, webConfig);
    }
    
    /// Get output filename
    override protected string getOutputName(string name, WebConfig config) const pure nothrow
    {
        return config.format == WebModuleFormat.ESM ? name ~ ".mjs" : name ~ ".js";
    }
    
    /// Parse TypeScript-specific config
    override protected void parseLanguageSpecificConfig(ref WebConfig config, JSONValue json)
    {
        // Mode
        if (auto v = "mode" in json)
        {
            string s = (*v).str.toLower;
            tsConfig.tsMode = s == "check" ? TSBuildMode.Check :
                             s == "bundle" ? TSBuildMode.Bundle :
                             s == "library" ? TSBuildMode.Library : TSBuildMode.Compile;
        }
        
        // Compiler
        if (auto v = "compiler" in json)
        {
            string s = (*v).str.toLower;
            tsConfig.compiler = s == "tsc" ? TSCompiler.TSC :
                               s == "swc" ? TSCompiler.SWC :
                               s == "esbuild" ? TSCompiler.ESBuild :
                               s == "webpack" ? TSCompiler.Webpack :
                               s == "rollup" ? TSCompiler.Rollup :
                               s == "vite" ? TSCompiler.Vite :
                               s == "none" ? TSCompiler.None : TSCompiler.Auto;
        }
        
        // Target
        if (auto v = "target" in json)
        {
            string s = (*v).str.toLower;
            if (s == "es5") tsConfig.tsTarget = TSTarget.ES5;
            else if (s == "es6" || s == "es2015") tsConfig.tsTarget = TSTarget.ES2015;
            else if (s == "es2020") tsConfig.tsTarget = TSTarget.ES2020;
            else if (s == "esnext") tsConfig.tsTarget = TSTarget.ESNext;
        }
        
        // Boolean flags
        if (auto v = "strict" in json) tsConfig.strict = (*v).type == JSONType.true_;
        if (auto v = "allowJs" in json) tsConfig.allowJs = (*v).type == JSONType.true_;
        if (auto v = "checkJs" in json) tsConfig.checkJs = (*v).type == JSONType.true_;
        if (auto v = "esModuleInterop" in json) tsConfig.esModuleInterop = (*v).type == JSONType.true_;
        if (auto v = "skipLibCheck" in json) tsConfig.skipLibCheck = (*v).type == JSONType.true_;
        if (auto v = "isolatedModules" in json) tsConfig.isolatedModules = (*v).type == JSONType.true_;
        if (auto v = "experimentalDecorators" in json) tsConfig.experimentalDecorators = (*v).type == JSONType.true_;
        if (auto v = "emitDecoratorMetadata" in json) tsConfig.emitDecoratorMetadata = (*v).type == JSONType.true_;
        
        // Paths
        if (auto v = "tsconfig" in json) tsConfig.tsconfig = (*v).str;
        if (auto v = "rootDir" in json) tsConfig.rootDir = (*v).str;
        if (auto v = "baseUrl" in json) tsConfig.baseUrl = (*v).str;
        
        // Arrays
        if (auto v = "typeRoots" in json)
            tsConfig.typeRoots = (*v).array.map!(e => e.str).array;
        if (auto v = "types" in json)
            tsConfig.types = (*v).array.map!(e => e.str).array;
        
        // JSX mode
        if (auto v = "jsx" in json)
        {
            string s = (*v).str.toLower;
            tsConfig.jsx = s == "preserve" ? TSXMode.Preserve :
                          s == "react-jsx" ? TSXMode.ReactJSX :
                          s == "react-jsxdev" ? TSXMode.ReactJSXDev :
                          s == "react-native" ? TSXMode.ReactNative : TSXMode.React;
        }
        
        // Try to load from tsconfig.json
        if (tsConfig.tsconfig.empty)
            tsConfig.tsconfig = findTSConfig(config.entry);
    }
    
    // ========== Private helpers ==========
    
    /// Compile TypeScript target using configured compiler
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
        // Collect inputs for caching
        string[] inputFiles = collectInputFiles(target.sources, webConfig);
        if (!tsConfig.tsconfig.empty && exists(tsConfig.tsconfig))
            inputFiles ~= tsConfig.tsconfig;
        
        // Create bundler/compiler
        auto bundler = TSBundlerFactory.create(tsConfig.compiler, toLegacyConfig(webConfig), getCache());
        
        if (!bundler.isAvailable())
        {
            result.error = "TypeScript compiler '" ~ bundler.name() ~ "' not available. " ~
                          "Install it or set compiler to 'auto'.";
            return result;
        }
        
        structuredLog.debug_("using_typescript_compiler_").field("detail", 
            "Using: " ~ bundler.name() ~ " (" ~ bundler.getVersion() ~ ")").emit();
        
        // Compile
        auto compileResult = bundler.compile(target.sources, toLegacyConfig(webConfig), target, config);
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report type errors even if compilation succeeded
        if (compileResult.hadTypeErrors)
            foreach (err; compileResult.typeErrors)
                structuredLog.warning("type_error_").field("detail", err).emit();
        
        result.success = true;
        result.outputs = compileResult.outputs.dup;
        if (compileResult.declarations.length > 0)
            result.outputs ~= compileResult.declarations;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    /// Type check without emitting
    private LanguageBuildResult typeCheckOnly(in Target target, in WorkspaceConfig config)
    {
        LanguageBuildResult result;
        
        auto checkResult = TypeChecker.check(target.sources, toLegacyConfig(WebConfig.init), config.root);
        
        if (!checkResult.success)
        {
            result.error = "Type check failed:\n" ~ checkResult.errors.join("\n");
            return result;
        }
        
        if (checkResult.hasWarnings)
        {
            structuredLog.warning("type_check_warnings").emit();
            foreach (warn; checkResult.warnings)
                structuredLog.warning("__").field("detail", "  " ~ warn).emit();
        }
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Find tsconfig.json in source tree
    private string findTSConfig(string entry)
    {
        if (entry.empty) return "";
        
        string dir = dirName(entry);
        while (dir != "/" && dir.length > 1)
        {
            string path = buildPath(dir, "tsconfig.json");
            if (exists(path)) return path;
            dir = dirName(dir);
        }
        return "";
    }
    
    /// Convert to legacy TSConfig for existing bundler interface
    private auto toLegacyConfig(WebConfig config)
    {
        import languages.web.typescript.tooling.bundlers : TSConfig = TSConfig;
        TSConfig legacy;
        legacy.entry = config.entry;
        legacy.outDir = config.outDir;
        legacy.sourceMap = config.sourcemap;
        legacy.declaration = config.declaration;
        legacy.declarationMap = config.declarationMap;
        legacy.minify = config.minify;
        legacy.strict = tsConfig.strict;
        legacy.compiler = cast(typeof(legacy.compiler)) tsConfig.compiler;
        legacy.mode = cast(typeof(legacy.mode)) tsConfig.tsMode;
        legacy.target = cast(typeof(legacy.target)) tsConfig.tsTarget;
        legacy.jsx = cast(typeof(legacy.jsx)) tsConfig.jsx;
        legacy.tsconfig = tsConfig.tsconfig;
        legacy.allowJs = tsConfig.allowJs;
        legacy.esModuleInterop = tsConfig.esModuleInterop;
        legacy.skipLibCheck = tsConfig.skipLibCheck;
        legacy.experimentalDecorators = tsConfig.experimentalDecorators;
        return legacy;
    }
}

/// TypeScript compilation result (for bundler interface compatibility)
struct TSCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string[] declarations;
    string outputHash;
    bool hadTypeErrors;
    string[] typeErrors;
}
