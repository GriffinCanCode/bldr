module languages.web.base;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.json;
import languages.base.base;
import languages.base.mixins;
import languages.base.types;
import languages.base.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process.checker : isCommandAvailable;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

// ============================================================================
// Web Language Enums (shared across TypeScript, JavaScript, CSS, Elm)
// ============================================================================

/// Output module format
enum WebModuleFormat
{
    CommonJS,   // CommonJS (require/exports)
    ESM,        // ES Modules (import/export)
    UMD,        // Universal Module Definition
    IIFE,       // Immediately Invoked Function Expression
    AMD,        // Asynchronous Module Definition
    System,     // SystemJS
}

/// Target platform
enum WebPlatform
{
    Browser,    // Browser environment
    Node,       // Node.js environment
    Neutral,    // Platform agnostic
    Deno,       // Deno runtime
    Bun,        // Bun runtime
}

/// Package manager
enum PackageManager
{
    NPM,
    Yarn,
    PNPM,
    Bun,
    Auto,       // Auto-detect from lockfile
}

/// Web build mode
enum WebBuildMode
{
    Development,
    Production,
    Watch,
    Check,      // Type check / lint only
}

// ============================================================================
// Web Config Structure
// ============================================================================

/// Web-specific configuration (shared across JS/TS/CSS/Elm)
struct WebConfig
{
    BaseConfig base;
    
    // Build settings
    WebBuildMode mode = WebBuildMode.Development;
    WebPlatform platform = WebPlatform.Node;
    WebModuleFormat format = WebModuleFormat.CommonJS;
    
    // Entry/output
    string entry;
    string outDir;
    string output;
    
    // Code generation
    bool minify = false;
    bool sourcemap = false;
    bool declaration = false;      // .d.ts for TS, nothing for others
    bool declarationMap = false;
    
    // Dependencies
    PackageManager packageManager = PackageManager.Auto;
    bool installDeps = false;
    string[] external;             // Don't bundle these
    
    // Config files
    string configFile;             // tsconfig.json, etc.
    
    // Target ES version
    string target = "es2020";
    
    // JSX support
    bool jsx = false;
    string jsxFactory = "React.createElement";
    string jsxFragment = "React.Fragment";
}

