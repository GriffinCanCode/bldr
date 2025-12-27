module languages.compiled.haskell.analysis.cabal;

import std.stdio;
import std.file;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.regex;
import infrastructure.utils.logging;

/// Cabal package metadata
struct CabalMetadata
{
    string name;
    string version_;
    string license;
    string author;
    string maintainer;
    string category;
    string synopsis;
    string description;
    string homepage;
    string bugReports;
    string[] buildDepends;
    string[] otherModules;
    string[] exposedModules;
    CabalExecutable[] executables;
    CabalLibrary[] libraries;
    CabalTestSuite[] testSuites;
    
    /// Parse cabal file from path
    static CabalMetadata fromFile(string path)
    {
        if (!exists(path))
        {
            structuredLog.warning("cabal_file_not_found_").field("detail", "Cabal file not found: " ~ path).emit();
            return CabalMetadata();
        }
        
        try
        {
            string content = readText(path);
            return parse(content);
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_parse_cabal_file_").field("detail", "Failed to parse cabal file: " ~ e.msg).emit();
            return CabalMetadata();
        }
    }
    
    /// Parse cabal file content
    static CabalMetadata parse(string content)
    {
        CabalMetadata meta;
        
        // Parse package metadata
        meta.name = extractField(content, "name");
        meta.version_ = extractField(content, "version");
        meta.license = extractField(content, "license");
        meta.author = extractField(content, "author");
        meta.maintainer = extractField(content, "maintainer");
        meta.category = extractField(content, "category");
        meta.synopsis = extractField(content, "synopsis");
        meta.description = extractField(content, "description");
        meta.homepage = extractField(content, "homepage");
        meta.bugReports = extractField(content, "bug-reports");
        
        // Parse build dependencies
        meta.buildDepends = extractDependencies(content, "build-depends");
        
        // Parse library section
        meta.libraries = parseLibraries(content);
        
        // Parse executable sections
        meta.executables = parseExecutables(content);
        
        // Parse test suites
        meta.testSuites = parseTestSuites(content);
        
        // Extract exposed and other modules
        meta.exposedModules = extractModuleList(content, "exposed-modules");
        meta.otherModules = extractModuleList(content, "other-modules");
        
        return meta;
    }
}

/// Cabal executable configuration
struct CabalExecutable
{
    string name;
    string mainIs;
    string[] buildDepends;
    string[] otherModules;
    string hsSourceDirs;
    string defaultLanguage;
}

/// Cabal library configuration
struct CabalLibrary
{
    string[] exposedModules;
    string[] otherModules;
    string[] buildDepends;
    string hsSourceDirs;
    string defaultLanguage;
}

/// Cabal test suite configuration
struct CabalTestSuite
{
    string name;
    string type;
    string mainIs;
    string[] buildDepends;
    string[] otherModules;
    string hsSourceDirs;
}

/// Extract a simple field value
private string extractField(string content, string fieldName)
{
    auto pattern = regex(`^` ~ fieldName ~ `\s*:\s*(.+?)$`, "mi");
    auto match = matchFirst(content, pattern);
    
    if (!match.empty && match.length >= 2)
        return match[1].strip;
    
    return "";
}

/// Extract multi-line field value
private string extractMultilineField(string content, string fieldName)
{
    auto pattern = regex(`^` ~ fieldName ~ `\s*:\s*(.+?)(?=^\S|\z)`, "msi");
    auto match = matchFirst(content, pattern);
    
    if (!match.empty && match.length >= 2)
    {
        // Join continuation lines
        string value = match[1];
        value = value.replaceAll(regex(`\s+`), " ");
        return value.strip;
    }
    
    return "";
}

