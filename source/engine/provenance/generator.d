/**
 * Build Provenance Generator
 * 
 * Collects and generates SLSA-compliant build provenance during
 * build execution. Integrates with the build engine to capture
 * materials, outputs, and execution metadata.
 * 
 * Design:
 * - Non-intrusive: Minimal impact on build performance
 * - Streaming: Captures data incrementally
 * - Hermetic-aware: Higher fidelity in hermetic mode
 */
module engine.provenance.generator;

import std.datetime : Clock, SysTime;
import std.uuid : randomUUID;
import std.conv : to;
import std.algorithm : map, filter;
import std.array : array;
import std.file : exists;
import engine.provenance.types;
import infrastructure.utils.crypto.blake3;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;

/// Provenance generator - captures build provenance data
struct ProvenanceGenerator
{
    private ProvenanceConfig config;
    private SysTime buildStart;
    private string invocationId;
    private ResourceDescriptor[] materials;
    private ResourceDescriptor[] outputs;
    private ResourceDescriptor[] byproducts;
    private string[string] internalParams;
    private bool isHermetic;
    private string builderVersion;
    
    /// Create generator with configuration
    static ProvenanceGenerator create(ProvenanceConfig config = ProvenanceConfig.init) @system
    {
        ProvenanceGenerator gen;
        gen.config = config;
        gen.invocationId = randomUUID().toString();
        gen.builderVersion = getBuilderVersion();
        return gen;
    }
    
    /// Start tracking a build invocation
    void startBuild(bool hermetic = false) @safe
    {
        buildStart = Clock.currTime();
        isHermetic = hermetic;
        materials = [];
        outputs = [];
        byproducts = [];
        internalParams.clear();
    }
    
    /// Record input material (source file, dependency)
    void addMaterial(string path, string uri = "") @system
    {
        if (!exists(path)) return;
        
        auto hash = FastHash.hashFile(path);
        auto rd = ResourceDescriptor.fromFile(path, hash);
        
        if (uri.length > 0)
            rd.uri = uri;
        
        materials ~= rd;
    }
    
    /// Record multiple materials efficiently
    void addMaterials(scope const(string)[] paths) @system
    {
        foreach (path; paths)
            addMaterial(path);
    }
    
    /// Record output artifact
    void addOutput(string path, string name = "") @system
    {
        if (!exists(path)) return;
        
        auto hash = FastHash.hashFile(path);
        auto rd = ResourceDescriptor.fromFile(path, hash);
        
        if (name.length > 0)
            rd.name = name;
        
        outputs ~= rd;
    }
    
    /// Record byproduct (logs, intermediate files)
    void addByproduct(string path, string mediaType = "") @system
    {
        if (!config.includeByproducts || !exists(path)) return;
        
        auto hash = FastHash.hashFile(path);
        auto rd = ResourceDescriptor.fromFile(path, hash);
        rd.mediaType = mediaType;
        byproducts ~= rd;
    }
    
    /// Record internal build parameter
    void setParameter(string key, string value) @safe
    {
        internalParams[key] = value;
    }
    
    /// Record resolved dependency with digest
    void addResolvedDependency(string uri, string hash, string name = "") @system
    {
        auto rd = ResourceDescriptor.fromUri(uri, hash);
        if (name.length > 0)
            rd.name = name;
        materials ~= rd;
    }
    
    /// Finalize and generate provenance attestation
    BuildResult!BuildProvenance finalize() @system
    {
        immutable buildEnd = Clock.currTime();
        
        // Build metadata
        BuildMetadata metadata;
        metadata.invocationId = invocationId;
        metadata.startedOn = buildStart;
        metadata.finishedOn = buildEnd;
        
        // Builder identity
        auto builder = BuilderId.bldr(builderVersion);
        
        // Run details
        RunDetails runDetails;
        runDetails.builder = builder;
        runDetails.metadata = metadata;
        runDetails.byproducts = byproducts;
        
        // Build definition
        BuildDefinition buildDef;
        buildDef.buildType = config.buildType;
        buildDef.resolvedDependencies = materials;
        buildDef.internalParameters = internalParams.dup;
        
        // Determine SLSA level achieved
        auto level = determineSLSALevel();
        
        // Create provenance predicate
        ProvenancePredicate predicate;
        predicate.buildDefinition = buildDef;
        predicate.runDetails = runDetails;
        
        // Create statement
        ProvenanceStatement statement;
        statement.subject = outputs;
        statement.predicate = predicate;
        
        // Create attestation
        BuildProvenance provenance;
        provenance.statement = statement;
        provenance.level = level;
        provenance.attestationId = invocationId;
        provenance.provenanceHash = computeProvenanceHash(statement);
        
        return Ok!(BuildProvenance, BuildError)(provenance);
    }
    
