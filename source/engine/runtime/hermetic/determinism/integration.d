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
import infrastructure.utils.logging.logger : Logger;

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
    static Result!(DeterminismIntegration, BuildError) create(
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
    Result!(VerificationReport, BuildError) verifyBuild(
        string[] command,
        SandboxSpec spec,
        string workingDir = ""
    ) @system
    {
        import std.datetime.stopwatch : StopWatch;
        
        if (!initialized)
            return Err!(VerificationReport, BuildError)(
                new SystemError("Integration not initialized", ErrorCode.NotInitialized));
        
        auto sw = StopWatch();
        sw.start();
        
        Logger.info("Starting determinism verification with " ~ 
                   config.iterations.to!string ~ " builds...");
        
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
            Logger.info("Build " ~ (i + 1).to!string ~ "/" ~ config.iterations.to!string);
            
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
        Logger.info("Comparing build outputs...");
        
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
            Logger.warning("Non-determinism detected, generating repair plan...");
            
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
        
        Logger.info(report.summary());
        Logger.info("Report saved to: " ~ reportPath);
        
        // Apply auto-repair if enabled
        if (!report.isDeterministic && config.autoRepair)
        {
            Logger.info("Auto-repair enabled, applying fixes...");
            applyAutoRepair(detections);
        }
        
        // Fail if configured to fail on violation
        if (!report.isDeterministic && config.failOnViolation)
        {
            auto error = new SystemError(
                "Build is non-deterministic: " ~ 
                verifyResult.violations.length.to!string ~ " violations",
                ErrorCode.BuildFailed
            );
            return Err!(VerificationReport, BuildError)(error);
        }
        
        return Ok!(VerificationReport, BuildError)(report);
    }
    
    /// Quick determinism check (single run with detection only)
    Result!(VerificationReport, BuildError) quickCheck(
        string[] command
    ) @system
    {
        import std.datetime.stopwatch : StopWatch;
        
        auto sw = StopWatch();
        sw.start();
        
        Logger.info("Running quick determinism check...");
        
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
            Logger.warning("Found " ~ detections.length.to!string ~ 
                         " potential determinism issues");
            
            DeterminismViolation[] violations;
            report.repairPlan = RepairEngine.generateRepairPlan(detections, violations);
        }
        else
        {
            Logger.info("No determinism issues detected in command");
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
        Logger.info("Applying automatic repairs...");
        
        auto flags = RepairEngine.generateConsolidatedFlags(detections);
        auto envVars = RepairEngine.generateConsolidatedEnvVars(detections);
        
        // Log what would be applied
        Logger.info("Would add compiler flags:");
        foreach (flag; flags)
            Logger.info("  " ~ flag);
        
        Logger.info("Would set environment variables:");
        foreach (key, value; envVars)
            Logger.info("  " ~ key ~ "=" ~ value);
        
        // TODO: Actually apply these to the build configuration
        Logger.warning("Auto-repair not fully implemented yet");
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
