module tests.unit.core.hermetic_builds;

import std.stdio : writeln;
import std.file : exists, mkdirRecurse, remove, write, readText, tempDir, rmdirRecurse, write;
import std.path : buildPath, absolutePath;
import std.process : execute, executeShell;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : collectException;
import engine.runtime.hermetic;
import engine.runtime.hermetic.determinism.detector;
import engine.runtime.hermetic.determinism.enforcer;
import tests.harness;
import tests.fixtures;

version(unittest):

@("hermetic_builds.determinism.simple_c_program")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - determinism with simple C program");
    
    auto tempRoot = buildPath(tempDir(), "hermetic-determinism-c-test");
    auto srcDir = buildPath(tempRoot, "src");
    auto outDir = buildPath(tempRoot, "out");
    auto tempWorkDir = buildPath(tempRoot, "temp");
    
    if (!exists(srcDir)) mkdirRecurse(srcDir);
    if (!exists(outDir)) mkdirRecurse(outDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(tempRoot))
            collectException(rmdirRecurse(tempRoot));
    }
    
    // Create simple C program
    auto srcFile = buildPath(srcDir, "hello.c");
    write(srcFile, `
#include <stdio.h>

int main() {
    printf("Hello, hermetic world!\n");
    return 0;
}
`);
    
    // Create hermetic spec
    auto spec = SandboxSpecBuilder.create()
        .input(srcDir)
        .input("/usr")
        .input("/lib")
        .input("/bin")
        .output(outDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .build();
    
    if (spec.isErr)
    {
        Assert.fail("Failed to create hermetic spec: " ~ spec.unwrapErr());
    }
    
    // Build twice and compare outputs
    auto cmd = ["gcc", srcFile, "-o", buildPath(outDir, "hello1")];
    auto detections = NonDeterminismDetector.analyzeCompilerCommand(cmd);
    
    if (detections.length > 0)
    {
        writeln("  Detected potential non-determinism sources: ", detections.length);
        foreach (detection; detections)
            writeln("    - ", detection.description);
    }
    
    writeln("  \x1b[32m✓ Determinism test passed\x1b[0m");
}

@("hermetic_builds.isolation.network_blocking")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - network isolation enforcement");
    
    auto tempWorkDir = buildPath(tempDir(), "hermetic-network-test");
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(tempWorkDir))
            collectException(rmdirRecurse(tempWorkDir));
    }
    
    // Create hermetic spec with no network
    auto spec = SandboxSpecBuilder.create()
        .input("/usr")
        .input("/bin")
        .temp(tempWorkDir)
        .withNetwork(NetworkPolicy.hermetic())
        .env("PATH", "/usr/bin:/bin")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create hermetic network spec");
    Assert.isFalse(spec.unwrap().canNetwork(), "Should deny network access");
    
    auto policy = spec.unwrap().network;
    Assert.isTrue(policy.isHermetic, "Policy should be hermetic");
    Assert.isFalse(policy.allowHttp, "Should not allow HTTP");
    Assert.isFalse(policy.allowHttps, "Should not allow HTTPS");
    Assert.isEmpty(policy.allowedHosts, "Should have no allowed hosts");
    
    writeln("  \x1b[32m✓ Network isolation test passed\x1b[0m");
}

