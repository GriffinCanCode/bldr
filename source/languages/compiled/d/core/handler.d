module languages.compiled.d.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv : to;
import languages.compiled.base;
import languages.compiled.d.core.config;
import languages.compiled.d.analysis.manifest;
import infrastructure.toolchain;
import languages.compiled.d.tooling.tools;
import languages.compiled.d.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Advanced D build handler with dub, compiler detection, and tooling support
class DHandler : BaseCompiledLanguageHandler
{
    private DConfig _config;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override protected string languageId() const pure nothrow => "d";
    
    override protected TargetLanguage languageType() const pure nothrow => TargetLanguage.D;
    
    override protected string[] configKeys() const pure nothrow => ["d", "dConfig"];
    
    override protected string toolchainNotFoundError() const pure nothrow =>
        "D compiler not available. Install from https://dlang.org/download.html";
    
    override protected string detectToolchain(in Target target, in WorkspaceConfig config) @system
    {
        _config = parseDConfig(target);
        
        // Auto-detect compiler using unified toolchain
        if (_config.compiler == DCompiler.Auto)
        {
            _config.compiler = detectBestCompiler();
            structuredLog.debug_("autodetected_compiler_").field("detail", "Auto-detected: " ~ compilerToString(_config.compiler)).emit();
        }
        
        // Verify compiler available
        if (!isCompilerAvailable(_config.compiler, _config.customCompiler))
            return "";
        
        return compilerToString(_config.compiler);
    }
    
    // ===== Build Methods =====
    
    override protected LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.outputType = OutputType.Executable;
        
        if (_config.entry.empty && !target.sources.empty)
        {
            // Look for main.d or app.d first
            foreach (source; target.sources)
            {
                auto base = baseName(source, ".d");
                if (base == "main" || base == "app")
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
        if (_config.outputType == OutputType.Executable)
            _config.outputType = OutputType.StaticLib;
        
        if (_config.entry.empty && !target.sources.empty)
        {
            // Look for lib.d or package.d first
            foreach (source; target.sources)
            {
                auto base = baseName(source, ".d");
                if (base == "lib" || base == "package")
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
        _config.mode = DBuildMode.Test;
        _config.compilerConfig.unittest_ = true;
        
        if (_config.buildConfig != BuildConfig.UnittestCov)
            _config.buildConfig = BuildConfig.Unittest;
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.mode = DBuildMode.Custom;
        return compileTarget(target, config);
    }
    
    // ===== Tooling =====
    
    override protected bool shouldFormat(in Target target) const @system => _config.tooling.runFmt;
    override protected bool shouldLint(in Target target) const @system => _config.tooling.runLint;
    
    override protected CompiledLanguageResult runFormatter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!DFormatter.isAvailable())
        {
            structuredLog.warning("dfmt_not_available_skipping").emit();
            return result;
        }
        
        structuredLog.info("running_dfmt_formatter").emit();
        
        auto res = DFormatter.format(target.sources, _config.tooling.fmtConfig, _config.tooling.fmtCheckOnly);
        if (res.status != 0)
        {
            structuredLog.warning("dfmt_failed_").field("detail", "dfmt failed: " ~ res.output).emit();
            result.hadWarnings = true;
            result.warnings = [res.output];
        }
        else if (_config.tooling.fmtCheckOnly)
            structuredLog.info("format_check_completed").emit();
        else
            structuredLog.info("code_formatted_successfully").emit();
        
        return result;
    }
    
    override protected CompiledLanguageResult runLinter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!DScanner.isAvailable())
        {
            structuredLog.warning("dscanner_not_available_skipping").emit();
            return result;
        }
        
        structuredLog.info("running_dscanner_linter").emit();
        
        auto res = DScanner.lint(
            target.sources,
            _config.tooling.lintConfig,
            _config.tooling.lintStyleCheck,
            _config.tooling.lintSyntaxCheck,
            _config.tooling.lintReport
        );
        
        if (res.status != 0 || !res.output.empty)
        {
            result.hadLintIssues = true;
            foreach (line; res.output.split("\n"))
            {
                if (!line.empty && (line.canFind("Warning:") || line.canFind("Error:")))
                    result.lintIssues ~= line;
            }
        }
        else
            structuredLog.info("no_lint_issues_found").emit();
        
