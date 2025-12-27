module languages.compiled.base;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.json;
import languages.base.base;
import languages.base.compiled;
import languages.base.types;
import languages.base.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// Common compile result structure for all compiled languages
struct CompiledLanguageResult
{
    bool success;
    string error;
    string[] outputs;
    string[] artifacts;
    string outputHash;
    bool hadWarnings;
    string[] warnings;
    bool hadLintIssues;
    string[] lintIssues;
}

/// Base handler for compiled languages (Rust, Zig, D, Swift, etc.)
/// Provides common build workflow: config→detect→format→lint→compile→link→test
abstract class BaseCompiledLanguageHandler : BaseCompiledHandler
{
    this(ActionCache cache = null) { super(cache); }
    
    /// Build the target with full context
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_target_").field("detail", "Building " ~ languageId() ~ " target: " ~ target.name).emit();
        
        // Detect and validate toolchain
        auto toolPath = detectToolchain(target, config);
        if (toolPath.empty && requiresToolchain())
        {
            result.error = toolchainNotFoundError();
            return result;
        }
        
        if (!toolPath.empty)
            structuredLog.info("using_toolchain_").field("detail", "Using " ~ languageId() ~ " toolchain: " ~ toolPath).emit();
        
        // Run formatter if requested
        if (shouldFormat(target))
        {
            auto fmtResult = runFormatter(target, config);
            if (fmtResult.hadWarnings)
            {
                structuredLog.info("formatting_issues_found").emit();
                foreach (warning; fmtResult.warnings[0 .. min(5, $)])
                    structuredLog.warning("__").field("detail", "  " ~ warning).emit();
            }
        }
        
        // Run linter if requested
        if (shouldLint(target))
        {
            auto lintResult = runLinter(target, config);
            if (lintResult.hadLintIssues)
            {
                structuredLog.warning("linter_found_issues").emit();
                foreach (issue; lintResult.lintIssues[0 .. min(5, $)])
                    structuredLog.warning("__").field("detail", "  " ~ issue).emit();
            }
        }
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, toolPath);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, toolPath);
                break;
            case TargetType.Test:
                result = buildAndRunTests(target, config, toolPath);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, toolPath);
                break;
        }
        
        // Record dependencies for incremental compilation
        if (context.depRecorder !is null && result.success)
            recordDependencies(target, config, context.depRecorder);
        
        return result;
    }
    
    /// Get outputs for target
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        string outDir = resolveOutputDir(target, config);
        
        if (!target.outputPath.empty)
            return [buildPath(outDir, target.outputPath)];
        
        auto name = target.name.split(":")[$ - 1];
        string outputName = getOutputName(name, target.type);
        
        return [buildPath(outDir, outputName)];
    }
    
    /// Analyze imports in source files
    override Import[] analyzeImports(in string[] sources) @system
    {
        auto spec = getLanguageSpec(languageType());
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
                allImports ~= spec.scanImports(source, content);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_").field("detail", "Failed to analyze imports in " ~ source).emit();
            }
        }
        return allImports;
    }
    
    // ========== Abstract methods to be implemented by subclasses ==========
    
    /// Language identifier (e.g., "rust", "zig", "d")
    protected abstract override string languageId() const pure nothrow;
    
    /// Language type for spec lookup
    protected abstract TargetLanguage languageType() const pure nothrow;
    
    /// Config keys to try when parsing (e.g., ["rust", "rustConfig"])
    protected abstract string[] configKeys() const pure nothrow;
    
    /// Error message when toolchain not found
    protected abstract string toolchainNotFoundError() const pure nothrow;
    
    /// Detect toolchain/compiler path
    protected abstract string detectToolchain(in Target target, in WorkspaceConfig config) @system;
    
    /// Build executable
    protected abstract LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, string toolPath) @system;
    
    /// Build library
    protected abstract LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, string toolPath) @system;
    
    /// Build and run tests
    protected abstract LanguageBuildResult buildAndRunTests(in Target target, in WorkspaceConfig config, string toolPath) @system;
    
    // ========== Optional overrides ==========
    
    /// Whether toolchain is required (default: true)
    protected bool requiresToolchain() const pure nothrow => true;
    
    /// Whether to run formatter (override to check config)
    protected bool shouldFormat(in Target target) const @system => false;
    
    /// Whether to run linter (override to check config)  
    protected bool shouldLint(in Target target) const @system => false;
    
    /// Run formatter (override to implement)
    protected CompiledLanguageResult runFormatter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        return result;
    }
    
    /// Run linter (override to implement)
    protected CompiledLanguageResult runLinter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        return result;
    }
    
    /// Build custom target (default: success with hash)
    protected LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources.dup);
        return result;
    }
    
    /// Record dependencies for incremental builds (override to implement)
    protected void recordDependencies(in Target target, in WorkspaceConfig config, DependencyRecorder recorder) @system
    {
        // Default: no-op, subclasses can override
    }
    
    /// Get output name with appropriate extension
    protected string getOutputName(string name, TargetType type) const pure nothrow
    {
        string ext = "";
        string prefix = "";
        
        final switch (type)
        {
            case TargetType.Executable:
            case TargetType.Test:
                version(Windows) ext = ".exe";
                break;
            case TargetType.Library:
                version(Windows) { prefix = ""; ext = ".lib"; }
                else { prefix = "lib"; ext = ".a"; }
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                break;
        }
        
        return prefix ~ name ~ ext;
    }
    
    /// Resolve output directory
    protected string resolveOutputDir(in Target target, in WorkspaceConfig config) const @system
    {
        // Subclasses can override to check language-specific config
        return config.options.outputDir;
    }
    
    // ========== Helper methods ==========
    
    /// Parse JSON config from target with fallback keys
    protected JSONValue parseTargetConfig(in Target target) const @system
    {
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try { return parseJSON(target.langConfig[key]); }
                catch (Exception) { continue; }
            }
        }
        return JSONValue.init;
    }
    
    /// Report compilation warnings
    protected void reportWarnings(string[] warnings, size_t maxShow = 5) @system
    {
        if (warnings.empty) return;
        
        structuredLog.warning("compilation_warnings").emit();
        foreach (warn; warnings[0 .. min(maxShow, $)])
            structuredLog.warning("__").field("detail", "  " ~ warn).emit();
        
        if (warnings.length > maxShow)
            structuredLog.warning("___and_more_").field("detail", "  ... and " ~ (warnings.length - maxShow).to!string ~ " more warnings").emit();
    }
    
    /// Create success result from compile output
    protected LanguageBuildResult successResult(string[] outputs, string[] artifacts, string hash) pure nothrow
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputs = outputs ~ artifacts;
        result.outputHash = hash;
        return result;
    }
    
    /// Create error result
    protected LanguageBuildResult errorResult(string message) pure nothrow
    {
        LanguageBuildResult result;
        result.error = message;
        return result;
    }
}

