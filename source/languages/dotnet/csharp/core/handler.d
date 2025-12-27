module languages.dotnet.csharp.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.base.base;
import languages.base.mixins;
import languages.dotnet.csharp.core.config;
import languages.dotnet.csharp.config.test : CSharpTestFramework;
import languages.dotnet.csharp.managers;
import languages.dotnet.csharp.tooling.detection;
import languages.dotnet.csharp.tooling.info;
import languages.dotnet.csharp.tooling.builders;
import languages.dotnet.csharp.tooling.formatters;
import languages.dotnet.csharp.tooling.analyzers;
import languages.dotnet.csharp.tooling.testers;
import languages.dotnet.csharp.analysis;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// C# build handler with action-level caching
class CSharpHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"csharp";
    mixin ConfigParsingMixin!(CSharpConfig, "parseCSharpConfig", ["csharp", "csConfig"]);
    mixin SimpleBuildOrchestrationMixin!(CSharpConfig, "parseCSharpConfig");
    
    private void enhanceConfigFromProject(
        ref CSharpConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        // Detect and enhance configuration from project structure
        BuildToolFactory.enhanceConfigFromProject(config, workspace.root);
        
        // Validate .NET installation
        if (!DotNetToolDetection.isDotNetAvailable() && config.buildTool != CSharpBuildTool.CSC)
        {
            structuredLog.warning("dotnet_cli_not_found_please_install_net_").emit();
        }
        
        // Check .NET version
        auto dotnetVersion = DotNetInfo.getVersion();
        if (dotnetVersion.empty)
        {
            structuredLog.warning("could_not_determine_net_version").emit();
        }
        else
        {
            structuredLog.info("using_net_").field("detail", "Using .NET " ~ dotnetVersion).emit();
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        string[] outputs;
        
        auto csConfig = parseCSharpConfig(target);
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Determine extension based on mode and target type
            string ext;
            if (csConfig.mode == CSharpBuildMode.NativeAOT || csConfig.mode == CSharpBuildMode.SingleFile)
            {
                version(Windows)
                    ext = ".exe";
                else
                    ext = "";
            }
            else if (target.type == TargetType.Library)
            {
                ext = ".dll";
            }
            else
            {
                ext = ".exe";
            }
            
            outputs ~= buildPath(config.options.outputDir, name ~ ext);
        }
        
        return outputs;
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        CSharpConfig csConfig
    )
    {
        LanguageBuildResult result;
        
        // Use build tool if configured
        if (csConfig.buildTool != CSharpBuildTool.Direct && csConfig.buildTool != CSharpBuildTool.None)
        {
            return buildWithBuildTool(target, config, csConfig);
        }
        
        // Restore NuGet packages if configured
        if (csConfig.nuget.autoRestore && DotNetToolDetection.hasProjectFile(config.root))
        {
            if (!NuGetOps.restore(config.root, csConfig.nuget))
            {
                structuredLog.warning("nuget_restore_had_issues_continuing_anyw").emit();
            }
        }
        
        // Auto-format if configured
        if (csConfig.formatter.autoFormat && csConfig.formatter.formatter != CSharpFormatter.None)
        {
            structuredLog.info("autoformatting_code").emit();
            auto formatter = CSharpFormatterFactory.create(csConfig.formatter.formatter, config.root);
            auto formatResult = formatter.format(target.sources.dup, csConfig.formatter, config.root, csConfig.formatter.checkOnly);
            
            if (!formatResult.success)
            {
                if (csConfig.formatter.verifyNoChanges)
                {
                    result.error = "Formatting verification failed: " ~ formatResult.error;
                    return result;
                }
                structuredLog.warning("formatting_failed_continuing_anyway").emit();
            }
        }
        
        // Run static analysis if configured
        if (csConfig.analysis.enabled && csConfig.analysis.analyzer != CSharpAnalyzer.None)
        {
            structuredLog.info("running_static_analysis").emit();
            auto analyzer = CSharpAnalyzerFactory.create(csConfig.analysis.analyzer, config.root);
            auto analysisResult = analyzer.analyze(target.sources.dup, csConfig.analysis, config.root);
            
            if (analysisResult.hasErrors() && csConfig.analysis.failOnErrors)
            {
                result.error = "Static analysis found errors:\n" ~ analysisResult.errors.join("\n");
                return result;
            }
            
            if (analysisResult.hasWarnings())
            {
                structuredLog.warning("static_analysis_warnings").emit();
                foreach (warning; analysisResult.warnings)
                {
                    structuredLog.warning("__").field("detail", "  " ~ warning).emit();
                }
                
                if (csConfig.analysis.failOnWarnings)
                {
                    result.error = "Static analysis warnings treated as errors";
                    return result;
                }
            }
        }
        
        // Build using appropriate builder with action cache
        auto builder = CSharpBuilderFactory.create(csConfig.mode, csConfig, getCache());
        
        if (!builder.isAvailable())
        {
            result.error = "Builder " ~ builder.name() ~ " not available";
            return result;
        }
        
        auto buildResult = builder.build(target.sources.dup, csConfig, target, config);
        
        if (!buildResult.success)
        {
            result.error = buildResult.error;
            return result;
        }
        
        result.success = true;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        CSharpConfig csConfig
    )
    {
        LanguageBuildResult result;
        
        // Libraries use standard build mode
        if (csConfig.mode == CSharpBuildMode.NativeAOT || csConfig.mode == CSharpBuildMode.SingleFile)
        {
            structuredLog.warning("converting_incompatible_build_mode_to_st").emit();
            csConfig.mode = CSharpBuildMode.Standard;
        }
        
        return buildExecutable(target, config, csConfig);
    }
    
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        CSharpConfig csConfig
    )
    {
        LanguageBuildResult result;
        
        structuredLog.info("running_c_tests").emit();
        
        // Use build tool for testing if available
        if (csConfig.buildTool == CSharpBuildTool.DotNet && DotNetToolDetection.hasProjectFile(config.root))
        {
            if (!DotNetOps.test(config.root, csConfig.test))
            {
                result.error = "dotnet test failed";
                return result;
            }
        }
        else if (csConfig.buildTool == CSharpBuildTool.MSBuild && MSBuildToolDetection.hasMSBuildFile(config.root))
        {
            if (!MSBuildOps.test(config.root, csConfig.test))
            {
                result.error = "MSBuild test failed";
                return result;
            }
        }
        else
        {
            // Run tests directly
            auto testResult = runTestsDirect(target, config, csConfig);
            if (!testResult.success)
                return testResult;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources.dup);
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(
        in Target target,
        in WorkspaceConfig config,
        CSharpConfig csConfig
    )
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources.dup);
        return result;
    }
    
    private LanguageBuildResult buildWithBuildTool(
        const Target target,
        const WorkspaceConfig config,
        CSharpConfig csConfig
    )
    {
        LanguageBuildResult result;
        
        final switch (csConfig.buildTool)
        {
            case CSharpBuildTool.DotNet:
                if (!DotNetOps.build(config.root, csConfig))
                {
                    result.error = "dotnet build failed";
                    return result;
                }
                break;
            
            case CSharpBuildTool.MSBuild:
                if (!MSBuildOps.build(config.root, csConfig))
                {
                    result.error = "MSBuild failed";
                    return result;
                }
                break;
            
            case CSharpBuildTool.Direct:
                // Direct CSC compilation
                result.error = "Direct CSC compilation not yet supported";
                return result;
            
            case CSharpBuildTool.Auto:
            case CSharpBuildTool.CSC:
            case CSharpBuildTool.None:
                // Fall back to direct compilation
                return buildExecutable(target, config, csConfig);
        }
        
        // Find output artifacts
        auto outputs = getOutputs(target, config);
        
        if (outputs.length > 0 && exists(outputs[0]))
        {
            result.success = true;
            result.outputs = outputs;
            result.outputHash = FastHash.hashFile(outputs[0]);
        }
        else
        {
            result.error = "Build succeeded but output not found";
        }
        
        return result;
    }
    
    private LanguageBuildResult runTestsDirect(
        const Target target,
        const WorkspaceConfig config,
        CSharpConfig csConfig
    )
    {
        LanguageBuildResult result;
        
        structuredLog.info("running_tests_directly").emit();
        
        // Auto-detect test framework if not specified
        CSharpTestFramework framework = csConfig.test.framework;
        if (framework == CSharpTestFramework.Auto)
        {
            // Try to detect from project file
            auto projectFiles = findProjectFiles(config.root);
            if (!projectFiles.empty)
            {
                framework = detectTestFramework(projectFiles[0]);
                if (framework == CSharpTestFramework.None)
                {
                    structuredLog.warning("could_not_detect_test_framework_trying_x").emit();
                    framework = CSharpTestFramework.XUnit;
                }
            }
            else
            {
                framework = CSharpTestFramework.XUnit; // Default
            }
        }
        
        // Create test runner
        auto testRunner = TestRunnerFactory.create(framework);
        
        if (!testRunner.isAvailable())
        {
            result.error = testRunner.name() ~ " test runner not available";
            structuredLog.warning("log_event").field("message", result.error ~ ", falling back to 'dotnet test'").emit();
            
            // Try dotnet test as fallback
            if (DotNetOps.test(config.root, csConfig.test))
            {
                result.success = true;
                result.outputHash = FastHash.hashStrings(target.sources.dup);
                return result;
            }
            return result;
        }
        
        structuredLog.info("using_").field("detail", "Using " ~ testRunner.name() ~ " test runner").emit();
        
        // Convert TestConfig to the format expected by test runners
        import languages.dotnet.csharp.config.test : TestConfig;
        TestConfig testConfig;
        testConfig.enabled = csConfig.test.enabled;
        testConfig.framework = csConfig.test.framework;
        testConfig.filter = csConfig.test.filter;
        testConfig.resultsDirectory = csConfig.test.resultsDirectory;
        testConfig.logger = csConfig.test.logger;
        testConfig.collectCoverage = csConfig.test.coverage;
        testConfig.coverageFormat = csConfig.test.coverageTool;
        testConfig.minCoverage = cast(int)csConfig.test.minCoverage;
        
        // Run tests
        auto testResult = testRunner.runTests(target.sources, testConfig, config.root);
        
        if (!testResult.success)
        {
            result.error = testResult.error;
            structuredLog.error("tests_failed").emit();
            structuredLog.error("__error_").field("detail", "  Error: " ~ testResult.error).emit();
            return result;
        }
        
        // Log test summary
        if (testResult.failed > 0)
        {
            structuredLog.warning("some_tests_failed_").field("detail", "Some tests failed: " ~ testResult.failed.to!string ~ " / " ~ 
                          (testResult.passed + testResult.failed).to!string).emit();
            result.error = "Test failures detected";
            return result;
        }
        
        structuredLog.info("all_tests_passed_").field("detail", "All tests passed: " ~ testResult.passed.to!string ~ " tests").emit();
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources.dup);
        
        return result;
    }
    
    /// Find project files in directory
    private string[] findProjectFiles(string dir)
    {
        import std.file : dirEntries, SpanMode;
        
        string[] projects;
        try {
            foreach (entry; dirEntries(dir, "*.csproj", SpanMode.depth))
                projects ~= entry.name;
        } catch (Exception) {}
        
        return projects;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.CSharp);
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

