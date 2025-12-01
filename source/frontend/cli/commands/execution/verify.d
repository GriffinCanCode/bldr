module frontend.cli.commands.execution.verify;

import std.stdio;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.algorithm : filter, map;
import std.array : array, empty;
import std.conv : to;
import std.string : strip, startsWith;
import infrastructure.config.parsing.parser;
import infrastructure.config.schema.schema;
import engine.graph;
import engine.runtime.hermetic.determinism;
import engine.runtime.services;
import infrastructure.utils.logging.logger;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.errors;

/// Verify command - verifies build determinism
struct VerifyCommand
{
    private static Terminal terminal;
    private static Formatter formatter;
    private static bool initialized = false;
    
    /// Initialize terminal and formatter
    private static void init() @system
    {
        if (!initialized)
        {
            auto caps = Capabilities.detect();
            terminal = Terminal(caps);
            formatter = Formatter(caps);
            initialized = true;
        }
    }
    
    /// Execute verify determinism command
    static int execute(string[] args) @system
    {
        init();
        
        // Parse arguments
        string targetSpec = "";
        uint iterations = 2;
        bool quickCheck = false;
        bool strictMode = false;
        bool showRepairPlan = true;
        string outputDir = ".builder-verify";
        string strategy = "hash";
        
        size_t i = 1; // Skip "verify" command itself
        while (i < args.length)
        {
            immutable arg = args[i];
            
            if (arg == "--iterations" || arg == "-n")
            {
                if (i + 1 >= args.length)
                {
                    stderr.writeln("Error: --iterations requires a value");
                    return 1;
                }
                iterations = args[i + 1].to!uint;
                i += 2;
            }
            else if (arg == "--quick" || arg == "-q")
            {
                quickCheck = true;
                i++;
            }
            else if (arg == "--strict")
            {
                strictMode = true;
                i++;
            }
            else if (arg == "--no-repair-plan")
            {
                showRepairPlan = false;
                i++;
            }
            else if (arg == "--output" || arg == "-o")
            {
                if (i + 1 >= args.length)
                {
                    stderr.writeln("Error: --output requires a value");
                    return 1;
                }
                outputDir = args[i + 1];
                i += 2;
            }
            else if (arg == "--strategy")
            {
                if (i + 1 >= args.length)
                {
                    stderr.writeln("Error: --strategy requires a value");
                    return 1;
                }
                strategy = args[i + 1];
                i += 2;
            }
            else if (arg == "--help" || arg == "-h")
            {
                printHelp();
                return 0;
            }
            else if (!arg.startsWith("-"))
            {
                if (targetSpec.empty)
                    targetSpec = arg;
                i++;
            }
            else
            {
                stderr.writeln("Unknown option: " ~ arg);
                return 1;
            }
        }
        
        if (targetSpec.empty)
        {
            stderr.writeln("Error: No target specified");
            stderr.writeln("Usage: bldr verify <target> [options]");
            return 1;
        }
        
        // Print header
        writeln(formatter.header("Build Determinism Verification"));
        writeln();
        
        try
        {
            // Quick check mode - just analyze command without building
            if (quickCheck)
            {
                return executeQuickCheck(targetSpec);
            }
            
            // Full verification mode - build multiple times and compare
            return executeFullVerification(
                targetSpec,
                iterations,
                strictMode,
                showRepairPlan,
                outputDir,
                strategy
            );
        }
        catch (Exception e)
        {
            writeln(formatter.formatError("Verification failed: " ~ e.msg));
            return 1;
        }
    }
    
