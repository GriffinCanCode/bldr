module languages.scripting.base;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import languages.base.base;
import languages.base.mixins;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType, NullActionCache;

/// Result type for pre/post build steps
struct ScriptingStepResult
{
    bool success = true;
    string error;
    string[] warnings;
    
    static ScriptingStepResult ok() => ScriptingStepResult(true, "", []);
    static ScriptingStepResult fail(string err) => ScriptingStepResult(false, err, []);
    static ScriptingStepResult warn(string[] warns) => ScriptingStepResult(true, "", warns);
    
    bool hasWarnings() const pure nothrow => !warnings.empty;
}

/// Result for environment setup
struct EnvironmentSetupResult
{
    bool success = true;
    string error;
    string interpreterCommand;  // The resolved interpreter path (e.g., "python3", "/usr/bin/ruby")
    string[string] envVars;     // Additional environment variables to set
    
    static EnvironmentSetupResult ok(string cmd) => EnvironmentSetupResult(true, "", cmd, null);
    static EnvironmentSetupResult fail(string err) => EnvironmentSetupResult(false, err, "", null);
}

/// Result for syntax validation
struct SyntaxValidationResult
{
    bool success = true;
    string[] errors;
    string[] warnings;
    
    static SyntaxValidationResult ok() => SyntaxValidationResult(true, [], []);
    static SyntaxValidationResult fail(string[] errs) => SyntaxValidationResult(false, errs, []);
    
    string firstError() const pure nothrow => errors.empty ? "" : errors[0];
    bool hasErrors() const pure nothrow => !errors.empty;
    bool hasWarnings() const pure nothrow => !warnings.empty;
}

/// Result for formatting
struct FormatStepResult
{
    bool success = true;
    string error;
    string[] filesModified;
    bool hasChanges;
    
    static FormatStepResult ok() => FormatStepResult(true, "", [], false);
    static FormatStepResult changed(string[] files) => FormatStepResult(true, "", files, true);
    static FormatStepResult fail(string err) => FormatStepResult(false, err, [], false);
}

/// Result for linting
struct LintStepResult
{
    bool success = true;
    string error;
    string[] errors;
    string[] warnings;
    
    static LintStepResult ok() => LintStepResult(true, "", [], []);
    static LintStepResult fail(string[] errs) => LintStepResult(false, errs.empty ? "" : errs[0], errs, []);
    
    bool hasErrors() const pure nothrow => !errors.empty;
    bool hasWarnings() const pure nothrow => !warnings.empty;
}

/// Result for type checking
struct TypeCheckStepResult
{
    bool success = true;
    string error;
    string[] errors;
    string[] warnings;
    
    static TypeCheckStepResult ok() => TypeCheckStepResult(true, "", [], []);
    static TypeCheckStepResult fail(string[] errs) => TypeCheckStepResult(false, errs.empty ? "" : errs[0], errs, []);
    static TypeCheckStepResult disabled() => TypeCheckStepResult(true, "", [], []);
    
    bool hasErrors() const pure nothrow => !errors.empty;
    bool hasWarnings() const pure nothrow => !warnings.empty;
}

/// Result for dependency installation
struct DependencyInstallResult
{
    bool success = true;
    string error;
    string[] installedPackages;
    
    static DependencyInstallResult ok() => DependencyInstallResult(true, "", []);
    static DependencyInstallResult ok(string[] packages) => DependencyInstallResult(true, "", packages);
    static DependencyInstallResult fail(string err) => DependencyInstallResult(false, err, []);
    static DependencyInstallResult skipped() => DependencyInstallResult(true, "", []);
}

/// Result for test execution
struct TestRunResult
{
    bool success = true;
    string error;
    uint passed;
    uint failed;
    uint skipped;
    string[] failedTests;
    string outputHash;
    
    static TestRunResult ok(uint passed = 0) => TestRunResult(true, "", passed, 0, 0, [], "");
    static TestRunResult fail(string err, string[] failed = []) => TestRunResult(false, err, 0, cast(uint)failed.length, 0, failed, "");
}

