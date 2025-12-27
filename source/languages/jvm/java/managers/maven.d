module languages.jvm.java.managers.maven;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.process;
import std.regex;
import std.conv;
import infrastructure.utils.logging;

/// Maven pom.xml metadata
struct MavenMetadata
{
    string groupId;
    string artifactId;
    string version_;
    string packaging = "jar";
    string name;
    string description;
    
    Dependency[] dependencies;
    Dependency[] dependencyManagement;
    Plugin[] plugins;
    string[] modules;
    Parent parent;
    Properties properties;
    
    Build build;
    
    /// Parse from pom.xml file
    static MavenMetadata fromFile(string pomPath)
    {
        if (!exists(pomPath))
            assert(false, "fileNotFoundError (Maven dependency analysis): " ~ pomPath);
        
        string content = readText(pomPath);
        return fromXML(content);
    }
    
    /// Parse from XML string
    static MavenMetadata fromXML(string xmlContent)
    {
        MavenMetadata meta;
        
        try
        {
            // Simple regex-based parsing (XML parsing in D can be complex)
            // For production, consider using a proper XML library
            
            meta.groupId = extractTag(xmlContent, "groupId");
            meta.artifactId = extractTag(xmlContent, "artifactId");
            meta.version_ = extractTag(xmlContent, "version");
            meta.packaging = extractTag(xmlContent, "packaging", "jar");
            meta.name = extractTag(xmlContent, "name");
            meta.description = extractTag(xmlContent, "description");
            
            // Parse dependencies
            auto depsMatch = matchFirst(xmlContent, regex(`<dependencies>(.*?)</dependencies>`, "s"));
            if (!depsMatch.empty)
            {
                meta.dependencies = parseDependencies(depsMatch[1]);
            }
            
            // Parse modules
            auto modulesMatch = matchFirst(xmlContent, regex(`<modules>(.*?)</modules>`, "s"));
            if (!modulesMatch.empty)
            {
                meta.modules = parseModules(modulesMatch[1]);
            }
            
            // Parse properties
            auto propsMatch = matchFirst(xmlContent, regex(`<properties>(.*?)</properties>`, "s"));
            if (!propsMatch.empty)
            {
                meta.properties = parseProperties(propsMatch[1]);
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_pomxml_").field("detail", "Failed to parse pom.xml: " ~ e.msg).emit();
        }
        
        return meta;
    }
    
    /// Get Java version from properties or compiler plugin
    string getJavaVersion() const
    {
        // Check maven.compiler.source or maven.compiler.release
        if ("maven.compiler.release" in properties.props)
            return properties.props["maven.compiler.release"];
        if ("maven.compiler.source" in properties.props)
            return properties.props["maven.compiler.source"];
        if ("java.version" in properties.props)
            return properties.props["java.version"];
        
        return "1.8"; // Default
    }
    
    /// Check if this is a multi-module project
    bool isMultiModule() const
    {
        return !modules.empty;
    }
    
    /// Check if Spring Boot is used
    bool usesSpringBoot() const
    {
        foreach (dep; dependencies)
        {
            if (dep.artifactId.canFind("spring-boot"))
                return true;
        }
        return false;
    }
    
    /// Get main class from properties or plugins
    string getMainClass() const
    {
        if ("mainClass" in properties.props)
            return properties.props["mainClass"];
        if ("exec.mainClass" in properties.props)
            return properties.props["exec.mainClass"];
        if ("start-class" in properties.props)
            return properties.props["start-class"];
        
        return "";
    }
}

/// Maven dependency
struct Dependency
{
    string groupId;
    string artifactId;
    string version_;
    string scope_ = "compile";
    string type = "jar";
    string classifier;
    bool optional = false;
    Exclusion[] exclusions;
    
    /// Get full coordinate
    string coordinate() const
    {
        string coord = groupId ~ ":" ~ artifactId;
        if (!version_.empty)
            coord ~= ":" ~ version_;
        if (!classifier.empty)
            coord ~= ":" ~ classifier;
        return coord;
    }
}

/// Maven exclusion
struct Exclusion
{
    string groupId;
    string artifactId;
}

/// Maven plugin
struct Plugin
{
    string groupId;
    string artifactId;
    string version_;
    string[string] configuration;
    Execution[] executions;
}

/// Plugin execution
struct Execution
{
    string id;
    string phase;
    string[] goals;
}

/// Maven parent
struct Parent
{
    string groupId;
    string artifactId;
    string version_;
    string relativePath = "../pom.xml";
}

/// Maven properties
struct Properties
{
    string[string] props;
}

/// Maven build configuration
struct Build
{
    string sourceDirectory = "src/main/java";
    string testSourceDirectory = "src/test/java";
    string outputDirectory = "target/classes";
    string testOutputDirectory = "target/test-classes";
    string finalName;
    Plugin[] plugins;
}

/// Maven operations
class MavenOps
{
    /// Execute Maven command
    static auto executeMaven(string[] args, string workingDir = ".")
    {
        return execute(["mvn"] ~ args, null, Config.none, size_t.max, workingDir);
    }
    
