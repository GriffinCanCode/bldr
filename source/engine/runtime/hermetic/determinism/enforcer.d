module engine.runtime.hermetic.determinism.enforcer;

import std.datetime : SysTime, Duration;
import std.path : buildPath, absolutePath;
import std.file : exists, mkdirRecurse, tempDir;
import std.conv : to;
import std.uuid : randomUUID;
import std.range : empty;
import engine.runtime.hermetic.core.spec;
import engine.runtime.hermetic.core.executor;
import infrastructure.errors;
import infrastructure.utils.logging : structuredLog;

/// Determinism configuration for reproducible builds
struct DeterminismConfig
{
    ulong fixedTimestamp = 1640995200;  // 2022-01-01 00:00:00 UTC
    uint prngSeed = 42;                 // Fixed PRNG seed
    bool normalizeTimestamps = true;    // Normalize file timestamps in outputs
    bool deterministicThreading = true; // Force single-threaded or deterministic scheduling
    string sourceEpoch;                 // SOURCE_DATE_EPOCH override
    bool strictMode = false;            // Fail on detected non-determinism
    
    /// Create default deterministic config
    static DeterminismConfig defaults() @safe pure nothrow
    {
        return DeterminismConfig();
    }
    
    /// Create strict config (fails on non-determinism)
    static DeterminismConfig strict() @safe pure nothrow
    {
        DeterminismConfig config = defaults();
        config.strictMode = true;
        return config;
    }
}

/// Determinism violation detected during build
struct DeterminismViolation
{
    string source;          // Source of non-determinism (time, random, thread)
    string description;     // Human-readable description
    string[] affectedFiles; // Files affected by violation
    string suggestion;      // Repair suggestion
}

/// Result of determinism enforcement
struct DeterminismResult
{
    bool deterministic;                    // Was execution deterministic?
    DeterminismViolation[] violations;     // Detected violations
    string outputHash;                     // Hash of output for comparison
    string[string] fileHashes;             // Per-file hashes
    Duration enforcementOverhead;          // Time spent enforcing determinism
}

/// Enforces deterministic execution beyond hermetic isolation
/// 
/// Builds on hermetic execution to ensure bit-for-bit reproducible outputs.
/// Uses syscall interception via LD_PRELOAD/DYLD_INSERT_LIBRARIES to:
/// - Override time() with fixed timestamp
/// - Override random() with seeded PRNG
/// - Control thread scheduling for determinism
/// 
/// Design Philosophy:
/// - Layered on top of HermeticExecutor (composition over inheritance)
/// - Platform-specific shim libraries for syscall interception
/// - Automatic detection and reporting of non-determinism sources
/// - Graceful degradation: warns but doesn't fail by default
struct DeterminismEnforcer
{
    private DeterminismConfig config;
    private HermeticExecutor executor;
    private string shimLibPath;
    private bool initialized;
    
    /// Create enforcer with hermetic executor
    static BuildResult!DeterminismEnforcer create(
        HermeticExecutor executor,
        DeterminismConfig config = DeterminismConfig.defaults()
    ) @system
    {
        DeterminismEnforcer enforcer;
        enforcer.config = config;
        enforcer.executor = executor;
        
        // Locate or build shim library
        auto shimResult = locateShimLibrary();
        if (shimResult.isErr)
        {
            // Shim not available - log warning but continue
            structuredLog.warning("determinism_shim_library_not_available_").field("detail", "Determinism shim library not available: " ~ shimResult.unwrapErr()).emit();
            structuredLog.warning("determinism_enforcement_will_be_limited").emit();
        }
        else
        {
            enforcer.shimLibPath = shimResult.unwrap();
        }
        
        enforcer.initialized = true;
        return Ok!(DeterminismEnforcer, BuildError)(enforcer);
    }
    
