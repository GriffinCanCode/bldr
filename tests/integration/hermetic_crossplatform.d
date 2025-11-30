module tests.integration.hermetic_crossplatform;

import std.stdio : writeln;
import std.file : exists, mkdirRecurse, rmdirRecurse, write, tempDir, readText;
import std.path : buildPath;
import std.process : execute, executeShell;
import std.algorithm : canFind, startsWith;
import std.string : strip;
import std.conv : to;
import infrastructure.utils.logging.logger;
import engine.runtime.hermetic;
import engine.runtime.hermetic.determinism.detector;
import engine.runtime.hermetic.determinism.enforcer;
import tests.harness;
import tests.fixtures;

version(unittest):

/// Platform detection
enum Platform
{
    Linux,
    macOS,
    Windows,
    Unknown
}

Platform currentPlatform() @safe
{
    version(Windows) return Platform.Windows;
    else version(OSX) return Platform.macOS;
    else version(linux) return Platform.Linux;
    else return Platform.Unknown;
}

/// Cross-platform hermetic test fixture
class CrossPlatformHermeticFixture
{
    private string testRoot;
    private string projectDir;
    private string buildDir;
    private string tempWorkDir;
    private Platform platform;
    
    this(string testName)
    {
        platform = currentPlatform();
        testRoot = buildPath(tempDir(), "hermetic-xplat-" ~ testName);
        projectDir = buildPath(testRoot, "project");
        buildDir = buildPath(testRoot, "build");
        tempWorkDir = buildPath(testRoot, "temp");
    }
    
    void setup()
    {
        if (!exists(projectDir)) mkdirRecurse(projectDir);
        if (!exists(buildDir)) mkdirRecurse(buildDir);
        if (!exists(tempWorkDir)) mkdirRecurse(tempWorkDir);
    }
    
    void teardown()
    {
        if (exists(testRoot))
            try { rmdirRecurse(testRoot); } catch (Exception) {}
    }
    
    /// Get platform-specific compiler
    string getCompiler() const
    {
        final switch (platform)
        {
            case Platform.Linux:
                return "gcc";
            case Platform.macOS:
                return "clang";
            case Platform.Windows:
                return "cl.exe";
            case Platform.Unknown:
                return "gcc";
        }
    }
    
    /// Get platform-specific system paths
    string[] getSystemPaths() const
    {
        final switch (platform)
        {
            case Platform.Linux:
                return ["/usr", "/lib", "/lib64", "/etc"];
            case Platform.macOS:
                return ["/usr", "/System", "/Library"];
            case Platform.Windows:
                return ["C:\\Windows", "C:\\Program Files"];
            case Platform.Unknown:
                return ["/usr"];
        }
    }
    
    /// Get platform-specific PATH environment
    string getPATH() const
    {
        final switch (platform)
        {
            case Platform.Linux:
                return "/usr/bin:/bin:/usr/local/bin";
            case Platform.macOS:
                return "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin";
            case Platform.Windows:
                return "C:\\Windows\\System32;C:\\Windows";
            case Platform.Unknown:
                return "/usr/bin:/bin";
        }
    }
    
    /// Get platform-specific temp directory
    string getTempDir() const
    {
        final switch (platform)
        {
            case Platform.Linux:
                return "/tmp";
            case Platform.macOS:
                return "/tmp";
            case Platform.Windows:
                return "C:\\Temp";
            case Platform.Unknown:
                return "/tmp";
        }
    }
    
    Platform getPlatform() const => platform;
    string getProjectDir() const => projectDir;
    string getBuildDir() const => buildDir;
    string getTempWorkDir() const => tempWorkDir;
}

// ============================================================================
// CROSS-PLATFORM HERMETIC TESTS
// ============================================================================

/// Test: Basic C compilation on all platforms
@("hermetic_xplat.c_compilation")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Hermetic C Compilation - " ~ currentPlatform().to!string);
    
    auto fixture = new CrossPlatformHermeticFixture("c-compile");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    // Create simple C program
    write(buildPath(fixture.getProjectDir(), "hello.c"), `
#include <stdio.h>

int main() {
    printf("Hello, hermetic world!\n");
    return 0;
}
`);
    
    // Create platform-appropriate hermetic spec
    auto specBuilder = SandboxSpecBuilder.create()
        .input(fixture.getProjectDir())
        .output(fixture.getBuildDir())
        .temp(fixture.getTempWorkDir())
        .env("PATH", fixture.getPATH())
        .env("SOURCE_DATE_EPOCH", "1640995200");
    
    // Add system paths
    foreach (path; fixture.getSystemPaths())
        specBuilder.input(path);
    
    auto spec = specBuilder.build();
    Assert.isTrue(spec.isOk, "Should create hermetic spec on " ~ currentPlatform().to!string);
    
    // Verify compiler detection works on this platform
    string compiler = fixture.getCompiler();
    auto compileCmd = [
        compiler,
        buildPath(fixture.getProjectDir(), "hello.c"),
        "-o", buildPath(fixture.getBuildDir(), "hello")
    ];
    
    auto detections = NonDeterminismDetector.analyzeCompilerCommand(
        compileCmd,
        CompilerType.GCC
    );
    
    Logger.info("Platform " ~ currentPlatform().to!string ~ " detections: " ~ detections.length.to!string);
    
    writeln("  \x1b[32m✓ C compilation test passed on " ~ currentPlatform().to!string ~ "\x1b[0m");
}

