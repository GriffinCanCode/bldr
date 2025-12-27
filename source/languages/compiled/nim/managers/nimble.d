module languages.compiled.nim.managers.nimble;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.compiled.nim.analysis.nimble;
import infrastructure.utils.logging;

/// Nimble package manager operations
class NimbleManager
{
    /// Install package dependencies
    static bool installDependencies(
        string projectDir,
        bool devMode = false,
        bool verbose = false
    )
    {
        string nimbleFile = NimbleParser.findNimbleFile(projectDir);
        
        if (nimbleFile.empty)
        {
            structuredLog.warning("no_nimble_file_found_skipping_dependency").emit();
            return true;
        }
        
        structuredLog.info("installing_nimble_dependencies").emit();
        
        string[] cmd = ["nimble", "install", "-y"];
        
        if (devMode)
            cmd ~= "--depsOnly";
        
        if (verbose)
            cmd ~= "--verbose";
        
        string workDir = dirName(nimbleFile);
        
        auto res = execute(cmd, null, std.process.Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            structuredLog.error("dependency_installation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("dependencies_installed_successfully").emit();
        return true;
    }
    
    /// Update package dependencies
    static bool updateDependencies(string projectDir, bool verbose = false)
    {
        structuredLog.info("updating_nimble_dependencies").emit();
        
        string[] cmd = ["nimble", "update"];
        
        if (verbose)
            cmd ~= "--verbose";
        
        auto res = execute(cmd, null, std.process.Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            structuredLog.error("dependency_update_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("dependencies_updated_successfully").emit();
        return true;
    }
    
    /// Install a specific package
    static bool installPackage(
        string packageName,
        string versionConstraint = "",
        bool verbose = false
    )
    {
        structuredLog.info("installing_package_").field("detail", "Installing package: " ~ packageName).emit();
        
        string[] cmd = ["nimble", "install", "-y"];
        
        if (!versionConstraint.empty)
            cmd ~= packageName ~ "@" ~ versionConstraint;
        else
            cmd ~= packageName;
        
        if (verbose)
            cmd ~= "--verbose";
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("package_installation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("package_installed_successfully").emit();
        return true;
    }
    
    /// List installed packages
    static string[] listPackages()
    {
        string[] packages;
        
        auto res = execute(["nimble", "list", "-i"]);
        
        if (res.status == 0)
        {
            // Parse output
            foreach (line; res.output.split("\n"))
            {
                line = line.strip();
                if (!line.empty && !line.startsWith("#"))
                {
                    // Extract package name (format: "package [version]")
                    auto parts = line.split(" ");
                    if (!parts.empty)
                        packages ~= parts[0];
                }
            }
        }
        
        return packages;
    }
    
    /// Search for packages
    static PackageInfo[] search(string query)
    {
        PackageInfo[] results;
        
        auto res = execute(["nimble", "search", query]);
        
        if (res.status == 0)
        {
            // Parse search results
            // Format varies, just collect package names for now
            foreach (line; res.output.split("\n"))
            {
                line = line.strip();
                if (!line.empty && !line.startsWith("#"))
                {
                    PackageInfo pkg;
                    auto parts = line.split("-");
                    if (!parts.empty)
                    {
                        pkg.name = parts[0].strip();
                        if (parts.length > 1)
                            pkg.description = parts[1 .. $].join("-").strip();
                        results ~= pkg;
                    }
                }
            }
        }
        
        return results;
    }
    
    /// Uninstall a package
    static bool uninstallPackage(string packageName)
    {
        structuredLog.info("uninstalling_package_").field("detail", "Uninstalling package: " ~ packageName).emit();
        
        auto res = execute(["nimble", "uninstall", "-y", packageName]);
        
        if (res.status != 0)
        {
            structuredLog.error("package_uninstallation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("package_uninstalled_successfully").emit();
        return true;
    }
    
    /// Initialize a new nimble package
    static bool initPackage(string dir, string packageName, bool isLibrary = false)
    {
        structuredLog.info("initializing_nimble_package_").field("detail", "Initializing nimble package: " ~ packageName).emit();
        
        string[] cmd = ["nimble", "init"];
        
        if (isLibrary)
            cmd ~= "-l";
        
        cmd ~= packageName;
        
        auto res = execute(cmd, null, std.process.Config.none, size_t.max, dir);
        
        if (res.status != 0)
        {
            structuredLog.error("package_initialization_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("package_initialized_successfully").emit();
        return true;
    }
}

/// Package information from search
struct PackageInfo
{
    string name;
    string description;
    string version_;
    string url;
}

