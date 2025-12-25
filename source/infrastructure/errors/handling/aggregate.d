module infrastructure.errors.handling.aggregate;

import std.algorithm : map, filter;
import std.array : array;
import infrastructure.errors.handling.result;
import infrastructure.errors.types.types;

/// Policy for error aggregation behavior
enum AggregationPolicy
{
    FailFast,      // Stop at first error
    CollectAll,    // Collect all errors, continue processing
    StopAtFatal    // Continue on recoverable errors, stop on fatal ones
}

/// Aggregated result containing successes and accumulated errors
/// This allows partial success - some operations succeed while others fail
struct AggregatedResult(T)
{
    T[] successes;
    BuildError[] errors;
    
    /// Check if any successes occurred
    @property bool hasSuccesses() const pure nothrow @nogc
    {
        return successes.length > 0;
    }
    
    /// Check if any errors occurred  
    @property bool hasErrors() const pure nothrow @nogc
    {
        return errors.length > 0;
    }
    
    /// Check if completely successful (no errors)
    @property bool isOk() const pure nothrow @nogc
    {
        return !hasErrors;
    }
    
    /// Check if completely failed (no successes)
    @property bool isFailed() const pure nothrow @nogc
    {
        return !hasSuccesses && hasErrors;
    }
    
    /// Check if partially successful (some successes, some errors)
    @property bool isPartial() const pure nothrow @nogc
    {
        return hasSuccesses && hasErrors;
    }
    
    /// Get only fatal errors
    const(BuildError)[] fatalErrors() const
    {
        return cast(const(BuildError)[])errors.filter!(e => !e.recoverable()).array;
    }
    
    /// Get only recoverable errors
    const(BuildError)[] recoverableErrors() const
    {
        return cast(const(BuildError)[])errors.filter!(e => e.recoverable()).array;
    }
}

/// Error aggregator for collecting results from multiple operations
/// 
/// Usage:
///   auto agg = ErrorAggregator!Target(AggregationPolicy.CollectAll);
///   foreach (file; files) {
///       agg.add(parseFile(file));
///       if (agg.shouldStop()) break;
///   }
///   auto result = agg.finish();
struct ErrorAggregator(T)
{
    private AggregationPolicy policy;
    private T[] successes;
    private BuildError[] errors;
    private bool stopped;
    
    /// Create aggregator with specified policy
    this(AggregationPolicy policy)
    {
        this.policy = policy;
    }
    
    /// Check if we should stop based on error and policy
    private bool shouldStopOnError(BuildError error) pure nothrow
    {
        final switch (policy)
        {
            case AggregationPolicy.FailFast: return true;
            case AggregationPolicy.CollectAll: return false;
            case AggregationPolicy.StopAtFatal: return !error.recoverable();
        }
    }
    
    /// Add a result to the aggregation
    void add(BuildResult!T result)
    {
        if (stopped) return;
        if (result.isOk)
        {
            successes ~= result.unwrap();
        }
        else
        {
            auto error = result.unwrapErr();
            errors ~= error;
            stopped = shouldStopOnError(error);
        }
    }
    
    /// Add multiple results from an array
    void add(BuildResult!(T[]) result)
    {
        if (result.isOk)
        {
            foreach (item; result.unwrap())
                if (!stopped) successes ~= item;
        }
        else
        {
            auto error = result.unwrapErr();
            errors ~= error;
            stopped = shouldStopOnError(error);
        }
    }
    
    /// Check if aggregation should stop (based on policy)
    @property bool shouldStop() const pure nothrow @nogc { return stopped; }
    
    /// Get current error count
    @property size_t errorCount() const pure nothrow @nogc { return errors.length; }
    
    /// Get current success count
    @property size_t successCount() const pure nothrow @nogc { return successes.length; }
    
    /// Finish aggregation and return result
    AggregatedResult!T finish() { return AggregatedResult!T(successes, errors); }
    
    /// Convert to a simple Result type (fails if any errors occurred)
    BuildResult!(T[]) toResult()
    {
        return errors.length == 0 
            ? Ok!(T[], BuildError)(successes) 
            : Err!(T[], BuildError)(errors[0]);
    }
}

/// Convenience function to aggregate an array of results
AggregatedResult!T aggregate(T)(
    BuildResult!T[] results,
    AggregationPolicy policy = AggregationPolicy.CollectAll)
{
    auto agg = ErrorAggregator!T(policy);
    
    foreach (result; results)
    {
        agg.add(result);
        if (agg.shouldStop())
            break;
    }
    
    return agg.finish();
}

/// Process items with a function that returns Results, aggregating the outcomes
AggregatedResult!R aggregateMap(T, R)(
    T[] items,
    BuildResult!R delegate(T) fn,
    AggregationPolicy policy = AggregationPolicy.CollectAll)
{
    auto agg = ErrorAggregator!R(policy);
    
    foreach (item; items)
    {
        agg.add(fn(item));
        if (agg.shouldStop())
            break;
    }
    
    return agg.finish();
}

/// Process items with a function that returns array Results, flattening the results
AggregatedResult!R aggregateFlatMap(T, R)(
    T[] items,
    BuildResult!(R[]) delegate(T) fn,
    AggregationPolicy policy = AggregationPolicy.CollectAll)
{
    auto agg = ErrorAggregator!R(policy);
    
    foreach (item; items)
    {
        agg.add(fn(item));
        if (agg.shouldStop())
            break;
    }
    
    return agg.finish();
}

unittest
{
    import infrastructure.errors.types.types : parseError;
    import infrastructure.errors.handling.codes : ErrorCode;
    
    // Test successful aggregation
    {
        auto r1 = Ok!(int, BuildError)(1);
        auto r2 = Ok!(int, BuildError)(2);
        auto r3 = Ok!(int, BuildError)(3);
        
        auto result = aggregate([r1, r2, r3]);
        assert(result.isOk);
        assert(result.successes == [1, 2, 3]);
        assert(result.errors.length == 0);
    }
    
    // Test fail-fast policy
    {
        auto r1 = Ok!(int, BuildError)(1);
        auto r2 = Err!(int, BuildError)(parseError("file1", "error"));
        auto r3 = Ok!(int, BuildError)(3);
        
        auto result = aggregate([r1, r2, r3], AggregationPolicy.FailFast);
        assert(result.isPartial);
        assert(result.successes == [1]);
        assert(result.errors.length == 1);
    }
    
    // Test collect-all policy
    {
        auto r1 = Ok!(int, BuildError)(1);
        auto r2 = Err!(int, BuildError)(parseError("file1", "error"));
        auto r3 = Ok!(int, BuildError)(3);
        
        auto result = aggregate([r1, r2, r3], AggregationPolicy.CollectAll);
        assert(result.isPartial);
        assert(result.successes == [1, 3]);
        assert(result.errors.length == 1);
    }
    
    // Test aggregateMap
    {
        auto items = ["1", "2", "x", "4"];
        
        auto result = aggregateMap(items, (string s) {
            try {
                import std.conv : to;
                return Ok!(int, BuildError)(s.to!int);
            } catch (Exception e) {
                return Err!(int, BuildError)(parseError(s, e.msg));
            }
        }, AggregationPolicy.CollectAll);
        
        assert(result.isPartial);
        assert(result.successes == [1, 2, 4]);
        assert(result.errors.length == 1);
    }
}

