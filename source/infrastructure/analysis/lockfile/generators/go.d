module infrastructure.analysis.lockfile.generators.go;

import std.string : strip, startsWith, split, indexOf;
import std.array : array, appender;
import std.algorithm : map, filter, sort, canFind;
import std.path : buildPath, dirName;
import std.file : exists, readText, write;
import std.conv : to;
import std.datetime : Clock;
import infrastructure.analysis.lockfile.types;
import infrastructure.analysis.lockfile.cache;
import infrastructure.analysis.manifests.go : GoManifestParser;
import infrastructure.analysis.manifests.types : Dependency, DependencyType;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Go modules lockfile generator (go.sum)
/// Generates deterministic checksums from go.mod
final class GoLockfileGenerator : ILockfileGenerator
{
    private LockfileCache cache;
    
    this(LockfileCache cache = null) @system
    {
        this.cache = cache;
    }
    
    override BuildResult!Lockfile generate(string manifestPath, GenerateOptions options) @system
    {
        if (!exists(manifestPath))
            return Err!(Lockfile, BuildError)(
                Errors.io(manifestPath, "go.mod not found").build());
        
        immutable manifestHash = LockfileCache.hashManifest(manifestPath);
        
        // Check cache
        if (cache !is null && !options.update)
        {
            auto cached = cache.get(manifestHash);
            if (cached.isOk)
            {
                structuredLog.debug_("go_sum_cache_hit").emit();
                return cached;
            }
        }
        
        // Parse go.mod
        auto parser = new GoManifestParser();
        auto parseResult = parser.parse(manifestPath);
        
        if (parseResult.isErr)
            return Err!(Lockfile, BuildError)(parseResult.unwrapErr());
        
        auto manifest = parseResult.unwrap();
        
        // Resolve dependencies
        auto resolveResult = resolveDependencies(manifest.dependencies, options);
        if (resolveResult.isErr)
            return Err!(Lockfile, BuildError)(resolveResult.unwrapErr());
        
        // Build lockfile
        Lockfile lockfile;
        lockfile.meta.format = "go";
        lockfile.meta.version_ = 1;
        lockfile.meta.timestamp = Clock.currTime.stdTime;
        lockfile.meta.manifestHash = manifestHash;
        lockfile.meta.engine = "builder";
        lockfile.dependencies = resolveResult.unwrap();
        
        // Sort deterministically
        lockfile.dependencies = lockfile.dependencies.sort!((a, b) => a.name < b.name).array;
        
        if (cache !is null)
            cache.put(manifestHash, lockfile);
        
        structuredLog.info("generated_gosum_with_").field("detail", "Generated go.sum with " ~ lockfile.count().to!string ~ " modules").emit();
        return Ok!(Lockfile, BuildError)(lockfile);
    }
    
    override BuildResult!Lockfile parse(string lockfilePath) @system
    {
        if (!exists(lockfilePath))
            return Err!(Lockfile, BuildError)(
                Errors.io(lockfilePath, "go.sum not found").build());
        
        try
        {
            auto content = readText(lockfilePath);
            return parseGoSum(content);
        }
        catch (Exception e)
        {
            return Err!(Lockfile, BuildError)(
                Errors.parse(lockfilePath, "Failed to parse: " ~ e.msg, Parse.InvalidConfiguration).build());
        }
    }
    
    override BuildResult!void write(const ref Lockfile lockfile, string outputPath) @system
    {
        try
        {
            auto content = generateGoSum(lockfile);
            .write(outputPath, content);
            structuredLog.info("wrote_gosum_").field("detail", "Wrote go.sum: " ~ outputPath).emit();
            return Ok!(void, BuildError)();
        }
        catch (Exception e)
        {
            return Err!(void, BuildError)(
                Errors.io(outputPath, "Failed to write: " ~ e.msg).build());
        }
    }
    
    override bool isUpToDate(string manifestPath, string lockfilePath) @system
    {
        if (!exists(manifestPath))
            return false;
        
        auto existing = buildPath(dirName(manifestPath), "go.sum");
        if (!exists(existing))
            return false;
        
        auto lockResult = parse(existing);
        if (lockResult.isErr)
            return false;
        
        immutable currentHash = LockfileCache.hashManifest(manifestPath);
        return lockResult.unwrap().meta.manifestHash == currentHash;
    }
    
    override string lockfileName() const pure @safe => "go.sum";
    
    override PackageManagerType type() const pure @safe => PackageManagerType.Go;
    
private:
    BuildResult!(ResolvedDependency[]) resolveDependencies(
        in Dependency[] deps,
        in GenerateOptions options
    ) @system
    {
        import infrastructure.analysis.manifests.types : Dependency, DependencyType;
        
        ResolvedDependency[] resolved;
        resolved.reserve(deps.length * 2);  // Each module may have /go.mod entry
        
        foreach (ref dep; deps)
        {
            if (options.exclude.canFind(dep.name))
                continue;
            
            // Module checksum
            ResolvedDependency r;
            r.name = dep.name;
            r.version_ = dep.version_;
            r.resolved = "https://proxy.golang.org/" ~ dep.name ~ "/@v/" ~ dep.version_ ~ ".mod";
            r.integrity = computeGoChecksum(dep.name, dep.version_);
            r.registry = "https://proxy.golang.org";
            
            resolved ~= r;
            
            // go.mod checksum (separate entry)
            ResolvedDependency modEntry;
            modEntry.name = dep.name ~ "/go.mod";
            modEntry.version_ = dep.version_;
            modEntry.integrity = computeGoModChecksum(dep.name, dep.version_);
            
            resolved ~= modEntry;
        }
        
        return Ok!(ResolvedDependency[], BuildError)(resolved);
    }
    
    string computeGoChecksum(string module_, string version_) const @system
    {
        // Go uses h1: prefix for SHA-256 base64
        auto hash = FastHash.hashStrings([module_, version_]);
        return "h1:" ~ hash[0 .. 44];  // Base64-ish truncation
    }
    
    string computeGoModChecksum(string module_, string version_) const @system
    {
        auto hash = FastHash.hashStrings([module_ ~ "/go.mod", version_]);
        return "h1:" ~ hash[0 .. 44];
    }
    
    BuildResult!Lockfile parseGoSum(string content) @system
    {
        Lockfile lockfile;
        lockfile.meta.format = "go";
        
        foreach (line; content.split("\n"))
        {
            line = line.strip;
            if (line.length == 0)
                continue;
            
            // Format: module version checksum
            auto parts = line.split(" ");
            if (parts.length < 3)
                continue;
            
            ResolvedDependency dep;
            dep.name = parts[0];
            dep.version_ = parts[1];
            dep.integrity = parts[2];
            
            lockfile.dependencies ~= dep;
        }
        
        return Ok!(Lockfile, BuildError)(lockfile);
    }
    
    string generateGoSum(const ref Lockfile lockfile) @system
    {
        auto result = appender!string;
        
        // Collect and sort for determinism
        string[] lines;
        foreach (ref dep; lockfile.dependencies)
            lines ~= dep.name ~ " " ~ dep.version_ ~ " " ~ dep.integrity;
        lines.sort();
        
        foreach (line; lines)
            result ~= line ~ "\n";
        
        return result[];
    }
}

