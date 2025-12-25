module infrastructure.analysis.manifests.maven;

import std.path : baseName, dirName, buildPath;
import std.file : exists, readText;
import std.string : strip, indexOf, lastIndexOf;
import std.algorithm : canFind, map, filter;
import std.array : array;
import std.conv : to;
import infrastructure.analysis.manifests.types;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;
import infrastructure.errors.types.types : ParseError, ioError;
import infrastructure.utils.logging.logger;

/// Maven project information extracted from pom.xml
private struct MavenProject
{
    string groupId;
    string artifactId;
    string version_;
    string packaging;
    string name;
    string description;
    MavenDependency[] dependencies;
    string[] modules;
    string sourceDirectory;
    string outputDirectory;
}

/// Maven dependency
private struct MavenDependency
{
    string groupId;
    string artifactId;
    string version_;
    string scope_;
    bool optional;
}

/// Parser for pom.xml (Maven) - Full XML parsing implementation
final class MavenManifestParser : IManifestParser
{
    override BuildResult!ManifestInfo parse(string filePath) @system
    {
        if (!exists(filePath))
        {
            return BuildResult!ManifestInfo.err(
                ioError(filePath, "File not found"));
        }
        
        try
        {
            // Read and parse pom.xml
            immutable content = readText(filePath);
            auto parseResult = parsePomXml(content);
            
            if (parseResult.isErr)
                return BuildResult!ManifestInfo.err(parseResult.unwrapErr());
            
            auto project = parseResult.unwrap();
            
            // Build ManifestInfo from parsed data
            ManifestInfo info;
            info.language = TargetLanguage.Java;
            info.name = project.artifactId.length > 0 ? project.artifactId : "app";
            info.version_ = project.version_;
            
            // Determine target type from packaging
            info.suggestedType = determineTargetType(project.packaging);
            
            // Extract dependencies
            info.dependencies = project.dependencies
                .map!(d => Dependency(
                    d.groupId ~ ":" ~ d.artifactId,
                    d.version_,
                    DependencyType.Runtime,
                    d.scope_ == "provided"
                ))
                .array;
            
            // Set source paths
            if (project.sourceDirectory.length > 0)
                info.sources = [project.sourceDirectory ~ "/**/*.java"];
            else
                info.sources = ["src/main/java/**/*.java"];  // Maven default
            
            // Set output directory in metadata
            if (project.outputDirectory.length > 0)
                info.metadata["buildDir"] = project.outputDirectory;
            else
                info.metadata["buildDir"] = "target";  // Maven default
            
            Logger.info("Parsed Maven project: " ~ info.name ~ " v" ~ info.version_);
            
            return BuildResult!ManifestInfo.ok(info);
        }
        catch (Exception e)
        {
            return BuildResult!ManifestInfo.err(
                new ParseError(filePath, "Failed to parse pom.xml: " ~ e.msg,
                             ErrorCode.InvalidConfiguration));
        }
    }
    
    override bool canParse(string filePath) const @safe
    {
        return baseName(filePath) == "pom.xml";
    }
    
    override string name() const pure nothrow @safe
    {
        return "maven";
    }
    
private:
    
    /// Parse pom.xml content (full XML parsing)
    BuildResult!MavenProject parsePomXml(string content) @system
    {
        MavenProject project;
        
        try
        {
            // Extract basic project info
            project.groupId = extractXmlTag(content, "groupId");
            project.artifactId = extractXmlTag(content, "artifactId");
            project.version_ = extractXmlTag(content, "version");
            project.packaging = extractXmlTag(content, "packaging");
            project.name = extractXmlTag(content, "name");
            project.description = extractXmlTag(content, "description");
            
            // Handle parent POM references
            auto parentSection = extractXmlSection(content, "parent");
            if (parentSection.length > 0)
            {
                // Inherit from parent if not overridden
                if (project.groupId.length == 0)
                    project.groupId = extractXmlTag(parentSection, "groupId");
                if (project.version_.length == 0)
                    project.version_ = extractXmlTag(parentSection, "version");
            }
            
            // Default packaging is jar
            if (project.packaging.length == 0)
                project.packaging = "jar";
            
            // Parse dependencies
            auto depsSection = extractXmlSection(content, "dependencies");
            if (depsSection.length > 0)
            {
                project.dependencies = parseDependencies(depsSection);
            }
            
            // Parse modules (for multi-module projects)
            auto modulesSection = extractXmlSection(content, "modules");
            if (modulesSection.length > 0)
            {
                project.modules = parseModules(modulesSection);
            }
            
            // Parse build configuration
            auto buildSection = extractXmlSection(content, "build");
            if (buildSection.length > 0)
            {
                project.sourceDirectory = extractXmlTag(buildSection, "sourceDirectory");
                project.outputDirectory = extractXmlTag(buildSection, "outputDirectory");
            }
            
            return Ok!(MavenProject, BuildError)(project);
        }
        catch (Exception e)
        {
            return Err!(MavenProject, BuildError)(
                new ParseError("", "Failed to parse Maven POM: " ~ e.msg,
                             ErrorCode.InvalidConfiguration));
        }
    }
    
