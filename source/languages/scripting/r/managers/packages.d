module languages.scripting.r.managers.packages;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import languages.scripting.r.core.config;
import languages.scripting.r.tooling.info;
import infrastructure.utils.logging;

/// Result of package installation
struct PackageInstallResult
{
    bool success;
    string error;
    string[] installedPackages;
    string[] failedPackages;
}

/// Install R packages using specified package manager
PackageInstallResult installPackages(
    RPackageDep[] packages,
    RPackageManager manager,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    if (packages.empty)
    {
        return PackageInstallResult(true, "", [], []);
    }
    
    // Auto-detect if needed
    if (manager == RPackageManager.Auto)
    {
        manager = detectBestPackageManager(rCmd);
    }
    
    structuredLog.info("installing_").field("detail", "Installing " ~ packages.length.to!string ~ " R package(s) using " ~ manager.to!string).emit();
    
    final switch (manager)
    {
        case RPackageManager.Auto:
            // Should have been resolved above
            return PackageInstallResult(false, "Failed to auto-detect package manager", [], []);
            
        case RPackageManager.InstallPackages:
            return installWithInstallPackages(packages, rCmd, workDir, config);
            
        case RPackageManager.Pak:
            return installWithPak(packages, rCmd, workDir, config);
            
        case RPackageManager.Renv:
            return installWithRenv(packages, rCmd, workDir, config);
            
        case RPackageManager.Packrat:
            return installWithPackrat(packages, rCmd, workDir, config);
            
        case RPackageManager.Remotes:
            return installWithRemotes(packages, rCmd, workDir, config);
            
        case RPackageManager.None:
            return PackageInstallResult(true, "", [], []);
    }
}

/// Install using standard install.packages()
private PackageInstallResult installWithInstallPackages(
    RPackageDep[] packages,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    PackageInstallResult result;
    
    // Build repository string
    string reposStr = `c("` ~ config.cranMirror ~ `"`;
    foreach (repo; config.additionalRepos)
    {
        reposStr ~= `, "` ~ repo ~ `"`;
    }
    reposStr ~= ")";
    
    // Separate packages by repository type
    RPackageDep[] cranPackages;
    RPackageDep[] biocPackages;
    RPackageDep[] githubPackages;
    
    foreach (pkg; packages)
    {
        final switch (pkg.repository)
        {
            case RRepository.CRAN:
            case RRepository.Custom:
                cranPackages ~= pkg;
                break;
            case RRepository.Bioconductor:
                biocPackages ~= pkg;
                break;
            case RRepository.GitHub:
            case RRepository.GitLab:
                githubPackages ~= pkg;
                break;
        }
    }
    
    // Install CRAN packages
    if (!cranPackages.empty)
    {
        string[] pkgNames = cranPackages.map!(p => `"` ~ p.name ~ `"`).array;
        string installCode = `install.packages(c(` ~ pkgNames.join(",") ~ `), repos=` ~ reposStr ~ `, dependencies=TRUE, quiet=FALSE)`;
        
        structuredLog.debug_("installing_cran_packages_").field("detail", "Installing CRAN packages: " ~ installCode).emit();
        
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", installCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Failed to install CRAN packages: " ~ res.output;
            result.failedPackages ~= cranPackages.map!(p => p.name).array;
            return result;
        }
        
        result.installedPackages ~= cranPackages.map!(p => p.name).array;
    }
    
    // Install Bioconductor packages
    if (!biocPackages.empty)
    {
        // First ensure BiocManager is installed
        string checkBioc = `if (!requireNamespace("BiocManager", quietly=TRUE)) install.packages("BiocManager", repos=` ~ reposStr ~ `)`;
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", checkBioc], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Failed to install BiocManager: " ~ res.output;
            result.failedPackages ~= biocPackages.map!(p => p.name).array;
            return result;
        }
        
        // Install Bioconductor packages
        string[] pkgNames = biocPackages.map!(p => `"` ~ p.name ~ `"`).array;
        string installCode = `BiocManager::install(c(` ~ pkgNames.join(",") ~ `))`;
        
        structuredLog.debug_("installing_bioconductor_packages_").field("detail", "Installing Bioconductor packages: " ~ installCode).emit();
        
        res = execute([rCmd, "-e", installCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Failed to install Bioconductor packages: " ~ res.output;
            result.failedPackages ~= biocPackages.map!(p => p.name).array;
            return result;
        }
        
        result.installedPackages ~= biocPackages.map!(p => p.name).array;
    }
    
    // Install GitHub packages (requires remotes)
    if (!githubPackages.empty)
    {
        // Ensure remotes is installed
        string checkRemotes = `if (!requireNamespace("remotes", quietly=TRUE)) install.packages("remotes", repos=` ~ reposStr ~ `)`;
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", checkRemotes], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Failed to install remotes: " ~ res.output;
            result.failedPackages ~= githubPackages.map!(p => p.name).array;
            return result;
        }
        
        // Install GitHub packages one by one (they may have different refs)
        foreach (pkg; githubPackages)
        {
            string installCmd;
            if (pkg.repository == RRepository.GitHub)
            {
                string refStr = pkg.gitRef.empty ? "" : `@ref="` ~ pkg.gitRef ~ `"`;
                installCmd = `remotes::install_github("` ~ pkg.customUrl ~ `"` ~ refStr ~ `)`;
            }
            else // GitLab
            {
                installCmd = `remotes::install_gitlab("` ~ pkg.customUrl ~ `")`;
            }
            
            structuredLog.debug_("installing_from_git_").field("detail", "Installing from Git: " ~ installCmd).emit();
            
            res = execute([rCmd, "-e", installCmd], env, Config.none, size_t.max, workDir);
            
            if (res.status != 0)
            {
                result.failedPackages ~= pkg.name;
            }
            else
            {
                result.installedPackages ~= pkg.name;
            }
        }
        
        if (!result.failedPackages.empty)
        {
            result.error = "Failed to install some GitHub packages";
            return result;
        }
    }
    
    result.success = true;
    return result;
}

