module languages.scripting.perl.services.test;

import languages.scripting.perl.core.config;
import infrastructure.config.schema.schema : LanguageBuildResult, Target;
import infrastructure.analysis.targets.types;
import engine.caching.actions.action;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import std.range : empty;
import std.array : join;

/// Test execution service interface
interface IPerlTestService
{
    /// Run tests for target
    LanguageBuildResult run(
        in Target target,
        in PerlConfig config,
        string projectRoot,
        ActionCache cache
    );
}

/// Concrete Perl test service
final class PerlTestService : IPerlTestService
{
    LanguageBuildResult run(
        in Target target,
        in PerlConfig config,
        string projectRoot,
        ActionCache cache
    ) @trusted
    {
        // Detect framework
        PerlTestFramework framework = config.test.framework;
        if (framework == PerlTestFramework.Auto)
        {
            framework = detectFramework();
        }
        
        // Run tests based on framework
        final switch (framework)
        {
            case PerlTestFramework.Auto:
                framework = PerlTestFramework.Prove;
                goto case PerlTestFramework.Prove;
            
            case PerlTestFramework.Prove:
                return runProveTests(target, config, projectRoot, cache);
            
            case PerlTestFramework.TestMore:
            case PerlTestFramework.Test2:
            case PerlTestFramework.TestClass:
                return runPerlTests(target, config, projectRoot);
            
            case PerlTestFramework.TAPHarness:
                return runProveTests(target, config, projectRoot, cache);
            
            case PerlTestFramework.None:
                LanguageBuildResult result;
                result.success = true;
                return result;
        }
    }
    
    private PerlTestFramework detectFramework() @trusted
    {
        import std.process : execute;
        
        // Check for prove
        if (isCommandAvailable("prove"))
            return PerlTestFramework.Prove;
        
        // Check for Test2
        try
        {
            auto res = execute(["perl", "-MTest2", "-e", "1"]);
            if (res.status == 0)
                return PerlTestFramework.Test2;
        }
        catch (Exception e) {}
        
        return PerlTestFramework.TestMore;
    }
    
    private LanguageBuildResult runProveTests(
        in Target target,
        in PerlConfig config,
        string projectRoot,
        ActionCache cache
    ) @trusted
    {
        import std.process : execute, Config;
        import std.file : exists, isDir, isFile, dirEntries, SpanMode;
        import std.path : buildPath;
        import std.conv : to;
        
        LanguageBuildResult result;
        
        if (!isCommandAvailable("prove"))
        {
            result.error = "prove command not available";
            return result;
        }
        
        // Gather test files
        string[] testFiles = gatherTestFiles(config, projectRoot);
        
        // Build metadata
        string[string] metadata;
        metadata["verbose"] = config.test.prove.verbose.to!string;
        metadata["lib"] = config.test.prove.lib.to!string;
        metadata["recurse"] = config.test.prove.recurse.to!string;
        metadata["parallel"] = config.test.parallel.to!string;
        metadata["jobs"] = config.test.jobs.to!string;
        metadata["includes"] = config.test.prove.includes.join(",");
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Test;
        actionId.subId = "prove";
        actionId.inputHash = FastHash.hashStrings(testFiles);
        
        // Check cache
        if (cache.isCached(actionId, testFiles, metadata))
        {
            structuredLog.info("__cached_test_execution_prove").emit();
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources);
            return result;
        }
        
        // Build command
        string[] cmd = ["prove"];
        
        if (config.test.prove.verbose)
            cmd ~= "-v";
        
        if (config.test.prove.lib)
            cmd ~= "-l";
        
        if (config.test.prove.recurse)
            cmd ~= "-r";
        
        if (config.test.prove.timer)
            cmd ~= "--timer";
        
        if (config.test.prove.color)
            cmd ~= "--color";
        
        if (config.test.parallel)
        {
            int jobs = config.test.jobs == 0 ? 4 : config.test.jobs;
            cmd ~= ["-j", jobs.to!string];
        }
        
        foreach (incDir; config.test.prove.includes)
        {
            cmd ~= ["-I", incDir];
        }
        
        if (!config.test.testPaths.empty)
            cmd ~= config.test.testPaths;
        else
            cmd ~= "t/";
        
