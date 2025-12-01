module tests.runner;

import std.stdio;
import std.algorithm;
import std.array;
import std.conv;
import std.getopt;
import std.path;
import std.file;
import std.parallelism;
import std.datetime.stopwatch;
import core.runtime;
import tests.harness;

/// Test runner configuration
struct RunConfig
{
    bool verbose;
    bool parallel;
    string filter;
    size_t workers;
}

/// Main test runner
class TestRunner
{
    private RunConfig config;
    private TestHarness harness;
    
    this(RunConfig config)
    {
        this.config = config;
        this.harness = new TestHarness();
    }
    
    /// Run all tests
    int run()
    {
        writeln("\x1b[36m╔════════════════════════════════════════════════════════════════╗\x1b[0m");
        writeln("\x1b[36m║                    BUILDER TEST SUITE                          ║\x1b[0m");
        writeln("\x1b[36m╚════════════════════════════════════════════════════════════════╝\x1b[0m");
        writeln();
        
        if (config.verbose)
        {
            writeln("Configuration:");
            writeln("  Verbose:  ", config.verbose);
            writeln("  Parallel: ", config.parallel);
            writeln("  Filter:   ", config.filter.empty ? "none" : config.filter);
            writeln("  Workers:  ", config.workers);
            writeln();
        }
        
        harness.begin();
        
        // Run D's built-in unittests
        auto result = runModuleUnitTests();
        
        harness.printResults(config.verbose);
        
        return result ? 0 : 1;
    }
    
    /// Run built-in unittest blocks
    private bool runModuleUnitTests()
    {
        // D's unittest blocks run automatically when compiled with -unittest
        // The druntime handles unittest execution before main() is called
        
        writeln("\x1b[36m[INFO]\x1b[0m Running built-in unittest blocks...\n");
        
        // The actual unittests run automatically via druntime
        // We can extend this with custom test discovery later
        
        return true;
    }
}

/// Parse command line arguments
RunConfig parseArgs(string[] args)
{
    RunConfig config;
    config.workers = totalCPUs;
    
    auto helpInfo = getopt(
        args,
        "verbose|v", "Enable verbose output", &config.verbose,
        "parallel|p", "Run tests in parallel", &config.parallel,
        "filter|f", "Filter tests by name", &config.filter,
        "workers|w", "Number of parallel workers", &config.workers
    );
    
    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Builder Test Runner\n\nUsage:", helpInfo.options);
        throw new Exception("Help requested");
    }
    
    return config;
}

/// Main entry point
int main(string[] args)
{
    try
    {
        auto config = parseArgs(args);
        auto runner = new TestRunner(config);
        return runner.run();
    }
    catch (Exception e)
    {
        if (e.msg != "Help requested")
            stderr.writeln("\x1b[31m[ERROR]\x1b[0m ", e.msg);
        return 1;
    }
}

