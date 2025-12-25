module infrastructure.migration.systems.sbt;

import std.string;
import std.array;
import std.algorithm;
import std.regex;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for Scala SBT build.sbt files
final class SbtMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "sbt"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["build.sbt"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        return baseName(filePath) == "build.sbt";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Scala SBT build.sbt to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Project name and version",
            "Scala version",
            "Library dependencies",
            "Standard directory structure"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Multi-project builds need per-project migration",
            "Complex SBT tasks require manual conversion",
            "Plugins need manual configuration"
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
        
        // Extract project name
        auto namePattern = regex(`name\s*:=\s*"([^"]+)"`);
        auto nameMatch = matchFirst(content, namePattern);
        string projectName = nameMatch.empty ? "app" : nameMatch[1];
        
        // Create main target
        MigrationTarget target;
        target.name = projectName;
        target.type = TargetType.Library;
        target.language = TargetLanguage.Scala;
        target.sources = ["src/main/scala/**/*.scala"];
        
        // Extract Scala version
        auto scalaPattern = regex(`scalaVersion\s*:=\s*"([^"]+)"`);
        auto scalaMatch = matchFirst(content, scalaPattern);
        if (!scalaMatch.empty)
            target.metadata["scala_version"] = scalaMatch[1];
        
        targets ~= target;
        
        // Check for test dependencies
        if (content.indexOf("Test") >= 0 || content.indexOf("test") >= 0)
        {
            MigrationTarget testTarget;
            testTarget.name = projectName ~ "-test";
            testTarget.type = TargetType.Test;
            testTarget.language = TargetLanguage.Scala;
            testTarget.sources = ["src/test/scala/**/*.scala"];
            testTarget.dependencies = [target.name];
            
            targets ~= testTarget;
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
}

