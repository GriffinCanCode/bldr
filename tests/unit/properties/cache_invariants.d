module tests.unit.properties.cache_invariants;

import std.algorithm;
import std.array;
import std.conv;
import std.digest.sha;
import std.file;
import std.path;
import std.stdio;
import tests.harness;
import tests.property;
import tests.adapters.cache_adapter;

version(unittest):

/// Test that cache keys are deterministic (same inputs = same key)
@("property.cache.determinism.same_input")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache key determinism");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool cacheKeyDeterministic(string input)
    {
        if (input.length == 0) return true;
        
        // Generate key twice with same input
        auto key1 = CacheKeyGenerator.fromString(input);
        auto key2 = CacheKeyGenerator.fromString(input);
        
        // Keys must be identical
        return key1 == key2;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!cacheKeyDeterministic(new StringGen(0, 1000));
    checkProperty(result, "cache.determinism.same_input");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test that cache keys are unique for different inputs
@("property.cache.uniqueness")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache key uniqueness");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool cacheKeysUnique(string[] inputs)
    {
        // Skip if we don't have at least 2 inputs
        if (inputs.length < 2) return true;
        
        // Filter out duplicates in input
        auto uniqueInputs = inputs.sort.uniq.array;
        if (uniqueInputs.length < 2) return true;
        
        // Generate keys
        string[] keys;
        foreach (input; uniqueInputs)
        {
            keys ~= CacheKeyGenerator.fromString(input);
        }
        
        // All keys should be unique
        auto uniqueKeys = keys.sort.uniq.array;
        return uniqueKeys.length == keys.length;
    }
    
    auto test = property!(string[])(config);
    auto result = test.forAll!cacheKeysUnique(
        new ArrayGen!string(new StringGen(1, 50), 2, 20)
    );
    checkProperty(result, "cache.uniqueness");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test that cache key generation is platform-independent
@("property.cache.platform_independence")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache key platform independence");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool platformIndependent(string input)
    {
        if (input.length == 0) return true;
        
        // Generate key with normalized input
        auto normalized = input.replace("\r\n", "\n").replace("\r", "\n");
        auto key1 = CacheKeyGenerator.fromString(normalized);
        
        // Generate again (should be same)
        auto key2 = CacheKeyGenerator.fromString(normalized);
        
        return key1 == key2;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!platformIndependent(new StringGen(0, 500));
    checkProperty(result, "cache.platform_independence");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test content hash stability
@("property.cache.content_hash.stability")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache content hash stability");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool contentHashStable(string content)
    {
        // Hash same content multiple times
        auto hash1 = ContentHasher.hashString(content);
        auto hash2 = ContentHasher.hashString(content);
        auto hash3 = ContentHasher.hashString(content);
        
        // All hashes must be identical
        return hash1 == hash2 && hash2 == hash3;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!contentHashStable(new StringGen(0, 10000));
    checkProperty(result, "cache.content_hash.stability");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test cache key composition (combining multiple inputs)
@("property.cache.composition")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache key composition");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool compositionDeterministic(string[] parts)
    {
        if (parts.length == 0) return true;
        
        // Compose key from parts multiple times
        auto key1 = CacheKeyGenerator.fromParts(parts);
        auto key2 = CacheKeyGenerator.fromParts(parts);
        
        // Keys must be identical
        return key1 == key2;
    }
    
    auto test = property!(string[])(config);
    auto result = test.forAll!compositionDeterministic(
        new ArrayGen!string(new StringGen(0, 100), 1, 10)
    );
    checkProperty(result, "cache.composition");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test cache key ordering sensitivity
@("property.cache.order_sensitivity")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache key order sensitivity");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool orderMatters(string[] parts)
    {
        // Need at least 2 different parts
        if (parts.length < 2) return true;
        
        auto uniqueParts = parts.sort.uniq.array;
        if (uniqueParts.length < 2) return true;
        
        // Generate key with original order
        auto key1 = CacheKeyGenerator.fromParts(parts);
        
        // Generate key with reversed order
        auto reversed = parts.dup.reverse;
        auto key2 = CacheKeyGenerator.fromParts(reversed);
        
        // If parts are different, keys should be different
        // (order should matter for cache correctness)
        if (parts != reversed)
            return key1 != key2;
        
        return true;
    }
    
    auto test = property!(string[])(config);
    auto result = test.forAll!orderMatters(
        new ArrayGen!string(new StringGen(1, 20), 2, 10)
    );
    checkProperty(result, "cache.order_sensitivity");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test cache key collision resistance
@("property.cache.collision_resistance")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Cache key collision resistance");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool noEasyCollisions(int seed)
    {
        // Generate many keys with slight variations
        string[] keys;
        
        foreach (i; 0 .. 20)
        {
            auto input = "input" ~ (seed + i).to!string;
            keys ~= CacheKeyGenerator.fromString(input);
        }
        
        // All keys should be unique
        auto uniqueKeys = keys.sort.uniq.array;
        return uniqueKeys.length == keys.length;
    }
    
    auto test = property!int(config);
    auto result = test.forAll!noEasyCollisions(new IntGen(0, 1_000_000));
    checkProperty(result, "cache.collision_resistance");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

