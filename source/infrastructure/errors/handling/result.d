module infrastructure.errors.handling.result;

import std.traits;
import std.conv;
import core.memory : GC;
import core.stdc.string : memset;
import infrastructure.errors.types.types : internalError;

/// Check if a type can be safely copied in a Result
/// This must be conservative - if in doubt, treat as non-copyable
private template IsTrulyCopyable(T)
{
    static if (!is(T == struct))
        enum IsTrulyCopyable = true;
    else static if (__traits(hasMember, T, "__xpostblit") && 
                    is(typeof(__traits(getMember, T.init, "__xpostblit")) == void function() @disable))
        enum IsTrulyCopyable = false;
    else static if (__traits(hasMember, T, "__postblit"))
        // Check if postblit is disabled by checking if it compiles
        enum IsTrulyCopyable = __traits(compiles, { T x = void; T y = x; });
    else
        // For structs without explicit postblit, check all fields recursively
        enum IsTrulyCopyable = () {
            static foreach (field; T.tupleof)
            {
                static if (!IsTrulyCopyable!(typeof(field)))
                    return false;
            }
            return true;
        }();
}

/// Algebraic result type representing either success (Ok) or failure (Err)
/// Inspired by Rust's Result<T, E> with D-specific optimizations
/// Supports both copyable and non-copyable types via static dispatch
struct Result(T, E)
{
    private bool _isOk;
    
    // Use pointer for non-copyable types, direct storage for copyable types
    static if (IsTrulyCopyable!T)
    {
        private union { T _value; E _error; }
    }
    else
    {
        private T* _valuePtr;  // Heap-allocated for non-copyable types
        private E _error;
    }
    
    /// Create a successful result (@system: union access controlled by _isOk flag)
    static if (IsTrulyCopyable!T)
    {
        static Result ok(T value) @system
        {
            Result r;
            r._isOk = true;
            r._value = value;
            return r;
        }
    }
    else
    {
        static Result ok(ref T value) @system
        {
            import core.stdc.string : memcpy;
            Result r;
            r._isOk = true;
            r._valuePtr = cast(T*)GC.malloc(T.sizeof);
            memcpy(r._valuePtr, &value, T.sizeof);
            // Clear source to prevent double cleanup
            memset(&value, 0, T.sizeof);
            return r;
        }
    }
    
    /// Create an error result (@system: union access controlled by _isOk flag)
    static Result err(E error) @system
    {
        Result r;
        r._isOk = false;
        r._error = error;
        return r;
    }
    
    /// Check if result is Ok
    @property bool isOk() const pure nothrow @nogc => _isOk;
    
    /// Check if result is Err
    @property bool isErr() const pure nothrow @nogc => !_isOk;
    
    /// Format error for exception message
    private string formatError(string prefix = "Called unwrap on an error") const
    {
        static if (is(E : string))
            return prefix ~ ": " ~ _error;
        else static if (is(typeof(_error.toString()) : string))
            return prefix ~ ": " ~ _error.toString();
        else
            return prefix;
    }
    
    /// Unwrap value (throws if error)
    static if (IsTrulyCopyable!T)
    {
        T unwrap() @system
        {
            if (!_isOk) assert(false, "Result unwrap failed: " ~ formatError());
            return _value;
        }
    }
    else
    {
        ref T unwrap() @system
        {
            if (!_isOk) assert(false, "Result unwrap failed: " ~ formatError());
            return *_valuePtr;
        }
    }
    
    /// Unwrap with contextual error message (Rust-style expect)
    static if (IsTrulyCopyable!T)
    {
        T expect(string context) @system
        {
            if (!_isOk) assert(false, "Result unwrap failed: " ~ formatError(context));
            return _value;
        }
    }
    else
    {
        ref T expect(string context) @system
        {
            if (!_isOk) assert(false, "Result unwrap failed: " ~ formatError(context));
            return *_valuePtr;
        }
    }
    
    /// Unwrap or return default value (only for copyable types)
    static if (IsTrulyCopyable!T)
    {
        T unwrapOr(T defaultValue) @system
        {
            return _isOk ? _value : defaultValue;
        }
    }
    
