module frontend.testframework.reporter;

import std.stdio;
import std.format : format;
import std.algorithm : map, filter;
import std.array : array, join, replicate, split;
import std.conv : to;
import std.string : strip;
import std.range : empty;
import std.datetime : Duration;
import frontend.testframework.results;
import frontend.cli.control.terminal;
import frontend.cli.display.format : Formatter;
import infrastructure.utils.logging;

/// Test result reporting
class TestReporter
{
    private Terminal terminal;
    private Formatter formatter;
    private bool useColor;
    private bool verbose;
    
    this(Terminal terminal, Formatter formatter, bool verbose = false) @system
    {
        this.terminal = terminal;
        this.formatter = formatter;
        this.useColor = terminal.capabilities.supportsColor;
        this.verbose = verbose;
    }
    
    /// Report test execution start
    void reportStart(size_t targetCount) @system
    {
        terminal.writeln();
        terminal.writeln(formatHeader("Running Tests"));
        terminal.writeln(format("Found %d test target(s)", targetCount));
        terminal.writeln();
        terminal.flush();
    }
    
    /// Report individual test result
    void reportTest(const TestResult result) @system
    {
        if (result.passed)
        {
            if (verbose)
            {
                terminal.writeln(formatSuccess("✓") ~ " " ~ result.targetId ~ 
                    formatDuration(result.duration) ~ formatCached(result.cached));
                
                if (!result.cases.empty && verbose)
                {
                    foreach (tc; result.cases)
                    {
                        terminal.writeln("  " ~ formatSuccess("✓") ~ " " ~ tc.name);
                    }
                }
            }
            else
            {
                terminal.write(formatSuccess("."));
            }
        }
        else
        {
            terminal.writeln();
            terminal.writeln(formatError("✗") ~ " " ~ result.targetId ~ 
                formatDuration(result.duration));
            
            if (!result.errorMessage.empty)
            {
                terminal.writeln("  Error: " ~ formatError(result.errorMessage));
            }
            
            if (!result.cases.empty)
            {
                auto failed = result.cases.filter!(c => !c.passed).array;
                foreach (tc; failed)
                {
                    terminal.writeln("  " ~ formatError("✗") ~ " " ~ tc.name);
                    if (!tc.failureMessage.empty)
                    {
                        terminal.writeln("    " ~ tc.failureMessage);
                    }
                }
            }
            
            if (!result.stderr.empty && verbose)
            {
                terminal.writeln("  stderr:");
                foreach (line; result.stderr.split("\n"))
                {
                    if (!line.strip().empty)
                        terminal.writeln("    " ~ line);
                }
            }
        }
        
        terminal.flush();
    }
    
    /// Report final summary
    void reportSummary(const TestStats stats) @system
    {
        terminal.writeln();
        terminal.writeln();
        terminal.writeln(formatHeader("Test Summary"));
        terminal.writeln();
        
        // Targets
        terminal.writeln(format("Test Targets:  %d", stats.totalTargets));
        terminal.writeln(format("  %s  %d", formatSuccess("Passed:"), stats.passedTargets));
        
        if (stats.failedTargets > 0)
        {
            terminal.writeln(format("  %s  %d", formatError("Failed:"), stats.failedTargets));
        }
        
        if (stats.cachedTargets > 0)
        {
            terminal.writeln(format("  %s %d", formatInfo("Cached:"), stats.cachedTargets));
        }
        
        // Cases (if available)
        if (stats.totalCases > 0)
        {
            terminal.writeln();
            terminal.writeln(format("Test Cases:    %d", stats.totalCases));
            terminal.writeln(format("  %s  %d", formatSuccess("Passed:"), stats.passedCases));
            
            if (stats.failedCases > 0)
            {
                terminal.writeln(format("  %s  %d", formatError("Failed:"), stats.failedCases));
            }
        }
        
        // Timing
        terminal.writeln();
        terminal.writeln(format("Duration:      %s", formatDuration(stats.totalDuration)));
        
        // Final status
        terminal.writeln();
        if (stats.allPassed)
        {
            terminal.writeln(formatSuccess("All tests passed!"));
        }
        else
        {
            terminal.writeln(formatError("Tests failed!"));
        }
        
        terminal.writeln();
        terminal.flush();
    }
    
    /// Report test failure details
    void reportFailures(const TestResult[] results) @system
    {
        auto failures = results.filter!(r => !r.passed).array;
        
        if (failures.empty)
            return;
        
        terminal.writeln();
        terminal.writeln(formatHeader("Failed Tests"));
        terminal.writeln();
        
        foreach (result; failures)
        {
            terminal.writeln(formatError("✗ " ~ result.targetId));
            
            if (!result.errorMessage.empty)
            {
                terminal.writeln("  " ~ result.errorMessage);
            }
            
            if (!result.cases.empty)
            {
                auto failedCases = result.cases.filter!(c => !c.passed).array;
                foreach (tc; failedCases)
                {
                    terminal.writeln("  • " ~ tc.name);
                    if (!tc.failureMessage.empty)
                    {
                        terminal.writeln("    " ~ tc.failureMessage);
                    }
                }
            }
            
            terminal.writeln();
        }
        
        terminal.flush();
    }
    
    // Formatting helpers
    
    private string formatHeader(string text) @system
    {
        if (!useColor)
            return "=== " ~ text ~ " ===";
        return "\x1b[1;36m=== " ~ text ~ " ===\x1b[0m";
    }
    
    private string formatSuccess(string text) @system
    {
        if (!useColor)
            return text;
        return "\x1b[32m" ~ text ~ "\x1b[0m";
    }
    
    private string formatError(string text) @system
    {
        if (!useColor)
            return text;
        return "\x1b[31m" ~ text ~ "\x1b[0m";
    }
    
    private string formatInfo(string text) @system
    {
        if (!useColor)
            return text;
        return "\x1b[33m" ~ text ~ "\x1b[0m";
    }
    
    private string formatDuration(Duration dur) @system
    {
        immutable ms = dur.total!"msecs";
        if (ms < 1000)
            return format(" (%d ms)", ms);
        else
            return format(" (%.2f s)", ms / 1000.0);
    }
    
    private string formatCached(bool cached) @system
    {
        if (!cached)
            return "";
        return formatInfo(" [cached]");
    }
}

