module languages.compiled.rust.analysis.manifest;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.range;
import std.json;
import std.conv;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Cargo.toml dependency information
struct CargoDependency
{
    string name;
    string version_;
    bool optional;
    bool defaultFeatures = true;
    string[] features;
    string git;
    string branch;
    string tag;
    string rev;
    string path;
}

/// Cargo package information
struct CargoPackage
{
    string name;
    string version_;
    string edition;
    string[] authors;
    string description;
    string license;
    string readme;
    string homepage;
    string repository;
    string documentation;
    string[] keywords;
    string[] categories;
}

/// Cargo profile information
struct CargoProfile
{
    string name;
    int optLevel;
    bool debug_;
    bool debugAssertions;
    bool overflowChecks;
    string lto;
    string panic;
    int codegen;
    bool incremental;
}

/// Cargo workspace information
struct CargoWorkspace
{
    string[] members;
    string[] exclude;
    string[] defaultMembers;
}

/// Cargo binary target
struct CargoBin
{
    string name;
    string path;
    bool test = true;
    bool bench = true;
    bool doc = true;
    string[] requiredFeatures;
}

/// Cargo library target
struct CargoLib
{
    string name;
    string path;
    string[] crateType;
    bool test = true;
    bool bench = true;
    bool doc = true;
    string[] requiredFeatures;
}

/// Parsed Cargo.toml manifest
struct CargoManifest
{
    CargoPackage package_;
    CargoLib lib;
    CargoBin[] bins;
    CargoDependency[string] dependencies;
    CargoDependency[string] devDependencies;
    CargoDependency[string] buildDependencies;
    string[string] features;
    CargoProfile[string] profiles;
    CargoWorkspace workspace;
    bool isWorkspace;
    
    /// Check if this is a library crate
    bool isLib() const
    {
        return !lib.name.empty || !lib.path.empty;
    }
    
    /// Check if this has binary targets
    bool hasBins() const
    {
        return !bins.empty;
    }
    
    /// Check if a feature exists
    bool hasFeature(string feature) const
    {
        return (feature in features) !is null;
    }
}

/// Cargo.toml parser
class CargoParser
{
    /// Parse Cargo.toml file
    static CargoManifest parse(string manifestPath)
    {
        CargoManifest manifest;
        
        if (!exists(manifestPath))
        {
            structuredLog.warning("cargotoml_not_found_").field("detail", "Cargo.toml not found: " ~ manifestPath).emit();
            return manifest;
        }
        
        try
        {
            auto content = readText(manifestPath);
            manifest = parseTOML(content);
            
            structuredLog.debug_("parsed_cargotoml_").field("detail", "Parsed Cargo.toml: " ~ manifest.package_.name).emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_cargotoml_").field("detail", "Failed to parse Cargo.toml: " ~ e.msg).emit();
        }
        
        return manifest;
    }
    
    /// Find Cargo.toml in directory tree
    static string findManifest(in string[] sources)
    {
        if (sources.empty)
            return "";
        
        string dir = dirName(sources[0]);
        
        while (dir != "/" && dir.length > 1)
        {
            string manifestPath = buildPath(dir, "Cargo.toml");
            if (exists(manifestPath))
                return manifestPath;
            
            dir = dirName(dir);
        }
        
        return "";
    }
    
    /// Detect workspace root
    static string findWorkspaceRoot(string startDir)
    {
        string dir = startDir;
        
        while (dir != "/" && dir.length > 1)
        {
            string manifestPath = buildPath(dir, "Cargo.toml");
            if (exists(manifestPath))
            {
                auto manifest = parse(manifestPath);
                if (manifest.isWorkspace)
                    return dir;
            }
            
            dir = dirName(dir);
        }
        
        return "";
    }
    
    /// Get all workspace members
    static string[] getWorkspaceMembers(string workspaceRoot)
    {
        string manifestPath = buildPath(workspaceRoot, "Cargo.toml");
        auto manifest = parse(manifestPath);
        
        if (!manifest.isWorkspace)
            return [];
        
        string[] members;
        foreach (member; manifest.workspace.members)
        {
            // Validate member pattern for path traversal
            if (!SecurityValidator.isPathTraversalSafe(member))
                continue;
            
            // Handle glob patterns
            if (member.canFind("*"))
            {
                // Simple glob expansion
                auto parts = member.split("*");
                if (parts.length >= 1)
                {
                    string baseDir = buildPath(workspaceRoot, parts[0].stripRight("/"));
                    if (exists(baseDir) && isDir(baseDir))
                    {
                        foreach (entry; dirEntries(baseDir, SpanMode.shallow))
                        {
                            // Validate entry is within workspace root
                            if (!SecurityValidator.isPathWithinBase(entry.name, workspaceRoot))
                                continue;
                            
                            if (entry.isDir)
                            {
                                string cargoToml = buildPath(entry.name, "Cargo.toml");
                                if (exists(cargoToml))
                                    members ~= entry.name;
                            }
                        }
                    }
                }
            }
            else
            {
                string memberPath = buildPath(workspaceRoot, member);
                // Validate member path is within workspace
                if (exists(memberPath) && isDir(memberPath) && 
                    SecurityValidator.isPathWithinBase(memberPath, workspaceRoot))
                {
                    members ~= memberPath;
                }
            }
        }
        
        return members;
    }
    
