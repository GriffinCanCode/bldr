module languages.jvm.java.managers.gradle;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.process;
import std.regex;
import std.conv;
import infrastructure.utils.logging;

/// Gradle project metadata
struct GradleMetadata
{
    string name;
    string version_;
    string group;
    string description;
    
    string[] dependencies;
    string[] plugins;
    string sourceCompatibility;
    string targetCompatibility;
    
    bool isMultiProject = false;
    string[] subprojects;
    
    /// Parse from build.gradle or build.gradle.kts
    static GradleMetadata fromFile(string buildFile)
    {
        if (!exists(buildFile))
            assert(false, "fileNotFoundError (Gradle dependency analysis): " ~ buildFile);
        
        string content = readText(buildFile);
        bool isKotlin = buildFile.endsWith(".kts");
        
        return isKotlin ? fromKotlinDSL(content) : fromGroovyDSL(content);
    }
    
    /// Parse from Groovy DSL (build.gradle)
    static GradleMetadata fromGroovyDSL(string content)
    {
        GradleMetadata meta;
        
        // Parse version
        auto versionMatch = matchFirst(content, regex(`version\s*[=:]?\s*['"]([^'"]+)['"]`));
        if (!versionMatch.empty)
            meta.version_ = versionMatch[1];
        
        // Parse group
        auto groupMatch = matchFirst(content, regex(`group\s*[=:]?\s*['"]([^'"]+)['"]`));
        if (!groupMatch.empty)
            meta.group = groupMatch[1];
        
        // Parse source/target compatibility
        auto sourceMatch = matchFirst(content, regex(`sourceCompatibility\s*[=:]?\s*['"]?([^'"\n]+)['"]?`));
        if (!sourceMatch.empty)
            meta.sourceCompatibility = sourceMatch[1].strip;
        
        auto targetMatch = matchFirst(content, regex(`targetCompatibility\s*[=:]?\s*['"]?([^'"\n]+)['"]?`));
        if (!targetMatch.empty)
            meta.targetCompatibility = targetMatch[1].strip;
        
        // Parse plugins
        auto pluginsSection = matchFirst(content, regex(`plugins\s*\{([^}]+)\}`));
        if (!pluginsSection.empty)
        {
            meta.plugins = parseGroovyPlugins(pluginsSection[1]);
        }
        
        // Parse dependencies
        auto depsSection = matchFirst(content, regex(`dependencies\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}`, "s"));
        if (!depsSection.empty)
        {
            meta.dependencies = parseGroovyDependencies(depsSection[1]);
        }
        
        return meta;
    }
    
    /// Parse from Kotlin DSL (build.gradle.kts)
    static GradleMetadata fromKotlinDSL(string content)
    {
        GradleMetadata meta;
        
        // Parse version
        auto versionMatch = matchFirst(content, regex(`version\s*=\s*"([^"]+)"`));
        if (!versionMatch.empty)
            meta.version_ = versionMatch[1];
        
        // Parse group
        auto groupMatch = matchFirst(content, regex(`group\s*=\s*"([^"]+)"`));
        if (!groupMatch.empty)
            meta.group = groupMatch[1];
        
        // Parse Java toolchain or compatibility
        auto toolchainMatch = matchFirst(content, regex(`languageVersion\.set\(JavaLanguageVersion\.of\((\d+)\)\)`));
        if (!toolchainMatch.empty)
        {
            meta.sourceCompatibility = toolchainMatch[1];
            meta.targetCompatibility = toolchainMatch[1];
        }
        else
        {
            auto sourceMatch = matchFirst(content, regex(`sourceCompatibility\s*=\s*JavaVersion\.VERSION_(\d+)`));
            if (!sourceMatch.empty)
                meta.sourceCompatibility = sourceMatch[1];
            
            auto targetMatch = matchFirst(content, regex(`targetCompatibility\s*=\s*JavaVersion\.VERSION_(\d+)`));
            if (!targetMatch.empty)
                meta.targetCompatibility = targetMatch[1];
        }
        
        // Parse plugins
        auto pluginsSection = matchFirst(content, regex(`plugins\s*\{([^}]+)\}`));
        if (!pluginsSection.empty)
        {
            meta.plugins = parseKotlinPlugins(pluginsSection[1]);
        }
        
        // Parse dependencies
        auto depsSection = matchFirst(content, regex(`dependencies\s*\{([^}]*(?:\{[^}]*\}[^}]*)*)\}`, "s"));
        if (!depsSection.empty)
        {
            meta.dependencies = parseKotlinDependencies(depsSection[1]);
        }
        
        return meta;
    }
    
    /// Get Java version
    string getJavaVersion() const
    {
        if (!sourceCompatibility.empty)
            return sourceCompatibility;
        if (!targetCompatibility.empty)
            return targetCompatibility;
        return "11"; // Default
    }
    
    /// Check if this uses Spring Boot
    bool usesSpringBoot() const
    {
        foreach (plugin; plugins)
        {
            if (plugin.canFind("spring-boot") || plugin.canFind("org.springframework.boot"))
                return true;
        }
        
        foreach (dep; dependencies)
        {
            if (dep.canFind("spring-boot"))
                return true;
        }
        
        return false;
    }
    
