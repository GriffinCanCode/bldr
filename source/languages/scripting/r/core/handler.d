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
import languages.base.base;
import languages.base.mixins;
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
import engine.caching.actions.action;

/// R language handler with action-level caching for linting, formatting, package building, and tests
class RHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"r";
    mixin ConfigParsingMixin!(RConfig, "parseRConfig", ["r", "rConfig"]);
    mixin SimpleBuildOrchestrationMixin!(RConfig, "parseRConfig");
    
    private void enhanceConfigFromProject(
        ref RConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        // Auto-detect package structure
        if (exists(buildPath(sourceDir, "DESCRIPTION")))
        {
            if (config.mode == RBuildMode.Script)
            {
                config.mode = RBuildMode.Package;
                structuredLog.debug_("detected_r_package_structure").emit();
            }
        }
        
        // Auto-detect Shiny app
        if (exists(buildPath(sourceDir, "app.R")) || 
            (exists(buildPath(sourceDir, "server.R")) && exists(buildPath(sourceDir, "ui.R"))))
        {
            if (config.mode == RBuildMode.Script)
            {
                config.mode = RBuildMode.Shiny;
                structuredLog.debug_("detected_shiny_app").emit();
            }
        }
        
        // Auto-detect RMarkdown
        if (target.sources[0].endsWith(".Rmd") || target.sources[0].endsWith(".rmd"))
        {
            if (config.mode == RBuildMode.Script)
            {
                config.mode = RBuildMode.RMarkdown;
                structuredLog.debug_("detected_rmarkdown_document").emit();
            }
        }
        
        // Auto-detect environment
        if (config.env.manager == REnvManager.Auto)
        {
            if (usesRenv(sourceDir))
            {
                config.env.manager = REnvManager.Renv;
                config.env.enabled = true;
                structuredLog.debug_("detected_renv_environment").emit();
            }
            else if (usesPackrat(sourceDir))
            {
                config.env.manager = REnvManager.Packrat;
                config.env.enabled = true;
                structuredLog.debug_("detected_packrat_environment").emit();
            }
        }
        
        // Validate R installation
        if (!validateRInstallation(config))
        {
            structuredLog.warning("rrscript_not_available_install_from_http").emit();
            return;
        }
        
        structuredLog.debug_("using_r_").field("detail", "Using R: " ~ getRVersion(config.rCommand)).emit();
        
        // Setup environment if configured
        if (config.env.enabled)
        {
            auto envResult = setupEnvironment(config, workspace.root);
            if (!envResult.success)
            {
                structuredLog.warning("environment_setup_failed_").field("detail", "Environment setup failed: " ~ envResult.error).emit();
                return;
            }
        }
        
        // Install dependencies if requested
        if (config.installDeps)
        {
            if (!installProjectDependencies(config, target, workspace))
            {
                structuredLog.warning("failed_to_install_dependencies").emit();
                return;
            }
        }
        
        // Run linter with action-level caching if configured
        if (config.lint.linter != RLinter.None && !target.sources.empty)
        {
            auto lintResult = lintFilesWithCache(target, config, workspace.root);
            if (!lintResult.success)
            {
                if (config.lint.failOnWarnings || lintResult.errorCount > 0)
                {
                    structuredLog.warning("linting_failed_with_").field("detail", "Linting failed with " ~ lintResult.errorCount.to!string ~ " error(s)").emit();
                }
            }
        }
        
        // Run formatter with action-level caching if configured
        if (config.format.autoFormat && !target.sources.empty)
        {
            auto formatResult = formatFilesWithCache(target, config, workspace.root);
            if (!formatResult.success)
            {
                structuredLog.warning("formatting_failed_").field("detail", "Formatting failed: " ~ formatResult.error).emit();
            }
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        RConfig rConfig = parseRConfig(target);
        enhanceConfigFromProject(rConfig, target, config);
        
        // Get builder for mode
        auto builder = getBuilder(rConfig.mode);
        if (builder)
        {
            return builder.getOutputs(target, config, rConfig);
        }
        
        // Fallback
        return [buildPath(config.options.outputDir, target.name.split(":")[$ - 1])];
    }
    
    /// Build executable target
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        RConfig rConfig
    )
    {
        auto builder = getBuilder(rConfig.mode);
        if (!builder)
        {
            LanguageBuildResult result;
            result.error = "No builder available for mode: " ~ rConfig.mode.to!string;
            return result;
        }
        
        if (!builder.validate(target, rConfig))
        {
            LanguageBuildResult result;
            result.error = "Build validation failed";
            return result;
        }
        
        // Build and convert result
        auto buildResult = builder.build(target, config, rConfig, rConfig.rExecutable);
        LanguageBuildResult result;
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputHash = buildResult.outputHash;
        result.outputs = buildResult.outputs;
        
        return result;
    }
    
    /// Build library target (R package)
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        RConfig rConfig
    )
    {
        // Libraries in R are packages
        rConfig.mode = RBuildMode.Package;
        return buildExecutable(target, config, rConfig);
    }
    
    /// Run tests
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        RConfig rConfig
    )
    {
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            result.error = "No test files specified";
            return result;
        }
        
        // Auto-detect test framework
        if (rConfig.test.framework == RTestFramework.Auto)
        {
            rConfig.test.framework = detectBestTestFramework(rConfig.rExecutable);
        }
        
        string workDir = config.root;
        if (!target.sources.empty)
            workDir = dirName(target.sources[0]);
        
        final switch (rConfig.test.framework)
        {
            case RTestFramework.Auto:
            case RTestFramework.None:
                // Run R scripts directly
                return runTestScripts(target, config, rConfig, workDir);
                
            case RTestFramework.Testthat:
                return runTestthatTests(target, config, rConfig, workDir);
                
            case RTestFramework.Tinytest:
                return runTinytestTests(target, config, rConfig, workDir);
                
            case RTestFramework.RUnit:
                return runRUnitTests(target, config, rConfig, workDir);
        }
    }
    
    /// Build custom target
    private LanguageBuildResult buildCustom(
        in Target target,
        in WorkspaceConfig config,
        RConfig rConfig
    )
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Validate R installation
    private bool validateRInstallation(RConfig config)
    {
        auto rInfo = detectR(config.rCommand);
        auto rscriptInfo = detectRscript(config.rExecutable);
        
        if (!rInfo.available || !rscriptInfo.available)
        {
            structuredLog.error("r_not_found_please_install_r_from_httpsw").emit();
            return false;
        }
        
        // Check version requirement
        if (!config.rVersion.empty && !rInfo.meetsVersion(config.rVersion))
        {
            structuredLog.error("r_version_").field("detail", "R version " ~ rInfo.version_ ~ " does not meet requirement: " ~ config.rVersion).emit();
            return false;
        }
        
        return true;
    }
    
    /// Setup environment
    private EnvResult setupEnvironment(ref RConfig config, string workDir)
    {
        // Check if environment exists
        auto status = getEnvironmentStatus(config.env.manager, workDir, config.rExecutable);
        
        if (status.hasLockfile && !status.exists)
        {
            // Restore from lockfile
            structuredLog.info("restoring_r_environment_from_lockfile").emit();
            return restoreEnvironment(config.env.manager, workDir, config.rExecutable, config);
        }
        else if (!status.exists && config.env.autoCreate)
        {
            // Initialize new environment
            structuredLog.info("creating_new_r_environment").emit();
            return initializeEnvironment(config.env.manager, workDir, config.rExecutable, config);
        }
        
        return EnvResult(true, "", "");
    }
    
    /// Install project dependencies
    private bool installProjectDependencies(ref RConfig config, in Target target, in WorkspaceConfig workspace)
    {
        string projectDir = workspace.root;
        if (!target.sources.empty)
            projectDir = dirName(target.sources[0]);
        
        // Detect dependencies
        auto deps = detectDependencies(projectDir);
        
        if (deps.empty)
        {
            structuredLog.debug_("no_dependencies_detected").emit();
            return true;
        }
        
        structuredLog.info("installing_").field("detail", "Installing " ~ deps.length.to!string ~ " dependencies").emit();
        
        auto result = installPackages(
            deps,
            config.packageManager,
            config.rExecutable,
            projectDir,
            config
        );
        
        if (!result.success)
        {
            structuredLog.error("dependency_installation_failed_").field("detail", "Dependency installation failed: " ~ result.error).emit();
            return false;
        }
        
        return true;
    }
    
    /// Get builder for mode
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
    
    /// Run testthat tests
    private LanguageBuildResult runTestthatTests(
        const Target target,
        const WorkspaceConfig config,
        RConfig rConfig,
        string workDir
    )
    {
        LanguageBuildResult result;
        
        string testCode = "testthat::test_dir('" ~ workDir ~ "', reporter='" ~ rConfig.test.reporter ~ "')";
        
        if (rConfig.test.coverage)
        {
            testCode = "covr::package_coverage(path='" ~ dirName(workDir) ~ "', type='tests')";
        }
        
        structuredLog.info("running_testthat_tests").emit();
        
        auto env = prepareEnvironment(rConfig);
        auto res = execute([rConfig.rExecutable, "-e", testCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Run tinytest tests
    private LanguageBuildResult runTinytestTests(
        const Target target,
        const WorkspaceConfig config,
        RConfig rConfig,
        string workDir
    )
    {
        LanguageBuildResult result;
        
        string testCode = "tinytest::test_all('" ~ workDir ~ "')";
        
        structuredLog.info("running_tinytest_tests").emit();
        
        auto env = prepareEnvironment(rConfig);
        auto res = execute([rConfig.rExecutable, "-e", testCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Run RUnit tests
    private LanguageBuildResult runRUnitTests(
        const Target target,
        const WorkspaceConfig config,
        RConfig rConfig,
        string workDir
    )
    {
        LanguageBuildResult result;
        
        string testCode = "RUnit::runTestSuite(RUnit::defineTestSuite('tests', dirs='" ~ workDir ~ "'))";
        
        structuredLog.info("running_runit_tests").emit();
        
        auto env = prepareEnvironment(rConfig);
        auto res = execute([rConfig.rExecutable, "-e", testCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Run test scripts directly
    private LanguageBuildResult runTestScripts(
        const Target target,
        const WorkspaceConfig config,
        RConfig rConfig,
        string workDir
    )
    {
        LanguageBuildResult result;
        
        foreach (source; target.sources)
        {
            structuredLog.info("running_r_test_").field("detail", "Running R test: " ~ source).emit();
            
            auto env = prepareEnvironment(rConfig);
            auto res = execute([rConfig.rExecutable, source], env, Config.none, size_t.max, workDir);
            
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
    
    /// Prepare environment variables
    private string[string] prepareEnvironment(ref RConfig config)
    {
        import std.process : environment;
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        foreach (key, value; config.rEnv)
            env[key] = value;
        
        if (!config.libPaths.empty)
        {
            env["R_LIBS_USER"] = config.libPaths.join(":");
        }
        
        if (!config.cranMirror.empty)
        {
            env["R_CRAN_MIRROR"] = config.cranMirror;
        }
        
        return env;
    }
    
    /// Lint files with action-level caching (per-file for granularity)
    private auto lintFilesWithCache(in Target target, RConfig rConfig, string workDir)
    {
        import languages.scripting.r.tooling.checkers : LintResult;
        
        LintResult result;
        result.success = true;
        result.errorCount = 0;
        result.warningCount = 0;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["linter"] = rConfig.lint.linter.to!string;
        metadata["rExecutable"] = rConfig.rExecutable;
        metadata["failOnWarnings"] = rConfig.lint.failOnWarnings.to!string;
        
        foreach (source; target.sources)
        {
            // Create action ID for linting
            ActionId actionId;
            actionId.targetId = target.name;
            actionId.type = ActionType.Custom;
            actionId.subId = "lint_" ~ baseName(source);
            actionId.inputHash = FastHash.hashFile(source);
            
            // Check if linting is cached
            if (getCache().isCached(actionId, [source], metadata))
            {
                structuredLog.debug_("__cached_linting_").field("detail", "  [Cached] Linting: " ~ source).emit();
                continue;
            }
            
            // Run actual linting
            auto fileResult = lintFiles([source], rConfig.lint, rConfig.rExecutable, workDir);
            
            // Record action result
            getCache().update(
                actionId,
                [source],
                [],
                metadata,
                fileResult.success
            );
            
            // Aggregate results
            result.errorCount += fileResult.errorCount;
            result.warningCount += fileResult.warningCount;
            
            if (!fileResult.success)
                result.success = false;
        }
        
        return result;
    }
    
    /// Format files with action-level caching (per-file for granularity)
    private auto formatFilesWithCache(in Target target, RConfig rConfig, string workDir)
    {
        import languages.scripting.r.tooling.checkers : FormatResult;
        
        FormatResult result;
        result.success = true;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["autoFormat"] = rConfig.format.autoFormat.to!string;
        metadata["rExecutable"] = rConfig.rExecutable;
        
        foreach (source; target.sources)
        {
            // Create action ID for formatting
            ActionId actionId;
            actionId.targetId = target.name;
            actionId.type = ActionType.Transform;
            actionId.subId = "format_" ~ baseName(source);
            actionId.inputHash = FastHash.hashFile(source);
            
            // Check if formatting is cached
            if (getCache().isCached(actionId, [source], metadata))
            {
                structuredLog.debug_("__cached_formatting_").field("detail", "  [Cached] Formatting: " ~ source).emit();
                continue;
            }
            
            // Run actual formatting
            auto fileResult = formatFiles([source], rConfig.format, rConfig.rExecutable, workDir);
            
            // Record action result (output is the same file, modified in place)
            getCache().update(
                actionId,
                [source],
                [source],
                metadata,
                fileResult.success
            );
            
            if (!fileResult.success)
            {
                result.success = false;
                result.error = fileResult.error;
            }
        }
        
        return result;
    }
    
    /// Analyze imports in R files
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.R);
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
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source ~ ": " ~ e.msg).emit();
            }
        }
        
        return allImports;
    }
}