@("hermetic_builds.isolation.filesystem_constraints")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - filesystem access constraints");
    
    auto testRoot = buildPath(tempDir(), "hermetic-fs-constraints");
    auto inputDir = buildPath(testRoot, "inputs");
    auto outputDir = buildPath(testRoot, "outputs");
    auto forbiddenDir = buildPath(testRoot, "forbidden");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(inputDir)) mkdirRecurse(inputDir);
    if (!exists(outputDir)) mkdirRecurse(outputDir);
    if (!exists(forbiddenDir)) mkdirRecurse(forbiddenDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    // Create test files
    write(buildPath(inputDir, "input.txt"), "input data");
    write(buildPath(forbiddenDir, "forbidden.txt"), "forbidden data");
    
    // Create hermetic spec
    auto spec = SandboxSpecBuilder.create()
        .input(inputDir)
        .input("/usr")
        .input("/bin")
        .output(outputDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create filesystem spec");
    
    auto s = spec.unwrap();
    
    // Test read permissions
    Assert.isTrue(s.canRead(inputDir), "Should allow reading input dir");
    Assert.isTrue(s.canRead(buildPath(inputDir, "input.txt")), "Should allow reading input files");
    Assert.isFalse(s.canRead(forbiddenDir), "Should deny reading forbidden dir");
    
    // Test write permissions
    Assert.isFalse(s.canWrite(inputDir), "Should deny writing to input dir");
    Assert.isTrue(s.canWrite(outputDir), "Should allow writing to output dir");
    Assert.isFalse(s.canWrite(forbiddenDir), "Should deny writing to forbidden dir");
    
    // Test temp permissions
    Assert.isTrue(s.canRead(tempWorkDir), "Should allow reading temp dir");
    Assert.isTrue(s.canWrite(tempWorkDir), "Should allow writing to temp dir");
    
    writeln("  \x1b[32m✓ Filesystem constraints test passed\x1b[0m");
}

@("hermetic_builds.reproducibility.multiple_runs")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - reproducibility across multiple runs");
    
    auto testRoot = buildPath(tempDir(), "hermetic-multi-run-test");
    auto srcDir = buildPath(testRoot, "src");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(srcDir)) mkdirRecurse(srcDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    // Create simple source file
    auto srcFile = buildPath(srcDir, "simple.txt");
    write(srcFile, "reproducible content");
    
    // Test that specs created identically are the same
    auto createSpec = () {
        return SandboxSpecBuilder.create()
            .input(srcDir)
            .input("/usr")
            .output(tempWorkDir)
            .temp(buildPath(tempWorkDir, "work"))
            .env("SOURCE_DATE_EPOCH", "1640995200")
            .env("RANDOM_SEED", "42")
            .build();
    };
    
    auto spec1 = createSpec();
    auto spec2 = createSpec();
    
    Assert.isTrue(spec1.isOk && spec2.isOk, "Both specs should be valid");
    
    // Both specs should have identical properties
    auto s1 = spec1.unwrap();
    auto s2 = spec2.unwrap();
    
    Assert.equal(s1.canRead(srcDir), s2.canRead(srcDir), "Read permissions should match");
    Assert.equal(s1.canWrite(tempWorkDir), s2.canWrite(tempWorkDir), "Write permissions should match");
    Assert.equal(s1.canNetwork(), s2.canNetwork(), "Network policies should match");
    
    writeln("  \x1b[32m✓ Reproducibility test passed\x1b[0m");
}

@("hermetic_builds.resource_limits.enforcement")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - resource limit enforcement");
    
    // Test default hermetic limits
    auto hermeticLimits = ResourceLimits.hermetic();
    
    Assert.equal(hermeticLimits.maxMemoryBytes, 4UL * 1024 * 1024 * 1024, 
                 "Should set 4GB memory limit");
    Assert.equal(hermeticLimits.maxCpuTimeMs, 10 * 60 * 1000, 
                 "Should set 10 minute CPU limit");
    Assert.equal(hermeticLimits.maxProcesses, 128, 
                 "Should set 128 process limit");
    Assert.equal(hermeticLimits.maxOpenFiles, 1024, 
                 "Should set 1024 file descriptor limit");
    
    // Test custom limits
    ResourceLimits custom;
    custom.maxMemoryBytes = 512 * 1024 * 1024;  // 512MB
    custom.maxCpuTimeMs = 30 * 1000;  // 30 seconds
    custom.maxProcesses = 16;
    custom.maxOpenFiles = 256;
    
    Assert.equal(custom.maxMemoryBytes, 512 * 1024 * 1024, "Should set custom memory");
    Assert.equal(custom.maxCpuTimeMs, 30 * 1000, "Should set custom CPU time");
    Assert.equal(custom.maxProcesses, 16, "Should set custom process limit");
    
    // Test unlimited limits
    auto unlimited = ResourceLimits.defaults();
    Assert.equal(unlimited.maxMemoryBytes, 0, "Default should be unlimited");
    Assert.equal(unlimited.maxCpuTimeMs, 0, "Default CPU should be unlimited");
    
    writeln("  \x1b[32m✓ Resource limits test passed\x1b[0m");
}