    /// Check if this uses Kotlin
    bool usesKotlin() const
    {
        foreach (plugin; plugins)
        {
            if (plugin.canFind("kotlin"))
                return true;
        }
        return false;
    }
    
    /// Check if this is an Android project
    bool isAndroid() const
    {
        foreach (plugin; plugins)
        {
            if (plugin.canFind("android"))
                return true;
        }
        return false;
    }
}

/// Gradle operations
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
    
    /// Build project
    static bool build(string projectDir, bool skipTests = false, bool useWrapper = false)
    {
        structuredLog.info("building_gradle_project").emit();
        
        string[] args = ["build"];
        if (skipTests)
            args ~= "-x" ~ "test";
        
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
    
    /// Clean build
    static bool clean(string projectDir, bool useWrapper = false)
    {
        structuredLog.info("cleaning_gradle_project").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["clean"], projectDir)
            : executeGradle(["clean"], projectDir);
        
        return result.status == 0;
    }
    
    /// Compile sources
    static bool compile(string projectDir, bool useWrapper = false)
    {
        structuredLog.info("compiling_gradle_project").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["compileJava"], projectDir)
            : executeGradle(["compileJava"], projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("gradle_compilation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run tests
    static bool test(string projectDir, bool useWrapper = false)
    {
        structuredLog.info("running_gradle_tests").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["test"], projectDir)
            : executeGradle(["test"], projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("gradle_tests_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Create JAR
    static bool jar(string projectDir, bool useWrapper = false)
    {
        structuredLog.info("creating_jar_with_gradle").emit();
        
        auto result = useWrapper
            ? executeGradleWrapper(["jar"], projectDir)
            : executeGradle(["jar"], projectDir);
        
        return result.status == 0;
    }
    
    /// Install dependencies
    static bool installDependencies(string projectDir, bool useWrapper = false)
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
    
    /// List available tasks
    static string[] listTasks(string projectDir, bool useWrapper = false)
    {
        auto result = useWrapper
            ? executeGradleWrapper(["tasks", "--all"], projectDir)
            : executeGradle(["tasks", "--all"], projectDir);
        
        if (result.status != 0)
            return [];
        
        string[] tasks;
        foreach (line; result.output.splitLines)
        {
            auto match = matchFirst(line, regex(`^\s*(\w+)\s+-\s+`));
            if (!match.empty)
                tasks ~= match[1];
        }
        
        return tasks;
    }
    
    /// Get project properties
    static string[string] getProperties(string projectDir, bool useWrapper = false)
    {
        auto result = useWrapper
            ? executeGradleWrapper(["properties"], projectDir)
            : executeGradle(["properties"], projectDir);
        
        string[string] props;
        
        if (result.status == 0)
        {
            foreach (line; result.output.splitLines)
            {
                auto parts = line.split(":");
                if (parts.length == 2)
                    props[parts[0].strip] = parts[1].strip;
            }
        }
        
        return props;
    }
}

/// Parse subprojects from settings.gradle
string[] parseSubprojects(string settingsFile)
{
    if (!exists(settingsFile))
        return [];
    
    string[] subprojects;
    string content = readText(settingsFile);
    
    // Match include 'project1', 'project2'
    auto includePattern = regex(`include\s*\(?['"]([^'"]+)['"]`, "g");
    foreach (match; matchAll(content, includePattern))
    {
        subprojects ~= match[1];
    }
    
    return subprojects;
}

// Helper parsing functions

private string[] parseGroovyPlugins(string pluginsBlock)
{
    string[] plugins;
    
    // Match: id 'java' or id "java" or java
    auto idPattern = regex(`(?:id\s+)?['"]?([a-zA-Z0-9.-]+)['"]?`, "g");
    foreach (match; matchAll(pluginsBlock, idPattern))
    {
        string plugin = match[1].strip;
        if (!plugin.empty && plugin != "id")
            plugins ~= plugin;
    }
    
    return plugins;
}

private string[] parseKotlinPlugins(string pluginsBlock)
{
    string[] plugins;
    
    // Match: id("java") or kotlin("jvm")
    auto idPattern = regex(`(?:id|kotlin|java)\s*\(\s*"([^"]+)"\s*\)`, "g");
    foreach (match; matchAll(pluginsBlock, idPattern))
    {
        plugins ~= match[1];
    }
    
    // Also match simple identifiers
    auto simplePattern = regex(`\b(java|application)\b`, "g");
    foreach (match; matchAll(pluginsBlock, simplePattern))
    {
        plugins ~= match[1];
    }
    
    return plugins;
}

private string[] parseGroovyDependencies(string depsBlock)
{
    string[] deps;
    
    // Match: implementation 'group:artifact:version'
    auto depPattern = regex(`(?:implementation|compile|api|testImplementation|runtimeOnly)\s+['"]([^'"]+)['"]`, "g");
    foreach (match; matchAll(depsBlock, depPattern))
    {
        deps ~= match[1];
    }
    
    return deps;
}

private string[] parseKotlinDependencies(string depsBlock)
{
    string[] deps;
    
    // Match: implementation("group:artifact:version")
    auto depPattern = regex(`(?:implementation|compile|api|testImplementation|runtimeOnly)\s*\(\s*"([^"]+)"\s*\)`, "g");
    foreach (match; matchAll(depsBlock, depPattern))
    {
        deps ~= match[1];
    }
    
    return deps;
}