    private static int executeQuickCheck(string targetSpec) @system
    {
        writeln(formatter.formatInfo("Running quick determinism check (no build)..."));
        writeln();
        
        // Parse builderfile
        auto configResult = ConfigParser.parseWorkspace(".");
        if (configResult.isErr)
        {
            writeln(formatter.formatError("Failed to parse Builderfile: " ~ 
                               configResult.unwrapErr().message()));
            return 1;
        }
        
        auto workspaceConfig = configResult.unwrap();
        auto services = new BuildServices(workspaceConfig, workspaceConfig.options);
        scope(exit) services.shutdown();
        
        // Build graph
        auto graphResult = services.analyzer.analyze(targetSpec);
        if (graphResult.isErr)
        {
            writeln(formatter.formatError("Failed to build graph: " ~ 
                               graphResult.unwrapErr().message()));
            return 1;
        }
        
        auto graph = graphResult.unwrap();
        
        // Find target
        auto targetNode = targetSpec in graph.nodes;
        if (targetNode is null)
        {
            writeln(formatter.formatError("Target not found: " ~ targetSpec));
            return 1;
        }
        auto target = &targetNode.target;
        
        // Get build command (simplified - would need to get from language handler)
        string[] command = ["echo", "placeholder"];
        
        // Create integration
        auto config = VerificationConfig.defaults();
        auto integrationResult = DeterminismIntegration.create(config);
        if (integrationResult.isErr)
        {
            writeln(formatter.formatError("Failed to create integration: " ~ 
                               integrationResult.unwrapErr().message()));
            return 1;
        }
        
        auto integration = integrationResult.unwrap();
        
        // Quick check
        auto checkResult = integration.quickCheck(command);
        if (checkResult.isErr)
        {
            writeln(formatter.formatError("Check failed: " ~ 
                               checkResult.unwrapErr().message()));
            return 1;
        }
        
        auto report = checkResult.unwrap();
        
        // Print results
        printQuickCheckResults(report);
        
        return report.isDeterministic ? 0 : 1;
    }
    
    private static int executeFullVerification(
        string targetSpec,
        uint iterations,
        bool strictMode,
        bool showRepairPlan,
        string outputDir,
        string strategyStr
    ) @system
    {
        writeln(formatter.formatInfo("Running full determinism verification..."));
        writeln("  Target: " ~ targetSpec);
        writeln("  Iterations: " ~ iterations.to!string);
        writeln("  Mode: " ~ (strictMode ? "strict" : "standard"));
        writeln();
        
        // Parse verification strategy
        VerificationStrategy strategy;
        switch (strategyStr)
        {
            case "hash":
                strategy = VerificationStrategy.ContentHash;
                break;
            case "bitwise":
                strategy = VerificationStrategy.BitwiseCompare;
                break;
            case "fuzzy":
                strategy = VerificationStrategy.Fuzzy;
                break;
            case "structural":
                strategy = VerificationStrategy.Structural;
                break;
            default:
                writeln(formatter.formatError("Unknown strategy: " ~ strategyStr));
                return 1;
        }
        
        // Create verification config
        VerificationConfig config;
        config.mode = VerificationMode.Automatic;
        config.iterations = iterations;
        config.strategy = strategy;
        config.failOnViolation = strictMode;
        config.outputDir = outputDir;
        
        // Create integration
        auto integrationResult = DeterminismIntegration.create(config);
        if (integrationResult.isErr)
        {
            writeln(formatter.formatError("Failed to create integration: " ~ 
                               integrationResult.unwrapErr().message()));
            return 1;
        }
        
        auto integration = integrationResult.unwrap();
        
        // TODO: Get actual build command and sandbox spec from target
        // For now, this is a placeholder
        import engine.runtime.hermetic.core.spec : SandboxSpec, SandboxSpecBuilder;
        
        auto specResult = SandboxSpecBuilder.create().build();
        if (specResult.isErr)
        {
            writeln(formatter.formatError("Failed to create sandbox spec"));
            return 1;
        }
        
        string[] command = ["echo", "placeholder"];
        
        // Run verification
        writeln(formatter.formatInfo("Building " ~ iterations.to!string ~ " times..."));
        auto sw = StopWatch(AutoStart.yes);
        
        auto verifyResult = integration.verifyBuild(command, specResult.unwrap());
        
        sw.stop();
        
        if (verifyResult.isErr)
        {
            writeln(formatter.formatError("Verification failed: " ~ 
                               verifyResult.unwrapErr().message()));
            return 1;
        }
        
        auto report = verifyResult.unwrap();
        
        // Print results
        writeln();
        printFullVerificationResults(report, showRepairPlan);
        
        return report.isDeterministic ? 0 : 1;
    }
    
