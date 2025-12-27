module languages.scripting.ruby.managers.factory;

import std.file;
import std.path;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.managers.base;
import languages.scripting.ruby.managers.bundler;
import languages.scripting.ruby.managers.rubygems;
import infrastructure.utils.logging;

/// Package manager factory
class PackageManagerFactory
{
    /// Create package manager based on configuration
    static PackageManager create(RubyPackageManager type, string projectRoot = ".")
    {
        final switch (type)
        {
            case RubyPackageManager.Auto:
                return detectBest(projectRoot);
            case RubyPackageManager.Bundler:
                return new BundlerManager(projectRoot);
            case RubyPackageManager.RubyGems:
                return new RubyGemsManager(projectRoot);
            case RubyPackageManager.None:
                return new NullPackageManager();
        }
    }
    
    /// Detect best available package manager
    static PackageManager detectBest(string projectRoot)
    {
        // Check for Gemfile - prefer Bundler
        if (exists(buildPath(projectRoot, "Gemfile")))
        {
            auto bundler = new BundlerManager(projectRoot);
            if (bundler.isAvailable())
            {
                structuredLog.debug_("detected_bundler_from_gemfile").emit();
                return bundler;
            }
        }
        
        // Check for gemspec files
        try
        {
            import std.file : SpanMode, dirEntries;
            auto files = dirEntries(projectRoot, "*.gemspec", SpanMode.shallow);
            if (!files.empty)
            {
                structuredLog.debug_("detected_gemspec_file_using_rubygems").emit();
                return new RubyGemsManager(projectRoot);
            }
        }
        catch (Exception e) {}
        
        // Default to Bundler if available
        auto bundler = new BundlerManager(projectRoot);
        if (bundler.isAvailable())
            return bundler;
        
        // Fallback to RubyGems
        return new RubyGemsManager(projectRoot);
    }
}

/// Null package manager (no-op)
class NullPackageManager : PackageManager
{
    override InstallResult install(string[] gems, bool development = false)
    {
        InstallResult result;
        result.success = true;
        return result;
    }
    
    override InstallResult installFromFile(string gemfilePath, bool deployment = false)
    {
        InstallResult result;
        result.success = true;
        return result;
    }
    
    override InstallResult update(string[] gems = [])
    {
        InstallResult result;
        result.success = true;
        return result;
    }
    
    override bool isAvailable()
    {
        return true;
    }
    
    override string name() const
    {
        return "None";
    }
    
    override string getVersion()
    {
        return "N/A";
    }
    
    override bool hasLockfile() const
    {
        return false;
    }
}