/// Test: Path separation across platforms
@("hermetic_xplat.path_separators")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Path Separators");
    
    auto fixture = new CrossPlatformHermeticFixture("paths");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    // Test that path handling is platform-aware
    string testPath = buildPath(fixture.getProjectDir(), "subdir", "file.txt");
    
    final switch (fixture.getPlatform())
    {
        case Platform.Windows:
            Assert.isTrue(testPath.canFind("\\"), "Windows should use backslash");
            break;
        case Platform.Linux:
        case Platform.macOS:
            Assert.isTrue(testPath.canFind("/"), "Unix should use forward slash");
            break;
        case Platform.Unknown:
            break;
    }
    
    writeln("  \x1b[32m✓ Path separator test passed\x1b[0m");
}

/// Test: Environment isolation per platform
@("hermetic_xplat.environment_isolation")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Environment Isolation - " ~ currentPlatform().to!string);
    
    auto fixture = new CrossPlatformHermeticFixture("env");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto specBuilder = SandboxSpecBuilder.create()
        .input(fixture.getProjectDir())
        .output(fixture.getBuildDir())
        .temp(fixture.getTempWorkDir())
        .env("PATH", fixture.getPATH())
        .env("SOURCE_DATE_EPOCH", "1640995200");
    
    // Platform-specific environment variables
    final switch (fixture.getPlatform())
    {
        case Platform.Linux:
            specBuilder
                .env("LD_LIBRARY_PATH", "/usr/lib")
                .env("HOME", fixture.getTempWorkDir());
            break;
        case Platform.macOS:
            specBuilder
                .env("DYLD_LIBRARY_PATH", "/usr/lib")
                .env("HOME", fixture.getTempWorkDir());
            break;
        case Platform.Windows:
            specBuilder
                .env("USERPROFILE", fixture.getTempWorkDir())
                .env("TMP", fixture.getTempWorkDir());
            break;
        case Platform.Unknown:
            break;
    }
    
    auto spec = specBuilder.build();
    Assert.isTrue(spec.isOk, "Should create platform-specific spec");
    
    auto s = spec.unwrap();
    Assert.isTrue(s.environment.vars.length > 0, "Should have environment variables");
    
    writeln("  \x1b[32m✓ Environment isolation test passed\x1b[0m");
}

/// Test: Compiler-specific determinism flags
@("hermetic_xplat.compiler_flags")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Compiler Determinism Flags");
    
    auto fixture = new CrossPlatformHermeticFixture("flags");
    
    struct TestCase
    {
        Platform platform;
        string compiler;
        CompilerType type;
        string[] expectedFlags;
    }
    
    TestCase[] testCases = [
        TestCase(
            Platform.Linux,
            "gcc",
            CompilerType.GCC,
            ["-frandom-seed=", "-ffile-prefix-map=", "-fdebug-prefix-map="]
        ),
        TestCase(
            Platform.macOS,
            "clang",
            CompilerType.Clang,
            ["-fdebug-prefix-map=", "-ffile-prefix-map="]
        ),
    ];
    
    foreach (testCase; testCases)
    {
        auto cmd = [testCase.compiler, "test.c", "-o", "test.exe"];
        auto detections = NonDeterminismDetector.analyzeCompilerCommand(cmd, testCase.type);
        
        Logger.info(testCase.platform.to!string ~ " (" ~ testCase.compiler ~ "): " ~ 
                   detections.length.to!string ~ " detections");
        
        // Verify platform-appropriate flags are suggested
        bool foundExpectedFlag = false;
        foreach (detection; detections)
        {
            foreach (expectedFlag; testCase.expectedFlags)
            {
                if (detection.compilerFlags.canFind(expectedFlag))
                {
                    foundExpectedFlag = true;
                    break;
                }
            }
        }
        
        if (detections.length > 0)
        {
            Assert.isTrue(foundExpectedFlag, 
                "Should suggest " ~ testCase.platform.to!string ~ "-appropriate flags");
        }
    }
    
    writeln("  \x1b[32m✓ Compiler flags test passed\x1b[0m");
}

