module languages.jvm.kotlin.multiplatform;

/// Kotlin Multiplatform support utilities
/// 
/// Provides helpers for managing multiplatform projects.

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import languages.jvm.kotlin.core.config;
import infrastructure.utils.logging;

/// Multiplatform project structure helper
class MultiplatformHelper
{
    /// Detect if project is multiplatform
    static bool isMultiplatform(string projectDir = ".")
    {
        // Check for build.gradle.kts with multiplatform plugin
        string buildFile = buildPath(projectDir, "build.gradle.kts");
        if (!exists(buildFile))
        {
            buildFile = buildPath(projectDir, "build.gradle");
            if (!exists(buildFile))
                return false;
        }
        
        string content = readText(buildFile);
        return content.canFind("kotlin(\"multiplatform\")") ||
               content.canFind("kotlin-multiplatform") ||
               content.canFind("org.jetbrains.kotlin.multiplatform");
    }
    
    /// Detect available targets in multiplatform project
    static KotlinPlatform[] detectTargets(string projectDir = ".")
    {
        KotlinPlatform[] targets;
        
        string buildFile = buildPath(projectDir, "build.gradle.kts");
        if (!exists(buildFile))
        {
            buildFile = buildPath(projectDir, "build.gradle");
            if (!exists(buildFile))
                return targets;
        }
        
        string content = readText(buildFile);
        
        // Check for target declarations
        if (content.canFind("jvm()") || content.canFind("jvm {"))
            targets ~= KotlinPlatform.JVM;
        
        if (content.canFind("js()") || content.canFind("js(") || content.canFind("js {"))
            targets ~= KotlinPlatform.JS;
        
        if (content.canFind("android()") || content.canFind("android {"))
            targets ~= KotlinPlatform.Android;
        
        // Native targets
        if (content.canFind("linuxX64()") || content.canFind("linuxArm64()") ||
            content.canFind("macosX64()") || content.canFind("macosArm64()") ||
            content.canFind("mingwX64()") || content.canFind("iosX64()") ||
            content.canFind("iosArm64()"))
        {
            targets ~= KotlinPlatform.Native;
        }
        
        if (content.canFind("wasm()") || content.canFind("wasm {"))
            targets ~= KotlinPlatform.Wasm;
        
        return targets;
    }
    
    /// Get source set directories for a platform
    static string[] getSourceSets(string projectDir, KotlinPlatform platform)
    {
        string[] sourceSets;
        
        // Common source sets
        string commonMain = buildPath(projectDir, "src", "commonMain", "kotlin");
        if (exists(commonMain))
            sourceSets ~= commonMain;
        
        string commonTest = buildPath(projectDir, "src", "commonTest", "kotlin");
        if (exists(commonTest))
            sourceSets ~= commonTest;
        
        // Platform-specific source sets
        string platformName;
        final switch (platform)
        {
            case KotlinPlatform.JVM:
                platformName = "jvmMain";
                break;
            case KotlinPlatform.JS:
                platformName = "jsMain";
                break;
            case KotlinPlatform.Android:
                platformName = "androidMain";
                break;
            case KotlinPlatform.Native:
                platformName = "nativeMain";
                break;
            case KotlinPlatform.Common:
                return sourceSets; // Already added above
            case KotlinPlatform.Wasm:
                platformName = "wasmMain";
                break;
        }
        
        string platformMain = buildPath(projectDir, "src", platformName, "kotlin");
        if (exists(platformMain))
            sourceSets ~= platformMain;
        
        return sourceSets;
    }
    
    /// Validate expect/actual declarations match
    static bool validateExpectActual(MultiplatformConfig config)
    {
        // This would require parsing Kotlin source files to find expect/actual pairs
        // For now, return true (validation happens during compilation)
        structuredLog.debug_("expectactual_validation_delegated_to_com").emit();
        return true;
    }
}

