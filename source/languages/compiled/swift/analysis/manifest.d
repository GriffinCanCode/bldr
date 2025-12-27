module languages.compiled.swift.analysis.manifest;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import languages.compiled.swift.config;
import infrastructure.utils.logging;

/// Package manifest parse result
struct PackageManifestParseResult
{
    bool isValid;
    PackageManifest manifest;
    string error;
}

/// Package.swift manifest parser
class PackageManifestParser
{
    /// Find Package.swift in source tree
    static string findManifest(string[] sources)
    {
        if (sources.empty)
            return "";
        
        string startDir = dirName(sources[0]);
        
        // Search upward for Package.swift
        string currentDir = startDir;
        while (currentDir != "/" && currentDir.length > 1)
        {
            string manifestPath = buildPath(currentDir, "Package.swift");
            if (exists(manifestPath) && isFile(manifestPath))
                return manifestPath;
            
            currentDir = dirName(currentDir);
        }
        
        return "";
    }
    
    /// Parse Package.swift manifest
    static PackageManifestParseResult parse(string manifestPath)
    {
        PackageManifestParseResult result;
        
        if (!exists(manifestPath) || !isFile(manifestPath))
        {
            result.error = "Manifest file not found: " ~ manifestPath;
            return result;
        }
        
        try
        {
            auto content = readText(manifestPath);
            
            result.manifest.manifestPath = manifestPath;
            
            // Extract tools version
            auto toolsMatch = content.matchFirst(regex(`//\s*swift-tools-version:\s*([\d.]+)`));
            if (!toolsMatch.empty)
                result.manifest.toolsVersion = toolsMatch[1];
            
            // Extract package name
            auto nameMatch = content.matchFirst(regex(`name:\s*"([^"]+)"`));
            if (!nameMatch.empty)
                result.manifest.name = nameMatch[1];
            
            // Extract platforms
            auto platformsMatch = content.matchFirst(regex(`platforms:\s*\[(.*?)\]`, "s"));
            if (!platformsMatch.empty)
            {
                string platformsStr = platformsMatch[1];
                auto platformMatches = platformsStr.matchAll(regex(`\.(\w+)\(`));
                foreach (match; platformMatches)
                {
                    result.manifest.platforms ~= match[1];
                }
            }
            
            // Extract products
            auto productsMatch = content.matchFirst(regex(`products:\s*\[(.*?)\]`, "s"));
            if (!productsMatch.empty)
            {
                string productsStr = productsMatch[1];
                auto productMatches = productsStr.matchAll(regex(`\.(?:executable|library)\(name:\s*"([^"]+)"`));
                foreach (match; productMatches)
                {
                    result.manifest.products ~= match[1];
                }
            }
            
            // Extract dependencies
            auto depsMatch = content.matchFirst(regex(`dependencies:\s*\[(.*?)\]`, "s"));
            if (!depsMatch.empty)
            {
                string depsStr = depsMatch[1];
                
                // Parse .package directives
                auto urlMatches = depsStr.matchAll(regex(`\.package\(url:\s*"([^"]+)"`));
                foreach (match; urlMatches)
                {
                    Dependency dep;
                    dep.url = match[1];
                    
                    // Extract name from URL
                    auto urlParts = dep.url.split("/");
                    if (!urlParts.empty)
                    {
                        dep.name = urlParts[$ - 1];
                        if (dep.name.endsWith(".git"))
                            dep.name = dep.name[0 .. $ - 4];
                    }
                    
                    result.manifest.dependencies ~= dep;
                }
            }
            
            // Extract targets
            auto targetsMatch = content.matchFirst(regex(`targets:\s*\[(.*?)\]`, "s"));
            if (!targetsMatch.empty)
            {
                string targetsStr = targetsMatch[1];
                auto targetMatches = targetsStr.matchAll(regex(`\.(?:target|executableTarget|testTarget)\(name:\s*"([^"]+)"`));
                foreach (match; targetMatches)
                {
                    result.manifest.targets ~= match[1];
                }
            }
            
            // Extract Swift language versions
            auto langVersionMatch = content.matchFirst(regex(`swiftLanguageVersions:\s*\[(.*?)\]`));
            if (!langVersionMatch.empty)
            {
                string versionsStr = langVersionMatch[1];
                auto versionMatches = versionsStr.matchAll(regex(`\.v([\d_]+)`));
                foreach (match; versionMatches)
                {
                    result.manifest.swiftLanguageVersions ~= match[1].replace("_", ".");
                }
            }
            
            // Extract C language standard
            auto cStdMatch = content.matchFirst(regex(`cLanguageStandard:\s*\.(\w+)`));
            if (!cStdMatch.empty)
                result.manifest.cLanguageStandard = cStdMatch[1];
            
            // Extract C++ language standard
            auto cxxStdMatch = content.matchFirst(regex(`cxxLanguageStandard:\s*\.(\w+)`));
            if (!cxxStdMatch.empty)
                result.manifest.cxxLanguageStandard = cxxStdMatch[1];
            
            result.isValid = !result.manifest.name.empty;
        }
        catch (Exception e)
        {
            result.error = "Failed to parse manifest: " ~ e.msg;
            structuredLog.warning("log_event").field("message", result.error).emit();
        }
        
        return result;
    }
    
