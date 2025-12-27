module languages.scripting.gleam.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.string;
import languages.scripting.base;
import languages.scripting.gleam.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process : isCommandAvailable;
import infrastructure.utils.security : execute;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Gleam language build handler with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class GleamHandler : BaseScriptingHandler
{
    private GleamConfig _currentConfig;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "gleam";
    
    override protected string[] configKeys() const pure nothrow @safe => ["gleam", "gleamConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.Gleam;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        GleamConfig gleamConfig = GleamConfig.fromJSON(config);
        _currentConfig = gleamConfig;
        
        if (!isGleamAvailable(gleamConfig))
            return EnvironmentSetupResult.fail("Gleam is not installed or not in PATH");
        
        return EnvironmentSetupResult.ok(gleamConfig.runtime.gleamPath);
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        // Gleam build will handle syntax validation
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        GleamConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = GleamConfig.fromJSON(json);
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
        
        string gleamTomlPath = buildPath(sourceDir, "gleam.toml");
        if (exists(gleamTomlPath))
        {
            try
            {
                auto content = readText(gleamTomlPath);
                parseGleamToml(content, _currentConfig);
                structuredLog.debug_("parsed_gleamtoml_configuration").emit();
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_gleamtoml_")
                    .field("detail", "Failed to parse gleam.toml: " ~ e.msg)
                    .emit();
            }
        }
    }
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.format.enabled && !_currentConfig.format.check;
    
    // Gleam doesn't have traditional pre-build steps
    override protected ScriptingStepResult preBuildSteps(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        // Auto-format if enabled
        if (shouldAutoFormat(langConfig))
        {
            string projectDir = getProjectDir(target);
            auto formatResult = runFormat(_currentConfig, projectDir);
            if (!formatResult.success)
                structuredLog.warning("format_failed_")
                    .field("detail", "Format failed: " ~ formatResult.error)
                    .emit();
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
            string projectDir = getProjectDir(target);
            string gleamToml = buildPath(projectDir, "gleam.toml");
            if (exists(gleamToml) && isFile(gleamToml))
                outputs ~= gleamToml;
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
        return buildProject(target, config, interpreterCmd);
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        _currentConfig.projectType = GleamProjectType.Library;
        return buildProject(target, config, interpreterCmd);
    }
    
    private LanguageBuildResult buildProject(
        in Target target,
        in WorkspaceConfig config,
        string interpreterCmd
    ) @system
    {
        LanguageBuildResult result;
        
        string projectDir = getProjectDir(target);
        
        // Build cache key
        ActionId buildActionId;
        buildActionId.targetId = target.name;
        buildActionId.type = ActionType.Compile;
        buildActionId.subId = _currentConfig.target == GleamTarget.JavaScript ? "js" : "erlang";
        buildActionId.inputHash = FastHash.hashStrings(target.sources);
        
        string[string] buildMetadata;
        buildMetadata["target"] = _currentConfig.target.to!string;
        buildMetadata["projectType"] = _currentConfig.projectType.to!string;
        
        if (getCache().isCached(buildActionId, target.sources, buildMetadata))
        {
            structuredLog.info("__cached_gleam_build").emit();
            result.success = true;
            result.outputHash = buildActionId.inputHash;
            return result;
        }
        
        string[] cmd = [_currentConfig.runtime.gleamPath, "build"];
        
        if (_currentConfig.target == GleamTarget.JavaScript)
            cmd ~= ["--target", "javascript"];
        
        if (_currentConfig.warningsAsErrors)
            cmd ~= "--warnings-as-errors";
        
        structuredLog.info("building_gleam_project_")
            .field("detail", "Building Gleam project: " ~ cmd.join(" "))
            .emit();
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        foreach (key, value; _currentConfig.env)
            env[key] = value;
        
        auto res = execute(cmd, env, Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            result.error = "Gleam build failed:\n" ~ res.output;
            getCache().update(buildActionId, target.sources, [], buildMetadata, false);
            return result;
        }
        
        result.success = true;
        result.outputs = getOutputs(target, config);
        result.outputHash = FastHash.hashStrings(target.sources);
        
        getCache().update(buildActionId, target.sources, result.outputs, buildMetadata, true);
        
        // Generate docs if configured (post-build)
        if (_currentConfig.docs.enabled)
        {
            auto docsResult = runDocs(_currentConfig, projectDir);
            if (!docsResult.success)
                structuredLog.warning("documentation_generation_failed_")
                    .field("detail", "Documentation generation failed: " ~ docsResult.error)
                    .emit();
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
        
        string projectDir = getProjectDir(target);
        
        string[] cmd = [_currentConfig.runtime.gleamPath, "test"];
        
        if (_currentConfig.target == GleamTarget.JavaScript)
            cmd ~= ["--target", "javascript"];
        
        structuredLog.info("running_gleam_tests_")
            .field("detail", "Running Gleam tests: " ~ cmd.join(" "))
            .emit();
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        foreach (key, value; _currentConfig.env)
            env[key] = value;
        
        auto res = execute(cmd, env, Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            result.error = "Gleam tests failed:\n" ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GLEAM-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private void parseGleamToml(string content, ref GleamConfig config) @system
    {
        foreach (line; content.splitLines)
        {
            line = line.strip;
            if (line.empty || line.startsWith("#"))
                continue;
            
            auto parts = line.findSplit("=");
            if (parts[1].empty)
                continue;
            
            string key = parts[0].strip;
            string value = parts[2].strip.strip("\"");
            
            switch (key)
            {
                case "target":
                    if (value == "javascript")
                        config.target = GleamTarget.JavaScript;
                    break;
                case "name":
                    if (config.hex.name.empty)
                        config.hex.name = value;
                    break;
                case "version":
                    if (config.hex.version_.empty)
                        config.hex.version_ = value;
                    break;
                default:
                    break;
            }
        }
    }
    
    private struct FormatResult
    {
        bool success;
        string error;
    }
    
    private FormatResult runFormat(GleamConfig config, string projectDir) @system
    {
        FormatResult result;
        
        string[] cmd = [config.runtime.gleamPath, "format"];
        
        if (config.format.check)
            cmd ~= "--check";
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectDir);
        
        result.success = res.status == 0;
        if (!result.success)
            result.error = res.output;
        
        return result;
    }
    
    private struct DocsResult
    {
        bool success;
        string error;
    }
    
    private DocsResult runDocs(GleamConfig config, string projectDir) @system
    {
        DocsResult result;
        
        string[] cmd = [config.runtime.gleamPath, "docs", "build"];
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectDir);
        
        result.success = res.status == 0;
        if (!result.success)
            result.error = res.output;
        
        return result;
    }
    
    private bool isGleamAvailable(GleamConfig config) @system
        => isCommandAvailable(config.runtime.gleamPath);
    
    private string getProjectDir(in Target target) @system
    {
        if (target.sources.empty)
            return ".";
        
        string dir = dirName(target.sources[0]);
        
        while (dir != "/" && dir != ".")
        {
            if (exists(buildPath(dir, "gleam.toml")))
                return dir;
            dir = dirName(dir);
        }
        
        return target.sources.empty ? "." : dirName(target.sources[0]);
    }
}
