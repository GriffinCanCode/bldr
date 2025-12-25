module tests.integration.extended_fuzzing;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.string;
import std.range : iota;
import std.datetime : Duration, seconds, msecs, MonoTime;
import core.thread;
import core.atomic;
import core.memory : GC;

import tests.harness;
import tests.fixtures;
import infrastructure.config.parsing.parser;
import infrastructure.config.parsing.lexer;
import infrastructure.config.analysis.semantic;
import infrastructure.errors;

// =============================================================================
// EXTENDED FUZZING INFRASTRUCTURE
// =============================================================================

/// Grammar-aware fuzzer that generates structurally valid but semantically varied DSL
class GrammarAwareFuzzer
{
    private Mt19937 rng;
    private immutable string[] keywords = ["target", "let", "if", "else", "for", "in", "import", "export"];
    private immutable string[] operators = ["=", "==", "!=", "<", ">", "<=", ">=", "+", "-", "*", "/", "&&", "||"];
    private immutable string[] targetTypes = ["executable", "library", "test", "plugin", "proto_library"];
    
    this(uint seed = unpredictableSeed) { rng.seed(seed); }
    
    /// Generate valid target with all field combinations
    string generateCompleteTarget()
    {
        auto name = randomIdentifier(5, 20);
        string dsl = "target(\"" ~ name ~ "\") {\n";
        
        // Required fields
        dsl ~= "    type: " ~ targetTypes[uniform(0, targetTypes.length, rng)] ~ ";\n";
        dsl ~= "    sources: " ~ generateSourceArray() ~ ";\n";
        
        // Optional fields (randomly include)
        if (uniform(0, 2, rng) == 0)
            dsl ~= "    deps: " ~ generateDepsArray() ~ ";\n";
        
        if (uniform(0, 3, rng) == 0)
            dsl ~= "    language: " ~ generateLanguage() ~ ";\n";
        
        if (uniform(0, 3, rng) == 0)
            dsl ~= "    output: \"build/" ~ name ~ "\";\n";
        
        if (uniform(0, 4, rng) == 0)
            dsl ~= "    visibility: [\"//...\"];\n";
        
        if (uniform(0, 4, rng) == 0)
            dsl ~= "    compiler_flags: " ~ generateFlagsArray() ~ ";\n";
        
        dsl ~= "}\n";
        return dsl;
    }
    
    /// Generate multiple targets with dependencies
    string generateProjectDSL()
    {
        auto targetCount = uniform(3, 10, rng);
        string[] targetNames;
        string dsl;
        
        foreach (i; 0 .. targetCount)
        {
            auto name = randomIdentifier(5, 15) ~ "_" ~ i.to!string;
            targetNames ~= name;
            
            dsl ~= "target(\"" ~ name ~ "\") {\n";
            dsl ~= "    type: " ~ targetTypes[uniform(0, targetTypes.length, rng)] ~ ";\n";
            dsl ~= "    sources: [\"src/" ~ name ~ ".d\"];\n";
            
            // Add deps on earlier targets
            if (i > 0 && uniform(0, 2, rng) == 0)
            {
                auto depCount = uniform(1, min(3, i + 1), rng);
                string[] deps;
                foreach (d; 0 .. depCount)
                {
                    auto depIdx = uniform(0, i, rng);
                    deps ~= "\"" ~ targetNames[depIdx] ~ "\"";
                }
                dsl ~= "    deps: [" ~ deps.join(", ") ~ "];\n";
            }
            
            dsl ~= "}\n\n";
        }
        
        return dsl;
    }
    
    /// Generate expression with nested operations
    string generateExpression(int depth = 0)
    {
        if (depth > 5)
            return generateLiteral();
        
        auto choice = uniform(0, 6, rng);
        
        switch (choice)
        {
            case 0: return generateLiteral();
            case 1: return "(" ~ generateExpression(depth + 1) ~ ")";
            case 2: return generateExpression(depth + 1) ~ " " ~ 
                          operators[uniform(0, operators.length, rng)] ~ " " ~ 
                          generateExpression(depth + 1);
            case 3: return "[" ~ generateExpressionList(depth + 1) ~ "]";
            case 4: return randomIdentifier(3, 10);
            default: return generateLiteral();
        }
    }
    