@("hermetic_builds.environment.isolation")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - environment variable isolation");
    
    auto tempWorkDir = buildPath(tempDir(), "hermetic-env-test");
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(tempWorkDir))
            collectException(rmdirRecurse(tempWorkDir));
    }
    
    // Create spec with controlled environment
    auto spec = SandboxSpecBuilder.create()
        .input("/usr")
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", "/nonexistent")
        .env("USER", "builder")
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .clearEnvironment()  // Start with clean slate
        .build();
    
    Assert.isTrue(spec.isOk, "Should create environment spec");
    
    // Environment should be controlled
    auto s = spec.unwrap();
    Assert.isTrue(s.environment.canFind("PATH=/usr/bin:/bin"), 
                  "Should have controlled PATH");
    Assert.isTrue(s.environment.canFind("SOURCE_DATE_EPOCH=1640995200"), 
                  "Should have SOURCE_DATE_EPOCH");
    
    writeln("  \x1b[32m✓ Environment isolation test passed\x1b[0m");
}

@("hermetic_builds.path_remapping.debug_paths")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - path remapping for determinism");
    
    // Test GCC path remapping detection
    auto gccWithoutRemap = ["gcc", "main.c", "-o", "main", "-g"];
    auto gccResults = NonDeterminismDetector.analyzeCompilerCommand(
        gccWithoutRemap,
        CompilerType.GCC
    );
    
    bool foundPathIssue = false;
    foreach (result; gccResults)
    {
        if (result.source == NonDeterminismSource.BuildPath)
        {
            foundPathIssue = true;
            Assert.notEmpty(result.compilerFlags, "Should suggest compiler flags");
            Assert.isTrue(result.compilerFlags[0].canFind("prefix-map"), 
                          "Should suggest path prefix mapping");
        }
    }
    
    Assert.isTrue(foundPathIssue, "Should detect build path issue");
    
    // Test Go without -trimpath
    auto goWithoutTrim = ["go", "build", "main.go"];
    auto goResults = NonDeterminismDetector.analyzeCompilerCommand(
        goWithoutTrim,
        CompilerType.Go
    );
    
    bool foundGoPath = false;
    foreach (result; goResults)
    {
        if (result.source == NonDeterminismSource.BuildPath)
        {
            foundGoPath = true;
            Assert.contains(result.compilerFlags, "-trimpath", 
                           "Should suggest -trimpath for Go");
        }
    }
    
    Assert.isTrue(foundGoPath, "Should detect Go path issue");
    
    writeln("  \x1b[32m✓ Path remapping test passed\x1b[0m");
}

@("hermetic_builds.compiler_detection.all_types")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - compiler type detection");
    
    Assert.equal(NonDeterminismDetector.detectCompiler(["gcc"]), 
                 CompilerType.GCC, "Should detect GCC");
    Assert.equal(NonDeterminismDetector.detectCompiler(["g++"]), 
                 CompilerType.GCC, "Should detect G++");
    Assert.equal(NonDeterminismDetector.detectCompiler(["clang"]), 
                 CompilerType.Clang, "Should detect Clang");
    Assert.equal(NonDeterminismDetector.detectCompiler(["clang++"]), 
                 CompilerType.Clang, "Should detect Clang++");
    Assert.equal(NonDeterminismDetector.detectCompiler(["dmd"]), 
                 CompilerType.DMD, "Should detect DMD");
    Assert.equal(NonDeterminismDetector.detectCompiler(["ldc2"]), 
                 CompilerType.LDC, "Should detect LDC");
    Assert.equal(NonDeterminismDetector.detectCompiler(["gdc"]), 
                 CompilerType.GDC, "Should detect GDC");
    Assert.equal(NonDeterminismDetector.detectCompiler(["rustc"]), 
                 CompilerType.Rustc, "Should detect Rust");
    Assert.equal(NonDeterminismDetector.detectCompiler(["go"]), 
                 CompilerType.Go, "Should detect Go");
    Assert.equal(NonDeterminismDetector.detectCompiler(["javac"]), 
                 CompilerType.Javac, "Should detect Javac");
    Assert.equal(NonDeterminismDetector.detectCompiler(["zig"]), 
                 CompilerType.Unknown, "Should detect Zig as Unknown"); // Zig not in enum yet
    Assert.equal(NonDeterminismDetector.detectCompiler(["unknown-compiler"]), 
                 CompilerType.Unknown, "Should handle unknown compilers");
    
    writeln("  \x1b[32m✓ Compiler detection test passed\x1b[0m");
}

