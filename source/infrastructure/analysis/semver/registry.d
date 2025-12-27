module infrastructure.analysis.semver.registry;

import std.algorithm : map, filter, sort;
import std.array : array;
import infrastructure.analysis.semver.version_;
import infrastructure.analysis.semver.constraint;
import infrastructure.analysis.semver.source;
import infrastructure.errors;

/// Registry connection configuration
struct RegistryConfig
{
    string url;              // Base URL
    string authToken;        // Optional auth token
    uint timeoutMs = 30_000; // Request timeout
    uint maxRetries = 3;     // Retry count
    bool offline;            // Offline mode (no network)
    
    static RegistryConfig npm() pure @safe
        => RegistryConfig("https://registry.npmjs.org");
    
    static RegistryConfig crates() pure @safe
        => RegistryConfig("https://crates.io/api/v1/crates");
    
    static RegistryConfig pypi() pure @safe
        => RegistryConfig("https://pypi.org/pypi");
}

/// Package metadata from registry
struct PackageMetadata
{
    string name;
    string description;
    string[] keywords;
    string license;
    string repository;
    string[] maintainers;
    SemVer[] versions;
    SemVer latest;
    string[string] dist;  // version -> tarball URL
}

/// Interface for registry-backed package sources
/// Extend this for npm, crates.io, PyPI, etc.
interface IRegistrySource : IPackageSource
{
    /// Get full package metadata
    BuildResult!PackageMetadata metadata(string pkgName) @system;
    
    /// Search for packages
    BuildResult!(string[]) search(string query, uint limit = 20) @system;
    
    /// Get download URL for specific version
    string downloadUrl(string pkgName, SemVer ver) @system;
    
    /// Registry configuration
    RegistryConfig config() const pure nothrow @safe;
}

/// Abstract base for HTTP-based registries
abstract class HttpRegistrySource : IRegistrySource
{
    protected RegistryConfig _config;
    protected SemVer[][string] versionCache;
    protected DependencyReq[][string] depCache;
    
    this(RegistryConfig config) @safe
    {
        _config = config;
    }
    
    override RegistryConfig config() const pure nothrow @safe => _config;
    
    override BuildResult!(SemVer[]) versions(PackageId pkg) @system
    {
        // Check cache
        if (auto cached = pkg.name in versionCache)
            return Ok!(SemVer[], BuildError)(*cached);
        
        // Offline mode
        if (_config.offline)
            return Ok!(SemVer[], BuildError)([]);
        
        // Fetch from registry
        auto result = fetchVersions(pkg.name);
        if (result.isOk)
            versionCache[pkg.name] = result.unwrap();
        
        return result;
    }
    
    override BuildResult!(DependencyReq[]) dependencies(PackageVersion pkg) @system
    {
        auto key = pkg.pkg.name ~ "@" ~ pkg.ver.toString();
        
        if (auto cached = key in depCache)
            return Ok!(DependencyReq[], BuildError)(*cached);
        
        if (_config.offline)
            return Ok!(DependencyReq[], BuildError)([]);
        
        auto result = fetchDependencies(pkg.pkg.name, pkg.ver);
        if (result.isOk)
            depCache[key] = result.unwrap();
        
        return result;
    }
    
    override bool exists(PackageId pkg) @system
    {
        auto vers = versions(pkg);
        return vers.isOk && vers.unwrap().length > 0;
    }
    
    /// Clear caches
    void clearCache() pure nothrow @safe
    {
        versionCache.clear();
        depCache.clear();
    }
    
protected:
    /// Subclasses implement actual HTTP fetching
    abstract BuildResult!(SemVer[]) fetchVersions(string pkgName) @system;
    abstract BuildResult!(DependencyReq[]) fetchDependencies(string pkgName, SemVer ver) @system;
}

/// NPM Registry source (registry.npmjs.org)
final class NpmRegistrySource : HttpRegistrySource
{
    this(RegistryConfig config = RegistryConfig.npm()) @safe
    {
        super(config);
    }
    
    override string name() const pure nothrow @safe => "npm";
    
    override BuildResult!PackageMetadata metadata(string pkgName) @system
    {
        if (_config.offline)
            return Err!(PackageMetadata, BuildError)(
                new AnalysisError("", "Offline mode enabled", Analysis.PackageNotFound));
        
        // Would fetch: GET {registry}/{pkgName}
        // Parse JSON response for versions, dist-tags, etc.
        return Err!(PackageMetadata, BuildError)(
            new AnalysisError("", "Network requests not implemented", Analysis.Failed));
    }
    
    override BuildResult!(string[]) search(string query, uint limit = 20) @system
    {
        if (_config.offline)
            return Ok!(string[], BuildError)([]);
        
        // Would fetch: GET {registry}/-/v1/search?text={query}&size={limit}
        return Err!(string[], BuildError)(
            new AnalysisError("", "Network requests not implemented", Analysis.Failed));
    }
    
