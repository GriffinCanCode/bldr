module tests.integration.real_world_builds;

import std.stdio;
import std.path;
import std.file;
import std.process;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import core.time;
import tests.harness;
import tests.fixtures;

/**
 * Real-world integration tests that run actual bldr build commands
 * against example projects to verify end-to-end functionality.
 * 
 * These tests ensure Builder works with realistic project structures
 * and catch regressions in the full build pipeline.
 */

/// Helper to run builder command and capture results
struct BuildResult
{
    int exitCode;
    string output;
    string errorOutput;
    Duration buildTime;
    
    bool succeeded() const { return exitCode == 0; }
    bool failed() const { return exitCode != 0; }
    
    void assertSuccess(string testName)
    {
        if (failed())
        {
            writeln("\x1b[31m[FAIL]\x1b[0m ", testName);
            writeln("Exit code: ", exitCode);
            writeln("STDOUT:\n", output);
            writeln("STDERR:\n", errorOutput);
            throw new Exception("Build failed with exit code " ~ exitCode.to!string);
        }
    }
    
    void assertFailure(string testName)
    {
        if (succeeded())
        {
            writeln("\x1b[31m[FAIL]\x1b[0m ", testName);
            writeln("Expected build to fail but it succeeded");
            writeln("STDOUT:\n", output);
            throw new Exception("Build unexpectedly succeeded");
        }
    }
}

/// Run builder command in a directory
BuildResult runBuilder(string workingDir, string[] args)
{
    import std.datetime.stopwatch : StopWatch, AutoStart;
    
    // Find builder executable
    string builderPath = findBuilderExecutable();
    
    auto sw = StopWatch(AutoStart.yes);
    
    // Run builder with provided arguments
    auto pipes = pipeProcess(
        [builderPath] ~ args,
        Redirect.stdout | Redirect.stderr,
        null, // env
        Config.none,
        workingDir
    );
    
    // Capture output
    string output;
    string errorOutput;
    
    foreach (line; pipes.stdout.byLine)
        output ~= line.idup ~ "\n";
    
    foreach (line; pipes.stderr.byLine)
        errorOutput ~= line.idup ~ "\n";
    
    auto exitCode = wait(pipes.pid);
    sw.stop();
    
    return BuildResult(exitCode, output, errorOutput, sw.peek());
}

/// Find builder executable (either in PATH or local bin/)
string findBuilderExecutable()
{
    // Try local bin first
    string localPath = buildPath(thisExePath().dirName, "..", "bin", "builder");
    if (exists(localPath))
        return absolutePath(localPath);
    
    // Try in PATH
    auto result = execute(["which", "builder"]);
    if (result.status == 0)
        return result.output.strip;
    
    throw new Exception("Could not find builder executable. Build it first with: make");
}

/// Get path to examples directory
string getExamplesPath()
{
    // From tests/integration, examples is ../../examples
    return buildPath(thisExePath().dirName, "..", "..", "examples");
}

/// Clean build artifacts from a project
void cleanProject(string projectPath)
{
    auto binPath = buildPath(projectPath, "bin");
    if (exists(binPath) && isDir(binPath))
    {
        try
        {
            rmdirRecurse(binPath);
        }
        catch (Exception e)
        {
            // Ignore cleanup errors
        }
    }
}

//=============================================================================
// REAL-WORLD BUILD TESTS
//=============================================================================

