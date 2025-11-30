module tests.unit.core.environment;

import std.stdio;
import std.algorithm : canFind;
import std.conv : to;
import infrastructure.telemetry.collection.environment;

unittest
{
    writeln("TEST: BuildEnvironment snapshot");
    
    auto env = BuildEnvironment.snapshot();
    
    // Should have detected at least some tools
    assert(env.toolVersions.length > 0, "Should detect at least one tool");
    
    // Should have system info
    assert(env.system.os.length > 0, "OS should be detected");
    assert(env.system.arch.length > 0, "Architecture should be detected");
    assert(env.system.cpuCores > 0, "CPU cores should be detected");
    assert(env.system.hostname.length > 0, "Hostname should be detected");
    
    // Should have captured PATH at minimum
    assert("PATH" in env.envVars, "PATH should be in environment variables");
    
    // Build time should be set
    assert(env.buildTime != env.buildTime.init, "Build time should be set");
    
    writeln("  ✓ BuildEnvironment snapshot works");
}

unittest
{
    writeln("TEST: SystemInfo detection");
    
    auto sys = SystemInfo.detect();
    
    // Check OS is one of the known values
    assert(sys.os == "Windows" || sys.os == "Linux" || sys.os == "macOS" ||
           sys.os == "FreeBSD" || sys.os == "OpenBSD" || sys.os == "NetBSD" ||
           sys.os == "Solaris" || sys.os == "Unknown",
           "OS should be one of known values");
    
    // Check arch is reasonable
    assert(sys.arch.length > 0, "Architecture should be detected");
    assert(sys.arch == "x86_64" || sys.arch == "x86" || sys.arch == "arm64" ||
           sys.arch == "arm" || sys.arch == "ppc64" || sys.arch == "ppc" ||
           sys.arch == "mips64" || sys.arch == "mips" || sys.arch == "unknown",
           "Arch should be one of known values");
    
    // CPU cores should be positive
    assert(sys.cpuCores > 0, "Should have at least 1 CPU core");
    
    // Hostname should exist
    assert(sys.hostname.length > 0, "Hostname should be detected");
    
    writeln("  ✓ SystemInfo detection works");
}

unittest
{
    writeln("TEST: BuildEnvironment compatibility checking");
    
    auto env1 = BuildEnvironment.snapshot();
    auto env2 = BuildEnvironment.snapshot();
    
    // Identical environments should be compatible
    assert(env1.isCompatible(env2), "Same environment should be compatible");
    
    // Modified tool version should make incompatible
    auto env3 = env2;
    if (env3.toolVersions.length > 0)
    {
        // Modify first tool version
        auto key = env3.toolVersions.keys[0];
        env3.toolVersions[key] = "999.0.0-test";
        assert(!env1.isCompatible(env3), "Different tool version should be incompatible");
    }
    
    // Different OS should be incompatible
    auto env4 = env2;
    env4.system.os = "TestOS";
    assert(!env1.isCompatible(env4), "Different OS should be incompatible");
    
    // Different arch should be incompatible
    auto env5 = env2;
    env5.system.arch = "test_arch";
    assert(!env1.isCompatible(env5), "Different architecture should be incompatible");
    
    writeln("  ✓ Compatibility checking works");
}

unittest
{
    writeln("TEST: BuildEnvironment diff generation");
    
    auto env1 = BuildEnvironment.snapshot();
    auto env2 = BuildEnvironment.snapshot();
    
    // Same environment should have no differences
    auto diff1 = env1.diff(env2);
    assert(diff1.length == 0, "Identical environments should have no differences");
    
    // Add a new tool to env2
    env2.toolVersions["test-tool"] = "1.0.0";
    auto diff2 = env1.diff(env2);
    assert(diff2.length > 0, "Should detect new tool");
    assert(diff2[0].canFind("test-tool"), "Diff should mention test-tool");
    assert(diff2[0].canFind("missing"), "Diff should show tool was missing");
    
    // Change OS
    env2.system.os = "CustomOS";
    auto diff3 = env1.diff(env2);
    bool foundOsDiff = false;
    foreach (d; diff3)
    {
        if (d.canFind("OS:"))
            foundOsDiff = true;
    }
    assert(foundOsDiff, "Should detect OS change");
    
    writeln("  ✓ Diff generation works");
}

unittest
{
    writeln("TEST: Tool version detection");
    
    auto env = BuildEnvironment.snapshot();
    
    // Check if common tools are detected (system-dependent)
    // Just verify the structure is correct
    foreach (pair; env.toolVersions.byKeyValue)
    {
        assert(pair.key.length > 0, "Tool name should not be empty");
        assert(pair.value.length > 0, "Tool version should not be empty");
        assert(pair.value.length <= 200, "Version string should be reasonably sized");
    }
    
    writeln("  ✓ Tool version detection structure is correct");
}

