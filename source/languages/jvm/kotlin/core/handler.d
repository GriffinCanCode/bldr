module languages.jvm.kotlin.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import core.time : MonoTime;
import languages.base.base;
import languages.base.mixins;
import languages.jvm.kotlin.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import engine.workers.integration : KotlinWorkerIntegration, shouldUsePersistentWorker;

/// Kotlin build handler with action-level caching
class KotlinHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"kotlin";
    mixin SimpleBuildOrchestrationMixin!(KotlinConfig, "parseKotlinConfig");
    
    private void enhanceConfigFromProject(
        ref KotlinConfig ktConfig,
        in Target target,
        in WorkspaceConfig config
    )
    {
        // Auto-detect build tool if needed
        if (ktConfig.buildTool == KotlinBuildTool.Auto)
        {
            ktConfig.buildTool = detectBuildTool();
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        string[] outputs;
        KotlinConfig ktConfig = parseKotlinConfig(target);
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Determine output based on mode and platform
            final switch (ktConfig.mode)
            {
                case KotlinBuildMode.JAR:
                case KotlinBuildMode.FatJAR:
                case KotlinBuildMode.Android:
                case KotlinBuildMode.Compile:
                    outputs ~= buildPath(config.options.outputDir, name ~ ".jar");
                    break;
                case KotlinBuildMode.Native:
                    outputs ~= buildPath(config.options.outputDir, name);
                    break;
                case KotlinBuildMode.JS:
                    outputs ~= buildPath(config.options.outputDir, name ~ ".js");
                    break;
                case KotlinBuildMode.Multiplatform:
                    // Multiple outputs for multiplatform
                    foreach (platform; ktConfig.multiplatform.targets)
                    {
                        final switch (platform)
                        {
                            case KotlinPlatform.JVM:
                            case KotlinPlatform.Android:
                                outputs ~= buildPath(config.options.outputDir, name ~ "-jvm.jar");
                                break;
                            case KotlinPlatform.JS:
                                outputs ~= buildPath(config.options.outputDir, name ~ "-js.js");
                                break;
                            case KotlinPlatform.Native:
                                outputs ~= buildPath(config.options.outputDir, name ~ "-native");
                                break;
                            case KotlinPlatform.Common:
                                outputs ~= buildPath(config.options.outputDir, name ~ "-common.jar");
                                break;
                            case KotlinPlatform.Wasm:
                                outputs ~= buildPath(config.options.outputDir, name ~ ".wasm");
                                break;
                        }
                    }
                    break;
            }
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Kotlin);
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
                Logger.warning("Failed to analyze imports in " ~ source);
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, KotlinConfig ktConfig)
    {
        // Delegate to appropriate builder based on mode
        import languages.jvm.kotlin.tooling.builders;
        
        auto builder = KotlinBuilderFactory.create(ktConfig.mode, ktConfig, actionCache);
        if (builder is null)
        {
            LanguageBuildResult result;
            result.error = "Unsupported build mode: " ~ ktConfig.mode.to!string;
            return result;
        }
        
        auto buildResult = builder.build(target.sources, ktConfig, target, config);
        
        // Convert to LanguageBuildResult
        LanguageBuildResult result;
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, KotlinConfig ktConfig)
    {
        // Libraries typically don't include runtime
        ktConfig.packaging.includeRuntime = false;
        
        return buildExecutable(target, config, ktConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, KotlinConfig ktConfig)
    {
        LanguageBuildResult result;
        
        // Use Gradle/Maven if available, otherwise fallback to direct kotlinc
        if (ktConfig.buildTool == KotlinBuildTool.Gradle)
        {
            import languages.jvm.kotlin.managers.gradle;
            
            string projectDir = target.sources.empty ? "." : dirName(target.sources[0]);
            bool success = GradleOps.test(projectDir, true);
            result.success = success;
            if (!success)
                result.error = "Gradle tests failed";
        }
        else if (ktConfig.buildTool == KotlinBuildTool.Maven)
        {
            import languages.jvm.kotlin.managers.maven;
            
            string projectDir = target.sources.empty ? "." : dirName(target.sources[0]);
            bool success = MavenOps.test(projectDir);
            result.success = success;
            if (!success)
                result.error = "Maven tests failed";
        }
        else
        {
            // Direct kotlinc test build - try persistent worker first
            auto tempJar = buildPath(config.options.outputDir, ".kotlin-test.jar");
            string classpath = target.deps.empty ? "" : buildClasspath(target, config);
            
            // Build compiler options
            string[] options;
            options ~= "-include-runtime";
            options ~= target.flags;
            options ~= ktConfig.compilerFlags;
            
            if (ktConfig.languageVersion.major > 0)
                options ~= ["-language-version", ktConfig.languageVersion.toString()];
            if (ktConfig.apiVersion.major > 0)
                options ~= ["-api-version", ktConfig.apiVersion.toString()];
            if (ktConfig.platform == KotlinPlatform.JVM)
                options ~= ["-jvm-target", ktConfig.jvmTarget.toString()];
            
            // Try persistent worker for compilation (20x+ speedup)
            if (shouldUsePersistentWorker("jvm-kotlinc"))
            {
                auto workerResult = KotlinWorkerIntegration.compile(
                    target.sources.dup,
                    tempJar,
                    classpath.empty ? [] : [classpath],
                    options,
                    true
                );
                
                if (workerResult.isOk)
                {
                    auto r = workerResult.unwrap();
                    if (r.success)
                    {
                        Logger.info("  [Warm worker] Compiled tests in " ~ 
                                   r.executionTimeMs.to!string ~ "ms" ~
                                   " (speedup: " ~ r.estimatedSpeedup().to!string ~ "x)");
                    }
                    else
                    {
                        result.error = "Test compilation failed: " ~ r.output;
                        return result;
                    }
                }
                else
                {
                    // Fall through to direct compilation
                    Logger.debugLog("Persistent worker unavailable, using direct kotlinc");
                    if (!compileTestsDirect(target.sources, tempJar, classpath, options, result))
                        return result;
                }
            }
            else
            {
                if (!compileTestsDirect(target.sources, tempJar, classpath, options, result))
                    return result;
            }
            
            // Run tests
            string testClass = ktConfig.test.framework == KotlinTestFramework.JUnit5 
                ? "org.junit.platform.console.ConsoleLauncher"
                : "TestKt";
            
            auto runCmd = ["kotlin", "-classpath", tempJar] ~ ktConfig.jvmFlags ~ [testClass] ~ ktConfig.test.testFlags;
            auto runRes = execute(runCmd);
            
            scope(exit) if (exists(tempJar)) remove(tempJar);
            
            if (runRes.status != 0)
            {
                result.error = "Tests failed: " ~ runRes.output;
                return result;
            }
            
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources);
        }
        
        return result;
    }
    
    /// Direct kotlinc compilation (fallback)
    private bool compileTestsDirect(
        const(string[]) sources,
        string outputJar,
        string classpath,
        string[] options,
        ref LanguageBuildResult result
    )
    {
        string[] cmd = ["kotlinc"];
        if (!classpath.empty)
            cmd ~= ["-classpath", classpath];
        cmd ~= options;
        cmd ~= sources;
        cmd ~= ["-d", outputJar];
        
        auto buildRes = execute(cmd);
        if (buildRes.status != 0)
        {
            result.error = "Test compilation failed: " ~ buildRes.output;
            return false;
        }
        return true;
    }
    
    /// Detect build tool from project structure
    private KotlinBuildTool detectBuildTool()
    {
        // Check for Gradle
        if (exists("build.gradle.kts") || exists("build.gradle") || 
            exists("gradlew") || exists("gradle.properties"))
        {
            return KotlinBuildTool.Gradle;
        }
        
        // Check for Maven
        if (exists("pom.xml"))
        {
            return KotlinBuildTool.Maven;
        }
        
        // Default to direct compilation
        return KotlinBuildTool.Direct;
    }
    
    /// Build classpath from dependencies
    private string buildClasspath(const Target target, const WorkspaceConfig config)
    {
        string[] paths;
        
        foreach (dep; target.deps)
        {
            auto depTarget = config.findTarget(dep);
            if (depTarget !is null)
            {
                auto depOutputs = getOutputs(*depTarget, config);
                paths ~= depOutputs;
            }
        }
        
        version(Windows)
            return paths.join(";");
        else
            return paths.join(":");
    }
}