    /// Generate syntactically invalid DSL that should trigger specific parser errors
    string generateSyntaxError(int errorType)
    {
        switch (errorType % 15)
        {
            case 0:  // Unclosed brace
                return "target(\"test\") {\n    type: executable;\n";
            case 1:  // Unclosed string
                return "target(\"test\") {\n    sources: [\"unclosed];\n}\n";
            case 2:  // Invalid token sequence
                return "target target \"test\" { type = executable; }\n";
            case 3:  // Missing argument
                return "target() { type: executable; }\n";
            case 4:  // Extra tokens
                return "target(\"test\") extra { type: executable; }\n";
            case 5:  // Invalid identifier start
                return "target(\"123invalid\") { type: executable; }\n";
            case 6:  // Unbalanced brackets
                return "target(\"test\") { sources: [[\"a\", \"b\"]; }\n";
            case 7:  // Missing semicolon
                return "target(\"test\") { type: executable sources: [\"a.d\"]; }\n";
            case 8:  // Invalid field value type
                return "target(\"test\") { type: 123; }\n";
            case 9:  // Duplicate brace
                return "target(\"test\") {{ type: executable; }}\n";
            case 10: // Invalid escape sequence
                return "target(\"test\\q\") { type: executable; }\n";
            case 11: // Null character
                return "target(\"te\x00st\") { type: executable; }\n";
            case 12: // Control character
                return "target(\"test\x1F\") { type: executable; }\n";
            case 13: // Very long line
                return "target(\"" ~ repeat('x', 100_000).array.idup ~ "\") { type: executable; }\n";
            case 14: // Deeply nested
                string nested = "target(\"test\") { sources: ";
                foreach (i; 0 .. 100) nested ~= "[";
                nested ~= "\"a.d\"";
                foreach (i; 0 .. 100) nested ~= "]";
                nested ~= "; }\n";
                return nested;
            default:
                return "invalid";
        }
    }
    
    /// Generate semantically invalid but syntactically valid DSL
    string generateSemanticError(int errorType)
    {
        switch (errorType % 10)
        {
            case 0:  // Missing required field
                return "target(\"test\") { deps: [\"lib\"]; }\n";
            case 1:  // Invalid type value
                return "target(\"test\") { type: nonexistent_type; sources: [\"a.d\"]; }\n";
            case 2:  // Circular dependency hint
                return "target(\"a\") { type: library; sources: [\"a.d\"]; deps: [\"b\"]; }\n" ~
                       "target(\"b\") { type: library; sources: [\"b.d\"]; deps: [\"a\"]; }\n";
            case 3:  // Duplicate target name
                return "target(\"dup\") { type: library; sources: [\"a.d\"]; }\n" ~
                       "target(\"dup\") { type: library; sources: [\"b.d\"]; }\n";
            case 4:  // Invalid source extension
                return "target(\"test\") { type: executable; language: python; sources: [\"a.rs\"]; }\n";
            case 5:  // Empty sources for executable
                return "target(\"test\") { type: executable; sources: []; }\n";
            case 6:  // Self-dependency
                return "target(\"self\") { type: library; sources: [\"a.d\"]; deps: [\"self\"]; }\n";
            case 7:  // Invalid visibility pattern
                return "target(\"test\") { type: library; sources: [\"a.d\"]; visibility: [\"invalid\"]; }\n";
            case 8:  // Conflicting options
                return "target(\"test\") { type: test; type: library; sources: [\"a.d\"]; }\n";
            case 9:  // Reference to undefined target
                return "target(\"test\") { type: library; sources: [\"a.d\"]; deps: [\"nonexistent\"]; }\n";
            default:
                return "target(\"test\") { type: library; }\n";
        }
    }
    
