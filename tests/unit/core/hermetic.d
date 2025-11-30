module tests.unit.core.hermetic;

import std.stdio : writeln;
import std.file : exists, mkdirRecurse, remove, write, readText, tempDir, rmdirRecurse;
import std.path : buildPath, absolutePath;
import std.process : execute;
import std.exception : collectException;
import engine.runtime.hermetic;
import tests.harness;

@("hermetic.spec.creation")
@system unittest
{
    writeln("Testing hermetic spec creation...");
    
    // Test basic spec creation
    auto builder = SandboxSpecBuilder.create()
        .input("/usr/lib")
        .output("/tmp/output")
        .temp("/tmp/work");
    
    auto result = builder.build();
    assert(result.isOk, "Failed to create spec");
    
    auto spec = result.unwrap();
    
    // Test path containment
    assert(spec.canRead("/usr/lib"), "Should allow reading input paths");
    assert(!spec.canWrite("/usr/lib"), "Should not allow writing input paths");
    assert(spec.canWrite("/tmp/output"), "Should allow writing output paths");
    assert(spec.canRead("/tmp/work") && spec.canWrite("/tmp/work"), "Should allow read-write on temp paths");
}

@("hermetic.spec.validation")
@system unittest
{
    writeln("Testing hermetic spec validation...");
    
    // Test overlap detection (should fail)
    auto badBuilder = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/workspace/bin");  // Overlaps with input
    
    auto result = badBuilder.build();
    assert(result.isErr, "Should detect path overlap");
    
    // Test hermetic network (should fail)
    auto networkBuilder = SandboxSpecBuilder.create()
        .input("/workspace")
        .output("/tmp/output")
        .withNetwork(NetworkPolicy(true, true, false, false, []));  // hermetic=true but allowHttp=true
    
    result = networkBuilder.build();
    assert(result.isErr, "Should detect network policy violation");
}

@("hermetic.spec.set_operations")
@safe unittest
{
    writeln("Testing PathSet set operations...");
    
    // Test union
    PathSet set1;
    set1.add("/a");
    set1.add("/b");
    
    PathSet set2;
    set2.add("/b");
    set2.add("/c");
    
    auto union_ = set1.union_(set2);
    assert(union_.contains("/a"), "Union should contain /a");
    assert(union_.contains("/b"), "Union should contain /b");
    assert(union_.contains("/c"), "Union should contain /c");
    
    // Test intersection
    auto intersection = set1.intersection(set2);
    assert(intersection.paths.length == 1, "Intersection should have 1 element");
    assert(intersection.contains("/b"), "Intersection should contain /b");
    
    // Test disjoint
    PathSet set3;
    set3.add("/x");
    set3.add("/y");
    
    assert(set1.disjoint(set3), "Sets should be disjoint");
    assert(!set1.disjoint(set2), "Sets should not be disjoint");
}

@("hermetic.spec.path_containment")
@safe unittest
{
    writeln("Testing path containment...");
    
    PathSet set;
    set.add("/workspace");
    
    // Test exact match
    assert(set.contains("/workspace"), "Should contain exact path");
    
    // Test subpath
    assert(set.contains("/workspace/src"), "Should contain subpath");
    assert(set.contains("/workspace/src/main.d"), "Should contain nested subpath");
    
    // Test non-contained
    assert(!set.contains("/other"), "Should not contain unrelated path");
    assert(!set.contains("/work"), "Should not contain prefix-only match");
}

@("hermetic.spec.builder_helpers")
@system unittest
{
    writeln("Testing spec builder helpers...");
    
    // Test forBuild helper
    auto buildSpec = HermeticSpecBuilder.forBuild(
        "/workspace",
        ["/workspace/main.d"],
        "/workspace/bin",
        "/tmp/build"
    );
    
    assert(buildSpec.isOk, "Should create build spec");
    auto spec = buildSpec.unwrap();
    assert(spec.canRead("/workspace"), "Should allow reading workspace");
    assert(spec.canWrite("/workspace/bin"), "Should allow writing to bin");
    assert(!spec.canNetwork(), "Build should be hermetic (no network)");
    
    // Test forTest helper
    auto testSpec = HermeticSpecBuilder.forTest(
        "/workspace",
        "/workspace/tests",
        "/tmp/test"
    );
    
    assert(testSpec.isOk, "Should create test spec");
}

@("hermetic.executor.creation")
@system unittest
{
    writeln("Testing hermetic executor creation...");
    
    auto spec = SandboxSpecBuilder.create()
        .input("/usr/lib")
        .output(buildPath(tempDir(), "hermetic-test-output"))
        .temp(buildPath(tempDir(), "hermetic-test-temp"))
        .build();
    
    assert(spec.isOk, "Should create spec");
    
    auto executorResult = HermeticExecutor.create(spec.unwrap());
    assert(executorResult.isOk, "Should create executor: " ~ 
        (executorResult.isErr ? executorResult.unwrapErr().toString() : ""));
}

@("hermetic.executor.platform")
@system unittest
{
    writeln("Testing platform detection...");
    
    auto platform = HermeticExecutor.platform();
    writeln("  Platform: ", platform);
    
    version(linux)
        assert(platform == "linux-namespaces", "Should detect Linux");
    else version(OSX)
        assert(platform == "macos-sandbox", "Should detect macOS");
    
    auto supported = HermeticExecutor.isSupported();
    writeln("  Supported: ", supported);
}

