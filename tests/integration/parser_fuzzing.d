module tests.integration.parser_fuzzing;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.string;
import tests.harness;
import tests.fixtures;
import infrastructure.config.parsing.parser;
import infrastructure.config.analysis.semantic;
import infrastructure.config.schema.schema;
import infrastructure.errors;

/// Fuzzer for DSL parser
class DSLFuzzer
{
    private Mt19937 rng;
    private string[] validFieldNames = ["sources", "deps", "type", "language", "output"];
    private string[] validTypes = ["executable", "library", "test"];
    private string[] validLanguages = ["python", "javascript", "typescript", "go", "rust", "d"];
    
    this(uint seed = unpredictableSeed)
    {
        rng.seed(seed);
    }
    
    /// Generate random valid DSL
    string generateValidDSL()
    {
        string dsl = "target(\"" ~ randomString(5, 15) ~ "\") {\n";
        
        // Add type
        dsl ~= "    type: " ~ validTypes[uniform(0, validTypes.length, rng)] ~ ";\n";
        
        // Add language
        if (uniform(0, 2, rng) == 0)
        {
            dsl ~= "    language: " ~ validLanguages[uniform(0, validLanguages.length, rng)] ~ ";\n";
        }
        
        // Add sources
        auto sourceCount = uniform(1, 5, rng);
        dsl ~= "    sources: [";
        foreach (i; 0 .. sourceCount)
        {
            if (i > 0) dsl ~= ", ";
            dsl ~= "\"" ~ randomString(3, 10) ~ ".py\"";
        }
        dsl ~= "];\n";
        
        // Add deps (sometimes)
        if (uniform(0, 3, rng) == 0)
        {
            auto depCount = uniform(1, 3, rng);
            dsl ~= "    deps: [";
            foreach (i; 0 .. depCount)
            {
                if (i > 0) dsl ~= ", ";
                dsl ~= "\"dep" ~ i.to!string ~ "\"";
            }
            dsl ~= "];\n";
        }
        
        dsl ~= "}\n";
        return dsl;
    }
    
    /// Generate malformed DSL (syntax errors)
    string generateMalformedDSL()
    {
        auto choice = uniform(0, 10, rng);
        
        switch (choice)
        {
            case 0: // Missing closing brace
                return "target(\"test\") {\n    type: executable;\n";
            
            case 1: // Missing semicolon
                return "target(\"test\") {\n    type: executable\n}\n";
            
            case 2: // Invalid field name
                return "target(\"test\") {\n    invalid_field: value;\n}\n";
            
            case 3: // Unterminated string
                return "target(\"test\") {\n    sources: [\"file.py];\n}\n";
            
            case 4: // Missing colon
                return "target(\"test\") {\n    type executable;\n}\n";
            
            case 5: // Empty target name
                return "target(\"\") {\n    type: executable;\n}\n";
            
            case 6: // Invalid array syntax
                return "target(\"test\") {\n    sources: \"file.py\";\n}\n";
            
            case 7: // Duplicate fields
                return "target(\"test\") {\n    type: executable;\n    type: library;\n}\n";
            
            case 8: // Missing required fields
                return "target(\"test\") {\n}\n";
            
            case 9: // Invalid type value
                return "target(\"test\") {\n    type: invalid_type;\n}\n";
            
            default:
                return "invalid syntax {{{";
        }
    }
    
    /// Generate edge case DSL
    string generateEdgeCaseDSL()
    {
        auto choice = uniform(0, 8, rng);
        
        switch (choice)
        {
            case 0: // Very long target name
                return "target(\"" ~ randomString(100, 200) ~ "\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
            
            case 1: // Very long field values
                string longPath = "";
                foreach (i; 0 .. 50)
                    longPath ~= "very/long/path/";
                return "target(\"test\") {\n    type: executable;\n    sources: [\"" ~ longPath ~ "file.py\"];\n}\n";
            
            case 2: // Many sources
                string dsl = "target(\"test\") {\n    type: executable;\n    sources: [";
                foreach (i; 0 .. 100)
                {
                    if (i > 0) dsl ~= ", ";
                    dsl ~= "\"file" ~ i.to!string ~ ".py\"";
                }
                dsl ~= "];\n}\n";
                return dsl;
            
            case 3: // Many deps
                string dsl2 = "target(\"test\") {\n    type: executable;\n    sources: [\"main.py\"];\n    deps: [";
                foreach (i; 0 .. 100)
                {
                    if (i > 0) dsl2 ~= ", ";
                    dsl2 ~= "\"dep" ~ i.to!string ~ "\"";
                }
                dsl2 ~= "];\n}\n";
                return dsl2;
            
            case 4: // Unicode in names
                return "target(\"测试\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
            
            case 5: // Special characters
                return "target(\"test-name_123\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
            
            case 6: // Whitespace variations
                return "target(  \"test\"  )  {\ntype:executable;sources:[\"main.py\"];\n}\n";
            
            case 7: // Empty arrays
                return "target(\"test\") {\n    type: executable;\n    sources: [];\n    deps: [];\n}\n";
            
            default:
                return "target(\"test\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
        }
    }
    
