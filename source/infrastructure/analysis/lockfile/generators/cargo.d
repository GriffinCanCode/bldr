module infrastructure.analysis.lockfile.generators.cargo;

import std.string : strip, startsWith, endsWith, split, indexOf;
import std.array : array, appender;
import std.algorithm : map, filter, sort, canFind;
import std.path : buildPath, dirName;
import std.file : exists, readText, write;
import std.conv : to;
import std.datetime : Clock;
import infrastructure.analysis.lockfile.types;
import infrastructure.analysis.lockfile.cache;
import infrastructure.analysis.lockfile.resolver;
import infrastructure.analysis.manifests.cargo : CargoManifestParser;
import infrastructure.analysis.manifests.types : Dependency, DependencyType;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.logging;
import infrastructure.errors;
import infrastructure.utils.simd.strings : SIMDStrings;

/// Cargo.lock generator for Rust projects
/// Generates deterministic lockfiles from Cargo.toml
final class CargoLockfileGenerator : ILockfileGenerator
{
    private LockfileCache cache;
    private DependencyResolver resolver;
    
    this(LockfileCache cache = null) @system
    {
        this.cache = cache;
        this.resolver = ResolverFactory.offline();
    }
    
    /// Set custom resolver
    void setResolver(DependencyResolver resolver) @safe
    {
        this.resolver = resolver;
    }
    
    override BuildResult!Lockfile generate(string manifestPath, GenerateOptions options) @system
    {
        if (!exists(manifestPath))
            return Err!(Lockfile, BuildError)(
                Errors.io(manifestPath, "Cargo.toml not found").build());
        
        immutable manifestHash = LockfileCache.hashManifest(manifestPath);
        
        // Check cache
        if (cache !is null && !options.update)
        {
            auto cached = cache.get(manifestHash);
            if (cached.isOk)
            {
                structuredLog.debug_("cargo_lockfile_cache_hit").emit();
                return cached;
            }
        }
        
        // Parse Cargo.toml
        auto parser = new CargoManifestParser();
        auto parseResult = parser.parse(manifestPath);
        
        if (parseResult.isErr)
            return Err!(Lockfile, BuildError)(parseResult.unwrapErr());
        
        auto manifest = parseResult.unwrap();
        
        // Resolve dependencies using PubGrub solver
        auto resolveOpts = ResolveOptions(
            options.production,
            options.frozen,
            options.update,
            options.exclude
        );
        auto resolveResult = resolver.resolve(manifest.dependencies, "cargo", resolveOpts);
        if (resolveResult.isErr)
            return Err!(Lockfile, BuildError)(resolveResult.unwrapErr());
        
        // Enrich with registry metadata
        auto enriched = enrichDependencies(resolveResult.unwrap());
        
        // Build lockfile
        Lockfile lockfile;
        lockfile.meta.format = "cargo";
        lockfile.meta.version_ = 3;  // Cargo.lock v3
        lockfile.meta.timestamp = Clock.currTime.stdTime;
        lockfile.meta.manifestHash = manifestHash;
        lockfile.meta.engine = "builder";
        lockfile.dependencies = enriched;
        
        // Sort deterministically
        lockfile.dependencies = lockfile.dependencies.sort!((a, b) => a.name < b.name).array;
        
        if (cache !is null)
            cache.put(manifestHash, lockfile);
        
        structuredLog.info("generated_cargolock_with_").field("detail", "Generated Cargo.lock with " ~ lockfile.count().to!string ~ " dependencies").emit();
        return Ok!(Lockfile, BuildError)(lockfile);
    }
    
