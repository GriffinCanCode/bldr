module engine.runtime.hermetic.tracing.verifier;

import std.datetime : Duration, msecs;
import std.algorithm : map, filter, any;
import std.array : array, Appender;
import std.conv : to;
import engine.runtime.hermetic.tracing.tracer;
import engine.runtime.hermetic.tracing.analyzer;
import engine.runtime.hermetic.determinism.detector;
import infrastructure.errors;

/// Combined verification result
struct VerificationResult
{
    bool hermetic;                       // Passed hermeticity verification
    bool deterministic;                  // Passed determinism verification (if enabled)
    HermeticityAnalysis hermeticAnalysis;// Detailed hermeticity analysis
    Detection[] staticDetections;        // Static determinism detections
    TraceResult trace;                   // Raw trace data
    Duration totalDuration;              // Total verification time
    string[] warnings;                   // Non-blocking warnings
    
    /// Overall verification passed
    bool passed() const @safe pure nothrow
    {
        return hermetic && deterministic;
    }
    
    /// Get all issues as strings
    string[] issues() const @safe
    {
        Appender!(string[]) issues;
        
        foreach (v; hermeticAnalysis.violations)
            issues ~= "[" ~ v.severity.to!string ~ "] " ~ v.description;
        
        foreach (d; staticDetections)
            issues ~= "[Static] " ~ d.description;
        
        return issues.data;
    }
    
    /// Generate comprehensive report
    string report() const @safe
    {
        Appender!string sb;
        
        sb ~= "╔══════════════════════════════════════════════════════════════╗\n";
        sb ~= "║           HERMETIC BUILD VERIFICATION REPORT                 ║\n";
        sb ~= "╚══════════════════════════════════════════════════════════════╝\n\n";
        
        // Overall status
        if (passed())
        {
            sb ~= "✓ VERIFICATION PASSED\n";
            sb ~= "  Build is hermetic and deterministic.\n\n";
        }
        else
        {
            sb ~= "✗ VERIFICATION FAILED\n";
            if (!hermetic)
                sb ~= "  • Hermeticity violations detected\n";
            if (!deterministic)
                sb ~= "  • Potential non-determinism detected\n";
            sb ~= "\n";
        }
        
        // Hermeticity section
        sb ~= hermeticAnalysis.report();
        
        // Static analysis section
        if (staticDetections.length > 0)
        {
            sb ~= "\nStatic Analysis Detections:\n";
            sb ~= "────────────────────────────────────────\n";
            foreach (d; staticDetections)
            {
                sb ~= "  [" ~ d.priority.to!string ~ "] " ~ d.description ~ "\n";
                if (d.compilerFlags.length > 0)
                    sb ~= "    Suggested flags: " ~ d.compilerFlags.to!string ~ "\n";
            }
        }
        
        // Warnings
        if (warnings.length > 0)
        {
            sb ~= "\nWarnings:\n";
            sb ~= "────────────────────────────────────────\n";
            foreach (w; warnings)
                sb ~= "  ⚠ " ~ w ~ "\n";
        }
        
        // Timing
        sb ~= "\nVerification completed in " ~ totalDuration.total!"msecs".to!string ~ "ms\n";
        
        return sb.data;
    }
}

/// Configuration for hermetic verification
struct VerificationConfig
{
    SyscallPolicy tracePolicy;           // Syscall tracing policy
    AnalyzerConfig analyzerConfig;       // Analysis configuration
    bool enableStaticAnalysis = true;    // Run static determinism checks
    bool enableRuntimeTracing = true;    // Run syscall tracing
    bool failOnWarnings = false;         // Treat warnings as failures
    uint verificationIterations = 1;     // Number of times to run (for flakiness)
    Duration timeout = Duration.zero;    // Execution timeout
    
    /// Create strict verification config
    static VerificationConfig strict() @safe
    {
        VerificationConfig cfg;
        cfg.tracePolicy = SyscallPolicy.hermetic();
        cfg.analyzerConfig = AnalyzerConfig.strict();
        return cfg;
    }
    
    /// Create permissive config (logging only)
    static VerificationConfig permissive() @safe
    {
        VerificationConfig cfg;
        cfg.tracePolicy = SyscallPolicy.permissive();
        cfg.analyzerConfig = AnalyzerConfig.permissive();
        cfg.failOnWarnings = false;
        return cfg;
    }
    
    /// Set workspace path
    ref VerificationConfig workspace(string path) return @safe
    {
        analyzerConfig.workspace(path);
        tracePolicy.allow(path);
        return this;
    }
    
    /// Allow additional path
    ref VerificationConfig allow(string path) return @safe
    {
        analyzerConfig.allowedPaths ~= path;
        tracePolicy.allow(path);
        return this;
    }
}

/// Hermetic build verifier combining static analysis and runtime tracing
struct HermeticVerifier
{
    private VerificationConfig config;
    private SyscallTracer tracer;
    private SyscallAnalyzer analyzer;
    private bool initialized;
    
    /// Create verifier with configuration
    static BuildResult!HermeticVerifier create(
        VerificationConfig config = VerificationConfig.strict()
    ) @system
    {
        HermeticVerifier verifier;
        verifier.config = config;
        verifier.analyzer = SyscallAnalyzer.create(config.analyzerConfig);
        
        if (config.enableRuntimeTracing)
        {
            auto tracerResult = SyscallTracer.create(config.tracePolicy);
            if (tracerResult.isErr)
            {
                // Runtime tracing not available - continue with static only
                verifier.config.enableRuntimeTracing = false;
            }
            else
            {
                verifier.tracer = tracerResult.unwrap();
            }
        }
        
        verifier.initialized = true;
        return Ok!(HermeticVerifier, BuildError)(verifier);
    }
    
