module engine.runtime.hermetic.core.spec;

import std.algorithm : canFind, map, filter;
import std.array : array;
import std.path : buildPath, absolutePath, dirName;
import std.string : startsWith;
import infrastructure.errors;

/// Hermetic sandbox specification using set theory
/// Models allowed operations as mathematical sets for provable correctness
/// 
/// Design: Input set I, Output set O, Network set N satisfy:
/// - Hermeticity: I ∩ O = ∅ (disjoint input/output)
/// - Reproducibility: Same I → Same O (deterministic)
/// - Isolation: N = ∅ for hermetic builds
/// 
/// This allows formal verification of build hermeticity
struct SandboxSpec
{
    /// Input paths (read-only) - Set I
    PathSet inputs;
    
    /// Output paths (write-only) - Set O
    PathSet outputs;
    
    /// Temporary paths (read-write) - Set T
    PathSet temps;
    
    /// Network access control - Set N
    NetworkPolicy network;
    
    /// Environment variables (whitelist) - Set E
    EnvSet environment;
    
    /// Resource limits - Set R
    ResourceLimits resources;
    
    /// Process restrictions
    ProcessPolicy process;
    
    /// Validate hermeticity constraints
    /// Ensures I ∩ O = ∅ and other invariants
    ValidationResult!bool validate() @safe const
    {
        // Check disjointness: inputs ∩ outputs = ∅
        foreach (inPath; inputs.paths)
        {
            foreach (outPath; outputs.paths)
            {
                if (pathsOverlap(inPath, outPath))
                {
                    return ValidationResult!bool.err(
                        "Hermeticity violated: input and output paths overlap: " ~ 
                        inPath ~ " and " ~ outPath);
                }
            }
        }
        
        // Validate network policy for hermetic builds
        if (network.isHermetic && (network.allowHttp || network.allowHttps))
        {
            return ValidationResult!bool.err(
                "Hermetic builds cannot allow network access");
        }
        
        // Validate temp paths don't overlap with inputs (temps can overlap outputs)
        foreach (tempPath; temps.paths)
        {
            foreach (inPath; inputs.paths)
            {
                if (pathsOverlap(tempPath, inPath))
                {
                    return ValidationResult!bool.err(
                        "Temp path overlaps with input: " ~ tempPath ~ " and " ~ inPath);
                }
            }
        }
        
        return ValidationResult!bool.ok(true);
    }
    
    /// Check if a path is allowed for reading (path ∈ I ∪ T)
    bool canRead(string path) @safe const
    {
        return inputs.contains(path) || temps.contains(path);
    }
    
    /// Check if a path is allowed for writing (path ∈ O ∪ T)
    bool canWrite(string path) @safe const
    {
        return outputs.contains(path) || temps.contains(path);
    }
    
    /// Check if network access is allowed
    bool canNetwork() @safe const pure nothrow
    {
        return !network.isHermetic;
    }
    
    /// Check if environment variable is allowed (var ∈ E)
    bool hasEnv(string key) @safe const
    {
        return environment.has(key);
    }
}

/// Path set with efficient containment checks
/// Supports prefix matching for directory hierarchies
struct PathSet
{
    string[] paths;
    
    /// Check if path is in set or under a set member
    bool contains(string path) @safe const
    {
        import std.path : absolutePath;
        
        auto absPath = absolutePath(path);
        
        foreach (allowed; paths)
        {
            auto absAllowed = absolutePath(allowed);
            
            // Exact match
            if (absPath == absAllowed)
                return true;
            
            // Prefix match (path under allowed directory)
            if (absPath.startsWith(absAllowed ~ "/"))
                return true;
        }
        
        return false;
    }
    
    /// Add path to set
    void add(string path) @safe
    {
        if (!contains(path))
            paths ~= path;
    }
    
    /// Union operation: this ∪ other
    PathSet union_(const PathSet other) @safe const
    {
        PathSet result;
        result.paths = paths.dup;
        
        foreach (path; other.paths)
        {
            if (!result.contains(path))
                result.paths ~= path;
        }
        
        return result;
    }
    
    /// Intersection operation: this ∩ other
    PathSet intersection(const PathSet other) @safe const
    {
        PathSet result;
        
        foreach (path; paths)
        {
            if (other.contains(path))
                result.paths ~= path;
        }
        
        return result;
    }
    
