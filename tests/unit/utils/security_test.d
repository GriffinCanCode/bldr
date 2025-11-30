module tests.unit.utils.security_test;

import std.stdio;
import std.exception;
import std.algorithm : canFind, startsWith;
import std.process : Config;
import infrastructure.errors;
import infrastructure.utils.security;

/// Comprehensive security validation tests
unittest
{
    writeln("Running security validation tests...");
    
    // Test 1: Path safety validation
    {
        // Valid paths
        assert(SecurityValidator.isPathSafe("src/main.cpp"));
        assert(SecurityValidator.isPathSafe("output/app.exe"));
        assert(SecurityValidator.isPathSafe("build/debug/test"));
        assert(SecurityValidator.isPathSafe("lib/libmath.a"));
        
        // Command injection attempts
        assert(!SecurityValidator.isPathSafe("file; rm -rf /"));
        assert(!SecurityValidator.isPathSafe("file | cat /etc/passwd"));
        assert(!SecurityValidator.isPathSafe("file && malicious"));
        assert(!SecurityValidator.isPathSafe("file`whoami`"));
        assert(!SecurityValidator.isPathSafe("file$var"));
        assert(!SecurityValidator.isPathSafe("file<input"));
        assert(!SecurityValidator.isPathSafe("file>output"));
        assert(!SecurityValidator.isPathSafe("file(test)"));
        assert(!SecurityValidator.isPathSafe("file{test}"));
        assert(!SecurityValidator.isPathSafe("file[test]"));
        
        // Null byte injection
        assert(!SecurityValidator.isPathSafe("file\0.txt"));
        assert(!SecurityValidator.isPathSafe("test\0"));
        
        // Control characters
        assert(!SecurityValidator.isPathSafe("file\n.txt"));
        assert(!SecurityValidator.isPathSafe("file\r.txt"));
        assert(!SecurityValidator.isPathSafe("file\t.txt"));
        
        // ANSI escape codes (terminal injection)
        assert(!SecurityValidator.isPathSafe("\x1b[31mfile"));
        assert(!SecurityValidator.isPathSafe("file\x1b[0m"));
    }
    
    // Test 2: Path traversal prevention
    {
        // Valid paths
        assert(SecurityValidator.isPathTraversalSafe("src/main.cpp"));
        assert(SecurityValidator.isPathTraversalSafe("output/test"));
        
        // Traversal attempts
        assert(!SecurityValidator.isPathTraversalSafe("../../../etc/passwd"));
        assert(!SecurityValidator.isPathTraversalSafe("..\\..\\windows\\system32"));
        assert(!SecurityValidator.isPathTraversalSafe("test/../../etc"));
        assert(!SecurityValidator.isPathTraversalSafe("file.."));
        
        // Hidden traversal
        assert(!SecurityValidator.isPathTraversalSafe("/./test"));
        assert(!SecurityValidator.isPathTraversalSafe("test/./file"));
        assert(!SecurityValidator.isPathTraversalSafe("test//file"));
        assert(!SecurityValidator.isPathTraversalSafe("test\\\\file"));
        
        // System directories (Unix)
        version(Posix)
        {
            assert(!SecurityValidator.isPathTraversalSafe("/etc/passwd"));
            assert(!SecurityValidator.isPathTraversalSafe("/proc/self/environ"));
            assert(!SecurityValidator.isPathTraversalSafe("/sys/kernel/config"));
            assert(!SecurityValidator.isPathTraversalSafe("/dev/null"));
            assert(!SecurityValidator.isPathTraversalSafe("/boot/vmlinuz"));
            assert(!SecurityValidator.isPathTraversalSafe("/root/.ssh/id_rsa"));
            assert(!SecurityValidator.isPathTraversalSafe("/var/log/auth.log"));
            assert(!SecurityValidator.isPathTraversalSafe("/tmp/malicious"));
        }
        
        // Windows device names
        version(Windows)
        {
            assert(!SecurityValidator.isPathTraversalSafe("CON"));
            assert(!SecurityValidator.isPathTraversalSafe("PRN"));
            assert(!SecurityValidator.isPathTraversalSafe("AUX"));
            assert(!SecurityValidator.isPathTraversalSafe("NUL"));
            assert(!SecurityValidator.isPathTraversalSafe("COM1"));
            assert(!SecurityValidator.isPathTraversalSafe("COM9"));
            assert(!SecurityValidator.isPathTraversalSafe("LPT1"));
            assert(!SecurityValidator.isPathTraversalSafe("LPT9"));
            assert(!SecurityValidator.isPathTraversalSafe("con.txt"));
            assert(!SecurityValidator.isPathTraversalSafe("CON\\test"));
        }
    }
    
    // Test 3: URL-encoded traversal detection
    {
        assert(!SecurityValidator.isPathSafe("%2e%2e/etc/passwd"));
        assert(!SecurityValidator.isPathSafe("..%2fetc/passwd"));
        assert(!SecurityValidator.isPathSafe("%2e%2e%2fetc/passwd"));
    }
    
    // Test 4: Argument safety
    {
        // Valid arguments
        assert(SecurityValidator.isArgumentSafe("-O2"));
        assert(SecurityValidator.isArgumentSafe("--flag"));
        assert(SecurityValidator.isArgumentSafe("--output=file"));
        assert(SecurityValidator.isArgumentSafe("value"));
        assert(SecurityValidator.isArgumentSafe(""));  // Empty is allowed
        
        // Injection attempts
        assert(!SecurityValidator.isArgumentSafe("; rm -rf /"));
        assert(!SecurityValidator.isArgumentSafe("| cat /etc/passwd"));
        assert(!SecurityValidator.isArgumentSafe("&& malicious"));
        assert(!SecurityValidator.isArgumentSafe("|| fallback"));
        assert(!SecurityValidator.isArgumentSafe("`whoami`"));
        assert(!SecurityValidator.isArgumentSafe("$HOME"));
        assert(!SecurityValidator.isArgumentSafe("$(command)"));
        
        // Quote escaping
        assert(!SecurityValidator.isArgumentSafe("'\"escape"));
        assert(!SecurityValidator.isArgumentSafe("\"'escape"));
    }
    
    // Test 5: Batch path validation
    {
        assert(SecurityValidator.arePathsSafe(["src/a.cpp", "src/b.cpp", "src/c.cpp"]));
        assert(!SecurityValidator.arePathsSafe(["src/a.cpp", "bad; rm", "src/c.cpp"]));
        assert(!SecurityValidator.arePathsSafe(["../etc/passwd"]));
    }
    
    writeln("✓ All security validation tests passed");
}

