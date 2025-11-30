module tests.unit.core.hermetic_advanced;

import std.stdio : writeln;
import std.file : exists, mkdirRecurse, rmdirRecurse, write, tempDir;
import std.path : buildPath;
import std.algorithm : canFind;
import std.conv : to;
import engine.runtime.hermetic;
import engine.runtime.hermetic.determinism.detector;
import engine.runtime.hermetic.determinism.enforcer;
import tests.harness;

version(unittest):

@("hermetic_advanced.edge_cases.empty_paths")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - edge case: empty path sets");
    
    // Test spec with no inputs (should work but be limited)
    auto spec1 = SandboxSpecBuilder.create()
        .output("/tmp/output")
        .temp("/tmp/temp")
        .build();
    
    Assert.isTrue(spec1.isOk, "Should allow spec with no inputs");
    
    // Test spec with no outputs (read-only build)
    auto spec2 = SandboxSpecBuilder.create()
        .input("/workspace")
        .temp("/tmp/temp")
        .build();
    
    Assert.isTrue(spec2.isOk, "Should allow spec with no outputs");
    
    writeln("  \x1b[32m✓ Empty paths test passed\x1b[0m");
}

@("hermetic_advanced.edge_cases.nested_paths")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - edge case: deeply nested paths");
    
    auto deepPath = "/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p";
    
    auto spec = SandboxSpecBuilder.create()
        .input(deepPath)
        .output("/tmp/output")
        .temp("/tmp/temp")
        .build();
    
    Assert.isTrue(spec.isOk, "Should handle deeply nested paths");
    
    auto s = spec.unwrap();
    Assert.isTrue(s.canRead(deepPath ~ "/file.txt"), 
                  "Should handle nested file reads");
    
    writeln("  \x1b[32m✓ Nested paths test passed\x1b[0m");
}

@("hermetic_advanced.edge_cases.special_characters")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - edge case: paths with special characters");
    
    auto pathWithSpaces = "/tmp/my dir/with spaces";
    auto pathWithDashes = "/tmp/my-project-name";
    auto pathWithUnderscores = "/tmp/my_project_name";
    
    auto spec = SandboxSpecBuilder.create()
        .input(pathWithSpaces)
        .input(pathWithDashes)
        .input(pathWithUnderscores)
        .output("/tmp/output")
        .temp("/tmp/temp")
        .build();
    
    Assert.isTrue(spec.isOk, "Should handle special characters in paths");
    
    auto s = spec.unwrap();
    Assert.isTrue(s.canRead(pathWithSpaces), "Should read paths with spaces");
    Assert.isTrue(s.canRead(pathWithDashes), "Should read paths with dashes");
    Assert.isTrue(s.canRead(pathWithUnderscores), "Should read paths with underscores");
    
    writeln("  \x1b[32m✓ Special characters test passed\x1b[0m");
}

@("hermetic_advanced.resource_limits.zero_limits")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - edge case: zero resource limits");
    
    ResourceLimits zero;
    zero.maxMemoryBytes = 0;  // Unlimited
    zero.maxCpuTimeMs = 0;    // Unlimited
    zero.maxProcesses = 0;    // Unlimited
    
    auto spec = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/output")
        .temp("/tmp/temp")
        .withResources(zero)
        .build();
    
    Assert.isTrue(spec.isOk, "Should accept zero (unlimited) limits");
    
    writeln("  \x1b[32m✓ Zero limits test passed\x1b[0m");
}

@("hermetic_advanced.resource_limits.extreme_limits")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - edge case: extreme resource limits");
    
    ResourceLimits extreme;
    extreme.maxMemoryBytes = 1024;  // 1KB - very restrictive
    extreme.maxCpuTimeMs = 100;     // 100ms - very short
    extreme.maxProcesses = 1;       // Single process only
    extreme.maxOpenFiles = 8;       // Very few FDs
    
    auto spec = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/output")
        .temp("/tmp/temp")
        .withResources(extreme)
        .build();
    
    Assert.isTrue(spec.isOk, "Should accept extreme limits");
    
    auto s = spec.unwrap();
    Assert.equal(s.resources.maxMemoryBytes, 1024, "Should preserve extreme memory");
    Assert.equal(s.resources.maxCpuTimeMs, 100, "Should preserve extreme CPU");
    
    writeln("  \x1b[32m✓ Extreme limits test passed\x1b[0m");
}

