module languages.dotnet.csharp.tooling.testers.mstest;

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

/// MSTest test runner
class MSTestRunner : ITestRunner
{
    override bool isAvailable()
    {
        // Check for dotnet CLI or vstest.console
        return isCommandAvailable("dotnet") || isCommandAvailable("vstest.console");
    }
    
    override string name() const
    {
        return "MSTest";
    }
    
    override TestResult runTests(in string[] testFiles, in TestConfig config, in string workingDir)
    {
        structuredLog.info("running_mstest_tests").emit();
        
        if (isCommandAvailable("dotnet")) return runWithDotnetTest(testFiles, config, workingDir);
        if (isCommandAvailable("vstest.console")) return runWithVSTest(testFiles, config, workingDir);
        
        TestResult result;
        result.error = "MSTest runner not found (install Visual Studio Test Platform or use dotnet test)";
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
        parseMSTestOutput(execResult.output, result);
        
        if (!result.success && result.error.empty) result.error = "MSTest tests failed";
        
        import std.format : format;
        structuredLog.info("log_event").field("message", format!"MSTest results: %d passed, %d failed, %d skipped"(result.passed, result.failed, result.skipped)).emit();
        return result;
    }
    
    private TestResult runWithVSTest(in string[] testFiles, in TestConfig config, in string workingDir)
    {
        TestResult result;
        auto assemblies = findTestAssemblies(buildPath(workingDir, "bin"));
        
        if (assemblies.empty) {
            result.error = "No MSTest test assemblies found";
            return result;
        }
        
        string[] cmd = ["vstest.console"] ~ assemblies;
        if (!config.filter.empty) cmd ~= "/TestCaseFilter:" ~ config.filter;
        if (!config.logger.empty) cmd ~= "/logger:" ~ config.logger;
        if (!config.resultsDirectory.empty) cmd ~= "/ResultsDirectory:" ~ config.resultsDirectory;
        cmd ~= config.args;
        
        auto execResult = execute(cmd, null, Config.none, size_t.max, workingDir);
        result.output = execResult.output;
        result.success = (execResult.status == 0);
        parseVSTestOutput(execResult.output, result);
        
        if (!result.success && result.error.empty) result.error = "MSTest tests failed";
        return result;
    }
    
    private void parseMSTestOutput(string output, ref TestResult result)
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
            structuredLog.debug_("failed_to_parse_mstest_output_").field("detail", "Failed to parse MSTest output: " ~ e.msg).emit();
        }
    }
    
    private void parseVSTestOutput(string output, ref TestResult result)
    {
        // VSTest format: "Passed: X Failed: Y Skipped: Z"
        try {
            import std.conv : to;
            auto passedMatch = output.matchFirst(regex(r"Passed:\s*(\d+)"));
            auto failedMatch = output.matchFirst(regex(r"Failed:\s*(\d+)"));
            auto skippedMatch = output.matchFirst(regex(r"Skipped:\s*(\d+)"));
            
            if (!passedMatch.empty) result.passed = passedMatch[1].to!size_t;
            if (!failedMatch.empty) result.failed = failedMatch[1].to!size_t;
            if (!skippedMatch.empty) result.skipped = skippedMatch[1].to!size_t;
        } catch (Exception e) {
            structuredLog.debug_("failed_to_parse_vstest_output_").field("detail", "Failed to parse VSTest output: " ~ e.msg).emit();
        }
    }
}

