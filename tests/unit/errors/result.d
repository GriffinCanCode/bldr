module tests.unit.errors.result;

import std.stdio;
import std.algorithm;
import std.conv;
import infrastructure.errors.handling.result;
import infrastructure.errors.types.types;
import tests.harness;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Basic Ok creation and unwrap");
    
    auto result = Ok!(int, string)(42);
    
    Assert.isTrue(result.isOk);
    Assert.isFalse(result.isErr);
    Assert.equal(result.unwrap(), 42);
    
    writeln("\x1b[32m  ✓ Ok result creation and unwrap works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Basic Err creation and unwrap");
    
    auto result = Err!(int, string)("Something went wrong");
    
    Assert.isFalse(result.isOk);
    Assert.isTrue(result.isErr);
    Assert.equal(result.unwrapErr(), "Something went wrong");
    
    writeln("\x1b[32m  ✓ Err result creation and unwrapErr works\x1b[0m");
}

unittest
{
    import core.exception : AssertError;
    
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Unwrap on error throws");
    
    auto result = Err!(int, string)("Error");
    
    void unwrapErr() { result.unwrap(); }
    Assert.throws!AssertError(unwrapErr());
    
    writeln("\x1b[32m  ✓ Unwrap on error throws correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - UnwrapErr on Ok throws");
    
    auto result = Ok!(int, string)(42);
    
    void unwrapErrOnOk() { result.unwrapErr(); }
    Assert.throws!Exception(unwrapErrOnOk());
    
    writeln("\x1b[32m  ✓ UnwrapErr on Ok throws correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Expect on Ok returns value");
    
    auto result = Ok!(int, string)(42);
    auto value = result.expect("Should not fail");
    
    Assert.equal(value, 42);
    
    writeln("\x1b[32m  ✓ Expect on Ok returns value correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Expect on Err throws with context");
    
    auto result = Err!(int, string)("Operation failed");
    
    bool caughtException = false;
    string exceptionMessage = "";
    
    try
    {
        result.expect("Critical operation");
    }
    catch (Throwable e)
    {
        caughtException = true;
        exceptionMessage = e.msg;
    }
    
    Assert.isTrue(caughtException);
    Assert.isTrue(exceptionMessage.canFind("Critical operation"));
    Assert.isTrue(exceptionMessage.canFind("Operation failed"));
    
    writeln("\x1b[32m  ✓ Expect includes context in error message\x1b[0m");
}

