module languages.jvm.java.tooling.testers.junit;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;

/// JUnit test result
struct JUnitTestResult
{
    bool success;
    string error;
    size_t passed;
    size_t failed;
    size_t skipped;
    string output;
}

/// JUnit version detection
enum JUnitVersion
{
    Unknown,
    JUnit4,
    JUnit5
}

/// Detect JUnit version from classpath or project file
JUnitVersion detectJUnitVersion(string projectDir)
{
    immutable junit5Markers = ["junit-jupiter", "junit-platform", "@junit.jupiter"];
    immutable junit4Markers = ["junit-4", "@junit:junit:4"];
    
    try {
        auto checkFile = (string path) {
            if (!exists(path)) return JUnitVersion.Unknown;
            auto content = readText(path);
            if (junit5Markers.any!(m => content.canFind(m))) return JUnitVersion.JUnit5;
            if (junit4Markers.any!(m => content.canFind(m))) return JUnitVersion.JUnit4;
            return JUnitVersion.Unknown;
        };
        
        // Check Maven pom.xml
        auto version_ = checkFile(buildPath(projectDir, "pom.xml"));
        if (version_ != JUnitVersion.Unknown) return version_;
        
        // Check Gradle build files
        foreach (file; ["build.gradle", "build.gradle.kts"]) {
            version_ = checkFile(buildPath(projectDir, file));
            if (version_ != JUnitVersion.Unknown) return version_;
        }
    } catch (Exception e) {
        structuredLog.debug_("failed_to_detect_junit_version_").field("detail", "Failed to detect JUnit version: " ~ e.msg).emit();
    }
    
    return JUnitVersion.JUnit5; // Default to JUnit 5 for modern projects
}

/// Run JUnit tests using Maven
JUnitTestResult runJUnitWithMaven(string projectDir, bool useWrapper, string[] args = [])
{
    JUnitTestResult result;
    structuredLog.info("running_junit_tests_with_maven").emit();
    
    auto cmd = (useWrapper && exists(buildPath(projectDir, "mvnw")) ? ["./mvnw"] : ["mvn"]) ~ "test" ~ args;
    auto execResult = execute(cmd, null, Config.none, size_t.max, projectDir);
    result.output = execResult.output;
    result.success = (execResult.status == 0);
    parseMavenTestOutput(execResult.output, result);
    
    if (!result.success && result.error.empty) result.error = "Maven tests failed";
    return result;
}

/// Run JUnit tests using Gradle
JUnitTestResult runJUnitWithGradle(string projectDir, bool useWrapper, string[] args = [])
{
    JUnitTestResult result;
    structuredLog.info("running_junit_tests_with_gradle").emit();
    
    auto cmd = (useWrapper && exists(buildPath(projectDir, "gradlew")) ? ["./gradlew"] : ["gradle"]) ~ "test" ~ args;
    auto execResult = execute(cmd, null, Config.none, size_t.max, projectDir);
    result.output = execResult.output;
    result.success = (execResult.status == 0);
    parseGradleTestOutput(execResult.output, result);
    
    if (!result.success && result.error.empty) result.error = "Gradle tests failed";
    return result;
}

/// Run JUnit tests directly
JUnitTestResult runJUnitDirect(string[] testClasses, string classpath, JUnitVersion version_)
{
    JUnitTestResult result;
    
    structuredLog.info("running_junit_tests_directly").emit();
    
    if (testClasses.empty)
    {
        result.error = "No test classes specified";
        return result;
    }
    
    string[] cmd;
    
    if (version_ == JUnitVersion.JUnit5)
    {
        // JUnit 5 ConsoleLauncher
        cmd = [
            "java",
            "-cp", classpath,
            "org.junit.platform.console.ConsoleLauncher"
        ];
        
        foreach (testClass; testClasses)
            cmd ~= ["--select-class", testClass];
    }
    else
    {
        // JUnit 4 runner
        cmd = [
            "java",
            "-cp", classpath,
            "org.junit.runner.JUnitCore"
        ];
        cmd ~= testClasses;
    }
    
    auto execResult = execute(cmd);
    result.output = execResult.output;
    result.success = (execResult.status == 0);
    
    if (version_ == JUnitVersion.JUnit5)
        parseJUnit5Output(execResult.output, result);
    else
        parseJUnit4Output(execResult.output, result);
    
    if (!result.success && result.error.empty)
        result.error = "JUnit tests failed";
    
    return result;
}