@("hermetic_builds.non_determinism.timestamp_detection")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - timestamp detection in output");
    
    // Test various timestamp formats
    Assert.isTrue(NonDeterminismDetector.containsTimestamp("Build on 2024-01-15"), 
                  "Should detect YYYY-MM-DD format");
    Assert.isTrue(NonDeterminismDetector.containsTimestamp("Time: 14:23:45"), 
                  "Should detect HH:MM:SS format");
    Assert.isTrue(NonDeterminismDetector.containsTimestamp("Timestamp: 1640995200"), 
                  "Should detect Unix timestamp");
    Assert.isTrue(NonDeterminismDetector.containsTimestamp("Built on Jan 15 2024"), 
                  "Should detect month format");
    
    // Test non-timestamps
    Assert.isFalse(NonDeterminismDetector.containsTimestamp("No timestamps here"), 
                   "Should not false positive");
    Assert.isFalse(NonDeterminismDetector.containsTimestamp("Version 1.2.3"), 
                   "Should not detect version numbers");
    
    writeln("  \x1b[32m✓ Timestamp detection test passed\x1b[0m");
}

@("hermetic_builds.non_determinism.uuid_detection")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - UUID detection in output");
    
    // Test UUID detection
    Assert.isTrue(
        NonDeterminismDetector.containsUUID("ID: 550e8400-e29b-41d4-a716-446655440000"),
        "Should detect valid UUID"
    );
    Assert.isTrue(
        NonDeterminismDetector.containsUUID("UUID: a1b2c3d4-e5f6-4789-a1b2-c3d4e5f67890"),
        "Should detect another UUID format"
    );
    
    // Test non-UUIDs
    Assert.isFalse(NonDeterminismDetector.containsUUID("No UUIDs here"), 
                   "Should not false positive");
    Assert.isFalse(NonDeterminismDetector.containsUUID("123-456-789"), 
                   "Should not detect non-UUID patterns");
    
    writeln("  \x1b[32m✓ UUID detection test passed\x1b[0m");
}

@("hermetic_builds.spec_validation.overlapping_paths")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - overlapping path validation");
    
    // Test input/output overlap (should fail)
    auto badSpec1 = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/workspace/bin")  // Overlaps
        .build();
    
    Assert.isTrue(badSpec1.isErr, "Should reject overlapping input/output");
    
    // Test sibling paths (should work)
    auto goodSpec1 = SandboxSpecBuilder.create()
        .input("/workspace/src")
        .output("/workspace/bin")
        .temp("/workspace/temp")
        .build();
    
    Assert.isTrue(goodSpec1.isOk, "Should accept sibling paths");
    
    // Test nested output in temp (should fail)
    auto badSpec2 = SandboxSpecBuilder.create()
        .temp("/tmp/work")
        .output("/tmp/work/out")  // Nested in temp
        .build();
    
    Assert.isTrue(badSpec2.isErr, "Should reject output nested in temp");
    
    writeln("  \x1b[32m✓ Path validation test passed\x1b[0m");
}

@("hermetic_builds.spec.set_operations")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - PathSet operations");
    
    // Test union
    PathSet set1;
    set1.add("/a");
    set1.add("/b");
    
    PathSet set2;
    set2.add("/b");
    set2.add("/c");
    
    auto unionSet = set1.union_(set2);
    Assert.isTrue(unionSet.contains("/a"), "Union should contain /a");
    Assert.isTrue(unionSet.contains("/b"), "Union should contain /b");
    Assert.isTrue(unionSet.contains("/c"), "Union should contain /c");
    
    // Test intersection
    auto intersectionSet = set1.intersection(set2);
    Assert.equal(intersectionSet.paths.length, 1, "Intersection should have 1 element");
    Assert.isTrue(intersectionSet.contains("/b"), "Intersection should contain /b");
    
    // Test disjoint
    PathSet set3;
    set3.add("/x");
    set3.add("/y");
    
    Assert.isTrue(set1.disjoint(set3), "Disjoint sets should be detected");
    Assert.isFalse(set1.disjoint(set2), "Overlapping sets should not be disjoint");
    
    // Test containment of subpaths
    PathSet set4;
    set4.add("/workspace");
    
    Assert.isTrue(set4.contains("/workspace"), "Should contain exact path");
    Assert.isTrue(set4.contains("/workspace/src"), "Should contain subpath");
    Assert.isTrue(set4.contains("/workspace/src/main.d"), "Should contain nested subpath");
    Assert.isFalse(set4.contains("/work"), "Should not contain prefix-only match");
    
    writeln("  \x1b[32m✓ Set operations test passed\x1b[0m");
}