    /// Unwrap or compute default value lazily (only for copyable types)
    static if (IsTrulyCopyable!T)
    {
        T unwrapOrElse(T delegate() fn)
        {
            return _isOk ? _value : fn();
        }
    }
    
    /// Get error (throws if ok)
    E unwrapErr() @system
    {
        if (_isOk) throw new Exception("Called unwrapErr on an Ok value");
        return _error;
    }
    
    /// Map success value to new type (only for copyable types)
    static if (IsTrulyCopyable!T)
    {
        Result!(U, E) map(U)(U delegate(T) fn)
        {
            if (_isOk)
                return Result!(U, E).ok(fn(_value));
            else
                return Result!(U, E).err(_error);
        }
    }
    
    /// Map error to new type (only for copyable T)
    static if (IsTrulyCopyable!T)
    {
        Result!(T, F) mapErr(F)(F delegate(E) fn)
        {
            if (_isOk)
                return Result!(T, F).ok(_value);
            else
                return Result!(T, F).err(fn(_error));
        }
    }
    
    /// Chain operations (flatMap/bind) - only for copyable types
    static if (IsTrulyCopyable!T)
    {
        Result!(U, E) andThen(U)(Result!(U, E) delegate(T) fn)
        {
            if (_isOk)
                return fn(_value);
            else
                return Result!(U, E).err(_error);
        }
    }
    
    /// Apply function if error (only for copyable types)
    static if (IsTrulyCopyable!T)
    {
        Result!(T, E) orElse(Result!(T, E) delegate(E) fn)
        {
            if (_isOk)
                return Result!(T, E).ok(_value);
            else
                return fn(_error);
        }
    }
    
    /// Inspect value without consuming (for debugging)
    static if (IsTrulyCopyable!T)
    {
        ref Result inspect(void delegate(ref const T) fn) return
        {
            if (_isOk)
                fn(_value);
            return this;
        }
    }
    else
    {
        ref Result inspect(void delegate(ref const T) fn) return
        {
            if (_isOk)
                fn(*_valuePtr);
            return this;
        }
    }
    
    /// Inspect error without consuming (for debugging)
    ref Result inspectErr(void delegate(ref const E) fn) return
    {
        if (!_isOk)
            fn(_error);
        return this;
    }
    
    /// Match on result (pattern matching style) - only for copyable types
    static if (IsTrulyCopyable!T)
    {
        U match(U)(U delegate(T) onOk, U delegate(E) onErr)
        {
            if (_isOk)
                return onOk(_value);
            else
                return onErr(_error);
        }
    }
    else
    {
        U match(U)(U delegate(ref T) onOk, U delegate(E) onErr)
        {
            if (_isOk)
                return onOk(*_valuePtr);
            else
                return onErr(_error);
        }
    }
}

/// Specialization for void value type (used by BuildResult!void)
struct Result(T : void, E)
{
    private bool _isOk;
    private E _error;
    
    /// Create a successful void result
    static Result ok() @system
    {
        Result r;
        r._isOk = true;
        return r;
    }
    
    /// Create an error result
    static Result err(E error) @system
    {
        Result r;
        r._isOk = false;
        r._error = error;
        return r;
    }
    
    @property bool isOk() const pure nothrow @nogc => _isOk;
    @property bool isErr() const pure nothrow @nogc => !_isOk;
    
    /// Unwrap error (asserts if Ok)
    E unwrapErr() @system
    {
        assert(!_isOk, "Called unwrapErr on Ok result");
        return _error;
    }
    
    /// Get error or null
    const(E)* err() const @system => _isOk ? null : &_error;
}

/// Helper to create Ok result (copyable types)
Result!(T, E) Ok(T, E)(T value) @system if (IsTrulyCopyable!T)
{
    return Result!(T, E).ok(value);
}

/// Helper to create Ok result (non-copyable types)
Result!(T, E) Ok(T, E)(ref T value) @system if (!IsTrulyCopyable!T)
{
    return Result!(T, E).ok(value);
}

/// Helper to create Ok void result
Result!(void, E) Ok(T : void, E)() @system { return Result!(void, E).ok(); }

/// Helper to create Err result
Result!(T, E) Err(T, E)(E error) @system { return Result!(T, E).err(error); }

