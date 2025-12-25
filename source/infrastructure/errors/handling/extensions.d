module infrastructure.errors.handling.extensions;

import std.traits;
import std.range;
import std.algorithm;
import std.array;
import std.typecons : Tuple, tuple;
import infrastructure.errors.handling.result;

/// Advanced functional operations for Result monad
/// Provides composability, traversal, and sequencing operations

/// Traverse a range with a function returning Result, collecting successes or stopping at first error
/// This is the monadic traverse operation - transforms each element and sequences the results
/// 
/// Example:
///   auto files = ["a.txt", "b.txt", "c.txt"];
///   auto result = traverse(files, (f) => readFile(f));
///   // Returns BuildResult!(string[]) with all file contents or first error
Result!(T[], E) traverse(R, Fn, T, E)(R range, Fn fn)
    if (isInputRange!R)
{
    T[] results;
    static if (hasLength!R)
        results.reserve(range.length);
    
    foreach (elem; range)
    {
        auto result = fn(elem);
        if (result.isErr)
            return Result!(T[], E).err(result.unwrapErr());
        results ~= result.unwrap();
    }
    
    return Result!(T[], E).ok(results);
}

/// Sequence a collection of Results into a Result of collection
/// Stops at first error, otherwise collects all successes
/// 
/// Example:
///   Result!(int, string)[] results = [Ok!(int, string)(1), Ok!(int, string)(2)];
///   auto sequenced = sequence(results);  // Ok!([1, 2])
Result!(T[], E) sequence(T, E)(Result!(T, E)[] results)
{
    return traverse(results, (r) => r);
}

/// Partition Results into successes and failures
/// Unlike sequence/traverse, this never fails - collects all results
/// 
/// Example:
///   auto results = [Ok!(int, string)(1), Err!(int, string)("fail"), Ok!(int, string)(2)];
///   auto partitioned = partition(results);
///   // partitioned.successes = [1, 2]
///   // partitioned.errors = ["fail"]
struct Partitioned(T, E)
{
    T[] successes;
    E[] errors;
    
    bool allSucceeded() const pure nothrow @nogc { return errors.length == 0; }
    bool anyFailed() const pure nothrow @nogc { return errors.length > 0; }
    bool allFailed() const pure nothrow @nogc { return successes.length == 0; }
}

Partitioned!(T, E) partition(T, E)(Result!(T, E)[] results)
{
    import std.algorithm : filter;
    import std.array : array;
    Partitioned!(T, E) part;
    part.successes.reserve(results.length);
    part.errors.reserve(results.length);
    foreach (r; results)
    {
        if (r.isOk)
            part.successes ~= r.unwrap();
        else
            part.errors ~= r.unwrapErr();
    }
    return part;
}

/// Zip two Results into a single Result containing a tuple
/// Short-circuits on first error
/// 
/// Example:
///   auto r1 = Ok!(int, string)(1);
///   auto r2 = Ok!(string, string)("a");
///   auto zipped = zip(r1, r2);  // Ok!((1, "a"))
Result!(Tuple!(T1, T2), E) zip(T1, T2, E)(Result!(T1, E) r1, Result!(T2, E) r2)
{
    if (r1.isErr)
        return Result!(Tuple!(T1, T2), E).err(r1.unwrapErr());
    if (r2.isErr)
        return Result!(Tuple!(T1, T2), E).err(r2.unwrapErr());
    
    return Result!(Tuple!(T1, T2), E).ok(tuple(r1.unwrap(), r2.unwrap()));
}

/// Zip three Results
Result!(Tuple!(T1, T2, T3), E) zip(T1, T2, T3, E)(
    Result!(T1, E) r1, Result!(T2, E) r2, Result!(T3, E) r3)
{
    if (r1.isErr) return Result!(Tuple!(T1, T2, T3), E).err(r1.unwrapErr());
    if (r2.isErr) return Result!(Tuple!(T1, T2, T3), E).err(r2.unwrapErr());
    if (r3.isErr) return Result!(Tuple!(T1, T2, T3), E).err(r3.unwrapErr());
    
    return Result!(Tuple!(T1, T2, T3), E).ok(tuple(r1.unwrap(), r2.unwrap(), r3.unwrap()));
}

/// Flatten nested Result types
/// Converts Result!(Result!(T, E), E) into Result!(T, E)
/// 
/// Example:
///   Result!(Result!(int, string), string) nested = ...;
///   auto flattened = flatten(nested);  // Result!(int, string)
Result!(T, E) flatten(T, E)(Result!(Result!(T, E), E) nested)
{
    if (nested.isErr)
        return Result!(T, E).err(nested.unwrapErr());
    
    return nested.unwrap();
}

/// Tap into success without consuming (for side effects like logging)
ref Result!(T, E) tap(T, E)(return ref Result!(T, E) result, void delegate(ref const T) fn)
{
    static if (is(T == void))
    {
        if (result.isOk) fn();
    }
    else
    {
        if (result.isOk) fn(result.unwrap());
    }
    return result;
}

/// Tap into error without consuming (for logging errors)
ref Result!(T, E) tapErr(T, E)(return ref Result!(T, E) result, void delegate(ref const E) fn)
{
    if (result.isErr) fn(result.unwrapErr());
    return result;
}

/// Recover from error by converting it to a success value
T recover(T, E)(Result!(T, E) result, T delegate(E) recoveryFn)
{
    return result.isOk ? result.unwrap() : recoveryFn(result.unwrapErr());
}

/// Collect results with different strategies
enum CollectStrategy
{
    FailFast,      /// Stop at first error (default traverse behavior)
    CollectAll,    /// Collect all successes, ignore errors
    Partition      /// Collect both successes and errors
}

