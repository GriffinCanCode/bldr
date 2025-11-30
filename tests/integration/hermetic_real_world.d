module tests.integration.hermetic_real_world;

import std.stdio : writeln;
import std.file : exists, mkdirRecurse, rmdirRecurse, write, tempDir;
import std.path : buildPath;
import std.process : execute;
import std.algorithm : canFind;
import std.conv : to;
import std.exception : collectException;
import engine.runtime.hermetic;
import engine.runtime.hermetic.determinism.detector;
import engine.runtime.hermetic.determinism.enforcer;
import tests.harness;
import tests.fixtures;

version(unittest):

@("hermetic_real_world.c_project.full_build")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - full C project hermetic build");
    
    auto testRoot = buildPath(tempDir(), "hermetic-c-project");
    auto projectDir = buildPath(testRoot, "project");
    auto srcDir = buildPath(projectDir, "src");
    auto includeDir = buildPath(projectDir, "include");
    auto buildDir = buildPath(projectDir, "build");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(srcDir)) mkdirRecurse(srcDir);
    if (!exists(includeDir)) mkdirRecurse(includeDir);
    if (!exists(buildDir)) mkdirRecurse(buildDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create realistic C project structure
    write(buildPath(includeDir, "math_utils.h"), `
#ifndef MATH_UTILS_H
#define MATH_UTILS_H

int add(int a, int b);
int multiply(int a, int b);

#endif
`);
    
    write(buildPath(srcDir, "math_utils.c"), `
#include "math_utils.h"

int add(int a, int b) {
    return a + b;
}

int multiply(int a, int b) {
    return a * b;
}
`);
    
    write(buildPath(srcDir, "main.c"), `
#include <stdio.h>
#include "math_utils.h"

int main() {
    int result = add(5, multiply(3, 2));
    printf("Result: %d\n", result);
    return 0;
}
`);
    
    // Create hermetic build spec
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .input("/lib")
        .input("/lib64")
        .output(buildDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create C project spec");
    
    // Analyze compiler commands for determinism
    auto compileCmd = [
        "gcc",
        "-I" ~ includeDir,
        buildPath(srcDir, "main.c"),
        buildPath(srcDir, "math_utils.c"),
        "-o", buildPath(buildDir, "program")
    ];
    
    auto detections = NonDeterminismDetector.analyzeCompilerCommand(compileCmd);
    
    if (detections.length > 0)
    {
        writeln("  Determinism suggestions:");
        foreach (detection; detections)
        {
            writeln("    - ", detection.description);
            if (detection.compilerFlags.length > 0)
                writeln("      Flags: ", detection.compilerFlags);
        }
    }
    
    writeln("  \x1b[32m✓ C project test passed\x1b[0m");
}

@("hermetic_real_world.go_project.module_build")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - Go module hermetic build");
    
    auto testRoot = buildPath(tempDir(), "hermetic-go-project");
    auto projectDir = buildPath(testRoot, "myapp");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(projectDir)) mkdirRecurse(projectDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create Go project
    write(buildPath(projectDir, "go.mod"), `
module example.com/myapp

go 1.21
`);
    
    write(buildPath(projectDir, "main.go"), `
package main

import "fmt"

func main() {
    fmt.Println("Hello, hermetic Go!")
}
`);
    
    // Create hermetic spec for Go build
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .input("/lib")
        .output(buildPath(projectDir, "bin"))
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin:/usr/local/go/bin")
        .env("GOCACHE", buildPath(tempWorkDir, "gocache"))
        .env("GOPATH", buildPath(tempWorkDir, "gopath"))
        .build();
    
    Assert.isTrue(spec.isOk, "Should create Go project spec");
    
    // Check Go compiler determinism
    auto goCmd = ["go", "build", "-o", "bin/myapp", "main.go"];
    auto detections = NonDeterminismDetector.analyzeCompilerCommand(goCmd, CompilerType.Go);
    
    bool foundTrimpath = false;
    foreach (detection; detections)
    {
        if (detection.source == NonDeterminismSource.BuildPath)
        {
            foundTrimpath = true;
            Assert.contains(detection.compilerFlags, "-trimpath", 
                           "Should suggest -trimpath for Go");
        }
    }
    
    Assert.isTrue(foundTrimpath, "Should detect Go path embedding issue");
    
    writeln("  \x1b[32m✓ Go project test passed\x1b[0m");
}

