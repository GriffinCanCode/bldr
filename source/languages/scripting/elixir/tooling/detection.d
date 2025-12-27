module languages.scripting.elixir.tooling.detection;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.elixir.config;
import infrastructure.utils.logging;

/// Project detector - identifies Elixir project types
class ProjectDetector
{
    /// Detect project type from directory
    static ElixirProjectType detectProjectType(string projectDir)
    {
        // Check for mix.exs
        string mixExsPath = buildPath(projectDir, "mix.exs");
        if (!exists(mixExsPath))
            return ElixirProjectType.Script;
        
        // Read mix.exs to determine type
        auto content = readText(mixExsPath);
        
        // Check for Nerves
        if (content.canFind(":nerves,") || content.canFind(":nerves_pack"))
            return ElixirProjectType.Nerves;
        
        // Check for umbrella
        if (content.canFind("apps_path:") || exists(buildPath(projectDir, "apps")))
            return ElixirProjectType.Umbrella;
        
        // Check for Phoenix
        if (content.canFind(":phoenix,") || content.canFind(":phoenix_html"))
        {
            // Check for LiveView
            if (content.canFind(":phoenix_live_view") || hasLiveView(projectDir))
                return ElixirProjectType.PhoenixLiveView;
            
            return ElixirProjectType.Phoenix;
        }
        
        // Check for escript
        if (content.canFind("escript:"))
            return ElixirProjectType.Escript;
        
        // Check if it's a library (no application callback)
        if (content.canFind("mod:") && content.canFind("Application"))
            return ElixirProjectType.MixProject;
        
        // Default to library if it has mix.exs but no application
        return ElixirProjectType.Library;
    }
    
    /// Check if project is Phoenix
    static bool isPhoenixProject(string projectDir)
    {
        string mixExsPath = buildPath(projectDir, "mix.exs");
        if (!exists(mixExsPath))
            return false;
        
        auto content = readText(mixExsPath);
        return content.canFind(":phoenix");
    }
    
    /// Check if Phoenix project has LiveView
    static bool hasLiveView(string projectDir)
    {
        // Check for phoenix_live_view in deps
        string mixExsPath = buildPath(projectDir, "mix.exs");
        if (exists(mixExsPath))
        {
            auto content = readText(mixExsPath);
            if (content.canFind(":phoenix_live_view"))
                return true;
        }
        
        // Check for LiveView files in lib/
        string libDir = buildPath(projectDir, "lib");
        if (exists(libDir))
        {
            foreach (entry; dirEntries(libDir, SpanMode.depth))
            {
                if (entry.isFile && entry.name.endsWith(".ex"))
                {
                    auto content = readText(entry.name);
                    if (content.canFind("use Phoenix.LiveView"))
                        return true;
                }
            }
        }
        
        return false;
    }
    
    /// Check if project is umbrella
    static bool isUmbrellaProject(string projectDir)
    {
        // Check for apps directory
        if (exists(buildPath(projectDir, "apps")))
            return true;
        
        // Check mix.exs
        string mixExsPath = buildPath(projectDir, "mix.exs");
        if (exists(mixExsPath))
        {
            auto content = readText(mixExsPath);
            return content.canFind("apps_path:");
        }
        
        return false;
    }
    
    /// Get umbrella apps
    static string[] getUmbrellaApps(string projectDir, string appsDir = "apps")
    {
        string[] apps;
        
        string appsDirPath = buildPath(projectDir, appsDir);
        if (!exists(appsDirPath) || !isDir(appsDirPath))
            return apps;
        
        foreach (entry; dirEntries(appsDirPath, SpanMode.shallow))
        {
            if (entry.isDir)
            {
                // Check if it has a mix.exs
                string mixExsPath = buildPath(entry.name, "mix.exs");
                if (exists(mixExsPath))
                {
                    apps ~= baseName(entry.name);
                }
            }
        }
        
        return apps;
    }
    
    /// Check if project is Nerves
    static bool isNervesProject(string projectDir)
    {
        string mixExsPath = buildPath(projectDir, "mix.exs");
        if (!exists(mixExsPath))
            return false;
        
        auto content = readText(mixExsPath);
        return content.canFind(":nerves");
    }
}

