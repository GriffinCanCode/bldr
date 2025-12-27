module languages.jvm.kotlin.tooling.builders.multiplatform;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.kotlin.tooling.builders.base;
import languages.jvm.kotlin.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;
import engine.caching.actions.action : ActionCache;

/// Kotlin Multiplatform builder
class MultiplatformBuilder : KotlinBuilder
{
    this(ActionCache cache = null) {}
    
    override KotlinBuildResult build(
        in string[] sources,
        in KotlinConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        KotlinBuildResult result;
        
        structuredLog.debug_("building_kotlin_multiplatform_project").emit();
        
        // Multiplatform builds require Gradle
        if (config.buildTool != KotlinBuildTool.Gradle)
        {
            result.error = "Kotlin Multiplatform requires Gradle";
            return result;
        }
        
        import languages.jvm.kotlin.managers.gradle;
        
        string projectDir = findProjectRoot(sources);
        
        // Build all targets or specific ones
        string[] tasks;
        if (config.multiplatform.targets.empty)
        {
            tasks = ["build"];
        }
        else
        {
            // Build specific targets
            foreach (platform; config.multiplatform.targets)
            {
                final switch (platform)
                {
                    case KotlinPlatform.JVM:
                        tasks ~= "jvmJar";
                        break;
                    case KotlinPlatform.JS:
                        tasks ~= "jsBrowserProductionWebpack";
                        break;
                    case KotlinPlatform.Native:
                        tasks ~= "linkReleaseExecutableNative";
                        break;
                    case KotlinPlatform.Android:
                        tasks ~= "assembleRelease";
                        break;
                    case KotlinPlatform.Common:
                        tasks ~= "compileKotlinMetadata";
                        break;
                    case KotlinPlatform.Wasm:
                        tasks ~= "wasmJsBrowserProductionWebpack";
                        break;
                }
            }
        }
        
        // Execute Gradle build
        auto res = GradleOps.executeGradleWrapper(tasks, projectDir);
        
        if (res.status == 0)
        {
            result.success = true;
            
            // Collect outputs from build directory
            string buildDir = buildPath(projectDir, "build");
            if (exists(buildDir))
            {
                // Find JVM JARs
                string jvmLibs = buildPath(buildDir, "libs");
                if (exists(jvmLibs))
                {
                    result.outputs ~= dirEntries(jvmLibs, "*.jar", SpanMode.shallow)
                        .filter!(e => SecurityValidator.isPathWithinBase(e.name, jvmLibs))
                        .map!(e => e.name)
                        .array;
                }
                
                // Find JS output
                string jsDir = buildPath(buildDir, "dist", "js", "productionExecutable");
                if (exists(jsDir))
                {
                    result.outputs ~= dirEntries(jsDir, "*.js", SpanMode.shallow)
                        .filter!(e => SecurityValidator.isPathWithinBase(e.name, jsDir))
                        .map!(e => e.name)
                        .array;
                }
                
                // Find Native binaries
                string nativeDir = buildPath(buildDir, "bin", "native");
                if (exists(nativeDir))
                {
                    result.outputs ~= dirEntries(nativeDir, "*", SpanMode.shallow)
                        .filter!(e => e.isFile && SecurityValidator.isPathWithinBase(e.name, nativeDir))
                        .map!(e => e.name)
                        .array;
                }
            }
            
            if (!result.outputs.empty)
            {
                result.outputHash = FastHash.hashFile(result.outputs[0]);
            }
        }
        else
        {
            result.error = "Multiplatform build failed: " ~ res.output;
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        // Check for Gradle
        auto result = execute(["gradle", "--version"]);
        if (result.status != 0)
        {
            // Check for wrapper
            version(Windows)
                result = execute([".\\gradlew.bat", "--version"]);
            else
                result = execute(["./gradlew", "--version"]);
        }
        return result.status == 0;
    }
    
    override string name() const
    {
        return "Multiplatform";
    }
    
    override bool supportsMode(KotlinBuildMode mode)
    {
        return mode == KotlinBuildMode.Multiplatform;
    }
    
    private string findProjectRoot(const string[] sources)
    {
        if (sources.empty)
            return ".";
        
        string projectDir = dirName(sources[0]);
        
        while (projectDir != dirName(projectDir))
        {
            if (exists(buildPath(projectDir, "build.gradle.kts")) ||
                exists(buildPath(projectDir, "build.gradle")))
            {
                return projectDir;
            }
            projectDir = dirName(projectDir);
        }
        
        return ".";
    }
}