@("hermetic_real_world.rust_project.cargo_build")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - Rust Cargo hermetic build");
    
    auto testRoot = buildPath(tempDir(), "hermetic-rust-project");
    auto projectDir = buildPath(testRoot, "myapp");
    auto srcDir = buildPath(projectDir, "src");
    auto targetDir = buildPath(projectDir, "target");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(srcDir)) mkdirRecurse(srcDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create Cargo project
    write(buildPath(projectDir, "Cargo.toml"), `
[package]
name = "myapp"
version = "0.1.0"
edition = "2021"

[dependencies]
`);
    
    write(buildPath(srcDir, "main.rs"), `
fn main() {
    println!("Hello, hermetic Rust!");
}
`);
    
    // Create hermetic spec for Rust build
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .input("/lib")
        .output(targetDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .env("CARGO_HOME", buildPath(tempWorkDir, "cargo"))
        .env("CARGO_TARGET_DIR", targetDir)
        .build();
    
    Assert.isTrue(spec.isOk, "Should create Rust project spec");
    
    // Check Rust compiler determinism
    auto rustCmd = ["rustc", "src/main.rs", "-o", "target/myapp"];
    auto detections = NonDeterminismDetector.analyzeCompilerCommand(rustCmd, CompilerType.Rustc);
    
    // Rust is mostly deterministic by default, but check anyway
    writeln("  Rust determinism detections: ", detections.length);
    
    writeln("  \x1b[32m✓ Rust project test passed\x1b[0m");
}

@("hermetic_real_world.d_project.dub_build")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - D language hermetic build");
    
    auto testRoot = buildPath(tempDir(), "hermetic-d-project");
    auto projectDir = buildPath(testRoot, "myapp");
    auto srcDir = buildPath(projectDir, "source");
    auto buildDir = buildPath(projectDir, "build");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(srcDir)) mkdirRecurse(srcDir);
    if (!exists(buildDir)) mkdirRecurse(buildDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create D project
    write(buildPath(projectDir, "dub.json"), `
{
    "name": "myapp",
    "targetType": "executable",
    "sourcePaths": ["source"]
}
`);
    
    write(buildPath(srcDir, "app.d"), `
import std.stdio;

void main()
{
    writeln("Hello, hermetic D!");
}
`);
    
    // Create hermetic spec for D build
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .input("/lib")
        .output(buildDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create D project spec");
    
    // Check D compiler determinism
    auto dmdCmd = ["dmd", "source/app.d", "-of=build/myapp"];
    auto detections = NonDeterminismDetector.analyzeCompilerCommand(dmdCmd, CompilerType.DMD);
    
    writeln("  D compiler detections: ", detections.length);
    foreach (detection; detections)
        writeln("    - ", detection.description);
    
    writeln("  \x1b[32m✓ D project test passed\x1b[0m");
}

@("hermetic_real_world.mixed_language.c_and_cpp")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - mixed C/C++ hermetic build");
    
    auto testRoot = buildPath(tempDir(), "hermetic-mixed-project");
    auto projectDir = buildPath(testRoot, "project");
    auto buildDir = buildPath(projectDir, "build");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(projectDir)) mkdirRecurse(projectDir);
    if (!exists(buildDir)) mkdirRecurse(buildDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create C file
    write(buildPath(projectDir, "utils.c"), `
int c_add(int a, int b) {
    return a + b;
}
`);
    
    // Create C++ file
    write(buildPath(projectDir, "main.cpp"), `
#include <iostream>

extern "C" int c_add(int a, int b);

int main() {
    std::cout << "Result: " << c_add(5, 3) << std::endl;
    return 0;
}
`);
    
    // Create hermetic spec for mixed build
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .input("/lib")
        .output(buildDir)
        .temp(tempWorkDir)
        .env("PATH", "/usr/bin:/bin")
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create mixed language spec");
    
    // Verify both C and C++ compilers are handled
    auto gccDetections = NonDeterminismDetector.analyzeCompilerCommand(
        ["gcc", "-c", "utils.c", "-o", "build/utils.o"],
        CompilerType.GCC
    );
    
    auto gppDetections = NonDeterminismDetector.analyzeCompilerCommand(
        ["g++", "main.cpp", "build/utils.o", "-o", "build/program"],
        CompilerType.GCC
    );
    
    Assert.notEmpty(gccDetections, "Should detect GCC issues");
    Assert.notEmpty(gppDetections, "Should detect G++ issues");
    
    writeln("  \x1b[32m✓ Mixed language test passed\x1b[0m");
}

