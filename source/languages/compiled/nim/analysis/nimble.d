module languages.compiled.nim.analysis.nimble;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.json;
import infrastructure.utils.logging;

/// Nimble package data
struct NimbleData
{
    string name;
    string version_;
    string author;
    string description;
    string license;
    string[] bin;
    string[] srcDir;
    string[] skipDirs;
    string[] skipFiles;
    string[] skipExt;
    Dependency[] requires;
    string backend;
}

/// Dependency specification
struct Dependency
{
    string name;
    string versionConstraint;
}

/// Nimble file parser
class NimbleParser
{
    /// Find .nimble file in directory or parent directories
    static string findNimbleFile(string startDir)
    {
        import std.file : dirEntries, SpanMode;
        
        string dir = absolutePath(startDir);
        
        while (dir != "/" && dir.length > 1)
        {
            try
            {
                // Look for *.nimble files
                auto nimbleFiles = dirEntries(dir, "*.nimble", SpanMode.shallow)
                    .filter!(f => f.isFile)
                    .map!(f => f.name)
                    .array;
                
                if (!nimbleFiles.empty)
                    return nimbleFiles[0];
            }
            catch (Exception e)
            {
                // Directory not accessible, move up
            }
            
            dir = dirName(dir);
        }
        
        return "";
    }
    
    /// Parse .nimble file
    static NimbleData parseNimbleFile(string nimbleFile)
    {
        NimbleData data;
        
        if (!exists(nimbleFile))
        {
            structuredLog.warning("nimble_file_not_found_").field("detail", "Nimble file not found: " ~ nimbleFile).emit();
            return data;
        }
        
        try
        {
            string content = readText(nimbleFile);
            data = parseNimbleContent(content, nimbleFile);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_nimble_file_").field("detail", "Failed to parse nimble file: " ~ e.msg).emit();
        }
        
        return data;
    }
    
    /// Parse nimble file content
    private static NimbleData parseNimbleContent(string content, string filename)
    {
        NimbleData data;
        
        // Extract package name from filename if not found in content
        data.name = baseName(stripExtension(filename));
        
        // Parse key-value assignments
        // Nimble files use Nim syntax: key = "value" or key = ["item1", "item2"]
        
        // Version
        auto versionRegex = regex(`version\s*=\s*"([^"]+)"`, "m");
        auto match = matchFirst(content, versionRegex);
        if (!match.empty)
            data.version_ = match[1];
        
        // Author
        auto authorRegex = regex(`author\s*=\s*"([^"]+)"`, "m");
        match = matchFirst(content, authorRegex);
        if (!match.empty)
            data.author = match[1];
        
        // Description
        auto descRegex = regex(`description\s*=\s*"([^"]+)"`, "m");
        match = matchFirst(content, descRegex);
        if (!match.empty)
            data.description = match[1];
        
        // License
        auto licenseRegex = regex(`license\s*=\s*"([^"]+)"`, "m");
        match = matchFirst(content, licenseRegex);
        if (!match.empty)
            data.license = match[1];
        
        // Backend
        auto backendRegex = regex(`backend\s*=\s*"([^"]+)"`, "m");
        match = matchFirst(content, backendRegex);
        if (!match.empty)
            data.backend = match[1];
        
        // Bin (binaries)
        data.bin = parseStringArray(content, "bin");
        
        // SrcDir
        data.srcDir = parseStringArray(content, "srcDir");
        
        // SkipDirs
        data.skipDirs = parseStringArray(content, "skipDirs");
        
        // SkipFiles
        data.skipFiles = parseStringArray(content, "skipFiles");
        
        // SkipExt
        data.skipExt = parseStringArray(content, "skipExt");
        
        // Requires (dependencies)
        data.requires = parseRequires(content);
        
        return data;
    }
    
    /// Parse string array from nimble file
    private static string[] parseStringArray(string content, string key)
    {
        string[] result;
        
        // Try to match array pattern: key = @["item1", "item2"]
        auto arrayRegex = regex(key ~ `\s*=\s*@?\[([^\]]+)\]`, "m");
        auto match = matchFirst(content, arrayRegex);
        
        if (!match.empty)
        {
            string arrayContent = match[1];
            
            // Extract quoted strings
            auto stringRegex = regex(`"([^"]+)"`, "g");
            foreach (m; matchAll(arrayContent, stringRegex))
            {
                result ~= m[1];
            }
        }
        else
        {
            // Try single string pattern: key = "value"
            auto stringRegex = regex(key ~ `\s*=\s*"([^"]+)"`, "m");
            match = matchFirst(content, stringRegex);
            
            if (!match.empty)
            {
                result ~= match[1];
            }
        }
        
        return result;
    }
    
    /// Parse requires (dependencies)
    private static Dependency[] parseRequires(string content)
    {
        Dependency[] deps;
        
        // Match: requires "nim >= 1.6.0", "package >= 1.0.0"
        auto requiresRegex = regex(`requires\s+"([^"]+)"`, "gm");
        
        foreach (match; matchAll(content, requiresRegex))
        {
            string depString = match[1];
            
            // Parse dependency string
            Dependency dep = parseDependencyString(depString);
            if (!dep.name.empty)
                deps ~= dep;
        }
        
        return deps;
    }
    
    /// Parse dependency string like "nim >= 1.6.0" or "package"
    private static Dependency parseDependencyString(string depString)
    {
        Dependency dep;
        
        // Trim whitespace
        depString = depString.strip();
        
        // Check for version constraint
        auto constraintRegex = regex(`^(\S+)\s+(.+)$`);
        auto match = matchFirst(depString, constraintRegex);
        
        if (!match.empty)
        {
            dep.name = match[1];
            dep.versionConstraint = match[2].strip();
        }
        else
        {
            // No version constraint
            dep.name = depString;
            dep.versionConstraint = "";
        }
        
        return dep;
    }
    
    /// Parse nimble lock file (nimble.lock)
    static LockedDependency[] parseLockFile(string lockFile)
    {
        LockedDependency[] deps;
        
        if (!exists(lockFile))
            return deps;
        
        try
        {
            string content = readText(lockFile);
            
            // Nimble lock files are JSON
            auto json = parseJSON(content);
            
            if ("packages" in json)
            {
                foreach (pkg; json["packages"].array)
                {
                    LockedDependency dep;
                    
                    if ("name" in pkg)
                        dep.name = pkg["name"].str;
                    
                    if ("version" in pkg)
                        dep.version_ = pkg["version"].str;
                    
                    if ("url" in pkg)
                        dep.url = pkg["url"].str;
                    
                    if ("checksum" in pkg)
                        dep.checksum = pkg["checksum"].str;
                    
                    deps ~= dep;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_lock_file_").field("detail", "Failed to parse lock file: " ~ e.msg).emit();
        }
        
        return deps;
    }
}

/// Locked dependency from nimble.lock
struct LockedDependency
{
    string name;
    string version_;
    string url;
    string checksum;
}