        structuredLog.info("running_tests_with_prove").emit();
        
        // Execute tests
        bool success = false;
        try
        {
            auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
            success = (res.status == 0);
            
            if (!success)
            {
                result.error = "Tests failed:\n" ~ res.output;
            }
            else
            {
                result.success = true;
                result.outputHash = FastHash.hashStrings(target.sources);
            }
        }
        catch (Exception e)
        {
            result.error = "Failed to run tests: " ~ e.msg;
        }
        
        // Update cache
        cache.update(actionId, testFiles, [], metadata, success);
        
        return result;
    }
    
    private LanguageBuildResult runPerlTests(
        in Target target,
        in PerlConfig config,
        string projectRoot
    ) @trusted
    {
        import std.process : execute, Config;
        import std.file : exists, isDir, isFile, dirEntries, SpanMode;
        import std.path : buildPath;
        import std.conv : to;
        
        LanguageBuildResult result;
        
        string perlCmd = config.perlVersion.interpreterPath.empty 
            ? "perl" 
            : config.perlVersion.interpreterPath;
        
        // Find test files
        string[] testFiles;
        foreach (testPath; config.test.testPaths)
        {
            auto fullPath = buildPath(projectRoot, testPath);
            if (exists(fullPath) && isDir(fullPath))
            {
                foreach (entry; dirEntries(fullPath, "*.t", SpanMode.depth))
                {
                    testFiles ~= entry.name;
                }
            }
            else if (exists(fullPath) && isFile(fullPath))
            {
                testFiles ~= fullPath;
            }
        }
        
        if (testFiles.empty)
        {
            result.error = "No test files found";
            return result;
        }
        
        structuredLog.info("running_").field("detail", "Running " ~ testFiles.length.to!string ~ " test files").emit();
        
        bool allPassed = true;
        foreach (testFile; testFiles)
        {
            string[] cmd = [perlCmd];
            
            foreach (incDir; config.includeDirs)
            {
                cmd ~= ["-I", incDir];
            }
            
            cmd ~= ["-I", "lib"];
            
            if (config.warnings)
                cmd ~= "-w";
            
            cmd ~= testFile;
            
            try
            {
                auto res = execute(cmd, null, Config.none, size_t.max, projectRoot);
                if (res.status != 0)
                {
                    structuredLog.error("test_failed_").field("detail", "Test failed: " ~ testFile).emit();
                    allPassed = false;
                }
            }
            catch (Exception e)
            {
                structuredLog.error("failed_to_run_test_").field("detail", "Failed to run test " ~ testFile ~ ": " ~ e.msg).emit();
                allPassed = false;
            }
        }
        
        if (!allPassed)
        {
            result.error = "Some tests failed";
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private string[] gatherTestFiles(in PerlConfig config, string projectRoot) @trusted
    {
        import std.file : exists, isDir, isFile, dirEntries, SpanMode;
        import std.path : buildPath;
        
        string[] testFiles;
        
        if (!config.test.testPaths.empty)
        {
            foreach (testPath; config.test.testPaths)
            {
                auto fullPath = buildPath(projectRoot, testPath);
                if (exists(fullPath) && isDir(fullPath))
                {
                    foreach (entry; dirEntries(fullPath, "*.t", SpanMode.depth))
                    {
                        testFiles ~= entry.name;
                    }
                }
                else if (exists(fullPath) && isFile(fullPath))
                {
                    testFiles ~= fullPath;
                }
            }
        }
        else if (exists(buildPath(projectRoot, "t")))
        {
            foreach (entry; dirEntries(buildPath(projectRoot, "t"), "*.t", SpanMode.depth))
            {
                testFiles ~= entry.name;
            }
        }
        
        return testFiles;
    }
    
    private bool isCommandAvailable(string cmd) @trusted
    {
        import std.process : execute;
        
        try
        {
            version(Windows)
            {
                auto res = execute(["where", cmd]);
                return res.status == 0;
            }
            else
            {
                auto res = execute(["which", cmd]);
                return res.status == 0;
            }
        }
        catch (Exception e)
        {
            return false;
        }
    }
}