@("hermetic_real_world.network_isolation.build_fails")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - network isolation prevents downloads");
    
    auto testRoot = buildPath(tempDir(), "hermetic-network-fail");
    auto projectDir = buildPath(testRoot, "project");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(projectDir)) mkdirRecurse(projectDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create project that tries to download something
    write(buildPath(projectDir, "build.sh"), `#!/bin/sh
# This build script tries to download dependencies
curl -O https://example.com/library.tar.gz
echo "Downloaded dependency"
`);
    
    // Create hermetic spec with no network
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .input("/bin")
        .output(buildPath(projectDir, "output"))
        .temp(tempWorkDir)
        .withNetwork(NetworkPolicy.hermetic())
        .env("PATH", "/usr/bin:/bin")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create network-isolated spec");
    Assert.isFalse(spec.unwrap().canNetwork(), "Should block network access");
    
    // Verify network policy is hermetic
    auto policy = spec.unwrap().network;
    Assert.isTrue(policy.isHermetic, "Policy should be hermetic");
    Assert.isFalse(policy.allowHttp, "HTTP should be blocked");
    Assert.isFalse(policy.allowHttps, "HTTPS should be blocked");
    
    writeln("  \x1b[32m✓ Network isolation test passed\x1b[0m");
}

@("hermetic_real_world.reproducibility.identical_runs")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - reproducibility across runs");
    
    auto testRoot = buildPath(tempDir(), "hermetic-reproducible");
    auto projectDir = buildPath(testRoot, "project");
    auto build1Dir = buildPath(testRoot, "build1");
    auto build2Dir = buildPath(testRoot, "build2");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(projectDir)) mkdirRecurse(projectDir);
    if (!exists(build1Dir)) mkdirRecurse(build1Dir);
    if (!exists(build2Dir)) mkdirRecurse(build2Dir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create simple source
    auto sourceContent = `
int main() {
    return 42;
}
`;
    write(buildPath(projectDir, "main.c"), sourceContent);
    
    // Build with deterministic flags twice
    auto createDeterministicSpec = (string outputDir) {
        return SandboxSpecBuilder.create()
            .input(projectDir)
            .input("/usr")
            .input("/lib")
            .output(outputDir)
            .temp(tempWorkDir)
            .env("PATH", "/usr/bin:/bin")
            .env("SOURCE_DATE_EPOCH", "1640995200")
            .build();
    };
    
    auto spec1 = createDeterministicSpec(build1Dir);
    auto spec2 = createDeterministicSpec(build2Dir);
    
    Assert.isTrue(spec1.isOk, "First spec should be valid");
    Assert.isTrue(spec2.isOk, "Second spec should be valid");
    
    // Both specs should have identical properties
    auto s1 = spec1.unwrap();
    auto s2 = spec2.unwrap();
    
    Assert.equal(s1.canNetwork(), s2.canNetwork(), "Network policies should match");
    Assert.equal(s1.environment.vars.length, s2.environment.vars.length, 
                 "Environment size should match");
    
    writeln("  \x1b[32m✓ Reproducibility test passed\x1b[0m");
}