/// Test secure executor
unittest
{
    writeln("Running secure executor tests...");
    
    // Test 1: Safe execution
    {
        auto exec = SecureExecutor.create();
        auto result = exec.run(["echo", "hello"]);
        assert(result.isOk);
        assert(result.unwrap().success);
    }
    
    // Test 2: Injection prevention
    {
        auto exec = SecureExecutor.create();
        auto badResult = exec.run(["echo", "hello; rm -rf /"]);
        assert(badResult.isErr);
        // Should be InjectionAttempt or InvalidCommand depending on implementation
        auto code = badResult.unwrapErr().code;
        assert(code == cast(ErrorCode)SecurityCode.InjectionAttempt || 
               code == cast(ErrorCode)SecurityCode.InvalidCommand);
    }
    
    // Test 3: Path validation in arguments
    {
        auto exec = SecureExecutor.create();
        auto pathResult = exec.run(["cat", "../../../etc/passwd"]);
        assert(pathResult.isErr);
        assert(pathResult.unwrapErr().code == cast(ErrorCode)SecurityCode.PathTraversal);
    }
    
    // Test 4: Builder pattern
    {
        auto configured = SecureExecutor.create()
            .in_("/tmp")
            .withEnv("TEST", "value")
            .audit();
        
        auto envVars = configured.getEnv();
        assert("TEST" in envVars);
        assert(envVars["TEST"] == "value");
    }
    
    // Test 5: Empty command rejection
    {
        auto exec = SecureExecutor.create();
        string[] emptyCmd;
        auto result = exec.run(emptyCmd);
        assert(result.isErr);
        assert(result.unwrapErr().code == cast(ErrorCode)SecurityCode.InvalidCommand);
    }
    
    writeln("✓ All secure executor tests passed");
}