    /// Generate DSL with unicode edge cases
    string generateUnicodeEdgeCase()
    {
        auto choice = uniform(0, 10, rng);
        
        switch (choice)
        {
            case 0:  // RTL characters
                return "target(\"مرحبا\") { type: library; sources: [\"a.d\"]; }\n";
            case 1:  // Emoji
                return "target(\"test🚀\") { type: library; sources: [\"🎉.d\"]; }\n";
            case 2:  // Zero-width characters
                return "target(\"te\u200Bst\") { type: library; sources: [\"a.d\"]; }\n";
            case 3:  // BOM
                return "\uFEFFtarget(\"test\") { type: library; sources: [\"a.d\"]; }\n";
            case 4:  // Combining characters
                return "target(\"café\") { type: library; sources: [\"a.d\"]; }\n";
            case 5:  // CJK
                return "target(\"测试\") { type: library; sources: [\"日本語.d\"]; }\n";
            case 6:  // Surrogate pair
                return "target(\"test𝕳𝖊𝖑𝖑𝖔\") { type: library; sources: [\"a.d\"]; }\n";
            case 7:  // Mixed scripts
                return "target(\"test_тест_测试\") { type: library; sources: [\"a.d\"]; }\n";
            case 8:  // Homoglyph attack
                return "target(\"tеst\") { type: library; sources: [\"a.d\"]; }\n";  // Cyrillic 'е'
            case 9:  // Unicode normalization forms
                return "target(\"e\u0301\") { type: library; sources: [\"a.d\"]; }\n";  // é as e + combining acute
            default:
                return "target(\"test\") { type: library; sources: [\"a.d\"]; }\n";
        }
    }

private:
    string randomIdentifier(size_t minLen, size_t maxLen)
    {
        auto len = uniform(minLen, maxLen + 1, rng);
        char[] result;
        result ~= cast(char)uniform('a', 'z' + 1, rng);  // First char must be letter
        foreach (i; 1 .. len)
        {
            auto choice = uniform(0, 63, rng);
            if (choice < 26) result ~= cast(char)('a' + choice);
            else if (choice < 52) result ~= cast(char)('A' + choice - 26);
            else if (choice < 62) result ~= cast(char)('0' + choice - 52);
            else result ~= '_';
        }
        return result.idup;
    }
    
    string generateSourceArray()
    {
        auto count = uniform(1, 5, rng);
        string[] sources;
        foreach (i; 0 .. count)
            sources ~= "\"src/" ~ randomIdentifier(3, 10) ~ ".d\"";
        return "[" ~ sources.join(", ") ~ "]";
    }
    
    string generateDepsArray()
    {
        auto count = uniform(1, 4, rng);
        string[] deps;
        foreach (i; 0 .. count)
            deps ~= "\"" ~ randomIdentifier(3, 10) ~ "\"";
        return "[" ~ deps.join(", ") ~ "]";
    }
    
    string generateFlagsArray()
    {
        string[] flags = ["\"-O2\"", "\"-Wall\"", "\"-g\"", "\"-fPIC\"", "\"-std=c++17\""];
        auto count = uniform(1, 4, rng);
        string[] selected;
        foreach (i; 0 .. count)
            selected ~= flags[uniform(0, flags.length, rng)];
        return "[" ~ selected.join(", ") ~ "]";
    }
    
    string generateLanguage()
    {
        string[] langs = ["d", "python", "javascript", "typescript", "go", "rust", "cpp", "java"];
        return langs[uniform(0, langs.length, rng)];
    }
    
    string generateLiteral()
    {
        auto choice = uniform(0, 4, rng);
        switch (choice)
        {
            case 0: return uniform(-1000, 1000, rng).to!string;
            case 1: return "\"" ~ randomIdentifier(5, 20) ~ "\"";
            case 2: return uniform(0, 2, rng) == 0 ? "true" : "false";
            case 3: return "null";
            default: return "0";
        }
    }
    
