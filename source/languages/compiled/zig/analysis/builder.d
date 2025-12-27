module languages.compiled.zig.analysis.builder;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.json;
import infrastructure.utils.logging;

/// Build.zig project information
struct BuildZigProject
{
    /// Project name
    string name;
    
    /// Project version
    string version_;
    
    /// Build steps defined
    string[] steps;
    
    /// Dependencies
    string[] dependencies;
    
    /// Modules
    string[] modules;
    
    /// Path to build.zig
    string path;
    
    /// Check if project is valid
    bool isValid() const nothrow
    {
        return !path.empty && exists(path);
    }
}

/// Build.zig parser and manager
class BuildZigParser
{
    /// Find build.zig in directory tree
    static string findBuildZig(string startPath)
    {
        string currentPath = startPath;
        
        // If startPath is a file, get its directory
        if (exists(currentPath) && isFile(currentPath))
            currentPath = dirName(currentPath);
        
        // Search up directory tree
        while (currentPath != "/" && currentPath.length > 1)
        {
            string buildZigPath = buildPath(currentPath, "build.zig");
            if (exists(buildZigPath))
            {
                structuredLog.debug_("found_buildzig_at_").field("detail", "Found build.zig at: " ~ buildZigPath).emit();
                return buildZigPath;
            }
            
            currentPath = dirName(currentPath);
        }
        
        return "";
    }
    
    /// Parse build.zig file
    static BuildZigProject parseBuildZig(string path)
    {
        BuildZigProject project;
        project.path = path;
        
        if (!exists(path))
        {
            structuredLog.warning("buildzig_not_found_").field("detail", "build.zig not found: " ~ path).emit();
            return project;
        }
        
        try
        {
            auto content = readText(path);
            
            // Extract project name
            project.name = extractProjectName(content);
            
            // Extract version
            project.version_ = extractVersion(content);
            
            // Extract build steps
            project.steps = extractBuildSteps(content);
            
            // Extract dependencies (from build.zig.zon if exists)
            auto zonPath = buildPath(dirName(path), "build.zig.zon");
            if (exists(zonPath))
            {
                project.dependencies = extractDependencies(zonPath);
            }
            
            // Extract modules
            project.modules = extractModules(content);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_buildzig_").field("detail", "Failed to parse build.zig: " ~ e.msg).emit();
        }
        
        return project;
    }
    
    /// Extract project name from build.zig
    private static string extractProjectName(string content)
    {
        // Look for .name = "project-name"
        auto lines = content.lineSplitter;
        foreach (line; lines)
        {
            auto trimmed = line.strip;
            if (trimmed.canFind(".name = "))
            {
                // Extract string between quotes
                auto start = trimmed.indexOf("\"");
                if (start >= 0)
                {
                    auto end = trimmed.indexOf("\"", start + 1);
                    if (end > start)
                    {
                        return trimmed[start + 1 .. end];
                    }
                }
            }
        }
        
        return "";
    }
    
    /// Extract version from build.zig
    private static string extractVersion(string content)
    {
        // Look for .version = "x.y.z"
        auto lines = content.lineSplitter;
        foreach (line; lines)
        {
            auto trimmed = line.strip;
            if (trimmed.canFind(".version = "))
            {
                auto start = trimmed.indexOf("\"");
                if (start >= 0)
                {
                    auto end = trimmed.indexOf("\"", start + 1);
                    if (end > start)
                    {
                        return trimmed[start + 1 .. end];
                    }
                }
            }
        }
        
        return "";
    }
    
    /// Extract build steps from build.zig
    private static string[] extractBuildSteps(string content)
    {
        string[] steps;
        
        // Look for b.step(...) calls
        auto lines = content.lineSplitter;
        foreach (line; lines)
        {
            auto trimmed = line.strip;
            if (trimmed.canFind("b.step("))
            {
                // Extract step name (first argument)
                auto start = trimmed.indexOf("\"");
                if (start >= 0)
                {
                    auto end = trimmed.indexOf("\"", start + 1);
                    if (end > start)
                    {
                        string stepName = trimmed[start + 1 .. end];
                        if (!steps.canFind(stepName))
                            steps ~= stepName;
                    }
                }
            }
        }
        
        return steps;
    }
    
