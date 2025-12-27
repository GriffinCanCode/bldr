module languages.compiled.haskell.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.regex;
import languages.compiled.base;
import languages.compiled.haskell.core.config;
import languages.compiled.haskell.tooling.ghc;
import languages.compiled.haskell.tooling.cabal;
import languages.compiled.haskell.tooling.stack;
import languages.compiled.haskell.analysis.cabal : parseCabalFile;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Haskell build handler with GHC, Cabal, and Stack support
class HaskellHandler : BaseCompiledLanguageHandler
{
    private HaskellConfig _config;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override string languageName() const pure nothrow @safe => "Haskell";
    
    override string[] fileExtensions() const pure nothrow @safe => [".hs", ".lhs"];
    
    override bool detectToolchain() @system
    {
        // Check for any available build tool
        if (StackWrapper.isAvailable()) return true;
        if (CabalWrapper.isAvailable()) return true;
        return GHCWrapper.isAvailable();
    }
    
    override string getToolchainVersion() @system
    {
        if (_config.buildTool == HaskellBuildTool.Stack && StackWrapper.isAvailable())
            return "Stack " ~ StackWrapper.getVersion();
        if (_config.buildTool == HaskellBuildTool.Cabal && CabalWrapper.isAvailable())
            return "Cabal " ~ CabalWrapper.getVersion();
        if (GHCWrapper.isAvailable())
            return "GHC " ~ GHCWrapper.getVersion();
        return "unknown";
    }
    
    override void parseConfig(in Target target, in WorkspaceConfig config) @system
    {
        _config = HaskellConfig.init;
        
        string configKey = "haskell" in target.langConfig ? "haskell" :
                          ("hs" in target.langConfig ? "hs" : "");
        
        if (!configKey.empty)
        {
            try { _config = HaskellConfig.fromJSON(parseJSON(target.langConfig[configKey])); }
            catch (Exception e) { structuredLog.warning("failed_to_parse_haskell_config").field("error", e.msg).emit(); }
        }
        
        if (_config.outputDir.empty)
            _config.outputDir = config.options.outputDir;
    }
    
    override FormatResult formatSources(in string[] sources) @system
    {
        FormatResult result;
        result.success = true;
        
        string[] hsFiles = sources.filter!(s => extension(s) == ".hs").array;
        if (hsFiles.empty) return result;
        
        if (_config.ormolu && GHCWrapper.isOroluAvailable())
        {
            structuredLog.debug_("running_ormolu").emit();
            GHCWrapper.runOrmolu(hsFiles);
        }
        else if (_config.fourmolu && GHCWrapper.isFourmoluAvailable())
        {
            structuredLog.debug_("running_fourmolu").emit();
            GHCWrapper.runFourmolu(hsFiles);
        }
        
        return result;
    }
    
    override LintResult lintSources(in string[] sources) @system
    {
        LintResult result;
        result.success = true;
        
        if (!_config.hlint || !GHCWrapper.isHLintAvailable())
            return result;
        
        string[] hsFiles = sources.filter!(s => extension(s) == ".hs").array;
        if (hsFiles.empty) return result;
        
        auto lintResult = GHCWrapper.runHLint(hsFiles);
        result.success = lintResult.success;
        result.hadIssues = !lintResult.hlintIssues.empty;
        result.issues = lintResult.hlintIssues.dup;
        
        return result;
    }
    
    override CompiledLanguageResult compileTarget(
        in Target target,
        in WorkspaceConfig config,
        in string[] sources
    ) @system
    {
        CompiledLanguageResult result;
        
        // Auto-detect build tool if needed
        if (_config.buildTool == HaskellBuildTool.Auto)
            _config.buildTool = detectBuildTool(config.root);
        
        // Auto-detect entry point
        if (_config.entry.empty && !sources.empty)
            _config.entry = findMainFile(sources);
        
        // Build based on target type and tool
        final switch (target.type)
        {
            case TargetType.Library:
                _config.mode = HaskellBuildMode.Library;
                break;
            case TargetType.Test:
                _config.mode = HaskellBuildMode.Test;
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                _config.mode = HaskellBuildMode.Custom;
                break;
            case TargetType.Executable:
                _config.mode = HaskellBuildMode.Compile;
                break;
        }
        
        // Compile based on build tool
        final switch (_config.buildTool)
        {
            case HaskellBuildTool.Auto:
                result.error = "Build tool not resolved";
                return result;
            case HaskellBuildTool.GHC:
                return buildWithGHC(target, config);
            case HaskellBuildTool.Cabal:
                return buildWithCabal(target, config);
            case HaskellBuildTool.Stack:
                return buildWithStack(target, config);
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        if (!target.outputPath.empty)
            return [buildPath(config.options.outputDir, target.outputPath)];
        return [buildPath(config.options.outputDir, target.name.split(":")[$ - 1])];
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        Import[] imports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source)) continue;
            
