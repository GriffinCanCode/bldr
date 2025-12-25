module infrastructure.migration.systems.maven;

import std.string;
import std.array;
import std.algorithm;
import std.regex;
import infrastructure.migration.core.base;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Migrator for Maven pom.xml files
final class MavenMigrator : BaseMigrator
{
    override string systemName() const pure nothrow @safe { return "maven"; }
    
    override string[] defaultFileNames() const pure nothrow @safe
    {
        return ["pom.xml"];
    }
    
    override bool canMigrate(string filePath) const @safe
    {
        import std.path : baseName;
        return baseName(filePath) == "pom.xml";
    }
    
    override string description() const pure nothrow @safe
    {
        return "Migrates Maven pom.xml to Builderfile format";
    }
    
    override string[] supportedFeatures() const pure nothrow @safe
    {
        return [
            "Standard Maven project structure",
            "Dependencies",
            "Plugins (compiler configuration)",
            "Packaging types (jar, war)"
        ];
    }
    
    override string[] limitations() const pure nothrow @safe
    {
        return [
            "Complex plugin configurations need review",
            "Multi-module projects require per-module migration",
            "Custom build phases need manual conversion"
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
        
        // Extract artifact ID for naming
        string artifactId = extractXmlTag(content, "artifactId");
        if (artifactId.empty)
            artifactId = "app";
        
        // Extract packaging type
        string packaging = extractXmlTag(content, "packaging");
        if (packaging.empty)
            packaging = "jar";
        
        // Create main build target
        MigrationTarget target;
        target.name = artifactId;
        target.type = packaging == "jar" ? TargetType.Library : TargetType.Executable;
        target.language = TargetLanguage.Java;
        target.sources = ["src/main/java/**/*.java"];
        target.output = "target/" ~ artifactId ~ "-1.0.jar";
        
        // Parse dependencies
        target.dependencies = parseMavenDependencies(content);
        
        // Parse compiler options
        string sourceVersion = extractXmlTag(content, "maven.compiler.source");
        string targetVersion = extractXmlTag(content, "maven.compiler.target");
        
        if (!sourceVersion.empty && !targetVersion.empty)
        {
            target.metadata["source"] = sourceVersion;
            target.metadata["target"] = targetVersion;
            target.flags = ["-source", sourceVersion, "-target", targetVersion];
        }
        
        targets ~= target;
        
        // Create test target if tests exist
        if (content.indexOf("src/test/java") >= 0 || content.indexOf("<scope>test</scope>") >= 0)
        {
            MigrationTarget testTarget;
            testTarget.name = artifactId ~ "-test";
            testTarget.type = TargetType.Test;
            testTarget.language = TargetLanguage.Java;
            testTarget.sources = ["src/test/java/**/*.java"];
            testTarget.dependencies = [target.name];
            
            targets ~= testTarget;
        }
        
        // Check for plugins
        if (content.indexOf("<plugins>") >= 0)
        {
            warnings ~= MigrationWarning(WarningLevel.Info,
                "Maven plugins found - review and configure manually",
                "Check pom.xml <plugins> section");
        }
        
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.success = true;
        
        return BuildResult!MigrationResult.ok(result);
    }
    
    private string extractXmlTag(string xml, string tagName)
    {
        auto pattern = regex("<" ~ tagName ~ ">([^<]+)</" ~ tagName ~ ">");
        auto match = matchFirst(xml, pattern);
        return match.empty ? "" : match[1].strip();
    }
    
    private string[] parseMavenDependencies(string xml)
    {
        // Extract all <dependency> blocks
        auto pattern = regex(r"<dependency>(.*?)</dependency>", "gs");
        string[] deps;
        
        foreach (match; matchAll(xml, pattern))
        {
            string depBlock = match[1];
            string groupId = extractXmlTag(depBlock, "groupId");
            string artifactId = extractXmlTag(depBlock, "artifactId");
            
            if (!groupId.empty && !artifactId.empty)
            {
                // Convert to simple dependency name
                deps ~= artifactId;
            }
        }
        
        return deps;
    }
}

