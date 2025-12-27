module languages.scripting.ruby.managers.rubygems;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.managers.base;
import infrastructure.utils.logging;

/// RubyGems direct package manager
class RubyGemsManager : PackageManager
{
    private string projectRoot;
    
    this(string projectRoot = ".")
    {
        this.projectRoot = projectRoot;
    }
    
    override InstallResult install(string[] gems, bool development = false)
    {
        InstallResult result;
        
        if (gems.empty)
        {
            result.error = "No gems specified";
            return result;
        }
        
        string[] cmd = ["gem", "install"];
        cmd ~= gems;
        
        // Add common flags
        cmd ~= ["--no-document"]; // Skip ri/rdoc generation for speed
        
        structuredLog.info("installing_gems_with_rubygems_").field("detail", "Installing gems with RubyGems: " ~ gems.join(", ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
            result.error = "Failed to install gems: " ~ res.output;
        else
            result.installedGems = gems;
        
        return result;
    }
    
    override InstallResult installFromFile(string gemfilePath, bool deployment = false)
    {
        InstallResult result;
        
        // RubyGems doesn't directly support Gemfile, so we parse it manually
        if (!exists(gemfilePath))
        {
            result.error = "Gemfile not found: " ~ gemfilePath;
            return result;
        }
        
        auto gems = parseGemfile(gemfilePath);
        if (gems.empty)
        {
            result.error = "No gems found in Gemfile";
            return result;
        }
        
        return install(gems, false);
    }
    
    override InstallResult update(string[] gems = [])
    {
        InstallResult result;
        
        string[] cmd = ["gem", "update"];
        
        if (!gems.empty)
            cmd ~= gems;
        else
            cmd ~= "--system"; // Update RubyGems itself
        
        structuredLog.info("updating_gems_with_rubygems").emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
            result.error = "Failed to update gems: " ~ res.output;
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["gem", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "RubyGems";
    }
    
    override string getVersion()
    {
        auto res = execute(["gem", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    override bool hasLockfile() const
    {
        return false; // RubyGems doesn't use lockfiles
    }
    
    /// List installed gems
    string[] listGems()
    {
        auto res = execute(["gem", "list"]);
        if (res.status != 0)
            return [];
        
        string[] gems;
        foreach (line; res.output.lineSplitter)
        {
            // Parse lines like "gem_name (version1, version2)"
            auto parts = line.split;
            if (!parts.empty)
                gems ~= parts[0];
        }
        return gems;
    }
    
    /// Check if gem is installed
    bool isGemInstalled(string gemName)
    {
        auto res = execute(["gem", "list", "-i", gemName]);
        return res.status == 0 && res.output.strip == "true";
    }
    
    /// Build gem from gemspec
    InstallResult buildGem(string gemspecFile)
    {
        InstallResult result;
        
        if (!exists(gemspecFile))
        {
            result.error = "Gemspec not found: " ~ gemspecFile;
            return result;
        }
        
        string[] cmd = ["gem", "build", gemspecFile];
        
        structuredLog.info("building_gem_from_").field("detail", "Building gem from " ~ gemspecFile).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, dirName(gemspecFile));
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
            result.error = "Failed to build gem: " ~ res.output;
        
        return result;
    }
    
    /// Install local gem file
    InstallResult installLocal(string gemFile)
    {
        InstallResult result;
        
        if (!exists(gemFile))
        {
            result.error = "Gem file not found: " ~ gemFile;
            return result;
        }
        
        string[] cmd = ["gem", "install", "--local", gemFile];
        
        structuredLog.info("installing_local_gem_").field("detail", "Installing local gem: " ~ gemFile).emit();
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
            result.error = "Failed to install local gem: " ~ res.output;
        
        return result;
    }
    
    private string[] parseGemfile(string gemfilePath)
    {
        string[] gems;
        
        try
        {
            auto content = readText(gemfilePath);
            foreach (line; content.lineSplitter)
            {
                auto stripped = line.strip;
                
                // Look for gem 'name' or gem "name"
                if (stripped.startsWith("gem "))
                {
                    auto parts = stripped[4..$].strip.split;
                    if (!parts.empty)
                    {
                        auto gemName = parts[0].strip("'\"");
                        if (!gemName.empty)
                            gems ~= gemName;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_gemfile_").field("detail", "Failed to parse Gemfile: " ~ e.msg).emit();
        }
        
        return gems;
    }
}


