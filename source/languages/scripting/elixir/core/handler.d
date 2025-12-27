module languages.scripting.elixir.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import languages.scripting.base;
import languages.scripting.elixir.config;
import languages.scripting.elixir.managers;
import languages.scripting.elixir.tooling;
import languages.scripting.elixir.analysis;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Elixir build handler with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class ElixirHandler : BaseScriptingHandler
{
    private ElixirConfig _currentConfig;
    private string _currentElixirCmd;
    private string _currentMixCmd;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "elixir";
    
    override protected string[] configKeys() const pure nothrow @safe => ["elixir", "elixirConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.Elixir;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        ElixirConfig elixirConfig = ElixirConfig.fromJSON(config);
        _currentConfig = elixirConfig;
        
        string elixirCmd = "elixir";
        
        if (!elixirConfig.elixirVersion.elixirPath.empty)
            elixirCmd = elixirConfig.elixirVersion.elixirPath;
        else if (elixirConfig.elixirVersion.useAsdf)
        {
            auto vm = new AsdfVersionManager(projectRoot);
            if (vm.isAvailable())
            {
                elixirCmd = vm.getElixirPath();
                structuredLog.info("using_elixir_from_asdf_")
                    .field("detail", "Using Elixir from asdf: " ~ vm.getCurrentVersion())
                    .emit();
            }
        }
        
        if (!ElixirTools.isElixirAvailable(elixirCmd))
        {
            structuredLog.warning("elixir_not_available_at_")
                .field("detail", "Elixir not available at: " ~ elixirCmd ~ ", falling back to 'elixir'")
                .emit();
            elixirCmd = "elixir";
        }
        
        auto version_ = ElixirTools.getElixirVersion(elixirCmd);
        structuredLog.debug_("using_elixir_")
            .field("detail", "Using Elixir: " ~ elixirCmd ~ " (" ~ version_ ~ ")")
            .emit();
        
        _currentElixirCmd = elixirCmd;
        _currentMixCmd = setupMixCommand(elixirConfig, projectRoot);
        
        return EnvironmentSetupResult.ok(elixirCmd);
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        // Elixir compilation handles syntax validation
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        ElixirConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = ElixirConfig.fromJSON(json);
                    _currentConfig = config;
                    return json;
                }
                catch (Exception e)
                {
                    structuredLog.warning("failed_to_parse_elixir_config_using_defa")
                        .field("detail", "Failed to parse Elixir config, using defaults: " ~ e.msg)
                        .emit();
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
        
        // Auto-detect project type
        if (_currentConfig.projectType == ElixirProjectType.MixProject)
        {
            auto detectedType = ProjectDetector.detectProjectType(sourceDir);
            if (detectedType != ElixirProjectType.MixProject)
            {
                _currentConfig.projectType = detectedType;
                structuredLog.debug_("detected_project_type_")
                    .field("detail", "Detected project type: " ~ detectedType.to!string)
                    .emit();
            }
        }
        
        // Parse mix.exs
        string mixExsPath = buildPath(sourceDir, _currentConfig.project.mixExsPath);
        if (exists(mixExsPath))
        {
            auto mixInfo = MixProjectParser.parse(mixExsPath);
            
            if (_currentConfig.project.name.empty && !mixInfo.name.empty)
                _currentConfig.project.name = mixInfo.name;
            
            if (_currentConfig.project.app.empty && !mixInfo.app.empty)
                _currentConfig.project.app = mixInfo.app;
            
            if (_currentConfig.project.version_.empty && !mixInfo.version_.empty)
                _currentConfig.project.version_ = mixInfo.version_;
            
            structuredLog.debug_("parsed_mix_project_")
                .field("detail", "Parsed Mix project: " ~ mixInfo.app)
                .emit();
        }
        
        // Check for Phoenix
        if (ProjectDetector.isPhoenixProject(sourceDir))
        {
            _currentConfig.phoenix.enabled = true;
            structuredLog.debug_("detected_phoenix_application").emit();
            
            if (ProjectDetector.hasLiveView(sourceDir))
            {
                _currentConfig.phoenix.liveView = true;
                structuredLog.debug_("detected_phoenix_liveview").emit();
            }
        }
        
        // Check for umbrella
        if (ProjectDetector.isUmbrellaProject(sourceDir))
        {
            _currentConfig.projectType = ElixirProjectType.Umbrella;
            auto apps = ProjectDetector.getUmbrellaApps(sourceDir, _currentConfig.umbrella.appsDir);
            if (!apps.empty)
            {
                _currentConfig.umbrella.apps = apps;
                structuredLog.debug_("detected_umbrella_apps_")
                    .field("detail", "Detected umbrella apps: " ~ apps.join(", "))
                    .emit();
            }
        }
        
        // Check for .tool-versions
        string toolVersionsPath = buildPath(sourceDir, ".tool-versions");
        if (exists(toolVersionsPath))
        {
            auto versions = VersionManager.parseToolVersions(toolVersionsPath);
            if ("elixir" in versions)
                structuredLog.debug_("found_elixir_version_in_toolversions_")
                    .field("detail", "Found Elixir version in .tool-versions: " ~ versions["elixir"])
                    .emit();
        }
    }
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.format.enabled;
    
    override protected ScriptingStepResult preBuildSteps(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        // Pre-build steps for Elixir
        if (!preBuildMixSteps(_currentConfig, config.root, _currentMixCmd))
            return ScriptingStepResult.fail("Pre-build steps failed");
        
        // Auto-format if configured
        if (_currentConfig.format.enabled)
        {
            structuredLog.info("autoformatting_code").emit();
            auto formatResult = Formatter.format(
                _currentConfig.format,
                target.sources,
                _currentMixCmd,
                _currentConfig.format.checkFormatted
            );
            
            if (!formatResult.success && _currentConfig.format.checkFormatted)
                return ScriptingStepResult.fail("Code is not properly formatted");
            
            if (formatResult.hasIssues())
            {
                foreach (issue; formatResult.issues)
                    structuredLog.warning("__").field("detail", "  " ~ issue).emit();
            }
        }
        
        // Run Credo if configured
        if (_currentConfig.credo.enabled)
        {
            structuredLog.info("running_credo_static_analysis").emit();
            auto credoResult = CredoChecker.check(_currentConfig.credo, _currentMixCmd);
            
            if (credoResult.hasErrors())
                return ScriptingStepResult.fail("Credo found critical issues:\n" ~ credoResult.errors.join("\n"));
            
            if (credoResult.hasWarnings())
            {
                structuredLog.warning("credo_warnings").emit();
                foreach (warning; credoResult.warnings)
                    structuredLog.warning("__").field("detail", "  " ~ warning).emit();
            }
        }
        
        return ScriptingStepResult.ok();
    }
    
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
            
            final switch (_currentConfig.projectType)
            {
                case ElixirProjectType.Script:
                    outputs ~= target.sources;
                    break;
                case ElixirProjectType.Escript:
                    outputs ~= buildPath(config.options.outputDir, name);
                    break;
                case ElixirProjectType.MixProject:
                case ElixirProjectType.Phoenix:
                case ElixirProjectType.PhoenixLiveView:
                case ElixirProjectType.Library:
                    string buildDir = _currentConfig.project.buildPath;
                    string envDir = envToString(_currentConfig.env);
                    outputs ~= buildPath(buildDir, envDir, "lib");
                    break;
                case ElixirProjectType.Umbrella:
                    string buildDir = _currentConfig.project.buildPath;
                    string envDir = envToString(_currentConfig.env);
                    foreach (app; _currentConfig.umbrella.apps)
                        outputs ~= buildPath(buildDir, envDir, "lib", app);
                    break;
                case ElixirProjectType.Nerves:
                    outputs ~= buildPath(config.options.outputDir, name ~ ".fw");
                    break;
            }
            
            if (_currentConfig.release.type != ReleaseType.None)
                outputs ~= buildPath(_currentConfig.release.path, _currentConfig.release.name);
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
        auto builder = BuilderFactory.create(_currentConfig.projectType, _currentConfig, getCache());
        
        if (!builder.isAvailable())
        {
            LanguageBuildResult result;
            result.error = "Required tools not available for " ~ _currentConfig.projectType.to!string;
            return result;
        }
        
        structuredLog.debug_("using_builder_")
            .field("detail", "Using builder: " ~ builder.name())
            .emit();
        
        auto buildResult = builder.build(target.sources, _currentConfig, target, config);
        
        LanguageBuildResult result;
        result.success = buildResult.success;
        if (!buildResult.errors.empty)
            result.error = buildResult.errors[0];
        result.outputs = buildResult.outputs;
        
        // Post-build steps
        if (result.success)
            postBuildElixirSteps(config.root, buildResult);
        
        return result;
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        if (_currentConfig.projectType == ElixirProjectType.MixProject)
            _currentConfig.projectType = ElixirProjectType.Library;
        
        auto result = buildExecutableImpl(target, config, langConfig, interpreterCmd);
        
        // Generate documentation if configured
        if (result.success && _currentConfig.documentation().enabled)
        {
            structuredLog.info("generating_documentation").emit();
            DocGenerator.generate(_currentConfig.documentation(), _currentMixCmd);
        }
        
        // Build Hex package if configured
        if (result.success && _currentConfig.hex.publish)
        {
            structuredLog.info("building_hex_package").emit();
            HexManager.buildPackage(_currentConfig.hex, _currentMixCmd);
        }
        
        return result;
    }
    
    override protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        LanguageBuildResult result;
        
        string[] cmd = [_currentMixCmd, "test"];
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        env["MIX_ENV"] = "test";
        
        if (_currentConfig.exunit().trace)
            cmd ~= "--trace";
        
        if (_currentConfig.exunit().maxCases > 0)
            cmd ~= ["--max-cases", _currentConfig.exunit().maxCases.to!string];
        
        foreach (tag; _currentConfig.exunit().exclude)
            cmd ~= ["--exclude", tag];
        
        foreach (tag; _currentConfig.exunit().include)
            cmd ~= ["--include", tag];
        
        foreach (tag; _currentConfig.exunit().only)
            cmd ~= ["--only", tag];
        
        if (_currentConfig.exunit().seed > 0)
            cmd ~= ["--seed", _currentConfig.exunit().seed.to!string];
        
        if (_currentConfig.exunit().timeout > 0)
            cmd ~= ["--timeout", _currentConfig.exunit().timeout.to!string];
        
        if (!_currentConfig.exunit().colors)
            cmd ~= "--no-color";
        
        if (!_currentConfig.exunit().testPaths.empty)
            cmd ~= _currentConfig.exunit().testPaths;
        
        structuredLog.info("running_exunit_tests_")
            .field("detail", "Running ExUnit tests: " ~ cmd.join(" "))
            .emit();
        
        auto res = execute(cmd, env, Config.none, size_t.max, config.root);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        // Run coverage if configured
        if (_currentConfig.coveralls().enabled)
        {
            structuredLog.info("generating_test_coverage").emit();
            
            string[] covCmd = [_currentMixCmd, "coveralls"];
            if (!_currentConfig.coveralls().post)
                covCmd ~= ["--local"];
            
            auto covRes = execute(covCmd, env, Config.none, size_t.max, config.root);
            if (covRes.status != 0)
                structuredLog.warning("coverage_generation_failed").emit();
        }
        
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ELIXIR-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private string setupMixCommand(ElixirConfig config, string projectRoot) @system
    {
        string mixCmd = "mix";
        
        string localMix = buildPath(projectRoot, "mix");
        if (exists(localMix))
            mixCmd = localMix;
        
        if (!ElixirTools.isMixAvailable(mixCmd))
            structuredLog.warning("mix_not_available").emit();
        
        return mixCmd;
    }
    
    private bool preBuildMixSteps(ElixirConfig config, string projectRoot, string mixCmd) @system
    {
        // Dependencies are handled by mix automatically during build
        return true;
    }
    
    private void postBuildElixirSteps(string projectRoot, ElixirBuildResult buildResult) @system
    {
        // Run Dialyzer if configured
        if (_currentConfig.dialyzer.enabled)
        {
            structuredLog.info("running_dialyzer").emit();
            auto dialyzerResult = DialyzerChecker.check(_currentConfig.dialyzer, _currentMixCmd);
            
            if (dialyzerResult.hasWarnings())
            {
                structuredLog.warning("dialyzer_warnings").emit();
                foreach (warning; dialyzerResult.warnings)
                    structuredLog.warning("__").field("detail", "  " ~ warning).emit();
            }
        }
        
        // Build release if configured
        if (_currentConfig.release.type != ReleaseType.None)
        {
            structuredLog.info("building_release").emit();
            auto releaseBuilder = ReleaseManager.createBuilder(_currentConfig.release.type);
            if (releaseBuilder.isAvailable())
                releaseBuilder.buildRelease(_currentConfig.release, _currentMixCmd);
        }
        
        // Generate documentation
        if (_currentConfig.documentation().enabled)
        {
            structuredLog.info("generating_documentation").emit();
            DocGenerator.generate(_currentConfig.documentation(), _currentMixCmd);
        }
    }
    
    private string envToString(MixEnv env) @system pure nothrow
    {
        final switch (env)
        {
            case MixEnv.Dev: return "dev";
            case MixEnv.Test: return "test";
            case MixEnv.Prod: return "prod";
            case MixEnv.Custom: return "custom";
        }
    }
}
