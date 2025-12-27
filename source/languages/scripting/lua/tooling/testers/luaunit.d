module languages.scripting.lua.tooling.testers.luaunit;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.regex;
import std.conv;
import std.string : strip;
import languages.scripting.lua.tooling.testers.base;
import languages.scripting.lua.tooling.detection : isAvailable, getRuntimeCommand;
import languages.scripting.lua.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// LuaUnit test framework - xUnit-style testing
class LuaUnitTester : Tester
{
    override TestResult runTests(
        const string[] sources,
        LuaConfig config,
        const Target target,
        const WorkspaceConfig workspace
    )
    {
        TestResult result;
        
        // Get Lua interpreter
        string luaCmd = getRuntimeCommand(config.runtime);
        
        if (!.isAvailable(luaCmd))
        {
            result.error = "Lua interpreter not found: " ~ luaCmd;
            return result;
        }
        
        // LuaUnit is typically required in test files
        // We run the test files directly with Lua
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            string[] cmd = [luaCmd, source];
            
            // Add LuaUnit-specific arguments via environment or command line
            // Depending on how the test file is structured
            
            structuredLog.debug_("running_luaunit_test_").field("detail", "Running LuaUnit test: " ~ cmd.join(" ")).emit();
            
            auto res = execute(cmd);
            
            // Parse LuaUnit output
            parseOutput(res.output, result);
            
            if (res.status != 0)
            {
                result.success = false;
                if (result.error.empty)
                {
                    result.error = "Tests failed in " ~ source;
                }
                // Continue to run other tests
            }
        }
        
        // If no failures occurred, mark as success
        if (result.error.empty)
        {
            result.success = true;
        }
        
        result.outputHash = FastHash.hashStrings(sources);
        
        return result;
    }
    
    override bool isAvailable()
    {
        // LuaUnit doesn't need to be globally installed
        // It can be required directly in test files
        return true;
    }
    
    override string name() const
    {
        return "LuaUnit";
    }
    
    override string getVersion()
    {
        // LuaUnit version is embedded in the library
        return "3.4+";
    }
    
    private void parseOutput(string output, ref TestResult result)
    {
        // Parse LuaUnit output
        // Example: "Ran 15 tests in 0.001 seconds, 15 successes, 0 failures"
        
        auto ranMatch = matchFirst(output, regex(`Ran\s+(\d+)\s+test`));
        if (!ranMatch.empty)
        {
            auto totalTests = ranMatch[1].to!int;
            
            auto successMatch = matchFirst(output, regex(`(\d+)\s+success`));
            if (!successMatch.empty)
            {
                result.testsPassed = successMatch[1].to!int;
            }
            
            auto failureMatch = matchFirst(output, regex(`(\d+)\s+failure`));
            if (!failureMatch.empty)
            {
                result.testsFailed = failureMatch[1].to!int;
            }
            else
            {
                // If no failures mentioned, assume passed = total
                if (result.testsPassed == 0)
                {
                    result.testsPassed = totalTests;
                }
            }
        }
        
        // Check for OK status
        if (output.canFind("OK") || output.canFind("SUCCESS"))
        {
            // Tests passed
        }
        else if (output.canFind("FAILED") || output.canFind("FAIL"))
        {
            // Extract failure information
            auto lines = output.split("\n");
            string[] errorLines;
            bool inError = false;
            
            foreach (line; lines)
            {
                if (line.canFind("FAILED") || line.canFind("Error") || line.canFind("Failure"))
                {
                    inError = true;
                }
                
                if (inError && !line.strip.empty)
                {
                    errorLines ~= line;
                }
            }
            
            if (!errorLines.empty)
            {
                result.error = errorLines.join("\n");
            }
        }
    }
}

