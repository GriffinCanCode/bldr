module languages.scripting.ruby.managers.environments;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.scripting.ruby.core.config;
import infrastructure.utils.logging;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Ruby version manager interface
interface VersionManager
{
    /// Get Ruby executable path
    string getRubyPath(string version_ = "");
    
    /// Check if version is installed
    bool isVersionInstalled(string version_);
    
    /// Install Ruby version (if supported)
    bool installVersion(string version_);
    
    /// Get current Ruby version
    string getCurrentVersion();
    
    /// Check if version manager is available
    bool isAvailable();
    
    /// Get version manager name
    string name() const;
}

/// Version manager factory
final class VersionManagerFactory
{
    /// Create version manager based on configuration
    static VersionManager create(RubyVersionManager type, string projectRoot = ".") @system
    {
        final switch (type)
        {
            case RubyVersionManager.Auto:
                return detectBest(projectRoot);
            case RubyVersionManager.Rbenv:
                return new RbenvManager(projectRoot);
            case RubyVersionManager.RVM:
                return new RVMManager(projectRoot);
            case RubyVersionManager.Chruby:
                return new ChrubyManager(projectRoot);
            case RubyVersionManager.ASDF:
                return new ASDFManager(projectRoot);
            case RubyVersionManager.System:
            case RubyVersionManager.None:
                return new SystemRubyManager();
        }
    }
    
    /// Detect best available version manager
    static VersionManager detectBest(string projectRoot) @system
    {
        // Priority order: rbenv > chruby > rvm > asdf > system
        
        // Check for .ruby-version file and corresponding manager
        immutable versionFile = buildPath(projectRoot, ".ruby-version");
        if (exists(versionFile))
        {
            // Try rbenv first (most common with .ruby-version)
            auto rbenv = new RbenvManager(projectRoot);
            if (rbenv.isAvailable())
            {
                structuredLog.debug_("detected_rbenv_from_rubyversion").emit();
                return rbenv;
            }
            
            // Try chruby
            auto chruby = new ChrubyManager(projectRoot);
            if (chruby.isAvailable())
            {
                structuredLog.debug_("detected_chruby_from_rubyversion").emit();
                return chruby;
            }
        }
        
        // Check for .rvmrc or .ruby-gemset (RVM)
        immutable rvmrc = buildPath(projectRoot, ".rvmrc");
        immutable gemset = buildPath(projectRoot, ".ruby-gemset");
        if (exists(rvmrc) || exists(gemset))
        {
            auto rvm = new RVMManager(projectRoot);
            if (rvm.isAvailable())
            {
                structuredLog.debug_("detected_rvm_from_rvmrc").emit();
                return rvm;
            }
        }
        
        // Check for .tool-versions (asdf)
        immutable toolVersions = buildPath(projectRoot, ".tool-versions");
        if (exists(toolVersions))
        {
            auto asdf = new ASDFManager(projectRoot);
            if (asdf.isAvailable())
            {
                structuredLog.debug_("detected_asdf_from_toolversions").emit();
                return asdf;
            }
        }
        
        // Try detecting by availability
        {
            auto rbenv = new RbenvManager(projectRoot);
            if (rbenv.isAvailable())
                return rbenv;
        }
        
        {
            auto chruby = new ChrubyManager(projectRoot);
            if (chruby.isAvailable())
                return chruby;
        }
        
        {
            auto rvm = new RVMManager(projectRoot);
            if (rvm.isAvailable())
                return rvm;
        }
        
        {
            auto asdf = new ASDFManager(projectRoot);
            if (asdf.isAvailable())
                return asdf;
        }
        
        // Fallback to system Ruby
        structuredLog.debug_("no_ruby_version_manager_detected_using_s").emit();
        return new SystemRubyManager();
    }
}

/// rbenv version manager (lightweight, shim-based)
final class RbenvManager : VersionManager
{
    private string projectRoot;
    
    this(string projectRoot = ".") @system pure nothrow @nogc
    {
        this.projectRoot = projectRoot;
    }
    