            try
            {
                auto content = readText(source);
                auto importRe = regex(r"^\s*import\s+(?:qualified\s+)?([A-Z][A-Za-z0-9._]*)", "m");
                size_t lineNum = 1;
                
                foreach (line; content.lineSplitter)
                {
                    auto match = line.matchFirst(importRe);
                    if (!match.empty && match.length >= 2)
                    {
                        Import imp;
                        imp.moduleName = match[1];
                        imp.kind = ImportKind.External;
                        imp.location = SourceLocation(source, lineNum, 0);
                        imports ~= imp;
                    }
                    lineNum++;
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports").field("file", source).field("error", e.msg).emit();
            }
        }
        
        return imports;
    }
    
    // ===== Private Helpers =====
    
    private CompiledLanguageResult buildWithGHC(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        
        if (!GHCWrapper.isAvailable())
        {
            result.error = "GHC not found. Install from: https://www.haskell.org/ghcup/";
            return result;
        }
        
        structuredLog.debug_("using_ghc").field("version", GHCWrapper.getVersion()).emit();
        auto compileResult = GHCWrapper.compile(target, config, _config, actionCache);
        
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.outputs = compileResult.outputs.dup;
        result.outputHash = compileResult.outputHash;
        result.hadWarnings = compileResult.hadWarnings;
        result.warnings = compileResult.warnings.dup;
        
        return result;
    }
    
    private CompiledLanguageResult buildWithCabal(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        
        if (!CabalWrapper.isAvailable())
        {
            result.error = "Cabal not found. Install from: https://www.haskell.org/ghcup/";
            return result;
        }
        
        structuredLog.debug_("using_cabal").field("version", CabalWrapper.getVersion()).emit();
        auto compileResult = CabalWrapper.build(target, config, _config, actionCache);
        
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.outputs = compileResult.outputs.dup;
        result.outputHash = compileResult.outputHash;
        result.hadWarnings = compileResult.hadWarnings;
        result.warnings = compileResult.warnings.dup;
        
        return result;
    }
    
    private CompiledLanguageResult buildWithStack(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        
        if (!StackWrapper.isAvailable())
        {
            result.error = "Stack not found. Install from: https://docs.haskellstack.org/";
            return result;
        }
        
        structuredLog.debug_("using_stack").field("version", StackWrapper.getVersion()).emit();
        auto compileResult = StackWrapper.build(target, config, _config, actionCache);
        
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.outputs = compileResult.outputs.dup;
        result.outputHash = compileResult.outputHash;
        result.hadWarnings = compileResult.hadWarnings;
        result.warnings = compileResult.warnings.dup;
        
        return result;
    }
    
    private HaskellBuildTool detectBuildTool(string projectRoot) @system
    {
        if (exists(buildPath(projectRoot, "stack.yaml")))
        {
            structuredLog.debug_("detected_stack_project").emit();
            return HaskellBuildTool.Stack;
        }
        
        if (!dirEntries(projectRoot, "*.cabal", SpanMode.shallow).empty)
        {
            structuredLog.debug_("detected_cabal_project").emit();
            return HaskellBuildTool.Cabal;
        }
        
        structuredLog.debug_("no_build_tool_using_ghc").emit();
        return HaskellBuildTool.GHC;
    }
    
    private string findMainFile(in string[] sources) @system
    {
        // Look for Main.hs
        foreach (source; sources)
        {
            string base = baseName(source);
            if (base == "Main.hs" || base == "main.hs")
                return source;
        }
        
        // Look for file with Main module
        foreach (source; sources)
        {
            if (extension(source) == ".hs" && hasMainModule(source))
                return source;
        }
        
        // Fallback
        foreach (source; sources)
            if (extension(source) == ".hs") return source;
        
        return sources.length > 0 ? sources[0] : "";
    }
    
    private bool hasMainModule(string filepath) @system
    {
        if (!exists(filepath)) return false;
        
        try
        {
            auto content = readText(filepath);
            auto mainModuleRe = regex(r"^\s*module\s+Main\s", "m");
            return !content.matchFirst(mainModuleRe).empty;
        }
        catch (Exception) { return false; }
    }
}