unittest
{
    writeln("TEST: Environment variable capture");
    
    auto env = BuildEnvironment.snapshot();
    
    // PATH should always be captured
    assert("PATH" in env.envVars, "PATH should be captured");
    
    // Verify captured variables are not empty
    foreach (pair; env.envVars.byKeyValue)
    {
        assert(pair.key.length > 0, "Env var key should not be empty");
        assert(pair.value.length > 0, "Env var value should not be empty");
    }
    
    writeln("  ✓ Environment variable capture works");
}

unittest
{
    writeln("TEST: BuildEnvironment toString formatting");
    
    auto env = BuildEnvironment.snapshot();
    auto str = env.toString();
    
    assert(str.length > 0, "toString should produce output");
    assert(str.canFind("Build Environment"), "Should have header");
    assert(str.canFind("[System]"), "Should have System section");
    assert(str.canFind("[Tools]"), "Should have Tools section");
    assert(str.canFind("[Environment]"), "Should have Environment section");
    
    // Should contain actual data
    assert(str.canFind(env.system.os), "Should show OS");
    assert(str.canFind(env.system.arch), "Should show architecture");
    
    writeln("  ✓ toString formatting works");
}

unittest
{
    writeln("TEST: Critical environment variable detection");
    
    auto env1 = BuildEnvironment.snapshot();
    auto env2 = env1;
    
    // Non-critical variable change should not affect compatibility
    env2.envVars["NON_CRITICAL_VAR"] = "test_value";
    assert(env1.isCompatible(env2), "Non-critical env var should not affect compatibility");
    
    // Critical variable change should affect compatibility if present
    if ("CC" in env2.envVars)
    {
        env2.envVars["CC"] = "/usr/bin/test-gcc";
        assert(!env1.isCompatible(env2), "CC change should affect compatibility");
    }
    else
    {
        // If CC not present, adding it should affect compatibility
        env2.envVars["CC"] = "gcc";
        assert(!env1.isCompatible(env2), "Adding CC should affect compatibility");
    }
    
    writeln("  ✓ Critical env var detection works");
}

unittest
{
    writeln("TEST: BuildEnvironment with missing tools");
    
    auto env1 = BuildEnvironment.snapshot();
    auto env2 = env1;
    
    // Remove a tool from env2
    if (env2.toolVersions.length > 0)
    {
        auto key = env2.toolVersions.keys[0];
        env2.toolVersions.remove(key);
        
        assert(!env1.isCompatible(env2), "Missing tool should make incompatible");
        
        auto diff = env1.diff(env2);
        bool foundMissingTool = false;
        foreach (d; diff)
        {
            if (d.canFind(key) && d.canFind("missing"))
                foundMissingTool = true;
        }
        assert(foundMissingTool, "Diff should show missing tool");
    }
    
    writeln("  ✓ Missing tool detection works");
}

unittest
{
    writeln("TEST: BuildEnvironment with additional tools");
    
    auto env1 = BuildEnvironment.snapshot();
    auto env2 = env1;
    
    // Add tools to env2
    env2.toolVersions["custom-tool-1"] = "1.2.3";
    env2.toolVersions["custom-tool-2"] = "4.5.6";
    
    // env1 should still be compatible with env2 (env1 has all required tools)
    // But env2 is not compatible with env1 (env1 missing new tools)
    assert(!env1.isCompatible(env2), "Environment with extra tools should be incompatible");
    
    auto diff = env1.diff(env2);
    assert(diff.length >= 2, "Should show at least 2 new tools");
    
    writeln("  ✓ Additional tool detection works");
}

unittest
{
    writeln("TEST: SystemInfo CPU core detection");
    
    auto sys = SystemInfo.detect();
    
    // Should detect at least 1 core
    assert(sys.cpuCores >= 1, "Should have at least 1 CPU core");
    
    // Sanity check - unlikely to have more than 1024 cores
    assert(sys.cpuCores <= 1024, "CPU core count seems unreasonably high");
    
    writeln("  ✓ CPU core detection is reasonable");
}

unittest
{
    writeln("TEST: BuildEnvironment version string length limits");
    
    // Test that version strings are reasonably sized (not full output)
    auto env = BuildEnvironment.snapshot();
    
    foreach (pair; env.toolVersions.byKeyValue)
    {
        assert(pair.value.length <= 200, 
               "Version string for " ~ pair.key ~ " should be limited to 200 chars");
    }
    
    writeln("  ✓ Version string length limits work");
}

unittest
{
    writeln("TEST: BuildEnvironment multiple snapshots");
    
    auto env1 = BuildEnvironment.snapshot();
    auto env2 = BuildEnvironment.snapshot();
    auto env3 = BuildEnvironment.snapshot();
    
    // All snapshots should be compatible (taken immediately after each other)
    assert(env1.isCompatible(env2), "Consecutive snapshots should be compatible");
    assert(env2.isCompatible(env3), "Consecutive snapshots should be compatible");
    assert(env1.isCompatible(env3), "Consecutive snapshots should be compatible");
    
    writeln("  ✓ Multiple snapshots are consistent");
}