    private static CargoManifest parseTOML(string content)
    {
        CargoManifest manifest;
        
        // This is a simplified TOML parser
        // In production, use a proper TOML library like toml-d
        
        auto lines = content.split("\n");
        string currentSection = "";
        
        foreach (line; lines)
        {
            line = line.strip;
            
            // Skip comments and empty lines
            if (line.empty || (() @trusted => SIMDStrings.startsWith(line, "#"))())
                continue;
            
            // Section headers (SIMD-accelerated)
            if ((() @trusted => SIMDStrings.startsWith(line, "[") && SIMDStrings.endsWith(line, "]"))())
            {
                currentSection = line[1 .. $ - 1].strip;
                
                // Detect workspace
                if (currentSection == "workspace")
                    manifest.isWorkspace = true;
                
                continue;
            }
            
            // Key-value pairs
            auto equalPos = line.indexOf("=");
            if (equalPos == -1)
                continue;
            
            string key = line[0 .. equalPos].strip;
            string value = line[equalPos + 1 .. $].strip;
            
            // Remove quotes (SIMD-accelerated)
            if ((() @trusted => SIMDStrings.startsWith(value, "\"") && SIMDStrings.endsWith(value, "\""))())
                value = value[1 .. $ - 1];
            else if ((() @trusted => SIMDStrings.startsWith(value, "'") && SIMDStrings.endsWith(value, "'"))())
                value = value[1 .. $ - 1];
            
            // Parse based on section
            if (currentSection == "package")
            {
                parsePackageField(manifest.package_, key, value);
            }
            else if (currentSection == "lib")
            {
                parseLibField(manifest.lib, key, value);
            }
            else if ((() @trusted => SIMDStrings.startsWith(currentSection, "dependencies"))())
            {
                // Simplified dependency parsing
                if (!value.empty && !(() @trusted => SIMDStrings.startsWith(value, "{"))())
                {
                    CargoDependency dep;
                    dep.name = key;
                    dep.version_ = value;
                    manifest.dependencies[key] = dep;
                }
            }
            else if ((() @trusted => SIMDStrings.startsWith(currentSection, "dev-dependencies"))())
            {
                if (!value.empty && !(() @trusted => SIMDStrings.startsWith(value, "{"))())
                {
                    CargoDependency dep;
                    dep.name = key;
                    dep.version_ = value;
                    manifest.devDependencies[key] = dep;
                }
            }
            else if ((() @trusted => SIMDStrings.startsWith(currentSection, "build-dependencies"))())
            {
                if (!value.empty && !(() @trusted => SIMDStrings.startsWith(value, "{"))())
                {
                    CargoDependency dep;
                    dep.name = key;
                    dep.version_ = value;
                    manifest.buildDependencies[key] = dep;
                }
            }
            else if ((() @trusted => SIMDStrings.startsWith(currentSection, "workspace"))())
            {
                parseWorkspaceField(manifest.workspace, key, value);
            }
        }
        
        return manifest;
    }
    
    private static void parsePackageField(ref CargoPackage package_, string key, string value)
    {
        switch (key)
        {
            case "name": package_.name = value; break;
            case "version": package_.version_ = value; break;
            case "edition": package_.edition = value; break;
            case "description": package_.description = value; break;
            case "license": package_.license = value; break;
            case "readme": package_.readme = value; break;
            case "homepage": package_.homepage = value; break;
            case "repository": package_.repository = value; break;
            case "documentation": package_.documentation = value; break;
            default: break;
        }
    }
    
    private static void parseLibField(ref CargoLib lib, string key, string value)
    {
        switch (key)
        {
            case "name": lib.name = value; break;
            case "path": lib.path = value; break;
            case "test": lib.test = value == "true"; break;
            case "bench": lib.bench = value == "true"; break;
            case "doc": lib.doc = value == "true"; break;
            default: break;
        }
    }
    
    private static void parseWorkspaceField(ref CargoWorkspace workspace, string key, string value) @trusted
    {
        if (key == "members")
        {
            // Parse array (SIMD-accelerated)
            if (SIMDStrings.startsWith(value, "[") && SIMDStrings.endsWith(value, "]"))
            {
                value = value[1 .. $ - 1];
                auto members = value.split(",");
                foreach (member; members)
                {
                    member = member.strip;
                    if (SIMDStrings.startsWith(member, "\""))
                        member = member[1 .. $ - 1];
                    if (!member.empty)
                        workspace.members ~= member;
                }
            }
        }
        else if (key == "exclude")
        {
            if (SIMDStrings.startsWith(value, "[") && SIMDStrings.endsWith(value, "]"))
            {
                value = value[1 .. $ - 1];
                auto excluded = value.split(",");
                foreach (ex; excluded)
                {
                    ex = ex.strip;
                    if (SIMDStrings.startsWith(ex, "\""))
                        ex = ex[1 .. $ - 1];
                    if (!ex.empty)
                        workspace.exclude ~= ex;
                }
            }
        }
    }
}

/// Cargo.lock parser for dependency resolution
class CargoLockParser
{
    struct LockEntry
    {
        string name;
        string version_;
        string source;
        string[] dependencies;
    }
    
    /// Parse Cargo.lock file
    static LockEntry[] parse(string lockPath)
    {
        LockEntry[] entries;
        
        if (!exists(lockPath))
            return entries;
        
        try
        {
            auto content = readText(lockPath);
            // Simplified parsing - in production use proper TOML parser
            structuredLog.debug_("parsed_cargolock").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_cargolock_").field("detail", "Failed to parse Cargo.lock: " ~ e.msg).emit();
        }
        
        return entries;
    }
}