    /// Generate potentially malicious DSL
    string generateMaliciousDSL()
    {
        auto choice = uniform(0, 8, rng);
        
        switch (choice)
        {
            case 0: // Path traversal attempt
                return "target(\"test\") {\n    type: executable;\n    sources: [\"../../../etc/passwd\"];\n}\n";
            
            case 1: // Absolute path injection
                return "target(\"test\") {\n    type: executable;\n    sources: [\"/etc/shadow\"];\n}\n";
            
            case 2: // Command injection attempt
                return "target(\"test; rm -rf /\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
            
            case 3: // Null bytes
                return "target(\"test\\0malicious\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
            
            case 4: // Very deep nesting
                string deep = "target(\"test\") {\n    sources: [";
                foreach (i; 0 .. 100)
                    deep ~= "[";
                deep ~= "\"file.py\"";
                foreach (i; 0 .. 100)
                    deep ~= "]";
                deep ~= "];\n}\n";
                return deep;
            
            case 5: // Code injection in strings
                return "target(\"test\") {\n    type: executable;\n    sources: [\"\"; DROP TABLE targets; --\"];\n}\n";
            
            case 6: // Symlink path
                return "target(\"test\") {\n    type: executable;\n    sources: [\"../../../../tmp/evil.py\"];\n}\n";
            
            case 7: // Buffer overflow attempt
                string huge = "target(\"";
                foreach (i; 0 .. 10_000)
                    huge ~= "A";
                huge ~= "\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
                return huge;
            
            default:
                return "target(\"test\") {\n    type: executable;\n    sources: [\"main.py\"];\n}\n";
        }
    }
    
    private string randomString(size_t minLen, size_t maxLen)
    {
        auto len = uniform(minLen, maxLen + 1, rng);
        auto chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_";
        string result;
        foreach (i; 0 .. len)
        {
            result ~= chars[uniform(0, chars.length, rng)];
        }
        return result;
    }
}