    /// Execute command with determinism enforcement
    BuildResult!DeterminismResult execute(
        string[] command,
        string workingDir = ""
    ) @system
    {
        if (!initialized)
            return Err!(DeterminismResult, BuildError)(
                Errors.system("Enforcer not initialized", Internal.NotInitialized)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        
        import std.datetime.stopwatch : StopWatch;
        auto sw = StopWatch();
        sw.start();
        
        // Augment sandbox spec with determinism environment
        auto spec = executor.getSpec();
        auto augmentedSpec = augmentDeterministicEnvironment(spec);
        
        // Create new executor with augmented spec
        auto execResult = HermeticExecutor.create(augmentedSpec, workingDir);
        if (execResult.isErr)
            return Err!(DeterminismResult, BuildError)(execResult.unwrapErr());
        
        auto detExec = execResult.unwrap();
        
        // Execute with interception
        auto output = detExec.execute(command, workingDir);
        if (output.isErr)
            return Err!(DeterminismResult, BuildError)(output.unwrapErr());
        
        sw.stop();
        
        // Analyze results for determinism
        auto result = analyzeOutput(output.unwrap());
        result.enforcementOverhead = sw.peek();
        
        // Check for violations
        if (config.strictMode && !result.deterministic)
        {
            return Err!(DeterminismResult, BuildError)(
                Errors.system("Build violated determinism: " ~ 
                    result.violations.length.to!string ~ " violations detected",
                    Build.Failed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        return Ok!(DeterminismResult, BuildError)(result);
    }
    
    /// Execute and verify determinism across multiple runs
    BuildResult!DeterminismResult executeAndVerify(
        string[] command,
        string workingDir = "",
        uint iterations = 3
    ) @system
    {
        import std.algorithm : all;
        
        if (iterations < 2)
            iterations = 2;
        
        structuredLog.info("verifying_determinism_across_").field("detail", "Verifying determinism across " ~ iterations.to!string ~ " builds...").emit();
        
        DeterminismResult[] results;
        results.length = iterations;
        
        // Execute multiple times
        foreach (i; 0 .. iterations)
        {
            structuredLog.debug_("determinism_verification_build_").field("detail", "Determinism verification build " ~ (i + 1).to!string).emit();
            
            auto result = execute(command, workingDir);
            if (result.isErr)
                return result;
            
            results[i] = result.unwrap();
        }
        
        // Verify all outputs match
        auto referenceHash = results[0].outputHash;
        bool allMatch = results.all!(r => r.outputHash == referenceHash);
        
        DeterminismResult finalResult = results[0];
        finalResult.deterministic = allMatch;
        
        if (!allMatch)
        {
            // Add violation for non-deterministic output
            DeterminismViolation violation;
            violation.source = "output_mismatch";
            violation.description = "Build outputs differ across runs";
            violation.suggestion = "Check compiler flags, timestamps, and randomness sources";
            finalResult.violations ~= violation;
            
            structuredLog.warning("build_is_nondeterministic_outputs_differ").emit();
        }
        else
        {
            structuredLog.info("_build_is_deterministic_all_outputs_matc").emit();
        }
        
        return Ok!(DeterminismResult, BuildError)(finalResult);
    }
    
    /// Get determinism configuration
    const(DeterminismConfig) getConfig() @safe const pure nothrow
    {
        return config;
    }
    
    private:
    
    /// Augment sandbox spec with determinism environment variables
    SandboxSpec augmentDeterministicEnvironment(const SandboxSpec spec) @system
    {
        import engine.runtime.hermetic.core.spec : SandboxSpecBuilder;
        
        auto builder = SandboxSpecBuilder.create();
        
        // Copy existing spec
        foreach (path; spec.inputs.paths)
            builder.input(path);
        foreach (path; spec.outputs.paths)
            builder.output(path);
        foreach (path; spec.temps.paths)
            builder.temp(path);
        
        builder.withNetwork(spec.network);
        builder.withResources(spec.resources);
        builder.withProcess(spec.process);
        
        // Add existing environment
        foreach (key, value; spec.environment.vars)
            builder.env(key, value);
        
        // Add determinism environment variables
        builder.env("SOURCE_DATE_EPOCH", config.fixedTimestamp.to!string);
        builder.env("BUILD_TIMESTAMP", config.fixedTimestamp.to!string);
        builder.env("RANDOM_SEED", config.prngSeed.to!string);
        
        // Force single-threaded for determinism if enabled
        if (config.deterministicThreading)
        {
            builder.env("MAKEFLAGS", "-j1");
            builder.env("CARGO_BUILD_JOBS", "1");
            builder.env("GOMAXPROCS", "1");
        }
        
        // Add shim library for syscall interception
        if (!shimLibPath.empty && exists(shimLibPath))
        {
            version(linux)
                builder.env("LD_PRELOAD", shimLibPath);
            else version(OSX)
                builder.env("DYLD_INSERT_LIBRARIES", shimLibPath);
        }
        
        return builder.build().unwrap();
    }
    
    /// Analyze execution output for determinism
    DeterminismResult analyzeOutput(Output output) @system
    {
        import infrastructure.utils.files.hash : FastHash;
        import std.file : exists;
        
        DeterminismResult result;
        result.deterministic = true;
        
        // Compute combined output hash
        string[] hashComponents;
        
        // Hash stdout and stderr
        hashComponents ~= FastHash.hashString(output.stdout);
        hashComponents ~= FastHash.hashString(output.stderr);
        
        // Hash each output file
        foreach (outputFile; output.outputFiles)
        {
            if (exists(outputFile))
            {
                string fileHash = FastHash.hashFile(outputFile);
                hashComponents ~= fileHash;
                
                // Store per-file hash in result for debugging
                result.violations ~= DeterminismViolation(
                    "output_file",
                    "Output file: " ~ outputFile,
                    [outputFile],
                    "Hash: " ~ fileHash
                );
            }
        }
        
        // Combine all hashes into single output hash
        result.outputHash = FastHash.hashStrings(hashComponents);
        
        return result;
    }
    
    /// Locate or build determinism shim library
    static Result!(string, string) locateShimLibrary() @system
    {
        import std.file : exists;
        import std.path : buildPath;
        
        // Check for pre-built shim library
        version(linux)
        {
            immutable shimName = "libdetshim.so";
        }
        else version(OSX)
        {
            immutable shimName = "libdetshim.dylib";
        }
        else
        {
            return Err!(string, string)("Platform not supported for shim library");
        }
        
        // Try multiple locations
        string[] searchPaths = [
            buildPath("bin", shimName),
            buildPath("lib", shimName),
            buildPath("/usr/local/lib/builder", shimName),
        ];
        
        foreach (path; searchPaths)
        {
            if (exists(path))
                return Ok!(string, string)(absolutePath(path));
        }
        
        return Err!(string, string)("Shim library not found in search paths");
    }
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing determinism enforcer...");
    
    // Test config creation
    auto config = DeterminismConfig.defaults();
    assert(config.fixedTimestamp == 1640995200);
    assert(config.prngSeed == 42);
    
    auto strictConfig = DeterminismConfig.strict();
    assert(strictConfig.strictMode);
    
    writeln("✓ Determinism enforcer tests passed");
}