/// Collect results from a range using specified strategy
auto collectWith(R, Fn, T, E, CollectStrategy strategy = CollectStrategy.FailFast)(
    R range, Fn fn)
    if (isInputRange!R)
{
    static if (strategy == CollectStrategy.FailFast)
    {
        return traverse(range, fn);
    }
    else static if (strategy == CollectStrategy.CollectAll)
    {
        T[] results;
        foreach (elem; range)
        {
            auto result = fn(elem);
            if (result.isOk)
                results ~= result.unwrap();
        }
        return results;
    }
    else static if (strategy == CollectStrategy.Partition)
    {
        Result!(T, E)[] results;
        foreach (elem; range)
        {
            results ~= fn(elem);
        }
        return partition(results);
    }
}

/// Try all operations until one succeeds (first success wins)
/// Returns error only if all operations fail (returns last error)
/// 
/// Example:
///   auto result = tryAll([
///       () => readFile("config.json"),
///       () => readFile("config.default.json"),
///       () => Ok!(string, BuildError)("{}")  // Fallback
///   ]);
Result!(T, E) tryAll(T, E)(Result!(T, E) delegate()[] operations)
{
    if (operations.length == 0)
        return Result!(T, E).err(cast(E)null);  // No operations provided
    
    E lastError;
    foreach (op; operations)
    {
        auto result = op();
        if (result.isOk)
            return result;
        lastError = result.unwrapErr();
    }
    
    return Result!(T, E).err(lastError);
}

/// Accumulate results using a binary operation (monadic fold/reduce)
/// Short-circuits on first error
/// 
/// Example:
///   auto numbers = [1, 2, 3, 4, 5];
///   auto result = foldResult(numbers, 0, (acc, n) => 
///       Ok!(int, string)(acc + n)
///   );  // Ok!(15)
Result!(Acc, E) foldResult(R, Acc, E)(
    R range, Acc initial, Result!(Acc, E) delegate(Acc, ElementType!R) fn)
    if (isInputRange!R)
{
    Acc acc = initial;
    foreach (elem; range)
    {
        auto result = fn(acc, elem);
        if (result.isErr)
            return result;
        acc = result.unwrap();
    }
    return Result!(Acc, E).ok(acc);
}

/// Apply a function to Result if it succeeds (alias for andThen)
Result!(U, E) apply(T, U, E)(Result!(T, E) result, Result!(U, E) delegate(T) fn)
{
    return result.andThen(fn);
}

/// Bi-map: map both success and error types simultaneously
Result!(U, F) bimap(T, E, U, F)(Result!(T, E) result, U delegate(T) okFn, F delegate(E) errFn)
{
    return result.isOk 
        ? Result!(U, F).ok(okFn(result.unwrap()))
        : Result!(U, F).err(errFn(result.unwrapErr()));
}

/// Parallel traversal for independent operations
/// Executes all operations in parallel and collects results
/// Useful for I/O-bound operations that don't depend on each other
/// 
/// Example:
///   auto files = ["a.txt", "b.txt", "c.txt"];
///   auto result = traverseParallel(files, (f) => readFile(f));
Result!(T[], E) traverseParallel(R, T, E)(R range, Result!(T, E) delegate(ElementType!R) fn)
    if (isInputRange!R)
{
    import std.parallelism : taskPool, parallel;
    import core.sync.mutex : Mutex;
    
    Result!(T, E)[] results;
    results.length = range.length;
    
    Mutex errorMutex = new Mutex();
    bool hasError = false;
    E firstError;
    
    size_t index = 0;
    foreach (elem; parallel(range))
    {
        auto result = fn(elem);
        
        synchronized (errorMutex)
        {
            if (result.isErr && !hasError)
            {
                hasError = true;
                firstError = result.unwrapErr();
            }
            results[index] = result;
            index++;
        }
    }
    
    if (hasError)
        return Result!(T[], E).err(firstError);
    
    return sequence(results);
}

unittest
{
    import std.conv : to;
    
    // Test traverse
    auto range = [1, 2, 3];
    Result!(int, string) delegate(int) fn = (int x) => Result!(int, string).ok(x * 2);
    auto result = traverse!(int[], typeof(fn), int, string)(range, fn);
    assert(result.isOk);
    assert(result.unwrap() == [2, 4, 6]);
    
    // Test traverse with error
    Result!(int, string) delegate(int) errorFn = (int x) => 
        x == 2 ? Result!(int, string).err("error") : Result!(int, string).ok(x);
    auto errorResult = traverse!(int[], typeof(errorFn), int, string)(range, errorFn);
    assert(errorResult.isErr);
    
    // Test partition
    auto mixed = [
        Result!(int, string).ok(1),
        Result!(int, string).err("e1"),
        Result!(int, string).ok(2),
        Result!(int, string).err("e2")
    ];
    auto part = partition(mixed);
    assert(part.successes == [1, 2]);
    assert(part.errors == ["e1", "e2"]);
    
    // Test zip
    auto r1 = Result!(int, string).ok(42);
    auto r2 = Result!(string, string).ok("hello");
    auto zipped = zip(r1, r2);
    assert(zipped.isOk);
    
    // Test flatten
    auto nested = Result!(Result!(int, string), string).ok(Result!(int, string).ok(42));
    auto flat = flatten(nested);
    assert(flat.isOk);
    assert(flat.unwrap() == 42);
    
    // Test recover
    auto failed = Result!(int, string).err("error");
    int delegate(string) recoverFn = (e) => 0;
    auto recovered = recover(failed, recoverFn);
    assert(recovered == 0);
}