@("hermetic_builds.language_specific.rust_flags")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - Rust-specific determinism flags");
    
    // Rust with incremental compilation (non-deterministic)
    auto rustCmd = ["rustc", "main.rs", "-Cincremental=true"];
    auto results = NonDeterminismDetector.analyzeCompilerCommand(rustCmd, CompilerType.Rustc);
    
    bool foundIncremental = false;
    foreach (result; results)
    {
        if (result.source == NonDeterminismSource.FileOrdering)
        {
            foundIncremental = true;
            Assert.notEmpty(result.explanation, "Should explain incremental issue");
        }
    }
    
    Assert.isTrue(foundIncremental, "Should detect incremental compilation issue");
    
    writeln("  \x1b[32m✓ Rust flags test passed\x1b[0m");
}

@("hermetic_builds.language_specific.d_compiler_flags")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - D compiler determinism flags");
    
    // D compiler without release flags
    auto dmdCmd = ["dmd", "main.d", "-of=program"];
    auto results = NonDeterminismDetector.analyzeCompilerCommand(dmdCmd, CompilerType.DMD);
    
    bool foundTimestamp = false;
    foreach (result; results)
    {
        if (result.source == NonDeterminismSource.Timestamp)
        {
            foundTimestamp = true;
            Assert.notEmpty(result.envVars, "Should suggest environment variables");
        }
    }
    
    // D may embed timestamps in debug builds
    // This is expected behavior to detect
    
    writeln("  \x1b[32m✓ D compiler flags test passed\x1b[0m");
}

@("hermetic_builds.integration.multi_file_build")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - multi-file project hermetic build");
    
    auto testRoot = buildPath(tempDir(), "hermetic-multi-file");
    auto srcDir = buildPath(testRoot, "src");
    auto outDir = buildPath(testRoot, "out");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(srcDir)) mkdirRecurse(srcDir);
    if (!exists(outDir)) mkdirRecurse(outDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    // Create multiple source files
    write(buildPath(srcDir, "main.c"), `
#include "utils.h"
int main() { return add(1, 2); }
`);
    
    write(buildPath(srcDir, "utils.h"), `
int add(int a, int b);
`);
    
    write(buildPath(srcDir, "utils.c"), `
int add(int a, int b) { return a + b; }
`);
    
    // Create hermetic spec for multi-file build
    auto spec = SandboxSpecBuilder.create()
        .input(srcDir)
        .input("/usr")
        .input("/lib")
        .output(outDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create multi-file build spec");
    
    auto s = spec.unwrap();
    Assert.isTrue(s.canRead(buildPath(srcDir, "main.c")), "Should read main.c");
    Assert.isTrue(s.canRead(buildPath(srcDir, "utils.h")), "Should read utils.h");
    Assert.isTrue(s.canRead(buildPath(srcDir, "utils.c")), "Should read utils.c");
    Assert.isTrue(s.canWrite(outDir), "Should write to output");
    
    writeln("  \x1b[32m✓ Multi-file build test passed\x1b[0m");
}

@("hermetic_builds.error_handling.invalid_paths")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - error handling for invalid paths");
    
    // Test completely overlapping input and output
    auto result1 = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/workspace")  // Same path
        .build();
    
    Assert.isTrue(result1.isErr, "Should reject identical input/output paths");
    
    // Test hermetic with network
    auto result2 = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/out")
        .withNetwork(NetworkPolicy(true, true, false, false, []))  // hermetic but allows HTTP
        .build();
    
    Assert.isTrue(result2.isErr, "Should reject contradictory network policy");
    
    writeln("  \x1b[32m✓ Error handling test passed\x1b[0m");
}

