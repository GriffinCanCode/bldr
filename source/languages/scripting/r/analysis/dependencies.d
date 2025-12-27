module languages.scripting.r.analysis.dependencies;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.json;
import std.regex;
import std.conv;
import languages.scripting.r.core.config;
import infrastructure.utils.logging;

/// Parse dependencies from DESCRIPTION file
RPackageDep[] parseDESCRIPTION(string descPath)
{
    if (!exists(descPath))
    {
        structuredLog.warning("description_file_not_found_").field("detail", "DESCRIPTION file not found: " ~ descPath).emit();
        return [];
    }
    
    RPackageDep[] deps;
    string content = readText(descPath);
    
    // Parse different dependency sections
    deps ~= parseDependencySection(content, "Depends", RRepository.CRAN);
    deps ~= parseDependencySection(content, "Imports", RRepository.CRAN);
    deps ~= parseDependencySection(content, "Suggests", RRepository.CRAN);
    deps ~= parseDependencySection(content, "LinkingTo", RRepository.CRAN);
    
    structuredLog.debug_("parsed_").field("detail", "Parsed " ~ deps.length.to!string ~ " dependencies from DESCRIPTION").emit();
    return deps;
}

/// Parse a specific dependency section from DESCRIPTION
private RPackageDep[] parseDependencySection(string content, string sectionName, RRepository defaultRepo)
{
    RPackageDep[] deps;
    
    // Match section: "SectionName: pkg1, pkg2 (>= 1.0.0), pkg3"
    // Can span multiple lines with indentation
    auto sectionRegex = regex(sectionName ~ r":\s*([^\n]*(?:\n\s+[^\n]+)*)", "m");
    auto match = matchFirst(content, sectionRegex);
    
    if (!match.empty)
    {
        string depStr = match[1].strip();
        
        // Remove line breaks and extra spaces
        depStr = depStr.replaceAll(regex(`\s+`), " ");
        
        // Split by comma
        auto depParts = depStr.split(",");
        
        foreach (part; depParts)
        {
            auto dep = parseDependencySpec(part.strip(), defaultRepo);
            if (dep.name != "R") // Exclude R itself
            {
                deps ~= dep;
            }
        }
    }
    
    return deps;
}

/// Parse individual dependency specification
private RPackageDep parseDependencySpec(string spec, RRepository defaultRepo)
{
    RPackageDep dep;
    dep.repository = defaultRepo;
    
    // Match "package (>= 1.0.0)" or just "package"
    auto versionRegex = regex(`^([^\s(]+)\s*(?:\(([^)]+)\))?`);
    auto match = matchFirst(spec, versionRegex);
    
    if (!match.empty)
    {
        dep.name = match[1].strip();
        if (match.length > 2 && !match[2].empty)
        {
            dep.version_ = match[2].strip();
        }
    }
    else
    {
        dep.name = spec.strip();
    }
    
    return dep;
}

/// Parse dependencies from renv.lock
RPackageDep[] parseRenvLock(string lockPath)
{
    if (!exists(lockPath))
    {
        structuredLog.warning("renvlock_file_not_found_").field("detail", "renv.lock file not found: " ~ lockPath).emit();
        return [];
    }
    
    RPackageDep[] deps;
    
    try
    {
        string content = readText(lockPath);
        auto json = parseJSON(content);
        
        if ("Packages" in json && json["Packages"].type == JSONType.object)
        {
            foreach (string pkgName, pkgInfo; json["Packages"].object)
            {
                RPackageDep dep;
                dep.name = pkgName;
                
                if ("Version" in pkgInfo)
                {
                    dep.version_ = "== " ~ pkgInfo["Version"].str;
                }
                
                if ("Repository" in pkgInfo)
                {
                    string repo = pkgInfo["Repository"].str.toLower();
                    if (repo == "cran")
                        dep.repository = RRepository.CRAN;
                    else if (repo.canFind("bioc"))
                        dep.repository = RRepository.Bioconductor;
                    else
                        dep.repository = RRepository.Custom;
                }
                else
                {
                    dep.repository = RRepository.CRAN;
                }
                
                // Check for GitHub source
                if ("RemoteType" in pkgInfo && pkgInfo["RemoteType"].str == "github")
                {
                    dep.repository = RRepository.GitHub;
                    if ("RemoteUsername" in pkgInfo && "RemoteRepo" in pkgInfo)
                    {
                        dep.customUrl = pkgInfo["RemoteUsername"].str ~ "/" ~ pkgInfo["RemoteRepo"].str;
                    }
                    if ("RemoteRef" in pkgInfo)
                    {
                        dep.gitRef = pkgInfo["RemoteRef"].str;
                    }
                }
                
                deps ~= dep;
            }
        }
        
        structuredLog.debug_("parsed_").field("detail", "Parsed " ~ deps.length.to!string ~ " dependencies from renv.lock").emit();
    }
    catch (Exception e)
    {
        structuredLog.error("failed_to_parse_renvlock_").field("detail", "Failed to parse renv.lock: " ~ e.msg).emit();
    }
    
    return deps;
}