// ==================== MONAD OPERATIONS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Map on Ok value");
    
    auto result = Ok!(int, string)(5);
    auto mapped = result.map((int x) => x * 2);
    
    Assert.isTrue(mapped.isOk);
    Assert.equal(mapped.unwrap(), 10);
    
    writeln("\x1b[32m  ✓ Map on Ok value works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Map on Err propagates error");
    
    auto result = Err!(int, string)("Error");
    auto mapped = result.map((int x) => x * 2);
    
    Assert.isTrue(mapped.isErr);
    Assert.equal(mapped.unwrapErr(), "Error");
    
    writeln("\x1b[32m  ✓ Map on Err propagates error correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Map type transformation");
    
    auto result = Ok!(int, string)(42);
    auto mapped = result.map((int x) => "Value: " ~ x.to!string);
    
    Assert.isTrue(mapped.isOk);
    Assert.equal(mapped.unwrap(), "Value: 42");
    
    writeln("\x1b[32m  ✓ Map type transformation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - MapErr transforms error");
    
    auto result = Err!(int, string)("Error");
    auto mapped = result.mapErr((string e) => e ~ " (transformed)");
    
    Assert.isTrue(mapped.isErr);
    Assert.equal(mapped.unwrapErr(), "Error (transformed)");
    
    writeln("\x1b[32m  ✓ MapErr transforms error correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - MapErr on Ok preserves value");
    
    auto result = Ok!(int, string)(42);
    auto mapped = result.mapErr((string e) => e ~ " (transformed)");
    
    Assert.isTrue(mapped.isOk);
    Assert.equal(mapped.unwrap(), 42);
    
    writeln("\x1b[32m  ✓ MapErr on Ok preserves value\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - AndThen chains success");
    
    auto result = Ok!(int, string)(5);
    auto chained = result.andThen((int x) => Ok!(int, string)(x * 2));
    
    Assert.isTrue(chained.isOk);
    Assert.equal(chained.unwrap(), 10);
    
    writeln("\x1b[32m  ✓ AndThen chains success correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - AndThen propagates error");
    
    auto result = Err!(int, string)("Initial error");
    auto chained = result.andThen((int x) => Ok!(int, string)(x * 2));
    
    Assert.isTrue(chained.isErr);
    Assert.equal(chained.unwrapErr(), "Initial error");
    
    writeln("\x1b[32m  ✓ AndThen propagates error correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - AndThen can transform to error");
    
    auto result = Ok!(int, string)(5);
    auto chained = result.andThen((int x) => 
        x > 10 ? Ok!(int, string)(x) : Err!(int, string)("Too small")
    );
    
    Assert.isTrue(chained.isErr);
    Assert.equal(chained.unwrapErr(), "Too small");
    
    writeln("\x1b[32m  ✓ AndThen can transform to error\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - OrElse provides fallback");
    
    auto result = Err!(int, string)("Error");
    auto recovered = result.orElse((string e) => Ok!(int, string)(99));
    
    Assert.isTrue(recovered.isOk);
    Assert.equal(recovered.unwrap(), 99);
    
    writeln("\x1b[32m  ✓ OrElse provides fallback correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - OrElse on Ok preserves value");
    
    auto result = Ok!(int, string)(42);
    auto recovered = result.orElse((string e) => Ok!(int, string)(99));
    
    Assert.isTrue(recovered.isOk);
    Assert.equal(recovered.unwrap(), 42);
    
    writeln("\x1b[32m  ✓ OrElse on Ok preserves value\x1b[0m");
}

// ==================== CHAINING OPERATIONS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Complex chaining success path");
    
    auto result = Ok!(int, string)(5)
        .map((int x) => x * 2)
        .andThen((int x) => Ok!(int, string)(x + 3))
        .map((int x) => x.to!string);
    
    Assert.isTrue(result.isOk);
    Assert.equal(result.unwrap(), "13");
    
    writeln("\x1b[32m  ✓ Complex chaining works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Chaining stops at first error");
    
    auto result = Ok!(int, string)(5)
        .map((int x) => x * 2)
        .andThen((int x) => Err!(int, string)("Failed at step 2"))
        .map((int x) => x + 100); // This should not execute
    
    Assert.isTrue(result.isErr);
    Assert.equal(result.unwrapErr(), "Failed at step 2");
    
    writeln("\x1b[32m  ✓ Chaining stops at first error correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Chaining with recovery");
    
    auto result = Ok!(int, string)(5)
        .andThen((int x) => Err!(int, string)("Temporary failure"))
        .orElse((string e) => Ok!(int, string)(100))
        .map((int x) => x * 2);
    
    Assert.isTrue(result.isOk);
    Assert.equal(result.unwrap(), 200);
    
    writeln("\x1b[32m  ✓ Chaining with recovery works correctly\x1b[0m");
}

// ==================== UNWRAP ALTERNATIVES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - UnwrapOr provides default on error");
    
    auto ok = Ok!(int, string)(42);
    auto err = Err!(int, string)("Error");
    
    Assert.equal(ok.unwrapOr(99), 42);
    Assert.equal(err.unwrapOr(99), 99);
    
    writeln("\x1b[32m  ✓ UnwrapOr provides default correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - UnwrapOrElse computes default lazily");
    
    bool called = false;
    auto ok = Ok!(int, string)(42);
    auto err = Err!(int, string)("Error");
    
    auto result1 = ok.unwrapOrElse(() { called = true; return 99; });
    Assert.equal(result1, 42);
    Assert.isFalse(called, "Should not call delegate on Ok");
    
    auto result2 = err.unwrapOrElse(() { called = true; return 99; });
    Assert.equal(result2, 99);
    Assert.isTrue(called, "Should call delegate on Err");
    
    writeln("\x1b[32m  ✓ UnwrapOrElse computes lazily correctly\x1b[0m");
}

