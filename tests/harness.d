module tests.harness;

import std.stdio;
import std.datetime.stopwatch;
import std.algorithm;
import std.array;
import std.conv;
import std.traits;
import std.meta;
import std.format;
import std.range;

/// Test result status
enum TestStatus
{
    Pass,
    Fail,
    Skip,
    Error
}

/// Result of a single test execution
struct TestResult
{
    string moduleName;
    string testName;
    TestStatus status;
    string message;
    Duration duration;
    TestSourceLocation location;
    
    bool passed() const pure nothrow
    {
        return status == TestStatus.Pass;
    }
}

/// Source location for test failures
struct TestSourceLocation
{
    string file;
    size_t line;
    
    string toString() const
    {
        return file ~ ":" ~ line.to!string;
    }
}

/// Statistics for test run
struct TestStats
{
    size_t total;
    size_t passed;
    size_t failed;
    size_t skipped;
    size_t errors;
    Duration totalTime;
    
    size_t failureCount() const pure nothrow
    {
        return failed + errors;
    }
    
    bool allPassed() const pure nothrow
    {
        return failureCount == 0;
    }
    
    double passRate() const pure nothrow
    {
        if (total == 0) return 100.0;
        return (passed * 100.0) / total;
    }
}

/// Test assertion exception
class AssertionError : Exception
{
    TestSourceLocation location;
    
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg);
        location = TestSourceLocation(file, line);
    }
}

/// Test harness for running and reporting tests
class TestHarness
{
    private TestResult[] results;
    private StopWatch timer;
    
    /// Begin test run
    void begin()
    {
        results = [];
        timer.reset();
        timer.start();
    }
    
    /// End test run and return statistics
    TestStats end()
    {
        timer.stop();
        
        TestStats stats;
        stats.total = results.length;
        stats.totalTime = timer.peek();
        
        foreach (result; results)
        {
            final switch (result.status)
            {
                case TestStatus.Pass:
                    stats.passed++;
                    break;
                case TestStatus.Fail:
                    stats.failed++;
                    break;
                case TestStatus.Skip:
                    stats.skipped++;
                    break;
                case TestStatus.Error:
                    stats.errors++;
                    break;
            }
        }
        
        return stats;
    }
    
    /// Record a test result
    void record(TestResult result)
    {
        results ~= result;
    }
    
    /// Get all recorded results
    TestResult[] getResults() const
    {
        return results.dup;
    }
    
    /// Print formatted test results
    void printResults(bool verbose = false)
    {
        auto stats = end();
        
        writeln("\n" ~ "=".repeat(70).join);
        writeln("TEST RESULTS");
        writeln("=".repeat(70).join);
        
        // Print failures first
        auto failures = results.filter!(r => !r.passed).array;
        if (!failures.empty)
        {
            writeln("\n\x1b[31mFAILURES:\x1b[0m");
            foreach (result; failures)
            {
                writeln("\n  \x1b[31m✗\x1b[0m ", result.moduleName, "::", result.testName);
                writeln("    Location: ", result.location);
                writeln("    Message: ", result.message);
                writeln("    Duration: ", result.duration.total!"msecs", "ms");
            }
        }
        
        // Print passes if verbose
        if (verbose)
        {
            auto passes = results.filter!(r => r.passed).array;
            if (!passes.empty)
            {
                writeln("\n\x1b[32mPASSES:\x1b[0m");
                foreach (result; passes)
                {
                    writeln("  \x1b[32m✓\x1b[0m ", result.moduleName, "::", result.testName,
                           " (", result.duration.total!"msecs", "ms)");
                }
            }
        }
        
        // Print summary
        writeln("\n" ~ "-".repeat(70).join);
        writeln("SUMMARY");
        writeln("-".repeat(70).join);
        writeln("  Total:    ", stats.total);
        writeln("  \x1b[32mPassed:   ", stats.passed, "\x1b[0m");
        if (stats.failed > 0)
            writeln("  \x1b[31mFailed:   ", stats.failed, "\x1b[0m");
        if (stats.errors > 0)
            writeln("  \x1b[31mErrors:   ", stats.errors, "\x1b[0m");
        if (stats.skipped > 0)
            writeln("  \x1b[33mSkipped:  ", stats.skipped, "\x1b[0m");
        writeln("  Pass Rate: ", format("%.1f%%", stats.passRate));
        writeln("  Duration:  ", stats.totalTime.total!"msecs", "ms");
        writeln("=".repeat(70).join);
        
        if (stats.allPassed)
            writeln("\n\x1b[32m✓ All tests passed!\x1b[0m\n");
        else
            writeln("\n\x1b[31m✗ Some tests failed\x1b[0m\n");
    }
}