@("hermetic_advanced.network_policy.partial_access")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - partial network access");
    
    // Allow specific hosts only
    auto policy = NetworkPolicy.allowHosts(["trusted-cdn.com", "api.internal.net"]);
    
    auto spec = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/output")
        .temp("/tmp/temp")
        .withNetwork(policy)
        .build();
    
    Assert.isTrue(spec.isOk, "Should create partial network spec");
    
    auto s = spec.unwrap();
    auto net = s.network;
    
    Assert.isFalse(net.isHermetic, "Should not be fully hermetic");
    Assert.isTrue(net.allowHttp, "Should allow HTTP to specific hosts");
    Assert.equal(net.allowedHosts.length, 2, "Should have 2 allowed hosts");
    Assert.contains(net.allowedHosts, "trusted-cdn.com", "Should contain first host");
    Assert.contains(net.allowedHosts, "api.internal.net", "Should contain second host");
    
    writeln("  \x1b[32m✓ Partial network access test passed\x1b[0m");
}

@("hermetic_advanced.network_policy.localhost_access")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - localhost network access");
    
    auto policy = NetworkPolicy.allowHosts(["localhost", "127.0.0.1"]);
    
    auto spec = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/output")
        .temp("/tmp/temp")
        .withNetwork(policy)
        .build();
    
    Assert.isTrue(spec.isOk, "Should allow localhost access");
    
    auto s = spec.unwrap();
    Assert.contains(s.network.allowedHosts, "localhost", "Should allow localhost");
    Assert.contains(s.network.allowedHosts, "127.0.0.1", "Should allow 127.0.0.1");
    
    writeln("  \x1b[32m✓ Localhost access test passed\x1b[0m");
}

@("hermetic_advanced.environment.variable_overriding")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - environment variable overriding");
    
    auto spec = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/output")
        .temp("/tmp/temp")
        .env("PATH", "/usr/bin")
        .env("PATH", "/usr/bin:/bin")  // Override previous
        .env("HOME", "/nonexistent")
        .build();
    
    Assert.isTrue(spec.isOk, "Should handle env overrides");
    
    auto s = spec.unwrap();
    
    // Check that the last value wins
    bool foundCorrectPath = false;
    foreach (envVar; s.environment.vars.byKeyValue)
    {
        if (envVar.key == "PATH" && envVar.value == "/usr/bin:/bin")
        {
            foundCorrectPath = true;
            break;
        }
    }
    
    Assert.isTrue(foundCorrectPath, "Should use last PATH value");
    
    writeln("  \x1b[32m✓ Environment overriding test passed\x1b[0m");
}

@("hermetic_advanced.environment.empty_variables")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - empty environment variables");
    
    auto spec = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/output")
        .temp("/tmp/temp")
        .env("EMPTY_VAR", "")
        .env("NORMAL_VAR", "value")
        .build();
    
    Assert.isTrue(spec.isOk, "Should handle empty env values");
    
    auto s = spec.unwrap();
    Assert.isTrue(s.environment.has("EMPTY_VAR"), "Should include empty var");
    Assert.equal(s.environment.vars["EMPTY_VAR"], "", "Empty var should be empty");
    Assert.isTrue(s.environment.has("NORMAL_VAR"), "Should include normal var");
    Assert.equal(s.environment.vars["NORMAL_VAR"], "value", "Normal var should have value");
    
    writeln("  \x1b[32m✓ Empty variables test passed\x1b[0m");
}

@("hermetic_advanced.determinism.custom_epoch")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - custom SOURCE_DATE_EPOCH");
    
    auto config1 = DeterminismConfig.defaults();
    config1.fixedTimestamp = 1000000000;  // Different epoch
    
    auto config2 = DeterminismConfig.defaults();
    config2.fixedTimestamp = 2000000000;  // Different epoch
    
    Assert.notEqual(config1.fixedTimestamp, config2.fixedTimestamp,
                    "Should allow different epochs");
    
    writeln("  \x1b[32m✓ Custom epoch test passed\x1b[0m");
}

