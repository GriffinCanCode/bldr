module languages.scripting.go.core.handler;

import std.stdio;
import std.process : Config, environment;
import infrastructure.utils.security : execute;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import languages.scripting.base;
import languages.scripting.go.core.config;
import languages.scripting.go.managers.modules;
import languages.scripting.go.tooling.tools;
import languages.scripting.go.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionId, ActionType;

/// Go build handler - modular and extensible with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class GoHandler : BaseScriptingHandler
{
    private GoConfig _currentConfig;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "go";
    
    override protected string[] configKeys() const pure nothrow @safe => ["go", "goConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.Go;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        GoConfig goConfig = GoConfig.fromJSON(config);
        _currentConfig = goConfig;
        
        // Go uses its own toolchain, just verify it's available
        if (!GoTools.isGoAvailable())
            return EnvironmentSetupResult.fail("Go compiler not available. Install from: https://golang.org/dl/");
        
        return EnvironmentSetupResult.ok("go");
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        // Go build will handle syntax validation
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        GoConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = GoConfig.fromJSON(json);
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
        
        auto goModPath = ModuleAnalyzer.findGoMod(sourceDir);
        if (!goModPath.empty && _currentConfig.modMode == GoModMode.Auto)
        {
            _currentConfig.modMode = GoModMode.On;
            structuredLog.debug_("detected_gomod_at_")
                .field("detail", "Detected go.mod at: " ~ goModPath)
                .emit();
            
            auto mod = ModuleAnalyzer.parseGoMod(goModPath);
            if (mod.isValid())
            {
                structuredLog.debug_("module_path_")
                    .field("detail", "Module path: " ~ mod.path)
                    .emit();
                structuredLog.debug_("go_version_")
                    .field("detail", "Go version: " ~ mod.goVersion)
                    .emit();
                
                if (_currentConfig.modPath.empty)
                    _currentConfig.modPath = mod.path;
            }
        }
        
        auto goWorkPath = ModuleAnalyzer.findGoWork(sourceDir);
        if (!goWorkPath.empty)
        {
            structuredLog.debug_("detected_gowork_at_")
                .field("detail", "Detected go.work at: " ~ goWorkPath)
                .emit();
            
            auto ws = ModuleAnalyzer.parseGoWork(goWorkPath);
            if (ws.isValid())
                structuredLog.debug_("workspace_modules_")
                    .field("detail", "Workspace modules: " ~ ws.use.join(", "))
                    .emit();
        }
        
        if (!_currentConfig.cgo.enabled)
        {
            foreach (source; target.sources)
            {
                if (exists(source) && hasCGoCode(source))
                {
                    structuredLog.debug_("detected_cgo_code_in_")
                        .field("detail", "Detected CGO code in: " ~ source)
                        .emit();
                    _currentConfig.cgo.enabled = true;
                    break;
                }
            }
        }
    }
    
    // Go doesn't have traditional pre-build steps like interpreted languages
    override protected ScriptingStepResult preBuildSteps(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
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
            
            version(Windows)
            {
                if (target.type == TargetType.Executable)
                    name ~= ".exe";
            }
            
            outputs ~= buildPath(config.options.outputDir, name);
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
        LanguageBuildResult result;
        
        if (target.sources.length == 0)
        {
            result.error = "No source files specified for target " ~ target.name;
            return result;
        }
        
        auto builder = GoBuilderFactory.createAuto(_currentConfig, getCache());
        
        if (!builder.isAvailable())
        {
            result.error = "Go compiler not available. Install from: https://golang.org/dl/";
            return result;
        }
        
        structuredLog.debug_("using_builder_")
            .field("detail", "Using builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")")
            .emit();
        
        auto buildResult = builder.build(target.sources, _currentConfig, target, config);
        
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        if (!buildResult.toolWarnings.empty)
        {
            structuredLog.info("build_completed_with_warnings_from_tools").emit();
            foreach (warning; buildResult.toolWarnings)
                structuredLog.warning("__").field("detail", "  " ~ warning).emit();
        }
        
        return result;
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        _currentConfig.mode = GoBuildMode.Library;
        
        auto builder = GoBuilderFactory.createAuto(_currentConfig, getCache());
        
        if (!builder.isAvailable())
        {
            LanguageBuildResult result;
            result.error = "Go compiler not available";
            return result;
        }
        
        structuredLog.debug_("building_go_librarypackage").emit();
        
        auto buildResult = builder.build(target.sources, _currentConfig, target, config);
        
        LanguageBuildResult result;
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
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
        
        if (!GoTools.isGoAvailable())
        {
            result.error = "Go not available for running tests";
            return result;
        }
        
        string workDir = config.root;
        if (!target.sources.empty)
            workDir = dirName(target.sources[0]);
        
        string[] cmd = ["go", "test"];
        
        cmd ~= _currentConfig.test.toFlags();
        
        auto allTags = _currentConfig.buildTags ~ _currentConfig.constraints.tags;
        if (!allTags.empty)
        {
            cmd ~= "-tags";
            cmd ~= allTags.join(",");
        }
        
        cmd ~= target.flags;
        
        if (target.sources.empty)
            cmd ~= "./...";
        else
            cmd ~= target.sources;
        
        structuredLog.info("running_go_tests_")
            .field("detail", "Running Go tests: " ~ cmd.join(" "))
            .emit();
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        if (_currentConfig.cgo.enabled)
        {
            foreach (key, value; _currentConfig.cgo.toEnv())
                env[key] = value;
        }
        
        if (_currentConfig.cross.isCross())
        {
            foreach (key, value; _currentConfig.cross.toEnv())
                env[key] = value;
        }
        
        auto res = execute(cmd, env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Go tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        if (_currentConfig.test.coverage && !_currentConfig.test.coverProfile.empty)
        {
            auto coverPath = buildPath(workDir, _currentConfig.test.coverProfile);
            if (exists(coverPath))
                result.outputs ~= coverPath;
        }
        
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // GO-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private bool hasCGoCode(string filePath) @system
    {
        try
        {
            auto content = readText(filePath);
            
            if (content.canFind("/*") && content.canFind("import \"C\""))
                return true;
            if (content.canFind("// #cgo "))
                return true;
            if (content.canFind("import \"C\""))
                return true;
                
            return false;
        }
        catch (Exception e)
        {
            return false;
        }
    }
}
