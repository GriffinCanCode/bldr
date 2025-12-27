module languages.scripting.r.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import languages.scripting.base;
import languages.scripting.r.core.config;
import languages.scripting.r.tooling.info;
import languages.scripting.r.managers.packages;
import languages.scripting.r.managers.environments;
import languages.scripting.r.tooling.checkers;
import languages.scripting.r.analysis.dependencies;
import languages.scripting.r.tooling.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// R language handler with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class RHandler : BaseScriptingHandler
{
    private RConfig _currentConfig;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "r";
    
    override protected string[] configKeys() const pure nothrow @safe => ["r", "rConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.R;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        RConfig rConfig = RConfig.fromJSON(config);
        _currentConfig = rConfig;
        
        auto rInfo = detectR(rConfig.rCommand);
        auto rscriptInfo = detectRscript(rConfig.rExecutable);
        
        if (!rInfo.available || !rscriptInfo.available)
            return EnvironmentSetupResult.fail("R not found. Please install R from https://www.r-project.org/");
        
        if (!rConfig.rVersion.empty && !rInfo.meetsVersion(rConfig.rVersion))
            return EnvironmentSetupResult.fail("R version " ~ rInfo.version_ ~ " does not meet requirement: " ~ rConfig.rVersion);
        
        structuredLog.debug_("using_r_")
            .field("detail", "Using R: " ~ getRVersion(rConfig.rCommand))
            .emit();
        
        // Setup environment if configured
        if (rConfig.env.enabled)
        {
            auto envResult = setupREnvironment(rConfig, projectRoot);
            if (!envResult.success)
                return EnvironmentSetupResult.fail(envResult.error);
        }
        
        return EnvironmentSetupResult.ok(rConfig.rExecutable);
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        // R scripts are validated when run
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        RConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = RConfig.fromJSON(json);
                    _currentConfig = config;
                    return json;
                }
                catch (Exception e)
                {
                    structuredLog.warning("config_parse_fallback").field("key", key).emit();
                }
            }
        }
        
        _currentConfig = config;
        return JSONValue.init;
    }
    
    override protected void enhanceConfigFromProject(
        ref JSONValue config,
        in Target target,
        in WorkspaceConfig workspace
    ) @system
    {
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        // Auto-detect package structure
        if (exists(buildPath(sourceDir, "DESCRIPTION")))
        {
            if (_currentConfig.mode == RBuildMode.Script)
            {
                _currentConfig.mode = RBuildMode.Package;
                structuredLog.debug_("detected_r_package_structure").emit();
            }
        }
        
        // Auto-detect Shiny app
        if (exists(buildPath(sourceDir, "app.R")) || 
            (exists(buildPath(sourceDir, "server.R")) && exists(buildPath(sourceDir, "ui.R"))))
        {
            if (_currentConfig.mode == RBuildMode.Script)
            {
                _currentConfig.mode = RBuildMode.Shiny;
                structuredLog.debug_("detected_shiny_app").emit();
            }
        }
        
        // Auto-detect RMarkdown
        if (target.sources[0].endsWith(".Rmd") || target.sources[0].endsWith(".rmd"))
        {
            if (_currentConfig.mode == RBuildMode.Script)
            {
                _currentConfig.mode = RBuildMode.RMarkdown;
                structuredLog.debug_("detected_rmarkdown_document").emit();
            }
        }
        
        // Auto-detect environment
        if (_currentConfig.env.manager == REnvManager.Auto)
        {
            if (usesRenv(sourceDir))
            {
                _currentConfig.env.manager = REnvManager.Renv;
                _currentConfig.env.enabled = true;
                structuredLog.debug_("detected_renv_environment").emit();
            }
            else if (usesPackrat(sourceDir))
            {
                _currentConfig.env.manager = REnvManager.Packrat;
                _currentConfig.env.enabled = true;
                structuredLog.debug_("detected_packrat_environment").emit();
            }
        }
    }
    
    override protected bool shouldInstallDeps(JSONValue config) const @system
        => _currentConfig.installDeps;
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.format.autoFormat;
    
    override protected bool shouldAutoLint(JSONValue config) const @system
        => _currentConfig.lint.linter != RLinter.None;
    
    override protected bool shouldFailOnLintError(JSONValue config) const @system
        => _currentConfig.lint.failOnWarnings;
    
    override protected DependencyInstallResult installDependencies(
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        auto deps = detectDependencies(projectRoot);
        
        if (deps.empty)
        {
            structuredLog.debug_("no_dependencies_detected").emit();
            return DependencyInstallResult.skipped();
        }
        
        structuredLog.info("installing_")
            .field("detail", "Installing " ~ deps.length.to!string ~ " dependencies")
            .emit();
        
        auto result = installPackages(
            deps,
            _currentConfig.packageManager,
            _currentConfig.rExecutable,
            projectRoot,
            _currentConfig
        );
        
        if (!result.success)
            return DependencyInstallResult.fail(result.error);
        
        return DependencyInstallResult.ok();
    }
    
    override protected LintStepResult runLinter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        string workDir = sources.empty ? "." : dirName(sources[0]);
        auto result = lintFiles(sources, _currentConfig.lint, _currentConfig.rExecutable, workDir);
        
        if (!result.success)
        {
            LintStepResult r;
            r.success = false;
            r.error = "Linting failed";
            return r;
        }
        
        return LintStepResult.ok();
    }
    
    override protected FormatStepResult runFormatter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        string workDir = sources.empty ? "." : dirName(sources[0]);
        auto result = formatFiles(sources, _currentConfig.format, _currentConfig.rExecutable, workDir);
        
        if (!result.success)
            return FormatStepResult.fail(result.error);
        
        return FormatStepResult.ok();
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        auto builder = getBuilder(_currentConfig.mode);
        if (builder)
            return builder.getOutputs(target, config, _currentConfig);
        
        return [buildPath(config.options.outputDir, target.name.split(":")[$ - 1])];
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // BUILD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected LanguageBuildResult buildExecutableImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        auto builder = getBuilder(_currentConfig.mode);
        if (!builder)
        {
            LanguageBuildResult result;
            result.error = "No builder available for mode: " ~ _currentConfig.mode.to!string;
            return result;
        }
        
        if (!builder.validate(target, _currentConfig))
        {
            LanguageBuildResult result;
            result.error = "Build validation failed";
            return result;
        }
        
        auto buildResult = builder.build(target, config, _currentConfig, _currentConfig.rExecutable);
        
        LanguageBuildResult result;
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputHash = buildResult.outputHash;
        result.outputs = buildResult.outputs;
        
        return result;
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        _currentConfig.mode = RBuildMode.Package;
        return buildExecutableImpl(target, config, langConfig, interpreterCmd);
    }
    
    override protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        if (target.sources.empty)
        {
            LanguageBuildResult result;
            result.error = "No test files specified";
            return result;
        }
        
        if (_currentConfig.test.framework == RTestFramework.Auto)
            _currentConfig.test.framework = detectBestTestFramework(_currentConfig.rExecutable);
        
        string workDir = config.root;
        if (!target.sources.empty)
            workDir = dirName(target.sources[0]);
        
        final switch (_currentConfig.test.framework)
        {
            case RTestFramework.Auto:
            case RTestFramework.None:
                return runTestScripts(target, workDir);
                
            case RTestFramework.Testthat:
                return runTestthatTests(target, workDir);
                
            case RTestFramework.Tinytest:
                return runTinytestTests(target, workDir);
                
            case RTestFramework.RUnit:
                return runRUnitTests(target, workDir);
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // R-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private EnvResult setupREnvironment(ref RConfig config, string workDir)
    {
        auto status = getEnvironmentStatus(config.env.manager, workDir, config.rExecutable);
        
        if (status.hasLockfile && !status.exists)
        {
            structuredLog.info("restoring_r_environment_from_lockfile").emit();
            return restoreEnvironment(config.env.manager, workDir, config.rExecutable, config);
        }
        else if (!status.exists && config.env.autoCreate)
        {
            structuredLog.info("creating_new_r_environment").emit();
            return initializeEnvironment(config.env.manager, workDir, config.rExecutable, config);
        }
        
        return EnvResult(true, "", "");
    }
    
    private RBuilder getBuilder(RBuildMode mode)
    {
        final switch (mode)
        {
            case RBuildMode.Script:
                return new RScriptBuilder();
            case RBuildMode.Package:
            case RBuildMode.Check:
            case RBuildMode.Vignette:
                return new RPackageBuilder();
            case RBuildMode.Shiny:
                return new RShinyBuilder();
            case RBuildMode.RMarkdown:
                return new RMarkdownBuilder();
        }
    }
    
    private LanguageBuildResult runTestthatTests(in Target target, string workDir)
    {
        LanguageBuildResult result;
        
        string testCode = "testthat::test_dir('" ~ workDir ~ "', reporter='" ~ _currentConfig.test.reporter ~ "')";
        
        if (_currentConfig.test.coverage)
            testCode = "covr::package_coverage(path='" ~ dirName(workDir) ~ "', type='tests')";
        
        structuredLog.info("running_testthat_tests").emit();
        
        auto env = prepareEnvironment(_currentConfig);
        auto res = execute([_currentConfig.rExecutable, "-e", testCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private LanguageBuildResult runTinytestTests(in Target target, string workDir)
    {
        LanguageBuildResult result;
        
        string testCode = "tinytest::test_all('" ~ workDir ~ "')";
        
        structuredLog.info("running_tinytest_tests").emit();
        
        auto env = prepareEnvironment(_currentConfig);
        auto res = execute([_currentConfig.rExecutable, "-e", testCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private LanguageBuildResult runRUnitTests(in Target target, string workDir)
    {
        LanguageBuildResult result;
        
        string testCode = "RUnit::runTestSuite(RUnit::defineTestSuite('tests', dirs='" ~ workDir ~ "'))";
        
        structuredLog.info("running_runit_tests").emit();
        
        auto env = prepareEnvironment(_currentConfig);
        auto res = execute([_currentConfig.rExecutable, "-e", testCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private LanguageBuildResult runTestScripts(in Target target, string workDir)
    {
        LanguageBuildResult result;
        
        foreach (source; target.sources)
        {
            structuredLog.info("running_r_test_")
                .field("detail", "Running R test: " ~ source)
                .emit();
            
            auto env = prepareEnvironment(_currentConfig);
            auto res = execute([_currentConfig.rExecutable, source], env, Config.none, size_t.max, workDir);
            
            if (res.status != 0)
            {
                result.error = "Test failed in " ~ source ~ ": " ~ res.output;
                return result;
            }
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private string[string] prepareEnvironment(ref RConfig config)
    {
        import std.process : environment;
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        foreach (key, value; config.rEnv)
            env[key] = value;
        
        if (!config.libPaths.empty)
            env["R_LIBS_USER"] = config.libPaths.join(":");
        
        if (!config.cranMirror.empty)
            env["R_CRAN_MIRROR"] = config.cranMirror;
        
        return env;
    }
}
