module tests.unit.properties.path_invariants;

import std.algorithm;
import std.array;
import std.conv;
import std.path;
import std.stdio;
import std.string;
import tests.harness;
import tests.property;
import tests.adapters.path_adapter;

version(unittest):

/// Test that path canonicalization is idempotent
@("property.path.canonicalization.idempotence")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path canonicalization idempotence");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool canonicalizationIdempotent(string path)
    {
        if (path.length == 0) return true;
        
        // Canonicalize once
        auto canonical1 = PathOps.canonicalize(path);
        
        // Canonicalize again
        auto canonical2 = PathOps.canonicalize(canonical1);
        
        // Should be the same
        return canonical1 == canonical2;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!canonicalizationIdempotent(new PathGen(1, 10));
    checkProperty(result, "path.canonicalization.idempotence");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test that path normalization removes redundant separators
@("property.path.normalization.separators")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path normalization removes redundant separators");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool noRedundantSeparators(string path)
    {
        if (path.length == 0) return true;
        
        auto normalized = PathOps.normalize(path);
        
        // Should not contain //
        return !normalized.canFind("//");
    }
    
    auto test = property!string(config);
    auto result = test.forAll!noRedundantSeparators(new PathGen(1, 10));
    checkProperty(result, "path.normalization.separators");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test path resolution is deterministic
@("property.path.resolution.determinism")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path resolution determinism");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool resolutionDeterministic(string path)
    {
        if (path.length == 0) return true;
        
        // Resolve path multiple times
        auto resolved1 = PathOps.resolve(path);
        auto resolved2 = PathOps.resolve(path);
        
        // Should always get same result
        return resolved1 == resolved2;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!resolutionDeterministic(new PathGen(1, 8));
    checkProperty(result, "path.resolution.determinism");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test relative path computation is inverse of joining
@("property.path.relative.inverse")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path relative computation inverse property");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool relativeIsInverse(string base, string target)
    {
        if (base.length == 0 || target.length == 0) return true;
        
        // Make absolute paths
        base = "/" ~ base;
        target = "/" ~ target;
        
        // Compute relative path from base to target
        auto rel = PathOps.relativePath(target, base);
        
        // Join base with relative path
        auto reconstructed = PathOps.normalize(buildPath(base, rel));
        auto normalizedTarget = PathOps.normalize(target);
        
        // Should get back to target
        return reconstructed == normalizedTarget;
    }
    
    auto test = property!(string, string)(config);
    auto pathGen = new PathGen(1, 5);
    
    // Note: This is a simplified test - full implementation would need composite generator
    // For now, test with generated paths
    static bool testFn(string path) {
        return relativeIsInverse(path, path ~ "/subdir");
    }
    
    auto simpleTest = property!string(config);
    auto result = simpleTest.forAll!testFn(pathGen);
    checkProperty(result, "path.relative.inverse");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test path joining associativity
@("property.path.join.associative")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path join associativity");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool joinAssociative(string[] parts)
    {
        if (parts.length < 3) return true;
        
        // Test: (a / b) / c == a / (b / c)
        auto a = parts[0].length > 0 ? parts[0] : "a";
        auto b = parts[1].length > 0 ? parts[1] : "b";
        auto c = parts[2].length > 0 ? parts[2] : "c";
        
        auto left = PathOps.normalize(buildPath(buildPath(a, b), c));
        auto right = PathOps.normalize(buildPath(a, buildPath(b, c)));
        
        return left == right;
    }
    
    auto test = property!(string[])(config);
    auto result = test.forAll!joinAssociative(
        new ArrayGen!string(new StringGen(1, 20), 3, 3)
    );
    checkProperty(result, "path.join.associative");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test path component extraction consistency
@("property.path.components.consistency")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path component extraction consistency");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool componentsConsistent(string path)
    {
        if (path.length == 0) return true;
        
        // Extract components
        auto components = PathOps.components(path);
        
        // Rejoin components
        string rejoined;
        foreach (i, comp; components)
        {
            if (i == 0)
                rejoined = comp;
            else
                rejoined = buildPath(rejoined, comp);
        }
        
        // Normalize both
        auto normalizedOriginal = PathOps.normalize(path);
        auto normalizedRejoined = PathOps.normalize(rejoined);
        
        // Should be equivalent
        return normalizedOriginal == normalizedRejoined;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!componentsConsistent(new PathGen(1, 8));
    checkProperty(result, "path.components.consistency");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test that normalization preserves absolute/relative nature
@("property.path.normalization.preserves_type")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path normalization preserves absolute/relative");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool preservesType(string path)
    {
        if (path.length == 0) return true;
        
        auto wasAbsolute = isAbsolute(path);
        auto normalized = PathOps.normalize(path);
        auto isStillAbsolute = isAbsolute(normalized);
        
        // Absolute paths stay absolute, relative stay relative
        return wasAbsolute == isStillAbsolute;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!preservesType(new PathGen(1, 10));
    checkProperty(result, "path.normalization.preserves_type");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test path comparison normalization
@("property.path.comparison.normalized")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path comparison normalization");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool comparisonConsistent(string path)
    {
        if (path.length == 0) return true;
        
        // Create equivalent paths with different formatting
        auto path1 = path;
        auto path2 = path.replace("/", "//");  // Add redundant separators
        
        // Normalized comparison should see them as equal
        auto norm1 = PathOps.normalize(path1);
        auto norm2 = PathOps.normalize(path2);
        
        return norm1 == norm2;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!comparisonConsistent(new PathGen(2, 8));
    checkProperty(result, "path.comparison.normalized");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Test path containment transitivity
@("property.path.containment.transitive")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m Path containment transitivity");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool containmentTransitive(string base)
    {
        if (base.length == 0) base = "/base";
        
        // Create nested paths: base ⊃ middle ⊃ inner
        auto middle = buildPath(base, "middle");
        auto inner = buildPath(middle, "inner");
        
        // Test transitivity: if base contains middle and middle contains inner,
        // then base contains inner
        bool baseContainsMiddle = PathOps.contains(base, middle);
        bool middleContainsInner = PathOps.contains(middle, inner);
        bool baseContainsInner = PathOps.contains(base, inner);
        
        // If first two are true, third must be true
        if (baseContainsMiddle && middleContainsInner)
            return baseContainsInner;
        
        return true;
    }
    
    auto test = property!string(config);
    auto result = test.forAll!containmentTransitive(new PathGen(1, 5));
    checkProperty(result, "path.containment.transitive");
    
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