// ============================================================================
// FUZZING TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m parser_fuzzing - Valid DSL fuzzing (1000 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-valid"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new DSLFuzzer();
    size_t successCount = 0;
    size_t totalIterations = 1000;
    
    foreach (i; 0 .. totalIterations)
    {
        auto dsl = fuzzer.generateValidDSL();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        std.file.write(buildfilePath, dsl);
        
        try
        {
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            if (result.isOk)
            {
                successCount++;
            }
        }
        catch (Exception e)
        {
            // Some valid DSL might still fail due to missing files, etc.
        }
        
        if ((i + 1) % 100 == 0)
        {
            writeln("    Tested ", i + 1, " valid inputs, ", successCount, " parsed successfully");
        }
    }
    
    auto successRate = (successCount * 100.0) / totalIterations;
    writeln("  Success rate: ", successRate, "%");
    
    Assert.isTrue(successRate >= 80.0, "At least 80% of valid inputs should parse");
    
    writeln("\x1b[32m  ✓ Valid DSL fuzzing passed\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m parser_fuzzing - Malformed DSL fuzzing (500 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-malformed"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new DSLFuzzer();
    size_t crashCount = 0;
    size_t totalIterations = 500;
    
    foreach (i; 0 .. totalIterations)
    {
        auto dsl = fuzzer.generateMalformedDSL();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        std.file.write(buildfilePath, dsl);
        
        try
        {
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            // Should either return error or throw exception, not crash
        }
        catch (Error e)
        {
            // Error (not Exception) indicates a crash/assertion failure
            crashCount++;
            writeln("    CRASH on input: ", dsl[0 .. min(50, dsl.length)]);
        }
        catch (Exception e)
        {
            // Exception is fine - parser rejected invalid input
        }
        
        if ((i + 1) % 100 == 0)
        {
            writeln("    Tested ", i + 1, " malformed inputs, ", crashCount, " crashes");
        }
    }
    
    writeln("  Total crashes: ", crashCount);
    Assert.equal(crashCount, 0, "Parser should not crash on malformed input");
    
    writeln("\x1b[32m  ✓ Malformed DSL fuzzing passed (no crashes)\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m parser_fuzzing - Edge case DSL fuzzing (500 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-edge"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new DSLFuzzer();
    size_t crashCount = 0;
    size_t totalIterations = 500;
    
    foreach (i; 0 .. totalIterations)
    {
        auto dsl = fuzzer.generateEdgeCaseDSL();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            // Edge cases should either parse or fail gracefully
        }
        catch (Error e)
        {
            crashCount++;
            writeln("    CRASH on edge case");
        }
        catch (Exception e)
        {
            // Expected for some edge cases
        }
        
        if ((i + 1) % 100 == 0)
        {
            writeln("    Tested ", i + 1, " edge cases, ", crashCount, " crashes");
        }
    }
    
    writeln("  Total crashes: ", crashCount);
    Assert.equal(crashCount, 0, "Parser should handle edge cases without crashing");
    
    writeln("\x1b[32m  ✓ Edge case DSL fuzzing passed\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m parser_fuzzing - Security fuzzing (malicious inputs)");
    
    auto tempDir = scoped(new TempDir("fuzz-security"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new DSLFuzzer();
    size_t securityBypassCount = 0;
    size_t crashCount = 0;
    size_t totalIterations = 200;
    
    foreach (i; 0 .. totalIterations)
    {
        auto dsl = fuzzer.generateMaliciousDSL();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            
            if (result.isOk)
            {
                auto targets = result.unwrap();
                // Check if malicious paths were allowed
                foreach (target; targets.targets)
                {
                    foreach (source; target.sources)
                    {
                        // Check for path traversal
                        if (source.canFind("..") || source.canFind("/etc/") || 
                            source.startsWith("/"))
                        {
                            securityBypassCount++;
                            writeln("    SECURITY BYPASS: ", source);
                        }
                    }
                }
            }
        }
        catch (Error e)
        {
            crashCount++;
        }
        catch (Exception e)
        {
            // Expected - parser should reject malicious input
        }
        
        if ((i + 1) % 50 == 0)
        {
            writeln("    Tested ", i + 1, " malicious inputs");
        }
    }
    
    writeln("  Security bypasses: ", securityBypassCount);
    writeln("  Crashes: ", crashCount);
    
    Assert.equal(crashCount, 0, "Parser should not crash on malicious input");
    Assert.isTrue(securityBypassCount < totalIterations * 0.1, 
                 "Parser should reject most malicious inputs");
    
    writeln("\x1b[32m  ✓ Security fuzzing passed\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m parser_fuzzing - Random byte fuzzing (100 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-random"));
    auto workspacePath = tempDir.getPath();
    
    auto rng = Random(unpredictableSeed);
    size_t crashCount = 0;
    size_t totalIterations = 100;
    
    foreach (i; 0 .. totalIterations)
    {
        // Generate random bytes
        auto len = uniform(10, 1000, rng);
        ubyte[] randomBytes;
        foreach (j; 0 .. len)
        {
            randomBytes ~= cast(ubyte)uniform(0, 256, rng);
        }
        
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, randomBytes);
            auto dsl = cast(string)randomBytes;
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            // Random bytes should almost never parse, but shouldn't crash
        }
        catch (Error e)
        {
            crashCount++;
        }
        catch (Exception e)
        {
            // Expected - random bytes are invalid
        }
        
        if ((i + 1) % 20 == 0)
        {
            writeln("    Tested ", i + 1, " random inputs, ", crashCount, " crashes");
        }
    }
    
    writeln("  Total crashes: ", crashCount);
    Assert.equal(crashCount, 0, "Parser should not crash on random bytes");
    
    writeln("\x1b[32m  ✓ Random byte fuzzing passed\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m parser_fuzzing - Mutation-based fuzzing");
    
    auto tempDir = scoped(new TempDir("fuzz-mutation"));
    auto workspacePath = tempDir.getPath();
    
    // Start with valid DSL
    string baseDSL = `target("test") {
    type: executable;
    language: python;
    sources: ["main.py", "utils.py"];
    deps: ["lib1", "lib2"];
}`;
    
    auto rng = Random(unpredictableSeed);
    size_t crashCount = 0;
    size_t totalIterations = 500;
    
    foreach (i; 0 .. totalIterations)
    {
        // Mutate the DSL
        string mutated = baseDSL.dup;
        auto mutationCount = uniform(1, 5, rng);
        
        foreach (m; 0 .. mutationCount)
        {
            auto mutationType = uniform(0, 4, rng);
            auto pos = uniform(0, mutated.length, rng);
            
            switch (mutationType)
            {
                case 0: // Delete character
                    if (pos < mutated.length)
                        mutated = mutated[0 .. pos] ~ mutated[min(pos + 1, mutated.length) .. $];
                    break;
                
                case 1: // Insert character
                    char c = cast(char)uniform(32, 127, rng);
                    mutated = mutated[0 .. pos] ~ c ~ mutated[pos .. $];
                    break;
                
                case 2: // Replace character
                    if (pos < mutated.length)
                    {
                        char c = cast(char)uniform(32, 127, rng);
                        mutated = mutated[0 .. pos] ~ c ~ mutated[min(pos + 1, mutated.length) .. $];
                    }
                    break;
                
                case 3: // Duplicate chunk
                    auto len = uniform(1, 10, rng);
                    if (pos + len < mutated.length)
                    {
                        auto chunk = mutated[pos .. pos + len];
                        mutated = mutated[0 .. pos] ~ chunk ~ chunk ~ mutated[pos + len .. $];
                    }
                    break;
                
                default:
                    break;
            }
        }
        
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, mutated);
            auto result = parseDSL(mutated, buildfilePath, workspacePath);
        }
        catch (Error e)
        {
            crashCount++;
        }
        catch (Exception e)
        {
            // Expected for mutated input
        }
        
        if ((i + 1) % 100 == 0)
        {
            writeln("    Tested ", i + 1, " mutations, ", crashCount, " crashes");
        }
    }
    
    writeln("  Total crashes: ", crashCount);
    Assert.equal(crashCount, 0, "Parser should not crash on mutated input");
    
    writeln("\x1b[32m  ✓ Mutation-based fuzzing passed\x1b[0m");
}