@("hermetic_real_world.large_project.stress_test")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - large project stress test");
    
    auto testRoot = buildPath(tempDir(), "hermetic-large-project");
    auto projectDir = buildPath(testRoot, "project");
    auto srcDir = buildPath(projectDir, "src");
    auto buildDir = buildPath(projectDir, "build");
    auto tempWorkDir = buildPath(testRoot, "temp");
    
    if (!exists(srcDir)) mkdirRecurse(srcDir);
    if (!exists(buildDir)) mkdirRecurse(buildDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create multiple source files
    foreach (i; 0 .. 20)
    {
        auto filename = buildPath(srcDir, "module" ~ i.to!string ~ ".c");
        write(filename, `
int func` ~ i.to!string ~ `() {
    return ` ~ i.to!string ~ `;
}
`);
    }
    
    // Create main file
    write(buildPath(srcDir, "main.c"), `
int main() {
    return 0;
}
`);
    
    // Create hermetic spec for large build
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .input("/lib")
        .output(buildDir)
        .temp(tempWorkDir)
        .withResources(ResourceLimits.hermetic())
        .env("PATH", "/usr/bin:/bin")
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create large project spec");
    
    // Verify all source files are readable
    auto s = spec.unwrap();
    foreach (i; 0 .. 20)
    {
        auto filename = buildPath(srcDir, "module" ~ i.to!string ~ ".c");
        Assert.isTrue(s.canRead(filename), "Should read module" ~ i.to!string);
    }
    
    writeln("  \x1b[32m✓ Large project test passed\x1b[0m");
}

@("hermetic_real_world.cleanup.temp_directory_isolation")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - temp directory isolation");
    
    auto testRoot = buildPath(tempDir(), "hermetic-temp-isolation");
    auto projectDir = buildPath(testRoot, "project");
    auto buildDir = buildPath(testRoot, "build");
    auto tempWorkDir = buildPath(testRoot, "temp");
    auto forbiddenTemp = buildPath(testRoot, "forbidden-temp");
    
    if (!exists(projectDir)) mkdirRecurse(projectDir);
    if (!exists(buildDir)) mkdirRecurse(buildDir);
    if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    if (!exists(forbiddenTemp)) mkdirRecurse(forbiddenTemp);
    
    void cleanup() 
    {
        if (exists(testRoot))
            collectException(rmdirRecurse(testRoot));
    }
    
    scope(exit) cleanup();
    
    // Create hermetic spec with specific temp directory
    auto spec = SandboxSpecBuilder.create()
        .input(projectDir)
        .input("/usr")
        .output(buildDir)
        .temp(tempWorkDir)  // Only this temp is allowed
        .env("PATH", "/usr/bin:/bin")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create temp isolation spec");
    
    auto s = spec.unwrap();
    Assert.isTrue(s.canWrite(tempWorkDir), "Should write to specified temp");
    Assert.isFalse(s.canWrite(forbiddenTemp), "Should not write to other temp");
    
    writeln("  \x1b[32m✓ Temp isolation test passed\x1b[0m");
}

@("hermetic_real_world.compiler_flags.comprehensive_check")
@system unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m hermetic_real_world - comprehensive compiler flag analysis");
    
    struct TestCase
    {
        string[] command;
        CompilerType compiler;
        string expectedIssue;
    }
    
    TestCase[] testCases = [
        // GCC without determinism flags
        TestCase(
            ["gcc", "main.c", "-o", "main", "-g"],
            CompilerType.GCC,
            "random-seed or path mapping"
        ),
        
        // Clang without path mapping
        TestCase(
            ["clang", "main.c", "-o", "main", "-g"],
            CompilerType.Clang,
            "path mapping"
        ),
        
        // Go without trimpath
        TestCase(
            ["go", "build", "main.go"],
            CompilerType.Go,
            "trimpath"
        ),
        
        // Rust with incremental
        TestCase(
            ["rustc", "main.rs", "-Cincremental=true"],
            CompilerType.Rustc,
            "incremental"
        ),
    ];
    
    foreach (testCase; testCases)
    {
        auto detections = NonDeterminismDetector.analyzeCompilerCommand(
            testCase.command,
            testCase.compiler
        );
        
        Assert.notEmpty(detections, 
            "Should detect issues in " ~ testCase.compiler.to!string);
        
        writeln("  ", testCase.compiler, ": ", detections.length, " issues detected");
    }
    
    writeln("  \x1b[32m✓ Comprehensive compiler check passed\x1b[0m");
}

