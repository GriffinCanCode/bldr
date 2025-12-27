module languages.dotnet.csharp.tooling.testers.base;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string : toLower;
import languages.dotnet.csharp.config.test;
import infrastructure.utils.logging;

/// Test execution result
struct TestResult
{
    bool success;
    string error;
    size_t passed;
    size_t failed;
    size_t skipped;
    string output;
}

/// Base test runner interface
interface ITestRunner
{
    /// Check if test runner is available
    bool isAvailable();
    
    /// Get test runner name
    string name() const;
    
    /// Run tests
    TestResult runTests(in string[] testFiles, in TestConfig config, in string workingDir);
}

/// Detect test framework from project/assembly
CSharpTestFramework detectTestFramework(string projectPath)
{
    if (!exists(projectPath)) return CSharpTestFramework.None;
    
    try {
        auto content = readText(projectPath);
        if (content.canFind("xunit") || content.canFind("xUnit")) return CSharpTestFramework.XUnit;
        if (content.canFind("NUnit")) return CSharpTestFramework.NUnit;
        if (content.canFind("MSTest.TestFramework") || content.canFind("Microsoft.VisualStudio.TestTools")) 
            return CSharpTestFramework.MSTest;
    } catch (Exception e) {
        structuredLog.debug_("failed_to_detect_test_framework_").field("detail", "Failed to detect test framework: " ~ e.msg).emit();
    }
    
    return CSharpTestFramework.None;
}

/// Find test assemblies in directory
string[] findTestAssemblies(string dir)
{
    if (!exists(dir) || !isDir(dir)) return [];
    
    import std.file : dirEntries, SpanMode;
    
    try {
        return dirEntries(dir, "*.dll", SpanMode.depth)
            .filter!(e => e.name.baseName.toLower().canFind("test"))
            .map!(e => e.name)
            .array;
    } catch (Exception e) {
        structuredLog.debug_("failed_to_scan_for_test_assemblies_").field("detail", "Failed to scan for test assemblies: " ~ e.msg).emit();
        return [];
    }
}

/// Helper to check if command is available
bool isCommandAvailable(string cmd)
{
    try {
        version(Windows) return execute(["where", cmd]).status == 0;
        else return execute(["which", cmd]).status == 0;
    } catch (Exception) { return false; }
}

