module engine.runtime.hermetic.determinism.integration;

import std.datetime : SysTime, Clock, Duration;
import std.conv : to;
import std.file : exists, mkdirRecurse, write, read, tempDir;
import std.path : buildPath;
import std.algorithm : map;
import std.array : array;
import infrastructure.utils.files.directories : ensureDirectoryWithGitignore;
import engine.runtime.hermetic.determinism.enforcer;
import engine.runtime.hermetic.determinism.verifier;
import engine.runtime.hermetic.determinism.detector;
import engine.runtime.hermetic.determinism.repair;
import engine.runtime.hermetic.core.executor;
import engine.runtime.hermetic.core.spec;
import infrastructure.errors;
import infrastructure.utils.logging : Logger, structuredLog;

/// Verification mode
enum VerificationMode
{
    Off,              // No verification
    OnDemand,         // Only when explicitly requested
    Automatic,        // Automatic two-build comparison
    Continuous        // Verify every build
}

/// Verification configuration
struct VerificationConfig
{
    VerificationMode mode = VerificationMode.Off;
    uint iterations = 2;                      // Number of builds to compare
    VerificationStrategy strategy = VerificationStrategy.ContentHash;
    bool autoRepair = false;                  // Automatically apply fixes
    bool failOnViolation = false;             // Fail build if non-deterministic
    string outputDir = ".builder-verify";     // Directory for verification artifacts
    
    /// Create default config
    static VerificationConfig defaults() @safe pure nothrow
    {
        return VerificationConfig();
    }
    
    /// Create automatic verification config
    static VerificationConfig automatic() @safe pure nothrow
    {
        VerificationConfig config;
        config.mode = VerificationMode.Automatic;
        config.iterations = 2;
        return config;
    }
    
    /// Create strict verification config
    static VerificationConfig strict() @safe pure nothrow
    {
        VerificationConfig config;
        config.mode = VerificationMode.Automatic;
        config.iterations = 3;
        config.failOnViolation = true;
        return config;
    }
}

/// Verification result with full analysis
struct VerificationReport
{
    bool isDeterministic;
    VerificationResult verificationResult;
    Detection[] detections;
    RepairPlan repairPlan;
    Duration totalTime;
    SysTime timestamp;
    
    /// Get summary string
    string summary() const @safe
    {
        if (isDeterministic)
            return "✓ Build is deterministic - all outputs match";
        else
            return "✗ Build is non-deterministic - " ~ 
                   verificationResult.violations.length.to!string ~ " issues found";
    }
    
    /// Save report to file
    void save(string path) const @system
    {
        import std.json : JSONValue;
        
        JSONValue json;
        json["deterministic"] = isDeterministic;
        json["violations"] = verificationResult.violations.length;
        json["detections"] = detections.length;
        json["timestamp"] = timestamp.toISOExtString();
        json["duration_ms"] = totalTime.total!"msecs";
        
        write(path, json.toPrettyString());
    }
}

/// Integrated determinism verification for build system
struct DeterminismIntegration
{
    private VerificationConfig config;
    private DeterminismEnforcer enforcer;
    private DeterminismVerifier verifier;
    private bool initialized;
    
    /// Create integration with configuration
    static BuildResult!DeterminismIntegration create(
        VerificationConfig config = VerificationConfig.defaults()
    ) @system
    {
        DeterminismIntegration integration;
        integration.config = config;
        
        // Create output directory
        ensureDirectoryWithGitignore(config.outputDir);
        
        // Create verifier
        integration.verifier = DeterminismVerifier.create(config.strategy);
        
        integration.initialized = true;
        return Ok!(DeterminismIntegration, BuildError)(integration);
    }
    
