module languages.scripting.lua.managers.luarocks;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.regex;
import std.string;
import languages.scripting.lua.core.config;
import infrastructure.utils.logging;

/// LuaRocks result structure
struct RockResult
{
    bool success;
    string error;
    string output;
}

/// LuaRocks package manager integration
class LuaRocksManager
{
    private LuaRocksConfig config;
    
    this(LuaRocksConfig config)
    {
        this.config = config;
    }
    
    /// Install dependencies from rockspec
    RockResult installDependencies(string rockspecFile)
    {
        RockResult result;
        
        if (!exists(rockspecFile))
        {
            result.error = "Rockspec file not found: " ~ rockspecFile;
            return result;
        }
        
        // Build command: luarocks install --only-deps rockspec
        string[] cmd = ["luarocks", "install"];
        
        // Only dependencies flag
        if (config.onlyDeps)
        {
            cmd ~= "--only-deps";
        }
        
        // Local installation
        if (config.local)
        {
            cmd ~= "--local";
        }
        
        // Custom tree
        if (config.customTree && !config.tree.empty)
        {
            cmd ~= "--tree";
            cmd ~= config.tree;
        }
        
        // Server URL
        if (!config.server.empty && config.server != "https://luarocks.org")
        {
            cmd ~= "--server";
            cmd ~= config.server;
        }
        
        // Force reinstall
        if (config.forceInstall)
        {
            cmd ~= "--force";
        }
        
        // Add rockspec file
        cmd ~= rockspecFile;
        
        structuredLog.debug_("installing_luarocks_dependencies_").field("detail", "Installing LuaRocks dependencies: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to install dependencies: " ~ res.output;
        }
        
        return result;
    }
    
    /// Install a specific rock
    RockResult installRock(string rockName)
    {
        RockResult result;
        
        string[] cmd = ["luarocks", "install"];
        
        // Local installation
        if (config.local)
        {
            cmd ~= "--local";
        }
        
        // Custom tree
        if (config.customTree && !config.tree.empty)
        {
            cmd ~= "--tree";
            cmd ~= config.tree;
        }
        
        // Server URL
        if (!config.server.empty && config.server != "https://luarocks.org")
        {
            cmd ~= "--server";
            cmd ~= config.server;
        }
        
        // Force reinstall
        if (config.forceInstall)
        {
            cmd ~= "--force";
        }
        
        // Add rock name
        cmd ~= rockName;
        
        structuredLog.debug_("installing_rock_").field("detail", "Installing rock: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to install rock " ~ rockName ~ ": " ~ res.output;
        }
        
        return result;
    }
    
    /// Build and install a rock from current directory
    RockResult buildRock(string rockspecFile = "")
    {
        RockResult result;
        
        string[] cmd = ["luarocks", "make"];
        
        // Local installation
        if (config.local)
        {
            cmd ~= "--local";
        }
        
        // Custom tree
        if (config.customTree && !config.tree.empty)
        {
            cmd ~= "--tree";
            cmd ~= config.tree;
        }
        
        // Force reinstall
        if (config.forceInstall)
        {
            cmd ~= "--force";
        }
        
        // Add rockspec file if specified
        if (!rockspecFile.empty)
        {
            cmd ~= rockspecFile;
        }
        
        structuredLog.debug_("building_rock_").field("detail", "Building rock: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to build rock: " ~ res.output;
        }
        
        return result;
    }
    
    /// Pack a rock for distribution
    RockResult packRock(string rockspecFile)
    {
        RockResult result;
        
        if (!exists(rockspecFile))
        {
            result.error = "Rockspec file not found: " ~ rockspecFile;
            return result;
        }
        
        string[] cmd = ["luarocks", "pack", rockspecFile];
        
        structuredLog.debug_("packing_rock_").field("detail", "Packing rock: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to pack rock: " ~ res.output;
        }
        
        return result;
    }
    
    /// List installed rocks
    RockResult listRocks()
    {
        RockResult result;
        
        string[] cmd = ["luarocks", "list"];
        
        // Local rocks only
        if (config.local)
        {
            cmd ~= "--local";
        }
        
        // Custom tree
        if (config.customTree && !config.tree.empty)
        {
            cmd ~= "--tree";
            cmd ~= config.tree;
        }
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to list rocks: " ~ res.output;
        }
        
        return result;
    }
    
    /// Search for rocks
    RockResult searchRocks(string query)
    {
        RockResult result;
        
        string[] cmd = ["luarocks", "search", query];
        
        // Server URL
        if (!config.server.empty && config.server != "https://luarocks.org")
        {
            cmd ~= "--server";
            cmd ~= config.server;
        }
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to search rocks: " ~ res.output;
        }
        
        return result;
    }
    
    /// Remove an installed rock
    RockResult removeRock(string rockName)
    {
        RockResult result;
        
        string[] cmd = ["luarocks", "remove", rockName];
        
        // Local installation
        if (config.local)
        {
            cmd ~= "--local";
        }
        
        // Custom tree
        if (config.customTree && !config.tree.empty)
        {
            cmd ~= "--tree";
            cmd ~= config.tree;
        }
        
        structuredLog.debug_("removing_rock_").field("detail", "Removing rock: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to remove rock " ~ rockName ~ ": " ~ res.output;
        }
        
        return result;
    }
    
    /// Get LuaRocks configuration
    RockResult getConfig()
    {
        RockResult result;
        
        string[] cmd = ["luarocks", "config"];
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
        {
            result.error = "Failed to get LuaRocks config: " ~ res.output;
        }
        
        return result;
    }
    
    /// Parse dependencies from rockspec file
    string[] parseDependencies(string rockspecFile)
    {
        string[] deps;
        
        if (!exists(rockspecFile))
            return deps;
        
        try
        {
            auto content = readText(rockspecFile);
            
            // Find dependencies section
            // dependencies = { "lua >= 5.1", "lpeg", "luasocket >= 3.0" }
            auto depsMatch = matchFirst(content, regex(`dependencies\s*=\s*\{([^}]+)\}`));
            if (!depsMatch.empty)
            {
                auto depsStr = depsMatch[1];
                
                // Extract individual dependencies
                auto depMatches = matchAll(depsStr, regex(`"([^"]+)"`));
                foreach (match; depMatches)
                {
                    auto dep = match[1].strip;
                    if (!dep.startsWith("lua "))  // Skip lua version requirement
                    {
                        deps ~= dep;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_rockspec_dependencies_").field("detail", "Failed to parse rockspec dependencies: " ~ e.msg).emit();
        }
        
        return deps;
    }
}

/// Check if LuaRocks is available
bool isLuaRocksAvailable()
{
    auto res = execute(["which", "luarocks"]);
    return res.status == 0;
}

/// Get LuaRocks version
string getLuaRocksVersion()
{
    try
    {
        auto res = execute(["luarocks", "--version"]);
        if (res.status == 0)
        {
            auto match = matchFirst(res.output, regex(`(\d+\.\d+\.\d+)`));
            if (!match.empty)
            {
                return match[1];
            }
        }
    }
    catch (Exception e)
    {
        import infrastructure.utils.logging : Logger;
        structuredLog.debug_("failed_to_get_luarocks_version_").field("detail", "Failed to get LuaRocks version: " ~ e.msg).emit();
    }
    
    return "unknown";
}