    /// Verify command execution for hermeticity
    BuildResult!VerificationResult verify(
        string[] command,
        string workingDir = ""
    ) @system
    {
        import std.datetime.stopwatch : StopWatch;
        import core.time : MonoTime;
        
        if (!initialized)
            return Err!(VerificationResult, BuildError)(
                Errors.system("Verifier not initialized", Internal.NotInitialized).build());
        
        auto sw = StopWatch();
        sw.start();
        
        VerificationResult result;
        result.hermetic = true;
        result.deterministic = true;
        
        // Static analysis of command
        if (config.enableStaticAnalysis)
            result.staticDetections = NonDeterminismDetector.analyzeCompilerCommand(command);
        
        // Runtime tracing
        if (config.enableRuntimeTracing)
        {
            auto traceResult = tracer.trace(command, workingDir);
            if (traceResult.isErr)
            {
                result.warnings ~= "Runtime tracing failed: " ~ traceResult.unwrapErr().message();
            }
            else
            {
                result.trace = traceResult.unwrap();
                result.hermeticAnalysis = analyzer.analyze(result.trace);
                result.hermetic = result.hermeticAnalysis.hermetic;
            }
        }
        else
        {
            result.warnings ~= "Runtime tracing disabled or unavailable";
        }
        
        // Determine determinism from static analysis
        if (result.staticDetections.length > 0)
        {
            auto criticalDetections = result.staticDetections
                .filter!(d => d.priority <= 2)
                .array;
            
            if (criticalDetections.length > 0)
                result.deterministic = false;
        }
        
        // Handle warnings as failures if configured
        if (config.failOnWarnings && result.warnings.length > 0)
        {
            result.hermetic = false;
            result.deterministic = false;
        }
        
        sw.stop();
        result.totalDuration = sw.peek();
        
        return Ok!(VerificationResult, BuildError)(result);
    }
    
    /// Verify and execute, returning both verification and execution results
    BuildResult!VerificationResult verifyAndExecute(
        string[] command,
        string workingDir = ""
    ) @system
    {
        // For now, just delegate to verify which runs the command via tracing
        return verify(command, workingDir);
    }
    
    /// Quick check: is command likely hermetic?
    bool quickCheck(string[] command) const @safe
    {
        // Static analysis only
        auto detections = NonDeterminismDetector.analyzeCompilerCommand(command);
        return !detections.any!(d => d.priority <= 2);
    }
    
    /// Get verifier capabilities
    VerifierCapabilities capabilities() @safe const
    {
        VerifierCapabilities caps;
        caps.hasStaticAnalysis = config.enableStaticAnalysis;
        caps.hasRuntimeTracing = config.enableRuntimeTracing;
        
        if (config.enableRuntimeTracing)
            caps.tracerCaps = tracer.capabilities();
        
        return caps;
    }
    
    /// Cleanup resources
    void cleanup() @system nothrow
    {
        if (config.enableRuntimeTracing)
            tracer.cleanup();
        initialized = false;
    }
}

/// Verifier capabilities
struct VerifierCapabilities
{
    bool hasStaticAnalysis;
    bool hasRuntimeTracing;
    TracerCapabilities tracerCaps;
}

/// Convenience function: verify hermetic execution
BuildResult!VerificationResult verifyHermetic(
    string[] command,
    string workingDir = "",
    VerificationConfig config = VerificationConfig.strict()
) @system
{
    auto verifierResult = HermeticVerifier.create(config);
    if (verifierResult.isErr)
        return Err!(VerificationResult, BuildError)(verifierResult.unwrapErr());
    
    auto verifier = verifierResult.unwrap();
    scope(exit) verifier.cleanup();
    
    return verifier.verify(command, workingDir);
}

/// Check if hermetic verification is available on this platform
bool isHermeticVerificationAvailable() @system nothrow
{
    return isSyscallTracingAvailable();
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing hermetic verifier...");
    
    // Test config creation
    auto strict = VerificationConfig.strict();
    assert(strict.enableStaticAnalysis);
    assert(strict.enableRuntimeTracing);
    
    auto permissive = VerificationConfig.permissive();
    assert(!permissive.failOnWarnings);
    
    // Test workspace config
    auto cfg = VerificationConfig.strict().workspace("/tmp/build");
    assert(cfg.analyzerConfig.workspacePaths.length > 0);
    
    // Test verifier creation
    auto verifierResult = HermeticVerifier.create(VerificationConfig.strict());
    if (verifierResult.isOk)
    {
        auto verifier = verifierResult.unwrap();
        
        // Test quick check
        immutable quick = verifier.quickCheck(["gcc", "-o", "main", "main.c"]);
        // GCC without specific flags may have determinism issues
        
        // Test capabilities
        auto caps = verifier.capabilities();
        assert(caps.hasStaticAnalysis);
        
        verifier.cleanup();
    }
    
    // Test result report generation
    VerificationResult result;
    result.hermetic = false;
    result.deterministic = true;
    result.totalDuration = msecs(100);
    
    HermeticityViolation v;
    v.severity = ViolationSeverity.Critical;
    v.category = ViolationCategory.Network;
    v.description = "Network access detected";
    
    HermeticityAnalysis analysis;
    analysis.hermetic = false;
    analysis.violations = [v];
    result.hermeticAnalysis = analysis;
    
    import std.string : indexOf;
    auto report = result.report();
    assert(report.indexOf("VERIFICATION FAILED") >= 0);
    assert(report.indexOf("Hermeticity violations") >= 0);
    
    writeln("✓ Hermetic verifier tests passed");
}

