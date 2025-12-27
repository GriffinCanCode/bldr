module languages.jvm.kotlin.managers.gradle;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.process;
import std.regex;
import std.conv;
import infrastructure.utils.logging;

/// Gradle Kotlin project metadata
struct GradleKotlinMetadata
{
    string name;
    string version_;
    string group;
    string description;
    
    string[] dependencies;
    string[] plugins;
    string kotlinVersion;
    string[] kotlinTargets;
    
    bool isMultiProject = false;
    string[] subprojects;
    
    bool isMultiplatform = false;
    bool isAndroid = false;
    bool usesKapt = false;
    bool usesKsp = false;
    
    /// Parse from build.gradle.kts or build.gradle
    static GradleKotlinMetadata fromFile(string buildFile)
    {
        if (!exists(buildFile))
            assert(false, "fileNotFoundError (Kotlin Gradle dependency analysis): " ~ buildFile);
        
        string content = readText(buildFile);
        bool isKotlinDSL = buildFile.endsWith(".kts");
        
        return isKotlinDSL ? fromKotlinDSL(content) : fromGroovyDSL(content);
    }
    
    /// Parse from Kotlin DSL (build.gradle.kts)
    static GradleKotlinMetadata fromKotlinDSL(string content)
    {
        GradleKotlinMetadata meta;
        
        // Parse version
        auto versionMatch = matchFirst(content, regex(`version\s*=\s*"([^"]+)"`));
        if (!versionMatch.empty)
            meta.version_ = versionMatch[1];
        
        // Parse group
        auto groupMatch = matchFirst(content, regex(`group\s*=\s*"([^"]+)"`));
        if (!groupMatch.empty)
            meta.group = groupMatch[1];
        
        // Parse Kotlin version
        auto kotlinMatch = matchFirst(content, regex(`kotlin\s*\(\s*"jvm"\s*\)\s+version\s+"([^"]+)"`));
        if (kotlinMatch.empty)
            kotlinMatch = matchFirst(content, regex(`id\s*\(\s*"org\.jetbrains\.kotlin\.jvm"\s*\)\s+version\s+"([^"]+)"`));
        if (!kotlinMatch.empty)
            meta.kotlinVersion = kotlinMatch[1];
        
        // Parse plugins
        auto pluginsSection = matchFirst(content, regex(`plugins\s*\{([^}]+)\}`, "s"));
        if (!pluginsSection.empty)
        {
            meta.plugins = parseKotlinPlugins(pluginsSection[1]);
        }
        
        // Detect multiplatform
        if (meta.plugins.any!(p => p.canFind("multiplatform")))
        {
            meta.isMultiplatform = true;
            meta.kotlinTargets = parseKotlinTargets(content);
        }
        
        // Detect Android
        if (meta.plugins.any!(p => p.canFind("android")))
        {
            meta.isAndroid = true;
        }
        
        // Detect KAPT
        if (meta.plugins.any!(p => p.canFind("kapt")))
        {
            meta.usesKapt = true;
        }
        
        // Detect KSP
        if (meta.plugins.any!(p => p.canFind("ksp") || p.canFind("symbol-processing")))
        {
            meta.usesKsp = true;
        }
        
        // Parse dependencies
        auto depsSection = matchFirst(content, regex(`dependencies\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}`, "s"));
        if (!depsSection.empty)
        {
            meta.dependencies = parseKotlinDependencies(depsSection[1]);
        }
        
        return meta;
    }
    