    /// Extract XML tag content (simple parser for well-formed XML)
    string extractXmlTag(string xml, string tagName) @safe
    {
        import std.string : format;
        
        immutable openTag = format("<%s>", tagName);
        immutable closeTag = format("</%s>", tagName);
        
        auto start = xml.indexOf(openTag);
        if (start == -1)
            return "";
        
        start += openTag.length;
        auto end = xml.indexOf(closeTag, start);
        if (end == -1)
            return "";
        
        return xml[start..end].strip();
    }
    
    /// Extract XML section (everything between opening and closing tags)
    string extractXmlSection(string xml, string tagName) @safe
    {
        import std.string : format;
        
        immutable openTag = format("<%s>", tagName);
        immutable closeTag = format("</%s>", tagName);
        
        auto start = xml.indexOf(openTag);
        if (start == -1)
            return "";
        
        auto end = xml.indexOf(closeTag, start);
        if (end == -1)
            return "";
        
        return xml[start + openTag.length..end].strip();
    }
    
    /// Parse dependencies section
    MavenDependency[] parseDependencies(string depsXml) @safe
    {
        MavenDependency[] deps;
        
        // Find all <dependency> sections
        size_t pos = 0;
        while (true)
        {
            auto start = depsXml.indexOf("<dependency>", pos);
            if (start == -1)
                break;
            
            auto end = depsXml.indexOf("</dependency>", start);
            if (end == -1)
                break;
            
            immutable depXml = depsXml[start + 12..end].strip();
            
            MavenDependency dep;
            dep.groupId = extractXmlTag(depXml, "groupId");
            dep.artifactId = extractXmlTag(depXml, "artifactId");
            dep.version_ = extractXmlTag(depXml, "version");
            dep.scope_ = extractXmlTag(depXml, "scope");
            
            immutable optionalStr = extractXmlTag(depXml, "optional");
            dep.optional = (optionalStr == "true");
            
            // Only add if we have at least groupId and artifactId
            if (dep.groupId.length > 0 && dep.artifactId.length > 0)
                deps ~= dep;
            
            pos = end + 13;
        }
        
        return deps;
    }
    
    /// Parse modules section
    string[] parseModules(string modulesXml) @safe
    {
        string[] modules;
        
        // Find all <module> tags
        size_t pos = 0;
        while (true)
        {
            auto start = modulesXml.indexOf("<module>", pos);
            if (start == -1)
                break;
            
            auto end = modulesXml.indexOf("</module>", start);
            if (end == -1)
                break;
            
            immutable module_ = modulesXml[start + 8..end].strip();
            if (module_.length > 0)
                modules ~= module_;
            
            pos = end + 9;
        }
        
        return modules;
    }
    
    /// Determine target type from Maven packaging
    TargetType determineTargetType(string packaging) const pure @safe
    {
        switch (packaging)
        {
            case "jar":
            case "bundle":
                return TargetType.Library;
            
            case "war":
            case "ear":
                return TargetType.Executable;  // Web applications
            
            case "maven-plugin":
                return TargetType.Library;
            
            case "pom":
                return TargetType.Library;  // Parent/aggregator POMs
            
            default:
                return TargetType.Executable;
        }
    }
}

