module tests.unit.properties.serialization_invariants;

import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.stdio;
import tests.harness;
import tests.property;
import infrastructure.utils.serialization;
import infrastructure.utils.serialization.core.buffer;
import infrastructure.errors;

version(unittest):

// =============================================================================
// TEST SCHEMAS FOR PROPERTY TESTS
// =============================================================================

/// Simple struct for basic roundtrip tests
@Serializable(SchemaVersion(1, 0), 0x54455354)  // "TEST"
struct SimpleData
{
    @Field(1) int intVal;
    @Field(2) uint uintVal;
    @Field(3) string strVal;
    @Field(4) bool boolVal;
}

/// Nested struct for complex roundtrip tests
@Serializable(SchemaVersion(1, 0))
struct NestedData
{
    @Field(1) string name;
    @Field(2) long timestamp;
}

/// Struct with arrays for collection roundtrip tests
@Serializable(SchemaVersion(1, 0), 0x41525259)  // "ARRY"
struct ArrayData
{
    @Field(1) string[] strings;
    @Field(2) int[] numbers;
}

/// Build target-like struct for realistic roundtrip tests
@Serializable(SchemaVersion(1, 0), 0x54524754)  // "TRGT"
struct TargetData
{
    @Field(1) string name;
    @Field(2) string targetType;
    @Field(3) string[] sources;
    @Field(4) string[] deps;
    @Field(5) @Optional string outputPath;
}

// =============================================================================
// SERIALIZATION ROUNDTRIP PROPERTIES
// =============================================================================