/// Assertion helpers with better error messages
struct Assert
{
    /// Fail immediately with a message
    static void fail(string message, string file = __FILE__, size_t line = __LINE__)
    {
        throw new AssertionError(message, file, line);
    }
    
    /// Assert equality with type-safe comparison
    static void equal(T)(T actual, T expected, 
                        string file = __FILE__, size_t line = __LINE__)
    {
        if (actual != expected)
        {
            auto msg = format("Expected: %s\nActual:   %s", expected, actual);
            throw new AssertionError(msg, file, line);
        }
    }
    
    /// Assert inequality
    static void notEqual(T)(T actual, T unexpected,
                           string file = __FILE__, size_t line = __LINE__)
    {
        if (actual == unexpected)
        {
            auto msg = format("Expected not equal to: %s", unexpected);
            throw new AssertionError(msg, file, line);
        }
    }
    
    /// Assert truth
    static void isTrue(bool condition, string message = "Condition is false",
                      string file = __FILE__, size_t line = __LINE__)
    {
        if (!condition)
            throw new AssertionError(message, file, line);
    }
    
    /// Assert falsity
    static void isFalse(bool condition, string message = "Condition is true",
                       string file = __FILE__, size_t line = __LINE__)
    {
        if (condition)
            throw new AssertionError(message, file, line);
    }
    
    /// Assert null
    static void isNull(T)(T value, string file = __FILE__, size_t line = __LINE__)
        if (is(T == class) || is(T : U[], U))
    {
        if (value !is null)
            throw new AssertionError("Expected null", file, line);
    }
    
    /// Assert not null
    static void notNull(T)(T value, string file = __FILE__, size_t line = __LINE__)
        if (is(T == class) || is(T : U[], U))
    {
        if (value is null)
            throw new AssertionError("Expected non-null", file, line);
    }
    
    /// Assert array contains element
    static void contains(T, E)(T[] array, E element,
                              string file = __FILE__, size_t line = __LINE__)
    {
        if (!array.canFind(element))
        {
            auto msg = format("Array does not contain: %s", element);
            throw new AssertionError(msg, file, line);
        }
    }
    
    /// Assert array is empty
    static void isEmpty(T)(T[] array, string file = __FILE__, size_t line = __LINE__)
    {
        if (!array.empty)
        {
            auto msg = format("Expected empty array, got length: %s", array.length);
            throw new AssertionError(msg, file, line);
        }
    }
    
    /// Assert array is not empty
    static void notEmpty(T)(T[] array, string file = __FILE__, size_t line = __LINE__)
    {
        if (array.empty)
            throw new AssertionError("Expected non-empty array", file, line);
    }
    
    /// Assert throws specific exception
    static void throws(E : Throwable = Exception)(lazy void expr,
                                                  string file = __FILE__, 
                                                  size_t line = __LINE__)
    {
        try
        {
            expr();
            throw new AssertionError("Expected exception was not thrown", file, line);
        }
        catch (AssertionError e)
        {
            throw e;
        }
        catch (E e)
        {
            // Expected exception caught
        }
        catch (Throwable t)
        {
            auto msg = format("Wrong exception type. Expected: %s, Got: %s",
                            E.stringof, typeid(t).name);
            throw new AssertionError(msg, file, line);
        }
    }
    
    /// Assert does not throw
    static void notThrows(lazy void expr, string file = __FILE__, size_t line = __LINE__)
    {
        try
        {
            expr();
        }
        catch (Throwable t)
        {
            auto msg = format("Unexpected exception: %s", t.msg);
            throw new AssertionError(msg, file, line);
        }
    }
}

/// Compile-time test registration via UDA
struct TestCase
{
    string name;
}

