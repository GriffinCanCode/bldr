module infrastructure.analysis.semver.source;

import std.algorithm : map, filter, sort;
import std.array : array;
import infrastructure.analysis.semver.version_;
import infrastructure.analysis.semver.constraint;
import infrastructure.errors;

/// Dependency requirement
struct DependencyReq
{
    PackageId pkg;
    VersionConstraint constraint;
}

/// Package source interface - abstracts over different registries
/// Implement this for npm, cargo, pip, etc.
interface IPackageSource
{
    /// Get available versions for a package (sorted descending)
    BuildResult!(SemVer[]) versions(PackageId pkg) @system;
    
    /// Get dependencies for a specific package version
    BuildResult!(DependencyReq[]) dependencies(PackageVersion pkg) @system;
    
    /// Check if package exists
    bool exists(PackageId pkg) @system;
    
    /// Source identifier (e.g., "npm", "cargo", "pypi")
    string name() const pure nothrow @safe;
}

/// Composite source - combines multiple package sources
/// Enables cross-language dependency resolution
final class CompositeSource : IPackageSource
{
    private IPackageSource[string] sources;
    
    /// Add a source for a specific ecosystem
    void addSource(string ecosystem, IPackageSource source) @safe
    {
        sources[ecosystem] = source;
    }
    
    override BuildResult!(SemVer[]) versions(PackageId pkg) @system
    {
        if (pkg.source.length == 0)
            return Err!(SemVer[], BuildError)(
                new AnalysisError("", "Package source not specified: " ~ pkg.name, Analysis.PackageNotFound));
        
        if (auto src = pkg.source in sources)
            return (*src).versions(pkg);
        
        return Err!(SemVer[], BuildError)(
            new AnalysisError("", "Unknown package source: " ~ pkg.source, Analysis.PackageNotFound));
    }
    
    override BuildResult!(DependencyReq[]) dependencies(PackageVersion pkg) @system
    {
        if (pkg.pkg.source.length == 0)
            return Err!(DependencyReq[], BuildError)(
                new AnalysisError("", "Package source not specified", Analysis.PackageNotFound));
        
        if (auto src = pkg.pkg.source in sources)
            return (*src).dependencies(pkg);
        
        return Err!(DependencyReq[], BuildError)(
            new AnalysisError("", "Unknown package source: " ~ pkg.pkg.source, Analysis.PackageNotFound));
    }
    
    override bool exists(PackageId pkg) @system
    {
        if (pkg.source.length == 0) return false;
        if (auto src = pkg.source in sources)
            return (*src).exists(pkg);
        return false;
    }
    
    override string name() const pure nothrow @safe => "composite";
}

/// In-memory package source for testing
final class MemorySource : IPackageSource
{
    private SemVer[][string] _versions;
    private DependencyReq[][string] _deps;
    private string _name;
    
    this(string name = "memory") @safe
    {
        _name = name;
    }
    
    /// Add a package version
    void addVersion(string pkgName, string ver, DependencyReq[] deps = []) @system
    {
        auto v = SemVer.parse(ver).unwrap();
        
        if (pkgName !in _versions)
            _versions[pkgName] = [];
        _versions[pkgName] ~= v;
        
        // Sort descending (newest first)
        _versions[pkgName].sort!((a, b) => a > b);
        
        // Store dependencies
        _deps[pkgName ~ "@" ~ ver] = deps;
    }
    
    override BuildResult!(SemVer[]) versions(PackageId pkg) @system
    {
        if (auto vers = pkg.name in _versions)
            return Ok!(SemVer[], BuildError)(*vers);
        return Ok!(SemVer[], BuildError)([]);
    }
    
    override BuildResult!(DependencyReq[]) dependencies(PackageVersion pkg) @system
    {
        auto key = pkg.pkg.name ~ "@" ~ pkg.ver.toString();
        if (auto deps = key in _deps)
            return Ok!(DependencyReq[], BuildError)(*deps);
        return Ok!(DependencyReq[], BuildError)([]);
    }
    
    override bool exists(PackageId pkg) @system
        => (pkg.name in _versions) !is null;
    
    override string name() const pure nothrow @safe => _name;
}

/// Cached wrapper around any package source
final class CachedSource : IPackageSource
{
    private IPackageSource inner;
    private SemVer[][PackageId] versionCache;
    private DependencyReq[][PackageVersion] depCache;
    
    this(IPackageSource inner) @safe
    {
        this.inner = inner;
    }
    
    override BuildResult!(SemVer[]) versions(PackageId pkg) @system
    {
        if (auto cached = pkg in versionCache)
            return Ok!(SemVer[], BuildError)(*cached);
        
        auto result = inner.versions(pkg);
        if (result.isOk)
            versionCache[pkg] = result.unwrap();
        return result;
    }
    
    override BuildResult!(DependencyReq[]) dependencies(PackageVersion pkg) @system
    {
        if (auto cached = pkg in depCache)
            return Ok!(DependencyReq[], BuildError)(*cached);
        
        auto result = inner.dependencies(pkg);
        if (result.isOk)
            depCache[pkg] = result.unwrap();
        return result;
    }
    