    /// Extract dependencies from build.zig.zon
    private static string[] extractDependencies(string zonPath)
    {
        string[] deps;
        
        try
        {
            auto content = readText(zonPath);
            
            // Look for .dependencies = .{ ... }
            auto lines = content.lineSplitter;
            bool inDeps = false;
            
            foreach (line; lines)
            {
                auto trimmed = line.strip;
                
                if (trimmed.canFind(".dependencies = .{"))
                {
                    inDeps = true;
                    continue;
                }
                
                if (inDeps)
                {
                    if (trimmed.canFind("}"))
                    {
                        inDeps = false;
                        break;
                    }
                    
                    // Extract dependency name
                    auto eqPos = trimmed.indexOf("=");
                    if (eqPos > 0)
                    {
                        string depName = trimmed[0 .. eqPos].strip;
                        if (depName.startsWith("."))
                            depName = depName[1 .. $];
                        if (!deps.canFind(depName))
                            deps ~= depName;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_buildzigzon_").field("detail", "Failed to parse build.zig.zon: " ~ e.msg).emit();
        }
        
        return deps;
    }
    
    /// Extract modules from build.zig
    private static string[] extractModules(string content)
    {
        string[] modules;
        
        // Look for b.addModule(...) calls
        auto lines = content.lineSplitter;
        foreach (line; lines)
        {
            auto trimmed = line.strip;
            if (trimmed.canFind("b.addModule(") || trimmed.canFind(".addModule("))
            {
                // Extract module name
                auto start = trimmed.indexOf("\"");
                if (start >= 0)
                {
                    auto end = trimmed.indexOf("\"", start + 1);
                    if (end > start)
                    {
                        string modName = trimmed[start + 1 .. end];
                        if (!modules.canFind(modName))
                            modules ~= modName;
                    }
                }
            }
        }
        
        return modules;
    }
    
    /// Check if directory is a build.zig project
    static bool isBuildZigProject(string path)
    {
        string buildZigPath = findBuildZig(path);
        return !buildZigPath.empty;
    }
    
    /// Get build.zig.zon path if exists
    static string getBuildZonPath(string buildZigPath)
    {
        auto dir = dirName(buildZigPath);
        auto zonPath = buildPath(dir, "build.zig.zon");
        return exists(zonPath) ? zonPath : "";
    }
    
    /// Check if zig.mod exists (older package format)
    static bool hasZigMod(string path)
    {
        auto zigModPath = buildPath(path, "zig.mod");
        return exists(zigModPath);
    }
}

/// Build.zig.zon (Zig package manifest) parser
class ZonParser
{
    /// Parse build.zig.zon file
    static JSONValue parseZon(string path)
    {
        JSONValue result;
        
        if (!exists(path))
            return result;
        
        try
        {
            auto content = readText(path);
            
            // Convert ZON format to JSON-ish format for parsing
            // ZON is not JSON, but has similar structure
            // This is a simple parser for basic extraction
            
            // For now, return empty - proper ZON parser would be more complex
            result = parseJSON("{}");
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_zon_file_").field("detail", "Failed to parse .zon file: " ~ e.msg).emit();
        }
        
        return result;
    }
    
    /// Extract package name from zon
    static string getPackageName(string zonPath)
    {
        if (!exists(zonPath))
            return "";
        
        try
        {
            auto content = readText(zonPath);
            
            // Look for .name = "package-name"
            auto lines = content.lineSplitter;
            foreach (line; lines)
            {
                auto trimmed = line.strip;
                if (trimmed.canFind(".name = "))
                {
                    auto start = trimmed.indexOf("\"");
                    if (start >= 0)
                    {
                        auto end = trimmed.indexOf("\"", start + 1);
                        if (end > start)
                        {
                            return trimmed[start + 1 .. end];
                        }
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_read_zon_file_").field("detail", "Failed to read .zon file: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Extract version from zon
    static string getPackageVersion(string zonPath)
    {
        if (!exists(zonPath))
            return "";
        
        try
        {
            auto content = readText(zonPath);
            
            // Look for .version = "x.y.z"
            auto lines = content.lineSplitter;
            foreach (line; lines)
            {
                auto trimmed = line.strip;
                if (trimmed.canFind(".version = "))
                {
                    auto start = trimmed.indexOf("\"");
                    if (start >= 0)
                    {
                        auto end = trimmed.indexOf("\"", start + 1);
                        if (end > start)
                        {
                            return trimmed[start + 1 .. end];
                        }
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_read_zon_file_").field("detail", "Failed to read .zon file: " ~ e.msg).emit();
        }
        
        return "";
    }
}