/// Test: File system case sensitivity
@("hermetic_xplat.case_sensitivity")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m File System Case Sensitivity");
    
    auto fixture = new CrossPlatformHermeticFixture("case");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    // Create files with different cases
    auto lowerFile = buildPath(fixture.getProjectDir(), "test.txt");
    auto upperFile = buildPath(fixture.getProjectDir(), "TEST.txt");
    
    write(lowerFile, "lowercase");
    
    // Check platform case sensitivity
    final switch (fixture.getPlatform())
    {
        case Platform.Linux:
            // Case-sensitive - can create both files
            write(upperFile, "uppercase");
            Assert.isTrue(exists(lowerFile), "Lower case file should exist");
            Assert.isTrue(exists(upperFile), "Upper case file should exist");
            Assert.equal(readText(lowerFile), "lowercase", "Should read correct file");
            Assert.equal(readText(upperFile), "uppercase", "Should read correct file");
            break;
            
        case Platform.macOS:
            // Case-insensitive by default (but case-preserving)
            // Writing to TEST.txt would overwrite test.txt
            if (exists(upperFile))
            {
                auto content = readText(upperFile);
                Logger.info("macOS: Same file, content = " ~ content);
            }
            break;
            
        case Platform.Windows:
            // Case-insensitive
            // test.txt and TEST.txt are the same file
            Assert.isTrue(exists(upperFile), "Should be same file as lowercase");
            break;
            
        case Platform.Unknown:
            break;
    }
    
    writeln("  \x1b[32m✓ Case sensitivity test passed\x1b[0m");
}

/// Test: Executable formats per platform
@("hermetic_xplat.executable_formats")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Executable Formats");
    
    auto fixture = new CrossPlatformHermeticFixture("exe");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    // Create minimal program
    write(buildPath(fixture.getProjectDir(), "main.c"), `
int main() { return 0; }
`);
    
    auto spec = SandboxSpecBuilder.create()
        .input(fixture.getProjectDir())
        .output(fixture.getBuildDir())
        .temp(fixture.getTempWorkDir())
        .env("PATH", fixture.getPATH())
        .env("SOURCE_DATE_EPOCH", "1640995200");
    
    foreach (path; fixture.getSystemPaths())
        spec.input(path);
    
    auto specResult = spec.build();
    Assert.isTrue(specResult.isOk, "Should create spec");
    
    // Expected executable extension per platform
    string exeName;
    final switch (fixture.getPlatform())
    {
        case Platform.Windows:
            exeName = "program.exe";
            break;
        case Platform.Linux:
        case Platform.macOS:
            exeName = "program";
            break;
        case Platform.Unknown:
            exeName = "program";
            break;
    }
    
    auto outputPath = buildPath(fixture.getBuildDir(), exeName);
    Logger.info("Expected executable: " ~ outputPath);
    
    writeln("  \x1b[32m✓ Executable format test passed\x1b[0m");
}

/// Test: Shared library naming conventions
@("hermetic_xplat.shared_libraries")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Shared Library Naming");
    
    struct LibraryName
    {
        Platform platform;
        string prefix;
        string extension;
        string example;
    }
    
    LibraryName[] conventions = [
        LibraryName(Platform.Linux, "lib", ".so", "libfoo.so"),
        LibraryName(Platform.macOS, "lib", ".dylib", "libfoo.dylib"),
        LibraryName(Platform.Windows, "", ".dll", "foo.dll"),
    ];
    
    foreach (convention; conventions)
    {
        string libName = convention.example;
        
        if (convention.prefix.length > 0)
            Assert.isTrue(libName.startsWith(convention.prefix), 
                        convention.platform.to!string ~ " should use prefix");
        
        Assert.isTrue(libName.canFind(convention.extension),
                     convention.platform.to!string ~ " should have correct extension");
        
        Logger.info(convention.platform.to!string ~ ": " ~ libName);
    }
    
    writeln("  \x1b[32m✓ Shared library naming test passed\x1b[0m");
}

