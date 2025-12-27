module languages.scripting.r.tooling.info;

import std.stdio;
import std.process;
import std.string;
import std.algorithm;
import std.array;
import std.regex;
import std.conv;
import std.typecons;
import languages.scripting.r.core.config;
import infrastructure.utils.logging;

/// R tool availability and version information
struct RToolInfo
{
    string executable;
    bool available;
    string version_;
    string path;
    
    /// Check if tool meets version requirement
    bool meetsVersion(string requirement) const
    {
        if (requirement.empty || version_.empty)
            return available;
        
        return compareVersions(version_, requirement);
    }
}

/// Detect R installation
RToolInfo detectR(string executable = "R")
{
    RToolInfo info;
    info.executable = executable;
    
    version(Windows)
    {
        auto res = execute(["where", executable]);
        if (res.status == 0)
        {
            info.available = true;
            info.path = res.output.strip();
        }
    }
    else
    {
        auto res = execute(["which", executable]);
        if (res.status == 0)
        {
            info.available = true;
            info.path = res.output.strip();
        }
    }
    
    if (info.available)
    {
        info.version_ = getRVersion(executable);
    }
    
    return info;
}

/// Detect Rscript installation
RToolInfo detectRscript(string executable = "Rscript")
{
    RToolInfo info;
    info.executable = executable;
    
    version(Windows)
    {
        auto res = execute(["where", executable]);
        if (res.status == 0)
        {
            info.available = true;
            info.path = res.output.strip();
        }
    }
    else
    {
        auto res = execute(["which", executable]);
        if (res.status == 0)
        {
            info.available = true;
            info.path = res.output.strip();
        }
    }
    
    if (info.available)
    {
        info.version_ = getRscriptVersion(executable);
    }
    
    return info;
}

/// Get R version
string getRVersion(string rCmd = "R")
{
    auto res = execute([rCmd, "--version"]);
    if (res.status == 0 && !res.output.empty)
    {
        // Extract version from output: "R version 4.3.1 (2023-06-16)"
        auto versionMatch = matchFirst(res.output, regex(`R version (\d+\.\d+\.\d+)`));
        if (versionMatch)
            return versionMatch[1];
    }
    return "";
}

/// Get Rscript version
string getRscriptVersion(string rscriptCmd = "Rscript")
{
    auto res = execute([rscriptCmd, "--version"]);
    if (res.status == 0 && !res.output.empty)
    {
        // Extract version from stderr output
        auto versionMatch = matchFirst(res.output, regex(`R scripting front-end version (\d+\.\d+\.\d+)`));
        if (versionMatch)
            return versionMatch[1];
        
        // Try alternative format
        versionMatch = matchFirst(res.output, regex(`(\d+\.\d+\.\d+)`));
        if (versionMatch)
            return versionMatch[1];
    }
    return "";
}

/// Check if R package is installed
bool isRPackageInstalled(string packageName, string rCmd = "Rscript")
{
    string checkCode = `tryCatch({library(` ~ packageName ~ `, quietly=TRUE); quit(status=0)}, error=function(e) quit(status=1))`;
    auto res = execute([rCmd, "-e", checkCode]);
    return res.status == 0;
}

/// Get installed R package version
string getRPackageVersion(string packageName, string rCmd = "Rscript")
{
    string versionCode = `cat(as.character(packageVersion('` ~ packageName ~ `')))`;
    auto res = execute([rCmd, "-e", versionCode]);
    if (res.status == 0)
        return res.output.strip();
    return "";
}

