module languages.scripting.php.tooling.detection;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import infrastructure.utils.logging;
import infrastructure.utils.process : isCommandAvailable;

/// Result of running a PHP tool
struct ToolResult
{
    bool success;
    string output;
    string[] warnings;
    string[] errors;
    
    /// Check if tool found issues
    bool hasIssues() const pure nothrow
    {
        return !warnings.empty || !errors.empty;
    }
}

/// PHP interpreter information
struct PHPInfo
{
    string path;
    string version_;
    int majorVersion;
    int minorVersion;
    int releaseVersion;
    bool isThreadSafe;
    string sapi;
    string[] loadedExtensions;
    string iniPath;
    
    /// Check if extension is loaded
    bool hasExtension(string ext) const
    {
        return loadedExtensions.canFind(ext.toLower);
    }
}

/// PHP tooling wrapper - integrates analyzers, formatters, test frameworks
class PHPTools
{
    /// Byte conversion constants
    private enum long BYTES_PER_KB = 1024;
    private enum long BYTES_PER_MB = 1024 * 1024;
    private enum long BYTES_PER_GB = 1024 * 1024 * 1024;
    
    /// Check if PHP is available
    static bool isPHPAvailable(string phpCmd = "php")
    {
        auto res = execute([phpCmd, "--version"]);
        return res.status == 0;
    }
    
    /// Get PHP version
    static string getPHPVersion(string phpCmd = "php")
    {
        auto res = execute([phpCmd, "--version"]);
        if (res.status == 0)
        {
            // Extract version from output (e.g., "PHP 8.3.0 (cli)")
            auto versionMatch = matchFirst(res.output, regex(`PHP (\d+\.\d+\.\d+)`));
            if (versionMatch)
                return versionMatch[1];
            return res.output.lineSplitter.front.strip;
        }
        return "unknown";
    }
    
    /// Get detailed PHP information
    static PHPInfo getPHPInfo(string phpCmd = "php")
    {
        PHPInfo info;
        info.path = getPHPPath(phpCmd);
        
        // Get version
        auto versionOutput = getPHPVersion(phpCmd);
        auto versionMatch = matchFirst(versionOutput, regex(`(\d+)\.(\d+)\.(\d+)`));
        if (versionMatch)
        {
            info.version_ = versionMatch[0];
            info.majorVersion = versionMatch[1].to!int;
            info.minorVersion = versionMatch[2].to!int;
            info.releaseVersion = versionMatch[3].to!int;
        }
        
        // Check thread safety
        auto versionCmd = execute([phpCmd, "--version"]);
        if (versionCmd.status == 0)
        {
            info.isThreadSafe = versionCmd.output.canFind("thread safety");
        }
        
        // Get SAPI
        auto sapiCmd = execute([phpCmd, "-r", "echo php_sapi_name();"]);
        if (sapiCmd.status == 0)
            info.sapi = sapiCmd.output.strip;
        
        // Get loaded extensions
        auto extCmd = execute([phpCmd, "-m"]);
        if (extCmd.status == 0)
        {
            info.loadedExtensions = extCmd.output
                .lineSplitter
                .map!(line => line.strip.toLower)
                .filter!(line => !line.empty && line[0] != '[')
                .array;
        }
        
        // Get INI path
        auto iniCmd = execute([phpCmd, "--ini"]);
        if (iniCmd.status == 0)
        {
            foreach (line; iniCmd.output.lineSplitter)
            {
                if (line.canFind("Loaded Configuration File"))
                {
                    auto parts = line.split(":");
                    if (parts.length > 1)
                        info.iniPath = parts[1].strip;
                    break;
                }
            }
        }
        
        return info;
    }
    
    /// Get PHP interpreter path
    static string getPHPPath(string phpCmd = "php")
    {
        version(Windows)
        {
            auto res = execute(["where", phpCmd]);
        }
        else
        {
            auto res = execute(["which", phpCmd]);
        }
        
        if (res.status == 0)
            return res.output.strip.split("\n")[0].strip;
        return "";
    }
    