/**
 * Base class for scripting language handlers.
 * 
 * Provides common infrastructure for interpreted languages including:
 * - Action-level caching
 * - Config parsing helpers
 * - Build orchestration
 * - Pre/post build step hooks
 * - Dependency installation
 * - Code quality tools (format, lint, type check)
 * - Syntax validation
 * - Import analysis
 * 
 * Subclasses implement language-specific behavior by overriding abstract and hook methods.
 * The build flow is:
 *   1. Parse config → enhanceConfigFromProject()
 *   2. Setup environment → setupEnvironment()
 *   3. Pre-build steps → preBuildSteps() [deps, format, lint, typecheck]
 *   4. Syntax validation → validateSyntax()
 *   5. Build → buildExecutable/buildLibrary/runTests
 *   6. Post-build steps → postBuildSteps()
 */
abstract class BaseScriptingHandler : BaseLanguageHandler
{
    private ActionCache _actionCache;
    
    this() {}
    
    ~this() nothrow
    {
        // ActionCache cleanup handled by GC - explicit destruction causes issues during GC finalization
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHODS - Must be implemented by each language handler
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Returns the language identifier (e.g., "python", "ruby", "go")
    /// Used for cache paths, logging, and error messages.
    protected abstract string languageId() const pure nothrow @safe;
    
    /// Returns the config keys to look for in target.langConfig
    /// E.g., ["python", "pyConfig"] or ["ruby", "rubyConfig"]
    protected abstract string[] configKeys() const pure nothrow @safe;
    
    /// Returns the target language enum value for this handler
    protected abstract TargetLanguage targetLanguage() const pure nothrow @safe;
    
    /// Setup the interpreter environment and return the command to use
    /// Should resolve version managers, virtual environments, etc.
    protected abstract EnvironmentSetupResult setupEnvironment(
        JSONValue config,
        string projectRoot
    ) @system;
    
    /// Validate syntax of source files
    /// Called before build to catch syntax errors early
    protected abstract SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHODS - Override for language-specific behavior (optional)
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Parse language-specific config from JSON
    /// Default implementation returns empty config; override to parse your config type
    protected JSONValue parseConfig(in Target target) @system
    {
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    return parseJSON(target.langConfig[key]);
                }
                catch (Exception e)
                {
                    structuredLog.warning("config_parse_fallback").field("key", key).emit();
                }
            }
        }
        return JSONValue.init;
    }
    
    /// Enhance config based on project structure auto-detection
    /// Override to detect package managers, frameworks, etc.
    protected void enhanceConfigFromProject(
        ref JSONValue config,
        in Target target,
        in WorkspaceConfig workspace
    ) @system
    {
        // Default: no enhancement. Override in subclass.
    }
    
    /// Install dependencies
    /// Override to implement package manager integration
    protected DependencyInstallResult installDependencies(
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        return DependencyInstallResult.skipped();
    }
    
    /// Run code formatter
    /// Override to implement auto-formatting
    protected FormatStepResult runFormatter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        return FormatStepResult.ok();
    }
    
    /// Run linter
    /// Override to implement linting
    protected LintStepResult runLinter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        return LintStepResult.ok();
    }
    
    /// Run type checker
    /// Override to implement type checking (mypy, sorbet, etc.)
    protected TypeCheckStepResult runTypeChecker(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        return TypeCheckStepResult.disabled();
    }
    
    /// Pre-build steps hook - called before main build
    /// Default runs: deps install, format, lint, type check
    /// Override to customize the pre-build workflow
    protected ScriptingStepResult preBuildSteps(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        string[] allWarnings;
        
        // 1. Install dependencies (if shouldInstallDeps returns true)
        if (shouldInstallDeps(langConfig))
        {
            auto depResult = installDependenciesWithCache(target, langConfig, config.root, interpreterCmd);
            if (!depResult.success)
                return ScriptingStepResult.fail(depResult.error);
        }
        
        // 2. Auto-format (if shouldAutoFormat returns true)
        if (shouldAutoFormat(langConfig))
        {
            structuredLog.info("autoformatting_code").emit();
            auto fmtResult = runFormatterWithCache(target, langConfig, interpreterCmd);
            if (!fmtResult.success)
                structuredLog.warning("formatting_failed_continuing_anyway").emit();
        }
        
        // 3. Lint (if shouldAutoLint returns true)
        if (shouldAutoLint(langConfig))
        {
            structuredLog.info("autolinting_code").emit();
            auto lintResult = runLinterWithCache(target, langConfig, interpreterCmd);
            if (!lintResult.success && shouldFailOnLintError(langConfig))
                return ScriptingStepResult.fail("Linting failed: " ~ lintResult.error);
            if (lintResult.hasWarnings())
                allWarnings ~= lintResult.warnings;
        }
        
        // 4. Type check (if shouldTypeCheck returns true)
        if (shouldTypeCheck(langConfig))
        {
            structuredLog.info("running_type_checking").emit();
            auto typeResult = runTypeCheckerWithCache(target, langConfig, interpreterCmd);
            if (!typeResult.success && shouldFailOnTypeError(langConfig))
                return ScriptingStepResult.fail("Type checking failed: " ~ typeResult.error);
            if (typeResult.hasWarnings())
                allWarnings ~= typeResult.warnings;
        }
        
        return allWarnings.empty ? ScriptingStepResult.ok() : ScriptingStepResult.warn(allWarnings);
    }
    
    /// Post-build steps hook - called after successful build
    /// Override to add documentation generation, packaging, etc.
    protected ScriptingStepResult postBuildSteps(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd,
        ref LanguageBuildResult buildResult
    ) @system
    {
        return ScriptingStepResult.ok();
    }
    
    /// Build executable target - override for language-specific build logic
    protected LanguageBuildResult buildExecutableImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        // Default: scripting languages typically don't compile
        // Just return sources as outputs
        LanguageBuildResult result;
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Build library target - override for language-specific build logic
    protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        // Default: same as executable for scripting languages
        return buildExecutableImpl(target, config, langConfig, interpreterCmd);
    }
    
    /// Run tests - override for language-specific test framework support
    protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Build custom target - override if needed
    protected LanguageBuildResult buildCustomImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CONFIG FLAG HELPERS - Override to customize behavior based on config
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Should install dependencies before build?
    protected bool shouldInstallDeps(JSONValue config) const @system
    {
        try { return config["installDeps"].get!bool; } catch (Exception) { return false; }
    }
    
    /// Should auto-format code before build?
    protected bool shouldAutoFormat(JSONValue config) const @system
    {
        try { return config["autoFormat"].get!bool; } catch (Exception) { return false; }
    }
    
    /// Should auto-lint code before build?
    protected bool shouldAutoLint(JSONValue config) const @system
    {
        try { return config["autoLint"].get!bool; } catch (Exception) { return false; }
    }
    
    /// Should run type checker before build?
    protected bool shouldTypeCheck(JSONValue config) const @system
    {
        try { return config["typeCheck"]["enabled"].get!bool; } catch (Exception) { return false; }
    }
    
    /// Should fail build on lint errors?
    protected bool shouldFailOnLintError(JSONValue config) const @system
    {
        try { return config["lint"]["failOnError"].get!bool; } catch (Exception) { return false; }
    }
    
    /// Should fail build on type errors?
    protected bool shouldFailOnTypeError(JSONValue config) const @system
    {
        try { return config["typeCheck"]["strict"].get!bool; } catch (Exception) { return true; }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // CACHING INFRASTRUCTURE
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Get access to the action cache (lazy initialization)
    protected final ActionCache getCache() @system
    {
        if (_actionCache is null)
        {
            version(unittest)
            {
                _actionCache = new NullActionCache();
            }
            else
            {
                auto cacheConfig = ActionCacheConfig.fromEnvironment();
                _actionCache = new ActionCache(".builder-cache/actions/" ~ languageId(), cacheConfig);
            }
        }
        return _actionCache;
    }
    
    /// Install dependencies with caching
    protected DependencyInstallResult installDependenciesWithCache(
        in Target target,
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        string[string] metadata;
        metadata["language"] = languageId();
        
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = "deps";
        actionId.inputHash = FastHash.hashStrings(target.sources);
        
        if (getCache().isCached(actionId, target.sources, metadata))
        {
            structuredLog.debug_("__cached_dependency_installation").emit();
            return DependencyInstallResult.ok();
        }
        
        auto result = installDependencies(config, projectRoot, interpreterCmd);
        getCache().update(actionId, target.sources, [], metadata, result.success);
        
        return result;
    }
    
    /// Run formatter with caching
    protected FormatStepResult runFormatterWithCache(
        in Target target,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        return runFormatter(target.sources, config, interpreterCmd);
    }
    
    /// Run linter with caching (per-file)
    protected LintStepResult runLinterWithCache(
        in Target target,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        string[string] metadata;
        metadata["language"] = languageId();
        
        string[] allErrors;
        string[] allWarnings;
        
        foreach (source; target.sources)
        {
            ActionId actionId;
            actionId.targetId = target.name;
            actionId.type = ActionType.Custom;
            actionId.subId = "lint:" ~ source;
            actionId.inputHash = FastHash.hashFile(source);
            
            if (getCache().isCached(actionId, [source], metadata))
            {
                structuredLog.debug_("__cached_lint_").field("detail", "  [Cached] Lint: " ~ source).emit();
                continue;
            }
            
            auto lintResult = runLinter([source], config, interpreterCmd);
            getCache().update(actionId, [source], [], metadata, lintResult.success);
            
            if (!lintResult.success)
                allErrors ~= lintResult.errors;
            allWarnings ~= lintResult.warnings;
        }
        
        if (!allErrors.empty)
            return LintStepResult.fail(allErrors);
        
        LintStepResult result;
        result.success = true;
        result.warnings = allWarnings;
        return result;
    }
    
    /// Run type checker with caching
    protected TypeCheckStepResult runTypeCheckerWithCache(
        in Target target,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        string[string] metadata;
        metadata["language"] = languageId();
        
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Custom;
        actionId.subId = "typecheck";
        actionId.inputHash = FastHash.hashStrings(target.sources);
        
        if (getCache().isCached(actionId, target.sources, metadata))
        {
            structuredLog.debug_("__cached_type_checking").emit();
            return TypeCheckStepResult.ok();
        }
        
        auto result = runTypeChecker(target.sources, config, interpreterCmd);
        getCache().update(actionId, target.sources, [], metadata, result.success);
        
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // BASE CLASS OVERRIDES - Implement the template method pattern
    // ═══════════════════════════════════════════════════════════════════════════
    
    /// Main build entry point - orchestrates the entire build process
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        structuredLog.debug_("building_").field("detail", "Building " ~ languageId() ~ " target: " ~ target.name).emit();
        
        // 1. Parse and enhance config
        JSONValue langConfig = parseConfig(target);
        enhanceConfigFromProject(langConfig, target, config);
        
        // 2. Setup environment
        auto envResult = setupEnvironment(langConfig, config.root);
        if (!envResult.success)
        {
            LanguageBuildResult result;
            result.error = envResult.error;
            return result;
        }
        string interpreterCmd = envResult.interpreterCommand;
        
        // 3. Pre-build steps
        auto preBuildResult = preBuildSteps(target, config, langConfig, interpreterCmd);
        if (!preBuildResult.success)
        {
            LanguageBuildResult result;
            result.error = preBuildResult.error;
            return result;
        }
        
        // 4. Validate syntax
        auto syntaxResult = validateSyntax(target.sources, langConfig, interpreterCmd);
        if (!syntaxResult.success)
        {
            LanguageBuildResult result;
            result.error = syntaxResult.firstError();
            return result;
        }
        
        // 5. Build based on target type
        LanguageBuildResult buildResult;
        final switch (target.type)
        {
            case TargetType.Executable:
                buildResult = buildExecutableImpl(target, config, langConfig, interpreterCmd);
                break;
            case TargetType.Library:
                buildResult = buildLibraryImpl(target, config, langConfig, interpreterCmd);
                break;
            case TargetType.Test:
                buildResult = runTestsImpl(target, config, langConfig, interpreterCmd);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                buildResult = buildCustomImpl(target, config, langConfig, interpreterCmd);
                break;
        }
        
        // 6. Post-build steps (only on success)
        if (buildResult.success)
        {
            auto postBuildResult = postBuildSteps(target, config, langConfig, interpreterCmd, buildResult);
            if (!postBuildResult.success)
            {
                buildResult.success = false;
                buildResult.error = postBuildResult.error;
            }
        }
        
        return buildResult;
    }
    
    /// Get output files for a target
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
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
    
    /// Analyze imports in source files
    override Import[] analyzeImports(in string[] sources) @system
    {
        auto spec = getLanguageSpec(targetLanguage());
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
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source).emit();
            }
        }
        
        return allImports;
    }
}