/// Detect package manager availability
RToolInfo detectPackageManager(RPackageManager manager, string rCmd = "Rscript")
{
    RToolInfo info;
    
    final switch (manager)
    {
        case RPackageManager.Auto:
            // Will be resolved later
            info.available = true;
            return info;
            
        case RPackageManager.InstallPackages:
            // Always available with base R
            info.available = true;
            info.executable = "install.packages";
            return info;
            
        case RPackageManager.Pak:
            info.executable = "pak";
            info.available = isRPackageInstalled("pak", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("pak", rCmd);
            return info;
            
        case RPackageManager.Renv:
            info.executable = "renv";
            info.available = isRPackageInstalled("renv", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("renv", rCmd);
            return info;
            
        case RPackageManager.Packrat:
            info.executable = "packrat";
            info.available = isRPackageInstalled("packrat", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("packrat", rCmd);
            return info;
            
        case RPackageManager.Remotes:
            info.executable = "remotes";
            info.available = isRPackageInstalled("remotes", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("remotes", rCmd);
            return info;
            
        case RPackageManager.None:
            info.available = false;
            return info;
    }
}

/// Auto-detect best available package manager
RPackageManager detectBestPackageManager(string rCmd = "Rscript")
{
    // Priority: pak > renv (if project uses it) > install.packages
    
    if (isRPackageInstalled("pak", rCmd))
    {
        structuredLog.debug_("detected_pak_package_manager").emit();
        return RPackageManager.Pak;
    }
    
    // Check for renv project structure
    import std.file : exists;
    if (exists("renv.lock") && isRPackageInstalled("renv", rCmd))
    {
        structuredLog.debug_("detected_renv_project").emit();
        return RPackageManager.Renv;
    }
    
    // Default to standard install.packages
    structuredLog.debug_("using_standard_installpackages").emit();
    return RPackageManager.InstallPackages;
}

/// Detect linter availability
RToolInfo detectLinter(RLinter linter, string rCmd = "Rscript")
{
    RToolInfo info;
    
    final switch (linter)
    {
        case RLinter.Auto:
            // Will be resolved later
            info.available = true;
            return info;
            
        case RLinter.Lintr:
            info.executable = "lintr";
            info.available = isRPackageInstalled("lintr", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("lintr", rCmd);
            return info;
            
        case RLinter.Goodpractice:
            info.executable = "goodpractice";
            info.available = isRPackageInstalled("goodpractice", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("goodpractice", rCmd);
            return info;
            
        case RLinter.None:
            info.available = false;
            return info;
    }
}

/// Auto-detect best available linter
RLinter detectBestLinter(string rCmd = "Rscript")
{
    if (isRPackageInstalled("lintr", rCmd))
    {
        structuredLog.debug_("detected_lintr").emit();
        return RLinter.Lintr;
    }
    
    structuredLog.debug_("no_linter_detected").emit();
    return RLinter.None;
}

/// Detect formatter availability
RToolInfo detectFormatter(RFormatter formatter, string rCmd = "Rscript")
{
    RToolInfo info;
    
    final switch (formatter)
    {
        case RFormatter.Auto:
            // Will be resolved later
            info.available = true;
            return info;
            
        case RFormatter.Styler:
            info.executable = "styler";
            info.available = isRPackageInstalled("styler", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("styler", rCmd);
            return info;
            
        case RFormatter.FormatR:
            info.executable = "formatR";
            info.available = isRPackageInstalled("formatR", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("formatR", rCmd);
            return info;
            
        case RFormatter.None:
            info.available = false;
            return info;
    }
}

/// Auto-detect best available formatter
RFormatter detectBestFormatter(string rCmd = "Rscript")
{
    if (isRPackageInstalled("styler", rCmd))
    {
        structuredLog.debug_("detected_styler").emit();
        return RFormatter.Styler;
    }
    
    if (isRPackageInstalled("formatR", rCmd))
    {
        structuredLog.debug_("detected_formatr").emit();
        return RFormatter.FormatR;
    }
    
    structuredLog.debug_("no_formatter_detected").emit();
    return RFormatter.None;
}

/// Detect test framework availability
RToolInfo detectTestFramework(RTestFramework framework, string rCmd = "Rscript")
{
    RToolInfo info;
    
    final switch (framework)
    {
        case RTestFramework.Auto:
            // Will be resolved later
            info.available = true;
            return info;
            
        case RTestFramework.Testthat:
            info.executable = "testthat";
            info.available = isRPackageInstalled("testthat", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("testthat", rCmd);
            return info;
            
        case RTestFramework.Tinytest:
            info.executable = "tinytest";
            info.available = isRPackageInstalled("tinytest", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("tinytest", rCmd);
            return info;
            
        case RTestFramework.RUnit:
            info.executable = "RUnit";
            info.available = isRPackageInstalled("RUnit", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("RUnit", rCmd);
            return info;
            
        case RTestFramework.None:
            info.available = false;
            return info;
    }
}

/// Auto-detect best available test framework
RTestFramework detectBestTestFramework(string rCmd = "Rscript")
{
    import std.file : exists;
    
    // Check for testthat directory structure
    if (exists("tests/testthat") && isRPackageInstalled("testthat", rCmd))
    {
        structuredLog.debug_("detected_testthat_framework").emit();
        return RTestFramework.Testthat;
    }
    
    if (isRPackageInstalled("testthat", rCmd))
    {
        structuredLog.debug_("detected_testthat_installed").emit();
        return RTestFramework.Testthat;
    }
    
    if (isRPackageInstalled("tinytest", rCmd))
    {
        structuredLog.debug_("detected_tinytest").emit();
        return RTestFramework.Tinytest;
    }
    
    if (isRPackageInstalled("RUnit", rCmd))
    {
        structuredLog.debug_("detected_runit").emit();
        return RTestFramework.RUnit;
    }
    
    structuredLog.debug_("no_test_framework_detected").emit();
    return RTestFramework.None;
}

/// Detect documentation generator availability
RToolInfo detectDocGenerator(RDocGenerator generator, string rCmd = "Rscript")
{
    RToolInfo info;
    
    final switch (generator)
    {
        case RDocGenerator.Auto:
        case RDocGenerator.Both:
            // Will be resolved later
            info.available = true;
            return info;
            
        case RDocGenerator.Roxygen2:
            info.executable = "roxygen2";
            info.available = isRPackageInstalled("roxygen2", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("roxygen2", rCmd);
            return info;
            
        case RDocGenerator.Pkgdown:
            info.executable = "pkgdown";
            info.available = isRPackageInstalled("pkgdown", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("pkgdown", rCmd);
            return info;
            
        case RDocGenerator.None:
            info.available = false;
            return info;
    }
}

/// Auto-detect best available doc generator
RDocGenerator detectBestDocGenerator(string rCmd = "Rscript")
{
    bool hasRoxygen = isRPackageInstalled("roxygen2", rCmd);
    bool hasPkgdown = isRPackageInstalled("pkgdown", rCmd);
    
    if (hasRoxygen && hasPkgdown)
    {
        structuredLog.debug_("detected_roxygen2_and_pkgdown").emit();
        return RDocGenerator.Both;
    }
    
    if (hasRoxygen)
    {
        structuredLog.debug_("detected_roxygen2").emit();
        return RDocGenerator.Roxygen2;
    }
    
    if (hasPkgdown)
    {
        structuredLog.debug_("detected_pkgdown").emit();
        return RDocGenerator.Pkgdown;
    }
    
    structuredLog.debug_("no_doc_generator_detected").emit();
    return RDocGenerator.None;
}

/// Detect environment manager availability
RToolInfo detectEnvManager(REnvManager manager, string rCmd = "Rscript")
{
    RToolInfo info;
    
    final switch (manager)
    {
        case REnvManager.Auto:
            // Will be resolved later
            info.available = true;
            return info;
            
        case REnvManager.Renv:
            info.executable = "renv";
            info.available = isRPackageInstalled("renv", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("renv", rCmd);
            return info;
            
        case REnvManager.Packrat:
            info.executable = "packrat";
            info.available = isRPackageInstalled("packrat", rCmd);
            if (info.available)
                info.version_ = getRPackageVersion("packrat", rCmd);
            return info;
            
        case REnvManager.None:
            info.available = false;
            return info;
    }
}

/// Auto-detect best available environment manager
REnvManager detectBestEnvManager(string rCmd = "Rscript")
{
    import std.file : exists;
    
    // Check for renv project
    if (exists("renv.lock") || exists("renv"))
    {
        if (isRPackageInstalled("renv", rCmd))
        {
            structuredLog.debug_("detected_renv_environment").emit();
            return REnvManager.Renv;
        }
    }
    
    // Check for packrat project
    if (exists("packrat/packrat.lock"))
    {
        if (isRPackageInstalled("packrat", rCmd))
        {
            structuredLog.debug_("detected_packrat_environment").emit();
            return REnvManager.Packrat;
        }
    }
    
    structuredLog.debug_("no_environment_manager_detected").emit();
    return REnvManager.None;
}

/// Check if devtools is available
bool isDevtoolsAvailable(string rCmd = "Rscript")
{
    return isRPackageInstalled("devtools", rCmd);
}

/// Check if BiocManager is available
bool isBiocManagerAvailable(string rCmd = "Rscript")
{
    return isRPackageInstalled("BiocManager", rCmd);
}

/// Check if coverage tools are available
bool isCoverageAvailable(string rCmd = "Rscript")
{
    return isRPackageInstalled("covr", rCmd);
}

/// Compare version strings
private bool compareVersions(string actual, string requirement)
{
    // Parse requirement operator
    string op = ">=";
    string reqVer = requirement;
    
    if (requirement.startsWith(">="))
    {
        op = ">=";
        reqVer = requirement[2..$].strip();
    }
    else if (requirement.startsWith("<="))
    {
        op = "<=";
        reqVer = requirement[2..$].strip();
    }
    else if (requirement.startsWith(">"))
    {
        op = ">";
        reqVer = requirement[1..$].strip();
    }
    else if (requirement.startsWith("<"))
    {
        op = "<";
        reqVer = requirement[1..$].strip();
    }
    else if (requirement.startsWith("=="))
    {
        op = "==";
        reqVer = requirement[2..$].strip();
    }
    else if (requirement.startsWith("="))
    {
        op = "==";
        reqVer = requirement[1..$].strip();
    }
    
    // Parse version numbers
    auto actualParts = actual.split(".").map!(p => p.to!int).array;
    auto reqParts = reqVer.split(".").map!(p => p.to!int).array;
    
    // Pad to same length (avoid array concatenation in loop)
    immutable maxLen = max(actualParts.length, reqParts.length);
    if (actualParts.length < maxLen)
    {
        immutable oldLen = actualParts.length;
        actualParts.length = maxLen;
        actualParts[oldLen .. $] = 0;
    }
    if (reqParts.length < maxLen)
    {
        immutable oldLen = reqParts.length;
        reqParts.length = maxLen;
        reqParts[oldLen .. $] = 0;
    }
    
    // Compare
    int cmp = 0;
    foreach (i; 0..actualParts.length)
    {
        if (actualParts[i] < reqParts[i])
        {
            cmp = -1;
            break;
        }
        else if (actualParts[i] > reqParts[i])
        {
            cmp = 1;
            break;
        }
    }
    
    // Apply operator
    switch (op)
    {
        case "==": return cmp == 0;
        case ">=": return cmp >= 0;
        case "<=": return cmp <= 0;
        case ">": return cmp > 0;
        case "<": return cmp < 0;
        default: return true;
    }
}

/// Get R library paths
string[] getRLibPaths(string rCmd = "Rscript")
{
    string code = `cat(.libPaths(), sep="\n")`;
    auto res = execute([rCmd, "-e", code]);
    if (res.status == 0)
    {
        return res.output.strip().split("\n").map!(s => s.strip()).array;
    }
    return [];
}

/// Get R environment variables
string[string] getREnvironment(string rCmd = "Rscript")
{
    string[string] env;
    
    string code = `e <- Sys.getenv(); cat(paste(names(e), e, sep="="), sep="\n")`;
    auto res = execute([rCmd, "-e", code]);
    if (res.status == 0)
    {
        foreach (line; res.output.strip().split("\n"))
        {
            auto parts = line.split("=");
            if (parts.length >= 2)
            {
                env[parts[0]] = parts[1..$].join("=");
            }
        }
    }
    
    return env;
}

/// Get R capabilities (what features R was compiled with)
string[string] getRCapabilities(string rCmd = "R")
{
    string[string] caps;
    
    string code = `caps <- capabilities(); cat(paste(names(caps), caps, sep="="), sep="\n")`;
    auto res = execute([rCmd, "--vanilla", "--slave", "-e", code]);
    if (res.status == 0)
    {
        foreach (line; res.output.strip().split("\n"))
        {
            auto parts = line.split("=");
            if (parts.length == 2)
            {
                caps[parts[0]] = parts[1];
            }
        }
    }
    
    return caps;
}