/// Extract dependencies from build-depends field
private string[] extractDependencies(string content, string fieldName)
{
    string[] deps;
    
    auto pattern = regex(`^` ~ fieldName ~ `\s*:\s*(.+?)(?=^\S|\z)`, "msi");
    auto match = matchFirst(content, pattern);
    
    if (!match.empty && match.length >= 2)
    {
        string depStr = match[1];
        // Remove newlines and normalize spaces
        depStr = depStr.replaceAll(regex(`\s+`), " ");
        
        // Split by comma
        auto depParts = depStr.split(",");
        
        foreach (dep; depParts)
        {
            dep = dep.strip;
            if (!dep.empty)
            {
                // Extract package name (before version constraints)
                auto nameMatch = matchFirst(dep, regex(`^([\w-]+)`));
                if (!nameMatch.empty)
                    deps ~= nameMatch[1];
            }
        }
    }
    
    return deps;
}

/// Extract module list
private string[] extractModuleList(string content, string fieldName)
{
    string[] modules;
    
    auto pattern = regex(`^` ~ fieldName ~ `\s*:\s*(.+?)(?=^\S|\z)`, "msi");
    auto match = matchFirst(content, pattern);
    
    if (!match.empty && match.length >= 2)
    {
        string modStr = match[1];
        // Remove newlines and normalize spaces
        modStr = modStr.replaceAll(regex(`\s+`), " ");
        
        // Split by comma or whitespace
        modules = modStr.split(regex(`[,\s]+`))
            .filter!(m => !m.empty)
            .array;
    }
    
    return modules;
}

/// Parse library sections
private CabalLibrary[] parseLibraries(string content)
{
    CabalLibrary[] libs;
    
    // Match library section
    auto libPattern = regex(`^library\s*$(.+?)(?=^(?:executable|test-suite|benchmark|\z))`, "msi");
    
    foreach (match; matchAll(content, libPattern))
    {
        if (match.length >= 2)
        {
            string section = match[1];
            
            CabalLibrary lib;
            lib.exposedModules = extractModuleList(section, "exposed-modules");
            lib.otherModules = extractModuleList(section, "other-modules");
            lib.buildDepends = extractDependencies(section, "build-depends");
            lib.hsSourceDirs = extractField(section, "hs-source-dirs");
            lib.defaultLanguage = extractField(section, "default-language");
            
            libs ~= lib;
        }
    }
    
    return libs;
}

/// Parse executable sections
private CabalExecutable[] parseExecutables(string content)
{
    CabalExecutable[] execs;
    
    // Match executable sections
    auto execPattern = regex(`^executable\s+(\S+)\s*$(.+?)(?=^(?:executable|library|test-suite|benchmark|\z))`, "msi");
    
    foreach (match; matchAll(content, execPattern))
    {
        if (match.length >= 3)
        {
            string name = match[1].strip;
            string section = match[2];
            
            CabalExecutable exec;
            exec.name = name;
            exec.mainIs = extractField(section, "main-is");
            exec.buildDepends = extractDependencies(section, "build-depends");
            exec.otherModules = extractModuleList(section, "other-modules");
            exec.hsSourceDirs = extractField(section, "hs-source-dirs");
            exec.defaultLanguage = extractField(section, "default-language");
            
            execs ~= exec;
        }
    }
    
    return execs;
}

/// Parse test suite sections
private CabalTestSuite[] parseTestSuites(string content)
{
    CabalTestSuite[] tests;
    
    // Match test-suite sections
    auto testPattern = regex(`^test-suite\s+(\S+)\s*$(.+?)(?=^(?:executable|library|test-suite|benchmark|\z))`, "msi");
    
    foreach (match; matchAll(content, testPattern))
    {
        if (match.length >= 3)
        {
            string name = match[1].strip;
            string section = match[2];
            
            CabalTestSuite test;
            test.name = name;
            test.type = extractField(section, "type");
            test.mainIs = extractField(section, "main-is");
            test.buildDepends = extractDependencies(section, "build-depends");
            test.otherModules = extractModuleList(section, "other-modules");
            test.hsSourceDirs = extractField(section, "hs-source-dirs");
            
            tests ~= test;
        }
    }
    
    return tests;
}

/// Parse cabal file and return metadata
CabalMetadata parseCabalFile(string path)
{
    return CabalMetadata.fromFile(path);
}
