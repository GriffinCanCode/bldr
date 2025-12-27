module languages.scripting.elixir.managers.versions;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import infrastructure.utils.logging;

/// Parse .tool-versions file (asdf format)
string[string] parseToolVersions(string filePath)
{
    string[string] versions;
    
    if (!exists(filePath) || !isFile(filePath))
        return versions;
    
    try
    {
        auto content = readText(filePath);
        foreach (line; content.split("\n"))
        {
            line = line.strip;
            if (line.empty || line.startsWith("#"))
                continue;
            
            auto parts = line.split();
            if (parts.length >= 2)
            {
                versions[parts[0]] = parts[1];
            }
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("failed_to_parse_toolversions_").field("detail", "Failed to parse .tool-versions: " ~ e.msg).emit();
    }
    
    return versions;
}

/// Base interface for version managers
interface VersionManagerInterface
{
    /// Check if version manager is available
    bool isAvailable();
    
    /// Get current Elixir version
    string getCurrentVersion();
    
    /// Get Elixir executable path
    string getElixirPath();
    
    /// Get version manager name
    string name() const;
}

/// asdf version manager
class AsdfVersionManager : VersionManagerInterface
{
    private string projectRoot;
    
    this(string projectRoot = ".")
    {
        this.projectRoot = projectRoot;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["asdf", "--version"]);
        return res.status == 0;
    }
    
    override string getCurrentVersion()
    {
        // Check .tool-versions
        string toolVersionsPath = buildPath(projectRoot, ".tool-versions");
        if (exists(toolVersionsPath))
        {
            auto versions = parseToolVersions(toolVersionsPath);
            if ("elixir" in versions)
                return versions["elixir"];
        }
        
        // Fallback to asdf current
        auto res = execute(["asdf", "current", "elixir"], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
        {
            auto parts = res.output.strip.split();
            if (parts.length >= 2)
                return parts[1];
        }
        
        return "unknown";
    }
    
    override string getElixirPath()
    {
        auto res = execute(["asdf", "which", "elixir"], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
            return res.output.strip;
        
        return "elixir";
    }
    
    override string name() const
    {
        return "asdf";
    }
}

/// kiex version manager (legacy)
class KiexVersionManager : VersionManagerInterface
{
    override bool isAvailable()
    {
        auto res = execute(["kiex", "list"]);
        return res.status == 0;
    }
    
    override string getCurrentVersion()
    {
        auto res = execute(["kiex", "list"]);
        if (res.status == 0)
        {
            // Parse current version from output
            auto lines = res.output.split("\n");
            foreach (line; lines)
            {
                if (line.canFind("*"))
                {
                    auto match = line.matchFirst(regex(`(\d+\.\d+\.\d+)`));
                    if (!match.empty)
                        return match[1];
                }
            }
        }
        return "unknown";
    }
    
    override string getElixirPath()
    {
        return "elixir"; // kiex manages PATH
    }
    
    override string name() const
    {
        return "kiex";
    }
}

/// Version manager factory and utilities
class VersionManager
{
    /// Parse .tool-versions file
    static string[string] parseToolVersions(string filePath)
    {
        return .parseToolVersions(filePath);
    }
    
    /// Detect available version manager
    static VersionManagerInterface detect()
    {
        // Try asdf first (most common)
        auto asdf = new AsdfVersionManager();
        if (asdf.isAvailable())
            return asdf;
        
        // Try kiex (legacy)
        auto kiex = new KiexVersionManager();
        if (kiex.isAvailable())
            return kiex;
        
        return null;
    }
}

