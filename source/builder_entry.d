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
import infrastructure.utils.logging;
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
    
    // Logging auto-initializes via shared static this()
    // SIMD now auto-initializes on first use (see utils.simd.dispatch)
    
    // Show SIMD capabilities banner on startup (except for quiet commands)
    import infrastructure.utils.simd.detection : CPU;
    immutable bool isQuietCommand = args.length >= 2 && 
        (args[1] == "version" || args[1] == "help" || args.canFind("--help") || args.canFind("--cpu-info"));
    immutable bool isVerboseMode = args.canFind("--verbose") || args.canFind("-v") || 
        args.canFind("--mode=verbose");
    
    if (!isQuietCommand && isVerboseMode) {
        CPU.printBanner();
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
    
    // Performance optimization flags
    bool workStealing = true;   // Work-stealing scheduler (default: enabled)
    bool speculation = true;    // Speculative execution (default: enabled)
    size_t speculationThreshold = 10;  // Min targets for speculation
    
    // Economic optimization flags
    float budget = float.infinity;
    float timeLimit = float.infinity;
    string optimize = "";
    bool force = false;
    
    auto helpInfo = getopt(
        args,
        std.getopt.config.passThrough,  // Allow subcommand-specific flags
        "verbose|v", "Enable verbose output", &verbose,
        "graph|g", "Show dependency graph", &showGraph,
        "mode|m", "CLI mode: auto, interactive, plain, verbose, quiet", &mode,
        "version", "Show version information", &showVersion,
        "cpu-info", "Show detailed CPU and SIMD information", &showCpuInfo,
        "watch|w", "Watch mode - rebuild on file changes", &watch,
        "clear", "Clear screen between builds in watch mode", &clearScreen,
        "debounce", "Debounce delay in milliseconds for watch mode", &debounceMs,
        "remote", "Enable remote execution on worker pool", &remoteExecution,
        "work-stealing", "Work-stealing scheduler for load balancing (default: true)", &workStealing,
        "speculation", "Speculative execution for critical path (default: true)", &speculation,
        "speculation-threshold", "Min targets to enable speculation (default: 10)", &speculationThreshold,
        "budget", "Maximum budget in USD (e.g., --budget=5.00)", &budget,
        "time-limit", "Maximum time limit in seconds (e.g., --time-limit=120)", &timeLimit,
        "optimize", "Optimization mode: cost, time, balanced", &optimize,
        "force|f", "Force overwrite existing files (for init command)", &force
    );
    
    if (showVersion)
    {
        writeln("bldr version 2.0.3");
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
    
    // Verbose mode is handled through CLI flags, structured logging level is set at init
    
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
                        
                        structuredLog.info("cost_optimization_enabled").emit();
                        if (budget != float.infinity)
                            structuredLog.info("__budget_constraint_").field("detail", "  Budget constraint: $" ~ budget.to!string).emit();
                        if (timeLimit != float.infinity)
                            structuredLog.info("__time_limit_").field("detail", "  Time limit: " ~ timeLimit.to!string ~ "s").emit();
                        if (optimize.length > 0)
                            structuredLog.info("__optimization_mode_").field("detail", "  Optimization mode: " ~ optimize).emit();
                    }
                    
                    buildCommand(target, showGraph, mode, remoteExecution, econConfig, workStealing, speculation, speculationThreshold);
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
                InitCommand.execute(".", force);
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
                    structuredLog.error("query_expression_required").emit();
                    structuredLog.info("usage_bldr_query_expression_formatpretty").emit();
                    structuredLog.info("example_bldr_query_deps").emit();
                    structuredLog.info("_________bldr_query_rdepslibutils_format").emit();
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
            case "explore":
                exploreCommand(args[2 .. $]);
                break;
            case "resolve":
                // Parse flags
                string resolvePath = ".";
                string resolveFormat = "pretty";
                bool dryRun = false;
                bool updateDeps = false;
                bool prodOnly = false;
                
                foreach (i, arg; args[2 .. $])
                {
                    if (arg == "--dry-run") dryRun = true;
                    else if (arg == "--update") updateDeps = true;
                    else if (arg == "--production") prodOnly = true;
                    else if (arg.startsWith("--format=")) resolveFormat = arg[9 .. $];
                    else if (!arg.startsWith("-")) resolvePath = arg;
                }
                
                ResolveCommand.execute(resolvePath, resolveFormat, dryRun, updateDeps, prodOnly);
                break;
            case "help":
                auto helpCommand = args.length > 2 ? args[2] : "";
                HelpCommand.execute(helpCommand);
                break;
            case "explain":
                ExplainCommand.execute(args[1 .. $]);
                break;
            case "version":
                writeln("bldr version 2.0.3");
                writeln("High-performance build system for mixed-language monorepos");
                break;
            default:
                structuredLog.error("unknown_command_").field("detail", "Unknown command: " ~ command).emit();
                HelpCommand.execute();
        }
    }
    catch (Exception e)
    {
        structuredLog.error("build_failed_").field("detail", "Build failed: " ~ e.msg).emit();
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
    EconomicsConfig econConfig = EconomicsConfig.init,
    bool useWorkStealing = true,
    bool enableSpeculation = true,
    size_t speculationThreshold = 10
) @system
{
    
    structuredLog.info("starting_build").emit();
    
    if (remoteExecution)
    {
        structuredLog.debug_("remote_execution_enabled").emit();
    }
    
    // Parse configuration with error handling
    auto configResult = ConfigParser.parseWorkspace(".");
    if (configResult.isErr)
    {
        structuredLog.error("failed_to_parse_workspace_configuration").emit();
        import infrastructure.errors.formatting.format : format;
        structuredLog.error("log_event").field("message", format(configResult.unwrapErr())).emit();
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    auto config = configResult.unwrap();
    structuredLog.info("found_").field("detail", "Found " ~ config.targets.length.to!string ~ " targets").emit();
    
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
        structuredLog.error("failed_to_analyze_dependencies").emit();
        import infrastructure.errors.formatting.format : format;
        structuredLog.error("log_event").field("message", format(graphResult.unwrapErr())).emit();
        import core.stdc.stdlib : exit;
        exit(1);
    }
    auto graph = graphResult.unwrap();
    
    if (showGraph)
    {
        structuredLog.info("ndependency_graph").emit();
        graph.print();
    }
    
    // Compute optimal build plan if economics enabled
    size_t maxParallelism = 0;  // Default: auto-detect
    // Apply CLI flags to config (CLI flags override environment defaults)
    config.options.useWorkStealing = useWorkStealing;
    config.options.enableSpeculation = enableSpeculation;
    config.options.speculationThreshold = speculationThreshold;
    bool useRemoteExecution = false;
    
    // Log optimization settings
    structuredLog.debug_("build_optimizations")
        .field("work_stealing", useWorkStealing)
        .field("speculation", enableSpeculation)
        .field("speculation_threshold", speculationThreshold)
        .emit();
    
    if (econConfig.enabled && services.economics !is null)
    {
        auto planResult = services.economics.computePlan(graph, econConfig);
        if (planResult.isErr)
        {
            structuredLog.warning("failed_to_compute_optimal_plan_").field("detail", "Failed to compute optimal plan: " ~ 
                         planResult.unwrapErr().message()).emit();
            structuredLog.debug_("falling_back_to_default_strategy").emit();
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
                    structuredLog.debug_("using_local_execution_with_").field("detail", "Using local execution with " ~ maxParallelism.to!string ~ " cores").emit();
                    break;
                    
                case ExecutionStrategy.Cached:
                    // Cache-optimized: minimal parallel overhead
                    maxParallelism = 4;
                    structuredLog.debug_("using_cacheoptimized_execution").emit();
                    break;
                    
                case ExecutionStrategy.Distributed:
                    maxParallelism = plan.strategy.workers * plan.strategy.cores;
                    useWorkStealing = true;  // Better for distributed workloads
                    useRemoteExecution = true;
                    structuredLog.debug_("using_distributed_execution_").field("detail", "Using distributed execution: " ~ 
                              plan.strategy.workers.to!string ~ " workers × " ~
                              plan.strategy.cores.to!string ~ " cores = " ~
                              maxParallelism.to!string ~ " total cores").emit();
                    break;
                    
                case ExecutionStrategy.Premium:
                    maxParallelism = plan.strategy.workers * plan.strategy.cores;
                    useWorkStealing = true;
                    useRemoteExecution = true;
                    structuredLog.debug_("using_premium_execution_").field("detail", "Using premium execution: " ~ 
                              plan.strategy.workers.to!string ~ " premium workers × " ~
                              plan.strategy.cores.to!string ~ " cores = " ~
                              maxParallelism.to!string ~ " total cores").emit();
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
    
    // Cleanup config cache (checkpoint WAL)
    ConfigParser.closeConfigIndex();
    
    // Shutdown economics and display cost summary
    if (econConfig.enabled && services.economics !is null)
    {
        auto shutdownResult = services.economics.shutdown();
        if (shutdownResult.isErr)
        {
            structuredLog.warning("failed_to_save_cost_history_").field("detail", "Failed to save cost history: " ~
                         shutdownResult.unwrapErr().message()).emit();
        }
    }
    
    // Report final status
    if (success)
    {
        structuredLog.info("build_completed_successfully").emit();
    }
    else
    {
        structuredLog.error("build_failed").emit();
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
    structuredLog.info("cleaning_build_cache").emit();
    
    import std.file : rmdirRecurse, exists;
    
    if (exists(".builder-cache"))
        rmdirRecurse(".builder-cache");
    
    if (exists("bin"))
        rmdirRecurse("bin");
    
    structuredLog.info("clean_completed").emit();
}

/// Graph command handler - visualizes dependency graph (refactored with DI)
void graphCommand(in string target) @system
{
    import core.stdc.signal : signal, SIGSEGV, SIGABRT;
    import core.stdc.stdlib : exit;
    
    structuredLog.info("analyzing_dependency_graph").emit();
    
    try
    {
        // Parse configuration with error handling
        auto configResult = ConfigParser.parseWorkspace(".");
        if (configResult.isErr)
        {
            structuredLog.error("failed_to_parse_workspace_configuration").emit();
            import infrastructure.errors.formatting.format : format;
            structuredLog.error("log_event").field("message", format(configResult.unwrapErr())).emit();
            exit(1);
        }
        
        auto config = configResult.unwrap();
        
        // Validate configuration has targets
        if (config.targets.length == 0)
        {
            structuredLog.warning("no_targets_found_in_workspace_configurat").emit();
            return;
        }
        
        // Create services (lightweight for analysis-only operation)
        auto services = new BuildServices(config, config.options);
        
        // Shutdown coordinator automatically registered in BuildServices
        
        // Analyze with error recovery
        auto graphResult = services.analyzer.analyze(target);
        if (graphResult.isErr)
        {
            structuredLog.error("failed_to_analyze_dependencies_").field("detail", "Failed to analyze dependencies: " ~ format(graphResult.unwrapErr())).emit();
            import core.stdc.stdlib : exit;
            exit(1);
        }
        auto graph = graphResult.unwrap();
        
        // Print with error handling
        graph.print();
    }
    catch (Exception e)
    {
        structuredLog.error("fatal_error_during_graph_analysis_").field("detail", "Fatal error during graph analysis: " ~ e.msg).emit();
        structuredLog.error("stack_trace").emit();
        structuredLog.error("log_event").field("message", e.toString()).emit();
        structuredLog.error("nthis_is_a_bug_in_builder_please_report_").emit();
        structuredLog.error("httpsgithubcomgriffincancodebuilderissue").emit();
        exit(1);
    }
    catch (Error e)
    {
        structuredLog.error("critical_error_segfaultassertion_failure").field("detail", "Critical error (segfault/assertion failure): " ~ e.msg).emit();
        structuredLog.error("stack_trace").emit();
        structuredLog.error("log_event").field("message", e.toString()).emit();
        structuredLog.error("nthis_is_a_critical_bug_in_builder_pleas").emit();
        structuredLog.error("httpsgithubcomgriffincancodebuilderissue").emit();
        exit(139); // SIGSEGV exit code
    }
}

/// Resume command handler - continues build from checkpoint (refactored with DI)
void resumeCommand(in string modeStr) @system
{
    import engine.runtime.recovery.checkpoint : CheckpointManager;
    import engine.runtime.recovery.resume : ResumePlanner, ResumeConfig;
    
    structuredLog.info("checking_for_build_checkpoint").emit();
    
    auto checkpointManager = new CheckpointManager(".", true);
    
    if (!checkpointManager.exists())
    {
        structuredLog.error("no_checkpoint_found_run_bldr_build_first").emit();
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    auto checkpointResult = checkpointManager.load();
    if (checkpointResult.isErr)
    {
        structuredLog.error("failed_to_load_checkpoint_").field("detail", "Failed to load checkpoint: " ~ checkpointResult.unwrapErr().message()).emit();
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    auto checkpoint = checkpointResult.unwrap();
    structuredLog.info("found_checkpoint_from_").field("detail", "Found checkpoint from " ~ checkpoint.timestamp.toSimpleString()).emit();
    structuredLog.info("progress_").field("detail", "Progress: " ~ checkpoint.completedTargets.to!string ~ "/" ~ 
               checkpoint.totalTargets.to!string ~ " targets (" ~ 
               checkpoint.completion().to!string[0..min(5, checkpoint.completion().to!string.length)] ~ "%)").emit();
    
    if (checkpoint.failedTargets > 0)
    {
        structuredLog.info("failed_targets").emit();
        foreach (target; checkpoint.failedTargetIds)
            structuredLog.error("___").field("detail", "  - " ~ target).emit();
    }
    
    writeln();
    
    // Parse configuration
    auto configResult = ConfigParser.parseWorkspace(".");
    if (configResult.isErr)
    {
        structuredLog.error("failed_to_parse_workspace_configuration").emit();
        import infrastructure.errors.formatting.format : format;
        structuredLog.error("log_event").field("message", format(configResult.unwrapErr())).emit();
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
            structuredLog.error("failed_to_analyze_dependencies_").field("detail", "Failed to analyze dependencies: " ~ format(graphResult.unwrapErr())).emit();
            import core.stdc.stdlib : exit;
            exit(1);
        }
        auto graph = graphResult.unwrap();
    
    // Validate checkpoint
    if (!checkpoint.isValid(graph))
    {
        structuredLog.error("checkpoint_invalid_for_current_project_s").emit();
        import core.stdc.stdlib : exit;
        exit(1);
    }
    
    structuredLog.info("resuming_build").emit();
    
    // Execute build with modern service-based architecture
    auto engine = services.createEngine(graph);
    engine.execute();
    engine.shutdown();
    
    // Cleanup and persist telemetry
    services.shutdown();
    
    // Cleanup config cache
    ConfigParser.closeConfigIndex();
    
    structuredLog.info("build_resumed_and_completed_successfully").emit();
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

/// Explore command handler - interactive dependency graph TUI
void exploreCommand(string[] args) @system
{
    string target;
    bool criticalPath = false;
    bool nonInteractive = false;
    string cacheDir = ".builder-cache";
    
    // Parse args
    foreach (arg; args)
    {
        if (arg == "--critical") criticalPath = true;
        else if (arg == "--non-interactive") nonInteractive = true;
        else if (arg.startsWith("--cache=")) cacheDir = arg[8 .. $];
        else if (arg == "--help" || arg == "-h")
        {
            ExplorerCommand.showHelp();
            return;
        }
        else if (!arg.startsWith("-")) target = arg;
    }
    
    ExplorerCommand.execute(target, criticalPath, nonInteractive, cacheDir);
}