/// Install using pak (modern, fast, with caching)
private PackageInstallResult installWithPak(
    RPackageDep[] packages,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    PackageInstallResult result;
    
    // Ensure pak is installed
    if (!isRPackageInstalled("pak", rCmd))
    {
        structuredLog.info("installing_pak_package_manager").emit();
        string installPak = `install.packages("pak", repos="` ~ config.cranMirror ~ `")`;
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", installPak], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Failed to install pak: " ~ res.output;
            return result;
        }
    }
    
    // Build package specification
    string[] pkgSpecs;
    foreach (pkg; packages)
    {
        string spec;
        final switch (pkg.repository)
        {
            case RRepository.CRAN:
            case RRepository.Custom:
                spec = pkg.name;
                if (!pkg.version_.empty)
                    spec ~= "@" ~ pkg.version_;
                break;
            case RRepository.Bioconductor:
                spec = "bioc::" ~ pkg.name;
                break;
            case RRepository.GitHub:
                spec = pkg.customUrl;
                if (!pkg.gitRef.empty)
                    spec ~= "@" ~ pkg.gitRef;
                break;
            case RRepository.GitLab:
                spec = "gitlab::" ~ pkg.customUrl;
                break;
        }
        pkgSpecs ~= `"` ~ spec ~ `"`;
    }
    
    string installCode = `pak::pkg_install(c(` ~ pkgSpecs.join(",") ~ `), upgrade=FALSE)`;
    
    structuredLog.info("installing_packages_with_pak_").field("detail", "Installing packages with pak: " ~ installCode).emit();
    
    auto env = prepareEnvironment(config);
    auto res = execute([rCmd, "-e", installCode], env, Config.none, size_t.max, workDir);
    
    if (res.status != 0)
    {
        result.error = "pak installation failed: " ~ res.output;
        result.failedPackages = packages.map!(p => p.name).array;
        return result;
    }
    
    result.success = true;
    result.installedPackages = packages.map!(p => p.name).array;
    return result;
}