/// Parse Maven test output - format: "Tests run: X, Failures: Y, Errors: Z, Skipped: W"
private void parseMavenTestOutput(string output, ref JUnitTestResult result)
{
    try {
        auto testsMatch = output.matchFirst(regex(r"Tests run:\s*(\d+)"));
        auto failuresMatch = output.matchFirst(regex(r"Failures:\s*(\d+)"));
        auto errorsMatch = output.matchFirst(regex(r"Errors:\s*(\d+)"));
        auto skippedMatch = output.matchFirst(regex(r"Skipped:\s*(\d+)"));
        
        immutable tests = testsMatch.empty ? 0 : testsMatch[1].to!size_t;
        immutable failures = failuresMatch.empty ? 0 : failuresMatch[1].to!size_t;
        immutable errors = errorsMatch.empty ? 0 : errorsMatch[1].to!size_t;
        result.skipped = skippedMatch.empty ? 0 : skippedMatch[1].to!size_t;
        
        result.failed = failures + errors;
        result.passed = tests - result.failed - result.skipped;
    } catch (Exception e) {
        structuredLog.debug_("failed_to_parse_maven_test_output_").field("detail", "Failed to parse Maven test output: " ~ e.msg).emit();
    }
}

/// Parse Gradle test output
private void parseGradleTestOutput(string output, ref JUnitTestResult result)
{
    auto summaryMatch = output.matchFirst(regex(r"(\d+)\s+tests?\s+completed,\s+(\d+)\s+failed,\s+(\d+)\s+skipped"));
    
    if (!summaryMatch.empty) {
        try {
            immutable total = summaryMatch[1].to!size_t;
            result.failed = summaryMatch[2].to!size_t;
            result.skipped = summaryMatch[3].to!size_t;
            result.passed = total - result.failed - result.skipped;
        } catch (Exception e) {
            structuredLog.debug_("failed_to_parse_gradle_test_output_").field("detail", "Failed to parse Gradle test output: " ~ e.msg).emit();
        }
    }
}

/// Parse JUnit 5 output
private void parseJUnit5Output(string output, ref JUnitTestResult result)
{
    try {
        auto successMatch = output.matchFirst(regex(r"\[.*?(\d+)\s+tests?\s+successful"));
        auto failedMatch = output.matchFirst(regex(r"\[.*?(\d+)\s+tests?\s+failed"));
        auto skippedMatch = output.matchFirst(regex(r"\[.*?(\d+)\s+tests?\s+skipped"));
        
        if (!successMatch.empty) result.passed = successMatch[1].to!size_t;
        if (!failedMatch.empty) result.failed = failedMatch[1].to!size_t;
        if (!skippedMatch.empty) result.skipped = skippedMatch[1].to!size_t;
    } catch (Exception e) {
        structuredLog.debug_("failed_to_parse_junit_5_output_").field("detail", "Failed to parse JUnit 5 output: " ~ e.msg).emit();
    }
}

/// Parse JUnit 4 output - format: "OK (X tests)" or "Tests run: X,  Failures: Y"
private void parseJUnit4Output(string output, ref JUnitTestResult result)
{
    try {
        auto okMatch = output.matchFirst(regex(r"OK\s+\((\d+)\s+tests?\)"));
        if (!okMatch.empty) {
            result.passed = okMatch[1].to!size_t;
            result.failed = 0;
            return;
        }
        
        auto failMatch = output.matchFirst(regex(r"Tests run:\s*(\d+),\s*Failures:\s*(\d+)"));
        if (!failMatch.empty) {
            immutable total = failMatch[1].to!size_t;
            result.failed = failMatch[2].to!size_t;
            result.passed = total - result.failed;
        }
    } catch (Exception e) {
        structuredLog.debug_("failed_to_parse_junit_4_output_").field("detail", "Failed to parse JUnit 4 output: " ~ e.msg).emit();
    }
}

