module builder_entry;

import core.stdc.stdlib : exit;
import std.stdio;
import std.getopt;
import std.algorithm;
import std.array;
import std.conv;
import engine.graph;
import engine.runtime.core.engine;
import engine.runtime.services;
import engine.runtime.shutdown.shutdown;
import infrastructure.telemetry;
import infrastructure.config.parsing.parser;
import infrastructure.config.schema.schema : EconomicsConfig;
import infrastructure.analysis.inference.analyzer;
import infrastructure.utils.logging.logger;
import infrastructure.utils.simd;
import infrastructure.errors;
import frontend.cli;
import frontend.cli.commands;
import frontend.cli.display.render : parseRenderMode;
import infrastructure.tools;

extern(C) int c_run_builder(int argc, char** argv)
{
    import core.runtime;
    import std.string : fromStringz;
    
    // Initialize D runtime
    try {
        if (!rt_init()) {
            return 1;
        }
    } catch (Throwable) {
        return 1;
    }
    
    scope(exit) rt_term();
    
    string[] args;
    for (int i = 0; i < argc; i++)
    {
        args ~= argv[i].fromStringz().idup;
    }
    
    return runBuilder(args);
}

int runBuilder(string[] args)
{
    // Install signal handlers for graceful shutdown on SIGINT/SIGTERM
    installSignalHandlers();
    
    // SIMD now auto-initializes on first use (see utils.simd.dispatch)
    Logger.initialize();
    
    // Show SIMD capabilities banner on startup (except for quiet commands)
    import infrastructure.utils.simd.detection : CPU;
    immutable bool isQuietCommand = args.length >= 2 && 
        (args[1] == "version" || args[1] == "help" || args.canFind("--help") || args.canFind("--cpu-info"));
    immutable bool isVerboseMode = args.canFind("--verbose") || args.canFind("-v") || 
        args.canFind("--mode=verbose");
    
    if (!isQuietCommand) {
        if (isVerboseMode) {
            CPU.printBanner();
        } else {
            CPU.printCompactBanner();
        }
    }
    
    string command = "build";
    string target = "";
    bool verbose = false;
    bool showGraph = false;
    bool showVersion = false;
    bool showCpuInfo = false;
    string mode = "auto"; // CLI render mode
    bool watch = false;
    bool clearScreen = true;
    long debounceMs = 300;
    bool remoteExecution = false;
    
    // Economic optimization flags
    float budget = float.infinity;
    float timeLimit = float.infinity;
    string optimize = "";
    
    auto helpInfo = getopt(
        args,
        "verbose|v", "Enable verbose output", &verbose,
        "graph|g", "Show dependency graph", &showGraph,
        "mode|m", "CLI mode: auto, interactive, plain, verbose, quiet", &mode,
        "version", "Show version information", &showVersion,
        "cpu-info", "Show detailed CPU and SIMD information", &showCpuInfo,
        "watch|w", "Watch mode - rebuild on file changes", &watch,
        "clear", "Clear screen between builds in watch mode", &clearScreen,
        "debounce", "Debounce delay in milliseconds for watch mode", &debounceMs,
        "remote", "Enable remote execution on worker pool", &remoteExecution,
        "budget", "Maximum budget in USD (e.g., --budget=5.00)", &budget,
        "time-limit", "Maximum time limit in seconds (e.g., --time-limit=120)", &timeLimit,
        "optimize", "Optimization mode: cost, time, balanced", &optimize
    );
    
    if (showVersion)
    {
        writeln("Builder version 1.0.6");
        writeln("High-performance build system for mixed-language monorepos");
        return 0;
    }
    
    if (showCpuInfo)
    {
        CPU.printBanner();
        return 0;
    }
    
    if (helpInfo.helpWanted || args.length < 2)
    {
        HelpCommand.execute();
        return 0;
    }
    
    command = args[1];
    if (args.length > 2)
        target = args[2];
    
    Logger.setVerbose(verbose);
    
    try
    {
        switch (command)
        {
            case "build":
                if (watch)
                {
                    watchCommand(target, clearScreen, showGraph, mode, verbose, debounceMs, remoteExecution);
                }
                else
                {
                    // Configure economics if specified
                    import infrastructure.config.schema.schema : EconomicsConfig;
                    EconomicsConfig econConfig;
                    
                    if (budget != float.infinity || timeLimit != float.infinity || optimize.length > 0)
                    {
                        econConfig.enabled = true;
                        econConfig.budgetUSD = budget;
                        econConfig.timeLimit = timeLimit;
                        if (optimize.length > 0)
                            econConfig.optimize = optimize;
                        
                        Logger.info("Cost optimization enabled");
                        if (budget != float.infinity)
                            Logger.info("  Budget constraint: $" ~ budget.to!string);
                        if (timeLimit != float.infinity)
                            Logger.info("  Time limit: " ~ timeLimit.to!string ~ "s");
                        if (optimize.length > 0)
                            Logger.info("  Optimization mode: " ~ optimize);
                    }
                    
                    buildCommand(target, showGraph, mode, remoteExecution, econConfig);
                }
                break;
            case "test":
                return TestCommand.execute(args);
            case "watch":
                watchCommand(target, clearScreen, showGraph, mode, verbose, debounceMs);
                break;
            case "clean":
                cleanCommand();
                break;
            case "graph":
                graphCommand(target);
                break;
            case "init":
                InitCommand.execute();
                break;
            case "infer":
                InferCommand.execute();
                break;
            case "wizard":
                WizardCommand.execute();
                break;
            case "migrate":
                return MigrateCommand.execute(args);
            case "resume":
                resumeCommand(mode);
                break;
            case "install-extension":
                installExtensionCommand();
                break;
            case "query":
                if (args.length < 3)
                {
                    Logger.error("Query expression required");
                    Logger.info("Usage: builder query '<expression>' [--format=pretty|list|json|dot]");
                    Logger.info("Example: builder query 'deps(//...)'");
                    Logger.info("         builder query 'rdeps(//lib:utils)' --format=json");
                }
                else
                {
                    // Parse format flag if present
                    string outputFormat = "pretty";
                    foreach (arg; args[3 .. $])
                    {
                        if (arg.startsWith("--format="))
                        {
                            outputFormat = arg[9 .. $];
                            break;
                        }
                    }
                    QueryCommand.execute(args[2], outputFormat);
                }
                break;
            case "verify":
            case "verify-determinism":
                return VerifyCommand.execute(args);
            case "telemetry":
                auto subcommand = args.length > 2 ? args[2] : "summary";
                TelemetryCommand.execute(subcommand);
                break;
            case "cache-server":
                CacheServerCommand.execute(args[1 .. $]);
                break;
            case "coordinator":
                coordinatorCommand(args[2 .. $]);
                break;
            case "worker":
                workerCommand(args[2 .. $]);
                break;
            case "plugin":
                PluginCommand.execute(args[1 .. $]);
                break;
            case "help":
                auto helpCommand = args.length > 2 ? args[2] : "";
                HelpCommand.execute(helpCommand);
                break;
            case "explain":
                ExplainCommand.execute(args);
                break;
            case "version":
                writeln("Builder version 1.0.6");
                writeln("High-performance build system for mixed-language monorepos");
                break;
            default:
                Logger.error("Unknown command: " ~ command);
                HelpCommand.execute();
        }
    }
    catch (Exception e)
    {
        Logger.error("Build failed: " ~ e.msg);
        return 1;
    }
    return 0;
}

