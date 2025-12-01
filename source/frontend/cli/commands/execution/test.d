module frontend.cli.commands.execution.test;

import std.stdio;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.algorithm : filter, map;
import std.array : array;
import std.range : empty;
import std.conv : to;
import std.string : strip, startsWith;
import infrastructure.config.parsing.parser;
import infrastructure.config.schema.schema;
import engine.graph;
import engine.runtime.services;
import frontend.testframework;
import frontend.testframework.config;
import frontend.testframework.execution;
import frontend.testframework.analytics;
import engine.runtime.shutdown.shutdown;
import infrastructure.utils.logging.logger;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.errors;

/// Test command - runs test targets with reporting
struct TestCommand
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
    
    /// Execute test command
    static int execute(string[] args) @system
    {
        init();
        
        // Load configuration from .buildertest (if exists)
        auto testConfig = BuilderTestConfig.load();
        
        // Parse command-line arguments (override config file)
        string targetSpec = "";
        string renderMode = "auto";
        bool initConfig = false;
        
        size_t i = 1; // Skip "test" command itself
        while (i < args.length)
        {
            immutable arg = args[i];
            
            if (arg == "--verbose" || arg == "-v")
            {
                testConfig.verbose = true;
                i++;
            }
            else if (arg == "--quiet" || arg == "-q")
            {
                testConfig.verbose = false;
                i++;
            }
            else if (arg == "--show-passed")
            {
                testConfig.showPassed = true;
                i++;
            }
            else if (arg == "--fail-fast")
            {
                testConfig.failFast = true;
                i++;
            }
            else if (arg == "--filter" && i + 1 < args.length)
            {
                // Legacy filter support
                i += 2;
            }
            else if (arg == "--jobs" || arg == "-j" && i + 1 < args.length)
            {
                testConfig.jobs = args[i + 1].to!size_t;
                i += 2;
            }
            else if (arg == "--shards" && i + 1 < args.length)
            {
                testConfig.shardCount = args[i + 1].to!size_t;
                i += 2;
            }
            else if (arg == "--no-shard")
            {
                testConfig.shard = false;
                i++;
            }
            else if (arg == "--no-cache")
            {
                testConfig.cache = false;
                i++;
            }
            else if (arg == "--no-retry")
            {
                testConfig.retry = false;
                i++;
            }
            else if (arg == "--max-retries" && i + 1 < args.length)
            {
                testConfig.maxRetries = args[i + 1].to!size_t;
                i += 2;
            }
            else if (arg == "--analytics")
            {
                testConfig.analytics = true;
                i++;
            }
            else if (arg == "--junit")
            {
                testConfig.junit = true;
                if (i + 1 < args.length && !args[i + 1].startsWith("--"))
                {
                    testConfig.junitPath = args[i + 1];
                    i += 2;
                }
                else
                {
                    i++;
                }
            }
            else if (arg == "--init-config")
            {
                initConfig = true;
                i++;
            }
            else if (arg == "--mode" && i + 1 < args.length)
            {
                renderMode = args[i + 1];
                i += 2;
            }
            else if (arg == "--help" || arg == "-h")
            {
                showHelp();
                return 0;
            }
            else if (!arg.startsWith("--"))
            {
                targetSpec = arg;
                i++;
            }
            else
            {
                Logger.error("Unknown option: " ~ arg);
                showHelp();
                return 1;
            }
        }
        
        // Handle --init-config
        if (initConfig)
        {
            return initializeConfig();
        }
        
        // Run tests
        return runTests(targetSpec, testConfig, renderMode);
    }
    
    /// Initialize .buildertest configuration file
    private static int initializeConfig() @system
    {
        import std.file : write, exists;
        
        if (exists(".buildertest"))
        {
            terminal.writeln("Error: .buildertest already exists");
            return 1;
        }
        
        auto example = BuilderTestConfig.generateExample();
        write(".buildertest", example);
        
        terminal.writeln("Created .buildertest configuration file");
        terminal.writeln("Edit this file to customize your test settings");
        return 0;
    }
    
    /// Run tests with configuration
    private static int runTests(string targetSpec, BuilderTestConfig config, string renderMode) @system
    {
        auto sw = StopWatch(AutoStart.yes);
        
        Logger.info("Discovering tests...");
        
        // Parse workspace configuration
        auto configResult = ConfigParser.parseWorkspace(".");
        if (configResult.isErr)
        {
            Logger.error("Failed to parse workspace configuration");
            import infrastructure.errors.formatting.format : format;
            Logger.error(format(configResult.unwrapErr()));
            return 1;
        }
        
        auto wsConfig = configResult.unwrap();
        
        // Discover test targets
        auto discovery = new TestDiscovery(wsConfig);
        Target[] testTargets;
        
        if (!targetSpec.empty)
        {
            testTargets = discovery.findByTarget(targetSpec);
        }
        else
        {
            testTargets = discovery.findAll();
        }
        
        if (testTargets.empty)
        {
            Logger.warning("No test targets found");
            if (!targetSpec.empty)
                Logger.info("Target specification: " ~ targetSpec);
            return 0;
        }
        
        Logger.info("Found " ~ testTargets.length.to!string ~ " test targets");
        
        // Create services
        auto services = new BuildServices(wsConfig, wsConfig.options);
        
        // Shutdown coordinator automatically registered in BuildServices
        
        // Set render mode
        import frontend.cli.display.render : parseRenderMode;
        immutable rm = parseRenderMode(renderMode);
        services.setRenderMode(rm);
        
        // Create test executor with config
        auto execConfig = config.toExecutionConfig();
        auto executor = new TestExecutor(execConfig);
        
        // Create reporter
        auto reporter = new TestReporter(terminal, formatter, config.verbose);
        reporter.reportStart(testTargets.length);
        
        // Execute tests
        auto results = executor.execute(testTargets, wsConfig, services);
        
        // Report results
        foreach (result; results)
        {
            reporter.reportTest(result);
            
            if (!result.passed && config.failFast)
            {
                Logger.info("Stopping due to --fail-fast");
                break;
            }
        }
        
        // Compute statistics
        immutable stats = TestStats.compute(results);
        
        // Report summary
        reporter.reportSummary(stats);
        
        // Generate analytics if enabled
        if (config.analytics)
        {
            generateAnalytics(results, stats, executor);
        }
        
        // Export JUnit XML if requested
        if (config.junit)
        {
            try
            {
                exportJUnit(results, config.junitPath);
                Logger.info("JUnit XML exported to: " ~ config.junitPath);
            }
            catch (Exception e)
            {
                Logger.warning("Failed to export JUnit XML: " ~ e.msg);
            }
        }
        
        // Cleanup
        executor.shutdown();
        services.shutdown();
        
        sw.stop();
        
        Logger.info("Total execution time: " ~ sw.peek().total!"msecs".to!string ~ "ms");
        
        // Return exit code
        return stats.allPassed ? 0 : 1;
    }
    
    /// Generate test analytics
    private static void generateAnalytics(TestResult[] results, TestStats stats, TestExecutor executor) @system
    {
        try
        {
            import std.array : replicate;
            Logger.info("\n" ~ "═".replicate(60));
            Logger.info("Test Analytics Report");
            Logger.info("═".replicate(60));
            
            // Get flaky records from detector
            FlakyRecord[] flakyRecords;
            if (executor.flakyDetector !is null)
            {
                flakyRecords = executor.flakyDetector.getFlakyTests();
            }
            
            auto health = TestAnalytics.analyzeHealth(results, flakyRecords);
            auto performance = TestAnalytics.analyzePerformance(results);
            auto report = TestAnalytics.generateReport(stats, health, performance);
            
            Logger.info("\n" ~ report);
        }
        catch (Exception e)
        {
            Logger.warning("Failed to generate analytics: " ~ e.msg);
        }
    }
    
    /// Show help for test command
    private static void showHelp() @system
    {
        terminal.writeln();
        terminal.writeln("Usage: bldr test [OPTIONS] [TARGET]");
        terminal.writeln();
        terminal.writeln("Run test targets with advanced features.");
        terminal.writeln();
        terminal.writeln("Configuration:");
        terminal.writeln("  --init-config         Create .buildertest configuration file");
        terminal.writeln();
        terminal.writeln("Basic Options:");
        terminal.writeln("  -v, --verbose         Show detailed output");
        terminal.writeln("  -q, --quiet           Minimal output");
        terminal.writeln("  --show-passed         Show passed tests");
        terminal.writeln("  --fail-fast           Stop on first failure");
        terminal.writeln();
        terminal.writeln("Execution Options:");
        terminal.writeln("  -j, --jobs N          Number of parallel jobs (0 = auto)");
        terminal.writeln("  --shards N            Number of test shards (0 = auto)");
        terminal.writeln("  --no-shard            Disable test sharding");
        terminal.writeln();
        terminal.writeln("Caching & Retry:");
        terminal.writeln("  --no-cache            Disable test result caching");
        terminal.writeln("  --no-retry            Disable automatic retry");
        terminal.writeln("  --max-retries N       Maximum retry attempts");
        terminal.writeln();
        terminal.writeln("Output:");
        terminal.writeln("  --analytics           Generate analytics report");
        terminal.writeln("  --junit [PATH]        Generate JUnit XML report");
        terminal.writeln("  --mode MODE           Render mode: auto, interactive, plain");
        terminal.writeln();
        terminal.writeln("Examples:");
        terminal.writeln("  bldr test                    # Run all tests (uses .buildertest)");
        terminal.writeln("  bldr test --init-config      # Create configuration file");
        terminal.writeln("  bldr test -j 8 --analytics   # Run with 8 jobs + analytics");
        terminal.writeln("  bldr test --no-cache         # Run without caching");
        terminal.writeln("  bldr test //path:target      # Run specific test");
        terminal.writeln();
        terminal.writeln("Config File (.buildertest):");
        terminal.writeln("  All options can be configured in .buildertest (JSON format)");
        terminal.writeln("  Command-line flags override config file settings");
        terminal.writeln();
        terminal.flush();
    }
}

