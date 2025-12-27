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
import languages.base.base;
import languages.base.mixins;
import languages.scripting.gleam.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process : isCommandAvailable;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Gleam language build handler with action-level caching
class GleamHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"gleam";
    mixin ConfigParsingMixin!(GleamConfig, "parseGleamConfig", ["gleam", "gleamConfig"]);
    mixin SimpleBuildOrchestrationMixin!(GleamConfig, "parseGleamConfig");
    
    private void enhanceConfigFromProject(
        ref GleamConfig config,
        in Target target,
        in WorkspaceConfig workspace
    ) @system
    {
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        // Auto-detect from gleam.toml if it exists
        string gleamTomlPath = buildPath(sourceDir, "gleam.toml");
        if (exists(gleamTomlPath))
        {
            try
            {
                auto content = readText(gleamTomlPath);
                parseGleamToml(content, config);
                structuredLog.debug_("parsed_gleamtoml_configuration").emit();
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_gleamtoml_").field("detail", "Failed to parse gleam.toml: " ~ e.msg).emit();
            }
        }
    }
    
    /// Parse gleam.toml for project settings
    private void parseGleamToml(string content, ref GleamConfig config) @system
    {
        // Simple TOML parsing for key settings
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
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        GleamConfig gleamConfig = parseGleamConfig(target);
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            // Gleam outputs BEAM or JS files in build/ directory
            // Use gleam.toml as the build marker since it's a file (not directory)
            string projectDir = getProjectDir(target);
            string gleamToml = buildPath(projectDir, "gleam.toml");
            if (exists(gleamToml) && isFile(gleamToml))
                outputs ~= gleamToml;
        }
        
        return outputs;
    }
    
    /// Build executable target
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        GleamConfig gleamConfig
    ) @system
    {
        return buildProject(target, config, gleamConfig);
    }
    
    /// Build library target
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        GleamConfig gleamConfig
    ) @system
    {
        gleamConfig.projectType = GleamProjectType.Library;
        return buildProject(target, config, gleamConfig);
    }
    
    /// Build project with gleam build
    private LanguageBuildResult buildProject(
        in Target target,
        in WorkspaceConfig config,
        GleamConfig gleamConfig
    ) @system
    {
        LanguageBuildResult result;
        
        // Validate gleam is available
        if (!isGleamAvailable(gleamConfig))
        {
            result.error = "Gleam is not installed or not in PATH";
            return result;
        }
        
        // Get project directory
        string projectDir = getProjectDir(target);
        
        // Auto-format if enabled
        if (gleamConfig.format.enabled && !gleamConfig.format.check)
        {
            auto formatResult = runFormat(gleamConfig, projectDir);
            if (!formatResult.success)
            {
                structuredLog.warning("format_failed_").field("detail", "Format failed: " ~ formatResult.error).emit();
            }
        }
        
        // Build cache key
        ActionId buildActionId;
        buildActionId.targetId = target.name;
        buildActionId.type = ActionType.Compile;
        buildActionId.subId = gleamConfig.target == GleamTarget.JavaScript ? "js" : "erlang";
        buildActionId.inputHash = FastHash.hashStrings(target.sources);
        
        string[string] buildMetadata;
        buildMetadata["target"] = gleamConfig.target.to!string;
        buildMetadata["projectType"] = gleamConfig.projectType.to!string;
        
        // Check cache
        if (getCache().isCached(buildActionId, target.sources, buildMetadata))
        {
            structuredLog.info("__cached_gleam_build").emit();
            result.success = true;
            result.outputHash = buildActionId.inputHash;
            return result;
        }
        
        // Build command
        string[] cmd = [gleamConfig.runtime.gleamPath, "build"];
        
        if (gleamConfig.target == GleamTarget.JavaScript)
            cmd ~= ["--target", "javascript"];
        
        if (gleamConfig.warningsAsErrors)
            cmd ~= "--warnings-as-errors";
        
        structuredLog.info("building_gleam_project_").field("detail", "Building Gleam project: " ~ cmd.join(" ")).emit();
        
        // Set up environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        foreach (key, value; gleamConfig.env)
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
        
        // Generate docs if configured
        if (gleamConfig.docs.enabled)
        {
            auto docsResult = runDocs(gleamConfig, projectDir);
            if (!docsResult.success)
            {
                structuredLog.warning("documentation_generation_failed_").field("detail", "Documentation generation failed: " ~ docsResult.error).emit();
            }
        }
        
        return result;
    }
    
    /// Run tests
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        GleamConfig gleamConfig
    ) @system
    {
        LanguageBuildResult result;
        
        if (!isGleamAvailable(gleamConfig))
        {
            result.error = "Gleam is not installed or not in PATH";
            return result;
        }
        
        string projectDir = getProjectDir(target);
        
        // Build test command
        string[] cmd = [gleamConfig.runtime.gleamPath, "test"];
        
        if (gleamConfig.target == GleamTarget.JavaScript)
            cmd ~= ["--target", "javascript"];
        
        structuredLog.info("running_gleam_tests_").field("detail", "Running Gleam tests: " ~ cmd.join(" ")).emit();
        
        // Set up environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        foreach (key, value; gleamConfig.env)
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
    
    /// Run formatter
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
    
    /// Run documentation generator
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
    
    /// Check if Gleam is available
    private bool isGleamAvailable(GleamConfig config) @system
    {
        return isCommandAvailable(config.runtime.gleamPath);
    }
    
    /// Get project directory from target sources
    private string getProjectDir(in Target target) @system
    {
        if (target.sources.empty)
            return ".";
        
        // Find gleam.toml to locate project root
        string dir = dirName(target.sources[0]);
        
        while (dir != "/" && dir != ".")
        {
            if (exists(buildPath(dir, "gleam.toml")))
                return dir;
            dir = dirName(dir);
        }
        
        // Fall back to source directory
        return target.sources.empty ? "." : dirName(target.sources[0]);
    }
    
    /// Analyze Gleam import statements
    override Import[] analyzeImports(in string[] sources) @system
    {
        auto spec = getLanguageSpec(TargetLanguage.Gleam);
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

