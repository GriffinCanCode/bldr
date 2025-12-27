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
import languages.base.base;
import languages.base.mixins;
import languages.compiled.d.core.config;
import languages.compiled.d.analysis.manifest;
import infrastructure.toolchain;
import languages.compiled.d.tooling.tools;
import languages.compiled.d.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Advanced D build handler with dub, compiler detection, and tooling support with action-level caching
class DHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"d";
    
    /// Detect best D compiler using unified toolchain
    private DCompiler detectBestDCompiler() @system
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
    
    /// Check if D compiler is available
    private bool isDCompilerAvailable(DCompiler compiler, string customCompiler) @system
    {
        import std.file : exists;
        
        auto registry = ToolchainRegistry.instance();
        registry.initialize();
        
        final switch (compiler)
        {
            case DCompiler.Auto:
                auto result = registry.findFor(Platform.host(), ToolchainType.Compiler);
                return result.isOk;
            case DCompiler.DMD:
                return !registry.getByName("dmd").empty;
            case DCompiler.LDC:
                return !registry.getByName("ldc").empty;
            case DCompiler.GDC:
                return !registry.getByName("gdc").empty;
            case DCompiler.Custom:
                return !customCompiler.empty && exists(customCompiler);
        }
    }
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_d_target_").field("detail", "Building D target: " ~ target.name).emit();
        
        // Parse D configuration
        DConfig dConfig = parseDConfig(target);
        
        // Auto-detect and validate compiler using unified toolchain system
        if (dConfig.compiler == DCompiler.Auto)
        {
            dConfig.compiler = detectBestDCompiler();
            structuredLog.debug_("autodetected_compiler_").field("detail", "Auto-detected compiler: " ~ compilerToString(dConfig.compiler)).emit();
        }
        
        // Check compiler availability
        if (!isDCompilerAvailable(dConfig.compiler, dConfig.customCompiler))
        {
            result.error = "D compiler not available: " ~ compilerToString(dConfig.compiler);
            return result;
        }
        
        // Run formatter if requested
        if (dConfig.tooling.runFmt)
        {
            runFormatter(target, dConfig);
        }
        
        // Run linter if requested
        if (dConfig.tooling.runLint)
        {
            auto lintResult = runLinter(target, dConfig);
            if (lintResult.hadLintIssues)
            {
                structuredLog.warning("linter_found_issues").emit();
                foreach (issue; lintResult.lintIssues)
                {
                    structuredLog.warning("__").field("detail", "  " ~ issue).emit();
                }
            }
        }
        
        // Build based on target type and mode
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, dConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, dConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, dConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, dConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        DConfig dConfig = parseDConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            string outputName = dConfig.outputName.empty ? name : dConfig.outputName;
            outputs ~= buildPath(config.options.outputDir, outputName);
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.D);
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
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, DConfig dConfig)
    {
        LanguageBuildResult result;
        
        // Set output type to executable
        dConfig.outputType = OutputType.Executable;
        
        // Auto-detect entry point if not specified
        if (dConfig.entry.empty && !target.sources.empty)
        {
            // Look for main.d or app.d first
            foreach (source; target.sources)
            {
                auto base = baseName(source, ".d");
                if (base == "main" || base == "app")
                {
                    dConfig.entry = source;
                    break;
                }
            }
            
            // Fallback to first source
            if (dConfig.entry.empty)
                dConfig.entry = target.sources[0];
        }
        
        // Compile
        return compileTarget(target, config, dConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, DConfig dConfig)
    {
        LanguageBuildResult result;
        
        // Set output type to library if not specified
        if (dConfig.outputType == OutputType.Executable)
            dConfig.outputType = OutputType.StaticLib;
        
        // Auto-detect entry point
        if (dConfig.entry.empty && !target.sources.empty)
        {
            // Look for lib.d or package.d first
            foreach (source; target.sources)
            {
                auto base = baseName(source, ".d");
                if (base == "lib" || base == "package")
                {
                    dConfig.entry = source;
                    break;
                }
            }
            
            // Fallback to first source
            if (dConfig.entry.empty)
                dConfig.entry = target.sources[0];
        }
        
        return compileTarget(target, config, dConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, DConfig dConfig)
    {
        LanguageBuildResult result;
        
        // Set mode to test
        dConfig.mode = DBuildMode.Test;
        
        // Enable unittest build
        dConfig.compilerConfig.unittest_ = true;
        
        // Set build config to unittest if not specified
        if (dConfig.buildConfig != BuildConfig.UnittestCov)
            dConfig.buildConfig = BuildConfig.Unittest;
        
        return compileTarget(target, config, dConfig);
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, DConfig dConfig)
    {
        LanguageBuildResult result;
        
        dConfig.mode = DBuildMode.Custom;
        
        return compileTarget(target, config, dConfig);
    }
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config, DConfig dConfig)
    {
        LanguageBuildResult result;
        
        // Create builder with action cache
        auto builder = DBuilderFactory.create(dConfig, actionCache);
        
        if (!builder.isAvailable())
        {
            result.error = "D builder '" ~ builder.name() ~ "' is not available. " ~
                          "Install D compiler from https://dlang.org/download.html";
            return result;
        }
        
        structuredLog.debug_("using_d_builder_").field("detail", "Using D builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        // Compile
        auto compileResult = builder.build(target.sources, dConfig, target, config);
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report warnings
        if (compileResult.hadWarnings)
        {
            structuredLog.warning("compilation_warnings").emit();
            foreach (warn; compileResult.warnings)
            {
                structuredLog.warning("__").field("detail", "  " ~ warn).emit();
            }
        }
        
        // Report coverage if enabled
        if (dConfig.test.coverage && compileResult.coveragePercent > 0.0)
        {
            structuredLog.info("code_coverage_").field("detail", "Code coverage: " ~ to!string(compileResult.coveragePercent) ~ "%").emit();
            
            if (dConfig.test.minCoverage > 0.0 && compileResult.coveragePercent < dConfig.test.minCoverage)
            {
                structuredLog.warning("coverage_below_minimum_threshold_").field("detail", "Coverage below minimum threshold: " ~ 
                             to!string(dConfig.test.minCoverage) ~ "%").emit();
            }
        }
        
        result.success = true;
        result.outputs = compileResult.outputs ~ compileResult.artifacts;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    private DConfig parseDConfig(in Target target)
    {
        DConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("d" in target.langConfig)
            configKey = "d";
        else if ("dConfig" in target.langConfig)
            configKey = "dConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = DConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_d_config_using_defaults_").field("detail", "Failed to parse D config, using defaults: " ~ e.msg).emit();
            }
        }
        
        // Auto-detect dub.json/dub.sdl if not specified
        if (config.dub.packagePath.empty)
        {
            config.dub.packagePath = DubManifest.findManifest(target.sources.dup);
            if (!config.dub.packagePath.empty)
            {
                structuredLog.debug_("found_dub_package_").field("detail", "Found DUB package: " ~ config.dub.packagePath).emit();
                
                // If dub package exists, prefer dub mode
                if (config.mode == DBuildMode.Compile)
                    config.mode = DBuildMode.Dub;
            }
        }
        
        // Auto-detect entry point if not specified
        if (config.entry.empty && !target.sources.empty)
        {
            config.entry = target.sources[0];
        }
        
        // Apply target flags to compiler config
        if (!target.flags.empty)
        {
            config.compilerConfig.optimizationFlags ~= target.flags;
        }
        
        return config;
    }
    
    private DCompiler detectBestCompiler()
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        
        // Prefer LDC for production builds (best optimization)
        if (!ExecutableDetector.findInPath("ldc2").empty)
            return DCompiler.LDC;
        
        // Fall back to DMD (fastest compilation)
        if (!ExecutableDetector.findInPath("dmd").empty)
            return DCompiler.DMD;
        
        // Last resort: GDC
        if (!ExecutableDetector.findInPath("gdc").empty)
            return DCompiler.GDC;
        
        return DCompiler.LDC; // Default, will fail later if not available
    }
    
    private bool isCompilerAvailable(DCompiler compiler, string customPath)
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        import std.range : empty;
        
        if (compiler == DCompiler.Custom)
        {
            import std.file : exists;
            return !customPath.empty && exists(customPath);
        }
        
        final switch (compiler)
        {
            case DCompiler.Auto:
                return true; // Will be resolved
            case DCompiler.LDC:
                return !ExecutableDetector.findInPath("ldc2").empty;
            case DCompiler.DMD:
                return !ExecutableDetector.findInPath("dmd").empty;
            case DCompiler.GDC:
                return !ExecutableDetector.findInPath("gdc").empty;
            case DCompiler.Custom:
                import std.file : exists;
                return !customPath.empty && exists(customPath);
        }
    }
    
    private string compilerToString(DCompiler compiler)
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
    
    private void runFormatter(in Target target, DConfig config)
    {
        if (!DFormatter.isAvailable())
        {
            structuredLog.warning("dfmt_not_available_skipping_formatting").emit();
            return;
        }
        
        structuredLog.info("running_dfmt_formatter").emit();
        
        auto res = DFormatter.format(target.sources, config.tooling.fmtConfig, config.tooling.fmtCheckOnly);
        
        if (res.status != 0)
        {
            structuredLog.warning("dfmt_failed_").field("detail", "dfmt failed: " ~ res.output).emit();
        }
        else if (config.tooling.fmtCheckOnly)
        {
            structuredLog.info("format_check_completed").emit();
        }
        else
        {
            structuredLog.info("code_formatted_successfully").emit();
        }
    }
    
    private DCompileResult runLinter(in Target target, DConfig config)
    {
        DCompileResult result;
        result.success = true;
        
        if (!DScanner.isAvailable())
        {
            structuredLog.warning("dscanner_not_available_skipping_linting").emit();
            return result;
        }
        
        structuredLog.info("running_dscanner_linter").emit();
        
        auto res = DScanner.lint(
            target.sources,
            config.tooling.lintConfig,
            config.tooling.lintStyleCheck,
            config.tooling.lintSyntaxCheck,
            config.tooling.lintReport
        );
        
        if (res.status != 0 || !res.output.empty)
        {
            result.hadLintIssues = true;
            
            // Parse linter output
            foreach (line; res.output.split("\n"))
            {
                if (!line.empty && (line.canFind("Warning:") || line.canFind("Error:")))
                {
                    result.lintIssues ~= line;
                }
            }
        }
        else
        {
            structuredLog.info("no_lint_issues_found").emit();
        }
        
        return result;
    }
}


