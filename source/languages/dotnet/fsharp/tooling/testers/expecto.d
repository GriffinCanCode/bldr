module languages.dotnet.fsharp.tooling.testers.expecto;

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

/// Expecto test runner (functional F# testing)
class ExpectoTester : FSharpTester
{
    TestResult runTests(string[] testFiles, FSharpTestConfig config)
    {
        TestResult result;
        auto sw = StopWatch(AutoStart.yes);
        
        // Find test project
        auto testProject = testFiles.find!(f => f.endsWith(".fsproj"));
        
        if (testProject.empty)
        {
            result.error = "No .fsproj test project found";
            return result;
        }
        
        // Use dotnet test
        string[] cmd = ["dotnet", "test", testProject.front];
        
        // Add verbosity
        cmd ~= ["--verbosity", "normal"];
        
        // Add filter if specified
        if (!config.filter.empty)
            cmd ~= ["--filter", config.filter];
        
        // Parallel execution
        if (!config.parallel)
            cmd ~= ["--", "RunConfiguration.MaxCpuCount=1"];
        
        // Add test flags
        cmd ~= config.testFlags;
        
        auto res = execute(cmd);
        
        sw.stop();
        result.duration = sw.peek().total!"msecs";
        
        // Parse results
        result = parseExpectoOutput(res.output);
        result.duration = sw.peek().total!"msecs";
        
        if (res.status != 0)
        {
            result.success = false;
            if (result.error.empty)
                result.error = "Tests failed";
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
    
    string getName()
    {
        return "Expecto";
    }
    
    bool isAvailable()
    {
        return DotnetOps.isAvailable();
    }
    
    private TestResult parseExpectoOutput(string output)
    {
        TestResult result;
        
        // Parse Expecto output
        foreach (line; output.splitLines)
        {
            if (line.canFind("tests run in"))
            {
                // Extract test counts
                auto match = line.matchFirst(r"(\d+) tests run in");
                if (!match.empty)
                    result.totalTests = match[1].to!int;
            }
            
            if (line.canFind("passed"))
            {
                auto match = line.matchFirst(r"(\d+) passed");
                if (!match.empty)
                    result.passed = match[1].to!int;
            }
            
            if (line.canFind("failed"))
            {
                auto match = line.matchFirst(r"(\d+) failed");
                if (!match.empty)
                    result.failed = match[1].to!int;
            }
        }
        
        return result;
    }
}

