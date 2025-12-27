module languages.scripting.go.managers.modules;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import infrastructure.utils.logging;

/// Represents a Go module (parsed from go.mod)
struct GoModule
{
    /// Module path
    string path;
    
    /// Go version requirement
    string goVersion;
    
    /// Direct dependencies
    ModuleDependency[] requires;
    
    /// Replaced modules
    ModuleReplacement[] replaces;
    
    /// Excluded modules
    ModuleExclusion[] excludes;
    
    /// Retracted versions
    string[] retracts;
    
    /// Check if module is valid
    bool isValid() const pure nothrow
    {
        return !path.empty && !goVersion.empty;
    }
}

/// Module dependency entry
struct ModuleDependency
{
    /// Module path
    string path;
    
    /// Version
    string version_;
    
    /// Indirect dependency flag
    bool indirect = false;
}

/// Module replacement directive
struct ModuleReplacement
{
    /// Original module path
    string oldPath;
    
    /// Original version (optional)
    string oldVersion;
    
    /// Replacement module path
    string newPath;
    
    /// Replacement version (optional for local paths)
    string newVersion;
}

/// Module exclusion directive
struct ModuleExclusion
{
    /// Module path
    string path;
    
    /// Excluded version
    string version_;
}

/// Go workspace (go.work)
struct GoWorkspace
{
    /// Go version
    string goVersion;
    
    /// Use directives (module directories)
    string[] use;
    
    /// Replace directives
    ModuleReplacement[] replaces;
    
    /// Check if workspace is valid
    bool isValid() const pure nothrow
    {
        return !goVersion.empty && !use.empty;
    }
}

/// Module analyzer - parses go.mod and go.sum files
class ModuleAnalyzer
{
    /// Parse go.mod file
    static GoModule parseGoMod(string goModPath)
    {
        GoModule mod;
        
        if (!exists(goModPath))
        {
            structuredLog.warning("gomod_not_found_").field("detail", "go.mod not found: " ~ goModPath).emit();
            return mod;
        }
        
        try
        {
            auto content = readText(goModPath);
            return parseGoModContent(content);
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_parse_gomod_").field("detail", "Failed to parse go.mod: " ~ e.msg).emit();
            return mod;
        }
    }
    
    /// Parse go.mod content
    static GoModule parseGoModContent(string content)
    {
        GoModule mod;
        
        auto lines = content.lineSplitter.map!(l => l.strip).array;
        bool inRequire = false;
        bool inReplace = false;
        bool inExclude = false;
        
        foreach (line; lines)
        {
            // Skip empty lines and comments
            if (line.empty || line.startsWith("//"))
                continue;
            
            // Module directive
            auto moduleMatch = matchFirst(line, regex(`^module\s+([\S]+)`));
            if (moduleMatch)
            {
                mod.path = moduleMatch[1];
                continue;
            }
            
            // Go version
            auto goMatch = matchFirst(line, regex(`^go\s+([\d.]+)`));
            if (goMatch)
            {
                mod.goVersion = goMatch[1];
                continue;
            }
            
            // Require block start
            if (line.startsWith("require ("))
            {
                inRequire = true;
                continue;
            }
            
            // Replace block start
            if (line.startsWith("replace ("))
            {
                inReplace = true;
                continue;
            }
            
            // Exclude block start
            if (line.startsWith("exclude ("))
            {
                inExclude = true;
                continue;
            }
            
            // Block end
            if (line == ")")
            {
                inRequire = false;
                inReplace = false;
                inExclude = false;
                continue;
            }
            
            // Parse require entries
            if (inRequire || line.startsWith("require "))
            {
                auto dep = parseRequire(line);
                if (!dep.path.empty)
                    mod.requires ~= dep;
                continue;
            }
            
            // Parse replace entries
            if (inReplace || line.startsWith("replace "))
            {
                auto repl = parseReplace(line);
                if (!repl.oldPath.empty)
                    mod.replaces ~= repl;
                continue;
            }
            
            // Parse exclude entries
            if (inExclude || line.startsWith("exclude "))
            {
                auto excl = parseExclude(line);
                if (!excl.path.empty)
                    mod.excludes ~= excl;
                continue;
            }
            
            // Retract directive
            if (line.startsWith("retract "))
            {
                auto retractMatch = matchFirst(line, regex(`retract\s+([\S]+)`));
                if (retractMatch)
                    mod.retracts ~= retractMatch[1];
                continue;
            }
        }
        
        return mod;
    }
    
