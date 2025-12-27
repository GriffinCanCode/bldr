module languages.scripting.php.managers.composer;

import std.json;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.process;
import std.range;
import infrastructure.utils.logging;

/// Composer.json metadata
struct ComposerMetadata
{
    string name;
    string description;
    string type;
    string version_;
    string[] keywords;
    string license;
    string[string] authors;
    string[string] require;
    string[string] requireDev;
    AutoloadConfig autoload;
    AutoloadConfig autoloadDev;
    ScriptsConfig scripts;
    ConfigSection config;
    string minimumStability;
    bool preferStable;
    
    /// Parse from JSON
    static ComposerMetadata fromJSON(JSONValue json)
    {
        ComposerMetadata meta;
        
        if ("name" in json) meta.name = json["name"].str;
        if ("description" in json) meta.description = json["description"].str;
        if ("type" in json) meta.type = json["type"].str;
        if ("version" in json) meta.version_ = json["version"].str;
        if ("license" in json) meta.license = json["license"].str;
        if ("minimum-stability" in json) meta.minimumStability = json["minimum-stability"].str;
        if ("prefer-stable" in json) meta.preferStable = json["prefer-stable"].type == JSONType.true_;
        
        if ("keywords" in json)
            meta.keywords = json["keywords"].array.map!(e => e.str).array;
        
        if ("require" in json)
        {
            foreach (string pkg, ver; json["require"].object)
                meta.require[pkg] = ver.str;
        }
        
        if ("require-dev" in json)
        {
            foreach (string pkg, ver; json["require-dev"].object)
                meta.requireDev[pkg] = ver.str;
        }
        
        if ("autoload" in json)
            meta.autoload = AutoloadConfig.fromJSON(json["autoload"]);
        
        if ("autoload-dev" in json)
            meta.autoloadDev = AutoloadConfig.fromJSON(json["autoload-dev"]);
        
        if ("scripts" in json)
            meta.scripts = ScriptsConfig.fromJSON(json["scripts"]);
        
        if ("config" in json)
            meta.config = ConfigSection.fromJSON(json["config"]);
        
        return meta;
    }
    
    /// Get PHP version requirement
    string getPHPVersion() const
    {
        if ("php" in require)
            return require["php"];
        return "";
    }
    
    /// Check if package requires specific extension
    bool requiresExtension(string ext) const
    {
        string extKey = "ext-" ~ ext;
        return (extKey in require) !is null || (extKey in requireDev) !is null;
    }
    
    /// Get all PSR-4 namespaces
    const(string[string]) getPSR4Namespaces() const
    {
        return autoload.psr4;
    }
}

/// Autoload configuration
struct AutoloadConfig
{
    string[string] psr4;
    string[string] psr0;
    string[] classmap;
    string[] files;
    string[] excludeFromClassmap;
    
    static AutoloadConfig fromJSON(JSONValue json)
    {
        AutoloadConfig config;
        
        if ("psr-4" in json)
        {
            foreach (string ns, path; json["psr-4"].object)
            {
                if (path.type == JSONType.string)
                    config.psr4[ns] = path.str;
                else if (path.type == JSONType.array)
                    config.psr4[ns] = path.array[0].str; // Take first path
            }
        }
        
        if ("psr-0" in json)
        {
            foreach (string ns, path; json["psr-0"].object)
            {
                if (path.type == JSONType.string)
                    config.psr0[ns] = path.str;
                else if (path.type == JSONType.array)
                    config.psr0[ns] = path.array[0].str;
            }
        }
        
        if ("classmap" in json)
            config.classmap = json["classmap"].array.map!(e => e.str).array;
        
        if ("files" in json)
            config.files = json["files"].array.map!(e => e.str).array;
        
        if ("exclude-from-classmap" in json)
            config.excludeFromClassmap = json["exclude-from-classmap"].array.map!(e => e.str).array;
        
        return config;
    }
    
    /// Validate PSR-4 mapping
    bool validatePSR4(string projectRoot) const
    {
        foreach (ns, dir; psr4)
        {
            string fullPath = buildPath(projectRoot, dir);
            if (!exists(fullPath) || !isDir(fullPath))
            {
                structuredLog.warning("psr4_directory_not_found_").field("detail", "PSR-4 directory not found: " ~ fullPath ~ " for namespace " ~ ns).emit();
                return false;
            }
        }
        return true;
    }
}