// ==================== MATCH PATTERN ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Match on Ok");
    
    auto result = Ok!(int, string)(42);
    auto matched = result.match(
        (int x) => "Got value: " ~ x.to!string,
        (string e) => "Got error: " ~ e
    );
    
    Assert.equal(matched, "Got value: 42");
    
    writeln("\x1b[32m  ✓ Match on Ok works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Match on Err");
    
    auto result = Err!(int, string)("Something failed");
    auto matched = result.match(
        (int x) => "Got value: " ~ x.to!string,
        (string e) => "Got error: " ~ e
    );
    
    Assert.equal(matched, "Got error: Something failed");
    
    writeln("\x1b[32m  ✓ Match on Err works correctly\x1b[0m");
}

// ==================== INSPECT OPERATIONS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Inspect on Ok calls function");
    
    int inspectedValue = 0;
    auto result = Ok!(int, string)(42);
    
    result.inspect((ref const int x) { inspectedValue = x; });
    
    Assert.equal(inspectedValue, 42);
    Assert.isTrue(result.isOk); // Inspect should not consume
    
    writeln("\x1b[32m  ✓ Inspect on Ok works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Inspect on Err does not call function");
    
    bool called = false;
    auto result = Err!(int, string)("Error");
    
    result.inspect((ref const int x) { called = true; });
    
    Assert.isFalse(called);
    
    writeln("\x1b[32m  ✓ Inspect on Err does not call function\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - InspectErr on Err calls function");
    
    string inspectedError = "";
    auto result = Err!(int, string)("Failed");
    
    result.inspectErr((ref const string e) { inspectedError = e; });
    
    Assert.equal(inspectedError, "Failed");
    
    writeln("\x1b[32m  ✓ InspectErr on Err works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - InspectErr on Ok does not call function");
    
    bool called = false;
    auto result = Ok!(int, string)(42);
    
    result.inspectErr((ref const string e) { called = true; });
    
    Assert.isFalse(called);
    
    writeln("\x1b[32m  ✓ InspectErr on Ok does not call function\x1b[0m");
}

// ==================== VOID RESULT SPECIALIZATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Void Result Ok");
    
    auto result = Result!string.ok();
    
    Assert.isTrue(result.isOk);
    Assert.isFalse(result.isErr);
    
    // Unwrap should not throw
    Assert.notThrows(result.unwrap());
    
    writeln("\x1b[32m  ✓ Void Result Ok works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Void Result Err");
    
    auto result = Result!string.err("Operation failed");
    
    Assert.isFalse(result.isOk);
    Assert.isTrue(result.isErr);
    Assert.equal(result.unwrapErr(), "Operation failed");
    
    writeln("\x1b[32m  ✓ Void Result Err works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Void Result map to value");
    
    auto result = Result!string.ok();
    auto mapped = result.map(() => 42);
    
    Assert.isTrue(mapped.isOk);
    Assert.equal(mapped.unwrap(), 42);
    
    writeln("\x1b[32m  ✓ Void Result map to value works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Void Result map to void");
    
    bool executed = false;
    auto result = Result!string.ok();
    auto mapped = result.map(() { executed = true; });
    
    Assert.isTrue(mapped.isOk);
    Assert.isTrue(executed);
    
    writeln("\x1b[32m  ✓ Void Result map to void works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Void Result andThen");
    
    auto result = Result!string.ok();
    auto chained = result.andThen(() => Ok!(int, string)(42));
    
    Assert.isTrue(chained.isOk);
    Assert.equal(chained.unwrap(), 42);
    
    writeln("\x1b[32m  ✓ Void Result andThen works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Void Result error propagation");
    
    auto result = Result!string.err("Failed");
    auto chained = result.andThen(() => Ok!(int, string)(42));
    
    Assert.isTrue(chained.isErr);
    Assert.equal(chained.unwrapErr(), "Failed");
    
    writeln("\x1b[32m  ✓ Void Result error propagation works\x1b[0m");
}