    override string getRubyPath(string version_ = "") const
    {
        if (!version_.empty)
        {
            // Get path for specific version
            const res = execute(["rbenv", "prefix", version_]);
            if (res.status == 0)
                return buildPath(res.output.strip, "bin", "ruby");
        }
        
        // Get current version's path
        const res = execute(["rbenv", "which", "ruby"], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
            return res.output.strip;
        
        return "ruby";
    }
    
    override bool isVersionInstalled(string version_) const
    {
        const res = execute(["rbenv", "versions", "--bare"]);
        if (res.status != 0)
            return false;
        
        foreach (line; res.output.lineSplitter)
        {
            if (line.strip == version_)
                return true;
        }
        return false;
    }
    
    override bool installVersion(string version_)
    {
        structuredLog.info("installing_ruby_").field("detail", "Installing Ruby " ~ version_ ~ " with rbenv").emit();
        
        // Check if ruby-build is available
        auto buildCheck = execute(["rbenv", "install", "--list"]);
        if (buildCheck.status != 0)
        {
            structuredLog.error("rubybuild_not_available_install_httpsgit").emit();
            return false;
        }
        
        auto res = execute(["rbenv", "install", version_]);
        if (res.status != 0)
        {
            structuredLog.error("failed_to_install_ruby_").field("detail", "Failed to install Ruby " ~ version_).emit();
            return false;
        }
        
        // Rehash after installation
        execute(["rbenv", "rehash"]);
        
        return true;
    }
    
    override string getCurrentVersion()
    {
        auto res = execute(["rbenv", "version-name"], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
            return res.output.strip;
        return "";
    }
    
    /// Check if rbenv is available
    /// 
    /// Safety: This function is @system because:
    /// 1. Executes external command (rbenv --version)
    /// 2. Uses array form of execute (no shell injection)
    /// 3. Read-only operation (just checks availability)
    /// 4. Exception handling ensures nothrow behavior
    /// 
    /// Invariants:
    /// - Returns true only if rbenv is installed and executable
    /// - Exception results in false (safe default)
    /// - No state modification (pure detection)
    /// 
    /// What could go wrong:
    /// - rbenv not in PATH: execute throws, caught, returns false
    /// - Permission denied: caught, returns false
    override bool isAvailable() @system
    {
        try
        {
            auto res = execute(["rbenv", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "rbenv";
    }
    
    /// Set local Ruby version
    bool setLocalVersion(string version_)
    {
        auto res = execute(["rbenv", "local", version_], null, Config.none, size_t.max, projectRoot);
        return res.status == 0;
    }
    
    /// Set global Ruby version
    bool setGlobalVersion(string version_)
    {
        auto res = execute(["rbenv", "global", version_]);
        return res.status == 0;
    }
    
    /// List available Ruby versions
    string[] listVersions() const
    {
        const res = execute(["rbenv", "versions", "--bare"]);
        if (res.status != 0)
            return [];
        
        return res.output.lineSplitter.map!(s => s.strip).array;
    }
}

/// RVM version manager (full-featured, function-based)
final class RVMManager : VersionManager
{
    private string projectRoot;
    
    this(string projectRoot = ".") @system pure nothrow @nogc
    {
        this.projectRoot = projectRoot;
    }
    
    override string getRubyPath(string version_ = "")
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate version string to prevent injection
        if (!version_.empty && !SecurityValidator.isArgumentSafe(version_))
        {
            structuredLog.error("invalid_ruby_version_").field("detail", "Invalid Ruby version: " ~ version_).emit();
            return "ruby";
        }
        
        // RVM uses shell functions, use safe bash -c with validated arguments
        string script;
        if (!version_.empty)
            script = "source ~/.rvm/scripts/rvm && rvm use '" ~ version_ ~ "' && which ruby";
        else
            script = "source ~/.rvm/scripts/rvm && which ruby";
        
        auto res = execute(["bash", "-c", script], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
            return res.output.strip;
        
        return "ruby";
    }
    
    override bool isVersionInstalled(string version_)
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate version before using
        if (!SecurityValidator.isArgumentSafe(version_))
            return false;
        
        auto script = "source ~/.rvm/scripts/rvm && rvm list strings";
        auto res = execute(["bash", "-c", script]);
        
        if (res.status != 0)
            return false;
        
        foreach (line; res.output.lineSplitter)
        {
            if (line.strip.canFind(version_))
                return true;
        }
        return false;
    }
    
    override bool installVersion(string version_)
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate version to prevent injection
        if (!SecurityValidator.isArgumentSafe(version_))
        {
            structuredLog.error("invalid_ruby_version_").field("detail", "Invalid Ruby version: " ~ version_).emit();
            return false;
        }
        
        structuredLog.info("installing_ruby_").field("detail", "Installing Ruby " ~ version_ ~ " with RVM").emit();
        
        auto script = "source ~/.rvm/scripts/rvm && rvm install '" ~ version_ ~ "'";
        auto res = execute(["bash", "-c", script]);
        
        if (res.status != 0)
        {
            structuredLog.error("failed_to_install_ruby_").field("detail", "Failed to install Ruby " ~ version_).emit();
            return false;
        }
        
        return true;
    }
    
    override string getCurrentVersion()
    {
        auto script = "source ~/.rvm/scripts/rvm && rvm current";
        auto res = execute(["bash", "-c", script], null, Config.none, size_t.max, projectRoot);
        
        if (res.status == 0)
            return res.output.strip;
        return "";
    }
    
    /// Check if RVM is available
    /// 
    /// Safety: @system because: Executes bash with source command (requires shell), uses exception handling for safe default
    override bool isAvailable() @system
    {
        try
        {
            auto script = "source ~/.rvm/scripts/rvm && rvm --version";
            auto res = execute(["bash", "-c", script]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "RVM";
    }
    
    /// Use specific Ruby version
    bool useVersion(string version_)
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate version
        if (!SecurityValidator.isArgumentSafe(version_))
        {
            structuredLog.error("invalid_ruby_version_").field("detail", "Invalid Ruby version: " ~ version_).emit();
            return false;
        }
        
        auto script = "source ~/.rvm/scripts/rvm && rvm use '" ~ version_ ~ "'";
        auto res = execute(["bash", "-c", script], null, Config.none, size_t.max, projectRoot);
        return res.status == 0;
    }
    
    /// Create gemset
    bool createGemset(string name)
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate gemset name
        if (!SecurityValidator.isArgumentSafe(name))
        {
            structuredLog.error("invalid_gemset_name_").field("detail", "Invalid gemset name: " ~ name).emit();
            return false;
        }
        
        auto script = "source ~/.rvm/scripts/rvm && rvm gemset create '" ~ name ~ "'";
        auto res = execute(["bash", "-c", script], null, Config.none, size_t.max, projectRoot);
        return res.status == 0;
    }
    
    /// Use gemset
    bool useGemset(string name)
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate gemset name
        if (!SecurityValidator.isArgumentSafe(name))
        {
            structuredLog.error("invalid_gemset_name_").field("detail", "Invalid gemset name: " ~ name).emit();
            return false;
        }
        
        auto script = "source ~/.rvm/scripts/rvm && rvm gemset use '" ~ name ~ "'";
        auto res = execute(["bash", "-c", script], null, Config.none, size_t.max, projectRoot);
        return res.status == 0;
    }
}

/// chruby version manager (minimal, elegant)
final class ChrubyManager : VersionManager
{
    private string projectRoot;
    
    this(string projectRoot = ".") @system pure nothrow @nogc
    {
        this.projectRoot = projectRoot;
    }
    
    override string getRubyPath(string version_ = "")
    {
        import infrastructure.utils.security.validation : SecurityValidator;
        
        // Validate version to prevent injection
        if (!version_.empty && !SecurityValidator.isArgumentSafe(version_))
        {
            structuredLog.error("invalid_ruby_version_").field("detail", "Invalid Ruby version: " ~ version_).emit();
            return "ruby";
        }
        
        // chruby modifies PATH, use safe bash -c with validated arguments
        string script;
        if (!version_.empty)
            script = "source /usr/local/share/chruby/chruby.sh && chruby '" ~ version_ ~ "' && which ruby";
        else
            script = "source /usr/local/share/chruby/chruby.sh && which ruby";
        
        auto res = execute(["bash", "-c", script], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
            return res.output.strip;
        
        return "ruby";
    }
    
    override bool isVersionInstalled(string version_)
    {
        // chruby looks for Rubies in ~/.rubies and /opt/rubies
        auto rubiesDirs = [
            expandTilde("~/.rubies"),
            "/opt/rubies"
        ];
        
        foreach (dir; rubiesDirs)
        {
            if (exists(dir))
            {
                try
                {
                    foreach (entry; dirEntries(dir, SpanMode.shallow))
                    {
                        if (entry.isDir && baseName(entry.name).canFind(version_))
                            return true;
                    }
                }
                catch (Exception e) {}
            }
        }
        
        return false;
    }
    
    override bool installVersion(string version_)
    {
        structuredLog.error("chruby_doesnt_support_automatic_installa").emit();
        structuredLog.error("__rubyinstall_ruby_").field("detail", "  ruby-install ruby " ~ version_).emit();
        return false;
    }
    
    override string getCurrentVersion()
    {
        // Check .ruby-version file
        auto versionFile = buildPath(projectRoot, ".ruby-version");
        if (exists(versionFile))
        {
            try
            {
                return readText(versionFile).strip;
            }
            catch (Exception e) {}
        }
        
        // Get from environment
        auto rubyVersion = environment.get("RUBY_VERSION", "");
        if (!rubyVersion.empty)
            return rubyVersion;
        
        return "";
    }
    
    /// Check if chruby is available
    /// 
    /// Safety: @system because: Checks file existence in known paths (file I/O), expandTilde() is system call
    override bool isAvailable() @system
    {
        // chruby is just a shell function, check if script exists
        return exists("/usr/local/share/chruby/chruby.sh") ||
               exists("/usr/share/chruby/chruby.sh") ||
               exists(expandTilde("~/.local/share/chruby/chruby.sh"));
    }
    
    override string name() const
    {
        return "chruby";
    }
}

/// asdf version manager (multi-language)
final class ASDFManager : VersionManager
{
    private string projectRoot;
    
    this(string projectRoot = ".") @system pure nothrow @nogc
    {
        this.projectRoot = projectRoot;
    }
    
    override string getRubyPath(string version_ = "")
    {
        if (!version_.empty)
        {
            auto res = execute(["asdf", "where", "ruby", version_]);
            if (res.status == 0)
                return buildPath(res.output.strip, "bin", "ruby");
        }
        
        auto res = execute(["asdf", "which", "ruby"], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
            return res.output.strip;
        
        return "ruby";
    }
    
    override bool isVersionInstalled(string version_)
    {
        auto res = execute(["asdf", "list", "ruby"]);
        if (res.status != 0)
            return false;
        
        foreach (line; res.output.lineSplitter)
        {
            if (line.strip.canFind(version_))
                return true;
        }
        return false;
    }
    
    override bool installVersion(string version_)
    {
        structuredLog.info("installing_ruby_").field("detail", "Installing Ruby " ~ version_ ~ " with asdf").emit();
        
        // Ensure ruby plugin is installed
        auto pluginRes = execute(["asdf", "plugin", "add", "ruby"]);
        // Ignore error if plugin already exists
        
        auto res = execute(["asdf", "install", "ruby", version_]);
        if (res.status != 0)
        {
            structuredLog.error("failed_to_install_ruby_").field("detail", "Failed to install Ruby " ~ version_).emit();
            return false;
        }
        
        return true;
    }
    
    override string getCurrentVersion()
    {
        auto res = execute(["asdf", "current", "ruby"], null, Config.none, size_t.max, projectRoot);
        if (res.status == 0)
        {
            // Parse output like "ruby 3.3.0 (set by ...)"
            auto parts = res.output.strip.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "";
    }
    
    /// Check if ASDF is available
    /// 
    /// Safety: @system because: Executes asdf command (process execution), exception handling provides safe default
    override bool isAvailable() @system
    {
        try
        {
            auto res = execute(["asdf", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "asdf";
    }
    
    /// Set local Ruby version
    bool setLocalVersion(string version_)
    {
        auto res = execute(["asdf", "local", "ruby", version_], null, Config.none, size_t.max, projectRoot);
        return res.status == 0;
    }
    
    /// Set global Ruby version
    bool setGlobalVersion(string version_)
    {
        auto res = execute(["asdf", "global", "ruby", version_]);
        return res.status == 0;
    }
}

/// System Ruby (no version manager)
final class SystemRubyManager : VersionManager
{
    override string getRubyPath(string version_ = "") const pure nothrow @nogc
    {
        return "ruby";
    }
    
    override bool isVersionInstalled(string version_) const
    {
        // Check if system Ruby matches requested version
        const res = execute(["ruby", "--version"]);
        if (res.status == 0)
        {
            return res.output.canFind(version_);
        }
        return false;
    }
    
    override bool installVersion(string version_)
    {
        structuredLog.error("cannot_install_ruby_versions_without_a_v").emit();
        structuredLog.error("consider_installing_rbenv_chruby_or_rvm").emit();
        return false;
    }
    
    override string getCurrentVersion()
    {
        auto res = execute(["ruby", "--version"]);
        if (res.status == 0)
        {
            // Parse "ruby 3.3.0 (2023-12-25 revision ...) [x86_64-darwin22]"
            auto parts = res.output.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "";
    }
    
    override bool isAvailable()
    {
        try
        {
            auto res = execute(["ruby", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    override string name() const
    {
        return "System Ruby";
    }
}

/// Ruby version utilities
final class RubyVersionUtil
{
    /// Parse .ruby-version file
    static string parseVersionFile(string filePath) @system
    {
        if (!exists(filePath))
            return "";
        
        try
        {
            string content = readText(filePath).strip;
            
            // Handle different formats:
            // "3.3.0"
            // "ruby-3.3.0"
            // "3.3.0@gemset" (RVM format)
            
            if (SIMDStrings.startsWith(content, "ruby-"))
                content = content[5..$];
            
            immutable atPos = content.indexOf("@");
            if (atPos > 0)
                content = content[0..atPos];
            
            return content;
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_rubyversion_").field("detail", "Failed to parse .ruby-version: " ~ e.msg).emit();
            return "";
        }
    }
    
    /// Write .ruby-version file
    static bool writeVersionFile(string filePath, string version_) @system
    {
        try
        {
            std.file.write(filePath, version_ ~ "\n");
            return true;
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_write_rubyversion_").field("detail", "Failed to write .ruby-version: " ~ e.msg).emit();
            return false;
        }
    }
    
    /// Compare versions
    static int compareVersions(string v1, string v2) @system
    {
        immutable parts1 = v1.split(".").map!(to!int).array;
        immutable parts2 = v2.split(".").map!(to!int).array;
        
        immutable len = min(parts1.length, parts2.length);
        
        foreach (i; 0..len)
        {
            if (parts1[i] < parts2[i])
                return -1;
            if (parts1[i] > parts2[i])
                return 1;
        }
        
        if (parts1.length < parts2.length)
            return -1;
        if (parts1.length > parts2.length)
            return 1;
        
        return 0;
    }
    
    /// Check if version satisfies requirement
    static bool satisfiesRequirement(string version_, string requirement) @system
    {
        // Simple version matching
        // Supports: "3.3", "3.3.0", ">= 3.0", "~> 3.3"
        
        immutable req = requirement.strip;
        
        if (SIMDStrings.startsWith(req, "~>"))
        {
            // Pessimistic version constraint
            immutable reqVer = req[2..$].strip;
            return SIMDStrings.startsWith(version_, reqVer);
        }
        else if (SIMDStrings.startsWith(req, ">="))
        {
            immutable reqVer = req[2..$].strip;
            return compareVersions(version_, reqVer) >= 0;
        }
        else if (SIMDStrings.startsWith(req, "<="))
        {
            immutable reqVer = req[2..$].strip;
            return compareVersions(version_, reqVer) <= 0;
        }
        else if (SIMDStrings.startsWith(req, ">"))
        {
            immutable reqVer = req[1..$].strip;
            return compareVersions(version_, reqVer) > 0;
        }
        else if (SIMDStrings.startsWith(req, "<"))
        {
            immutable reqVer = req[1..$].strip;
            return compareVersions(version_, reqVer) < 0;
        }
        else
        {
            // Exact match or prefix match
            return SIMDStrings.startsWith(version_, req);
        }
    }
    
    /// Get Ruby version from executable
    static string getRubyVersion(string rubyCmd = "ruby") @system
    {
        const res = execute([rubyCmd, "--version"]);
        if (res.status == 0)
        {
            immutable parts = res.output.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "";
    }
    
    /// Check if Ruby command is available
    static bool isRubyAvailable(string rubyCmd = "ruby") nothrow
    {
        try
        {
            const res = execute([rubyCmd, "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
}