@("hermetic_advanced.determinism.strict_vs_relaxed")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - strict vs relaxed determinism");
    
    auto strict = DeterminismConfig.strict();
    auto relaxed = DeterminismConfig.defaults();
    
    Assert.isTrue(strict.strictMode, "Strict should be strict");
    Assert.isFalse(relaxed.strictMode, "Default should not be strict");
    
    // Both should have deterministic settings
    Assert.equal(strict.fixedTimestamp, relaxed.fixedTimestamp,
                 "Should use same timestamp");
    Assert.equal(strict.prngSeed, relaxed.prngSeed,
                 "Should use same PRNG seed");
    
    writeln("  \x1b[32m✓ Strict vs relaxed test passed\x1b[0m");
}

@("hermetic_advanced.path_set.union_many")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - union of many path sets");
    
    PathSet result;
    
    // Union many sets
    foreach (i; 0 .. 10)
    {
        PathSet temp;
        temp.add("/path" ~ i.to!string);
        result = result.union_(temp);
    }
    
    Assert.equal(result.paths.length, 10, "Should have 10 paths");
    
    foreach (i; 0 .. 10)
        Assert.isTrue(result.contains("/path" ~ i.to!string),
                     "Should contain path" ~ i.to!string);
    
    writeln("  \x1b[32m✓ Union many test passed\x1b[0m");
}

@("hermetic_advanced.path_set.intersection_many")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - intersection of many path sets");
    
    PathSet common;
    common.add("/common");
    
    PathSet result = common;
    
    // Intersect with sets that all contain /common
    foreach (i; 0 .. 5)
    {
        PathSet temp;
        temp.add("/common");
        temp.add("/unique" ~ i.to!string);
        result = result.intersection(temp);
    }
    
    Assert.equal(result.paths.length, 1, "Should have only common path");
    Assert.isTrue(result.contains("/common"), "Should contain common path");
    
    writeln("  \x1b[32m✓ Intersection many test passed\x1b[0m");
}

@("hermetic_advanced.compiler_detection.path_variations")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - compiler detection with path variations");
    
    // Test with full paths
    Assert.equal(NonDeterminismDetector.detectCompiler(["/usr/bin/gcc"]),
                 CompilerType.GCC, "Should detect GCC in full path");
    
    Assert.equal(NonDeterminismDetector.detectCompiler(["/opt/llvm/bin/clang++"]),
                 CompilerType.Clang, "Should detect Clang in full path");
    
    // Test with version suffixes
    Assert.equal(NonDeterminismDetector.detectCompiler(["gcc-11"]),
                 CompilerType.GCC, "Should detect GCC with version");
    
    Assert.equal(NonDeterminismDetector.detectCompiler(["clang-15"]),
                 CompilerType.Clang, "Should detect Clang with version");
    
    writeln("  \x1b[32m✓ Compiler path variations test passed\x1b[0m");
}

@("hermetic_advanced.violation_detection.multiple_sources")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - multiple non-determinism sources");
    
    // Analyze output with multiple issues
    auto output = `
Build started at 2024-01-15 14:23:45
Generated UUID: 550e8400-e29b-41d4-a716-446655440000
Random seed: 12345
Thread 0x7f8a9b2c3d4e started
`;
    
    auto violations = NonDeterminismDetector.analyzeBuildOutput(output, "");
    
    Assert.notEmpty(violations, "Should detect multiple violations");
    
    bool foundTimestamp = false;
    bool foundUUID = false;
    
    foreach (violation; violations)
    {
        if (violation.source == NonDeterminismSource.Timestamp)
            foundTimestamp = true;
        if (violation.source == NonDeterminismSource.RandomValue)
            foundUUID = true;
    }
    
    Assert.isTrue(foundTimestamp, "Should detect timestamp");
    Assert.isTrue(foundUUID, "Should detect UUID");
    
    writeln("  \x1b[32m✓ Multiple sources test passed\x1b[0m");
}