    /// Parse from Groovy DSL (build.gradle)
    static GradleKotlinMetadata fromGroovyDSL(string content)
    {
        GradleKotlinMetadata meta;
        
        // Parse version
        auto versionMatch = matchFirst(content, regex(`version\s*[=:]?\s*['"]([^'"]+)['"]`));
        if (!versionMatch.empty)
            meta.version_ = versionMatch[1];
        
        // Parse group
        auto groupMatch = matchFirst(content, regex(`group\s*[=:]?\s*['"]([^'"]+)['"]`));
        if (!groupMatch.empty)
            meta.group = groupMatch[1];
        
        // Parse Kotlin version
        auto kotlinMatch = matchFirst(content, regex(`kotlin\s*\(\s*['"]jvm['"]\s*\)\s+version\s+['"]([^'"]+)['"]`));
        if (kotlinMatch.empty)
            kotlinMatch = matchFirst(content, regex(`id\s+['"]org\.jetbrains\.kotlin\.jvm['"]\s+version\s+['"]([^'"]+)['"]`));
        if (!kotlinMatch.empty)
            meta.kotlinVersion = kotlinMatch[1];
        
        // Parse plugins
        auto pluginsSection = matchFirst(content, regex(`plugins\s*\{([^}]+)\}`));
        if (!pluginsSection.empty)
        {
            meta.plugins = parseGroovyPlugins(pluginsSection[1]);
        }
        
        // Detect multiplatform
        if (meta.plugins.any!(p => p.canFind("multiplatform")))
        {
            meta.isMultiplatform = true;
            meta.kotlinTargets = parseKotlinTargets(content);
        }
        
        // Detect Android
        if (meta.plugins.any!(p => p.canFind("android")))
        {
            meta.isAndroid = true;
        }
        
        // Detect KAPT
        if (meta.plugins.any!(p => p.canFind("kapt")))
        {
            meta.usesKapt = true;
        }
        
        // Detect KSP
        if (meta.plugins.any!(p => p.canFind("ksp") || p.canFind("symbol-processing")))
        {
            meta.usesKsp = true;
        }
        
        // Parse dependencies
        auto depsSection = matchFirst(content, regex(`dependencies\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}`, "s"));
        if (!depsSection.empty)
        {
            meta.dependencies = parseGroovyDependencies(depsSection[1]);
        }
        
        return meta;
    }
}

/// Gradle operations for Kotlin projects
class GradleOps
{
    /// Execute Gradle command
    static auto executeGradle(string[] args, string workingDir = ".")
    {
        return execute(["gradle"] ~ args, null, Config.none, size_t.max, workingDir);
    }
    
    /// Execute Gradle wrapper command
    static auto executeGradleWrapper(string[] args, string workingDir = ".")
    {
        version(Windows)
            string gradlew = ".\\gradlew.bat";
        else
            string gradlew = "./gradlew";
        
        return execute([gradlew] ~ args, null, Config.none, size_t.max, workingDir);
    }
    