    /// Check if disjoint: this ∩ other = ∅
    bool disjoint(const PathSet other) @safe const
    {
        return intersection(other).paths.length == 0;
    }
}

/// Network access policy
struct NetworkPolicy
{
    bool isHermetic = true;    // Fully hermetic (no network)
    bool allowHttp = false;    // Allow HTTP
    bool allowHttps = false;   // Allow HTTPS
    bool allowDns = false;     // Allow DNS lookups
    string[] allowedHosts;     // Whitelist of allowed hosts
    
    /// Create hermetic policy (no network)
    static NetworkPolicy hermetic() @safe pure nothrow
    {
        return NetworkPolicy(true, false, false, false, []);
    }
    
    /// Create policy allowing specific hosts
    static NetworkPolicy allowHosts(string[] hosts) @safe pure nothrow
    {
        return NetworkPolicy(false, true, true, true, hosts);
    }
}

/// Environment variable set
struct EnvSet
{
    string[string] vars;
    bool inheritPath = false;  // Whether to inherit PATH
    bool inheritHome = false;  // Whether to inherit HOME
    
    /// Check if variable exists
    bool has(string key) @safe const pure nothrow
    {
        return (key in vars) !is null;
    }
    
    /// Get variable value
    string get(string key, string defaultValue = "") @safe const
    {
        auto val = key in vars;
        return val ? *val : defaultValue;
    }
    
    /// Set variable
    void set(string key, string value) @safe pure nothrow
    {
        vars[key] = value;
    }
    
    /// Create minimal environment
    static EnvSet minimal() @safe pure nothrow
    {
        EnvSet env;
        env.vars["USER"] = "builder";
        env.vars["LANG"] = "C.UTF-8";
        env.vars["LC_ALL"] = "C.UTF-8";
        return env;
    }
    
    /// Build environment map for execution
    string[string] toMap() @safe const
    {
        string[string] result;
        foreach (k, v; vars)
            result[k] = v;
        return result;
    }
}

/// Resource limits for cgroups/job objects
struct ResourceLimits
{
    ulong maxMemoryBytes = 0;     // 0 = unlimited
    ulong maxCpuTimeMs = 0;       // 0 = unlimited
    uint maxProcesses = 256;      // Process limit
    ulong maxFileSize = 1024 * 1024 * 1024;  // 1GB per file
    uint cpuShares = 1024;        // CPU weight (Linux)
    ulong maxDiskIO = 0;          // 0 = unlimited (bytes)
    ulong maxNetworkIO = 0;       // 0 = unlimited (bytes)
    uint maxOpenFiles = 1024;     // File descriptor limit
    ulong maxOutputBytes = 0;     // 0 = unlimited (bytes)
    
    /// Create default limits
    static ResourceLimits defaults() @safe pure nothrow
    {
        return ResourceLimits();
    }
    
    /// Create strict limits for hermetic builds
    static ResourceLimits hermetic() @safe pure nothrow
    {
        ResourceLimits limits;
        limits.maxMemoryBytes = 4UL * 1024 * 1024 * 1024;  // 4GB
        limits.maxCpuTimeMs = 60 * 60 * 1000;  // 1 hour
        limits.maxProcesses = 128;
        limits.maxDiskIO = 10UL * 1024 * 1024 * 1024;  // 10GB
        limits.maxNetworkIO = 1UL * 1024 * 1024 * 1024;  // 1GB
        limits.maxOpenFiles = 512;
        limits.maxOutputBytes = 100UL * 1024 * 1024;   // 100MB
        return limits;
    }
}

/// Process execution policy
struct ProcessPolicy
{
    bool allowFork = true;        // Allow fork/clone
    bool allowExec = true;        // Allow exec*
    uint maxChildren = 64;        // Max child processes
    bool killOnParentExit = true; // Kill children when parent exits
    
    /// Create hermetic policy
    static ProcessPolicy hermetic() @safe pure nothrow
    {
        ProcessPolicy policy;
        policy.maxChildren = 32;
        policy.killOnParentExit = true;
        return policy;
    }
}

/// Builder for SandboxSpec with fluent API
struct SandboxSpecBuilder
{
    private SandboxSpec spec;
    