    /// Validate PHP syntax for a file
    static ToolResult validateSyntax(string filePath, string phpCmd = "php")
    {
        ToolResult result;
        result.success = true;
        
        auto cmd = [phpCmd, "-l", filePath];
        auto res = execute(cmd);
        
        result.output = res.output;
        
        if (res.status != 0)
        {
            result.success = false;
            result.errors ~= "Syntax error in " ~ filePath ~ ": " ~ res.output;
        }
        
        return result;
    }
    
    /// Validate syntax for multiple files in batch
    static ToolResult validateSyntaxBatch(const string[] files, string phpCmd = "php")
    {
        ToolResult result;
        result.success = true;
        
        foreach (file; files)
        {
            auto fileResult = validateSyntax(file, phpCmd);
            if (!fileResult.success)
            {
                result.success = false;
                result.errors ~= fileResult.errors;
            }
        }
        
        return result;
    }
    
    /// Check if Composer is available
    static bool isComposerAvailable(string composerCmd = "composer")
    {
        auto res = execute([composerCmd, "--version"]);
        return res.status == 0;
    }
    
    /// Check if PHPStan is available
    static bool isPHPStanAvailable()
    {
        // Try global installation
        auto res = execute(["phpstan", "--version"]);
        if (res.status == 0)
            return true;
        
        // Try vendor/bin
        string vendorBin = buildPath("vendor", "bin", "phpstan");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Get PHPStan command path
    static string getPHPStanCommand()
    {
        auto res = execute(["phpstan", "--version"]);
        if (res.status == 0)
            return "phpstan";
        
        string vendorBin = buildPath("vendor", "bin", "phpstan");
        if (exists(vendorBin))
            return vendorBin;
        
        return "";
    }
    
    /// Check if Psalm is available
    static bool isPsalmAvailable()
    {
        auto res = execute(["psalm", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "psalm");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Get Psalm command path
    static string getPsalmCommand()
    {
        auto res = execute(["psalm", "--version"]);
        if (res.status == 0)
            return "psalm";
        
        string vendorBin = buildPath("vendor", "bin", "psalm");
        if (exists(vendorBin))
            return vendorBin;
        
        return "";
    }
    
    /// Check if Phan is available
    static bool isPhanAvailable()
    {
        auto res = execute(["phan", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "phan");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Check if PHP-CS-Fixer is available
    static bool isPHPCSFixerAvailable()
    {
        auto res = execute(["php-cs-fixer", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "php-cs-fixer");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Get PHP-CS-Fixer command path
    static string getPHPCSFixerCommand()
    {
        auto res = execute(["php-cs-fixer", "--version"]);
        if (res.status == 0)
            return "php-cs-fixer";
        
        string vendorBin = buildPath("vendor", "bin", "php-cs-fixer");
        if (exists(vendorBin))
            return vendorBin;
        
        return "";
    }
    
    /// Check if PHP_CodeSniffer is available
    static bool isPHPCSAvailable()
    {
        auto res = execute(["phpcs", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "phpcs");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Get PHPCS command path
    static string getPHPCSCommand()
    {
        auto res = execute(["phpcs", "--version"]);
        if (res.status == 0)
            return "phpcs";
        
        string vendorBin = buildPath("vendor", "bin", "phpcs");
        if (exists(vendorBin))
            return vendorBin;
        
        return "";
    }
    
    /// Check if PHPUnit is available
    static bool isPHPUnitAvailable()
    {
        auto res = execute(["phpunit", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "phpunit");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Get PHPUnit command path
    static string getPHPUnitCommand()
    {
        auto res = execute(["phpunit", "--version"]);
        if (res.status == 0)
            return "phpunit";
        
        string vendorBin = buildPath("vendor", "bin", "phpunit");
        if (exists(vendorBin))
            return vendorBin;
        
        return "";
    }
    
    /// Check if Pest is available
    static bool isPestAvailable()
    {
        auto res = execute(["pest", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "pest");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Check if Codeception is available
    static bool isCodeceptionAvailable()
    {
        auto res = execute(["codecept", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "codecept");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Check if Behat is available
    static bool isBehatAvailable()
    {
        auto res = execute(["behat", "--version"]);
        if (res.status == 0)
            return true;
        
        string vendorBin = buildPath("vendor", "bin", "behat");
        if (exists(vendorBin))
            return true;
        
        return false;
    }
    
    /// Check if Box (PHAR builder) is available
    static bool isBoxAvailable()
    {
        auto res = execute(["box", "--version"]);
        if (res.status == 0)
            return true;
        
        // Check for box.phar
        if (exists("box.phar"))
            return true;
        
        return false;
    }
    
    /// Get Box command
    static string getBoxCommand()
    {
        auto res = execute(["box", "--version"]);
        if (res.status == 0)
            return "box";
        
        if (exists("box.phar"))
            return "php box.phar";
        
        return "";
    }
    
    /// Check if FrankenPHP is available
    static bool isFrankenPHPAvailable(string frankenphpCmd = "frankenphp")
    {
        auto res = execute([frankenphpCmd, "version"]);
        return res.status == 0;
    }
    
    /// Get FrankenPHP version
    static string getFrankenPHPVersion(string frankenphpCmd = "frankenphp")
    {
        auto res = execute([frankenphpCmd, "version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Check if PHP extension is loaded
    static bool isExtensionLoaded(string extension, string phpCmd = "php")
    {
        auto cmd = [phpCmd, "-r", "echo extension_loaded('" ~ extension ~ "') ? '1' : '0';"];
        auto res = execute(cmd);
        
        if (res.status == 0)
            return res.output.strip == "1";
        
        return false;
    }
    
    /// Get list of loaded PHP extensions
    static string[] getLoadedExtensions(string phpCmd = "php")
    {
        auto cmd = [phpCmd, "-m"];
        auto res = execute(cmd);
        
        if (res.status == 0)
        {
            return res.output
                .lineSplitter
                .map!(line => line.strip)
                .filter!(line => !line.empty && line[0] != '[')
                .array;
        }
        
        return [];
    }
    
    /// Check if PHP has required extensions for a project
    static string[] checkRequiredExtensions(string[] required, string phpCmd = "php")
    {
        string[] missing;
        
        foreach (ext; required)
        {
            if (!isExtensionLoaded(ext, phpCmd))
                missing ~= ext;
        }
        
        return missing;
    }
    
    /// Run PHP script and capture output
    static ToolResult runScript(string scriptPath, string[] args = [], string phpCmd = "php")
    {
        ToolResult result;
        
        string[] cmd = [phpCmd, scriptPath] ~ args;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        result.output = res.output;
        
        if (res.status != 0)
        {
            result.success = false;
            result.errors ~= "Script execution failed: " ~ res.output;
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
    
    /// Check INI setting value
    static string getIniSetting(string setting, string phpCmd = "php")
    {
        auto cmd = [phpCmd, "-r", "echo ini_get('" ~ setting ~ "');"];
        auto res = execute(cmd);
        
        if (res.status == 0)
            return res.output.strip;
        
        return "";
    }
    
    /// Get PHP memory limit in bytes
    static long getMemoryLimit(string phpCmd = "php")
    {
        string limit = getIniSetting("memory_limit", phpCmd);
        
        if (limit == "-1")
            return -1; // Unlimited
        
        // Parse value like "128M", "1G", etc.
        auto match = matchFirst(limit, regex(`(\d+)([KMG]?)`));
        if (match)
        {
            long value = match[1].to!long;
            string unit = match[2];
            
            switch (unit.toUpper)
            {
                case "K": return value * BYTES_PER_KB;
                case "M": return value * BYTES_PER_MB;
                case "G": return value * BYTES_PER_GB;
                default: return value;
            }
        }
        
        return 0;
    }
    
}