    string generateExpressionList(int depth)
    {
        auto count = uniform(0, 4, rng);
        if (count == 0) return "";
        string[] exprs;
        foreach (i; 0 .. count)
            exprs ~= generateExpression(depth);
        return exprs.join(", ");
    }
}

/// Coverage-guided fuzzer that tracks which parser paths are exercised
class CoverageGuidedFuzzer
{
    private Mt19937 rng;
    private GrammarAwareFuzzer grammarFuzzer;
    private bool[string] seenErrors;
    private string[] corpus;
    
    this(uint seed = unpredictableSeed)
    {
        rng.seed(seed);
        grammarFuzzer = new GrammarAwareFuzzer(seed);
        initializeCorpus();
    }
    
    private void initializeCorpus()
    {
        // Seed with minimal valid inputs
        corpus ~= "target(\"a\") { type: library; sources: [\"a.d\"]; }";
        corpus ~= "target(\"b\") { type: executable; sources: [\"main.d\"]; deps: [\"a\"]; }";
        corpus ~= "let x = 42;";
    }
    
    /// Generate input and track if it triggers new coverage
    string generateAndTrack()
    {
        auto choice = uniform(0, 5, rng);
        
        switch (choice)
        {
            case 0: return mutateCorpusEntry();
            case 1: return grammarFuzzer.generateCompleteTarget();
            case 2: return grammarFuzzer.generateSyntaxError(uniform(0, 15, rng));
            case 3: return grammarFuzzer.generateSemanticError(uniform(0, 10, rng));
            case 4: return spliceCorpusEntries();
            default: return corpus[uniform(0, corpus.length, rng)];
        }
    }
    
    void recordError(string errorMsg)
    {
        // Extract error type (first line or first 50 chars)
        auto errorKey = errorMsg.length > 50 ? errorMsg[0 .. 50] : errorMsg;
        if (errorKey !in seenErrors)
        {
            seenErrors[errorKey] = true;
        }
    }
    
    size_t uniqueErrorCount() const => seenErrors.length;
    
private:
    string mutateCorpusEntry()
    {
        if (corpus.length == 0) return "";
        
        auto entry = corpus[uniform(0, corpus.length, rng)].dup;
        auto mutationType = uniform(0, 5, rng);
        
        switch (mutationType)
        {
            case 0: // Insert random character
                auto pos = uniform(0, entry.length + 1, rng);
                auto c = cast(char)uniform(32, 127, rng);
                return entry[0 .. pos] ~ c ~ entry[pos .. $];
            
            case 1: // Delete random character
                if (entry.length > 1)
                {
                    auto pos = uniform(0, entry.length, rng);
                    return entry[0 .. pos] ~ entry[min(pos + 1, entry.length) .. $];
                }
                return entry;
            
            case 2: // Replace random character
                if (entry.length > 0)
                {
                    auto pos = uniform(0, entry.length, rng);
                    auto c = cast(char)uniform(32, 127, rng);
                    return entry[0 .. pos] ~ c ~ entry[min(pos + 1, entry.length) .. $];
                }
                return entry;
            
            case 3: // Duplicate chunk
                if (entry.length > 5)
                {
                    auto start = uniform(0, entry.length - 5, rng);
                    auto len = uniform(1, min(10, entry.length - start), rng);
                    auto chunk = entry[start .. start + len];
                    return entry[0 .. start] ~ chunk ~ chunk ~ entry[start .. $];
                }
                return entry;
            
            case 4: // Swap adjacent characters
                if (entry.length > 2)
                {
                    auto pos = uniform(0, entry.length - 1, rng);
                    auto temp = entry[pos];
                    entry[pos] = entry[pos + 1];
                    entry[pos + 1] = temp;
                }
                return entry.idup;
            
            default:
                return entry.idup;
        }
    }
    