    private static void printQuickCheckResults(VerificationReport report) @system
    {
        writeln();
        writeln(formatter.section("Quick Check Results"));
        writeln();
        
        if (report.detections.length == 0)
        {
            writeln(formatter.green("✓ No potential determinism issues detected"));
        }
        else
        {
            writeln(formatter.formatWarning("⚠ Found " ~ report.detections.length.to!string ~ 
                                 " potential issues:"));
            writeln();
            
            foreach (i, detection; report.detections)
            {
                writeln("  " ~ (i + 1).to!string ~ ". " ~ detection.description);
                if (detection.compilerFlags.length > 0)
                {
                    writeln("     Suggested flags: " ~ detection.compilerFlags[0]);
                }
            }
        }
        
        writeln();
        writeln(formatter.formatInfo("Run without --quick to perform full verification"));
    }
    
    private static void printFullVerificationResults(
        VerificationReport report,
        bool showRepairPlan
    ) @system
    {
        writeln(formatter.section("Verification Results"));
        writeln();
        
        // Summary
        if (report.isDeterministic)
        {
            writeln(formatter.green("✓ Build is DETERMINISTIC"));
            writeln("  All " ~ report.verificationResult.totalFiles.to!string ~ 
                   " output files match across builds");
        }
        else
        {
            writeln(formatter.formatError("✗ Build is NON-DETERMINISTIC"));
            writeln("  " ~ (report.verificationResult.totalFiles - 
                   report.verificationResult.matchingFiles).to!string ~ 
                   " of " ~ report.verificationResult.totalFiles.to!string ~ 
                   " files differ");
        }
        
        writeln();
        writeln("  Duration: " ~ (report.totalTime.total!"msecs" / 1000.0).to!string ~ "s");
        writeln();
        
        // File comparison details
        if (!report.isDeterministic && report.verificationResult.comparisons.length > 0)
        {
            writeln(formatter.section("File Differences"));
            writeln();
            
            foreach (comp; report.verificationResult.comparisons)
            {
                if (!comp.matches)
                {
                    writeln("  " ~ comp.filePath);
                    foreach (diff; comp.differences)
                    {
                        writeln("    - " ~ diff);
                    }
                }
            }
            writeln();
        }
        
        // Repair plan
        if (!report.isDeterministic && showRepairPlan && 
            report.repairPlan.suggestions.length > 0)
        {
            writeln();
            writeln(report.repairPlan.format());
        }
    }
    
    private static void printHelp() @system
    {
        writeln("Usage: bldr verify <target> [options]");
        writeln();
        writeln("Verify build determinism by comparing outputs across multiple builds");
        writeln();
        writeln("Options:");
        writeln("  -n, --iterations N    Number of builds to compare (default: 2)");
        writeln("  -q, --quick           Quick check without building");
        writeln("  --strict              Fail if non-deterministic");
        writeln("  --no-repair-plan      Don't show repair suggestions");
        writeln("  -o, --output DIR      Output directory (default: .builder-verify)");
        writeln("  --strategy STRATEGY   Verification strategy:");
        writeln("                          hash (default) - Fast content hash");
        writeln("                          bitwise - Bit-for-bit comparison");
        writeln("                          fuzzy - Ignore metadata");
        writeln("                          structural - Compare structure");
        writeln("  -h, --help            Show this help");
        writeln();
        writeln("Examples:");
        writeln("  bldr verify //main:app");
        writeln("  bldr verify //main:app --iterations 5");
        writeln("  bldr verify //main:app --quick");
        writeln("  bldr verify //main:app --strict --strategy bitwise");
    }
}