    override string downloadUrl(string pkgName, SemVer ver) @system
    {
        // Format: https://registry.npmjs.org/{pkg}/-/{pkg}-{version}.tgz
        import std.string : split;
        
        if (pkgName.length > 0 && pkgName[0] == '@')
        {
            auto parts = pkgName[1 .. $].split("/");
            if (parts.length == 2)
                return _config.url ~ "/" ~ pkgName ~ "/-/" ~ parts[1] ~ "-" ~ ver.toString() ~ ".tgz";
        }
        return _config.url ~ "/" ~ pkgName ~ "/-/" ~ pkgName ~ "-" ~ ver.toString() ~ ".tgz";
    }
    
protected:
    override BuildResult!(SemVer[]) fetchVersions(string pkgName) @system
    {
        // Would parse: GET {registry}/{pkgName} -> versions object
        return Ok!(SemVer[], BuildError)([]);
    }
    
    override BuildResult!(DependencyReq[]) fetchDependencies(string pkgName, SemVer ver) @system
    {
        // Would parse: GET {registry}/{pkgName}/{version} -> dependencies
        return Ok!(DependencyReq[], BuildError)([]);
    }
}

/// Crates.io Registry source
final class CratesRegistrySource : HttpRegistrySource
{
    this(RegistryConfig config = RegistryConfig.crates()) @safe
    {
        super(config);
    }
    
    override string name() const pure nothrow @safe => "cargo";
    
    override BuildResult!PackageMetadata metadata(string pkgName) @system
    {
        if (_config.offline)
            return Err!(PackageMetadata, BuildError)(
                new AnalysisError("", "Offline mode enabled", Analysis.PackageNotFound));
        
        // Would fetch: GET {api}/crates/{pkgName}
        return Err!(PackageMetadata, BuildError)(
            new AnalysisError("", "Network requests not implemented", Analysis.Failed));
    }
    
    override BuildResult!(string[]) search(string query, uint limit = 20) @system
    {
        if (_config.offline)
            return Ok!(string[], BuildError)([]);
        
        // Would fetch: GET {api}/crates?q={query}&per_page={limit}
        return Err!(string[], BuildError)(
            new AnalysisError("", "Network requests not implemented", Analysis.Failed));
    }
    
    override string downloadUrl(string pkgName, SemVer ver) @system
        => _config.url ~ "/" ~ pkgName ~ "/" ~ ver.toString() ~ "/download";
    
protected:
    override BuildResult!(SemVer[]) fetchVersions(string pkgName) @system
    {
        // Would parse: GET {api}/crates/{pkgName}/versions
        return Ok!(SemVer[], BuildError)([]);
    }
    
    override BuildResult!(DependencyReq[]) fetchDependencies(string pkgName, SemVer ver) @system
    {
        // Would parse: GET {api}/crates/{pkgName}/{version}/dependencies
        return Ok!(DependencyReq[], BuildError)([]);
    }
}

/// PyPI Registry source
final class PyPIRegistrySource : HttpRegistrySource
{
    this(RegistryConfig config = RegistryConfig.pypi()) @safe
    {
        super(config);
    }
    
    override string name() const pure nothrow @safe => "pip";
    
    override BuildResult!PackageMetadata metadata(string pkgName) @system
    {
        if (_config.offline)
            return Err!(PackageMetadata, BuildError)(
                new AnalysisError("", "Offline mode enabled", Analysis.PackageNotFound));
        
        // Would fetch: GET {api}/{pkgName}/json
        return Err!(PackageMetadata, BuildError)(
            new AnalysisError("", "Network requests not implemented", Analysis.Failed));
    }
    
    override BuildResult!(string[]) search(string query, uint limit = 20) @system
    {
        if (_config.offline)
            return Ok!(string[], BuildError)([]);
        
        // PyPI search API is limited, would use: GET {api}/search/?q={query}
        return Err!(string[], BuildError)(
            new AnalysisError("", "Network requests not implemented", Analysis.Failed));
    }
    
    override string downloadUrl(string pkgName, SemVer ver) @system
    {
        // Format varies - would need to fetch from metadata
        return _config.url ~ "/" ~ pkgName ~ "/" ~ ver.toString();
    }
    
protected:
    override BuildResult!(SemVer[]) fetchVersions(string pkgName) @system
    {
        // Would parse: GET {api}/{pkgName}/json -> releases keys
        return Ok!(SemVer[], BuildError)([]);
    }
    
    override BuildResult!(DependencyReq[]) fetchDependencies(string pkgName, SemVer ver) @system
    {
        // PyPI doesn't expose deps directly - need to parse wheel metadata
        return Ok!(DependencyReq[], BuildError)([]);
    }
}

/// Factory for creating registry sources
struct RegistryFactory
{
    /// Create npm registry source
    static IRegistrySource npm(bool offline = false) @safe
    {
        auto config = RegistryConfig.npm();
        config.offline = offline;
        return new NpmRegistrySource(config);
    }
    
    /// Create crates.io registry source
    static IRegistrySource crates(bool offline = false) @safe
    {
        auto config = RegistryConfig.crates();
        config.offline = offline;
        return new CratesRegistrySource(config);
    }
    
    /// Create PyPI registry source
    static IRegistrySource pypi(bool offline = false) @safe
    {
        auto config = RegistryConfig.pypi();
        config.offline = offline;
        return new PyPIRegistrySource(config);
    }
    
    /// Create composite source with all registries
    static CompositeSource all(bool offline = false) @safe
    {
        auto composite = new CompositeSource();
        composite.addSource("npm", npm(offline));
        composite.addSource("cargo", crates(offline));
        composite.addSource("pip", pypi(offline));
        return composite;
    }
}