    override bool exists(PackageId pkg) @system
        => inner.exists(pkg);
    
    override string name() const pure nothrow @safe => inner.name();
    
    /// Clear cache
    void clear() pure nothrow @safe
    {
        versionCache.clear();
        depCache.clear();
    }
}

/// Adapter to create package source from manifest parser
/// Bridges existing manifest parsers to the solver
final class ManifestSource : IPackageSource
{
    import infrastructure.analysis.manifests.types : ManifestInfo, Dependency;
    
    private ManifestInfo delegate(string) @system loader;
    private string _name;
    private string rootPath;
    
    this(string name, string rootPath, ManifestInfo delegate(string) @system loader) @system
    {
        _name = name;
        this.rootPath = rootPath;
        this.loader = loader;
    }
    
    override BuildResult!(SemVer[]) versions(PackageId pkg) @system
    {
        // For local packages, only current version available
        // For external packages, would need registry lookup
        try
        {
            auto manifest = loader(pkg.name);
            auto ver = SemVer.parse(manifest.version_);
            if (ver.isErr)
                return Ok!(SemVer[], BuildError)([SemVer(0, 1, 0)]);
            return Ok!(SemVer[], BuildError)([ver.unwrap()]);
        }
        catch (Exception)
        {
            return Ok!(SemVer[], BuildError)([]);
        }
    }
    
    override BuildResult!(DependencyReq[]) dependencies(PackageVersion pkg) @system
    {
        try
        {
            auto manifest = loader(pkg.pkg.name);
            DependencyReq[] deps;
            
            foreach (ref dep; manifest.dependencies)
            {
                auto constraint = VersionConstraint.parse(dep.version_);
                if (constraint.isOk)
                    deps ~= DependencyReq(PackageId(dep.name, _name), constraint.unwrap());
            }
            
            return Ok!(DependencyReq[], BuildError)(deps);
        }
        catch (Exception e)
        {
            return Err!(DependencyReq[], BuildError)(
                new AnalysisError("", "Failed to load manifest: " ~ e.msg, Analysis.Failed));
        }
    }
    
    override bool exists(PackageId pkg) @system
    {
        try
        {
            loader(pkg.name);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    override string name() const pure nothrow @safe => _name;
}

/// Factory for creating ecosystem-specific sources
struct SourceFactory
{
    /// Create source for npm packages
    static IPackageSource npm(string projectPath) @system
    {
        import infrastructure.analysis.manifests.npm : NpmManifestParser;
        import std.path : buildPath;
        
        auto parser = new NpmManifestParser();
        
        return new ManifestSource("npm", projectPath, (string name) @system {
            auto result = parser.parse(buildPath(projectPath, "node_modules", name, "package.json"));
            if (result.isErr)
                throw new Exception(result.unwrapErr().message());
            return result.unwrap();
        });
    }
    
    /// Create source for cargo packages
    static IPackageSource cargo(string projectPath) @system
    {
        import infrastructure.analysis.manifests.cargo : CargoManifestParser;
        import std.path : buildPath;
        
        auto parser = new CargoManifestParser();
        
        return new ManifestSource("cargo", projectPath, (string name) @system {
            // Cargo uses registry, not local node_modules style
            auto result = parser.parse(buildPath(projectPath, "Cargo.toml"));
            if (result.isErr)
                throw new Exception(result.unwrapErr().message());
            return result.unwrap();
        });
    }
    
    /// Create source for pip packages
    static IPackageSource pip(string projectPath) @system
    {
        import infrastructure.analysis.manifests.python : PythonManifestParser;
        import std.path : buildPath;
        
        auto parser = new PythonManifestParser();
        
        return new ManifestSource("pip", projectPath, (string name) @system {
            auto result = parser.parse(buildPath(projectPath, "pyproject.toml"));
            if (result.isErr)
                throw new Exception(result.unwrapErr().message());
            return result.unwrap();
        });
    }
    
    /// Create composite source with all ecosystems
    static CompositeSource all(string projectPath) @system
    {
        auto composite = new CompositeSource();
        composite.addSource("npm", npm(projectPath));
        composite.addSource("cargo", cargo(projectPath));
        composite.addSource("pip", pip(projectPath));
        return composite;
    }
}

unittest
{
    // Test memory source
    auto src = new MemorySource("test");
    src.addVersion("foo", "1.0.0");
    src.addVersion("foo", "1.1.0");
    src.addVersion("foo", "2.0.0");
    
    auto vers = src.versions(PackageId("foo", "test")).unwrap();
    assert(vers.length == 3);
    assert(vers[0] == SemVer.parse("2.0.0").unwrap());  // Newest first
    
    // Test with dependencies
    src.addVersion("bar", "1.0.0", [
        DependencyReq(PackageId("foo", "test"), VersionConstraint.parse("^1.0.0").unwrap())
    ]);
    
    auto deps = src.dependencies(PackageVersion(PackageId("bar", "test"), SemVer.parse("1.0.0").unwrap())).unwrap();
    assert(deps.length == 1);
    assert(deps[0].pkg.name == "foo");
}

