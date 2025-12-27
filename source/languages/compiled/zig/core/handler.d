module languages.compiled.zig.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import languages.compiled.base;
import languages.compiled.zig.core.config;
import languages.compiled.zig.analysis.builder;
import languages.compiled.zig.tooling.tools;
import languages.compiled.zig.analysis.targets;
import languages.compiled.zig.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Advanced Zig build handler with build.zig and cross-compilation support
class ZigHandler : BaseCompiledLanguageHandler
{
    private ZigConfig _config;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override protected string languageId() const pure nothrow => "zig";
    
    override protected TargetLanguage languageType() const pure nothrow => TargetLanguage.Zig;
    
    override protected string[] configKeys() const pure nothrow => ["zig", "zigConfig"];
    
    override protected string toolchainNotFoundError() const pure nothrow =>
        "Zig compiler not available. Install from https://ziglang.org/download/";
    
    override protected string detectToolchain(in Target target, in WorkspaceConfig config) @system
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        
        _config = parseZigConfig(target);
        enhanceConfigFromProject(_config, target, config);
        
        return ExecutableDetector.findInPath("zig");
    }
    
    // ===== Build Methods =====
    
    override protected LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.outputType = OutputType.Exe;
        
        if (_config.entry.empty && !target.sources.empty)
        {
            // Look for main.zig first
            foreach (source; target.sources)
            {
                if (baseName(source) == "main.zig")
                {
                    _config.entry = source;
                    break;
                }
            }
            if (_config.entry.empty)
                _config.entry = target.sources[0];
        }
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        if (_config.outputType == OutputType.Exe)
            _config.outputType = OutputType.Lib;
        
        if (_config.entry.empty && !target.sources.empty)
        {
            // Look for lib.zig or root.zig first
            foreach (source; target.sources)
            {
                string basename = baseName(source);
                if (basename == "lib.zig" || basename == "root.zig")
                {
                    _config.entry = source;
                    break;
                }
            }
            if (_config.entry.empty)
                _config.entry = target.sources[0];
        }
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildAndRunTests(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.mode = ZigBuildMode.Test;
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.mode = ZigBuildMode.Custom;
        return compileTarget(target, config);
    }
    
    // ===== Tooling =====
    
    override protected bool shouldFormat(in Target target) const @system => _config.runFmt;
    override protected bool shouldLint(in Target target) const @system => _config.runCheck;
    
    override protected CompiledLanguageResult runFormatter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        auto fmtResult = ZigTools.format(
            target.sources.dup,
            _config.fmtCheck,
            !_config.fmtCheck,
            _config.fmtExclude
        );
        
        if (fmtResult.hasIssues())
        {
            result.hadWarnings = true;
            result.warnings = fmtResult.warnings;
        }
        
        return result;
    }
    
    override protected CompiledLanguageResult runLinter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        auto checkResult = ZigTools.astCheck(target.sources.dup);
        if (!checkResult.success)
        {
            result.hadLintIssues = true;
            result.lintIssues = checkResult.errors;
        }
        
        return result;
    }
    
    override protected string resolveOutputDir(in Target target, in WorkspaceConfig config) const @system
    {
        return _config.outputDir.empty ? config.options.outputDir : _config.outputDir;
    }
    
    override protected string getOutputName(string name, TargetType type) const pure nothrow
    {
        string ext = "";
        version(Windows) { if (type == TargetType.Executable || type == TargetType.Test) ext = ".exe"; }
        return name ~ ext;
    }
    
    // ===== Private Implementation =====
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config) @system
    {
        auto builder = ZigBuilderFactory.create(_config.builder, _config);
        
        if (!builder.isAvailable())
            return errorResult("Zig compiler not available. Install from https://ziglang.org/download/");
        
        structuredLog.debug_("using_zig_builder_").field("detail", "Using Zig builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        auto compileResult = builder.build(target.sources, _config, target, config);
        
        if (!compileResult.success)
            return errorResult(compileResult.error);
        
        if (compileResult.hadWarnings && !compileResult.warnings.empty)
            reportWarnings(compileResult.warnings);
        
        return successResult(compileResult.outputs, compileResult.artifacts, compileResult.outputHash);
    }
    
    private ZigConfig parseZigConfig(in Target target) @system
    {
        ZigConfig config;
        
        auto json = parseTargetConfig(target);
        if (json != JSONValue.init)
        {
            try { config = ZigConfig.fromJSON(json); }
            catch (Exception e)
                structuredLog.warning("failed_to_parse_zig_config_").field("detail", "Using defaults: " ~ e.msg).emit();
        }
        
        return config;
    }
    
    private void enhanceConfigFromProject(ref ZigConfig config, in Target target, in WorkspaceConfig workspace) @system
    {
        if (target.sources.empty && target.root.empty)
            return;
        
        // Determine search directory
        string sourceDir;
        if (!target.root.empty)
        {
            sourceDir = target.root.isAbsolute ? target.root : buildPath(workspace.root, target.root);
            structuredLog.debug_("using_target_root_").field("detail", "Using target root: " ~ sourceDir).emit();
        }
        else if (!target.sources.empty)
            sourceDir = dirName(target.sources[0]);
        else
            sourceDir = workspace.root;
        
        // Auto-detect build.zig
        if (config.builder == ZigBuilderType.Auto)
        {
            auto buildZigPath = BuildZigParser.findBuildZig(sourceDir);
            if (!buildZigPath.empty)
            {
                structuredLog.debug_("detected_buildzig_").field("detail", "Detected build.zig: " ~ buildZigPath).emit();
                config.buildZig.path = buildZigPath.idup;
                config.builder = ZigBuilderType.BuildZig;
                
                auto project = BuildZigParser.parseBuildZig(buildZigPath);
                if (!project.name.empty)
                    structuredLog.debug_("project_").field("detail", "Project: " ~ project.name ~ (project.version_.empty ? "" : " v" ~ project.version_)).emit();
            }
            else
                config.builder = ZigBuilderType.Compile;
        }
        
        // Auto-detect entry point
        if (config.entry.empty && !target.sources.empty)
        {
            foreach (source; target.sources)
            {
                string basename = baseName(source);
                if (basename == "main.zig" || basename == "lib.zig" || basename == "root.zig")
                {
                    config.entry = source.idup;
                    break;
                }
            }
            if (config.entry.empty)
                config.entry = target.sources[0].idup;
        }
        
        TargetManager.initialize();
    }
}