/// Scripts configuration
struct ScriptsConfig
{
    string[string] scripts;
    
    static ScriptsConfig fromJSON(JSONValue json)
    {
        ScriptsConfig config;
        
        foreach (string name, cmd; json.object)
        {
            if (cmd.type == JSONType.string)
                config.scripts[name] = cmd.str;
            else if (cmd.type == JSONType.array)
                config.scripts[name] = cmd.array.map!(e => e.str).join(" && ");
        }
        
        return config;
    }
    
    /// Get script command
    string getScript(string name) const
    {
        if (name in scripts)
            return scripts[name];
        return "";
    }
}

/// Config section
struct ConfigSection
{
    string vendorDir = "vendor";
    string binDir = "vendor/bin";
    bool optimizeAutoloader = false;
    bool classMapAuthoritative = false;
    bool apcu = false;
    string platform;
    
    static ConfigSection fromJSON(JSONValue json)
    {
        ConfigSection config;
        
        if ("vendor-dir" in json) config.vendorDir = json["vendor-dir"].str;
        if ("bin-dir" in json) config.binDir = json["bin-dir"].str;
        if ("optimize-autoloader" in json) config.optimizeAutoloader = json["optimize-autoloader"].type == JSONType.true_;
        if ("classmap-authoritative" in json) config.classMapAuthoritative = json["classmap-authoritative"].type == JSONType.true_;
        if ("apcu-autoloader" in json) config.apcu = json["apcu-autoloader"].type == JSONType.true_;
        
        return config;
    }
}

/// Composer tool wrapper
class ComposerTool
{
    private string composerPath;
    private string projectRoot;
    
    this(string composerPath = "composer", string projectRoot = ".")
    {
        this.composerPath = composerPath;
        this.projectRoot = projectRoot;
    }
    
    /// Check if composer is available
    static bool isAvailable(string composerPath = "composer")
    {
        auto res = execute([composerPath, "--version"]);
        return res.status == 0;
    }
    