/// Parse dependencies from packrat.lock
RPackageDep[] parsePackratLock(string lockPath)
{
    if (!exists(lockPath))
    {
        structuredLog.warning("packratlock_file_not_found_").field("detail", "packrat.lock file not found: " ~ lockPath).emit();
        return [];
    }
    
    RPackageDep[] deps;
    
    try
    {
        string content = readText(lockPath);
        
        // packrat.lock has a custom format:
        // PackratFormat: 1.4
        // PackratVersion: 0.5.0
        // RVersion: 4.0.0
        // Repos: CRAN=https://cran.rstudio.com/
        //
        // Package: packagename
        // Source: CRAN
        // Version: 1.0.0
        // Hash: xxxxx
        //
        // Package: another
        // ...
        
        auto packageRegex = regex(`Package:\s*(\S+)`, "m");
        auto sourceRegex = regex(`Source:\s*(\S+)`, "m");
        auto versionRegex = regex(`Version:\s*(\S+)`, "m");
        
        // Split by double newline to get package blocks
        auto blocks = content.split("\n\n");
        
        foreach (block; blocks)
        {
            auto pkgMatch = matchFirst(block, packageRegex);
            if (!pkgMatch.empty)
            {
                RPackageDep dep;
                dep.name = pkgMatch[1];
                
                auto verMatch = matchFirst(block, versionRegex);
                if (!verMatch.empty)
                {
                    dep.version_ = "== " ~ verMatch[1];
                }
                
                auto srcMatch = matchFirst(block, sourceRegex);
                if (!srcMatch.empty)
                {
                    string source = srcMatch[1].toLower();
                    if (source == "cran")
                        dep.repository = RRepository.CRAN;
                    else if (source.canFind("bioc"))
                        dep.repository = RRepository.Bioconductor;
                    else if (source == "github")
                        dep.repository = RRepository.GitHub;
                    else
                        dep.repository = RRepository.Custom;
                }
                else
                {
                    dep.repository = RRepository.CRAN;
                }
                
                deps ~= dep;
            }
        }
        
        structuredLog.debug_("parsed_").field("detail", "Parsed " ~ deps.length.to!string ~ " dependencies from packrat.lock").emit();
    }
    catch (Exception e)
    {
        structuredLog.error("failed_to_parse_packratlock_").field("detail", "Failed to parse packrat.lock: " ~ e.msg).emit();
    }
    
    return deps;
}

/// Detect and parse dependencies from project
RPackageDep[] detectDependencies(string projectDir)
{
    structuredLog.debug_("detecting_dependencies_in_").field("detail", "Detecting dependencies in: " ~ projectDir).emit();
    
    // Try renv.lock first (most specific)
    string renvLock = buildPath(projectDir, "renv.lock");
    if (exists(renvLock))
    {
        structuredLog.debug_("found_renvlock_parsing").emit();
        return parseRenvLock(renvLock);
    }
    
    // Try packrat.lock
    string packratLock = buildPath(projectDir, "packrat", "packrat.lock");
    if (exists(packratLock))
    {
        structuredLog.debug_("found_packratlock_parsing").emit();
        return parsePackratLock(packratLock);
    }
    
    // Try DESCRIPTION file
    string descPath = buildPath(projectDir, "DESCRIPTION");
    if (exists(descPath))
    {
        structuredLog.debug_("found_description_parsing").emit();
        return parseDESCRIPTION(descPath);
    }
    
    // Scan R files for library() calls
    structuredLog.debug_("no_lock_files_or_description_found_scann").emit();
    return scanRFilesForDependencies(projectDir);
}