/// Build command handler (refactored to use dependency injection)
void buildCommand(
    in string target,
    in bool showGraph,
    in string modeStr,
    in bool remoteExecution = false,
    EconomicsConfig econConfig = EconomicsConfig.init
) @system
{
    
    Logger.info("Starting build...");
    
    if (remoteExecution)
    {
        Logger.info("Remote execution enabled");
    }
    
    // Parse configuration with error handling
    auto configResult = ConfigParser.parseWorkspace(".");
    if (configResult.isErr)
    {
        Logger.error("Failed to parse workspace configuration");
        import infrastructure.errors.formatting.format : format;
        Logger.error(format(configResult.unwrapErr()));
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    auto config = configResult.unwrap();
    Logger.info("Found " ~ config.targets.length.to!string ~ " targets");
    
    // Configure economics if provided
    if (econConfig.enabled)
    {
        config.options.economics = econConfig;
    }
    
    // Configure remote execution if enabled
    if (remoteExecution)
    {
        config.options.distributed.remoteExecution = true;
        // Set defaults from environment or use sensible defaults
        import std.process : environment;
        if (config.options.distributed.coordinatorUrl.length == 0)
        {
            config.options.distributed.coordinatorUrl = 
                environment.get("BUILDER_COORDINATOR_URL", "http://localhost:9000");
        }
        if (config.options.distributed.artifactStoreUrl.length == 0)
        {
            config.options.distributed.artifactStoreUrl =
                environment.get("BUILDER_ARTIFACT_STORE_URL", "http://localhost:8080");
        }
    }
    
    // Create services with dependency injection
    auto services = new BuildServices(config, config.options);
    
    // Shutdown coordinator automatically registered in BuildServices
    
    // Set render mode
    immutable renderMode = parseRenderMode(modeStr);
    services.setRenderMode(renderMode);
    auto renderer = services.getRenderer();
    
    // Analyze dependencies
    auto graphResult = services.analyzer.analyze(target);
    if (graphResult.isErr)
    {
        Logger.error("Failed to analyze dependencies");
        import infrastructure.errors.formatting.format : format;
        Logger.error(format(graphResult.unwrapErr()));
        import core.stdc.stdlib : exit;
        exit(1);
    }
    auto graph = graphResult.unwrap();
    
    if (showGraph)
    {
        Logger.info("\nDependency Graph:");
        graph.print();
    }
    
    // Compute optimal build plan if economics enabled
    size_t maxParallelism = 0;  // Default: auto-detect
    bool useWorkStealing = false;
    bool useRemoteExecution = false;
    
    if (econConfig.enabled && services.economics !is null)
    {
        auto planResult = services.economics.computePlan(graph, econConfig);
        if (planResult.isErr)
        {
            Logger.warning("Failed to compute optimal plan: " ~ 
                         planResult.unwrapErr().message());
            Logger.info("Falling back to default strategy");
        }
        else
        {
            import engine.economics.strategies : ExecutionStrategy;
            
            auto plan = planResult.unwrap();
            services.economics.displayPlan(plan);
            
            // Apply plan to execution strategy
            final switch (plan.strategy.strategy)
            {
                case ExecutionStrategy.Local:
                    maxParallelism = plan.strategy.cores;
                    Logger.info("Using local execution with " ~ maxParallelism.to!string ~ " cores");
                    break;
                    
                case ExecutionStrategy.Cached:
                    // Cache-optimized: minimal parallel overhead
                    maxParallelism = 4;
                    Logger.info("Using cache-optimized execution");
                    break;
                    
                case ExecutionStrategy.Distributed:
                    maxParallelism = plan.strategy.workers * plan.strategy.cores;
                    useWorkStealing = true;  // Better for distributed workloads
                    useRemoteExecution = true;
                    Logger.info("Using distributed execution: " ~ 
                              plan.strategy.workers.to!string ~ " workers × " ~
                              plan.strategy.cores.to!string ~ " cores = " ~
                              maxParallelism.to!string ~ " total cores");
                    break;
                    
                case ExecutionStrategy.Premium:
                    maxParallelism = plan.strategy.workers * plan.strategy.cores;
                    useWorkStealing = true;
                    useRemoteExecution = true;
                    Logger.info("Using premium execution: " ~ 
                              plan.strategy.workers.to!string ~ " premium workers × " ~
                              plan.strategy.cores.to!string ~ " cores = " ~
                              maxParallelism.to!string ~ " total cores");
                    break;
            }
        }
    }
    
    // Execute build with modern service-based architecture
    auto engine = services.createEngine(graph, maxParallelism, true, true, useWorkStealing);
    bool success = engine.execute();
    engine.shutdown();
    
    // Cleanup and persist telemetry
    services.shutdown();
    
    // Shutdown economics and display cost summary
    if (econConfig.enabled && services.economics !is null)
    {
        auto shutdownResult = services.economics.shutdown();
        if (shutdownResult.isErr)
        {
            Logger.warning("Failed to save cost history: " ~
                         shutdownResult.unwrapErr().message());
        }
    }
    
    // Report final status
    if (success)
    {
        Logger.success("Build completed successfully!");
    }
    else
    {
        Logger.error("Build failed!");
        import core.stdc.stdlib : exit;
        exit(1);
    }
}

/// Clean command handler - removes build artifacts and cache
/// 
/// Safety: This function is @system because:
/// 1. exists() and rmdirRecurse() are file system operations (inherently @system)
/// 2. Hardcoded directory names prevent path traversal
/// 3. Checks existence before attempting deletion
/// 4. rmdirRecurse is safe for non-existent paths
/// 
/// Invariants:
/// - Only removes .builder-cache and bin directories
/// - No user-provided paths (prevents injection)
/// - Existence checked before deletion
/// 
/// What could go wrong:
/// - Permission denied: exception thrown (safe failure)
/// - Directory in use: exception thrown (safe failure)
/// - Hardcoded paths ensure no accidental deletion of user data
void cleanCommand() @system
{
    Logger.info("Cleaning build cache...");
    
    import std.file : rmdirRecurse, exists;
    
    if (exists(".builder-cache"))
        rmdirRecurse(".builder-cache");
    
    if (exists("bin"))
        rmdirRecurse("bin");
    
    Logger.success("Clean completed!");
}

/// Graph command handler - visualizes dependency graph (refactored with DI)
void graphCommand(in string target) @system
{
    import core.stdc.signal : signal, SIGSEGV, SIGABRT;
    import core.stdc.stdlib : exit;
    
    Logger.info("Analyzing dependency graph...");
    
    try
    {
        // Parse configuration with error handling
        auto configResult = ConfigParser.parseWorkspace(".");
        if (configResult.isErr)
        {
            Logger.error("Failed to parse workspace configuration");
            import infrastructure.errors.formatting.format : format;
            Logger.error(format(configResult.unwrapErr()));
            exit(1);
        }
        
        auto config = configResult.unwrap();
        
        // Validate configuration has targets
        if (config.targets.length == 0)
        {
            Logger.warning("No targets found in workspace configuration");
            return;
        }
        
        // Create services (lightweight for analysis-only operation)
        auto services = new BuildServices(config, config.options);
        
        // Shutdown coordinator automatically registered in BuildServices
        
        // Analyze with error recovery
        auto graphResult = services.analyzer.analyze(target);
        if (graphResult.isErr)
        {
            Logger.error("Failed to analyze dependencies: " ~ format(graphResult.unwrapErr()));
            import core.stdc.stdlib : exit;
            exit(1);
        }
        auto graph = graphResult.unwrap();
        
        // Print with error handling
        graph.print();
    }
    catch (Exception e)
    {
        Logger.error("Fatal error during graph analysis: " ~ e.msg);
        Logger.error("Stack trace:");
        Logger.error(e.toString());
        Logger.error("\nThis is a bug in Builder. Please report it at:");
        Logger.error("https://github.com/GriffinCanCode/Builder/issues");
        exit(1);
    }
    catch (Error e)
    {
        Logger.error("Critical error (segfault/assertion failure): " ~ e.msg);
        Logger.error("Stack trace:");
        Logger.error(e.toString());
        Logger.error("\nThis is a critical bug in Builder. Please report it at:");
        Logger.error("https://github.com/GriffinCanCode/Builder/issues");
        exit(139); // SIGSEGV exit code
    }
}

/// Resume command handler - continues build from checkpoint (refactored with DI)
void resumeCommand(in string modeStr) @system
{
    import engine.runtime.recovery.checkpoint : CheckpointManager;
    import engine.runtime.recovery.resume : ResumePlanner, ResumeConfig;
    
    Logger.info("Checking for build checkpoint...");
    
    auto checkpointManager = new CheckpointManager(".", true);
    
    if (!checkpointManager.exists())
    {
        Logger.error("No checkpoint found. Run 'builder build' first.");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    auto checkpointResult = checkpointManager.load();
    if (checkpointResult.isErr)
    {
        Logger.error("Failed to load checkpoint: " ~ checkpointResult.unwrapErr());
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    auto checkpoint = checkpointResult.unwrap();
    Logger.info("Found checkpoint from " ~ checkpoint.timestamp.toSimpleString());
    Logger.info("Progress: " ~ checkpoint.completedTargets.to!string ~ "/" ~ 
               checkpoint.totalTargets.to!string ~ " targets (" ~ 
               checkpoint.completion().to!string[0..min(5, checkpoint.completion().to!string.length)] ~ "%)");
    
    if (checkpoint.failedTargets > 0)
    {
        Logger.info("Failed targets:");
        foreach (target; checkpoint.failedTargetIds)
            Logger.error("  - " ~ target);
    }
    
    writeln();
    
    // Parse configuration
    auto configResult = ConfigParser.parseWorkspace(".");
    if (configResult.isErr)
    {
        Logger.error("Failed to parse workspace configuration");
        import infrastructure.errors.formatting.format : format;
        Logger.error(format(configResult.unwrapErr()));
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    auto config = configResult.unwrap();
    
    // Create services with dependency injection
    auto services = new BuildServices(config, config.options);
    
    // Shutdown coordinator automatically registered in BuildServices
    
    // Set render mode
    immutable renderMode = parseRenderMode(modeStr);
    services.setRenderMode(renderMode);
    auto renderer = services.getRenderer();
    
    // Rebuild graph
        auto graphResult = services.analyzer.analyze("");
        if (graphResult.isErr)
        {
            Logger.error("Failed to analyze dependencies: " ~ format(graphResult.unwrapErr()));
            import core.stdc.stdlib : exit;
            exit(1);
        }
        auto graph = graphResult.unwrap();
    
    // Validate checkpoint
    if (!checkpoint.isValid(graph))
    {
        Logger.error("Checkpoint invalid for current project state. Run 'builder clean' and rebuild.");
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    Logger.info("Resuming build...");
    
    // Execute build with modern service-based architecture
    auto engine = services.createEngine(graph);
    engine.execute();
    engine.shutdown();
    
    // Cleanup and persist telemetry
    services.shutdown();
    
    Logger.success("Build resumed and completed successfully!");
}

/// Install VS Code extension command
/// 
/// Safety: This function is @system because:
/// 1. VSCodeExtension.install() performs validated file I/O
/// 2. Extension installation uses verified paths
/// 3. Process execution for VS Code CLI is validated
/// 4. Installation is handled atomically by VSCodeExtension
/// 
/// Invariants:
/// - Extension files are verified before installation
/// - VS Code presence is detected before attempting install
/// - Installation errors are reported via exceptions
/// 
/// What could go wrong:
/// - VS Code not installed: detected by VSCodeExtension
/// - Permission denied: exception thrown and caught
/// - Extension files missing: validated before install
void installExtensionCommand() @system
{
    VSCodeExtension.install();
}

/// Watch command handler - continuously watches for file changes and rebuilds
void watchCommand(
    in string target,
    in bool clearScreen,
    in bool showGraph,
    in string modeStr,
    in bool verbose,
    in long debounceMs,
    in bool remoteExecution = false) @system
{
    WatchCommand.execute(target, clearScreen, showGraph, modeStr, verbose, debounceMs);
}