@("hermetic.executor.simple_execution")
@system unittest
{
    writeln("Testing simple hermetic execution...");
    
    // Create temp directories
    auto outputDir = buildPath(tempDir(), "hermetic-test-exec-output");
    auto tempWorkDir = buildPath(tempDir(), "hermetic-test-exec-temp");
    
    if (!exists(outputDir))
        mkdirRecurse(outputDir);
    if (!exists(tempWorkDir))
        mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(outputDir))
            collectException(rmdirRecurse(outputDir));
        if (exists(tempWorkDir))
            collectException(rmdirRecurse(tempWorkDir));
    }
    
    // Create spec
    auto spec = SandboxSpecBuilder.create()
        .input("/usr")
        .input("/bin")
        .input("/lib")
        .output(outputDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .build();
    
    if (spec.isErr)
    {
        Assert.fail("Failed to create spec: " ~ spec.unwrapErr());
    }
    
    // Create executor
    auto executorResult = HermeticExecutor.create(spec.unwrap(), tempWorkDir);
    if (executorResult.isErr)
    {
        Assert.fail("Failed to create executor: " ~ executorResult.unwrapErr().toString());
    }
    
    auto executor = executorResult.unwrap();
    
    // Execute simple command
    auto result = executor.execute(["echo", "hello"], tempWorkDir);
    
    if (result.isErr)
    {
        Assert.fail("Execution failed: " ~ result.unwrapErr().toString());
    }
    
    auto output = result.unwrap();
    writeln("  Output: ", output.stdout);
    writeln("  Exit code: ", output.exitCode);
    writeln("  Hermetic: ", output.hermetic);
    
    assert(output.success(), "Should execute successfully");
}

@("hermetic.executor.filesystem_isolation")
@system unittest
{
    writeln("Testing filesystem isolation...");
    
    // Create temp structure
    auto testRoot = buildPath(tempDir(), "hermetic-fs-test");
    auto inputDir = buildPath(testRoot, "input");
    auto outputDir = buildPath(testRoot, "output");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(inputDir))
        mkdirRecurse(inputDir);
    if (!exists(outputDir))
        mkdirRecurse(outputDir);
    if (!exists(tempWorkDir))
        mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    // Create input file
    auto inputFile = buildPath(inputDir, "input.txt");
    write(inputFile, "test input");
    
    // Create spec
    auto spec = SandboxSpecBuilder.create()
        .input(inputDir)
        .input("/usr")
        .input("/bin")
        .output(outputDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .build();
    
    if (spec.isErr)
    {
        Assert.fail("Failed to create spec: " ~ spec.unwrapErr());
    }
    
    auto executorResult = HermeticExecutor.create(spec.unwrap(), tempWorkDir);
    if (executorResult.isErr)
    {
        Assert.fail("Failed to create executor: " ~ executorResult.unwrapErr().toString());
    }
    
    auto executor = executorResult.unwrap();
    
    // Try to read input file (should work)
    auto readResult = executor.execute(["cat", inputFile], tempWorkDir);
    if (readResult.isOk)
    {
        writeln("  Read input: success");
    }
    else
    {
        writeln("  Read input: ", readResult.unwrapErr().toString());
    }
    
    // Try to write to output (should work)
    auto outputFile = buildPath(outputDir, "output.txt");
    version(Posix)
    {
        auto writeResult = executor.execute(
            ["sh", "-c", "echo test > " ~ outputFile],
            tempWorkDir
        );
        
        if (writeResult.isOk)
        {
            writeln("  Write output: success");
        }
        else
        {
            writeln("  Write output: ", writeResult.unwrapErr().toString());
        }
    }
}

@("hermetic.network_isolation")
@system unittest
{
    writeln("Testing network isolation...");
    
    // Create hermetic spec (no network)
    auto tempWorkDir = buildPath(tempDir(), "hermetic-net-test");
    if (!exists(tempWorkDir))
        mkdirRecurse(tempWorkDir);
    
    scope(exit)
    {
        if (exists(tempWorkDir))
            collectException(rmdirRecurse(tempWorkDir));
    }
    
    auto spec = SandboxSpecBuilder.create()
        .input("/usr")
        .input("/bin")
        .temp(tempWorkDir)
        .withNetwork(NetworkPolicy.hermetic())
        .env("PATH", "/usr/bin:/bin")
        .build();
    
    assert(spec.isOk, "Should create hermetic spec");
    assert(!spec.unwrap().canNetwork(), "Should not allow network");
    
    // Note: Actually testing network isolation requires executing and
    // attempting network operations, which may not be reliable in all
    // test environments. The spec validation is the key test here.
}

@("hermetic.resource_limits")
@safe unittest
{
    writeln("Testing resource limits...");
    
    // Create spec with resource limits
    auto limits = ResourceLimits.hermetic();
    assert(limits.maxMemoryBytes == 4UL * 1024 * 1024 * 1024, "Should set 4GB memory limit");
    assert(limits.maxCpuTimeMs > 0, "Should set CPU time limit");
    assert(limits.maxProcesses == 128, "Should set process limit");
    
    // Test custom limits
    ResourceLimits custom;
    custom.maxMemoryBytes = 1024 * 1024 * 1024;  // 1GB
    custom.maxCpuTimeMs = 60 * 1000;  // 1 minute
    custom.maxProcesses = 32;
    
    auto spec = SandboxSpecBuilder.create()
        .input("/usr")
        .temp("/tmp")
        .withResources(custom)
        .build();
    
    assert(spec.isOk, "Should create spec with custom limits");
}

// Run all tests
version(unittest)
{
    static this()
    {
        writeln("=== Hermetic Execution Tests ===");
    }
}