    /// Get package dependencies from manifest
    static Dependency[] getDependencies(string manifestPath)
    {
        auto parseResult = parse(manifestPath);
        if (parseResult.isValid)
            return parseResult.manifest.dependencies;
        return [];
    }
    
    /// Get package products from manifest
    static string[] getProducts(string manifestPath)
    {
        auto parseResult = parse(manifestPath);
        if (parseResult.isValid)
            return parseResult.manifest.products;
        return [];
    }
    
    /// Get package targets from manifest
    static string[] getTargets(string manifestPath)
    {
        auto parseResult = parse(manifestPath);
        if (parseResult.isValid)
            return parseResult.manifest.targets;
        return [];
    }
    
    /// Check if manifest specifies a particular platform
    static bool supportsPlatform(string manifestPath, string platform)
    {
        auto parseResult = parse(manifestPath);
        if (parseResult.isValid)
        {
            return parseResult.manifest.platforms.canFind(platform.toLower);
        }
        return false;
    }
}

/// Package.resolved parser (dependency lock file)
class PackageResolvedParser
{
    /// Package resolved entry
    struct ResolvedPackage
    {
        string name;
        string url;
        string version_;
        string revision;
    }
    
    /// Parse Package.resolved file
    static ResolvedPackage[] parse(string resolvedPath)
    {
        ResolvedPackage[] packages;
        
        if (!exists(resolvedPath) || !isFile(resolvedPath))
            return packages;
        
        try
        {
            import std.json;
            
            auto content = readText(resolvedPath);
            auto json = parseJSON(content);
            
            // Version 2 format (Swift 5.6+)
            if (auto pins = "pins" in json)
            {
                foreach (ref pin; pins.array)
                {
                    ResolvedPackage pkg;
                    
                    if (auto identity = "identity" in pin)
                        pkg.name = identity.str;
                    
                    if (auto location = "location" in pin)
                        pkg.url = location.str;
                    
                    if (auto state = "state" in pin)
                    {
                        if (auto version_ = "version" in *state)
                            pkg.version_ = version_.str;
                        if (auto revision = "revision" in *state)
                            pkg.revision = revision.str;
                    }
                    
                    packages ~= pkg;
                }
            }
            // Version 1 format (older Swift versions)
            else if (auto object = "object" in json)
            {
                if (auto pins = "pins" in *object)
                {
                    foreach (ref pin; pins.array)
                    {
                        ResolvedPackage pkg;
                        
                        if (auto package_ = "package" in pin)
                            pkg.name = package_.str;
                        
                        if (auto repositoryURL = "repositoryURL" in pin)
                            pkg.url = repositoryURL.str;
                        
                        if (auto state = "state" in pin)
                        {
                            if (auto version_ = "version" in *state)
                                pkg.version_ = version_.str;
                            if (auto revision = "revision" in *state)
                                pkg.revision = revision.str;
                        }
                        
                        packages ~= pkg;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_packageresolved_").field("detail", "Failed to parse Package.resolved: " ~ e.msg).emit();
        }
        
        return packages;
    }
    
    /// Find Package.resolved file
    static string findResolved(string packagePath)
    {
        // Try common locations
        string[] candidates = [
            buildPath(packagePath, "Package.resolved"),
            buildPath(packagePath, ".build", "Package.resolved"),
        ];
        
        foreach (candidate; candidates)
        {
            if (exists(candidate) && isFile(candidate))
                return candidate;
        }
        
        return "";
    }
}

