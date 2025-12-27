module infrastructure.analysis.lockfile.generators.maven;

import std.string : strip, format, indexOf;
import std.array : array, appender;
import std.algorithm : map, filter, sort, canFind;
import std.path : buildPath, dirName;
import std.file : exists, readText, write;
import std.conv : to;
import std.datetime : Clock;
import infrastructure.analysis.lockfile.types;
import infrastructure.analysis.lockfile.cache;
import infrastructure.analysis.manifests.maven : MavenManifestParser;
import infrastructure.analysis.manifests.types : Dependency, DependencyType;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Maven lockfile generator
/// Generates deterministic dependency-lock.json from pom.xml
final class MavenLockfileGenerator : ILockfileGenerator
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
                Errors.io(manifestPath, "pom.xml not found").build());
        
        immutable manifestHash = LockfileCache.hashManifest(manifestPath);
        
        // Check cache
        if (cache !is null && !options.update)
        {
            auto cached = cache.get(manifestHash);
            if (cached.isOk)
            {
                structuredLog.debug_("maven_lockfile_cache_hit").emit();
                return cached;
            }
        }
        
        // Parse pom.xml
        auto parser = new MavenManifestParser();
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
        lockfile.meta.format = "maven";
        lockfile.meta.version_ = 1;
        lockfile.meta.timestamp = Clock.currTime.stdTime;
        lockfile.meta.manifestHash = manifestHash;
        lockfile.meta.engine = "builder";
        lockfile.dependencies = resolveResult.unwrap();
        
        // Sort deterministically
        lockfile.dependencies = lockfile.dependencies.sort!((a, b) => a.name < b.name).array;
        
        if (cache !is null)
            cache.put(manifestHash, lockfile);
        
        structuredLog.info("generated_maven_lockfile_with_").field("detail", "Generated Maven lockfile with " ~ lockfile.count().to!string ~ " dependencies").emit();
        return Ok!(Lockfile, BuildError)(lockfile);
    }
    
    override BuildResult!Lockfile parse(string lockfilePath) @system
    {
        if (!exists(lockfilePath))
            return Err!(Lockfile, BuildError)(
                Errors.io(lockfilePath, "Lockfile not found").build());
        
        try
        {
            import std.json : parseJSON, JSONType;
            
            auto content = readText(lockfilePath);
            auto json = parseJSON(content);
            
            Lockfile lockfile;
            lockfile.meta.format = "maven";
            
            if ("version" in json)
                lockfile.meta.version_ = json["version"].integer;
            
            if ("dependencies" in json && json["dependencies"].type == JSONType.object)
            {
                foreach (string coord, data; json["dependencies"].object)
                {
                    ResolvedDependency dep;
                    dep.name = coord;
                    
                    if ("version" in data)
                        dep.version_ = data["version"].str;
                    if ("sha1" in data)
                        dep.integrity = "sha1:" ~ data["sha1"].str;
                    if ("scope" in data)
                        dep.dev = data["scope"].str == "test";
                    
                    lockfile.dependencies ~= dep;
                }
            }
            
            return Ok!(Lockfile, BuildError)(lockfile);
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
            auto content = generateMavenLock(lockfile);
            .write(outputPath, content);
            structuredLog.info("wrote_maven_lockfile_").field("detail", "Wrote Maven lockfile: " ~ outputPath).emit();
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
        
        auto existing = buildPath(dirName(manifestPath), "dependency-lock.json");
        if (!exists(existing))
            return false;
        
        auto lockResult = parse(existing);
        if (lockResult.isErr)
            return false;
        
        immutable currentHash = LockfileCache.hashManifest(manifestPath);
        return lockResult.unwrap().meta.manifestHash == currentHash;
    }
    
    override string lockfileName() const pure @safe => "dependency-lock.json";
    
    override PackageManagerType type() const pure @safe => PackageManagerType.Maven;
    
private:
    BuildResult!(ResolvedDependency[]) resolveDependencies(
        in Dependency[] deps,
        in GenerateOptions options
    ) @system
    {
        import infrastructure.analysis.manifests.types : Dependency, DependencyType;
        
        ResolvedDependency[] resolved;
        resolved.reserve(deps.length);
        
        foreach (ref dep; deps)
        {
            if (options.exclude.canFind(dep.name))
                continue;
            
            ResolvedDependency r;
            r.name = dep.name;  // groupId:artifactId
            r.version_ = dep.version_;
            r.resolved = buildMavenUrl(dep.name, dep.version_);
            r.integrity = computeMavenChecksum(dep.name, dep.version_);
            r.dev = dep.type == DependencyType.Development;
            r.optional = dep.optional;
            r.registry = "https://repo1.maven.org/maven2";
            
            resolved ~= r;
        }
        
        return Ok!(ResolvedDependency[], BuildError)(resolved);
    }
    
    string buildMavenUrl(string coord, string version_) const @safe
    {
        // coord format: groupId:artifactId
        auto colonIdx = coord.indexOf(":");
        if (colonIdx < 0)
            return "";
        
        string groupId = coord[0 .. colonIdx];
        string artifactId = coord[colonIdx + 1 .. $];
        
        import std.string : replace;
        string groupPath = groupId.replace(".", "/");
        
        return format("https://repo1.maven.org/maven2/%s/%s/%s/%s-%s.jar",
            groupPath, artifactId, version_, artifactId, version_);
    }
    
    string computeMavenChecksum(string coord, string version_) const @system
    {
        auto hash = FastHash.hashStrings([coord, version_]);
        return "sha1:" ~ hash[0 .. 40];
    }
    
    string generateMavenLock(const ref Lockfile lockfile) @system
    {
        auto result = appender!string;
        
        result ~= "{\n";
        result ~= `  "version": 1,` ~ "\n";
        result ~= `  "dependencies": {` ~ "\n";
        
        bool first = true;
        foreach (ref dep; lockfile.dependencies)
        {
            if (!first)
                result ~= ",\n";
            first = false;
            
            result ~= format(`    "%s": {` ~ "\n", dep.name);
            result ~= format(`      "version": "%s"`, dep.version_);
            
            if (dep.integrity.length > 0)
            {
                string integ = dep.integrity;
                if (integ.length > 5 && integ[0..5] == "sha1:")
                    integ = integ[5 .. $];
                result ~= format(`,` ~ "\n" ~ `      "sha1": "%s"`, integ);
            }
            
            if (dep.dev)
                result ~= `,` ~ "\n" ~ `      "scope": "test"`;
            
            result ~= "\n    }";
        }
        
        result ~= "\n  }\n}\n";
        return result[];
    }
}