    string spliceCorpusEntries()
    {
        if (corpus.length < 2) return corpus.length > 0 ? corpus[0] : "";
        
        auto entry1 = corpus[uniform(0, corpus.length, rng)];
        auto entry2 = corpus[uniform(0, corpus.length, rng)];
        
        if (entry1.length == 0 || entry2.length == 0)
            return entry1 ~ entry2;
        
        auto cut1 = uniform(0, entry1.length, rng);
        auto cut2 = uniform(0, entry2.length, rng);
        
        return entry1[0 .. cut1] ~ entry2[cut2 .. $];
    }
}

// =============================================================================
// EXTENDED FUZZING TESTS
// =============================================================================

/// Grammar-aware fuzzing: complete targets
@("fuzzing.grammar_aware.complete_targets")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Grammar-Aware - Complete Target Generation (2000 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-grammar-complete"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new GrammarAwareFuzzer();
    size_t parseSuccess = 0;
    size_t crashes = 0;
    immutable size_t iterations = 2000;
    
    foreach (i; 0 .. iterations)
    {
        auto dsl = fuzzer.generateCompleteTarget();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            if (result.isOk)
                parseSuccess++;
        }
        catch (Error e)
        {
            crashes++;
            writeln("    CRASH at iteration " ~ i.to!string);
        }
        catch (Exception e)
        {
            // Parse failure is expected sometimes
        }
        
        if ((i + 1) % 500 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    auto successRate = (parseSuccess * 100.0) / iterations;
    writeln("  Parse success: " ~ parseSuccess.to!string ~ "/" ~ iterations.to!string ~ 
            " (" ~ successRate.to!string ~ "%)");
    writeln("  Crashes: " ~ crashes.to!string);
    
    Assert.equal(crashes, 0, "No crashes should occur");
    Assert.isTrue(successRate >= 70.0, "At least 70% should parse successfully");
    writeln("\x1b[32m  ✓ Grammar-aware fuzzing passed\x1b[0m");
}

/// Grammar-aware fuzzing: project with dependencies
@("fuzzing.grammar_aware.project_deps")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Grammar-Aware - Project with Dependencies (500 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-grammar-project"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new GrammarAwareFuzzer();
    size_t crashes = 0;
    immutable size_t iterations = 500;
    
    foreach (i; 0 .. iterations)
    {
        auto dsl = fuzzer.generateProjectDSL();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e) { }
        
        if ((i + 1) % 100 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    Assert.equal(crashes, 0, "No crashes on project DSL");
    writeln("\x1b[32m  ✓ Project dependency fuzzing passed\x1b[0m");
}

/// Syntax error fuzzing: all error types
@("fuzzing.syntax_errors.comprehensive")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Syntax Errors - Comprehensive (1500 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-syntax-errors"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new GrammarAwareFuzzer();
    size_t crashes = 0;
    size_t properlyRejected = 0;
    immutable size_t iterations = 1500;
    
    foreach (i; 0 .. iterations)
    {
        auto dsl = fuzzer.generateSyntaxError(i);
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            if (result.isErr)
                properlyRejected++;
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e)
        {
            properlyRejected++;
        }
        
        if ((i + 1) % 300 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    auto rejectionRate = (properlyRejected * 100.0) / iterations;
    writeln("  Properly rejected: " ~ properlyRejected.to!string ~ "/" ~ iterations.to!string);
    writeln("  Crashes: " ~ crashes.to!string);
    
    Assert.equal(crashes, 0, "Syntax errors should not crash parser");
    Assert.isTrue(rejectionRate >= 80.0, "Most syntax errors should be rejected");
    writeln("\x1b[32m  ✓ Syntax error fuzzing passed\x1b[0m");
}

/// Semantic error fuzzing
@("fuzzing.semantic_errors.comprehensive")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Semantic Errors - Comprehensive (1000 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-semantic-errors"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new GrammarAwareFuzzer();
    size_t crashes = 0;
    immutable size_t iterations = 1000;
    
    foreach (i; 0 .. iterations)
    {
        auto dsl = fuzzer.generateSemanticError(i);
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            // Semantic errors may parse but should be caught later
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e) { }
        
        if ((i + 1) % 200 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    Assert.equal(crashes, 0, "Semantic errors should not crash");
    writeln("\x1b[32m  ✓ Semantic error fuzzing passed\x1b[0m");
}

/// Unicode edge case fuzzing
@("fuzzing.unicode.edge_cases")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Unicode - Edge Cases (500 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-unicode"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new GrammarAwareFuzzer();
    size_t crashes = 0;
    immutable size_t iterations = 500;
    
    foreach (i; 0 .. iterations)
    {
        auto dsl = fuzzer.generateUnicodeEdgeCase();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
        }
        catch (Error e)
        {
            crashes++;
            writeln("    CRASH on unicode case " ~ (i % 10).to!string);
        }
        catch (Exception e) { }
        
        if ((i + 1) % 100 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    Assert.equal(crashes, 0, "Unicode edge cases should not crash");
    writeln("\x1b[32m  ✓ Unicode edge case fuzzing passed\x1b[0m");
}

/// Coverage-guided fuzzing
@("fuzzing.coverage_guided.exploration")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Coverage-Guided - Exploration (3000 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-coverage"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new CoverageGuidedFuzzer();
    size_t crashes = 0;
    immutable size_t iterations = 3000;
    
    foreach (i; 0 .. iterations)
    {
        auto dsl = fuzzer.generateAndTrack();
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            if (result.isErr)
                fuzzer.recordError(result.unwrapErr().message());
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e)
        {
            fuzzer.recordError(e.msg);
        }
        
        if ((i + 1) % 500 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ ", unique errors: " ~ fuzzer.uniqueErrorCount().to!string);
    }
    
    writeln("  Unique error types discovered: " ~ fuzzer.uniqueErrorCount().to!string);
    writeln("  Crashes: " ~ crashes.to!string);
    
    Assert.equal(crashes, 0, "Coverage-guided fuzzing should not crash");
    writeln("\x1b[32m  ✓ Coverage-guided fuzzing passed\x1b[0m");
}

/// Binary mutation fuzzing
@("fuzzing.binary.mutations")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Binary - Bit-Level Mutations (1000 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-binary"));
    auto workspacePath = tempDir.getPath();
    
    // Base valid input
    string baseDSL = `target("test") {
    type: executable;
    sources: ["main.d", "utils.d"];
    deps: ["lib1"];
}`;
    
    auto rng = Mt19937(12345);
    size_t crashes = 0;
    immutable size_t iterations = 1000;
    
    foreach (i; 0 .. iterations)
    {
        // Apply bit-level mutations
        auto data = cast(ubyte[])baseDSL.dup;
        auto mutationCount = uniform(1, 10, rng);
        
        foreach (m; 0 .. mutationCount)
        {
            auto mutationType = uniform(0, 4, rng);
            
            switch (mutationType)
            {
                case 0: // Bit flip
                    if (data.length > 0)
                    {
                        auto pos = uniform(0, data.length, rng);
                        auto bit = uniform(0, 8, rng);
                        data[pos] ^= cast(ubyte)(1 << bit);
                    }
                    break;
                
                case 1: // Byte replacement
                    if (data.length > 0)
                    {
                        auto pos = uniform(0, data.length, rng);
                        data[pos] = cast(ubyte)uniform(0, 256, rng);
                    }
                    break;
                
                case 2: // Interesting values
                    if (data.length > 0)
                    {
                        ubyte[] interesting = [0x00, 0x01, 0x7F, 0x80, 0xFF];
                        auto pos = uniform(0, data.length, rng);
                        data[pos] = interesting[uniform(0, interesting.length, rng)];
                    }
                    break;
                
                case 3: // Block zeroing
                    if (data.length > 4)
                    {
                        auto start = uniform(0, data.length - 4, rng);
                        auto len = uniform(1, 5, rng);
                        foreach (j; 0 .. len)
                            if (start + j < data.length)
                                data[start + j] = 0;
                    }
                    break;
                
                default: break;
            }
        }
        
        auto mutatedDSL = cast(string)data;
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, mutatedDSL);
            auto result = parseDSL(mutatedDSL, buildfilePath, workspacePath);
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e) { }
        
        if ((i + 1) % 200 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    Assert.equal(crashes, 0, "Binary mutations should not crash parser");
    writeln("\x1b[32m  ✓ Binary mutation fuzzing passed\x1b[0m");
}

/// Lexer boundary fuzzing
@("fuzzing.lexer.boundaries")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Lexer - Token Boundaries (500 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-lexer"));
    auto workspacePath = tempDir.getPath();
    
    auto rng = Mt19937(54321);
    size_t crashes = 0;
    immutable size_t iterations = 500;
    
    // Generate inputs that stress token boundaries
    string[] boundaryInputs = [
        "target(\"\")",                    // Empty string
        "target()",                        // Missing argument
        "target \"test\")",                // Missing paren
        "target(\"test\"",                 // Unclosed
        "1234567890123456789012345678901234567890", // Long number
        "\"" ~ repeat('a', 10000).array.idup ~ "\"", // Long string
        "[[[[[[[[[[[[[[[[]]]]]]]]]]]]]]]", // Nested brackets
        "====================",            // Repeated operator
        "                   ",             // Whitespace only
        "\n\n\n\n\n\n\n\n\n\n",           // Newlines only
        "/* /* nested */ */",              // Nested comments
        "// comment\n// another\n",        // Multiple line comments
    ];
    
    foreach (i; 0 .. iterations)
    {
        auto input = i < boundaryInputs.length 
            ? boundaryInputs[i] 
            : boundaryInputs[uniform(0, boundaryInputs.length, rng)];
        
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, input);
            // Test lexer directly if available, otherwise through parser
            auto result = parseDSL(input, buildfilePath, workspacePath);
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e) { }
    }
    
    Assert.equal(crashes, 0, "Lexer boundary cases should not crash");
    writeln("\x1b[32m  ✓ Lexer boundary fuzzing passed\x1b[0m");
}

/// Resource exhaustion fuzzing
@("fuzzing.resources.exhaustion")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Resources - Exhaustion Attempts (100 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-resources"));
    auto workspacePath = tempDir.getPath();
    
    auto rng = Mt19937(99999);
    size_t crashes = 0;
    size_t timeouts = 0;
    immutable size_t iterations = 100;
    
    foreach (i; 0 .. iterations)
    {
        string dsl;
        auto choice = i % 5;
        
        switch (choice)
        {
            case 0: // Deep nesting
                dsl = "target(\"test\") { sources: ";
                foreach (j; 0 .. 500) dsl ~= "[";
                dsl ~= "\"a.d\"";
                foreach (j; 0 .. 500) dsl ~= "]";
                dsl ~= "; }";
                break;
            
            case 1: // Wide array
                dsl = "target(\"test\") { type: library; sources: [";
                foreach (j; 0 .. 5000)
                {
                    if (j > 0) dsl ~= ", ";
                    dsl ~= "\"file" ~ j.to!string ~ ".d\"";
                }
                dsl ~= "]; }";
                break;
            
            case 2: // Many targets
                foreach (j; 0 .. 500)
                    dsl ~= "target(\"t" ~ j.to!string ~ "\") { type: library; sources: [\"a.d\"]; }\n";
                break;
            
            case 3: // Long identifiers
                dsl = "target(\"" ~ repeat('a', 50000).array.idup ~ "\") { type: library; sources: [\"a.d\"]; }";
                break;
            
            case 4: // Many fields
                dsl = "target(\"test\") {\n    type: library;\n    sources: [\"a.d\"];\n";
                foreach (j; 0 .. 1000)
                    dsl ~= "    // comment " ~ j.to!string ~ "\n";
                dsl ~= "}";
                break;
            
            default:
                dsl = "target(\"test\") { type: library; sources: [\"a.d\"]; }";
        }
        
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        auto startTime = MonoTime.currTime;
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
            
            auto elapsed = MonoTime.currTime - startTime;
            if (elapsed > 5.seconds)
                timeouts++;
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e) { }
        
        if ((i + 1) % 20 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    writeln("  Crashes: " ~ crashes.to!string ~ ", Timeouts (>5s): " ~ timeouts.to!string);
    
    Assert.equal(crashes, 0, "Resource exhaustion should not crash");
    Assert.isTrue(timeouts < iterations / 2, "Most inputs should complete in reasonable time");
    writeln("\x1b[32m  ✓ Resource exhaustion fuzzing passed\x1b[0m");
}

/// Expression complexity fuzzing
@("fuzzing.expressions.complexity")
unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Expressions - Complexity (500 iterations)");
    
    auto tempDir = scoped(new TempDir("fuzz-expr"));
    auto workspacePath = tempDir.getPath();
    
    auto fuzzer = new GrammarAwareFuzzer();
    size_t crashes = 0;
    immutable size_t iterations = 500;
    
    foreach (i; 0 .. iterations)
    {
        auto expr = fuzzer.generateExpression(0);
        auto dsl = "let x = " ~ expr ~ ";";
        auto buildfilePath = buildPath(workspacePath, "Builderfile" ~ i.to!string);
        
        try
        {
            std.file.write(buildfilePath, dsl);
            auto result = parseDSL(dsl, buildfilePath, workspacePath);
        }
        catch (Error e)
        {
            crashes++;
        }
        catch (Exception e) { }
        
        if ((i + 1) % 100 == 0)
            writeln("    Progress: " ~ (i + 1).to!string ~ "/" ~ iterations.to!string);
    }
    
    Assert.equal(crashes, 0, "Complex expressions should not crash parser");
    writeln("\x1b[32m  ✓ Expression complexity fuzzing passed\x1b[0m");
}

/// Concurrent fuzzing (parser thread safety)
@("fuzzing.concurrent.parser_safety")
@system unittest
{
    writeln("\x1b[36m[FUZZ]\x1b[0m Concurrent - Parser Thread Safety");
    
    auto tempDir = scoped(new TempDir("fuzz-concurrent"));
    auto workspacePath = tempDir.getPath();
    
    shared size_t totalOperations = 0;
    shared size_t crashes = 0;
    shared bool done = false;
    
    Thread[] threads;
    
    foreach (t; 0 .. 4)
    {
        threads ~= new Thread({
            auto fuzzer = new GrammarAwareFuzzer(cast(uint)(t * 10000));
            auto threadWorkspace = buildPath(workspacePath, "thread" ~ t.to!string);
            mkdirRecurse(threadWorkspace);
            
            size_t localOps = 0;
            
            while (!atomicLoad(done) && localOps < 500)
            {
                auto dsl = fuzzer.generateCompleteTarget();
                auto buildfilePath = buildPath(threadWorkspace, "Builderfile" ~ localOps.to!string);
                
                try
                {
                    std.file.write(buildfilePath, dsl);
                    auto result = parseDSL(dsl, buildfilePath, threadWorkspace);
                }
                catch (Error e)
                {
                    atomicOp!"+="(crashes, 1);
                }
                catch (Exception e) { }
                
                localOps++;
                atomicOp!"+="(totalOperations, 1);
            }
        });
    }
    
    foreach (thread; threads) thread.start();
    
    Thread.sleep(5.seconds);
    atomicStore(done, true);
    
    foreach (thread; threads) thread.join();
    
    auto ops = atomicLoad(totalOperations);
    auto crashCount = atomicLoad(crashes);
    
    writeln("  Total operations: " ~ ops.to!string);
    writeln("  Crashes: " ~ crashCount.to!string);
    
    Assert.equal(crashCount, 0, "Concurrent parsing should not crash");
    Assert.isTrue(ops >= 100, "Should complete meaningful number of operations");
    writeln("\x1b[32m  ✓ Concurrent parser fuzzing passed\x1b[0m");
}