/// Install using renv (reproducible environments)
private PackageInstallResult installWithRenv(
    RPackageDep[] packages,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    PackageInstallResult result;
    
    // Check if renv project exists
    string renvLock = buildPath(workDir, "renv.lock");
    
    if (exists(renvLock))
    {
        // Restore from lockfile
        structuredLog.info("restoring_packages_from_renvlock").emit();
        string restoreCode = `renv::restore()`;
        
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", restoreCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "renv restore failed: " ~ res.output;
            return result;
        }
    }
    else
    {
        // Initialize renv if needed
        if (!exists(buildPath(workDir, "renv")))
        {
            structuredLog.info("initializing_renv_environment").emit();
            string initCode = `renv::init(bare=TRUE)`;
            
            auto env = prepareEnvironment(config);
            auto res = execute([rCmd, "-e", initCode], env, Config.none, size_t.max, workDir);
            
            if (res.status != 0)
            {
                result.error = "renv init failed: " ~ res.output;
                return result;
            }
        }
        
        // Install packages
        string[] pkgNames = packages.map!(p => `"` ~ p.name ~ `"`).array;
        string installCode = `renv::install(c(` ~ pkgNames.join(",") ~ `))`;
        
        structuredLog.info("installing_packages_with_renv").emit();
        
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", installCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "renv install failed: " ~ res.output;
            result.failedPackages = packages.map!(p => p.name).array;
            return result;
        }
        
        // Snapshot the environment
        string snapshotCode = `renv::snapshot()`;
        res = execute([rCmd, "-e", snapshotCode], env, Config.none, size_t.max, workDir);
    }
    
    result.success = true;
    result.installedPackages = packages.map!(p => p.name).array;
    return result;
}

/// Install using packrat (legacy)
private PackageInstallResult installWithPackrat(
    RPackageDep[] packages,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    PackageInstallResult result;
    
    // Check if packrat project exists
    string packratLock = buildPath(workDir, "packrat", "packrat.lock");
    
    if (exists(packratLock))
    {
        // Restore from lockfile
        structuredLog.info("restoring_packages_from_packratlock").emit();
        string restoreCode = `packrat::restore()`;
        
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", restoreCode], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "packrat restore failed: " ~ res.output;
            return result;
        }
    }
    else
    {
        // Initialize packrat if needed
        if (!exists(buildPath(workDir, "packrat")))
        {
            structuredLog.info("initializing_packrat_environment").emit();
            string initCode = `packrat::init()`;
            
            auto env = prepareEnvironment(config);
            auto res = execute([rCmd, "-e", initCode], env, Config.none, size_t.max, workDir);
            
            if (res.status != 0)
            {
                result.error = "packrat init failed: " ~ res.output;
                return result;
            }
        }
    }
    
    result.success = true;
    result.installedPackages = packages.map!(p => p.name).array;
    return result;
}

/// Install using remotes package
private PackageInstallResult installWithRemotes(
    RPackageDep[] packages,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    PackageInstallResult result;
    
    // Ensure remotes is installed
    if (!isRPackageInstalled("remotes", rCmd))
    {
        structuredLog.info("installing_remotes_package").emit();
        string installRemotes = `install.packages("remotes", repos="` ~ config.cranMirror ~ `")`;
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", installRemotes], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Failed to install remotes: " ~ res.output;
            return result;
        }
    }
    
    // Install packages based on repository type
    auto env = prepareEnvironment(config);
    
    foreach (pkg; packages)
    {
        string installCmd;
        
        final switch (pkg.repository)
        {
            case RRepository.CRAN:
            case RRepository.Custom:
                installCmd = `remotes::install_cran("` ~ pkg.name ~ `")`;
                break;
            case RRepository.Bioconductor:
                installCmd = `remotes::install_bioc("` ~ pkg.name ~ `")`;
                break;
            case RRepository.GitHub:
                string refParam = pkg.gitRef.empty ? "" : `, ref="` ~ pkg.gitRef ~ `"`;
                installCmd = `remotes::install_github("` ~ pkg.customUrl ~ `"` ~ refParam ~ `)`;
                break;
            case RRepository.GitLab:
                installCmd = `remotes::install_gitlab("` ~ pkg.customUrl ~ `")`;
                break;
        }
        
        structuredLog.debug_("installing_with_remotes_").field("detail", "Installing with remotes: " ~ installCmd).emit();
        
        auto res = execute([rCmd, "-e", installCmd], env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.failedPackages ~= pkg.name;
        }
        else
        {
            result.installedPackages ~= pkg.name;
        }
    }
    
    if (!result.failedPackages.empty)
    {
        result.error = "Failed to install some packages with remotes";
        return result;
    }
    
    result.success = true;
    return result;
}

