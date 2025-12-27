module languages.jvm.kotlin.tooling.builders.android;

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
import engine.caching.actions.action : ActionCache;

/// Android Kotlin builder (AAR/APK)
class AndroidBuilder : KotlinBuilder
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
        
        structuredLog.debug_("building_android_kotlin_project").emit();
        
        // Android builds require Gradle
        if (config.buildTool != KotlinBuildTool.Gradle)
        {
            result.error = "Android builds require Gradle";
            return result;
        }
        
        import languages.jvm.kotlin.managers.gradle;
        
        string projectDir = findProjectRoot(sources);
        
        // Determine build task
        string[] tasks;
        if (config.android.variants.empty)
        {
            tasks = ["assembleRelease"];
        }
        else
        {
            foreach (variant; config.android.variants)
            {
                tasks ~= "assemble" ~ capitalize(variant);
            }
        }
        
        // Execute Gradle build
        auto res = GradleOps.executeGradleWrapper(tasks, projectDir);
        
        if (res.status == 0)
        {
            result.success = true;
            
            // Find output APKs/AARs
            string buildDir = buildPath(projectDir, "build", "outputs");
            
            // Check for AAR (library)
            string aarDir = buildPath(buildDir, "aar");
            if (exists(aarDir))
            {
                result.outputs ~= dirEntries(aarDir, "*.aar", SpanMode.shallow)
                    .map!(e => e.name)
                    .array;
            }
            
            // Check for APK (application)
            string apkDir = buildPath(buildDir, "apk");
            if (exists(apkDir))
            {
                result.outputs ~= dirEntries(apkDir, "*.apk", SpanMode.depth)
                    .map!(e => e.name)
                    .array;
            }
            
            if (!result.outputs.empty)
            {
                result.outputHash = FastHash.hashFile(result.outputs[0]);
            }
        }
        else
        {
            result.error = "Android build failed: " ~ res.output;
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        // Check for Gradle and Android SDK
        auto gradleResult = execute(["gradle", "--version"]);
        if (gradleResult.status != 0)
        {
            version(Windows)
                gradleResult = execute([".\\gradlew.bat", "--version"]);
            else
                gradleResult = execute(["./gradlew", "--version"]);
        }
        
        // Check for ANDROID_HOME environment variable
        import std.process : environment;
        bool hasAndroidSDK = environment.get("ANDROID_HOME", "").length > 0 ||
                            environment.get("ANDROID_SDK_ROOT", "").length > 0;
        
        return gradleResult.status == 0 && hasAndroidSDK;
    }
    
    override string name() const
    {
        return "Android";
    }
    
    override bool supportsMode(KotlinBuildMode mode)
    {
        return mode == KotlinBuildMode.Android;
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
                // Verify it's an Android project
                string buildFile = exists(buildPath(projectDir, "build.gradle.kts"))
                    ? buildPath(projectDir, "build.gradle.kts")
                    : buildPath(projectDir, "build.gradle");
                
                string content = readText(buildFile);
                if (content.canFind("com.android."))
                {
                    return projectDir;
                }
            }
            projectDir = dirName(projectDir);
        }
        
        return ".";
    }
    
    private string capitalize(string s)
    {
        if (s.empty)
            return s;
        return s[0..1].toUpper ~ s[1..$];
    }
}

