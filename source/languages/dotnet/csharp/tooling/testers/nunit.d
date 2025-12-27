module languages.dotnet.csharp.tooling.testers.nunit;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import languages.dotnet.csharp.tooling.testers.base;
import languages.dotnet.csharp.config.test;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;

/// NUnit test runner
class NUnitRunner : ITestRunner
{
    override bool isAvailable()
    {
        // Check for dotnet CLI or nunit-console
        return isCommandAvailable("dotnet") || isCommandAvailable("nunit-console");
    }
    
    override string name() const
    {
        return "NUnit";
    }
    
    override TestResult runTests(in string[] testFiles, in TestConfig config, in string workingDir)
    {
        structuredLog.info("running_nunit_tests").emit();
        
        if (isCommandAvailable("dotnet")) return runWithDotnetTest(testFiles, config, workingDir);
        if (isCommandAvailable("nunit-console")) return runWithNUnitConsole(testFiles, config, workingDir);
        
        TestResult result;
        result.error = "NUnit test runner not found (install NUnit or use dotnet test)";
        return result;
    }
    
    private TestResult runWithDotnetTest(in string[] testFiles, in TestConfig config, in string workingDir)
    {
        TestResult result;
        string[] cmd = ["dotnet", "test"];
        if (!config.filter.empty) cmd ~= ["--filter", config.filter];
        if (config.noBuild) cmd ~= "--no-build";
        cmd ~= ["--logger", "trx"];
        if (!config.resultsDirectory.empty) cmd ~= ["--results-directory", config.resultsDirectory];
        cmd ~= config.args;
        
        auto execResult = execute(cmd, null, Config.none, size_t.max, workingDir);
        result.output = execResult.output;
        result.success = (execResult.status == 0);
        parseNUnitOutput(execResult.output, result);
        
        if (!result.success && result.error.empty) result.error = "NUnit tests failed";
        
        import std.format : format;
        structuredLog.info("log_event").field("message", format!"NUnit results: %d passed, %d failed, %d skipped"(result.passed, result.failed, result.skipped)).emit();
        return result;
    }
    
    private TestResult runWithNUnitConsole(in string[] testFiles, in TestConfig config, in string workingDir)
    {
        TestResult result;
        auto assemblies = findTestAssemblies(buildPath(workingDir, "bin"));
        
        if (assemblies.empty) {
            result.error = "No NUnit test assemblies found";
            return result;
        }
        
        string[] cmd = ["nunit-console"] ~ assemblies;
        if (!config.filter.empty) cmd ~= ["--where", config.filter];
        if (!config.resultsDirectory.empty) cmd ~= ["--result", buildPath(config.resultsDirectory, "TestResults.xml")];
        cmd ~= config.args;
        
        auto execResult = execute(cmd, null, Config.none, size_t.max, workingDir);
        result.output = execResult.output;
        result.success = (execResult.status == 0);
        parseNUnitConsoleOutput(execResult.output, result);
        
        if (!result.success && result.error.empty) result.error = "NUnit tests failed";
        return result;
    }
    
    private void parseNUnitOutput(string output, ref TestResult result)
    {
        try {
            import std.conv : to;
            auto passedMatch = output.matchFirst(regex(r"Passed[!:\s]+(\d+)"));
            auto failedMatch = output.matchFirst(regex(r"Failed[!:\s]+(\d+)"));
            auto skippedMatch = output.matchFirst(regex(r"Skipped[!:\s]+(\d+)"));
            
            if (!passedMatch.empty) result.passed = passedMatch[1].to!size_t;
            if (!failedMatch.empty) result.failed = failedMatch[1].to!size_t;
            if (!skippedMatch.empty) result.skipped = skippedMatch[1].to!size_t;
        } catch (Exception e) {
            structuredLog.debug_("failed_to_parse_nunit_output_").field("detail", "Failed to parse NUnit output: " ~ e.msg).emit();
        }
    }
    
    private void parseNUnitConsoleOutput(string output, ref TestResult result)
    {
        // NUnit console format: "Test Count: X, Passed: Y, Failed: Z, Warnings: W, Inconclusive: I, Skipped: S"
        try {
            import std.conv : to;
            auto passedMatch = output.matchFirst(regex(r"Passed:\s*(\d+)"));
            auto failedMatch = output.matchFirst(regex(r"Failed:\s*(\d+)"));
            auto skippedMatch = output.matchFirst(regex(r"Skipped:\s*(\d+)"));
            
            if (!passedMatch.empty) result.passed = passedMatch[1].to!size_t;
            if (!failedMatch.empty) result.failed = failedMatch[1].to!size_t;
            if (!skippedMatch.empty) result.skipped = skippedMatch[1].to!size_t;
        } catch (Exception e) {
            structuredLog.debug_("failed_to_parse_nunit_console_output_").field("detail", "Failed to parse NUnit console output: " ~ e.msg).emit();
        }
    }
}

