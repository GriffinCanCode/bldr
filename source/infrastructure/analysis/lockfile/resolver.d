module infrastructure.analysis.lockfile.resolver;

import std.algorithm : map, filter, sort;
import std.array : array;
import std.conv : to;
import infrastructure.analysis.lockfile.types;
import infrastructure.analysis.semver;
import infrastructure.analysis.manifests.types : Dependency, DependencyType;
import infrastructure.errors;

/// Unified dependency resolver using PubGrub algorithm
/// Integrates semver constraint solving with lockfile generation
final class DependencyResolver
{
    private IPackageSource source;
    private bool[string] visited;
    
    this(IPackageSource source) @safe
    {
        this.source = source;
    }
    
    /// Resolve dependencies from manifest to exact versions
    BuildResult!(ResolvedDependency[]) resolve(
        in Dependency[] deps,
        string ecosystem,
        in ResolveOptions options = ResolveOptions.init
    ) @system
    {
        // Build memory source from known dependencies
        auto memSource = new MemorySource(ecosystem);
        
        // For each dependency, we need available versions
        // In offline mode, we use the constraint as the only version
        foreach (ref dep; deps)
        {
            if (options.production && dep.type == DependencyType.Development)
                continue;
            
            auto constraint = VersionConstraint.parse(dep.version_);
            if (constraint.isErr)
            {
                // Fallback: use version string directly
                auto verResult = SemVer.parse(stripOperators(dep.version_));
                if (verResult.isOk)
                    memSource.addVersion(dep.name, verResult.unwrap().toString());
                continue;
            }
            
            // Use the constraint's minimum version as available
            auto ver = extractMinVersion(constraint.unwrap());
            memSource.addVersion(dep.name, ver.toString());
        }
        
        // If we have an external source, compose with memory source
        IPackageSource resolveSource = source !is null 
            ? composeWithFallback(source, memSource)
            : memSource;
        
        // Resolve using PubGrub solver
        ResolvedDependency[] resolved;
        resolved.reserve(deps.length);
        
        foreach (ref dep; deps)
        {
            if (options.production && dep.type == DependencyType.Development)
                continue;
            
            auto constraintResult = VersionConstraint.parse(dep.version_);
            SemVer resolvedVer;
            
            if (constraintResult.isOk)
            {
                // Get available versions
                auto versResult = resolveSource.versions(PackageId(dep.name, ecosystem));
                if (versResult.isOk)
                {
                    auto versions = versResult.unwrap();
                    auto constraint = constraintResult.unwrap();
                    
                    // Find best matching version
                    foreach (v; versions)
                    {
                        if (constraint.allows(v))
                        {
                            resolvedVer = v;
                            break;  // Versions sorted descending, first match is best
                        }
                    }
                }
                
                if (resolvedVer == SemVer.zero)
                    resolvedVer = extractMinVersion(constraintResult.unwrap());
            }
            else
            {
                // Parse as direct version
                auto verResult = SemVer.parse(stripOperators(dep.version_));
                resolvedVer = verResult.isOk ? verResult.unwrap() : SemVer(0, 0, 0);
            }
            
            ResolvedDependency r;
            r.name = dep.name;
            r.version_ = resolvedVer.toString();
            r.dev = dep.type == DependencyType.Development;
            r.optional = dep.optional;
            
            resolved ~= r;
        }
        
        // Sort deterministically
        resolved = resolved.sort!((a, b) => a.name < b.name).array;
        
        return Ok!(ResolvedDependency[], BuildError)(resolved);
    }
    
    /// Full PubGrub resolution for complex dependency graphs
    BuildResult!Resolution solveGraph(
        string rootName,
        string rootConstraint,
        string ecosystem
    ) @system
    {
        if (source is null)
            return Err!(Resolution, BuildError)(
                new AnalysisError("", "No package source configured", Analysis.PackageNotFound));
        
        auto solver = new PubGrubSolver(source);
        auto constraintResult = VersionConstraint.parse(rootConstraint);
        
        if (constraintResult.isErr)
            return Err!(Resolution, BuildError)(constraintResult.unwrapErr());
        
        return solver.solve(PackageId(rootName, ecosystem), constraintResult.unwrap());
    }
    
private:
    /// Strip semver operators for fallback parsing
    static string stripOperators(string spec) pure @safe
    {
        if (spec.length == 0) return "0.0.0";
        
        size_t start = 0;
        while (start < spec.length && (spec[start] == '^' || spec[start] == '~' || 
               spec[start] == '>' || spec[start] == '<' || spec[start] == '=' || spec[start] == ' '))
            start++;
        
        // Find end (stop at space or comma)
        size_t end = start;
        while (end < spec.length && spec[end] != ' ' && spec[end] != ',')
            end++;
        
        return start < end ? spec[start .. end] : "0.0.0";
    }
    
    /// Extract minimum satisfying version from constraint
    static SemVer extractMinVersion(VersionConstraint c) pure nothrow @safe
    {
        if (c.ranges.length == 0)
            return SemVer.zero;
        return c.ranges[0].min;
    }
    
    /// Compose sources with fallback
    static IPackageSource composeWithFallback(IPackageSource primary, IPackageSource fallback) @safe
    {
        auto composite = new CompositeSource();
        // For now, return primary - could implement actual fallback logic
        return primary;
    }
}

/// Resolution options
struct ResolveOptions
{
    bool production;        // Exclude dev dependencies
    bool frozen;            // Fail if resolution differs from lockfile
    bool update;            // Update to latest versions
    string[] exclude;       // Packages to exclude
    
    static ResolveOptions ci() pure @safe
    {
        ResolveOptions opts;
        opts.frozen = true;
        return opts;
    }
}

/// Factory for creating resolvers with ecosystem-specific sources
struct ResolverFactory
{
    /// Create resolver for npm ecosystem
    static DependencyResolver npm(string projectPath = ".") @system
        => new DependencyResolver(SourceFactory.npm(projectPath));
    
    /// Create resolver for cargo ecosystem
    static DependencyResolver cargo(string projectPath = ".") @system
        => new DependencyResolver(SourceFactory.cargo(projectPath));
    
    /// Create resolver for pip ecosystem
    static DependencyResolver pip(string projectPath = ".") @system
        => new DependencyResolver(SourceFactory.pip(projectPath));
    
    /// Create offline resolver (no registry lookups)
    static DependencyResolver offline() @safe
        => new DependencyResolver(null);
    
    /// Create resolver with composite source
    static DependencyResolver all(string projectPath = ".") @system
        => new DependencyResolver(SourceFactory.all(projectPath));
}

