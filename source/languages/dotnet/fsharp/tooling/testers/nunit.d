module languages.dotnet.fsharp.tooling.testers.nunit;

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

/// NUnit test runner
class NUnitTester : FSharpTester
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
        
        cmd ~= config.testFlags;
        
        auto res = execute(cmd);
        
        sw.stop();
        result.duration = sw.peek().total!"msecs";
        
        result = parseNUnitOutput(res.output);
        result.duration = sw.peek().total!"msecs";
        
        result.success = res.status == 0;
        
        if (!result.success && result.error.empty)
            result.error = "Tests failed";
        
        return result;
    }
    
    string getName()
    {
        return "NUnit";
    }
    
    bool isAvailable()
    {
        return DotnetOps.isAvailable();
    }
    
    private TestResult parseNUnitOutput(string output)
    {
        TestResult result;
        
        foreach (line; output.splitLines)
        {
            // NUnit output format
            if (line.canFind("Test Count:"))
            {
                auto match = matchFirst(line, regex(r"(\d+)"));
                if (!match.empty)
                    result.totalTests = match[1].to!int;
            }
            
            if (line.canFind("Passed:"))
            {
                auto match = matchFirst(line, regex(r"Passed:\s*(\d+)"));
                if (!match.empty)
                    result.passed = match[1].to!int;
            }
            
            if (line.canFind("Failed:"))
            {
                auto match = matchFirst(line, regex(r"Failed:\s*(\d+)"));
                if (!match.empty)
                    result.failed = match[1].to!int;
            }
            
            if (line.canFind("Skipped:") || line.canFind("Ignored:"))
            {
                auto match = matchFirst(line, regex(r"(?:Skipped|Ignored):\s*(\d+)"));
                if (!match.empty)
                    result.skipped = match[1].to!int;
            }
        }
        
        return result;
    }
}