        return result;
    }
    
    override protected string resolveOutputDir(in Target target, in WorkspaceConfig config) const @system
    {
        return _config.outputDir.empty ? config.options.outputDir : _config.outputDir;
    }
    
    override protected string getOutputName(string name, TargetType type) const pure nothrow
    {
        string outputName = _config.outputName.empty ? name : _config.outputName;
        return outputName;
    }
    
    // ===== Private Implementation =====
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config) @system
    {
        auto builder = DBuilderFactory.create(_config, actionCache);
        
        if (!builder.isAvailable())
            return errorResult("D builder '" ~ builder.name() ~ "' not available. Install from https://dlang.org/download.html");
        
        structuredLog.debug_("using_d_builder_").field("detail", "Using D builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        auto compileResult = builder.build(target.sources, _config, target, config);
        
        if (!compileResult.success)
            return errorResult(compileResult.error);
        
        if (compileResult.hadWarnings)
            reportWarnings(compileResult.warnings);
        
        // Report coverage if enabled
        if (_config.test.coverage && compileResult.coveragePercent > 0.0)
        {
            structuredLog.info("code_coverage_").field("detail", "Code coverage: " ~ to!string(compileResult.coveragePercent) ~ "%").emit();
            if (_config.test.minCoverage > 0.0 && compileResult.coveragePercent < _config.test.minCoverage)
                structuredLog.warning("coverage_below_min_").field("detail", "Coverage below minimum: " ~ to!string(_config.test.minCoverage) ~ "%").emit();
        }
        
        return successResult(compileResult.outputs, compileResult.artifacts, compileResult.outputHash);
    }
    
    private DConfig parseDConfig(in Target target) @system
    {
        DConfig config;
        
        auto json = parseTargetConfig(target);
        if (json != JSONValue.init)
        {
            try { config = DConfig.fromJSON(json); }
            catch (Exception e)
                structuredLog.warning("failed_to_parse_d_config_").field("detail", "Using defaults: " ~ e.msg).emit();
        }
        
        // Auto-detect dub.json/dub.sdl
        if (config.dub.packagePath.empty)
        {
            config.dub.packagePath = DubManifest.findManifest(target.sources.dup);
            if (!config.dub.packagePath.empty)
            {
                structuredLog.debug_("found_dub_package_").field("detail", "Found DUB package: " ~ config.dub.packagePath).emit();
                if (config.mode == DBuildMode.Compile)
                    config.mode = DBuildMode.Dub;
            }
        }
        
        // Auto-detect entry point
        if (config.entry.empty && !target.sources.empty)
            config.entry = target.sources[0];
        
        // Apply target flags
        if (!target.flags.empty)
            config.compilerConfig.optimizationFlags ~= target.flags;
        
        return config;
    }
    
    private DCompiler detectBestCompiler() @system
    {
        auto registry = ToolchainRegistry.instance();
        registry.initialize();
        
        // Priority: LDC > DMD > GDC
        if (!registry.getByName("ldc").empty)
            return DCompiler.LDC;
        if (!registry.getByName("dmd").empty)
            return DCompiler.DMD;
        if (!registry.getByName("gdc").empty)
            return DCompiler.GDC;
        
        return DCompiler.Auto;
    }
    
    private bool isCompilerAvailable(DCompiler compiler, string customPath) @system
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        
        if (compiler == DCompiler.Custom)
            return !customPath.empty && exists(customPath);
        
        final switch (compiler)
        {
            case DCompiler.Auto:
                return true;
            case DCompiler.LDC:
                return !ExecutableDetector.findInPath("ldc2").empty;
            case DCompiler.DMD:
                return !ExecutableDetector.findInPath("dmd").empty;
            case DCompiler.GDC:
                return !ExecutableDetector.findInPath("gdc").empty;
            case DCompiler.Custom:
                return !customPath.empty && exists(customPath);
        }
    }
    
    private string compilerToString(DCompiler compiler) pure nothrow
    {
        final switch (compiler)
        {
            case DCompiler.Auto: return "auto";
            case DCompiler.LDC: return "ldc2";
            case DCompiler.DMD: return "dmd";
            case DCompiler.GDC: return "gdc";
            case DCompiler.Custom: return "custom";
        }
    }
}