    /// Verify build determinism with automatic two-build comparison
    BuildResult!VerificationReport verifyBuild(
        string[] command,
        SandboxSpec spec,
        string workingDir = ""
    ) @system
    {
        import std.datetime.stopwatch : StopWatch;
        
        if (!initialized)
            return Err!(VerificationReport, BuildError)(
                Errors.system("Integration not initialized", Internal.NotInitialized)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        auto sw = StopWatch();
        sw.start();
        
        structuredLog.info("starting_determinism_verification_with_").field("detail", "Starting determinism verification with " ~ 
                   config.iterations.to!string ~ " builds...").emit();
        
        // Create hermetic executor
        auto executorResult = HermeticExecutor.create(spec, workingDir);
        if (executorResult.isErr)
            return Err!(VerificationReport, BuildError)(executorResult.unwrapErr());
        
        auto executor = executorResult.unwrap();
        
        // Create enforcer
        auto enforcerResult = DeterminismEnforcer.create(
            executor,
            DeterminismConfig.defaults()
        );
        if (enforcerResult.isErr)
            return Err!(VerificationReport, BuildError)(enforcerResult.unwrapErr());
        
        auto localEnforcer = enforcerResult.unwrap();
        
        // Execute multiple builds
        string[] outputDirs;
        outputDirs.length = config.iterations;
        
        foreach (i; 0 .. config.iterations)
        {
            structuredLog.info("build_").field("detail", "Build " ~ (i + 1).to!string ~ "/" ~ config.iterations.to!string).emit();
            
            // Create unique output directory for this iteration
            immutable iterDir = buildPath(config.outputDir, "build-" ~ i.to!string);
            mkdirRecurse(iterDir);
            outputDirs[i] = iterDir;
            
            // Execute build
            auto buildResult = localEnforcer.execute(command, workingDir);
            if (buildResult.isErr)
                return Err!(VerificationReport, BuildError)(buildResult.unwrapErr());
        }
        
        // Compare outputs from all builds
        structuredLog.info("comparing_build_outputs").emit();
        
        auto compareResult = verifier.verifyDirectory(outputDirs[0], outputDirs[1]);
        if (compareResult.isErr)
            return Err!(VerificationReport, BuildError)(compareResult.unwrapErr());
        
        auto verifyResult = compareResult.unwrap();
        
        // Analyze for non-determinism sources
        auto detections = NonDeterminismDetector.analyzeCompilerCommand(command);
        
        // Generate repair plan if non-deterministic
        RepairPlan repairPlan;
        if (!verifyResult.isDeterministic)
        {
            structuredLog.warning("nondeterminism_detected_generating_repai").emit();
            
            DeterminismViolation[] violations;
            foreach (v; verifyResult.violations)
            {
                DeterminismViolation violation;
                violation.description = v;
                violation.source = "output_comparison";
                violations ~= violation;
            }
            
            repairPlan = RepairEngine.generateRepairPlan(detections, violations);
        }
        
        sw.stop();
        
        // Build report
        VerificationReport report;
        report.isDeterministic = verifyResult.isDeterministic;
        report.verificationResult = verifyResult;
        report.detections = detections;
        report.repairPlan = repairPlan;
        report.totalTime = sw.peek();
        report.timestamp = Clock.currTime();
        
        // Save report
        immutable reportPath = buildPath(config.outputDir, "report.json");
        report.save(reportPath);
        
        structuredLog.info("log_event").field("message", report.summary()).emit();
        structuredLog.info("report_saved_to_").field("detail", "Report saved to: " ~ reportPath).emit();
        
        // Apply auto-repair if enabled
        if (!report.isDeterministic && config.autoRepair)
        {
            structuredLog.info("autorepair_enabled_applying_fixes").emit();
            applyAutoRepair(detections);
        }
        
        // Fail if configured to fail on violation
        if (!report.isDeterministic && config.failOnViolation)
        {
            auto error = Errors.system(
                "Build is non-deterministic: " ~ 
                verifyResult.violations.length.to!string ~ " violations",
                Build.Failed)
                .withLocation(__FILE__, __LINE__)
                .build();
            return Err!(VerificationReport, BuildError)(error);
        }
        
        return Ok!(VerificationReport, BuildError)(report);
    }
    
    /// Quick determinism check (single run with detection only)
    BuildResult!VerificationReport quickCheck(
        string[] command
    ) @system
    {
        import std.datetime.stopwatch : StopWatch;
        
        auto sw = StopWatch();
        sw.start();
        
        structuredLog.info("running_quick_determinism_check").emit();
        
        // Analyze command for potential issues
        auto detections = NonDeterminismDetector.analyzeCompilerCommand(command);
        
        sw.stop();
        
        // Build minimal report
        VerificationReport report;
        report.isDeterministic = (detections.length == 0);
        report.detections = detections;
        report.totalTime = sw.peek();
        report.timestamp = Clock.currTime();
        
        if (detections.length > 0)
        {
            structuredLog.warning("found_").field("detail", "Found " ~ detections.length.to!string ~ 
                         " potential determinism issues").emit();
            
            DeterminismViolation[] violations;
            report.repairPlan = RepairEngine.generateRepairPlan(detections, violations);
        }
        else
        {
            structuredLog.info("no_determinism_issues_detected_in_comman").emit();
        }
        
        return Ok!(VerificationReport, BuildError)(report);
    }
    
    /// Get verification configuration
    const(VerificationConfig) getConfig() const @safe pure nothrow
    {
        return config;
    }
    
    private:
    
    /// Apply automatic repairs
    void applyAutoRepair(Detection[] detections) @system
    {
        structuredLog.info("applying_automatic_repairs").emit();
        
        auto flags = RepairEngine.generateConsolidatedFlags(detections);
        auto envVars = RepairEngine.generateConsolidatedEnvVars(detections);
        
        // Log what would be applied
        structuredLog.info("would_add_compiler_flags").emit();
        foreach (flag; flags)
            structuredLog.info("__").field("detail", "  " ~ flag).emit();
        
        structuredLog.info("would_set_environment_variables").emit();
        foreach (key, value; envVars)
            structuredLog.info("__").field("detail", "  " ~ key ~ "=" ~ value).emit();
        
        // TODO: Actually apply these to the build configuration
        structuredLog.warning("autorepair_not_fully_implemented_yet").emit();
    }
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing determinism integration...");
    
    // Test config creation
    auto config = VerificationConfig.automatic();
    assert(config.mode == VerificationMode.Automatic);
    assert(config.iterations == 2);
    
    auto strictConfig = VerificationConfig.strict();
    assert(strictConfig.failOnViolation);
    assert(strictConfig.iterations == 3);
    
    // Test integration creation
    auto integrationResult = DeterminismIntegration.create(config);
    assert(integrationResult.isOk);
    
    writeln("✓ Determinism integration tests passed");
}