/// Parse web config from JSON
string[] parseWebConfig(ref WebConfig config, JSONValue json)
{
    string[] parsed = parseBaseConfig(config.base, json);
    
    // Mode
    if (auto v = "mode" in json)
    {
        string s = (*v).str.toLower;
        config.mode = s == "production" ? WebBuildMode.Production :
                     s == "watch" ? WebBuildMode.Watch :
                     s == "check" ? WebBuildMode.Check : WebBuildMode.Development;
        parsed ~= "mode";
    }
    
    // Platform
    if (auto v = "platform" in json)
    {
        string s = (*v).str.toLower;
        config.platform = s == "browser" ? WebPlatform.Browser :
                         s == "node" ? WebPlatform.Node :
                         s == "deno" ? WebPlatform.Deno :
                         s == "bun" ? WebPlatform.Bun : WebPlatform.Neutral;
        parsed ~= "platform";
    }
    
    // Format
    if (auto v = "format" in json)
    {
        string s = (*v).str.toLower;
        config.format = s == "esm" ? WebModuleFormat.ESM :
                       s == "umd" ? WebModuleFormat.UMD :
                       s == "iife" ? WebModuleFormat.IIFE :
                       s == "amd" ? WebModuleFormat.AMD : WebModuleFormat.CommonJS;
        parsed ~= "format";
    }
    
    // Entry/output
    if (auto v = "entry" in json) { config.entry = (*v).str; parsed ~= "entry"; }
    if (auto v = "outDir" in json) { config.outDir = (*v).str; parsed ~= "outDir"; }
    else if (auto v = "out_dir" in json) { config.outDir = (*v).str; parsed ~= "outDir"; }
    if (auto v = "output" in json) { config.output = (*v).str; parsed ~= "output"; }
    
    // Code generation
    if (auto v = "minify" in json) { config.minify = (*v).type == JSONType.true_; parsed ~= "minify"; }
    if (auto v = "sourcemap" in json) { config.sourcemap = (*v).type == JSONType.true_; parsed ~= "sourcemap"; }
    else if (auto v = "sourceMap" in json) { config.sourcemap = (*v).type == JSONType.true_; parsed ~= "sourcemap"; }
    if (auto v = "declaration" in json) { config.declaration = (*v).type == JSONType.true_; parsed ~= "declaration"; }
    if (auto v = "declarationMap" in json) { config.declarationMap = (*v).type == JSONType.true_; parsed ~= "declarationMap"; }
    
    // Package manager
    if (auto v = "packageManager" in json)
    {
        string s = (*v).str.toLower;
        config.packageManager = s == "npm" ? PackageManager.NPM :
                               s == "yarn" ? PackageManager.Yarn :
                               s == "pnpm" ? PackageManager.PNPM :
                               s == "bun" ? PackageManager.Bun : PackageManager.Auto;
        parsed ~= "packageManager";
    }
    if (auto v = "installDeps" in json) { config.installDeps = (*v).type == JSONType.true_; parsed ~= "installDeps"; }
    
    // External
    if (auto v = "external" in json)
    {
        config.external = (*v).array.map!(e => e.str).array;
        parsed ~= "external";
    }
    
    // Config file
    if (auto v = "configFile" in json) { config.configFile = (*v).str; parsed ~= "configFile"; }
    else if (auto v = "config" in json) { config.configFile = (*v).str; parsed ~= "configFile"; }
    else if (auto v = "tsconfig" in json) { config.configFile = (*v).str; parsed ~= "configFile"; }
    
    // Target
    if (auto v = "target" in json) { config.target = (*v).str; parsed ~= "target"; }
    
    // JSX
    if (auto v = "jsx" in json) { config.jsx = (*v).type == JSONType.true_; parsed ~= "jsx"; }
    if (auto v = "jsxFactory" in json) { config.jsxFactory = (*v).str; parsed ~= "jsxFactory"; }
    if (auto v = "jsxFragment" in json) { config.jsxFragment = (*v).str; parsed ~= "jsxFragment"; }
    
    return parsed;
}

// ============================================================================
// Web Build Result
// ============================================================================

/// Result from web language compilation/bundling
struct WebBuildResult
{
    bool success;
    string error;
    string[] outputs;
    string[] declarations;
    string outputHash;
    bool hadWarnings;
    string[] warnings;
    string[] typeErrors;
}

// ============================================================================
// Base Web Handler
// ============================================================================

