module languages.dotnet.csharp.tooling.testers.xunit;

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

/// xUnit test runner
class XUnitRunner : ITestRunner
{
    override bool isAvailable()
    {
        // Check for dotnet CLI (includes xunit console runner)
        return isCommandAvailable("dotnet");
    }
    
    override string name() const
    {
        return "xUnit";
    }
    
    override TestResult runTests(in string[] testFiles, in TestConfig config, in string workingDir)
    {
        TestResult result;
        structuredLog.info("running_xunit_tests").emit();
        
        // Find test assemblies - either from testFiles or output directory
        auto assemblies = testFiles.filter!(f => [".dll", ".exe"].canFind(f.extension)).array;
        if (assemblies.empty) assemblies = findTestAssemblies(buildPath(workingDir, "bin"));
        
        if (assemblies.empty) {
            result.error = "No test assemblies found for xUnit";
            return result;
        }
        
        // Build command with conditional arguments
        string[] cmd = ["dotnet", "test"];
        if (!config.filter.empty) cmd ~= ["--filter", config.filter];
        if (config.noBuild) cmd ~= "--no-build";
        cmd ~= ["--logger", "trx"];
        if (!config.resultsDirectory.empty) cmd ~= ["--results-directory", config.resultsDirectory];
        cmd ~= config.args;
        
        auto execResult = execute(cmd, null, Config.none, size_t.max, workingDir);
        result.output = execResult.output;
        result.success = (execResult.status == 0);
        parseXUnitOutput(execResult.output, result);
        
        if (!result.success && result.error.empty) result.error = "xUnit tests failed";
        
        import std.format : format;
        structuredLog.info("log_event").field("message", format!"xUnit results: %d passed, %d failed, %d skipped"(result.passed, result.failed, result.skipped)).emit();
        return result;
    }
    
    private void parseXUnitOutput(string output, ref TestResult result)
    {
        // Parse xUnit output format: "Total tests: X. Passed: Y. Failed: Z. Skipped: W."
        try {
            import std.conv : to;
            auto passedMatch = output.matchFirst(regex(r"Passed[:\s]+(\d+)"));
            auto failedMatch = output.matchFirst(regex(r"Failed[:\s]+(\d+)"));
            auto skippedMatch = output.matchFirst(regex(r"Skipped[:\s]+(\d+)"));
            
            if (!passedMatch.empty) result.passed = passedMatch[1].to!size_t;
            if (!failedMatch.empty) result.failed = failedMatch[1].to!size_t;
            if (!skippedMatch.empty) result.skipped = skippedMatch[1].to!size_t;
        } catch (Exception e) {
            structuredLog.debug_("failed_to_parse_xunit_output_").field("detail", "Failed to parse xUnit output: " ~ e.msg).emit();
        }
    }
}