/// Scan R files for library()/require() calls
RPackageDep[] scanRFilesForDependencies(string projectDir)
{
    import std.file : dirEntries, SpanMode;
    import infrastructure.utils.security.validation;
    
    RPackageDep[string] depsMap; // Use map to deduplicate
    
    try
    {
        foreach (entry; dirEntries(projectDir, "*.{R,r}", SpanMode.shallow))
        {
            // Validate entry is within project directory
            if (!SecurityValidator.isPathWithinBase(entry.name, projectDir))
                continue;
            
            if (entry.isFile)
            {
                auto fileDeps = scanRFile(entry.name);
                foreach (dep; fileDeps)
                {
                    depsMap[dep.name] = dep;
                }
            }
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("error_scanning_r_files_").field("detail", "Error scanning R files: " ~ e.msg).emit();
    }
    
    auto deps = depsMap.values;
    structuredLog.debug_("scanned_r_files_found_").field("detail", "Scanned R files, found " ~ deps.length.to!string ~ " unique dependencies").emit();
    return deps;
}

/// Scan a single R file for dependencies
RPackageDep[] scanRFile(string filePath)
{
    RPackageDep[] deps;
    
    try
    {
        string content = readText(filePath);
        
        // Match library() and require() calls
        // library(pkg) or library("pkg") or library('pkg')
        auto libraryRegex = regex(`(?:library|require)\s*\(\s*['\"]?([a-zA-Z0-9.]+)['\"]?\s*\)`, "g");
        
        foreach (match; matchAll(content, libraryRegex))
        {
            RPackageDep dep;
            dep.name = match[1];
            dep.repository = RRepository.CRAN;
            deps ~= dep;
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("error_scanning_file_").field("detail", "Error scanning file " ~ filePath ~ ": " ~ e.msg).emit();
    }
    
    return deps;
}

/// Find R package root (directory containing DESCRIPTION)
string findPackageRoot(string startDir)
{
    string dir = startDir;
    
    while (dir != "/" && dir.length > 1)
    {
        string descPath = buildPath(dir, "DESCRIPTION");
        if (exists(descPath) && isFile(descPath))
        {
            return dir;
        }
        
        dir = dirName(dir);
    }
    
    return "";
}

/// Check if directory is an R package
bool isRPackage(string dir)
{
    string descPath = buildPath(dir, "DESCRIPTION");
    return exists(descPath) && isFile(descPath);
}

/// Check if directory uses renv
bool usesRenv(string dir)
{
    string renvLock = buildPath(dir, "renv.lock");
    string renvDir = buildPath(dir, "renv");
    return exists(renvLock) || (exists(renvDir) && isDir(renvDir));
}

/// Check if directory uses packrat
bool usesPackrat(string dir)
{
    string packratDir = buildPath(dir, "packrat");
    return exists(packratDir) && isDir(packratDir);
}

/// Get minimum R version from DESCRIPTION
string getMinimumRVersion(string descPath)
{
    if (!exists(descPath))
        return "";
    
    try
    {
        string content = readText(descPath);
        
        // Look for "Depends: R (>= x.y.z)"
        auto rVersionRegex = regex(`Depends:.*\bR\s*\(>=?\s*([\d.]+)\)`, "m");
        auto match = matchFirst(content, rVersionRegex);
        
        if (!match.empty)
        {
            return match[1];
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("error_parsing_r_version_from_description").field("detail", "Error parsing R version from DESCRIPTION: " ~ e.msg).emit();
    }
    
    return "";
}

/// Get package version from DESCRIPTION
string getPackageVersion(string descPath)
{
    if (!exists(descPath))
        return "";
    
    try
    {
        string content = readText(descPath);
        
        // Look for "Version: x.y.z"
        auto versionRegex = regex(`Version:\s*([\d.]+)`, "m");
        auto match = matchFirst(content, versionRegex);
        
        if (!match.empty)
        {
            return match[1];
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("error_parsing_package_version_from_descr").field("detail", "Error parsing package version from DESCRIPTION: " ~ e.msg).emit();
    }
    
    return "";
}

/// Get package name from DESCRIPTION
string getPackageName(string descPath)
{
    if (!exists(descPath))
        return "";
    
    try
    {
        string content = readText(descPath);
        
        // Look for "Package: name"
        auto nameRegex = regex(`Package:\s*(\S+)`, "m");
        auto match = matchFirst(content, nameRegex);
        
        if (!match.empty)
        {
            return match[1];
        }
    }
    catch (Exception e)
    {
        structuredLog.warning("error_parsing_package_name_from_descript").field("detail", "Error parsing package name from DESCRIPTION: " ~ e.msg).emit();
    }
    
    return "";
}

/// Parse package metadata from DESCRIPTION
struct PackageMetadata
{
    string name;
    string version_;
    string title;
    string description;
    string[] authors;
    string maintainer;
    string license;
    string rVersion;
    RPackageDep[] depends;
    RPackageDep[] imports;
    RPackageDep[] suggests;
    RPackageDep[] linkingTo;
}

/// Get full package metadata from DESCRIPTION
PackageMetadata getPackageMetadata(string descPath)
{
    PackageMetadata metadata;
    
    if (!exists(descPath))
    {
        return metadata;
    }
    
    try
    {
        string content = readText(descPath);
        
        // Parse basic fields
        metadata.name = getPackageName(descPath);
        metadata.version_ = getPackageVersion(descPath);
        metadata.rVersion = getMinimumRVersion(descPath);
        
        // Parse title
        auto titleMatch = matchFirst(content, regex(`Title:\s*([^\n]+)`, "m"));
        if (!titleMatch.empty)
            metadata.title = titleMatch[1].strip();
        
        // Parse description (can be multi-line)
        auto descMatch = matchFirst(content, regex(`Description:\s*([^\n]*(?:\n\s+[^\n]+)*)`, "m"));
        if (!descMatch.empty)
        {
            metadata.description = descMatch[1].replaceAll(regex(`\s+`), " ").strip();
        }
        
        // Parse license
        auto licenseMatch = matchFirst(content, regex(`License:\s*([^\n]+)`, "m"));
        if (!licenseMatch.empty)
            metadata.license = licenseMatch[1].strip();
        
        // Parse maintainer
        auto maintainerMatch = matchFirst(content, regex(`Maintainer:\s*([^\n]+)`, "m"));
        if (!maintainerMatch.empty)
            metadata.maintainer = maintainerMatch[1].strip();
        
        // Parse dependencies
        metadata.depends = parseDependencySection(content, "Depends", RRepository.CRAN);
        metadata.imports = parseDependencySection(content, "Imports", RRepository.CRAN);
        metadata.suggests = parseDependencySection(content, "Suggests", RRepository.CRAN);
        metadata.linkingTo = parseDependencySection(content, "LinkingTo", RRepository.CRAN);
        
        structuredLog.debug_("parsed_package_metadata_").field("detail", "Parsed package metadata: " ~ metadata.name ~ " " ~ metadata.version_).emit();
    }
    catch (Exception e)
    {
        structuredLog.error("failed_to_parse_description_metadata_").field("detail", "Failed to parse DESCRIPTION metadata: " ~ e.msg).emit();
    }
    
    return metadata;
}

/// Generate DESCRIPTION file from package config
void generateDESCRIPTION(string outputPath, const ref RPackageConfig config)
{
    string desc = "Package: " ~ config.name ~ "\n";
    desc ~= "Type: Package\n";
    desc ~= "Title: " ~ (config.title.empty ? config.name : config.title) ~ "\n";
    desc ~= "Version: " ~ config.version_ ~ "\n";
    
    if (!config.authors.empty)
        desc ~= "Authors@R: " ~ config.authors.join(", ") ~ "\n";
    
    if (!config.maintainer.empty)
        desc ~= "Maintainer: " ~ config.maintainer ~ "\n";
    
    if (!config.description.empty)
        desc ~= "Description: " ~ config.description ~ "\n";
    
    desc ~= "License: " ~ config.license ~ "\n";
    desc ~= "Encoding: UTF-8\n";
    
    if (config.lazyData)
        desc ~= "LazyData: true\n";
    
    if (config.roxygen2Markdown)
        desc ~= "Roxygen: list(markdown = TRUE)\n";
    
    desc ~= "Depends: R (>= " ~ config.rVersion ~ ")";
    
    // Add package dependencies
    if (!config.depends.empty)
    {
        desc ~= formatDependencyList("Depends", config.depends, config.rVersion);
    }
    
    if (!config.imports.empty)
    {
        desc ~= formatDependencyList("Imports", config.imports);
    }
    
    if (!config.suggests.empty)
    {
        desc ~= formatDependencyList("Suggests", config.suggests);
    }
    
    if (!config.linkingTo.empty)
    {
        desc ~= formatDependencyList("LinkingTo", config.linkingTo);
    }
    
    std.file.write(outputPath, desc);
    structuredLog.info("generated_description_file_at_").field("detail", "Generated DESCRIPTION file at: " ~ outputPath).emit();
}

/// Format dependency list for DESCRIPTION file
private string formatDependencyList(string sectionName, const RPackageDep[] deps, string rVersion = "")
{
    string result = "\n" ~ sectionName ~ ":\n";
    
    // Add R version if this is Depends section
    if (sectionName == "Depends" && !rVersion.empty)
    {
        result ~= "    R (>= " ~ rVersion ~ ")";
        if (!deps.empty)
            result ~= ",\n";
    }
    
    foreach (i, dep; deps)
    {
        result ~= "    " ~ dep.name;
        if (!dep.version_.empty)
            result ~= " (" ~ dep.version_ ~ ")";
        if (i < deps.length - 1)
            result ~= ",";
        result ~= "\n";
    }
    
    return result;
}