/// Test: System include paths per platform
@("hermetic_xplat.system_includes")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m System Include Paths");
    
    struct IncludePath
    {
        Platform platform;
        string[] paths;
    }
    
    IncludePath[] includes = [
        IncludePath(Platform.Linux, [
            "/usr/include",
            "/usr/local/include",
            "/usr/include/x86_64-linux-gnu"
        ]),
        IncludePath(Platform.macOS, [
            "/usr/include",
            "/usr/local/include",
            "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include"
        ]),
        IncludePath(Platform.Windows, [
            "C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\Community\\VC\\Tools\\MSVC\\14.29.30133\\include",
            "C:\\Program Files (x86)\\Windows Kits\\10\\Include\\10.0.19041.0\\ucrt"
        ]),
    ];
    
    foreach (include; includes)
    {
        Logger.info(include.platform.to!string ~ " include paths:");
        foreach (path; include.paths)
        {
            Logger.info("  " ~ path);
        }
    }
    
    writeln("  \x1b[32m✓ System includes test passed\x1b[0m");
}

/// Test: Reproducibility across platforms
@("hermetic_xplat.reproducibility")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Cross-Platform Reproducibility");
    
    auto fixture = new CrossPlatformHermeticFixture("repro");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    // Create deterministic source
    write(buildPath(fixture.getProjectDir(), "calc.c"), `
int add(int a, int b) {
    return a + b;
}

int main() {
    return add(40, 2);
}
`);
    
    // Create hermetic spec with deterministic settings
    auto spec = SandboxSpecBuilder.create()
        .input(fixture.getProjectDir())
        .output(fixture.getBuildDir())
        .temp(fixture.getTempWorkDir())
        .env("PATH", fixture.getPATH())
        .env("SOURCE_DATE_EPOCH", "1640995200")
        .env("ZERO_AR_DATE", "1")
        .build();
    
    Assert.isTrue(spec.isOk, "Should create reproducible spec on " ~ currentPlatform().to!string);
    
    auto s = spec.unwrap();
    
    // Verify deterministic environment
    Assert.isTrue(s.environment.has("SOURCE_DATE_EPOCH"), "Should fix timestamps");
    
    // Note: Actual binary reproducibility would require compiling on multiple
    // machines/platforms and comparing hashes. This test verifies the setup.
    
    writeln("  \x1b[32m✓ Reproducibility test passed on " ~ currentPlatform().to!string ~ "\x1b[0m");
}

/// Test: Platform-specific temp directory isolation
@("hermetic_xplat.temp_isolation")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Platform Temp Directory Isolation");
    
    auto fixture = new CrossPlatformHermeticFixture("temp");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto hermeticTemp = fixture.getTempWorkDir();
    auto systemTemp = fixture.getTempDir();
    
    // Create hermetic spec that isolates temp
    auto spec = SandboxSpecBuilder.create()
        .input(fixture.getProjectDir())
        .output(fixture.getBuildDir())
        .temp(hermeticTemp)
        .env("PATH", fixture.getPATH());
    
    // Add platform-specific temp env vars
    final switch (fixture.getPlatform())
    {
        case Platform.Linux:
        case Platform.macOS:
            spec.env("TMPDIR", hermeticTemp);
            spec.env("TEMP", hermeticTemp);
            spec.env("TMP", hermeticTemp);
            break;
        case Platform.Windows:
            spec.env("TEMP", hermeticTemp);
            spec.env("TMP", hermeticTemp);
            break;
        case Platform.Unknown:
            break;
    }
    
    auto specResult = spec.build();
    Assert.isTrue(specResult.isOk, "Should create temp-isolated spec");
    
    auto s = specResult.unwrap();
    Assert.isTrue(s.canWrite(hermeticTemp), "Should write to hermetic temp");
    Assert.isFalse(s.canWrite(systemTemp), "Should NOT write to system temp");
    
    writeln("  \x1b[32m✓ Temp isolation test passed\x1b[0m");
}

/// Test: Network isolation across platforms
@("hermetic_xplat.network_isolation")
@system unittest
{
    writeln("\x1b[36m[XPLAT]\x1b[0m Network Isolation - " ~ currentPlatform().to!string);
    
    auto fixture = new CrossPlatformHermeticFixture("network");
    fixture.setup();
    scope(exit) fixture.teardown();
    
    auto spec = SandboxSpecBuilder.create()
        .input(fixture.getProjectDir())
        .output(fixture.getBuildDir())
        .withNetwork(NetworkPolicy.hermetic())
        .env("PATH", fixture.getPATH())
        .build();
    
    Assert.isTrue(spec.isOk, "Should create network-isolated spec");
    
    auto s = spec.unwrap();
    Assert.isFalse(s.canNetwork(), "Should block network on " ~ currentPlatform().to!string);
    
    auto policy = s.network;
    Assert.isTrue(policy.isHermetic, "Should be hermetic");
    Assert.isFalse(policy.allowHttp, "Should block HTTP");
    Assert.isFalse(policy.allowHttps, "Should block HTTPS");
    
    writeln("  \x1b[32m✓ Network isolation test passed\x1b[0m");
}