    /// Execute Maven wrapper command
    static auto executeMavenWrapper(string[] args, string workingDir = ".")
    {
        version(Windows)
            string mvnw = ".\\mvnw.cmd";
        else
            string mvnw = "./mvnw";
        
        return execute([mvnw] ~ args, null, Config.none, size_t.max, workingDir);
    }
    
    /// Install dependencies
    static bool installDependencies(string projectDir, bool useWrapper = false)
    {
        structuredLog.info("installing_maven_dependencies").emit();
        
        auto result = useWrapper 
            ? executeMavenWrapper(["dependency:resolve"], projectDir)
            : executeMaven(["dependency:resolve"], projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("maven_dependency_installation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Clean build
    static bool clean(string projectDir, bool useWrapper = false)
    {
        structuredLog.info("cleaning_maven_project").emit();
        
        auto result = useWrapper
            ? executeMavenWrapper(["clean"], projectDir)
            : executeMaven(["clean"], projectDir);
        
        return result.status == 0;
    }
    
    /// Compile sources
    static bool compile(string projectDir, bool skipTests = false, bool useWrapper = false)
    {
        structuredLog.info("compiling_maven_project").emit();
        
        string[] args = ["compile"];
        if (skipTests)
            args ~= "-DskipTests";
        
        auto result = useWrapper
            ? executeMavenWrapper(args, projectDir)
            : executeMaven(args, projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("maven_compilation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Package project
    static bool packageProject(string projectDir, bool skipTests = false, bool useWrapper = false)
    {
        structuredLog.info("packaging_maven_project").emit();
        
        string[] args = ["package"];
        if (skipTests)
            args ~= "-DskipTests";
        
        auto result = useWrapper
            ? executeMavenWrapper(args, projectDir)
            : executeMaven(args, projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("maven_packaging_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run tests
    static bool test(string projectDir, bool useWrapper = false)
    {
        structuredLog.info("running_maven_tests").emit();
        
        auto result = useWrapper
            ? executeMavenWrapper(["test"], projectDir)
            : executeMaven(["test"], projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("maven_tests_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Get effective POM
    static string getEffectivePom(string projectDir, bool useWrapper = false)
    {
        auto result = useWrapper
            ? executeMavenWrapper(["help:effective-pom", "-Doutput=/dev/stdout"], projectDir)
            : executeMaven(["help:effective-pom", "-Doutput=/dev/stdout"], projectDir);
        
        return result.status == 0 ? result.output : "";
    }
    
    /// Get Maven version
    static string getVersion()
    {
        auto result = execute(["mvn", "-version"]);
        if (result.status == 0)
        {
            auto match = matchFirst(result.output, regex(`Apache Maven ([\d.]+)`));
            if (!match.empty)
                return match[1];
        }
        return "";
    }
}

// Helper functions for parsing

private string extractTag(string xml, string tagName, string defaultValue = "")
{
    auto pattern = regex(`<` ~ tagName ~ `>(.*?)</` ~ tagName ~ `>`, "s");
    auto match = matchFirst(xml, pattern);
    return match.empty ? defaultValue : match[1].strip;
}

private Dependency[] parseDependencies(string depsXml)
{
    Dependency[] deps;
    
    auto depPattern = regex(`<dependency>(.*?)</dependency>`, "sg");
    foreach (match; matchAll(depsXml, depPattern))
    {
        Dependency dep;
        string depXml = match[1];
        
        dep.groupId = extractTag(depXml, "groupId");
        dep.artifactId = extractTag(depXml, "artifactId");
        dep.version_ = extractTag(depXml, "version");
        dep.scope_ = extractTag(depXml, "scope", "compile");
        dep.type = extractTag(depXml, "type", "jar");
        dep.classifier = extractTag(depXml, "classifier");
        
        string optionalStr = extractTag(depXml, "optional");
        dep.optional = optionalStr == "true";
        
        if (!dep.groupId.empty && !dep.artifactId.empty)
            deps ~= dep;
    }
    
    return deps;
}

private string[] parseModules(string modulesXml)
{
    string[] modules;
    
    auto modulePattern = regex(`<module>(.*?)</module>`, "sg");
    foreach (match; matchAll(modulesXml, modulePattern))
    {
        string moduleName = match[1].strip;
        if (!moduleName.empty)
            modules ~= moduleName;
    }
    
    return modules;
}

private Properties parseProperties(string propsXml)
{
    Properties props;
    
    // Match any <tag>value</tag> pattern
    auto propPattern = regex(`<([^>]+)>(.*?)</\1>`, "sg");
    foreach (match; matchAll(propsXml, propPattern))
    {
        string key = match[1].strip;
        string value = match[2].strip;
        if (!key.empty)
            props.props[key] = value;
    }
    
    return props;
}

