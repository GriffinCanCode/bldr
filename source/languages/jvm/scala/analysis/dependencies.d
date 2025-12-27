module languages.jvm.scala.analysis.dependencies;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.regex;
import languages.jvm.scala.core.config;
import languages.jvm.scala.tooling.detection;
import languages.jvm.scala.managers.sbt;
import infrastructure.utils.logging;

/// Scala dependency information
struct ScalaDependency
{
    string organization;
    string name;
    string version_;
    string scope_ = "compile";
    bool isScalaLibrary = false;
    
    /// Get full coordinate
    string coordinate() const
    {
        return organization ~ ":" ~ name ~ ":" ~ version_;
    }
}

/// Dependency analyzer for Scala projects
class DependencyAnalyzer
{
    /// Analyze dependencies from project
    static ScalaDependency[] analyzeDependencies(string projectDir)
    {
        // Try sbt first
        if (ScalaToolDetection.hasBuildSbt(projectDir))
        {
            return analyzeSbtDependencies(projectDir);
        }
        
        // Try Mill
        if (ScalaToolDetection.hasBuildSc(projectDir))
        {
            return analyzeMillDependencies(projectDir);
        }
        
        return [];
    }
    
    /// Analyze sbt dependencies
    static ScalaDependency[] analyzeSbtDependencies(string projectDir)
    {
        ScalaDependency[] deps;
        
        string buildSbtPath = buildPath(projectDir, "build.sbt");
        if (!exists(buildSbtPath))
            return deps;
        
        try
        {
            auto meta = SbtMetadata.fromFile(buildSbtPath);
            
            foreach (dep; meta.dependencies)
            {
                ScalaDependency scalaDep;
                scalaDep.organization = dep.organization;
                scalaDep.name = dep.name;
                scalaDep.version_ = dep.version_;
                scalaDep.scope_ = dep.scope_;
                scalaDep.isScalaLibrary = dep.organization == "org.scala-lang" && 
                                          dep.name.startsWith("scala-");
                
                deps ~= scalaDep;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_analyze_sbt_dependencies_").field("detail", "Failed to analyze sbt dependencies: " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Analyze Mill dependencies
    static ScalaDependency[] analyzeMillDependencies(string projectDir)
    {
        ScalaDependency[] deps;
        
        string buildScPath = buildPath(projectDir, "build.sc");
        if (!exists(buildScPath))
            return deps;
        
        try
        {
            auto content = readText(buildScPath);
            
            // Look for ivy dependencies: ivy"org::name:version"
            auto pattern = regex(`ivy"([^:]+)::([^:]+):([^"]+)"`);
            
            foreach (match; matchAll(content, pattern))
            {
                ScalaDependency dep;
                dep.organization = match[1];
                dep.name = match[2];
                dep.version_ = match[3];
                dep.isScalaLibrary = dep.organization == "org.scala-lang";
                
                deps ~= dep;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_analyze_mill_dependencies_").field("detail", "Failed to analyze Mill dependencies: " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Extract imports from Scala source file
    static string[] extractImports(string sourceFile)
    {
        string[] imports;
        
        if (!exists(sourceFile))
            return imports;
        
        try
        {
            auto content = readText(sourceFile);
            
            // Match import statements
            auto pattern = regex(`import\s+([\w.]+(?:\.\{[^}]+\})?)`);
            
            foreach (match; matchAll(content, pattern))
            {
                imports ~= match[1];
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_extract_imports_from_").field("detail", "Failed to extract imports from " ~ sourceFile).emit();
        }
        
        return imports;
    }
}