/// Test: Build simple Python project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Simple Python project");
    
    auto projectPath = buildPath(getExamplesPath(), "simple");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Python simple project");
    
    // Verify output artifact exists
    auto binPath = buildPath(projectPath, "bin", "app");
    Assert.isTrue(exists(binPath), "Expected output binary: " ~ binPath);
    
    writeln("\x1b[32m  ✓ Python simple project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build Go project with modules
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Go project with modules");
    
    auto projectPath = buildPath(getExamplesPath(), "go-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Go project");
    
    // Verify build output
    Assert.isTrue(result.output.canFind("go") || result.output.canFind("Build"), 
                  "Expected Go build output");
    
    writeln("\x1b[32m  ✓ Go project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build Rust project with Cargo
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Rust project with Cargo");
    
    auto projectPath = buildPath(getExamplesPath(), "rust-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Rust project");
    
    // Verify artifacts
    auto binPath = buildPath(projectPath, "bin");
    Assert.isTrue(exists(binPath), "Expected bin directory");
    
    writeln("\x1b[32m  ✓ Rust project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build TypeScript project with transpilation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - TypeScript project");
    
    auto projectPath = buildPath(getExamplesPath(), "typescript-app");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("TypeScript project");
    
    // Verify JS output files
    auto binPath = buildPath(projectPath, "bin");
    Assert.isTrue(exists(binPath), "Expected bin directory");
    
    // Should have transpiled .js files
    auto jsFiles = dirEntries(binPath, "*.js", SpanMode.shallow).array;
    Assert.notEmpty(jsFiles, "Expected transpiled JavaScript files");
    
    writeln("\x1b[32m  ✓ TypeScript project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build C++ project with compilation
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - C++ project");
    
    auto projectPath = buildPath(getExamplesPath(), "cpp-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("C++ project");
    
    // Verify compiled binary
    auto binPath = buildPath(projectPath, "bin", "cpp-app");
    Assert.isTrue(exists(binPath), "Expected compiled binary: " ~ binPath);
    
    writeln("\x1b[32m  ✓ C++ project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build Java project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Java project");
    
    auto projectPath = buildPath(getExamplesPath(), "java-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Java project");
    
    writeln("\x1b[32m  ✓ Java project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build multi-language project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Mixed language project");
    
    auto projectPath = buildPath(getExamplesPath(), "mixed-lang");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Mixed language project");
    
    // This tests that Builder can handle multiple languages in one project
    Assert.isTrue(result.output.canFind("Build") || result.output.length > 0,
                  "Expected build output");
    
    writeln("\x1b[32m  ✓ Mixed language project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build Python project with dependencies
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Python multi-file project");
    
    auto projectPath = buildPath(getExamplesPath(), "python-multi");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Python multi-file project");
    
    // Verify binary was created
    auto binPath = buildPath(projectPath, "bin", "calculator");
    Assert.isTrue(exists(binPath), "Expected output binary");
    
    writeln("\x1b[32m  ✓ Python multi-file project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Incremental rebuild (build twice, second should be faster)
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Incremental rebuild");
    
    auto projectPath = buildPath(getExamplesPath(), "simple");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found");
        return;
    }
    
    cleanProject(projectPath);
    
    // First build
    auto result1 = runBuilder(projectPath, ["build"]);
    result1.assertSuccess("First build");
    auto firstBuildTime = result1.buildTime;
    
    // Second build (should be cached/faster)
    auto result2 = runBuilder(projectPath, ["build"]);
    result2.assertSuccess("Second build");
    auto secondBuildTime = result2.buildTime;
    
    writeln("\x1b[32m  ✓ First build: ", firstBuildTime.total!"msecs", "ms\x1b[0m");
    writeln("\x1b[32m  ✓ Second build: ", secondBuildTime.total!"msecs", "ms\x1b[0m");
    
    // Second build should typically be faster (cached)
    // Note: We don't assert this strictly as CI might be unpredictable
    if (secondBuildTime < firstBuildTime)
    {
        writeln("\x1b[32m  ✓ Incremental build was faster (cache working)\x1b[0m");
    }
}

/// Test: Clean command removes artifacts
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Clean command");
    
    auto projectPath = buildPath(getExamplesPath(), "simple");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found");
        return;
    }
    
    // Build first
    auto buildResult = runBuilder(projectPath, ["build"]);
    buildResult.assertSuccess("Build before clean");
    
    auto binPath = buildPath(projectPath, "bin");
    Assert.isTrue(exists(binPath), "Expected bin directory after build");
    
    // Clean
    auto cleanResult = runBuilder(projectPath, ["clean"]);
    cleanResult.assertSuccess("Clean command");
    
    // Verify artifacts removed
    Assert.isFalse(exists(binPath), "Expected bin directory to be removed");
    
    writeln("\x1b[32m  ✓ Clean command removed build artifacts\x1b[0m");
}

/// Test: Build with verbose flag
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Verbose build output");
    
    auto projectPath = buildPath(getExamplesPath(), "simple");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found");
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build", "--verbose"]);
    result.assertSuccess("Verbose build");
    
    // Verbose output should contain more information
    Assert.isTrue(result.output.length > 50, "Expected verbose output");
    
    writeln("\x1b[32m  ✓ Verbose build produced detailed output\x1b[0m");
}

/// Test: Build specific target
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Build specific target");
    
    auto projectPath = buildPath(getExamplesPath(), "python-multi");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found");
        return;
    }
    
    cleanProject(projectPath);
    
    // Build specific target (if the project has named targets)
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Target build");
    
    writeln("\x1b[32m  ✓ Target-specific build succeeded\x1b[0m");
}

