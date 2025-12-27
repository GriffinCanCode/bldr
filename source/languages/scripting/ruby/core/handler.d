module languages.scripting.ruby.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import languages.scripting.base;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.tooling.info;
import languages.scripting.ruby.managers;
import languages.scripting.ruby.tooling.checkers;
import languages.scripting.ruby.tooling.formatters;
import languages.scripting.ruby.tooling.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// Ruby build handler with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class RubyHandler : BaseScriptingHandler
{
    private RubyConfig _currentConfig;
    private string _currentRubyCmd;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "ruby";
    
    override protected string[] configKeys() const pure nothrow @safe => ["ruby", "rubyConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.Ruby;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        RubyConfig rubyConfig = RubyConfig.fromJSON(config);
        _currentConfig = rubyConfig;
        
        string rubyCmd = "ruby";
        
        if (rubyConfig.rubyVersion.major > 0)
        {
            auto versionManager = VersionManagerFactory.create(rubyConfig.versionManager, projectRoot);
            string versionStr = rubyConfig.rubyVersion.toString();
            if (versionManager.isVersionInstalled(versionStr))
            {
                rubyCmd = versionManager.getRubyPath(versionStr);
                structuredLog.debug_("using_ruby_version_")
                    .field("detail", "Using Ruby version: " ~ versionStr)
                    .emit();
            }
        }
        
        _currentRubyCmd = rubyCmd;
        return EnvironmentSetupResult.ok(rubyCmd);
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        if (sources.empty)
            return SyntaxValidationResult.ok();
        
        string[] checkErrors;
        auto checkSuccess = SyntaxChecker.check(sources, checkErrors);
        
        if (!checkSuccess)
            return SyntaxValidationResult.fail(checkErrors.empty ? ["Syntax check failed"] : checkErrors);
        
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        RubyConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = RubyConfig.fromJSON(json);
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
        
        if (_currentConfig.packageManager == RubyPackageManager.Auto)
        {
            _currentConfig.packageManager = detectPackageManager(sourceDir);
            structuredLog.debug_("detected_package_manager_")
                .field("detail", "Detected package manager: " ~ _currentConfig.packageManager.to!string)
                .emit();
        }
        
        if (_currentConfig.versionManager == RubyVersionManager.Auto)
        {
            _currentConfig.versionManager = detectVersionManager(sourceDir);
            structuredLog.debug_("detected_version_manager_")
                .field("detail", "Detected version manager: " ~ _currentConfig.versionManager.to!string)
                .emit();
        }
    }
    
    override protected bool shouldInstallDeps(JSONValue config) const @system
        => _currentConfig.installDeps;
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.format.autoFormat && _currentConfig.format.formatter != RubyFormatter.None;
    
    override protected bool shouldTypeCheck(JSONValue config) const @system
        => _currentConfig.typeCheck.enabled;
    
    override protected DependencyInstallResult installDependencies(
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        auto packageManager = PackageManagerFactory.create(_currentConfig.packageManager, projectRoot);
        
        if (packageManager.hasLockfile())
        {
            structuredLog.info("installing_dependencies").emit();
            auto result = packageManager.installFromFile(buildPath(projectRoot, "Gemfile"));
            if (!result.success)
                return DependencyInstallResult.fail("Failed to install dependencies");
        }
        
        return DependencyInstallResult.ok();
    }
    
    override protected FormatStepResult runFormatter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto formatter = FormatterFactory.create(_currentConfig.format.formatter);
        auto fmtResult = formatter.format(sources, _currentConfig.format, _currentConfig.format.autoCorrect);
        
        if (!fmtResult.success)
            return FormatStepResult.fail("Formatting failed");
        
        if (fmtResult.hasOffenses())
        {
            structuredLog.info("found_")
                .field("detail", "Found " ~ fmtResult.offenseCount.to!string ~ " style offenses")
                .emit();
            if (fmtResult.autoFixed)
                structuredLog.info("autofixed_offenses").emit();
        }
        
        return FormatStepResult.ok();
    }
    
    override protected TypeCheckStepResult runTypeChecker(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto checker = TypeCheckerFactory.create(_currentConfig.typeCheck.checker);
        auto result = checker.check(sources, _currentConfig.typeCheck);
        
        if (result.hasErrors())
        {
            TypeCheckStepResult r;
            r.success = false;
            r.errors = result.errors;
            r.error = result.errors.empty ? "" : result.errors[0];
            return r;
        }
        
        if (result.hasWarnings() && _currentConfig.typeCheck.strict)
        {
            TypeCheckStepResult r;
            r.success = false;
            r.errors = result.warnings;
            r.error = "Type checking warnings in strict mode";
            return r;
        }
        
        return TypeCheckStepResult.ok();
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
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            result.error = "No source files provided";
            return result;
        }
        
        auto outputs = getOutputs(target, config);
        if (!outputs.empty && !target.sources.empty)
        {
            auto outputPath = outputs[0];
            auto mainFile = target.sources[0];
            
            // Generate wrapper script
            import std.file : write;
            write(outputPath, "#!/usr/bin/env ruby\nrequire_relative '" ~ mainFile ~ "'\n");
        }
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            result.error = "No source files provided";
            return result;
        }
        
        if (_currentConfig.mode == RubyBuildMode.Gem)
        {
            auto builder = new GemBuilder();
            auto buildResult = builder.build(target.sources, _currentConfig, target, config);
            if (!buildResult.success)
            {
                result.error = "Failed to build gem: " ~ buildResult.error;
                return result;
            }
            result.outputs = buildResult.outputs;
        }
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    override protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        auto runner = _currentConfig.test.framework;
        if (runner == RubyTestFramework.Auto)
            runner = detectTestFramework(config.root);
        
        final switch (runner)
        {
            case RubyTestFramework.Auto:
                runner = RubyTestFramework.Minitest;
                goto case RubyTestFramework.Minitest;
            
            case RubyTestFramework.Minitest:
                return runMinitest(target, interpreterCmd);
            
            case RubyTestFramework.RSpec:
                return runRSpec(target, interpreterCmd);
            
            case RubyTestFramework.TestUnit:
                return runTestUnit(target, interpreterCmd);
            
            case RubyTestFramework.Cucumber:
                return runCucumber(target, interpreterCmd, config.root);
            
            case RubyTestFramework.None:
                LanguageBuildResult result;
                result.success = true;
                return result;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // RUBY-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private RubyPackageManager detectPackageManager(string projectRoot)
    {
        if (exists(buildPath(projectRoot, "Gemfile")))
            return RubyPackageManager.Bundler;
        if (exists(buildPath(projectRoot, "*.gemspec")))
            return RubyPackageManager.RubyGems;
        return RubyPackageManager.Bundler;
    }
    
    private RubyVersionManager detectVersionManager(string projectRoot)
    {
        auto versionFile = buildPath(projectRoot, ".ruby-version");
        if (exists(versionFile))
        {
            auto checkRbenv = execute(["which", "rbenv"]);
            if (checkRbenv.status == 0)
                return RubyVersionManager.Rbenv;
            
            auto checkChruby = execute(["which", "chruby"]);
            if (checkChruby.status == 0)
                return RubyVersionManager.Chruby;
        }
        
        if (exists(buildPath(projectRoot, ".rvmrc")))
            return RubyVersionManager.RVM;
        
        if (exists(buildPath(projectRoot, ".tool-versions")))
            return RubyVersionManager.ASDF;
        
        return RubyVersionManager.System;
    }
    
    private RubyTestFramework detectTestFramework(string projectRoot)
    {
        import languages.scripting.ruby.tooling.testers.cucumber;
        if (CucumberRunner.detectCucumber(projectRoot))
            return RubyTestFramework.Cucumber;
        
        if (exists(buildPath(projectRoot, "spec")))
            return RubyTestFramework.RSpec;
        
        if (exists(buildPath(projectRoot, "test")))
            return RubyTestFramework.Minitest;
        
        return RubyTestFramework.Minitest;
    }
    
    private LanguageBuildResult runMinitest(in Target target, string rubyCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = [rubyCmd, "-Ilib:test"];
        foreach (source; target.sources)
            cmd ~= ["-r", source];
        cmd ~= _currentConfig.test.minitestArgs;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "Minitest failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runRSpec(in Target target, string rubyCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = ["rspec"];
        cmd ~= _currentConfig.test.rspecArgs;
        cmd ~= target.sources;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "RSpec failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runTestUnit(in Target target, string rubyCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = [rubyCmd];
        cmd ~= target.sources;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "Test::Unit failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runCucumber(in Target target, string rubyCmd, string projectRoot)
    {
        LanguageBuildResult result;
        
        import languages.scripting.ruby.tooling.testers.cucumber;
        
        if (!CucumberRunner.isAvailable())
        {
            result.error = "Cucumber not available (install: gem install cucumber)";
            structuredLog.error("log_event").field("message", result.error).emit();
            return result;
        }
        
        structuredLog.info("running_cucumber_bdd_tests").emit();
        
        string[] featureFiles;
        foreach (source; target.sources)
        {
            if (source.endsWith(".feature"))
                featureFiles ~= source;
        }
        
        if (featureFiles.empty)
        {
            auto featuresDir = buildPath(dirName(target.sources.empty ? "." : target.sources[0]), "features");
            if (!exists(featuresDir))
                featuresDir = "features";
            
            if (exists(featuresDir))
            {
                try {
                    foreach (entry; dirEntries(featuresDir, "*.feature", SpanMode.depth))
                        featureFiles ~= entry.name;
                } catch (Exception e) {
                    structuredLog.warning("failed_to_scan_features_directory_")
                        .field("detail", "Failed to scan features directory: " ~ e.msg)
                        .emit();
                }
            }
        }
        
        if (featureFiles.empty)
        {
            structuredLog.warning("no_feature_files_found_skipping_cucumber").emit();
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources);
            return result;
        }
        
        auto cucumberResult = CucumberRunner.runTests(
            featureFiles,
            _currentConfig.test,
            rubyCmd,
            dirName(featureFiles[0])
        );
        
        result.success = cucumberResult.success;
        result.error = cucumberResult.error;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        if (cucumberResult.hasFailures())
        {
            structuredLog.error("cucumber_tests_failed").emit();
            structuredLog.error("__scenarios_")
                .field("detail", "  Scenarios: " ~ cucumberResult.scenariosPassed.to!string ~ "/" ~ 
                            cucumberResult.scenarios.to!string ~ " passed")
                .emit();
        }
        else if (cucumberResult.scenarios > 0)
        {
            structuredLog.info("all_cucumber_tests_passed").emit();
        }
        
        return result;
    }
    
    private auto typeCheckWithCache(in Target target, RubyConfig config)
    {
        auto actionId = ActionId(target.name, ActionType.Custom, FastHash.hashStrings(target.sources), "typecheck");
        actionId.inputHash = FastHash.hashStrings(target.sources);
        
        string[string] metadata;
        metadata["checker"] = config.typeCheck.checker.to!string;
        
        if (getCache().isCached(actionId, target.sources, metadata))
        {
            structuredLog.debug_("__cached_type_checking").emit();
            return TypeCheckResult();
        }
        
        auto checker = TypeCheckerFactory.create(config.typeCheck.checker);
        auto result = checker.check(target.sources, config.typeCheck);
        
        getCache().update(actionId, target.sources, [], metadata, !result.hasErrors());
        
        return result;
    }
}