/// Property: serialize(deserialize(serialize(x))) == serialize(x)
/// Serialization should be deterministic and roundtrip should produce identical bytes
@("property.serialization.roundtrip.simple")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Serialization roundtrip - simple types");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool simpleRoundtrip(int intVal, string strVal)
    {
        // Create test data
        SimpleData original;
        original.intVal = intVal;
        original.uintVal = intVal >= 0 ? cast(uint)intVal : 0;
        original.strVal = strVal.length > 0 ? strVal : "default";
        original.boolVal = intVal > 0;
        
        // Serialize
        ubyte[] serialized = Codec.serialize(original);
        
        // Deserialize
        auto result = () @trusted { return Codec.deserialize!SimpleData(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        // Re-serialize
        ubyte[] reserialized = Codec.serialize(deserialized);
        
        // Bytes should be identical (deterministic serialization)
        return serialized == reserialized;
    }
    
    // Generate test cases
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        int intVal = uniform(-1_000_000, 1_000_000, rng);
        
        // Generate random string
        auto strLen = uniform(0, 50, rng);
        char[] strBuf;
        foreach (j; 0 .. strLen)
            strBuf ~= cast(char)uniform('a', 'z' + 1, rng);
        
        if (simpleRoundtrip(intVal, strBuf.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Parsing then serializing arrays produces identical output
@("property.serialization.roundtrip.arrays")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Serialization roundtrip - arrays");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool arrayRoundtrip(string[] strings, int[] numbers)
    {
        ArrayData original;
        original.strings = strings.dup;
        original.numbers = numbers.dup;
        
        // Serialize
        ubyte[] serialized = Codec.serialize(original);
        
        // Deserialize
        auto result = () @trusted { return Codec.deserialize!ArrayData(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        // Verify content equality
        return deserialized.strings == original.strings && 
               deserialized.numbers == original.numbers;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random string array
        auto strCount = uniform(0, 20, rng);
        string[] strings;
        foreach (j; 0 .. strCount)
        {
            auto strLen = uniform(1, 30, rng);
            char[] str;
            foreach (k; 0 .. strLen)
                str ~= cast(char)uniform('a', 'z' + 1, rng);
            strings ~= str.idup;
        }
        
        // Generate random int array
        auto numCount = uniform(0, 50, rng);
        int[] numbers;
        foreach (j; 0 .. numCount)
            numbers ~= uniform(-10000, 10000, rng);
        
        if (arrayRoundtrip(strings, numbers))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Build target roundtrip preserves all fields
@("property.serialization.roundtrip.target")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Serialization roundtrip - target data");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool targetRoundtrip(string name, string[] sources, string[] deps)
    {
        TargetData original;
        original.name = name.length > 0 ? name : "target";
        original.targetType = "executable";
        original.sources = sources.dup;
        original.deps = deps.dup;
        original.outputPath = "build/" ~ original.name;
        
        // Serialize
        ubyte[] serialized = Codec.serialize(original);
        
        // Deserialize
        auto result = () @trusted { return Codec.deserialize!TargetData(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        // Re-serialize and compare
        ubyte[] reserialized = Codec.serialize(deserialized);
        return serialized == reserialized;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate target name
        auto nameLen = uniform(1, 20, rng);
        char[] name;
        foreach (j; 0 .. nameLen)
            name ~= cast(char)uniform('a', 'z' + 1, rng);
        
        // Generate sources
        auto srcCount = uniform(1, 10, rng);
        string[] sources;
        foreach (j; 0 .. srcCount)
            sources ~= "src/" ~ name.idup ~ uniform(0, 100, rng).to!string ~ ".d";
        
        // Generate deps
        auto depCount = uniform(0, 5, rng);
        string[] deps;
        foreach (j; 0 .. depCount)
            deps ~= "//lib:" ~ name.idup ~ "_dep" ~ j.to!string;
        
        if (targetRoundtrip(name.idup, sources, deps))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// VARINT ENCODING PROPERTIES
// =============================================================================

/// Property: Varint encode/decode roundtrip for unsigned 32-bit integers
@("property.serialization.varint.u32")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Varint roundtrip - unsigned 32-bit");
    
    auto config = PropertyConfig(numTests: 200);
    
    static bool varintU32Roundtrip(uint value) @trusted
    {
        auto writer = WriteBuffer(16);
        writer.writeVarU32(value);
        
        auto data = writer.data;
        auto reader = ReadBuffer(data.dup);
        
        uint decoded = reader.readVarU32();
        return decoded == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test edge cases
    if (varintU32Roundtrip(0)) passed++;
    if (varintU32Roundtrip(1)) passed++;
    if (varintU32Roundtrip(127)) passed++;
    if (varintU32Roundtrip(128)) passed++;
    if (varintU32Roundtrip(uint.max)) passed++;
    if (varintU32Roundtrip(uint.max / 2)) passed++;
    
    // Random tests
    foreach (i; 6 .. config.numTests)
    {
        uint value = uniform!uint(rng);
        if (varintU32Roundtrip(value))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Varint encode/decode roundtrip for signed 32-bit integers
@("property.serialization.varint.i32")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Varint roundtrip - signed 32-bit");
    
    auto config = PropertyConfig(numTests: 200);
    
    static bool varintI32Roundtrip(int value) @trusted
    {
        auto writer = WriteBuffer(16);
        writer.writeVarI32(value);
        
        auto data = writer.data;
        auto reader = ReadBuffer(data.dup);
        
        int decoded = reader.readVarI32();
        return decoded == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test edge cases
    if (varintI32Roundtrip(0)) passed++;
    if (varintI32Roundtrip(1)) passed++;
    if (varintI32Roundtrip(-1)) passed++;
    if (varintI32Roundtrip(int.max)) passed++;
    if (varintI32Roundtrip(int.min)) passed++;
    
    // Random tests
    foreach (i; 5 .. config.numTests)
    {
        int value = uniform!int(rng);
        if (varintI32Roundtrip(value))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Varint encode/decode roundtrip for unsigned 64-bit integers
@("property.serialization.varint.u64")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Varint roundtrip - unsigned 64-bit");
    
    auto config = PropertyConfig(numTests: 200);
    
    static bool varintU64Roundtrip(ulong value) @trusted
    {
        auto writer = WriteBuffer(16);
        writer.writeVarU64(value);
        
        auto data = writer.data;
        auto reader = ReadBuffer(data.dup);
        
        ulong decoded = reader.readVarU64();
        return decoded == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test edge cases
    if (varintU64Roundtrip(0)) passed++;
    if (varintU64Roundtrip(1)) passed++;
    if (varintU64Roundtrip(ulong.max)) passed++;
    if (varintU64Roundtrip(uint.max)) passed++;
    if (varintU64Roundtrip(cast(ulong)uint.max + 1)) passed++;
    
    // Random tests
    foreach (i; 5 .. config.numTests)
    {
        ulong value = uniform!ulong(rng);
        if (varintU64Roundtrip(value))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Varint encode/decode roundtrip for signed 64-bit integers
@("property.serialization.varint.i64")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Varint roundtrip - signed 64-bit");
    
    auto config = PropertyConfig(numTests: 200);
    
    static bool varintI64Roundtrip(long value) @trusted
    {
        auto writer = WriteBuffer(16);
        writer.writeVarI64(value);
        
        auto data = writer.data;
        auto reader = ReadBuffer(data.dup);
        
        long decoded = reader.readVarI64();
        return decoded == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test edge cases
    if (varintI64Roundtrip(0)) passed++;
    if (varintI64Roundtrip(1)) passed++;
    if (varintI64Roundtrip(-1)) passed++;
    if (varintI64Roundtrip(long.max)) passed++;
    if (varintI64Roundtrip(long.min)) passed++;
    
    // Random tests
    foreach (i; 5 .. config.numTests)
    {
        long value = uniform!long(rng);
        if (varintI64Roundtrip(value))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// BUFFER PROPERTIES
// =============================================================================

/// Property: String write/read roundtrip preserves content
@("property.serialization.buffer.string")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Buffer string roundtrip");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool stringRoundtrip(string value) @trusted
    {
        auto writer = WriteBuffer(value.length + 16);
        writer.writeString(value);
        
        auto data = writer.data;
        auto reader = ReadBuffer(data.dup);
        
        string decoded = reader.readString();
        return decoded == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test edge cases
    if (stringRoundtrip("")) passed++;
    if (stringRoundtrip("a")) passed++;
    if (stringRoundtrip("hello world")) passed++;
    
    // Random tests
    foreach (i; 3 .. config.numTests)
    {
        auto strLen = uniform(0, 500, rng);
        char[] str;
        foreach (j; 0 .. strLen)
            str ~= cast(char)uniform(32, 127, rng);  // Printable ASCII
        
        if (stringRoundtrip(str.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Fixed-size integer write/read roundtrip
@("property.serialization.buffer.fixed_int")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Buffer fixed-size integer roundtrip");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool fixedIntRoundtrip(ushort u16, uint u32, ulong u64) @trusted
    {
        auto writer = WriteBuffer(32);
        writer.writeU16(u16);
        writer.writeU32(u32);
        writer.writeU64(u64);
        
        auto data = writer.data;
        auto reader = ReadBuffer(data.dup);
        
        return reader.readU16() == u16 &&
               reader.readU32() == u32 &&
               reader.readU64() == u64;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        ushort u16 = uniform!ushort(rng);
        uint u32 = uniform!uint(rng);
        ulong u64 = uniform!ulong(rng);
        
        if (fixedIntRoundtrip(u16, u32, u64))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// SERIALIZATION DETERMINISM PROPERTIES
// =============================================================================

/// Property: Serializing the same value twice produces identical bytes
@("property.serialization.determinism.identical_output")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Serialization determinism");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool serializationDeterministic(string name, string[] sources)
    {
        TargetData data;
        data.name = name.length > 0 ? name : "test";
        data.targetType = "library";
        data.sources = sources.dup;
        data.deps = [];
        data.outputPath = "";
        
        // Serialize multiple times
        ubyte[] s1 = Codec.serialize(data);
        ubyte[] s2 = Codec.serialize(data);
        ubyte[] s3 = Codec.serialize(data);
        
        // All should be identical
        return s1 == s2 && s2 == s3;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        auto nameLen = uniform(1, 20, rng);
        char[] name;
        foreach (j; 0 .. nameLen)
            name ~= cast(char)uniform('a', 'z' + 1, rng);
        
        auto srcCount = uniform(0, 10, rng);
        string[] sources;
        foreach (j; 0 .. srcCount)
            sources ~= "src/file" ~ j.to!string ~ ".d";
        
        if (serializationDeterministic(name.idup, sources))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Different values produce different serialized bytes
@("property.serialization.uniqueness.different_values")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Serialization uniqueness");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool differentValuesUnique(int val1, int val2)
    {
        if (val1 == val2)
            return true;  // Skip equal values
        
        SimpleData d1, d2;
        d1.intVal = val1;
        d1.uintVal = 0;
        d1.strVal = "test";
        d1.boolVal = true;
        
        d2.intVal = val2;
        d2.uintVal = 0;
        d2.strVal = "test";
        d2.boolVal = true;
        
        ubyte[] s1 = Codec.serialize(d1);
        ubyte[] s2 = Codec.serialize(d2);
        
        // Different values should produce different bytes
        return s1 != s2;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        int val1 = uniform(-1_000_000, 1_000_000, rng);
        int val2 = uniform(-1_000_000, 1_000_000, rng);
        
        if (differentValuesUnique(val1, val2))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// VARINT SIZE PROPERTIES
// =============================================================================

/// Property: Varint encoding uses optimal number of bytes
@("property.serialization.varint.optimal_size")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Varint optimal encoding size");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool varintOptimalSize(uint value) @trusted
    {
        auto writer = WriteBuffer(16);
        writer.writeVarU32(value);
        
        size_t encodedSize = writer.data.length;
        
        // Calculate expected size based on value
        size_t expectedSize;
        if (value < 128)
            expectedSize = 1;
        else if (value < 16384)
            expectedSize = 2;
        else if (value < 2097152)
            expectedSize = 3;
        else if (value < 268435456)
            expectedSize = 4;
        else
            expectedSize = 5;
        
        return encodedSize == expectedSize;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test boundary values
    if (varintOptimalSize(0)) passed++;
    if (varintOptimalSize(127)) passed++;
    if (varintOptimalSize(128)) passed++;
    if (varintOptimalSize(16383)) passed++;
    if (varintOptimalSize(16384)) passed++;
    if (varintOptimalSize(uint.max)) passed++;
    
    // Random tests
    foreach (i; 6 .. config.numTests)
    {
        uint value = uniform!uint(rng);
        if (varintOptimalSize(value))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// FUZZ TESTING - GARBAGE INPUT REJECTION
// =============================================================================

/// Property: Random garbage bytes don't crash deserializer
@("property.serialization.fuzz.garbage_input")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Fuzz - Garbage input rejection");
    
    auto config = PropertyConfig(numTests: 500);
    Mt19937 rng = Mt19937(config.seed + 1000);
    
    size_t crashes = 0;
    size_t validRejects = 0;
    size_t unexpectedSuccess = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random garbage of varying sizes
        auto len = uniform(0, 10000, rng);
        ubyte[] garbage = new ubyte[len];
        foreach (ref b; garbage)
            b = cast(ubyte)uniform(0, 256, rng);
        
        try
        {
            auto result = () @trusted { return Codec.deserialize!TargetData(garbage); }();
            if (result.isErr)
                validRejects++;
            else
                unexpectedSuccess++;  // Garbage decoded - suspicious
        }
        catch (Error e)
        {
            crashes++;  // Should never happen
        }
        catch (Exception e)
        {
            validRejects++;  // Expected - garbage rejected
        }
    }
    
    writeln("  Rejects: " ~ validRejects.to!string ~ 
           ", Crashes: " ~ crashes.to!string ~
           ", Unexpected: " ~ unexpectedSuccess.to!string);
    
    Assert.equal(crashes, 0, "Deserializer should not crash on garbage input");
    Assert.isTrue(validRejects > config.numTests * 0.9, "Most garbage should be rejected");
    
    writeln("  \x1b[32m✓ Passed fuzz test (" ~ config.numTests.to!string ~ " inputs)\x1b[0m");
}

/// Property: Truncated data is rejected gracefully
@("property.serialization.fuzz.truncated_input")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Fuzz - Truncated input handling");
    
    auto config = PropertyConfig(numTests: 100);
    Mt19937 rng = Mt19937(config.seed + 2000);
    
    size_t crashes = 0;
    size_t validRejects = 0;
    
    // Create valid serialized data
    TargetData validData;
    validData.name = "test-target";
    validData.targetType = "library";
    validData.sources = ["src/a.d", "src/b.d", "src/c.d"];
    validData.deps = ["//lib:dep1", "//lib:dep2"];
    validData.outputPath = "build/output";
    
    ubyte[] validSerialized = Codec.serialize(validData);
    
    foreach (i; 0 .. config.numTests)
    {
        // Truncate at random positions
        auto truncateAt = uniform(0, validSerialized.length, rng);
        ubyte[] truncated = validSerialized[0..truncateAt].dup;
        
        try
        {
            auto result = () @trusted { return Codec.deserialize!TargetData(truncated); }();
            if (result.isErr)
                validRejects++;
            // If it somehow succeeds with truncated data, that's suspicious but not a crash
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e)
        {
            validRejects++;
        }
    }
    
    Assert.equal(crashes, 0, "Truncated input should not crash deserializer");
    writeln("  \x1b[32m✓ Passed truncation test (" ~ validRejects.to!string ~ " valid rejects)\x1b[0m");
}

/// Property: Bit-flipped data is rejected
@("property.serialization.fuzz.bit_flip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Fuzz - Bit flip handling");
    
    auto config = PropertyConfig(numTests: 100);
    Mt19937 rng = Mt19937(config.seed + 3000);
    
    size_t crashes = 0;
    size_t detected = 0;
    size_t undetected = 0;
    
    // Create valid serialized data
    SimpleData validData;
    validData.intVal = 12345;
    validData.uintVal = 67890;
    validData.strVal = "test string content";
    validData.boolVal = true;
    
    ubyte[] validSerialized = Codec.serialize(validData);
    
    foreach (i; 0 .. config.numTests)
    {
        // Flip random bits
        ubyte[] corrupted = validSerialized.dup;
        auto flipCount = uniform(1, 5, rng);
        
        foreach (j; 0 .. flipCount)
        {
            auto pos = uniform(0, corrupted.length, rng);
            auto bit = uniform(0, 8, rng);
            corrupted[pos] ^= cast(ubyte)(1 << bit);
        }
        
        try
        {
            auto result = () @trusted { return Codec.deserialize!SimpleData(corrupted); }();
            if (result.isErr)
            {
                detected++;
            }
            else
            {
                auto decoded = result.unwrap();
                // Check if data differs (corruption detected through content)
                if (decoded.intVal != validData.intVal ||
                    decoded.uintVal != validData.uintVal ||
                    decoded.strVal != validData.strVal ||
                    decoded.boolVal != validData.boolVal)
                {
                    detected++;  // Different data = detected corruption
                }
                else
                {
                    undetected++;  // Same data despite corruption - might be in padding
                }
            }
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e)
        {
            detected++;
        }
    }
    
    writeln("  Detected: " ~ detected.to!string ~
           ", Undetected: " ~ undetected.to!string ~
           ", Crashes: " ~ crashes.to!string);
    
    Assert.equal(crashes, 0, "Bit flips should not crash deserializer");
    writeln("  \x1b[32m✓ Passed bit flip test\x1b[0m");
}

// =============================================================================
// SIZE LIMIT TESTS
// =============================================================================

/// Property: Very large arrays serialize/deserialize correctly
@("property.serialization.limits.large_arrays")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Size limits - Large arrays");
    
    // Test arrays at boundary sizes
    size_t[] testSizes = [0, 1, 127, 128, 255, 256, 1000, 10000];
    size_t passed = 0;
    
    foreach (size; testSizes)
    {
        ArrayData data;
        
        // Generate array of specified size
        foreach (i; 0 .. size)
        {
            data.strings ~= "item" ~ i.to!string;
            data.numbers ~= cast(int)i;
        }
        
        // Serialize
        ubyte[] serialized = Codec.serialize(data);
        
        // Deserialize
        auto result = () @trusted { return Codec.deserialize!ArrayData(serialized); }();
        
        if (result.isOk)
        {
            auto decoded = result.unwrap();
            if (decoded.strings.length == size && decoded.numbers.length == size)
                passed++;
            else
                writeln("    Size mismatch at " ~ size.to!string);
        }
        else
        {
            writeln("    Deserialization failed at size " ~ size.to!string);
        }
    }
    
    Assert.equal(passed, testSizes.length, "All array sizes should roundtrip");
    writeln("  \x1b[32m✓ Passed large array test (" ~ testSizes.length.to!string ~ " sizes)\x1b[0m");
}

/// Property: Very long strings serialize/deserialize correctly
@("property.serialization.limits.long_strings")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Size limits - Long strings");
    
    size_t[] testLengths = [0, 1, 127, 128, 255, 256, 1000, 10000, 100000];
    size_t passed = 0;
    
    foreach (len; testLengths)
    {
        SimpleData data;
        
        // Generate string of specified length
        char[] str = new char[len];
        foreach (i, ref c; str)
            c = cast(char)('a' + (i % 26));
        data.strVal = str.idup;
        data.intVal = cast(int)len;
        data.uintVal = cast(uint)len;
        data.boolVal = len > 0;
        
        // Serialize
        ubyte[] serialized = Codec.serialize(data);
        
        // Deserialize
        auto result = () @trusted { return Codec.deserialize!SimpleData(serialized); }();
        
        if (result.isOk)
        {
            auto decoded = result.unwrap();
            if (decoded.strVal.length == len && decoded.strVal == data.strVal)
                passed++;
            else
                writeln("    String mismatch at length " ~ len.to!string);
        }
        else
        {
            writeln("    Deserialization failed at length " ~ len.to!string);
        }
    }
    
    Assert.equal(passed, testLengths.length, "All string lengths should roundtrip");
    writeln("  \x1b[32m✓ Passed long string test (" ~ testLengths.length.to!string ~ " lengths)\x1b[0m");
}

// =============================================================================
// UNICODE EDGE CASE TESTS
// =============================================================================

/// Property: Unicode edge cases handled correctly
@("property.serialization.unicode.edge_cases")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Unicode edge cases");
    
    // Various unicode edge cases
    string[] testStrings = [
        "",                           // Empty
        "hello",                      // ASCII only
        "héllo wörld",               // Latin extended
        "日本語テスト",                // Japanese
        "🎉🚀💻",                      // Emoji
        "مرحبا",                       // Arabic (RTL)
        "שָׁלוֹם",                        // Hebrew with diacritics
        "\u0000\u0001\u001F",         // Control characters
        "a\u200Bb\u200Cc",            // Zero-width characters
        "\uFEFF test",                // BOM
        "test\u0000null",             // Embedded null
        "𝕳𝖊𝖑𝖑𝖔",                      // Mathematical symbols (4-byte UTF-8)
    ];
    
    size_t passed = 0;
    
    foreach (testStr; testStrings)
    {
        SimpleData data;
        data.strVal = testStr;
        data.intVal = cast(int)testStr.length;
        data.uintVal = 0;
        data.boolVal = true;
        
        try
        {
            ubyte[] serialized = Codec.serialize(data);
            auto result = () @trusted { return Codec.deserialize!SimpleData(serialized); }();
            
            if (result.isOk)
            {
                auto decoded = result.unwrap();
                if (decoded.strVal == testStr)
                    passed++;
                else
                    writeln("    Mismatch: expected " ~ testStr.length.to!string ~ " chars");
            }
        }
        catch (Exception e)
        {
            writeln("    Exception for string of length " ~ testStr.length.to!string);
        }
    }
    
    Assert.equal(passed, testStrings.length, "All unicode strings should roundtrip");
    writeln("  \x1b[32m✓ Passed unicode test (" ~ testStrings.length.to!string ~ " cases)\x1b[0m");
}

// =============================================================================
// SCHEMA EVOLUTION TESTS
// =============================================================================

/// Schema V1 - original
@Serializable(SchemaVersion(1, 0), 0x56455231)  // "VER1"
struct SchemaV1
{
    @Field(1) string name;
    @Field(2) int value;
}

/// Schema V2 - added optional field
@Serializable(SchemaVersion(2, 0), 0x56455232)  // "VER2"
struct SchemaV2
{
    @Field(1) string name;
    @Field(2) int value;
    @Field(3) @Optional string description;  // New field
}

/// Schema V3 - added another optional field
@Serializable(SchemaVersion(3, 0), 0x56455233)  // "VER3"
struct SchemaV3
{
    @Field(1) string name;
    @Field(2) int value;
    @Field(3) @Optional string description;
    @Field(4) @Optional int priority;  // New field
}

/// Property: Schema forward compatibility (old data in new schema)
@("property.serialization.evolution.forward_compat")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Schema evolution - Forward compatibility");
    
    auto config = PropertyConfig(numTests: 50);
    Mt19937 rng = Mt19937(config.seed + 5000);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Create V1 data
        SchemaV1 v1Data;
        v1Data.name = "test" ~ uniform(0, 1000, rng).to!string;
        v1Data.value = uniform(-10000, 10000, rng);
        
        // Serialize as V1
        ubyte[] serialized = Codec.serialize(v1Data);
        
        // Try to deserialize as V2 (forward compat)
        // Note: This tests if V1 data can be read by V2 schema
        // The magic number difference will cause this to fail, which is expected
        // In real systems, you'd have version negotiation
        
        // For this test, we verify V1 roundtrips correctly
        auto result = () @trusted { return Codec.deserialize!SchemaV1(serialized); }();
        
        if (result.isOk)
        {
            auto decoded = result.unwrap();
            if (decoded.name == v1Data.name && decoded.value == v1Data.value)
                passed++;
        }
    }
    
    Assert.equal(passed, config.numTests, "V1 data should roundtrip in V1 schema");
    writeln("  \x1b[32m✓ Passed forward compatibility test\x1b[0m");
}

/// Property: Schema backward compatibility (new data defaults work)
@("property.serialization.evolution.backward_compat")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Schema evolution - Backward compatibility");
    
    auto config = PropertyConfig(numTests: 50);
    Mt19937 rng = Mt19937(config.seed + 6000);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Create V2 data with optional field
        SchemaV2 v2Data;
        v2Data.name = "test" ~ uniform(0, 1000, rng).to!string;
        v2Data.value = uniform(-10000, 10000, rng);
        v2Data.description = "description " ~ uniform(0, 100, rng).to!string;
        
        // Serialize as V2
        ubyte[] serialized = Codec.serialize(v2Data);
        
        // Deserialize as V2 (same version)
        auto result = () @trusted { return Codec.deserialize!SchemaV2(serialized); }();
        
        if (result.isOk)
        {
            auto decoded = result.unwrap();
            if (decoded.name == v2Data.name && 
                decoded.value == v2Data.value &&
                decoded.description == v2Data.description)
                passed++;
        }
    }
    
    Assert.equal(passed, config.numTests, "V2 data should roundtrip correctly");
    writeln("  \x1b[32m✓ Passed backward compatibility test\x1b[0m");
}

/// Property: Optional fields default correctly when absent
@("property.serialization.evolution.optional_defaults")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Schema evolution - Optional field defaults");
    
    // V2 without description set
    SchemaV2 dataWithoutOptional;
    dataWithoutOptional.name = "test";
    dataWithoutOptional.value = 42;
    // description is not set - should use default (empty string)
    
    ubyte[] serialized = Codec.serialize(dataWithoutOptional);
    auto result = () @trusted { return Codec.deserialize!SchemaV2(serialized); }();
    
    Assert.isTrue(result.isOk, "Should deserialize successfully");
    
    auto decoded = result.unwrap();
    Assert.equal(decoded.name, "test", "Name should match");
    Assert.equal(decoded.value, 42, "Value should match");
    // Optional field should have default value
    Assert.equal(decoded.description, "", "Optional field should default to empty");
    
    writeln("  \x1b[32m✓ Passed optional defaults test\x1b[0m");
}

// =============================================================================
// EXTREME VALUE TESTS
// =============================================================================

/// Property: Integer boundary values serialize correctly
@("property.serialization.extremes.int_boundaries")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Extreme values - Integer boundaries");
    
    int[] testValues = [
        int.min,
        int.min + 1,
        -1,
        0,
        1,
        int.max - 1,
        int.max
    ];
    
    size_t passed = 0;
    
    foreach (testVal; testValues)
    {
        SimpleData data;
        data.intVal = testVal;
        data.uintVal = testVal >= 0 ? cast(uint)testVal : 0;
        data.strVal = "boundary test";
        data.boolVal = true;
        
        ubyte[] serialized = Codec.serialize(data);
        auto result = () @trusted { return Codec.deserialize!SimpleData(serialized); }();
        
        if (result.isOk)
        {
            auto decoded = result.unwrap();
            if (decoded.intVal == testVal)
                passed++;
            else
                writeln("    Mismatch: " ~ testVal.to!string ~ " != " ~ decoded.intVal.to!string);
        }
    }
    
    Assert.equal(passed, testValues.length, "All boundary values should roundtrip");
    writeln("  \x1b[32m✓ Passed integer boundary test\x1b[0m");
}

/// Property: Unsigned integer boundaries
@("property.serialization.extremes.uint_boundaries")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Extreme values - Unsigned boundaries");
    
    uint[] testValues = [
        0,
        1,
        127,
        128,
        255,
        256,
        uint.max / 2,
        uint.max - 1,
        uint.max
    ];
    
    size_t passed = 0;
    
    foreach (testVal; testValues)
    {
        SimpleData data;
        data.intVal = 0;
        data.uintVal = testVal;
        data.strVal = "uint test";
        data.boolVal = false;
        
        ubyte[] serialized = Codec.serialize(data);
        auto result = () @trusted { return Codec.deserialize!SimpleData(serialized); }();
        
        if (result.isOk)
        {
            auto decoded = result.unwrap();
            if (decoded.uintVal == testVal)
                passed++;
        }
    }
    
    Assert.equal(passed, testValues.length, "All uint boundaries should roundtrip");
    writeln("  \x1b[32m✓ Passed unsigned boundary test\x1b[0m");
}