    /// Parse go.work file
    static GoWorkspace parseGoWork(string goWorkPath)
    {
        GoWorkspace workspace;
        
        if (!exists(goWorkPath))
        {
            structuredLog.debug_("gowork_not_found_").field("detail", "go.work not found: " ~ goWorkPath).emit();
            return workspace;
        }
        
        try
        {
            auto content = readText(goWorkPath);
            return parseGoWorkContent(content);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_gowork_").field("detail", "Failed to parse go.work: " ~ e.msg).emit();
            return workspace;
        }
    }
    
    /// Parse go.work content
    static GoWorkspace parseGoWorkContent(string content)
    {
        GoWorkspace workspace;
        
        auto lines = content.lineSplitter.map!(l => l.strip).array;
        bool inUse = false;
        bool inReplace = false;
        
        foreach (line; lines)
        {
            if (line.empty || line.startsWith("//"))
                continue;
            
            // Go version
            auto goMatch = matchFirst(line, regex(`^go\s+([\d.]+)`));
            if (goMatch)
            {
                workspace.goVersion = goMatch[1];
                continue;
            }
            
            // Use block
            if (line.startsWith("use ("))
            {
                inUse = true;
                continue;
            }
            
            // Replace block
            if (line.startsWith("replace ("))
            {
                inReplace = true;
                continue;
            }
            
            // Block end
            if (line == ")")
            {
                inUse = false;
                inReplace = false;
                continue;
            }
            
            // Parse use entries
            if (inUse || line.startsWith("use "))
            {
                auto useMatch = matchFirst(line, regex(`(?:use\s+)?([\S]+)`));
                if (useMatch && !useMatch[1].empty)
                    workspace.use ~= useMatch[1];
                continue;
            }
            
            // Parse replace entries
            if (inReplace || line.startsWith("replace "))
            {
                auto repl = parseReplace(line);
                if (!repl.oldPath.empty)
                    workspace.replaces ~= repl;
                continue;
            }
        }
        
        return workspace;
    }
    
    /// Find go.mod in directory or parent directories
    static string findGoMod(string startDir)
    {
        string dir = startDir.absolutePath.buildNormalizedPath;
        
        while (dir != "/" && dir.length > 1)
        {
            string goModPath = buildPath(dir, "go.mod");
            if (exists(goModPath))
                return goModPath;
            
            dir = dirName(dir);
        }
        
        return "";
    }
    
    /// Find go.work in directory or parent directories
    static string findGoWork(string startDir)
    {
        string dir = startDir.absolutePath.buildNormalizedPath;
        
        while (dir != "/" && dir.length > 1)
        {
            string goWorkPath = buildPath(dir, "go.work");
            if (exists(goWorkPath))
                return goWorkPath;
            
            dir = dirName(dir);
        }
        
        return "";
    }
    
    /// Check if directory is inside a Go module
    static bool isInModule(string dir)
    {
        return !findGoMod(dir).empty;
    }
    
    /// Check if directory is inside a Go workspace
    static bool isInWorkspace(string dir)
    {
        return !findGoWork(dir).empty;
    }
    
    /// Get module path for a directory
    static string getModulePath(string dir)
    {
        auto goModPath = findGoMod(dir);
        if (goModPath.empty)
            return "";
        
        auto mod = parseGoMod(goModPath);
        return mod.path;
    }
    
    private static ModuleDependency parseRequire(string line)
    {
        ModuleDependency dep;
        
        // Remove "require" prefix if present
        line = line.replace("require ", "").strip;
        
        // Pattern: module version [// indirect]
        auto parts = line.split();
        if (parts.length >= 2)
        {
            dep.path = parts[0];
            dep.version_ = parts[1];
            
            if (parts.length > 2 && line.canFind("// indirect"))
                dep.indirect = true;
        }
        
        return dep;
    }
    
    private static ModuleReplacement parseReplace(string line)
    {
        ModuleReplacement repl;
        
        // Remove "replace" prefix if present
        line = line.replace("replace ", "").strip;
        
        // Pattern: old [version] => new [version]
        auto parts = line.split("=>");
        if (parts.length == 2)
        {
            auto oldParts = parts[0].strip.split();
            auto newParts = parts[1].strip.split();
            
            if (!oldParts.empty)
            {
                repl.oldPath = oldParts[0];
                if (oldParts.length > 1)
                    repl.oldVersion = oldParts[1];
            }
            
            if (!newParts.empty)
            {
                repl.newPath = newParts[0];
                if (newParts.length > 1)
                    repl.newVersion = newParts[1];
            }
        }
        
        return repl;
    }
    
    private static ModuleExclusion parseExclude(string line)
    {
        ModuleExclusion excl;
        
        // Remove "exclude" prefix if present
        line = line.replace("exclude ", "").strip;
        
        auto parts = line.split();
        if (parts.length >= 2)
        {
            excl.path = parts[0];
            excl.version_ = parts[1];
        }
        
        return excl;
    }
}

