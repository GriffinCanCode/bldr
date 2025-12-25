module infrastructure.analysis.lockfile.types;

import infrastructure.utils.serialization;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;

/// Resolved dependency with exact version and integrity hash
@Serializable(SchemaVersion(1, 0), 0x4C4B4450) // "LKDP"
struct ResolvedDependency
{
    @Field(1) string name;              // Package name
    @Field(2) string version_;          // Exact resolved version
    @Field(3) string integrity;         // Content hash (BLAKE3 or sha512)
    @Field(4) string resolved;          // Resolved URL or registry path
    @Field(5) @Optional string[] deps;  // Transitive dependency names
    @Field(6) @Optional bool dev;       // Is dev dependency
    @Field(7) @Optional bool optional;  // Is optional dependency
    @Field(8) @Optional string registry;// Registry source
    
    /// Compute deterministic hash of this dependency
    string hash() const @system => FastHash.hashStrings([name, version_, integrity, resolved]);
    
    /// Check if resolution is valid
    bool isValid() const pure @safe => name.length > 0 && version_.length > 0;
}

/// Lockfile metadata
@Serializable(SchemaVersion(1, 0))
struct LockfileMeta
{
    @Field(1) string format;           // "npm", "cargo", "go", "maven"
    @Field(2) @Packed long version_;   // Lockfile format version
    @Field(3) @Packed long timestamp;  // Generation timestamp
    @Field(4) string manifestHash;     // Hash of source manifest
    @Field(5) @Optional string engine; // Package manager used
}

/// Complete lockfile with resolved dependencies
@Serializable(SchemaVersion(1, 0), 0x424C4B46) // "BLKF" - Builder Lockfile
struct Lockfile
{
    @Field(1) LockfileMeta meta;
    @Field(2) ResolvedDependency[] dependencies;
    @Field(3) @Optional string[string] checksums;  // path -> checksum for additional files
    
    /// Compute deterministic lockfile hash (for cache key)
    string hash() const @system
    {
        import std.algorithm : map, sort;
        import std.array : array;
        
        string[] parts;
        parts ~= meta.format;
        parts ~= meta.manifestHash;
        
        // Collect hashes and sort deterministically
        string[] depHashes;
        foreach (ref dep; dependencies)
            depHashes ~= dep.name ~ ":" ~ dep.hash();
        depHashes.sort();
        parts ~= depHashes;
        
        return FastHash.hashStrings(parts);
    }
    
    /// Get dependency by name
    const(ResolvedDependency)* get(string name) const pure @trusted
    {
        foreach (i, ref dep; dependencies)
            if (dep.name == name)
                return &dependencies[i];
        return null;
    }
    
    /// Check if lockfile is empty
    bool empty() const pure @safe => dependencies.length == 0;
    
    /// Number of resolved dependencies
    size_t count() const pure @safe => dependencies.length;
}

/// Lockfile diff for incremental updates
struct LockfileDiff
{
    ResolvedDependency[] added;
    ResolvedDependency[] removed;
    ResolvedDependency[] updated;  // Version changed
    
    /// Check if there are any changes
    bool hasChanges() const pure @safe => 
        added.length > 0 || removed.length > 0 || updated.length > 0;
    
    /// Compute diff between two lockfiles
    static LockfileDiff compute(const ref Lockfile old, const ref Lockfile new_) @trusted
    {
        LockfileDiff diff;
        
        // Build lookup maps
        bool[string] oldNames, newNames;
        string[string] oldVersions;
        
        foreach (ref dep; old.dependencies)
        {
            oldNames[dep.name] = true;
            oldVersions[dep.name] = dep.version_;
        }
        
        foreach (ref dep; new_.dependencies)
            newNames[dep.name] = true;
        
        // Find added and updated
        foreach (ref dep; new_.dependencies)
        {
            ResolvedDependency copy = cast(ResolvedDependency)dep;
            if (dep.name !in oldNames)
                diff.added ~= copy;
            else if (oldVersions[dep.name] != dep.version_)
                diff.updated ~= copy;
        }
        
        // Find removed
        foreach (ref dep; old.dependencies)
            if (dep.name !in newNames)
                diff.removed ~= cast(ResolvedDependency)dep;
        
        return diff;
    }
}

/// Package manager type for unified handling
enum PackageManagerType
{
    Npm,      // npm, yarn, pnpm
    Cargo,    // Rust
    Go,       // Go modules
    Maven,    // Java/Kotlin
    Pip,      // Python
    Composer, // PHP
    Unknown
}

/// Detect package manager from manifest filename
PackageManagerType detectPackageManager(string filename) pure @safe
{
    import std.path : baseName;
    import std.string : endsWith;
    
    immutable name = baseName(filename);
    
    if (name == "package.json") return PackageManagerType.Npm;
    if (name == "Cargo.toml") return PackageManagerType.Cargo;
    if (name == "go.mod") return PackageManagerType.Go;
    if (name == "pom.xml") return PackageManagerType.Maven;
    if (name == "requirements.txt" || name == "pyproject.toml") return PackageManagerType.Pip;
    if (name == "composer.json") return PackageManagerType.Composer;
    
    return PackageManagerType.Unknown;
}

/// Lockfile generator interface
interface ILockfileGenerator
{
    /// Generate lockfile from manifest
    BuildResult!Lockfile generate(string manifestPath, GenerateOptions options = GenerateOptions.init) @system;
    
    /// Parse existing lockfile
    BuildResult!Lockfile parse(string lockfilePath) @system;
    
    /// Write lockfile to disk
    BuildResult!void write(const ref Lockfile lockfile, string outputPath) @system;
    
    /// Check if lockfile is up-to-date with manifest
    bool isUpToDate(string manifestPath, string lockfilePath) @system;
    
    /// Get the expected lockfile name for this package manager
    string lockfileName() const pure @safe;
    
    /// Package manager type
    PackageManagerType type() const pure @safe;
}

/// Generation options
struct GenerateOptions
{
    bool frozen;           // Fail if lockfile would change
    bool update;           // Update all dependencies to latest
    bool production;       // Only production dependencies
    bool includeOptional;  // Include optional dependencies
    string[] exclude;      // Packages to exclude from resolution
    
    static GenerateOptions ci() pure @safe
    {
        GenerateOptions opts;
        opts.frozen = true;
        return opts;
    }
}

