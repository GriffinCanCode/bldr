module languages.scripting.php.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.uuid;
import languages.scripting.base;
import languages.scripting.php.core.config;
import languages.scripting.php.tooling.detection;
import languages.scripting.php.managers.composer;
import languages.scripting.php.analysis;
import languages.scripting.php.tooling.formatters;
import languages.scripting.php.tooling.packagers;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// PHP build handler with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class PHPHandler : BaseScriptingHandler
{
    private PHPConfig _currentConfig;
    private string _currentPhpCmd;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "php";
    
    override protected string[] configKeys() const pure nothrow @safe => ["php", "phpConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.PHP;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        PHPConfig phpConfig = PHPConfig.fromJSON(config);
        _currentConfig = phpConfig;
        
        string phpCmd = "php";
        
        if (!phpConfig.phpVersion.interpreterPath.empty)
            phpCmd = phpConfig.phpVersion.interpreterPath;
        
        if (!PHPTools.isPHPAvailable(phpCmd))
        {
            structuredLog.warning("php_not_available_at_")
                .field("detail", "PHP not available at: " ~ phpCmd ~ ", falling back to 'php'")
                .emit();
            phpCmd = "php";
        }
        
        structuredLog.debug_("using_php_")
            .field("detail", "Using PHP: " ~ phpCmd ~ " (" ~ PHPTools.getPHPVersion(phpCmd) ~ ")")
            .emit();
        
        _currentPhpCmd = phpCmd;
        return EnvironmentSetupResult.ok(phpCmd);
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        string[] allErrors;
        
        foreach (source; sources)
        {
            auto res = execute([interpreterCmd, "-l", source]);
            if (res.status != 0)
                allErrors ~= "In " ~ source ~ ": " ~ res.output;
        }
        
        if (!allErrors.empty)
            return SyntaxValidationResult.fail(allErrors);
        
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        PHPConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = PHPConfig.fromJSON(json);
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
        
        if (_currentConfig.composer.composerJson.empty)
        {
            string composerPath = ComposerTool.findComposerJson(sourceDir);
            if (!composerPath.empty)
            {
                _currentConfig.composer.composerJson = composerPath;
                structuredLog.debug_("found_composerjson_")
                    .field("detail", "Found composer.json: " ~ composerPath)
                    .emit();
            }
        }
        
        if (_currentConfig.analysis.analyzer == PHPAnalyzer.Auto)
            _currentConfig.analysis.analyzer = AnalyzerFactory.detectFromProject(workspace.root);
        
        if (_currentConfig.formatter.formatter == PHPFormatter.Auto)
            _currentConfig.formatter.formatter = FormatterFactory.detectFromProject(workspace.root);
    }
    
    override protected bool shouldInstallDeps(JSONValue config) const @system
        => _currentConfig.composer.autoInstall;
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.formatter.enabled && _currentConfig.formatter.formatter != PHPFormatter.None;
    
    override protected bool shouldAutoLint(JSONValue config) const @system
        => _currentConfig.analysis.enabled && _currentConfig.analysis.analyzer != PHPAnalyzer.None;
    
    override protected DependencyInstallResult installDependencies(
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        if (!ComposerTool.isAvailable(_currentConfig.composer.composerPath))
        {
            structuredLog.error("composer_not_available").emit();
            return DependencyInstallResult.fail("Composer not available");
        }
        
        auto composer = new ComposerTool(_currentConfig.composer.composerPath, projectRoot);
        
        structuredLog.info("installing_composer_dependencies").emit();
        bool success = composer.install(
            _currentConfig.composer.noDev,
            _currentConfig.composer.optimizeAutoloader
        );
        
        if (!success)
            return DependencyInstallResult.fail("Composer install failed");
        
        return DependencyInstallResult.ok();
    }
    
    override protected FormatStepResult runFormatter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto formatter = FormatterFactory.create(_currentConfig.formatter.formatter, ".");
        auto formatResult = formatter.format(sources, _currentConfig.formatter, ".", false);
        
        if (!formatResult.success)
            return FormatStepResult.fail("Formatting failed");
        
        return FormatStepResult.ok();
    }
    
    override protected LintStepResult runLinter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto analyzer = AnalyzerFactory.create(_currentConfig.analysis.analyzer, ".");
        auto analysisResult = analyzer.analyze(sources, _currentConfig.analysis, ".");
        
        if (analysisResult.hasErrors())
        {
            LintStepResult result;
            result.success = false;
            result.errors = analysisResult.errors;
            result.error = analysisResult.errors.empty ? "" : analysisResult.errors[0];
            return result;
        }
        
        LintStepResult result;
        result.success = true;
        result.warnings = analysisResult.warnings;
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        string[] outputs;
        
        if (_currentConfig.mode == PHPBuildMode.PHAR || _currentConfig.mode == PHPBuildMode.FrankenPHP)
        {
            string outputFile = _currentConfig.phar.outputFile;
            if (outputFile.empty)
                outputFile = "app.phar";
            
            outputs ~= buildPath(config.options.outputDir, outputFile);
        }
        else
        {
            if (!target.outputPath.empty)
                outputs ~= buildPath(config.options.outputDir, target.outputPath);
            else
            {
                auto name = target.name.split(":")[$ - 1];
                outputs ~= buildPath(config.options.outputDir, name);
            }
        }
        
        return outputs;
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
        if (target.sources.length == 0)
        {
            LanguageBuildResult result;
            result.error = "No source files specified for target " ~ target.name;
            return result;
        }
        
        if (_currentConfig.validateAutoload)
            validatePSR4Autoload(config.root);
        
        final switch (_currentConfig.mode)
        {
            case PHPBuildMode.Script:
                return buildScript(target, config);
            case PHPBuildMode.Application:
                return buildApplication(target, config);
            case PHPBuildMode.Library:
                return buildLibrary(target, config);
            case PHPBuildMode.PHAR:
                return buildPHAR(target, config);
            case PHPBuildMode.Package:
                return buildPackage(target, config);
            case PHPBuildMode.FrankenPHP:
                return buildFrankenPHP(target, config);
        }
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        _currentConfig.mode = PHPBuildMode.Library;
        return buildExecutableImpl(target, config, langConfig, interpreterCmd);
    }
    
    override protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        auto framework = _currentConfig.test.framework;
        if (framework == PHPTestFramework.Auto)
            framework = detectTestFramework(config.root);
        
        final switch (framework)
        {
            case PHPTestFramework.Auto:
                framework = PHPTestFramework.PHPUnit;
                goto case PHPTestFramework.PHPUnit;
                
            case PHPTestFramework.PHPUnit:
                return runPHPUnit(target, config);
                
            case PHPTestFramework.Pest:
                return runPest(target, config);
                
            case PHPTestFramework.Codeception:
            case PHPTestFramework.Behat:
                LanguageBuildResult result;
                result.success = true;
                result.outputHash = FastHash.hashStrings(target.sources);
                return result;
                
            case PHPTestFramework.None:
                LanguageBuildResult result;
                result.success = true;
                return result;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PHP-SPECIFIC BUILD METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private LanguageBuildResult buildScript(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        auto outputs = getOutputs(target, config);
        if (!outputs.empty && !target.sources.empty)
        {
            auto outputPath = outputs[0];
            auto outputDir = dirName(outputPath);
            auto mainFile = target.sources[0];
            
            if (!exists(outputDir))
                mkdirRecurse(outputDir);
            
            string wrapper = "#!/usr/bin/env php\n<?php\n";
            
            if (_currentConfig.strictTypes)
                wrapper ~= "declare(strict_types=1);\n\n";
            
            if (!_currentConfig.includePaths.empty)
            {
                wrapper ~= "set_include_path(get_include_path() . PATH_SEPARATOR . '" ~ 
                          _currentConfig.includePaths.join("' . PATH_SEPARATOR . '") ~ "');\n\n";
            }
            
            string autoloadPath = buildPath(config.root, "vendor", "autoload.php");
            if (exists(autoloadPath))
            {
                string relPath = relativePath(autoloadPath, outputDir);
                wrapper ~= "require_once dirname(__FILE__) . '/" ~ relPath ~ "';\n\n";
            }
            
            string mainRelPath = relativePath(mainFile, outputDir);
            wrapper ~= "require_once dirname(__FILE__) . '/" ~ mainRelPath ~ "';\n";
            
            std.file.write(outputPath, wrapper);
            
            version(Posix)
            {
                if (SecurityValidator.isPathSafe(outputPath))
                {
                    auto chmodResult = execute(["chmod", "+x", outputPath]);
                    if (chmodResult.status != 0)
                        structuredLog.warning("failed_to_make_wrapper_executable_")
                            .field("detail", "Failed to make wrapper executable: " ~ chmodResult.output)
                            .emit();
                }
            }
        }
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildApplication(in Target target, in WorkspaceConfig config) @system
    {
        auto result = buildScript(target, config);
        
        if (result.success && _currentConfig.composer.optimizeAutoloader)
        {
            structuredLog.info("optimizing_composer_autoloader").emit();
            auto composer = new ComposerTool(_currentConfig.composer.composerPath, config.root);
            composer.dumpAutoload(true, _currentConfig.composer.authoritative, _currentConfig.composer.apcu);
        }
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildPHAR(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        structuredLog.info("creating_phar_archive").emit();
        
        auto packager = PackagerFactory.create(_currentConfig.phar.tool);
        
        if (!packager.isAvailable())
        {
            result.error = "PHAR packager '" ~ packager.name() ~ "' is not available";
            return result;
        }
        
        string[string] metadata;
        metadata["packager"] = packager.name();
        metadata["outputFile"] = _currentConfig.phar.outputFile;
        
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = "phar";
        actionId.inputHash = FastHash.hashStrings(target.sources);
        
        string outputFile = _currentConfig.phar.outputFile;
        if (outputFile.empty)
            outputFile = "app.phar";
        string fullOutputPath = buildPath(config.options.outputDir, outputFile);
        
        if (getCache().isCached(actionId, target.sources, metadata) && exists(fullOutputPath))
        {
            structuredLog.debug_("__cached_phar_packaging_")
                .field("detail", "  [Cached] PHAR packaging: " ~ outputFile)
                .emit();
            result.success = true;
            result.outputs = [fullOutputPath];
            result.outputHash = FastHash.hashFile(fullOutputPath);
            return result;
        }
        
        auto packageResult = packager.createPackage(target.sources, _currentConfig.phar, config.root);
        
        getCache().update(actionId, target.sources, packageResult.artifacts, metadata, packageResult.success);
        
        if (!packageResult.success)
        {
            result.error = "PHAR packaging failed:\n" ~ packageResult.errors.join("\n");
            return result;
        }
        
        result.success = true;
        result.outputs = packageResult.artifacts;
        result.outputHash = FastHash.hashStrings(packageResult.artifacts);
        
        return result;
    }
    
    private LanguageBuildResult buildPackage(in Target target, in WorkspaceConfig config) @system
    {
        auto composer = new ComposerTool(_currentConfig.composer.composerPath, config.root);
        
        if (!composer.validate())
            structuredLog.warning("composerjson_validation_failed").emit();
        
        return buildLibrary(target, config);
    }
    
    private LanguageBuildResult buildFrankenPHP(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        if (!PHPTools.isFrankenPHPAvailable(_currentConfig.frankenphp.binaryPath))
        {
            result.error = "FrankenPHP not available. Install from: https://frankenphp.dev/";
            return result;
        }
        
        structuredLog.info("building_frankenphp_standalone_binary").emit();
        
        string[] pharFiles;
        if (_currentConfig.frankenphp.embed)
        {
            auto pharResult = buildPHAR(target, config);
            if (!pharResult.success)
                return pharResult;
            pharFiles = pharResult.outputs;
        }
        
        auto name = target.name.split(":")[$ - 1];
        if (name.empty)
            name = "app";
        
        string outputPath = buildPath(config.options.outputDir, name);
        
        createFrankenPHPWrapper(outputPath, pharFiles.empty ? "" : pharFiles[0], 
            target.sources.empty ? "" : target.sources[0], config.root);
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    private void createFrankenPHPWrapper(string outputPath, string pharPath, string entryPoint, string projectRoot) @system
    {
        string wrapper = "#!/usr/bin/env bash\n";
        wrapper ~= "# FrankenPHP application wrapper\n";
        wrapper ~= "SCRIPT_DIR=\"$( cd \"$( dirname \"${BASH_SOURCE[0]}\" )\" && pwd )\"\n";
        wrapper ~= "FRANKENPHP_BIN=\"" ~ _currentConfig.frankenphp.binaryPath ~ "\"\n\n";
        wrapper ~= "if ! command -v \"$FRANKENPHP_BIN\" &> /dev/null; then\n";
        wrapper ~= "    echo \"Error: FrankenPHP not found\"\n";
        wrapper ~= "    exit 1\n";
        wrapper ~= "fi\n\n";
        wrapper ~= "exec \"$FRANKENPHP_BIN\" php-server \"$@\"\n";
        
        if (!exists(dirName(outputPath)))
            mkdirRecurse(dirName(outputPath));
        
        std.file.write(outputPath, wrapper);
        
        version(Posix)
        {
            if (SecurityValidator.isPathSafe(outputPath))
                execute(["chmod", "+x", outputPath]);
        }
        
        structuredLog.info("created_frankenphp_wrapper_")
            .field("detail", "Created FrankenPHP wrapper: " ~ outputPath)
            .emit();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PHP-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private void validatePSR4Autoload(string projectRoot) @system
    {
        if (_currentConfig.composer.composerJson.empty)
            return;
        
        try
        {
            auto metadata = ComposerTool.parseComposerJson(_currentConfig.composer.composerJson);
            
            foreach (ns, dir; metadata.autoload.psr4)
            {
                string fullPath = buildPath(projectRoot, dir);
                if (!exists(fullPath))
                    structuredLog.warning("psr4_directory_not_found_")
                        .field("detail", "PSR-4 directory not found: " ~ fullPath ~ " for namespace " ~ ns)
                        .emit();
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_validate_psr4_autoload_")
                .field("detail", "Failed to validate PSR-4 autoload: " ~ e.msg)
                .emit();
        }
    }
    
    private PHPTestFramework detectTestFramework(string projectRoot) @system
    {
        if (PHPTools.isPHPUnitAvailable() || exists(buildPath(projectRoot, "phpunit.xml")))
            return PHPTestFramework.PHPUnit;
        
        if (PHPTools.isPestAvailable() || exists(buildPath(projectRoot, "pest.php")))
            return PHPTestFramework.Pest;
        
        if (PHPTools.isCodeceptionAvailable() || exists(buildPath(projectRoot, "codeception.yml")))
            return PHPTestFramework.Codeception;
        
        if (PHPTools.isBehatAvailable() || exists(buildPath(projectRoot, "behat.yml")))
            return PHPTestFramework.Behat;
        
        return PHPTestFramework.PHPUnit;
    }
    
    private LanguageBuildResult runPHPUnit(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        string phpunitCmd = PHPTools.getPHPUnitCommand();
        if (phpunitCmd.empty)
        {
            result.error = "PHPUnit not found. Install: composer require --dev phpunit/phpunit";
            return result;
        }
        
        string[] cmd = [phpunitCmd];
        
        if (!_currentConfig.test.configFile.empty && exists(_currentConfig.test.configFile))
            cmd ~= ["--configuration", _currentConfig.test.configFile];
        
        if (_currentConfig.test.verbose)
            cmd ~= "--verbose";
        
        if (_currentConfig.test.coverage)
            cmd ~= ["--coverage-" ~ _currentConfig.test.coverageFormat, _currentConfig.test.coverageDir];
        
        if (_currentConfig.test.stopOnFailure)
            cmd ~= "--stop-on-failure";
        
        if (!_currentConfig.test.testPaths.empty)
            cmd ~= _currentConfig.test.testPaths;
        else if (!target.sources.empty)
            cmd ~= target.sources;
        
        structuredLog.info("running_phpunit_")
            .field("detail", "Running PHPUnit: " ~ cmd.join(" "))
            .emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, config.root);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runPest(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        if (!PHPTools.isPestAvailable())
        {
            result.error = "Pest not found. Install: composer require --dev pestphp/pest";
            return result;
        }
        
        string[] cmd = [buildPath("vendor", "bin", "pest")];
        
        if (_currentConfig.test.verbose)
            cmd ~= "-v";
        
        if (_currentConfig.test.coverage)
            cmd ~= "--coverage";
        
        structuredLog.info("running_pest_")
            .field("detail", "Running Pest: " ~ cmd.join(" "))
            .emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, config.root);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
}