    /// Start building a spec
    static SandboxSpecBuilder create() @safe pure nothrow
    {
        SandboxSpecBuilder builder;
        builder.spec.network = NetworkPolicy.hermetic();
        builder.spec.environment = EnvSet.minimal();
        builder.spec.resources = ResourceLimits.hermetic();
        builder.spec.process = ProcessPolicy.hermetic();
        return builder;
    }
    
    /// Add input path (read-only)
    ref auto input(string path) @safe return
    {
        spec.inputs.add(path);
        return this;
    }
    
    /// Add output path (write-only)
    ref auto output(string path) @safe return
    {
        spec.outputs.add(path);
        return this;
    }
    
    /// Add temp path (read-write)
    ref auto temp(string path) @safe return
    {
        spec.temps.add(path);
        return this;
    }
    
    /// Set network policy
    ref auto withNetwork(const NetworkPolicy policy) @trusted return
    {
        spec.network = cast(NetworkPolicy)policy;
        return this;
    }
    
    /// Add environment variable
    ref auto env(string key, string value) @safe return
    {
        spec.environment.set(key, value);
        return this;
    }
    
    /// Clear all environment variables
    ref auto clearEnvironment() @safe return
    {
        spec.environment.vars.clear();
        return this;
    }
    
    /// Set resource limits
    ref auto withResources(ResourceLimits limits) @safe return
    {
        spec.resources = limits;
        return this;
    }
    
    /// Set process policy
    ref auto withProcess(ProcessPolicy policy) @safe return
    {
        spec.process = policy;
        return this;
    }
    
    /// Build and validate spec
    Result!(SandboxSpec, string) build() @system
    {
        auto validationResult = spec.validate();
        if (validationResult.isErr)
            return Err!(SandboxSpec, string)(validationResult.unwrapErr());
        
        return Ok!(SandboxSpec, string)(spec);
    }
}

/// Check if two paths overlap (one is prefix of other)
private bool pathsOverlap(string path1, string path2) @safe
{
    import std.path : absolutePath;
    
    auto abs1 = absolutePath(path1);
    auto abs2 = absolutePath(path2);
    
    return abs1 == abs2 ||
           abs1.startsWith(abs2 ~ "/") ||
           abs2.startsWith(abs1 ~ "/");
}

/// Result type for validation
struct ValidationResult(T)
{
    private bool _isOk;
    private T _value;
    private string _error;
    
    static ValidationResult ok(T val) @safe
    {
        ValidationResult r;
        r._isOk = true;
        r._value = val;
        return r;
    }
    
    static ValidationResult err(string error) @safe
    {
        ValidationResult r;
        r._isOk = false;
        r._error = error;
        return r;
    }
    
    bool isOk() @safe const pure nothrow { return _isOk; }
    bool isErr() @safe const pure nothrow { return !_isOk; }
    
    T unwrap() @safe
    {
        if (!_isOk)
            assert(false, "Result unwrap failed: " ~ _error);
        return _value;
    }
    
    string unwrapErr() @safe const
    {
        if (_isOk)
            assert(false, "Result is ok, not an error");
        return _error;
    }
}

@system unittest
{
    // Test hermeticity validation
    auto builder = SandboxSpecBuilder.create()
        .input("/workspace/src")
        .output("/workspace/bin")
        .temp("/tmp/build");
    
    auto result = builder.build();
    assert(result.isOk);
    
    // Test overlap detection
    auto badBuilder = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/workspace/bin");  // Overlaps with input
    
    auto badResult = badBuilder.build();
    assert(badResult.isErr);
}

@safe unittest
{
    // Test PathSet operations
    PathSet set1;
    set1.add("/a");
    set1.add("/b");
    
    PathSet set2;
    set2.add("/b");
    set2.add("/c");
    
    // Test union
    auto union_ = set1.union_(set2);
    assert(union_.contains("/a"));
    assert(union_.contains("/b"));
    assert(union_.contains("/c"));
    
    // Test intersection
    auto intersection = set1.intersection(set2);
    assert(intersection.paths.length == 1);
    assert(intersection.contains("/b"));
    
    // Test disjoint
    PathSet set3;
    set3.add("/x");
    assert(set1.disjoint(set3));
    assert(!set1.disjoint(set2));
}