    override BuildResult!Lockfile parse(string lockfilePath) @system
    {
        if (!exists(lockfilePath))
            return Err!(Lockfile, BuildError)(
                Errors.io(lockfilePath, "Cargo.lock not found").build());
        
        try
        {
            auto content = readText(lockfilePath);
            return parseCargoLock(content);
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
            auto content = generateCargoLock(lockfile);
            .write(outputPath, content);
            structuredLog.info("wrote_cargolock_").field("detail", "Wrote Cargo.lock: " ~ outputPath).emit();
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
        if (!exists(manifestPath) || !exists(lockfilePath))
            return false;
        
        // Check existing lockfile
        auto existing = buildPath(dirName(manifestPath), "Cargo.lock");
        if (!exists(existing))
            return false;
        
        auto lockResult = parse(existing);
        if (lockResult.isErr)
            return false;
        
        immutable currentHash = LockfileCache.hashManifest(manifestPath);
        return lockResult.unwrap().meta.manifestHash == currentHash;
    }
    
    override string lockfileName() const pure @safe => "Cargo.lock";
    
    override PackageManagerType type() const pure @safe => PackageManagerType.Cargo;
    
private:
    /// Enrich resolved dependencies with crates.io metadata
    ResolvedDependency[] enrichDependencies(ResolvedDependency[] deps) @system
    {
        foreach (ref dep; deps)
        {
            dep.resolved = "https://crates.io/api/v1/crates/" ~ dep.name ~ "/" ~ dep.version_ ~ "/download";
            dep.integrity = FastHash.hashStrings([dep.name, dep.version_]);
            dep.registry = "https://crates.io";
        }
        return deps;
    }
    
    BuildResult!Lockfile parseCargoLock(string content) @system
    {
        Lockfile lockfile;
        lockfile.meta.format = "cargo";
        
        // Parse TOML lockfile
        string currentSection;
        ResolvedDependency currentDep;
        bool inPackage;
        
        foreach (line; content.split("\n"))
        {
            line = line.strip;
            
            if (line.length == 0 || SIMDStrings.startsWith(line, "#"))
                continue;
            
            // Section header
            if (SIMDStrings.startsWith(line, "[") && SIMDStrings.endsWith(line, "]"))
            {
                // Save previous package
                if (inPackage && currentDep.isValid())
                    lockfile.dependencies ~= currentDep;
                
                currentSection = line[1 .. $ - 1].strip;
                inPackage = currentSection == "package";
                
                if (inPackage)
                    currentDep = ResolvedDependency.init;
                
                continue;
            }
            
            // Key-value in [[package]]
            if (inPackage)
            {
                auto eqIdx = line.indexOf("=");
                if (eqIdx < 0)
                    continue;
                
                auto key = line[0 .. eqIdx].strip;
                auto value = line[eqIdx + 1 .. $].strip;
                
                // Remove quotes
                if (SIMDStrings.startsWith(value, "\"") && SIMDStrings.endsWith(value, "\""))
                    value = value[1 .. $ - 1];
                
                switch (key)
                {
                    case "name": currentDep.name = value; break;
                    case "version": currentDep.version_ = value; break;
                    case "source": currentDep.resolved = value; break;
                    case "checksum": currentDep.integrity = value; break;
                    default: break;
                }
            }
        }
        
        // Don't forget last package
        if (inPackage && currentDep.isValid())
            lockfile.dependencies ~= currentDep;
        
        return Ok!(Lockfile, BuildError)(lockfile);
    }
    
    string generateCargoLock(const ref Lockfile lockfile) @system
    {
        auto result = appender!string;
        
        result ~= "# This file is automatically @generated by Builder.\n";
        result ~= "# It is not intended for manual editing.\n";
        result ~= "version = 3\n\n";
        
        foreach (ref dep; lockfile.dependencies)
        {
            result ~= "[[package]]\n";
            result ~= "name = \"" ~ dep.name ~ "\"\n";
            result ~= "version = \"" ~ dep.version_ ~ "\"\n";
            
            if (dep.resolved.length > 0)
                result ~= "source = \"" ~ dep.resolved ~ "\"\n";
            if (dep.integrity.length > 0)
                result ~= "checksum = \"" ~ dep.integrity ~ "\"\n";
            
            if (dep.deps.length > 0)
            {
                result ~= "dependencies = [\n";
                foreach (d; dep.deps)
                    result ~= " \"" ~ d ~ "\",\n";
                result ~= "]\n";
            }
            
            result ~= "\n";
        }
        
        return result[];
    }
}

