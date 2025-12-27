module languages.dotnet.fsharp.tooling.testers.xunit;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.datetime.stopwatch;
import std.regex;
import std.conv;
import languages.dotnet.fsharp.tooling.testers.base;
import languages.dotnet.fsharp.config;
import languages.dotnet.fsharp.managers.dotnet;
import infrastructure.utils.logging;

/// xUnit test runner
class XUnitTester : FSharpTester
{
    TestResult runTests(string[] testFiles, FSharpTestConfig config)
    {
        TestResult result;
        auto sw = StopWatch(AutoStart.yes);
        
        auto testProject = testFiles.find!(f => f.endsWith(".fsproj"));
        
        if (testProject.empty)
        {
            result.error = "No .fsproj test project found";
            return result;
        }
        
        string[] cmd = ["dotnet", "test", testProject.front];
        
        cmd ~= ["--verbosity", "normal"];
        
        if (!config.filter.empty)
            cmd ~= ["--filter", config.filter];
        
        if (!config.parallel)
            cmd ~= ["--", "xUnit.parallelizeTestCollections=false"];
        
        cmd ~= config.testFlags;
        
        auto res = execute(cmd);
        
        sw.stop();
        result.duration = sw.peek().total!"msecs";
        
        result = parseXUnitOutput(res.output);
        result.duration = sw.peek().total!"msecs";
        
        result.success = res.status == 0;
        
        if (!result.success && result.error.empty)
            result.error = "Tests failed";
        
        return result;
    }
    
    string getName()
    {
        return "xUnit";
    }
    
    bool isAvailable()
    {
        return DotnetOps.isAvailable();
    }
    
    private TestResult parseXUnitOutput(string output)
    {
        TestResult result;
        
        auto totalPattern = regex(r"Total:\s*(\d+)");
        auto passedPattern = regex(r"Passed:\s*(\d+)");
        auto failedPattern = regex(r"Failed:\s*(\d+)");
        auto skippedPattern = regex(r"Skipped:\s*(\d+)");
        
        foreach (line; output.splitLines)
        {
            auto totalMatch = matchFirst(line, totalPattern);
            if (!totalMatch.empty)
                result.totalTests = totalMatch[1].to!int;
            
            auto passedMatch = matchFirst(line, passedPattern);
            if (!passedMatch.empty)
                result.passed = passedMatch[1].to!int;
            
            auto failedMatch = matchFirst(line, failedPattern);
            if (!failedMatch.empty)
                result.failed = failedMatch[1].to!int;
            
            auto skippedMatch = matchFirst(line, skippedPattern);
            if (!skippedMatch.empty)
                result.skipped = skippedMatch[1].to!int;
        }
        
        return result;
    }
}

