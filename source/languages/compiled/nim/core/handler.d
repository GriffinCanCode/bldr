module languages.compiled.nim.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.uni : toLower;
import languages.compiled.base;
import languages.compiled.nim.core.config;
import languages.compiled.nim.builders;
import languages.compiled.nim.tooling.tools;
import languages.compiled.nim.analysis.nimble;
import languages.compiled.nim.managers.nimble;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Nim build handler with multi-backend support
class NimHandler : BaseCompiledLanguageHandler
{
    private NimConfig _config;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override string languageName() const pure nothrow @safe => "Nim";
    
    override string[] fileExtensions() const pure nothrow @safe => [".nim", ".nims"];
    
    override bool detectToolchain() @system => NimTools.isCompilerAvailable();
    
    override string getToolchainVersion() @system => NimTools.getVersion();
    
    override void parseConfig(in Target target, in WorkspaceConfig config) @system
    {
        _config = NimConfig.init;
        
        string configKey = "nim" in target.langConfig ? "nim" :
                          ("nimConfig" in target.langConfig ? "nimConfig" : "");
        
        if (!configKey.empty)
        {
            try { _config = NimConfig.fromJSON(parseJSON(target.langConfig[configKey])); }
            catch (Exception e) { structuredLog.warning("failed_to_parse_nim_config").field("error", e.msg).emit(); }
        }
        
        // Apply target flags if not in langConfig
        if (!target.flags.empty && configKey.empty)
            _config.compilerFlags ~= target.flags;
        
        // Enhance config from project
        if (!target.sources.empty)
            enhanceConfigFromProject(target, config);
    }
    
    override FormatResult formatSources(in string[] sources) @system
    {
        FormatResult result;
        result.success = true;
        
        if (!_config.runFormat) return result;
        
        auto fmtResult = NimTools.format(
            sources.dup,
            _config.formatCheck,
            _config.formatIndent,
            _config.formatMaxLineLen
        );
        
        result.success = !fmtResult.hasIssues;
        result.hadIssues = fmtResult.hasIssues;
        result.warnings = fmtResult.warnings.dup;
        
        return result;
    }
    
    override LintResult lintSources(in string[] sources) @system
    {
        LintResult result;
        result.success = true;
        
        if (!_config.runCheck) return result;
        
        auto checkResult = NimTools.check(sources.dup);
        result.success = checkResult.success;
        result.hadIssues = !checkResult.errors.empty;
        result.issues = checkResult.errors.dup;
        
        return result;
    }
    
    override CompiledLanguageResult compileTarget(
        in Target target,
        in WorkspaceConfig config,
        in string[] sources
    ) @system
    {
        CompiledLanguageResult result;
        
        // Install dependencies if requested
        if (_config.nimble.enabled && _config.nimble.installDeps)
        {
            string projectDir = sources.empty ? "." : dirName(sources[0]);
            NimbleManager.installDependencies(projectDir, _config.nimble.devMode, _config.verbose);
        }
        
        // Auto-detect entry point
        if (_config.entry.empty && !sources.empty)
            _config.entry = findEntryFile(sources);
        
        // Set mode based on target type
        final switch (target.type)
        {
            case TargetType.Library:
                if (_config.appType != AppType.StaticLib && _config.appType != AppType.DynamicLib)
                    _config.appType = AppType.StaticLib;
                break;
            case TargetType.Test:
                _config.mode = NimBuildMode.Test;
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                _config.mode = NimBuildMode.Custom;
                break;
            case TargetType.Executable:
                if (_config.appType != AppType.Console && _config.appType != AppType.Gui)
                    _config.appType = AppType.Console;
                break;
        }
        
        // Create builder and compile
        auto builder = NimBuilderFactory.create(_config.builder, _config, actionCache);
        
        if (!builder.isAvailable())
        {
            result.error = "Nim compiler not available. Install from: https://nim-lang.org/install.html";
            return result;
        }
        
        structuredLog.debug_("using_nim_builder").field("name", builder.name()).field("version", builder.getVersion()).emit();
        
        auto compileResult = builder.build(sources, _config, target, config);
        
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.outputs = compileResult.outputs ~ compileResult.artifacts;
        result.outputHash = compileResult.outputHash;
        result.hadWarnings = compileResult.hadWarnings;
        result.warnings = compileResult.warnings.dup;
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        string outputDir = _config.outputDir.empty ? config.options.outputDir : _config.outputDir;
        
        if (!target.outputPath.empty)
            return [buildPath(outputDir, target.outputPath)];
        
        auto name = target.name.split(":")[$ - 1];
        return [buildPath(outputDir, name ~ getOutputExtension())];
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Nim);
        if (spec is null) return [];
        
        Import[] imports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source)) continue;
            
            try
            {
                auto content = readText(source);
                imports ~= spec.scanImports(source, content);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports").field("file", source).emit();
            }
        }
        
        return imports;
    }
    
    // ===== Private Helpers =====
    
    private void enhanceConfigFromProject(in Target target, in WorkspaceConfig workspace) @system
    {
        string sourceDir = dirName(target.sources[0]);
        
        if (_config.builder == NimBuilderType.Auto || _config.nimble.enabled)
        {
            string nimbleFile = NimbleParser.findNimbleFile(sourceDir);
            if (!nimbleFile.empty)
            {
                structuredLog.debug_("detected_nimble_file").field("path", nimbleFile).emit();
                _config.nimble.nimbleFile = nimbleFile;
                
                auto nimbleData = NimbleParser.parseNimbleFile(nimbleFile);
                if (!nimbleData.name.empty && !nimbleData.backend.empty && _config.backend == NimBackend.C)
                {
                    switch (nimbleData.backend.toLower)
                    {
                        case "cpp": case "c++": _config.backend = NimBackend.Cpp; break;
                        case "js": case "javascript": _config.backend = NimBackend.Js; break;
                        case "objc": case "objective-c": _config.backend = NimBackend.ObjC; break;
                        default: break;
                    }
                }
            }
        }
    }
    
    private string findEntryFile(in string[] sources) @system
    {
        foreach (candidate; ["main.nim", "lib.nim"])
            foreach (source; sources)
                if (baseName(source) == candidate) return source;
        
        // Check nimble file for entry
        string nimbleFile = NimbleParser.findNimbleFile(".");
        if (!nimbleFile.empty)
        {
            auto nimbleData = NimbleParser.parseNimbleFile(nimbleFile);
            if (!nimbleData.name.empty)
            {
                string libFile = nimbleData.name ~ ".nim";
                foreach (source; sources)
                    if (baseName(source) == libFile) return source;
            }
        }
        
        return sources.length > 0 ? sources[0] : "";
    }
    
    private string getOutputExtension() @system
    {
        if (_config.backend == NimBackend.Js) return ".js";
        
        if (_config.appType == AppType.StaticLib)
        {
            version(Windows) return ".lib";
            else return ".a";
        }
        
        if (_config.appType == AppType.DynamicLib)
        {
            version(Windows) return ".dll";
            else version(OSX) return ".dylib";
            else return ".so";
        }
        
        version(Windows) return ".exe";
        else return "";
    }
}