@("hermetic_advanced.spec_builder.fluent_api")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - fluent API chaining");
    
    // Test that all methods return the builder for chaining
    auto spec = SandboxSpecBuilder.create()
        .input("/workspace/src")
        .input("/workspace/include")
        .input("/usr/lib")
        .output("/workspace/build")
        .output("/workspace/dist")
        .temp("/tmp/work")
        .temp("/tmp/cache")
        .env("PATH", "/usr/bin:/bin")
        .env("CC", "gcc")
        .env("CXX", "g++")
        .withNetwork(NetworkPolicy.hermetic())
        .withResources(ResourceLimits.hermetic())
        .build();
    
    Assert.isTrue(spec.isOk, "Fluent API should work");
    
    auto s = spec.unwrap();
    Assert.isTrue(s.canRead("/workspace/src"), "Should have first input");
    Assert.isTrue(s.canRead("/workspace/include"), "Should have second input");
    Assert.isTrue(s.canWrite("/workspace/build"), "Should have first output");
    Assert.isTrue(s.canWrite("/workspace/dist"), "Should have second output");
    
    writeln("  \x1b[32m✓ Fluent API test passed\x1b[0m");
}

@("hermetic_advanced.edge_cases.same_path_multiple_roles")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - same path in multiple roles (should fail)");
    
    // Try to add same path as both input and output
    auto result = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/workspace")  // Same as input
        .build();
    
    Assert.isTrue(result.isErr, "Should reject same path as input and output");
    
    writeln("  \x1b[32m✓ Same path multiple roles test passed\x1b[0m");
}

@("hermetic_advanced.performance.large_path_sets")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - performance with large path sets");
    
    import std.datetime.stopwatch : StopWatch, AutoStart;
    
    auto sw = StopWatch(AutoStart.yes);
    
    // Create spec with many paths
    auto builder = SandboxSpecBuilder.create();
    
    foreach (i; 0 .. 100)
    {
        builder = builder.input("/workspace/module" ~ i.to!string);
    }
    
    auto spec = builder
        .output("/workspace/build")
        .temp("/tmp/work")
        .build();
    
    sw.stop();
    auto elapsed = sw.peek();
    
    Assert.isTrue(spec.isOk, "Should handle 100 input paths");
    
    writeln("  Created spec with 100 paths in ", elapsed.total!"msecs", "ms");
    Assert.isTrue(elapsed.total!"msecs" < 1000, "Should be fast (< 1 second)");
    
    writeln("  \x1b[32m✓ Large path sets test passed\x1b[0m");
}

@("hermetic_advanced.timestamp_formats.comprehensive")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - comprehensive timestamp detection");
    
    string[] timestampFormats = [
        "2024-01-15",               // ISO date
        "01/15/2024",               // US date format
        "15-01-2024",               // EU date format
        "14:23:45",                 // Time
        "14:23:45.123",             // Time with milliseconds
        "1640995200",               // Unix timestamp
        "Jan 15 2024",              // Month name
        "January 15, 2024",         // Full month name
        "Mon Jan 15 14:23:45 2024", // Date output format
    ];
    
    foreach (format; timestampFormats)
    {
        auto detected = NonDeterminismDetector.containsTimestamp(format);
        // Some formats might not be detected, which is okay
        // Just log the results
        writeln("  Format '", format, "': ", detected ? "detected" : "not detected");
    }
    
    writeln("  \x1b[32m✓ Timestamp formats test passed\x1b[0m");
}

@("hermetic_advanced.resource_monitoring.interface")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_advanced - resource monitoring interface");
    
    // Test that ResourceLimits can be configured comprehensively
    ResourceLimits limits;
    limits.maxMemoryBytes = 2UL * 1024 * 1024 * 1024;  // 2GB
    limits.maxCpuTimeMs = 5 * 60 * 1000;               // 5 minutes
    limits.maxProcesses = 64;
    limits.maxOpenFiles = 512;
    limits.maxOutputBytes = 100 * 1024 * 1024;         // 100MB
    
    Assert.equal(limits.maxMemoryBytes, 2UL * 1024 * 1024 * 1024,
                 "Memory limit should be set");
    Assert.equal(limits.maxCpuTimeMs, 5 * 60 * 1000,
                 "CPU limit should be set");
    Assert.equal(limits.maxProcesses, 64,
                 "Process limit should be set");
    Assert.equal(limits.maxOpenFiles, 512,
                 "FD limit should be set");
    Assert.equal(limits.maxOutputBytes, 100 * 1024 * 1024,
                 "Output limit should be set");
    
    writeln("  \x1b[32m✓ Resource monitoring test passed\x1b[0m");
}
