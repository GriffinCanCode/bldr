module languages.scripting.go.core.handler;

import std.stdio;
import std.process : Config, environment;
import infrastructure.utils.security : execute;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import languages.base.base;
import languages.base.mixins;
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
class GoHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"go";
    mixin ConfigParsingMixin!(GoConfig, "parseGoConfig", ["go", "goConfig"]);
    mixin SimpleBuildOrchestrationMixin!(GoConfig, "parseGoConfig");
    
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
    
    private void enhanceConfigFromProject(
        ref GoConfig config,
        const Target target,
        const WorkspaceConfig workspace
    ) @system
    {
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        auto goModPath = ModuleAnalyzer.findGoMod(sourceDir);
        if (!goModPath.empty && config.modMode == GoModMode.Auto)
        {
            config.modMode = GoModMode.On;
            structuredLog.debug_("detected_gomod_at_").field("detail", "Detected go.mod at: " ~ goModPath).emit();
            
            auto mod = ModuleAnalyzer.parseGoMod(goModPath);
            if (mod.isValid())
            {
                structuredLog.debug_("module_path_").field("detail", "Module path: " ~ mod.path).emit();
                structuredLog.debug_("go_version_").field("detail", "Go version: " ~ mod.goVersion).emit();
                
                if (config.modPath.empty)
                    config.modPath = mod.path;
            }
        }
        
        auto goWorkPath = ModuleAnalyzer.findGoWork(sourceDir);
        if (!goWorkPath.empty)
        {
            structuredLog.debug_("detected_gowork_at_").field("detail", "Detected go.work at: " ~ goWorkPath).emit();
            
            auto ws = ModuleAnalyzer.parseGoWork(goWorkPath);
            if (ws.isValid())
                structuredLog.debug_("workspace_modules_").field("detail", "Workspace modules: " ~ ws.use.join(", ")).emit();
        }
        
        if (!config.cgo.enabled)
        {
            foreach (source; target.sources)
            {
                if (exists(source) && hasCGoCode(source))
                {
                    structuredLog.debug_("detected_cgo_code_in_").field("detail", "Detected CGO code in: " ~ source).emit();
                    config.cgo.enabled = true;
                    break;
                }
            }
        }
    }
    
    private LanguageBuildResult buildExecutable(
        const Target target,
        const WorkspaceConfig config,
        GoConfig goConfig
    ) @system
    {
        LanguageBuildResult result;
        
        if (target.sources.length == 0)
        {
            result.error = "No source files specified for target " ~ target.name;
            return result;
        }
        
        auto builder = GoBuilderFactory.createAuto(goConfig, getCache());
        
        if (!builder.isAvailable())
        {
            result.error = "Go compiler not available. Install from: https://golang.org/dl/";
            return result;
        }
        
        structuredLog.debug_("using_builder_").field("detail", "Using builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        auto buildResult = builder.build(target.sources, goConfig, target, config);
        
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
    
    private LanguageBuildResult buildLibrary(
        const Target target,
        const WorkspaceConfig config,
        GoConfig goConfig
    ) @system
    {
        goConfig.mode = GoBuildMode.Library;
        
        auto builder = GoBuilderFactory.createAuto(goConfig, getCache());
        
        if (!builder.isAvailable())
        {
            LanguageBuildResult result;
            result.error = "Go compiler not available";
            return result;
        }
        
        structuredLog.debug_("building_go_librarypackage").emit();
        
        auto buildResult = builder.build(target.sources, goConfig, target, config);
        
        LanguageBuildResult result;
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        return result;
    }
    
    private LanguageBuildResult runTests(
        const Target target,
        const WorkspaceConfig config,
        GoConfig goConfig
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
        
        cmd ~= goConfig.test.toFlags();
        
        auto allTags = goConfig.buildTags ~ goConfig.constraints.tags;
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
        
        structuredLog.info("running_go_tests_").field("detail", "Running Go tests: " ~ cmd.join(" ")).emit();
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        if (goConfig.cgo.enabled)
        {
            foreach (key, value; goConfig.cgo.toEnv())
                env[key] = value;
        }
        
        if (goConfig.cross.isCross())
        {
            foreach (key, value; goConfig.cross.toEnv())
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
        
        if (goConfig.test.coverage && !goConfig.test.coverProfile.empty)
        {
            auto coverPath = buildPath(workDir, goConfig.test.coverProfile);
            if (exists(coverPath))
                result.outputs ~= coverPath;
        }
        
        return result;
    }
    
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
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        auto spec = getLanguageSpec(TargetLanguage.Go);
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