    /// Get composer version
    static string getVersion(string composerPath = "composer")
    {
        auto res = execute([composerPath, "--version", "--no-ansi"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Find composer.json in directory tree
    static string findComposerJson(string startDir)
    {
        string dir = startDir;
        
        while (dir != "/" && dir.length > 1)
        {
            string composerPath = buildPath(dir, "composer.json");
            if (exists(composerPath) && isFile(composerPath))
                return composerPath;
            
            string parentDir = dirName(dir);
            if (parentDir == dir) // Reached root
                break;
            dir = parentDir;
        }
        
        return "";
    }
    
    /// Parse composer.json
    static ComposerMetadata parseComposerJson(string composerJsonPath)
    {
        if (!exists(composerJsonPath))
            assert(false, "fileNotFoundError (Composer dependency analysis): " ~ composerJsonPath);
        
        try
        {
            string content = readText(composerJsonPath);
            auto json = parseJSON(content);
            return ComposerMetadata.fromJSON(json);
        }
        catch (Exception e)
        {
            assert(false, "parseErrorWithContext (" ~ composerJsonPath ~ "): Failed to parse composer.json: " ~ e.msg);
        }
    }
    
    /// Run composer install
    bool install(bool noDev = false, bool optimize = false)
    {
        string[] cmd = [composerPath, "install"];
        
        if (noDev)
            cmd ~= "--no-dev";
        
        if (optimize)
        {
            cmd ~= "--optimize-autoloader";
            cmd ~= "--classmap-authoritative";
        }
        
        cmd ~= "--no-interaction";
        
        structuredLog.info("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("composer_install_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run composer update
    bool update(string[] packages = [])
    {
        string[] cmd = [composerPath, "update"];
        
        if (!packages.empty)
            cmd ~= packages;
        else
            cmd ~= "--no-interaction";
        
        structuredLog.info("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("composer_update_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run composer dump-autoload
    bool dumpAutoload(bool optimize = true, bool authoritative = false, bool apcu = false)
    {
        string[] cmd = [composerPath, "dump-autoload"];
        
        if (optimize)
            cmd ~= "--optimize";
        
        if (authoritative)
            cmd ~= "--classmap-authoritative";
        
        if (apcu)
            cmd ~= "--apcu";
        
        structuredLog.info("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("composer_dumpautoload_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Validate composer.json
    bool validate()
    {
        string[] cmd = [composerPath, "validate", "--no-check-all"];
        
        structuredLog.debug_("validating_composerjson").emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.warning("composer_validation_failed_").field("detail", "Composer validation failed: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Check if composer.lock exists and is up to date
    bool isLockFileValid()
    {
        string lockPath = buildPath(projectRoot, "composer.lock");
        string jsonPath = buildPath(projectRoot, "composer.json");
        
        if (!exists(lockPath))
            return false;
        
        if (!exists(jsonPath))
            return false;
        
        // Check if composer.json is newer than composer.lock
        auto lockTime = timeLastModified(lockPath);
        auto jsonTime = timeLastModified(jsonPath);
        
        return lockTime >= jsonTime;
    }
    
    /// Get autoload file path
    string getAutoloadPath() const
    {
        return buildPath(projectRoot, "vendor", "autoload.php");
    }
    
    /// Check if vendor directory exists
    bool hasVendorDir() const
    {
        string vendorPath = buildPath(projectRoot, "vendor");
        return exists(vendorPath) && isDir(vendorPath);
    }
}

/// PSR-4 autoload validator
class PSR4Validator
{
    /// Validate PSR-4 compliance for a PHP file
    static bool validateFile(string filePath, string namespace, string basePath)
    {
        if (!exists(filePath))
            return false;
        
        try
        {
            string content = readText(filePath);
            
            // Extract declared namespace from file
            auto declaredNs = extractNamespace(content);
            if (declaredNs.empty)
            {
                structuredLog.warning("no_namespace_found_in_").field("detail", "No namespace found in: " ~ filePath).emit();
                return false;
            }
            
            // Calculate expected namespace from file path
            string expectedNs = calculateExpectedNamespace(filePath, namespace, basePath);
            
            if (declaredNs != expectedNs)
            {
                structuredLog.warning("namespace_mismatch_in_").field("detail", "Namespace mismatch in " ~ filePath ~ 
                             ": expected " ~ expectedNs ~ ", found " ~ declaredNs).emit();
                return false;
            }
            
            // Extract class name from file
            string className = extractClassName(content);
            if (className.empty)
            {
                structuredLog.warning("no_classinterfacetrait_found_in_").field("detail", "No class/interface/trait found in: " ~ filePath).emit();
                return false;
            }
            
            // Check if filename matches class name
            string expectedFilename = className ~ ".php";
            string actualFilename = baseName(filePath);
            
            if (actualFilename != expectedFilename)
            {
                structuredLog.warning("filename_mismatch_in_").field("detail", "Filename mismatch in " ~ filePath ~
                             ": expected " ~ expectedFilename ~ ", found " ~ actualFilename).emit();
                return false;
            }
            
            return true;
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_validate_").field("detail", "Failed to validate " ~ filePath ~ ": " ~ e.msg).emit();
            return false;
        }
    }
    
    /// Extract namespace from PHP content
    private static string extractNamespace(string content)
    {
        import std.regex;
        
        // Match: namespace Foo\Bar\Baz;
        auto namespaceRegex = regex(`namespace\s+([\w\\]+)\s*;", "m`);
        auto match = matchFirst(content, namespaceRegex);
        
        if (match.empty)
            return "";
        
        return match[1];
    }
    
    /// Extract class/interface/trait name from PHP content
    private static string extractClassName(string content)
    {
        import std.regex;
        
        // Match: class/interface/trait/enum Name
        auto classRegex = regex(`(?:class|interface|trait|enum)\s+(\w+)", "m`);
        auto match = matchFirst(content, classRegex);
        
        if (match.empty)
            return "";
        
        return match[1];
    }
    
    /// Calculate expected namespace based on file path
    private static string calculateExpectedNamespace(
        string filePath,
        string psr4Namespace,
        string psr4BasePath
    )
    {
        // Normalize paths
        string absFile = absolutePath(filePath);
        string absBase = absolutePath(psr4BasePath);
        
        // Get relative path from base
        string relPath = relativePath(dirName(absFile), absBase);
        
        if (relPath == ".")
            return psr4Namespace.stripRight("\\");
        
        // Convert path separators to namespace separators
        string pathNs = relPath.replace("/", "\\").replace("\\\\", "\\");
        
        // Combine with base namespace
        string fullNs = psr4Namespace ~ pathNs;
        
        return fullNs.stripRight("\\");
    }
}

