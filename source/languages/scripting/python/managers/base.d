module languages.scripting.python.managers.base;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.python.core.config;
import languages.scripting.python.tooling.detection : ToolDetection;
alias PyTools = ToolDetection;
import infrastructure.utils.logging;

/// Package installation result
struct InstallResult
{
    bool success;
    string error;
    string[] installedPackages;
    float timeSeconds;
}

/// Base interface for Python package managers
interface PackageManager
{
    /// Install dependencies from file
    InstallResult installFromFile(string file, bool upgrade = false, bool editable = false);
    
    /// Install specific packages
    InstallResult installPackages(string[] packages, bool upgrade = false, bool editable = false);
    
    /// Check if package manager is available
    bool isAvailable();
    
    /// Get package manager name
    string name() const;
    
    /// Get version
    string getVersion();
}

/// Null package manager - no installation
class NullManager : PackageManager
{
    InstallResult installFromFile(string file, bool upgrade = false, bool editable = false)
    {
        InstallResult result;
        result.success = true;
        structuredLog.warning("no_package_manager_available_skipping_in").emit();
        return result;
    }
    
    InstallResult installPackages(string[] packages, bool upgrade = false, bool editable = false)
    {
        InstallResult result;
        result.success = true;
        structuredLog.warning("no_package_manager_available_skipping_in").emit();
        return result;
    }
    
    bool isAvailable()
    {
        return true;
    }
    
    string name() const
    {
        return "none";
    }
    
    string getVersion()
    {
        return "n/a";
    }
}