    /// Build Kotlin project
    static bool build(string projectDir, bool skipTests = false, bool useWrapper = true)
    {
        structuredLog.info("building_kotlin_project_with_gradle").emit();
        
        string[] args = ["build"];
        if (skipTests)
            args ~= ["-x", "test"];
        
        auto result = useWrapper
            ? executeGradleWrapper(args, projectDir)
            : executeGradle(args, projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("gradle_build_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Compile Kotlin sources
    static bool compileKotlin(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("compiling_kotlin_sources").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["compileKotlin"], projectDir)
            : executeGradle(["compileKotlin"], projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("kotlin_compilation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run Kotlin tests
    static bool test(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("running_kotlin_tests").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["test"], projectDir)
            : executeGradle(["test"], projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("kotlin_tests_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Create JAR
    static bool jar(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("creating_jar_with_gradle").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["jar"], projectDir)
            : executeGradle(["jar"], projectDir);
        
        return result.status == 0;
    }
    
    /// Build multiplatform targets
    static bool buildMultiplatform(string projectDir, string[] targets = [], bool useWrapper = true)
    {
        structuredLog.info("building_multiplatform_targets").emit();
        
        string[] args;
        if (targets.empty)
            args = ["build"];
        else
        {
            foreach (target; targets)
            {
                args ~= target ~ "Binaries";
            }
        }
        
        auto result = useWrapper
            ? executeGradleWrapper(args, projectDir)
            : executeGradle(args, projectDir);
        
        return result.status == 0;
    }
    
    /// Run detekt analysis
    static bool detekt(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("running_detekt_analysis").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["detekt"], projectDir)
            : executeGradle(["detekt"], projectDir);
        
        return result.status == 0;
    }
    
    /// Format code with ktlint
    static bool ktlintFormat(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("formatting_kotlin_code_with_ktlint").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["ktlintFormat"], projectDir)
            : executeGradle(["ktlintFormat"], projectDir);
        
        return result.status == 0;
    }
    
    /// Check code style with ktlint
    static bool ktlintCheck(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("checking_kotlin_code_style").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["ktlintCheck"], projectDir)
            : executeGradle(["ktlintCheck"], projectDir);
        
        return result.status == 0;
    }
    
    /// Clean build
    static bool clean(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("cleaning_gradle_project").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["clean"], projectDir)
            : executeGradle(["clean"], projectDir);
        
        return result.status == 0;
    }
    
    /// Install dependencies
    static bool installDependencies(string projectDir, bool useWrapper = true)
    {
        structuredLog.info("resolving_gradle_dependencies").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["dependencies"], projectDir)
            : executeGradle(["dependencies"], projectDir);
        
        return result.status == 0;
    }
    
    /// Get Gradle version
    static string getVersion()
    {
        auto result = execute(["gradle", "--version"]);
        if (result.status == 0)
        {
            auto match = matchFirst(result.output, regex(`Gradle ([\d.]+)`));
            if (!match.empty)
                return match[1];
        }
        return "";
    }
}

// Helper parsing functions

private string[] parseKotlinPlugins(string pluginsBlock)
{
    string[] plugins;
    
    // Match: kotlin("jvm") or id("org.jetbrains.kotlin.jvm")
    auto kotlinPattern = regex(`kotlin\s*\(\s*"([^"]+)"\s*\)`, "g");
    foreach (match; matchAll(pluginsBlock, kotlinPattern))
    {
        plugins ~= "kotlin." ~ match[1];
    }
    
    // Match: id("plugin.name")
    auto idPattern = regex(`id\s*\(\s*"([^"]+)"\s*\)`, "g");
    foreach (match; matchAll(pluginsBlock, idPattern))
    {
        plugins ~= match[1];
    }
    
    return plugins;
}

private string[] parseGroovyPlugins(string pluginsBlock)
{
    string[] plugins;
    
    // Match: id 'plugin' or id "plugin"
    auto idPattern = regex(`id\s+['"]([^'"]+)['"]`, "g");
    foreach (match; matchAll(pluginsBlock, idPattern))
    {
        plugins ~= match[1];
    }
    
    return plugins;
}

private string[] parseKotlinDependencies(string depsBlock)
{
    string[] deps;
    
    // Match: implementation("group:artifact:version")
    auto depPattern = regex(`(?:implementation|api|compileOnly|runtimeOnly|testImplementation)\s*\(\s*"([^"]+)"\s*\)`, "g");
    foreach (match; matchAll(depsBlock, depPattern))
    {
        deps ~= match[1];
    }
    
    return deps;
}

private string[] parseGroovyDependencies(string depsBlock)
{
    string[] deps;
    
    // Match: implementation 'group:artifact:version'
    auto depPattern = regex(`(?:implementation|api|compileOnly|runtimeOnly|testImplementation)\s+['"]([^'"]+)['"]`, "g");
    foreach (match; matchAll(depsBlock, depPattern))
    {
        deps ~= match[1];
    }
    
    return deps;
}

private string[] parseKotlinTargets(string content)
{
    string[] targets;
    
    // Match Kotlin multiplatform targets: jvm(), js(), etc.
    auto targetPattern = regex(`(jvm|js|android|iosX64|iosArm64|macosX64|linuxX64|mingwX64)\s*\(`, "g");
    foreach (match; matchAll(content, targetPattern))
    {
        targets ~= match[1];
    }
    
    return targets;
}

