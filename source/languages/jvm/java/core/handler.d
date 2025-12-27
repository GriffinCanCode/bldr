module languages.jvm.java.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.process : environment;
import languages.base.base;
import languages.base.mixins;
import languages.jvm.java.core.config;
import languages.jvm.java.managers;
import languages.jvm.java.tooling.detection;
import languages.jvm.java.tooling.info;
import languages.jvm.java.tooling.builders;
import languages.jvm.java.tooling.formatters;
import languages.jvm.java.analysis;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionId, ActionType;

/// Java build handler - comprehensive and modular with action-level caching
class JavaHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"java";
    mixin SimpleBuildOrchestrationMixin!(JavaConfig, "parseJavaConfig");
    
    private void enhanceConfigFromProject(
        ref JavaConfig javaConfig,
        in Target target,
        in WorkspaceConfig config
    )
    {
        // Detect and enhance configuration from project structure
        BuildToolFactory.enhanceConfigFromProject(javaConfig, config.root);
        
        // Validate Java installation
        if (!JavaToolDetection.isJavacAvailable())
        {
            structuredLog.error("java_compiler_javac_not_found_please_ins").emit();
            return;
        }
        
        // Check Java version
        auto javaVersion = JavaInfo.getVersion();
        if (!JavaInfo.meetsMinimumVersion(javaVersion, javaConfig.sourceVersion))
        {
            structuredLog.warning("java_version_").field("detail", "Java version " ~ javaVersion.toString() ~ 
                          " may not support source version " ~ javaConfig.sourceVersion.toString()).emit();
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        string[] outputs;
        
        JavaConfig javaConfig = parseJavaConfig(target);
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Determine extension based on build mode
            string ext = ".jar";
            if (javaConfig.mode == JavaBuildMode.WAR)
                ext = ".war";
            else if (javaConfig.mode == JavaBuildMode.EAR)
                ext = ".ear";
            else if (javaConfig.mode == JavaBuildMode.NativeImage)
            {
                version(Windows)
                    ext = ".exe";
                else
                    ext = "";
            }
            
            outputs ~= buildPath(config.options.outputDir, name ~ ext);
        }
        
        return outputs;
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        JavaConfig javaConfig
    )
    {
        LanguageBuildResult result;
        
        // Use build tool if explicitly configured (Maven or Gradle only)
        if (javaConfig.buildTool == JavaBuildTool.Maven || javaConfig.buildTool == JavaBuildTool.Gradle)
        {
            return buildWithBuildTool(target, config, javaConfig);
        }
        
        // Install dependencies if using Maven/Gradle
        if (javaConfig.maven.autoInstall && JavaToolDetection.hasPomXml(config.root))
        {
            bool useWrapper = BuildToolFactory.shouldUseWrapper(JavaBuildTool.Maven, config.root);
            if (!MavenOps.installDependencies(config.root, useWrapper))
            {
                structuredLog.warning("maven_dependency_installation_had_issues").emit();
            }
        }
        else if (javaConfig.gradle.autoInstall && JavaToolDetection.hasBuildGradle(config.root))
        {
            bool useWrapper = BuildToolFactory.shouldUseWrapper(JavaBuildTool.Gradle, config.root);
            if (!GradleOps.installDependencies(config.root, useWrapper))
            {
                structuredLog.warning("gradle_dependency_resolution_had_issues_").emit();
            }
        }
        
        // Auto-format if configured
        if (javaConfig.formatter.autoFormat && javaConfig.formatter.formatter != languages.jvm.java.core.config.JavaFormatterType.None)
        {
            structuredLog.info("autoformatting_code").emit();
            auto formatter = JavaFormatterFactory.create(javaConfig.formatter.formatter, config.root);
            auto formatResult = formatter.format(target.sources, javaConfig.formatter, config.root, javaConfig.formatter.checkOnly);
            
            if (!formatResult.success)
            {
                structuredLog.warning("formatting_failed_continuing_anyway").emit();
            }
        }
        
        // Run static analysis if configured
        if (javaConfig.analysis.enabled && javaConfig.analysis.analyzer != JavaAnalyzer.None)
        {
            structuredLog.info("running_static_analysis").emit();
            auto analyzer = AnalyzerFactory.create(javaConfig.analysis.analyzer, config.root);
            auto analysisResult = analyzer.analyze(target.sources, javaConfig.analysis, config.root);
            
            if (analysisResult.hasErrors() && javaConfig.analysis.failOnErrors)
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
                
                if (javaConfig.analysis.failOnWarnings)
                {
                    result.error = "Static analysis warnings treated as errors";
                    return result;
                }
            }
        }
        
        // Build using appropriate builder, pass actionCache for per-file caching
        auto builder = JavaBuilderFactory.create(javaConfig.mode, javaConfig, getCache());
        
        if (!builder.isAvailable())
        {
            result.error = "Builder " ~ builder.name() ~ " not available";
            return result;
        }
        
        auto buildResult = builder.build(target.sources, javaConfig, target, config);
        
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
        JavaConfig javaConfig
    )
    {
        LanguageBuildResult result;
        
        // Libraries are built similarly to executables, just without main class
        if (javaConfig.packaging.mainClass.empty)
        {
            // Force JAR mode for libraries
            if (javaConfig.mode == JavaBuildMode.FatJAR)
                javaConfig.mode = JavaBuildMode.JAR;
        }
        
        return buildExecutable(target, config, javaConfig);
    }
    
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        JavaConfig javaConfig
    )
    {
        LanguageBuildResult result;
        
        structuredLog.info("running_java_tests").emit();
        
        // Use build tool for testing if available
        if (javaConfig.buildTool == JavaBuildTool.Maven && JavaToolDetection.hasPomXml(config.root))
        {
            bool useWrapper = BuildToolFactory.shouldUseWrapper(JavaBuildTool.Maven, config.root);
            if (!MavenOps.test(config.root, useWrapper))
            {
                result.error = "Maven tests failed";
                return result;
            }
        }
        else if (javaConfig.buildTool == JavaBuildTool.Gradle && JavaToolDetection.hasBuildGradle(config.root))
        {
            bool useWrapper = BuildToolFactory.shouldUseWrapper(JavaBuildTool.Gradle, config.root);
            if (!GradleOps.test(config.root, useWrapper))
            {
                result.error = "Gradle tests failed";
                return result;
            }
        }
        else
        {
            // Run JUnit directly
            auto testResult = runJUnitTests(target, config, javaConfig);
            if (!testResult.success)
                return testResult;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(
        const Target target,
        const WorkspaceConfig config,
        JavaConfig javaConfig
    )
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private LanguageBuildResult buildWithBuildTool(
        const Target target,
        const WorkspaceConfig config,
        JavaConfig javaConfig
    )
    {
        LanguageBuildResult result;
        
        bool useWrapper = BuildToolFactory.shouldUseWrapper(javaConfig.buildTool, config.root);
        
        final switch (javaConfig.buildTool)
        {
            case JavaBuildTool.Maven:
                if (!MavenOps.packageProject(config.root, javaConfig.maven.skipTests, useWrapper))
                {
                    result.error = "Maven build failed";
                    return result;
                }
                break;
            
            case JavaBuildTool.Gradle:
                if (!GradleOps.build(config.root, javaConfig.gradle.skipTests, useWrapper))
                {
                    result.error = "Gradle build failed";
                    return result;
                }
                break;
            
            case JavaBuildTool.Auto:
            case JavaBuildTool.Direct:
            case JavaBuildTool.Ant:
            case JavaBuildTool.None:
                // Should not reach here - these are handled by buildExecutable directly
                result.error = "Unexpected build tool mode: " ~ javaConfig.buildTool.to!string;
                return result;
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
    
    private LanguageBuildResult runJUnitTests(
        const Target target,
        const WorkspaceConfig config,
        JavaConfig javaConfig
    )
    {
        LanguageBuildResult result;
        
        structuredLog.info("running_junit_tests_directly").emit();
        
        // Import JUnit test utilities
        import languages.jvm.java.tooling.testers.junit;
        
        // Detect JUnit version
        auto junitVersion = detectJUnitVersion(config.root);
        structuredLog.info("detected_").field("detail", "Detected " ~ (junitVersion == JUnitVersion.JUnit5 ? "JUnit 5" : "JUnit 4")).emit();
        
        // Try to build classpath
        string classpath = buildClasspath(config.root, javaConfig);
        
        if (classpath.empty)
        {
            structuredLog.warning("could_not_build_classpath_tests_may_fail").emit();
            classpath = buildPath(config.root, "target", "test-classes") ~ ":" ~ 
                       buildPath(config.root, "target", "classes");
        }
        
        // Find test classes from sources
        string[] testClasses;
        foreach (source; target.sources)
        {
            if (source.endsWith(".java") && (source.canFind("Test") || source.canFind("test")))
            {
                // Convert file path to class name
                auto className = source
                    .replace("/", ".")
                    .replace("\\", ".")
                    .stripExtension();
                
                // Remove src/test/java prefix if present
                auto srcTestIdx = className.indexOf("src.test.java.");
                if (srcTestIdx >= 0)
                    className = className[srcTestIdx + "src.test.java.".length .. $];
                
                testClasses ~= className;
            }
        }
        
        if (testClasses.empty)
        {
            structuredLog.warning("no_test_classes_found_marking_as_success").emit();
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources);
            return result;
        }
        
        // Run JUnit tests
        auto testResult = runJUnitDirect(testClasses, classpath, junitVersion);
        
        if (!testResult.success)
        {
            result.error = testResult.error;
            structuredLog.error("tests_failed").emit();
            structuredLog.error("__error_").field("detail", "  Error: " ~ testResult.error).emit();
            
            if (testResult.failed > 0)
            {
                structuredLog.error("log_event").field("message", testResult.failed.to!string ~ " test(s) failed, " ~ 
                           testResult.passed.to!string ~ " passed").emit();
            }
            
            return result;
        }
        
        structuredLog.info("all_tests_passed_").field("detail", "All tests passed: " ~ testResult.passed.to!string ~ " tests").emit();
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    /// Build classpath for testing
    private string buildClasspath(string projectDir, JavaConfig config)
    {
        string[] classpathEntries;
        
        // Add compiled classes
        classpathEntries ~= buildPath(projectDir, "target", "classes");
        classpathEntries ~= buildPath(projectDir, "target", "test-classes");
        
        // Add build output
        classpathEntries ~= buildPath(projectDir, "build", "classes", "java", "main");
        classpathEntries ~= buildPath(projectDir, "build", "classes", "java", "test");
        
        // Add dependencies from Maven local repo
        auto m2Repo = buildPath(environment.get("HOME", ""), ".m2", "repository");
        if (exists(m2Repo))
        {
            try {
                import std.file : dirEntries, SpanMode;
                foreach (entry; dirEntries(m2Repo, "*.jar", SpanMode.depth))
                {
                    auto name = baseName(entry.name);
                    // Only include test-related JARs
                    if (name.canFind("junit") || name.canFind("hamcrest") || name.canFind("mockito"))
                        classpathEntries ~= entry.name;
                }
            } catch (Exception) {}
        }
        
        version(Windows)
            return classpathEntries.join(";");
        else
            return classpathEntries.join(":");
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Java);
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
