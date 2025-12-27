module languages.jvm.scala.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.base.base;
import languages.base.mixins;
import languages.jvm.scala.core.config;
import languages.jvm.scala.tooling.builders;
import languages.jvm.scala.tooling.formatters;
import languages.jvm.scala.tooling.checkers;
import languages.jvm.scala.tooling.detection;
import languages.jvm.scala.tooling.info;
import languages.jvm.scala.managers.sbt;
import languages.jvm.scala.managers.mill;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Scala build handler with action-level caching
class ScalaHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"scala";
    mixin ConfigParsingMixin!(ScalaConfig, "parseScalaConfig", ["scala", "scalaConfig"]);
    mixin SimpleBuildOrchestrationMixin!(ScalaConfig, "parseScalaConfig");
    
    private void enhanceConfigFromProject(
        ref ScalaConfig scalaConfig,
        in Target target,
        in WorkspaceConfig config
    )
    {
        // Auto-detect Scala version if not specified
        if (scalaConfig.versionInfo.major == 0 || scalaConfig.versionInfo.minor == 0)
        {
            scalaConfig.versionInfo = ScalaToolDetection.detectScalaVersion(config.root);
        }
        
        // Auto-detect build tool if not specified
        if (scalaConfig.buildTool == ScalaBuildTool.Auto)
        {
            scalaConfig.buildTool = ScalaToolDetection.detectBuildTool(config.root);
            structuredLog.debug_("autodetected_build_tool_").field("detail", "Auto-detected build tool: " ~ scalaConfig.buildTool.to!string).emit();
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Check for special build modes
            ScalaConfig scalaConfig = parseScalaConfig(target);
            
            if (scalaConfig.mode == ScalaBuildMode.ScalaJS)
                outputs ~= buildPath(config.options.outputDir, name ~ ".js");
            else if (scalaConfig.mode == ScalaBuildMode.ScalaNative)
            {
                version(Windows)
                    outputs ~= buildPath(config.options.outputDir, name ~ ".exe");
                else
                    outputs ~= buildPath(config.options.outputDir, name);
            }
            else if (scalaConfig.mode == ScalaBuildMode.Assembly)
                outputs ~= buildPath(config.options.outputDir, name ~ "-assembly.jar");
            else
                outputs ~= buildPath(config.options.outputDir, name ~ ".jar");
        }
        
        return outputs;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, ScalaConfig scalaConfig)
    {
        LanguageBuildResult result;
        
        // Format sources if enabled
        if (scalaConfig.formatter.enabled && scalaConfig.formatter.autoFormat)
        {
            formatSources(target.sources, scalaConfig, config.root);
        }
        
        // Run linter if enabled
        if (scalaConfig.linter.enabled)
        {
            bool lintOk = checkSources(target.sources, scalaConfig, config.root);
            if (!lintOk && scalaConfig.linter.failOnWarnings)
            {
                result.error = "Linter found issues";
                return result;
            }
        }
        
        // Get appropriate builder with action cache
        auto builder = ScalaBuilderFactory.createAuto(scalaConfig, config.root, getCache());
        
        structuredLog.debug_("using_builder_").field("detail", "Using builder: " ~ builder.name()).emit();
        
        // Build
        auto buildResult = builder.build(target.sources, scalaConfig, target, config);
        
        // Convert to LanguageBuildResult
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, ScalaConfig scalaConfig)
    {
        // Libraries are built the same way as executables, just packaged differently
        return buildExecutable(target, config, scalaConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, ScalaConfig scalaConfig)
    {
        LanguageBuildResult result;
        
        if (!scalaConfig.test.enabled)
        {
            structuredLog.info("tests_disabled_in_configuration").emit();
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources);
            return result;
        }
        
        // Detect test framework
        auto framework = scalaConfig.test.framework;
        if (framework == ScalaTestFramework.Auto)
        {
            framework = ScalaToolDetection.detectTestFramework(config.root);
        }
        
        structuredLog.info("running_tests_with_framework_").field("detail", "Running tests with framework: " ~ framework.to!string).emit();
        
        // Use build tool for tests
        bool testsPassed = false;
        
        final switch (scalaConfig.buildTool)
        {
            case ScalaBuildTool.SBT:
                testsPassed = SbtOps.test(config.root);
                break;
            
            case ScalaBuildTool.Mill:
                testsPassed = MillOps.test(config.root);
                break;
            
            case ScalaBuildTool.ScalaCLI:
            case ScalaBuildTool.Direct:
            case ScalaBuildTool.Maven:
            case ScalaBuildTool.Gradle:
            case ScalaBuildTool.Bloop:
            case ScalaBuildTool.Auto:
            case ScalaBuildTool.None:
                // Fallback: compile and try to run
                auto builder = ScalaBuilderFactory.create(ScalaBuildMode.JAR, scalaConfig);
                auto buildResult = builder.build(target.sources, scalaConfig, target, config);
                testsPassed = buildResult.success;
                break;
        }
        
        if (!testsPassed)
        {
            result.error = "Tests failed";
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Scala);
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
    
    // Helper methods
    
    private void formatSources(const string[] sources, ScalaConfig config, string workingDir)
    {
        auto formatter = FormatterFactory.create(config.formatter.formatter, workingDir);
        
        if (!formatter.isAvailable())
        {
            structuredLog.warning("formatter_not_available_").field("detail", "Formatter not available: " ~ formatter.name()).emit();
            return;
        }
        
        structuredLog.info("formatting_sources_with_").field("detail", "Formatting sources with " ~ formatter.name()).emit();
        
        auto result = formatter.format(sources, config.formatter, workingDir, false);
        
        if (!result.success)
        {
            structuredLog.warning("formatting_had_issues_").field("detail", "Formatting had issues: " ~ result.error).emit();
        }
        else
        {
            structuredLog.debug_("formatted_").field("detail", "Formatted " ~ result.filesFormatted.to!string ~ " files").emit();
        }
    }
    
    private bool checkSources(const string[] sources, ScalaConfig config, string workingDir)
    {
        auto checker = CheckerFactory.create(config.linter.linter, workingDir);
        
        if (!checker.isAvailable())
        {
            structuredLog.warning("checker_not_available_").field("detail", "Checker not available: " ~ checker.name()).emit();
            return true;
        }
        
        structuredLog.info("checking_sources_with_").field("detail", "Checking sources with " ~ checker.name()).emit();
        
        auto result = checker.check(sources, config.linter, workingDir);
        
        if (!result.success)
        {
            structuredLog.warning("linter_found_").field("detail", "Linter found " ~ result.issuesFound.to!string ~ " issues").emit();
            foreach (violation; result.violations)
                structuredLog.warning("log_event").field("message", violation).emit();
            return false;
        }
        
        return true;
    }
}