/// Base handler for web languages (TypeScript, JavaScript, CSS, Elm)
abstract class BaseWebHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"web";
    
    /// Build the target with full context
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_web_target_").field("detail", 
            "Building " ~ languageId() ~ " target: " ~ target.name).emit();
        
        // Validate sources
        if (target.sources.empty)
        {
            result.error = "No source files provided for " ~ languageId() ~ " target";
            return result;
        }
        
        // Parse configuration
        WebConfig webConfig = parseConfig(target);
        
        // Validate sources for this language
        auto validationError = validateSources(target.sources, webConfig);
        if (!validationError.empty)
        {
            result.error = validationError;
            return result;
        }
        
        // Detect toolkit/compiler
        auto toolPath = detectToolkit(webConfig);
        if (toolPath.empty)
        {
            result.error = toolkitNotFoundError();
            return result;
        }
        
        // Setup directories
        string outDir = webConfig.outDir.empty ? config.options.outputDir : webConfig.outDir;
        if (!exists(outDir)) mkdirRecurse(outDir);
        
        // Install dependencies if requested
        if (webConfig.installDeps)
            installDependencies(target.sources, webConfig.packageManager);
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, webConfig, toolPath);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, webConfig, toolPath);
                break;
            case TargetType.Test:
                result = runTests(target, config, webConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, webConfig, toolPath);
                break;
        }
        
        return result;
    }
    
    /// Get outputs for target
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        WebConfig webConfig = parseConfig(target);
        string outDir = webConfig.outDir.empty ? config.options.outputDir : webConfig.outDir;
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(outDir, target.outputPath);
        }
        else if (!webConfig.output.empty)
        {
            outputs ~= buildPath(outDir, webConfig.output);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(outDir, getOutputName(name, webConfig));
        }
        
        // Add sourcemap if enabled
        if (webConfig.sourcemap)
            outputs ~= outputs[0] ~ ".map";
        
        // Add declaration files for TypeScript libraries
        if (webConfig.declaration)
        {
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(outDir, name ~ ".d.ts");
            if (webConfig.declarationMap)
                outputs ~= buildPath(outDir, name ~ ".d.ts.map");
        }
        
        return outputs;
    }
    
    /// Analyze imports in source files
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(languageEnum());
        if (spec is null) return [];
        
        Import[] imports;
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source)) continue;
            try
            {
                auto content = readText(source);
                imports ~= spec.scanImports(source, content);
            }
            catch (Exception) {}
        }
        return imports;
    }
    
    // ========== Abstract methods to be implemented by subclasses ==========
    
    /// Language identifier
    protected abstract string languageId() const pure nothrow;
    
    /// Target language enum for spec lookup
    protected abstract TargetLanguage languageEnum() const pure nothrow;
    
    /// Config keys to try when parsing
    protected abstract string[] configKeys() const pure nothrow;
    
    /// Get error message when toolkit not found
    protected abstract string toolkitNotFoundError() const pure nothrow;
    
    /// Validate sources are appropriate for this handler
    protected abstract string validateSources(const(string[]) sources, WebConfig config) const;
    
    /// Detect toolkit path (node, tsc, elm, etc.)
    protected abstract string detectToolkit(WebConfig config);
    
    /// Build executable target
    protected abstract LanguageBuildResult buildExecutable(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    );
    
    /// Build library target
    protected abstract LanguageBuildResult buildLibrary(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    );
    
    /// Get output filename with appropriate extension
    protected abstract string getOutputName(string name, WebConfig config) const pure nothrow;
    
    // ========== Common implementation (overridable) ==========
    
    /// Run tests (default implementation)
    protected LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
        // Try to detect test framework from package.json
        string packageJsonPath = findPackageJson(target.sources);
        string[] cmd;
        
        if (!packageJsonPath.empty && exists(packageJsonPath))
        {
            cmd = detectTestCommand(packageJsonPath);
        }
        
        if (cmd.empty)
        {
            // Fallback to common test runners
            if (isCommandAvailable("vitest"))
                cmd = ["vitest", "run"];
            else if (isCommandAvailable("jest"))
                cmd = ["jest"];
            else
                cmd = getPackageManagerCmd(webConfig.packageManager) ~ ["test"];
        }
        
        structuredLog.debug_("running_tests_").field("detail", "Running tests: " ~ cmd.join(" ")).emit();
        
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
    
    /// Build custom target (default implementation)
    protected LanguageBuildResult buildCustom(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    )
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Parse language-specific config
    protected WebConfig parseConfig(in Target target)
    {
        WebConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    parseWebConfig(config, json);
                    parseLanguageSpecificConfig(config, json);
                    break;
                }
                catch (Exception e)
                {
                    structuredLog.warning("config_parse_failed_").field("detail", 
                        "Using defaults: " ~ e.msg).emit();
                }
            }
        }
        
        // Apply target flags
        if (!target.flags.empty) config.base.extraFlags ~= target.flags;
        if (!target.includes.empty) config.base.includeDirs ~= target.includes;
        
        // Auto-detect entry point
        if (config.entry.empty && !target.sources.empty)
            config.entry = target.sources[0];
        
        return config;
    }
    
    /// Parse language-specific config fields (override in subclasses)
    protected void parseLanguageSpecificConfig(ref WebConfig config, JSONValue json) {}
    
    // ========== Shared utilities ==========
    
    /// Find package.json in source tree
    protected string findPackageJson(const(string[]) sources)
    {
        if (sources.empty) return "";
        
        string dir = dirName(sources[0]);
        while (dir != "/" && dir.length > 1)
        {
            string path = buildPath(dir, "package.json");
            if (exists(path)) return path;
            dir = dirName(dir);
        }
        return "";
    }
    
    /// Detect test command from package.json
    protected string[] detectTestCommand(string packageJsonPath)
    {
        try
        {
            auto json = parseJSON(readText(packageJsonPath));
            if ("scripts" in json && "test" in json["scripts"].object)
            {
                string testScript = json["scripts"]["test"].str;
                if (testScript != "echo \"Error: no test specified\" && exit 1")
                    return ["npm", "test"];
            }
        }
        catch (Exception) {}
        return [];
    }
    
    /// Install dependencies
    protected void installDependencies(const(string[]) sources, PackageManager pm)
    {
        import std.file : getcwd;
        
        string packageJsonPath = buildPath(getcwd(), "package.json");
        if (!exists(packageJsonPath))
            packageJsonPath = findPackageJson(sources);
        
        if (packageJsonPath.empty || !exists(packageJsonPath))
        {
            structuredLog.warning("no_packagejson_found_skipping_dependency").emit();
            return;
        }
        
        string packageDir = dirName(packageJsonPath);
        string nodeModulesPath = buildPath(packageDir, "node_modules");
        
        if (exists(nodeModulesPath) && isDir(nodeModulesPath))
        {
            structuredLog.debug_("dependencies_already_installed_skipping").emit();
            return;
        }
        
        auto cmd = getPackageManagerCmd(pm) ~ ["install"];
        structuredLog.info("installing_dependencies_with_").field("detail", 
            "Installing dependencies with " ~ cmd[0] ~ "...").emit();
        
        auto res = execute(cmd, packageDir);
        
        if (res.status != 0)
            structuredLog.warning("failed_to_install_dependencies_").field("detail", res.output).emit();
        else
            structuredLog.info("dependencies_installed_successfully").emit();
    }
    
    /// Get package manager command
    protected string[] getPackageManagerCmd(PackageManager pm)
    {
        if (pm == PackageManager.Auto)
            pm = detectPackageManager();
        
        final switch (pm)
        {
            case PackageManager.NPM: return ["npm"];
            case PackageManager.Yarn: return ["yarn"];
            case PackageManager.PNPM: return ["pnpm"];
            case PackageManager.Bun: return ["bun"];
            case PackageManager.Auto: return ["npm"];
        }
    }
    
    /// Detect package manager from lockfiles
    protected PackageManager detectPackageManager()
    {
        if (exists("bun.lockb") || exists("bun.lock")) return PackageManager.Bun;
        if (exists("pnpm-lock.yaml")) return PackageManager.PNPM;
        if (exists("yarn.lock")) return PackageManager.Yarn;
        return PackageManager.NPM;
    }
    
    /// Collect input files for caching (sources + config files)
    protected string[] collectInputFiles(const(string[]) sources, WebConfig config)
    {
        string[] inputs = sources.dup;
        
        if (!sources.empty)
        {
            string baseDir = dirName(sources[0]);
            string[] configFiles = [
                buildPath(baseDir, "package.json"),
                buildPath(baseDir, "package-lock.json"),
                buildPath(baseDir, "yarn.lock"),
                buildPath(baseDir, "pnpm-lock.yaml"),
                buildPath(baseDir, "tsconfig.json"),
                buildPath(baseDir, "jsconfig.json"),
            ];
            foreach (cf; configFiles)
                if (exists(cf)) inputs ~= cf;
        }
        
        if (!config.configFile.empty && exists(config.configFile))
            inputs ~= config.configFile;
        
        return inputs;
    }
    
    /// Build cache metadata
    protected string[string] buildCacheMetadata(WebConfig config, string toolPath)
    {
        string[string] metadata;
        metadata["language"] = languageId();
        metadata["mode"] = config.mode.to!string;
        metadata["platform"] = config.platform.to!string;
        metadata["format"] = config.format.to!string;
        metadata["minify"] = config.minify.to!string;
        metadata["sourcemap"] = config.sourcemap.to!string;
        metadata["target"] = config.target;
        if (!config.entry.empty) metadata["entry"] = config.entry;
        if (!config.external.empty) metadata["external"] = config.external.join(",");
        return metadata;
    }
}