/// Test drop-in execute replacement
unittest
{
    writeln("Running drop-in execute tests...");
    
    // Test 1: Valid command
    {
        auto res = execute(["echo", "test"]);
        assert(res.status == 0);
    }
    
    // Test 2: Command with flags
    {
        auto res = execute(["ls", "-la"]);
        // May fail if ls not available, but shouldn't throw security exception
    }
    
    // Test 3: Injection attempt should throw
    {
        bool caught = false;
        try
        {
            auto res = execute(["echo", "test; rm -rf /"]);
        }
        catch (Exception e)
        {
            caught = true;
            assert(e.msg.canFind("SECURITY"));
        }
        assert(caught);
    }
    
    // Test 4: Path traversal should throw
    {
        bool caught = false;
        try
        {
            auto res = execute(["cat", "../../../etc/passwd"]);
        }
        catch (Exception e)
        {
            caught = true;
            assert(e.msg.canFind("SECURITY"));
        }
        assert(caught);
    }
    
    // Test 5: Unsafe working directory should throw
    version(Posix)
    {
        bool caught = false;
        try
        {
            auto res = execute(["ls"], "/etc");
        }
        catch (Exception e)
        {
            caught = true;
            assert(e.msg.canFind("SECURITY"));
        }
        assert(caught);
    }
    
    // Test 6: Skip validation flag
    {
        // This should succeed even with "dangerous" path
        auto res = execute(["echo", "test"], null, Config.none, size_t.max, null, true);
        assert(res.status == 0);
    }
    
    writeln("✓ All drop-in execute tests passed");
}

/// Integration test: Full security workflow
unittest
{
    writeln("Running security integration tests...");
    
    // Simulate a build process with security checks
    {
        string[] sourceFiles = ["src/main.cpp", "src/utils.cpp"];
        
        // Validate all source files
        assert(SecurityValidator.arePathsSafe(sourceFiles));
        
        // Build command
        string[] buildCmd = ["g++", "-o", "output/app"] ~ sourceFiles;
        
        // All arguments should be safe
        foreach (arg; buildCmd)
        {
            if (arg.canFind('/') || arg.canFind('\\'))
            {
                if (!arg.startsWith("-"))
                {
                    assert(SecurityValidator.isPathSafe(arg));
                }
            }
        }
        
        // Execute would validate automatically
        // auto res = execute(buildCmd);
    }
    
    // Simulate malicious input detection
    {
        string maliciousSource = "../../../etc/passwd";
        assert(!SecurityValidator.isPathSafe(maliciousSource));
        
        // This would throw if executed
        bool caught = false;
        try
        {
            auto res = execute(["cat", maliciousSource]);
        }
        catch (Exception e)
        {
            caught = true;
        }
        assert(caught);
    }
    
    writeln("✓ All integration tests passed");
}

/// Performance benchmark
unittest
{
    import std.datetime.stopwatch;
    
    writeln("Running security performance benchmarks...");
    
    auto sw = StopWatch(AutoStart.yes);
    
    // Benchmark path validation
    {
        sw.reset();
        sw.start();
        foreach (i; 0 .. 10_000)
        {
            SecurityValidator.isPathSafe("src/main.cpp");
        }
        sw.stop();
        writeln("  Path validation: ", sw.peek.total!"usecs", " μs for 10k calls");
    }
    
    // Benchmark argument validation
    {
        sw.reset();
        sw.start();
        foreach (i; 0 .. 10_000)
        {
            SecurityValidator.isArgumentSafe("--flag=value");
        }
        sw.stop();
        writeln("  Argument validation: ", sw.peek.total!"usecs", " μs for 10k calls");
    }
    
    writeln("✓ Performance benchmarks completed");
}