    /// Determine SLSA level based on build characteristics
    private SLSALevel determineSLSALevel() const @safe pure nothrow
    {
        // L3 requires hermetic builds
        if (isHermetic && config.targetLevel >= SLSALevel.L3)
            return SLSALevel.L3;
        
        // L2 requires hosted platform (always true for bldr)
        if (config.targetLevel >= SLSALevel.L2)
            return SLSALevel.L2;
        
        // L1 if provenance exists
        return SLSALevel.L1;
    }
    
    /// Compute BLAKE3 hash of provenance statement
    private static ubyte[32] computeProvenanceHash(const ref ProvenanceStatement stmt) @system
    {
        // Serialize key fields for hashing
        string data;
        
        // Hash subjects
        foreach (ref subj; stmt.subject)
        {
            data ~= subj.uri;
            foreach (k, v; subj.digest)
                data ~= k ~ ":" ~ v;
        }
        
        // Hash build definition
        data ~= stmt.predicate.buildDefinition.buildType;
        foreach (ref dep; stmt.predicate.buildDefinition.resolvedDependencies)
        {
            data ~= dep.uri;
            foreach (k, v; dep.digest)
                data ~= k ~ ":" ~ v;
        }
        
        // Hash run details
        data ~= stmt.predicate.runDetails.builder.id;
        data ~= stmt.predicate.runDetails.metadata.invocationId;
        
        auto hash = Blake3.hashHex(cast(ubyte[]) data);
        
        ubyte[32] result;
        foreach (i; 0 .. 32)
            result[i] = cast(ubyte)(parseHexDigit(hash[i*2]) << 4 | parseHexDigit(hash[i*2+1]));
        
        return result;
    }
    
    /// Parse single hex digit
    private static ubyte parseHexDigit(char c) @safe pure nothrow @nogc
    {
        if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
        if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
        if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
        return 0;
    }
}

/// Get bldr version from build info
private string getBuilderVersion() @system nothrow
{
    try
    {
        import std.process : environment;
        if (auto ver = environment.get("BLDR_VERSION"))
            return ver;
    }
    catch (Exception) {}
    
    return "0.1.0";  // Default version
}

/// Provenance collector - thread-safe accumulator for parallel builds
final class ProvenanceCollector
{
    import core.sync.mutex : Mutex;
    
    private Mutex mutex;
    private ProvenanceGenerator generator;
    private bool active;
    
    /// Create collector with config
    this(ProvenanceConfig config = ProvenanceConfig.init) @system
    {
        mutex = new Mutex();
        generator = ProvenanceGenerator.create(config);
    }
    
    /// Begin collecting provenance
    void begin(bool hermetic = false) @system
    {
        synchronized (mutex)
        {
            generator.startBuild(hermetic);
            active = true;
        }
    }
    
    /// Record material (thread-safe)
    void recordMaterial(string path) @system
    {
        synchronized (mutex)
        {
            if (active)
                generator.addMaterial(path);
        }
    }
    
    /// Record output (thread-safe)
    void recordOutput(string path, string name = "") @system
    {
        synchronized (mutex)
        {
            if (active)
                generator.addOutput(path, name);
        }
    }
    
    /// Record parameter (thread-safe)
    void recordParameter(string key, string value) @system
    {
        synchronized (mutex)
        {
            if (active)
                generator.setParameter(key, value);
        }
    }
    
    /// Finalize and return provenance
    BuildResult!BuildProvenance complete() @system
    {
        synchronized (mutex)
        {
            active = false;
            return generator.finalize();
        }
    }
    
    /// Check if actively collecting
    bool isActive() const @system
    {
        synchronized (cast(Mutex) mutex)
            return active;
    }
}