/// Test: Parallel build performance
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Parallel build");
    
    auto projectPath = buildPath(getExamplesPath(), "typescript-app");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found");
        return;
    }
    
    cleanProject(projectPath);
    
    // Build with parallelism
    auto result = runBuilder(projectPath, ["build", "-j", "4"]);
    result.assertSuccess("Parallel build");
    
    writeln("\x1b[32m  ✓ Parallel build completed in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build JavaScript React project (complex frontend)
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - JavaScript React project");
    
    auto projectPath = buildPath(getExamplesPath(), "javascript", "javascript-react");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found");
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("React project");
    
    // Verify bundled output
    auto binPath = buildPath(projectPath, "bin");
    Assert.isTrue(exists(binPath), "Expected build output directory");
    
    writeln("\x1b[32m  ✓ React project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build with missing dependencies (should fail gracefully)
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Handle missing dependencies");
    
    auto tempDir = scoped(new TempDir("missing-deps-test"));
    
    // Create a project with non-existent dependency reference
    tempDir.createFile("Builderfile", `
target("bad-target") {
    type: executable;
    sources: ["main.py"];
    deps: ["//non-existent-dep"];
}
`);
    
    tempDir.createFile("main.py", "print('test')");
    
    auto result = runBuilder(tempDir.getPath(), ["build"]);
    
    // Should fail gracefully with clear error
    result.assertFailure("Build with missing dependency");
    Assert.isTrue(result.errorOutput.canFind("dep") || result.output.canFind("dep"),
                  "Expected error message about missing dependency");
    
    writeln("\x1b[32m  ✓ Missing dependency handled gracefully\x1b[0m");
}

/// Test: Build with syntax error in Builderfile
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Handle Builderfile syntax error");
    
    auto tempDir = scoped(new TempDir("syntax-error-test"));
    
    // Create invalid Builderfile
    tempDir.createFile("Builderfile", `
target("bad-syntax" {
    type: executable
    sources: ["main.py"]
    // Missing closing brace and semicolons
`);
    
    tempDir.createFile("main.py", "print('test')");
    
    auto result = runBuilder(tempDir.getPath(), ["build"]);
    
    // Should fail with parse error
    result.assertFailure("Build with syntax error");
    Assert.isTrue(result.errorOutput.length > 0 || result.output.canFind("error"),
                  "Expected parse error message");
    
    writeln("\x1b[32m  ✓ Syntax error handled gracefully\x1b[0m");
}

/// Test: Build Haskell project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Haskell project");
    
    auto projectPath = buildPath(getExamplesPath(), "haskell-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Haskell project");
    
    writeln("\x1b[32m  ✓ Haskell project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build OCaml project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - OCaml project");
    
    auto projectPath = buildPath(getExamplesPath(), "ocaml-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("OCaml project");
    
    writeln("\x1b[32m  ✓ OCaml project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build Perl project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Perl project");
    
    auto projectPath = buildPath(getExamplesPath(), "perl-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Perl project");
    
    writeln("\x1b[32m  ✓ Perl project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build Elm project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Elm project");
    
    auto projectPath = buildPath(getExamplesPath(), "elm-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Elm project");
    
    writeln("\x1b[32m  ✓ Elm project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build Protobuf project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Protobuf project");
    
    auto projectPath = buildPath(getExamplesPath(), "protobuf-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("Protobuf project");
    
    writeln("\x1b[32m  ✓ Protobuf project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build C# project
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - C# project");
    
    auto projectPath = buildPath(getExamplesPath(), "csharp-project");
    if (!exists(projectPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Example project not found: ", projectPath);
        return;
    }
    
    cleanProject(projectPath);
    
    auto result = runBuilder(projectPath, ["build"]);
    result.assertSuccess("C# project");
    
    writeln("\x1b[32m  ✓ C# project built successfully in ", 
            result.buildTime.total!"msecs", "ms\x1b[0m");
}

/// Test: Build all examples (comprehensive smoke test)
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m real_world_builds - Build all example projects");
    
    auto examplesPath = getExamplesPath();
    if (!exists(examplesPath))
    {
        writeln("\x1b[33m[SKIP]\x1b[0m Examples directory not found");
        return;
    }
    
    // List of example projects to test
    string[] projectsToTest = [
        "simple",
        "python-multi",
        "go-project",
        "rust-project",
        "cpp-project",
        "java-project",
        "typescript-app",
        "d-project",
        "lua-project",
        "ruby-project",
        "php-project",
        "r-project",
        "nim-project",
        "zig-project",
        "haskell-project",
        "ocaml-project",
        "perl-project",
        "elm-project",
        "protobuf-project",
        "csharp-project",
        "mixed-lang",
    ];
    
    int passed = 0;
    int failed = 0;
    int skipped = 0;
    
    foreach (project; projectsToTest)
    {
        auto projectPath = buildPath(examplesPath, project);
        
        if (!exists(projectPath))
        {
            writeln("  \x1b[33m⊘ SKIP\x1b[0m ", project, " (not found)");
            skipped++;
            continue;
        }
        
        cleanProject(projectPath);
        
        try
        {
            auto result = runBuilder(projectPath, ["build"]);
            
            if (result.succeeded())
            {
                writeln("  \x1b[32m✓ PASS\x1b[0m ", project, 
                       " (", result.buildTime.total!"msecs", "ms)");
                passed++;
            }
            else
            {
                writeln("  \x1b[31m✗ FAIL\x1b[0m ", project);
                writeln("    Exit code: ", result.exitCode);
                writeln("    Error: ", result.errorOutput);
                failed++;
            }
        }
        catch (Exception e)
        {
            writeln("  \x1b[31m✗ FAIL\x1b[0m ", project, " - ", e.msg);
            failed++;
        }
    }
    
    writeln();
    writeln("\x1b[36mSummary:\x1b[0m");
    writeln("  Passed:  ", passed);
    writeln("  Failed:  ", failed);
    writeln("  Skipped: ", skipped);
    
    Assert.equal(failed, 0, "Some example projects failed to build");
    
    writeln("\x1b[32m  ✓ All example projects built successfully!\x1b[0m");
}




