module infrastructure.migration.systems.gradle;

import std.string;
import std.array;
import std.algorithm;
import std.regex;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for Gradle build.gradle files
final class GradleMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "gradle"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["build.gradle", "build.gradle.kts"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        auto name = baseName(filePath);
        return name == "build.gradle" || name == "build.gradle.kts";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Gradle build.gradle to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Java/Kotlin/Groovy projects",
            "Application plugin",
            "Java library plugin",
            "Dependencies",
            "Source sets"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Complex Gradle scripts require manual review",
            "Custom tasks need manual conversion",
            "Multi-project builds need per-project migration"
        ];
    }
    
    override BuildResult!MigrationResult migrate(string inputPath) @system
    {
        auto contentResult = readInputFile(inputPath);
        if (contentResult.isErr)
            return BuildResult!MigrationResult.err(contentResult.unwrapErr());
        
        auto content = contentResult.unwrap();
        MigrationTarget[] targets;
        MigrationWarning[] warnings;
        
        // Detect language
        TargetLanguage language = TargetLanguage.Java;
        if (content.indexOf("kotlin") >= 0 || content.indexOf(".kt") >= 0)
            language = TargetLanguage.Kotlin;
        else if (content.indexOf("groovy") >= 0)
            language = TargetLanguage.Generic;  // Groovy not directly supported
        
        // Detect plugins
        bool hasApplication = content.indexOf("application") >= 0 || 
                             content.indexOf("'application'") >= 0;
        bool hasJavaLibrary = content.indexOf("java-library") >= 0;
        
        // Extract project name
        string projectName = "app";
        auto namePattern = regex(`rootProject\.name\s*=\s*['"]([^'"]+)['"]`);
        auto nameMatch = matchFirst(content, namePattern);
        if (!nameMatch.empty)
            projectName = nameMatch[1];
        
        // Create main target
        MigrationTarget target;
        target.name = projectName;
        target.type = hasApplication ? TargetType.Executable : TargetType.Library;
        target.language = language;
        
        string ext = language == TargetLanguage.Kotlin ? "kt" : "java";
        target.sources = ["src/main/" ~ ext ~ "/**/*." ~ ext];
        
        // Parse dependencies
        target.dependencies = parseGradleDependencies(content);
        
        targets ~= target;
        
        // Create test target if test dependencies found
        if (content.indexOf("testImplementation") >= 0 || 
            content.indexOf("testCompile") >= 0)
        {
            MigrationTarget testTarget;
            testTarget.name = projectName ~ "-test";
            testTarget.type = TargetType.Test;
            testTarget.language = language;
            testTarget.sources = ["src/test/" ~ ext ~ "/**/*." ~ ext];
            testTarget.dependencies = [target.name];
            
            targets ~= testTarget;
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
    
    private string[] parseGradleDependencies(string content)
    {
        // Match: implementation 'group:artifact:version'
        auto pattern = regex(`(?:implementation|api|compile)\s+['"]([^:'"]+):([^:'"]+)`);
        string[] deps;
        
        foreach (match; matchAll(content, pattern))
        {
            // Use artifact name as dependency
            deps ~= match[2];
        }
        
        return deps;
    }
}

