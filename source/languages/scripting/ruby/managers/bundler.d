module languages.scripting.ruby.managers.bundler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.managers.base;
import infrastructure.utils.logging;

/// Bundler package manager implementation
class BundlerManager : PackageManager
{
    private string projectRoot;
    private string gemfilePath;
    
    this(string projectRoot = ".", string gemfilePath = "Gemfile")
    {
        this.projectRoot = projectRoot;
        this.gemfilePath = buildPath(projectRoot, gemfilePath);
    }
    
    override InstallResult install(string[] gems, bool development = false)
    {
        InstallResult result;
        
        if (gems.empty)
        {
            result.error = "No gems specified";
            return result;
        }
        
        // Use bundle add for adding gems
        string[] cmd = ["bundle", "add"];
        cmd ~= gems;
        
        if (development)
            cmd ~= "--group=development";
        
        structuredLog.info("installing_gems_with_bundler_").field("detail", "Installing gems with Bundler: " ~ gems.join(", ")).emit();
        
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
        
        if (!exists(gemfilePath))
        {
            result.error = "Gemfile not found: " ~ gemfilePath;
            return result;
        }
        
        string[] cmd = ["bundle", "install"];
        
        if (deployment)
            cmd ~= "--deployment";
        
        structuredLog.info("installing_dependencies_from_gemfile").emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
            result.error = "Failed to install from Gemfile: " ~ res.output;
        else
            result.installedGems = parseInstalledGems(res.output);
        
        return result;
    }
    
    override InstallResult update(string[] gems = [])
    {
        InstallResult result;
        
        string[] cmd = ["bundle", "update"];
        
        if (!gems.empty)
            cmd ~= gems;
        
        structuredLog.info("updating_gems_with_bundler").emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
            result.error = "Failed to update gems: " ~ res.output;
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["bundle", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "Bundler";
    }
    
    override string getVersion()
    {
        auto res = execute(["bundle", "--version"]);
        if (res.status == 0)
        {
            // Parse "Bundler version X.Y.Z"
            auto parts = res.output.strip.split;
            if (parts.length >= 3)
                return parts[2];
        }
        return "unknown";
    }
    
    override bool hasLockfile() const
    {
        return exists(buildPath(projectRoot, "Gemfile.lock"));
    }
    
    /// Install with specific configuration
    InstallResult installWithConfig(BundlerConfig config)
    {
        InstallResult result;
        
        string[] cmd = ["bundle", "install"];
        
        // Apply configuration
        if (!config.path.empty)
            cmd ~= ["--path", config.path];
        
        if (config.deployment)
            cmd ~= "--deployment";
        
        if (config.local)
            cmd ~= "--local";
        
        if (config.frozen)
            cmd ~= "--frozen";
        
        if (config.jobs > 0)
            cmd ~= ["--jobs", config.jobs.to!string];
        
        if (config.retry_ > 0)
            cmd ~= ["--retry", config.retry_.to!string];
        
        if (!config.without.empty)
            cmd ~= ["--without", config.without.join(":")];
        
        if (!config.with_.empty)
            cmd ~= ["--with", config.with_.join(":")];
        
        if (config.clean)
            cmd ~= "--clean";
        
        structuredLog.info("installing_with_bundler_").field("detail", "Installing with Bundler: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        result.success = res.status == 0;
        result.output = res.output;
        
        if (!result.success)
            result.error = "Bundle install failed: " ~ res.output;
        else
            result.installedGems = parseInstalledGems(res.output);
        
        return result;
    }
    
    /// Check if bundle is in sync
    bool isInSync()
    {
        auto res = execute(["bundle", "check"], null, Config.none, size_t.max, projectRoot);
        return res.status == 0;
    }
    
    /// Get gem list from bundle
    string[] listGems()
    {
        auto res = execute(["bundle", "list"], null, Config.none, size_t.max, projectRoot);
        if (res.status != 0)
            return [];
        
        string[] gems;
        foreach (line; res.output.lineSplitter)
        {
            // Parse lines like "  * gem_name (version)"
            if (line.strip.startsWith("*"))
            {
                auto parts = line.strip[1..$].strip.split;
                if (!parts.empty)
                    gems ~= parts[0];
            }
        }
        return gems;
    }
    
    /// Execute in bundle context
    auto bundleExec(string[] cmd)
    {
        auto fullCmd = ["bundle", "exec"] ~ cmd;
        return execute(fullCmd, null, Config.none, size_t.max, projectRoot);
    }
    
    private string[] parseInstalledGems(string output)
    {
        string[] gems;
        foreach (line; output.lineSplitter)
        {
            // Look for "Installing gem_name" or "Using gem_name"
            if (line.canFind("Installing ") || line.canFind("Using "))
            {
                auto parts = line.split;
                if (parts.length >= 2)
                    gems ~= parts[1];
            }
        }
        return gems;
    }
}