/// Specialized Result for void type (operations that don't return a value)
/// This specialization is necessary because void cannot be stored in unions or fields
struct Result(E) if (is(E))
{
    private bool _isOk;
    private E _error;
    
    /// Create a successful void result
    static Result ok() @system
    {
        Result r;
        r._isOk = true;
        return r;
    }
    
    /// Create an error result
    static Result err(E error) @system
    {
        Result r;
        r._isOk = false;
        r._error = error;
        return r;
    }
    
    /// Check if result is Ok
    @property bool isOk() const pure nothrow @nogc
    {
        return _isOk;
    }
    
    /// Check if result is Err
    @property bool isErr() const pure nothrow @nogc
    {
        return !_isOk;
    }
    
    /// Format error for exception message
    private string formatError(string prefix = "Called unwrap on an error") const
    {
        static if (is(E : string))
            return prefix ~ ": " ~ _error;
        else static if (is(typeof(_error.toString()) : string))
            return prefix ~ ": " ~ _error.toString();
        else
            return prefix;
    }
    
    /// Unwrap (throws if error, returns void if ok)
    void unwrap()
    {
        if (!_isOk) assert(false, "Result unwrap failed: " ~ formatError());
    }
    
    /// Unwrap with contextual error message (Rust-style expect)
    void expect(string context)
    {
        if (!_isOk) assert(false, "Result unwrap failed: " ~ formatError(context));
    }
    
    /// Get error (throws if ok)
    E unwrapErr() @system
    {
        if (_isOk) assert(false, "Called unwrapErr on an Ok value");
        return _error;
    }
    
    /// Map success to new type (delegate takes no parameters)
    Result!(U, E) map(U)(U delegate() fn)
    {
        if (_isOk)
            return Result!(U, E).ok(fn());
        else
            return Result!(U, E).err(_error);
    }
    
    /// Map to another void result (delegate takes no parameters)
    Result!E map()(void delegate() fn)
    {
        if (_isOk)
        {
            fn();
            return Result!E.ok();
        }
        else
            return Result!E.err(_error);
    }
    
    /// Map error to new type
    Result!F mapErr(F)(F delegate(E) fn)
    {
        if (_isOk)
            return Result!F.ok();
        else
            return Result!F.err(fn(_error));
    }
    
    /// Chain operations (flatMap/bind) - delegate takes no parameters
    Result!(U, E) andThen(U)(Result!(U, E) delegate() fn)
    {
        if (_isOk)
            return fn();
        else
            return Result!(U, E).err(_error);
    }
    
    /// Chain to another void result - delegate takes no parameters
    Result!E andThen()(Result!E delegate() fn)
    {
        if (_isOk)
            return fn();
        else
            return Result!E.err(_error);
    }
    
    /// Apply function if error
    Result!E orElse(Result!E delegate(E) fn)
    {
        if (_isOk)
            return Result!E.ok();
        else
            return fn(_error);
    }
    
    /// Inspect success without consuming (delegate takes no parameters)
    ref Result inspect(void delegate() fn) return
    {
        if (_isOk)
            fn();
        return this;
    }
    
    /// Inspect error without consuming
    ref Result inspectErr(void delegate(ref const E) fn) return
    {
        if (!_isOk)
            fn(_error);
        return this;
    }
    
    /// Match on result (pattern matching style) - onOk takes no parameters
    U match(U)(U delegate() onOk, U delegate(E) onErr)
    {
        if (_isOk)
            return onOk();
        else
            return onErr(_error);
    }
}

/// Void result type alias (for operations that don't return a value)
alias VoidResult(E) = Result!E;

// ============================================================================
// BuildError-specific Result Aliases
// ============================================================================

/// Import BuildError for type aliases
import infrastructure.errors.types.types : BuildError;

/// Result with a value and BuildError - the most common pattern in the codebase
alias BuildResult(T) = Result!(T, BuildError);

/// Void result with BuildError - for operations that don't return a value
alias VoidBuildResult = Result!BuildError;

/// Create a successful void result
Result!E success(E)() @system { return Result!E.ok(); }

/// Create an error void result
Result!E failure(E)(E error) @system { return Result!E.err(error); }