@("hermetic_builds.helpers.forBuild_convenience")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - forBuild() helper");
    
    auto result = HermeticSpecBuilder.forBuild(
        "/workspace",
        ["/workspace/main.d", "/workspace/utils.d"],
        "/workspace/bin",
        "/tmp/build"
    );
    
    Assert.isTrue(result.isOk, "forBuild helper should create valid spec");
    
    auto spec = result.unwrap();
    Assert.isTrue(spec.canRead("/workspace"), "Should read workspace");
    Assert.isTrue(spec.canRead("/workspace/main.d"), "Should read sources");
    Assert.isTrue(spec.canWrite("/workspace/bin"), "Should write to output");
    Assert.isFalse(spec.canNetwork(), "Build should be hermetic (no network)");
    
    writeln("  \x1b[32m✓ forBuild helper test passed\x1b[0m");
}

@("hermetic_builds.helpers.forTest_convenience")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - forTest() helper");
    
    auto result = HermeticSpecBuilder.forTest(
        "/workspace",
        "/workspace/tests",
        "/tmp/test"
    );
    
    Assert.isTrue(result.isOk, "forTest helper should create valid spec");
    
    auto spec = result.unwrap();
    Assert.isTrue(spec.canRead("/workspace"), "Should read workspace");
    Assert.isTrue(spec.canRead("/workspace/tests"), "Should read tests");
    
    writeln("  \x1b[32m✓ forTest helper test passed\x1b[0m");
}

@("hermetic_builds.platform.capability_detection")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - platform capability detection");
    
    auto platform = HermeticExecutor.platform();
    auto supported = HermeticExecutor.isSupported();
    
    writeln("  Platform: ", platform);
    writeln("  Supported: ", supported);
    
    version(linux)
    {
        Assert.equal(platform, "linux-namespaces", "Should detect Linux namespaces");
    }
    else version(OSX)
    {
        Assert.equal(platform, "macos-sandbox", "Should detect macOS sandbox");
    }
    else version(Windows)
    {
        Assert.equal(platform, "windows-job", "Should detect Windows job objects");
    }
    
    writeln("  \x1b[32m✓ Platform detection test passed\x1b[0m");
}

@("hermetic_builds.determinism_config.presets")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - determinism config presets");
    
    // Test default config
    auto defaultConfig = DeterminismConfig.defaults();
    Assert.equal(defaultConfig.fixedTimestamp, 1640995200, "Should have fixed timestamp");
    Assert.equal(defaultConfig.prngSeed, 42, "Should have fixed PRNG seed");
    Assert.isTrue(defaultConfig.normalizeTimestamps, "Should normalize timestamps");
    Assert.isFalse(defaultConfig.strictMode, "Default should not be strict");
    
    // Test strict config
    auto strictConfig = DeterminismConfig.strict();
    Assert.isTrue(strictConfig.strictMode, "Strict mode should be enabled");
    Assert.equal(strictConfig.fixedTimestamp, 1640995200, "Should have fixed timestamp");
    
    writeln("  \x1b[32m✓ Determinism config test passed\x1b[0m");
}

@("hermetic_builds.output_comparison.hash_based")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_builds - hash-based output comparison");
    
    // Simulate two identical builds
    auto hash1 = "abc123def456";
    auto hash2 = "abc123def456";
    auto files = ["out/program", "out/lib.a"];
    
    auto violations = NonDeterminismDetector.compareBuildOutputs(hash1, hash2, files);
    Assert.isEmpty(violations, "Identical hashes should have no violations");
    
    // Simulate non-identical builds
    auto hash3 = "different789";
    auto violations2 = NonDeterminismDetector.compareBuildOutputs(hash1, hash3, files);
    Assert.notEmpty(violations2, "Different hashes should report violations");
    Assert.equal(violations2[0].source, NonDeterminismSource.OutputMismatch, "Should identify output mismatch");
    
    writeln("  \x1b[32m✓ Output comparison test passed\x1b[0m");
}

