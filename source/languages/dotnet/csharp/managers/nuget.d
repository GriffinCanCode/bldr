module languages.dotnet.csharp.managers.nuget;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.dotnet.csharp.core.config;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;

/// NuGet package management operations
struct NuGetOps
{
    /// Restore NuGet packages
    static bool restore(string projectRoot, NuGetConfig config)
    {
        structuredLog.info("restoring_nuget_packages").emit();
        
        string[] cmd = ["dotnet", "restore"];
        
        // Config file
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["--configfile", config.configFile];
        
        // Packages directory
        if (!config.packagesDirectory.empty)
            cmd ~= ["--packages", config.packagesDirectory];
        
        // Sources
        foreach (source; config.sources)
        {
            cmd ~= ["--source", source];
        }
        
        // Locked mode
        if (config.lockedMode)
            cmd ~= ["--locked-mode"];
        
        // Force evaluate
        if (config.forceEvaluate)
            cmd ~= ["--force-evaluate"];
        
        // No cache
        if (config.noCache)
            cmd ~= ["--no-cache"];
        
        // Execute restore - use safe array form
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.error("nuget_restore_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        structuredLog.info("nuget_restore_succeeded").emit();
        return true;
    }
    
    /// Install a NuGet package
    static bool install(string projectRoot, string packageName, string packageVersion = "")
    {
        structuredLog.info("installing_nuget_package_").field("detail", "Installing NuGet package: " ~ packageName).emit();
        
        string[] cmd = ["dotnet", "add", "package", packageName];
        
        if (!packageVersion.empty)
            cmd ~= ["--version", packageVersion];
        
        // Use safe array form instead of executeShell
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.error("package_install_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        structuredLog.info("package_installed_successfully").emit();
        return true;
    }
    
    /// Remove a NuGet package
    static bool remove(string projectRoot, string packageName)
    {
        structuredLog.info("removing_nuget_package_").field("detail", "Removing NuGet package: " ~ packageName).emit();
        
        string[] cmd = ["dotnet", "remove", "package", packageName];
        
        // Use safe array form instead of executeShell
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.error("package_removal_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        structuredLog.info("package_removed_successfully").emit();
        return true;
    }
    
    /// List installed packages
    static string[] listPackages(string projectRoot)
    {
        string[] packages;
        
        string[] cmd = ["dotnet", "list", "package"];
        
        // Use safe array form instead of executeShell
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.warning("failed_to_list_packages_").field("detail", "Failed to list packages: " ~ result.output).emit();
            return packages;
        }
        
        // Parse output
        auto lines = result.output.split("\n");
        foreach (line; lines)
        {
            line = line.strip();
            if (line.startsWith(">"))
            {
                // Package line format: "> PackageName    Version"
                auto parts = line[1..$].split();
                if (parts.length >= 2)
                    packages ~= parts[0] ~ " " ~ parts[1];
            }
        }
        
        return packages;
    }
    
    /// Update packages
    static bool update(string projectRoot)
    {
        structuredLog.info("updating_nuget_packages").emit();
        
        // List packages first
        auto packages = listPackages(projectRoot);
        
        foreach (pkg; packages)
        {
            auto parts = pkg.split();
            if (parts.length >= 1)
            {
                // Update to latest version
                string[] cmd = ["dotnet", "add", "package", parts[0]];
                // Use safe array form instead of executeShell
                execute(cmd, null, Config.none, size_t.max, projectRoot);
            }
        }
        
        structuredLog.info("package_update_completed").emit();
        return true;
    }
    
    /// Check for outdated packages
    static string[] outdatedPackages(string projectRoot)
    {
        string[] outdated;
        
        string[] cmd = ["dotnet", "list", "package", "--outdated"];
        
        // Use safe array form instead of executeShell
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            structuredLog.warning("failed_to_check_outdated_packages_").field("detail", "Failed to check outdated packages: " ~ result.output).emit();
            return outdated;
        }
        
        // Parse output
        auto lines = result.output.split("\n");
        foreach (line; lines)
        {
            line = line.strip();
            if (line.startsWith(">"))
            {
                outdated ~= line[1..$].strip();
            }
        }
        
        return outdated;
    }
    
    /// Check for vulnerable packages
    static string[] vulnerablePackages(string projectRoot)
    {
        string[] vulnerable;
        
        string[] cmd = ["dotnet", "list", "package", "--vulnerable"];
        
        // Use safe array form instead of executeShell
        auto result = execute(cmd, null, Config.none, size_t.max, projectRoot);
        
        if (result.status != 0)
        {
            // Vulnerability check might not be available in all versions
            return vulnerable;
        }
        
        // Parse output
        auto lines = result.output.split("\n");
        foreach (line; lines)
        {
            line = line.strip();
            if (line.startsWith(">"))
            {
                vulnerable ~= line[1..$].strip();
            }
        }
        
        return vulnerable;
    }
}