/// Helper to create Ok void result (type-inferred from error type)
Result!E Ok(E)() @system { return Result!E.ok(); }

/// Helper to create Err void result (explicit)
Result!E Err(E)(E error) @system { return Result!E.err(error); }

/// Collect results into a single result (stops at first error)
Result!(T[], E) collect(T, E)(Result!(T, E)[] results)
{
    T[] values;
    values.reserve(results.length);
    foreach (r; results)
    {
        if (r.isErr) return Result!(T[], E).err(r.unwrapErr());
        values ~= r.unwrap();
    }
    return Result!(T[], E).ok(values);
}

/// Try to execute a function and catch exceptions as errors
Result!(T, E) trying(T, E)(T delegate() fn, E delegate(Exception) errorMapper)
{
    try
    {
        return Result!(T, E).ok(fn());
    }
    catch (Exception e)
    {
        return Result!(T, E).err(errorMapper(e));
    }
}

unittest
{
    // Test Ok path
    auto r1 = Result!(int, string).ok(42);
    assert(r1.isOk);
    assert(r1.unwrap() == 42);
    
    // Test Err path
    auto r2 = Result!(int, string).err("failed");
    assert(r2.isErr);
    assert(r2.unwrapErr() == "failed");
    
    // Test map
    auto r3 = r1.map((int x) => x * 2);
    assert(r3.unwrap() == 84);
    
    // Test andThen
    auto r4 = r1.andThen((int x) => Result!(string, string).ok(x.to!string));
    assert(r4.unwrap() == "42");
}

unittest
{
    // Test void Result - Ok path
    auto v1 = Result!string.ok();
    assert(v1.isOk);
    assert(!v1.isErr);
    v1.unwrap(); // Should not throw
    
    // Test void Result - Err path
    auto v2 = Result!string.err("operation failed");
    assert(v2.isErr);
    assert(!v2.isOk);
    assert(v2.unwrapErr() == "operation failed");
    
    // Test map from void to value
    auto v3 = v1.map(() => 42);
    assert(v3.isOk);
    assert(v3.unwrap() == 42);
    
    // Test map from void to void
    bool called = false;
    auto v4 = v1.map(() { called = true; });
    assert(v4.isOk);
    assert(called);
    
    // Test map preserves error
    auto v5 = v2.map(() => 42);
    assert(v5.isErr);
    assert(v5.unwrapErr() == "operation failed");
    
    // Test andThen from void to value
    auto v6 = v1.andThen(() => Result!(int, string).ok(99));
    assert(v6.isOk);
    assert(v6.unwrap() == 99);
    
    // Test andThen from void to void
    auto v7 = v1.andThen(() => Result!string.ok());
    assert(v7.isOk);
    
    // Test andThen preserves error
    auto v8 = v2.andThen(() => Result!(int, string).ok(99));
    assert(v8.isErr);
    assert(v8.unwrapErr() == "operation failed");
    
    // Test mapErr
    auto v9 = v2.mapErr((string s) => s.length);
    assert(v9.isErr);
    assert(v9.unwrapErr() == "operation failed".length);
    
    // Test inspect
    bool inspected = false;
    v1.inspect(() { inspected = true; });
    assert(inspected);
    
    // Test inspectErr
    bool inspectedErr = false;
    v2.inspectErr((ref const string s) { inspectedErr = true; });
    assert(inspectedErr);
    
    // Test match
    auto matched = v1.match(
        () => "success",
        (string e) => "error: " ~ e
    );
    assert(matched == "success");
    
    auto matchedErr = v2.match(
        () => "success",
        (string e) => "error: " ~ e
    );
    assert(matchedErr == "error: operation failed");
    
    // Test helper functions
    auto v10 = success!string();
    assert(v10.isOk);
    
    auto v11 = failure!string("helper error");
    assert(v11.isErr);
    assert(v11.unwrapErr() == "helper error");
    
    // Test Ok/Err helpers
    auto v12 = Ok!string();
    assert(v12.isOk);
    
    auto v13 = Result!string.err("explicit error");
    assert(v13.isErr);
    assert(v13.unwrapErr() == "explicit error");
}