// ==================== PRACTICAL USE CASES ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Simulated file operation");
    
    // Simulate file read operation
    Result!(string, string) readFile(string path)
    {
        if (path == "valid.txt")
            return Ok!(string, string)("File contents");
        else
            return Err!(string, string)("File not found: " ~ path);
    }
    
    auto result1 = readFile("valid.txt");
    Assert.isTrue(result1.isOk);
    Assert.equal(result1.unwrap(), "File contents");
    
    auto result2 = readFile("invalid.txt");
    Assert.isTrue(result2.isErr);
    Assert.equal(result2.unwrapErr(), "File not found: invalid.txt");
    
    writeln("\x1b[32m  ✓ Simulated file operation works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Chained file operations");
    
    Result!(string, string) readFile(string path)
    {
        if (path == "config.json")
            return Ok!(string, string)(`{"value": 42}`);
        return Err!(string, string)("File not found");
    }
    
    Result!(int, string) parseJson(string content)
    {
        // Simplified JSON parsing
        if (content.canFind("42"))
            return Ok!(int, string)(42);
        return Err!(int, string)("Parse error");
    }
    
    auto result = readFile("config.json")
        .andThen((string content) => parseJson(content))
        .map((int value) => value * 2);
    
    Assert.isTrue(result.isOk);
    Assert.equal(result.unwrap(), 84);
    
    writeln("\x1b[32m  ✓ Chained file operations work correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Error recovery with fallback");
    
    Result!(int, string) tryPrimary()
    {
        return Err!(int, string)("Primary failed");
    }
    
    Result!(int, string) trySecondary(string error)
    {
        return Ok!(int, string)(100);
    }
    
    auto result = tryPrimary()
        .orElse((string err) => trySecondary(err))
        .map((int x) => x * 2);
    
    Assert.isTrue(result.isOk);
    Assert.equal(result.unwrap(), 200);
    
    writeln("\x1b[32m  ✓ Error recovery with fallback works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Validation pipeline");
    
    Result!(int, string) validatePositive(int x)
    {
        if (x > 0)
            return Ok!(int, string)(x);
        return Err!(int, string)("Must be positive");
    }
    
    Result!(int, string) validateRange(int x)
    {
        if (x >= 1 && x <= 100)
            return Ok!(int, string)(x);
        return Err!(int, string)("Must be between 1 and 100");
    }
    
    // Valid input
    auto result1 = Ok!(int, string)(50)
        .andThen((int x) => validatePositive(x))
        .andThen((int x) => validateRange(x));
    
    Assert.isTrue(result1.isOk);
    Assert.equal(result1.unwrap(), 50);
    
    // Invalid: too large
    auto result2 = Ok!(int, string)(150)
        .andThen((int x) => validatePositive(x))
        .andThen((int x) => validateRange(x));
    
    Assert.isTrue(result2.isErr);
    Assert.equal(result2.unwrapErr(), "Must be between 1 and 100");
    
    // Invalid: negative
    auto result3 = Ok!(int, string)(-5)
        .andThen((int x) => validatePositive(x))
        .andThen((int x) => validateRange(x));
    
    Assert.isTrue(result3.isErr);
    Assert.equal(result3.unwrapErr(), "Must be positive");
    
    writeln("\x1b[32m  ✓ Validation pipeline works correctly\x1b[0m");
}

// ==================== ERROR TYPE INTEGRATION ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m errors.result - Integration with BuildError");
    
    Result!(string, BuildError) buildTarget()
    {
        auto error = new BuildFailureError("mylib", "Compilation failed");
        return Err!(string, BuildError)(error);
    }
    
    auto result = buildTarget();
    
    Assert.isTrue(result.isErr);
    auto error = cast(BuildFailureError) result.unwrapErr();
    Assert.equal(error.targetId, "mylib");
    
    writeln("\x1b[32m  ✓ Integration with BuildError works\x1b[0m");
}