/// Install dependencies from DESCRIPTION file
PackageInstallResult installFromDESCRIPTION(
    string descPath,
    RPackageManager manager,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    if (!exists(descPath))
    {
        return PackageInstallResult(false, "DESCRIPTION file not found: " ~ descPath, [], []);
    }
    
    structuredLog.info("installing_dependencies_from_description").emit();
    
    // Auto-detect if needed
    if (manager == RPackageManager.Auto)
    {
        manager = detectBestPackageManager(rCmd);
    }
    
    // Use devtools if available and requested
    if (config.package_.useDevtools && isDevtoolsAvailable(rCmd))
    {
        string installCode = `devtools::install_deps("` ~ dirName(descPath) ~ `", dependencies=TRUE)`;
        
        structuredLog.debug_("installing_with_devtools_").field("detail", "Installing with devtools: " ~ installCode).emit();
        
        auto env = prepareEnvironment(config);
        auto res = execute([rCmd, "-e", installCode], env, Config.none, size_t.max, workDir);
        
        if (res.status == 0)
        {
            return PackageInstallResult(true, "", [], []);
        }
    }
    
    // Fallback: parse DESCRIPTION and install manually
    import languages.scripting.r.analysis.dependencies : parseDESCRIPTION;
    
    auto deps = parseDESCRIPTION(descPath);
    return installPackages(deps, manager, rCmd, workDir, config);
}

/// Prepare environment variables for R execution
private string[string] prepareEnvironment(const ref RConfig config)
{
    import std.process : environment;
    
    string[string] env;
    
    // Copy system environment
    foreach (key, value; environment.toAA())
        env[key] = value;
    
    // Add custom R environment variables
    foreach (key, value; config.rEnv)
        env[key] = value;
    
    // Add library paths
    if (!config.libPaths.empty)
    {
        env["R_LIBS_USER"] = config.libPaths.join(":");
    }
    
    // Set CRAN mirror
    if (!config.cranMirror.empty)
    {
        env["R_CRAN_MIRROR"] = config.cranMirror;
    }
    
    return env;
}

/// Update package to latest version
PackageInstallResult updatePackage(
    string packageName,
    RPackageManager manager,
    string rCmd,
    string workDir,
    const ref RConfig config
)
{
    structuredLog.info("updating_package_").field("detail", "Updating package: " ~ packageName).emit();
    
    if (manager == RPackageManager.Auto)
    {
        manager = detectBestPackageManager(rCmd);
    }
    
    final switch (manager)
    {
        case RPackageManager.Auto:
            return PackageInstallResult(false, "Failed to detect package manager", [], []);
            
        case RPackageManager.Pak:
            string updateCode = `pak::pkg_install("` ~ packageName ~ `", upgrade=TRUE)`;
            auto env = prepareEnvironment(config);
            auto res = execute([rCmd, "-e", updateCode], env, Config.none, size_t.max, workDir);
            
            if (res.status == 0)
                return PackageInstallResult(true, "", [packageName], []);
            else
                return PackageInstallResult(false, res.output, [], [packageName]);
            
        case RPackageManager.InstallPackages:
        case RPackageManager.Remotes:
            string updateCode = `update.packages("` ~ packageName ~ `", repos="` ~ config.cranMirror ~ `")`;
            auto env = prepareEnvironment(config);
            auto res = execute([rCmd, "-e", updateCode], env, Config.none, size_t.max, workDir);
            
            if (res.status == 0)
                return PackageInstallResult(true, "", [packageName], []);
            else
                return PackageInstallResult(false, res.output, [], [packageName]);
            
        case RPackageManager.Renv:
            string updateCode = `renv::update("` ~ packageName ~ `")`;
            auto env = prepareEnvironment(config);
            auto res = execute([rCmd, "-e", updateCode], env, Config.none, size_t.max, workDir);
            
            if (res.status == 0)
                return PackageInstallResult(true, "", [packageName], []);
            else
                return PackageInstallResult(false, res.output, [], [packageName]);
            
        case RPackageManager.Packrat:
        case RPackageManager.None:
            return PackageInstallResult(false, "Package updates not supported with " ~ manager.to!string, [], []);
    }
}

/// Remove package
bool removePackage(string packageName, string rCmd, string workDir)
{
    structuredLog.info("removing_package_").field("detail", "Removing package: " ~ packageName).emit();
    
    string removeCode = `remove.packages("` ~ packageName ~ `")`;
    auto res = execute([rCmd, "-e", removeCode], null, Config.none, size_t.max, workDir);
    
    return res.status == 0;
}

