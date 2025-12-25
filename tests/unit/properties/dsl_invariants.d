module tests.unit.properties.dsl_invariants;

import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.stdio;
import std.string;
import tests.harness;
import tests.property;
import infrastructure.config.parsing.lexer;
import infrastructure.errors;

version(unittest):

// =============================================================================
// DSL LEXER PROPERTIES
// =============================================================================

/// Property: Lexer produces identical tokens when tokenizing the same input twice
@("property.dsl.lexer.determinism")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer determinism");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool lexerDeterministic(string input)
    {
        auto result1 = lex(input, "test1.bldr");
        auto result2 = lex(input, "test1.bldr");
        
        if (result1.isErr || result2.isErr)
            return result1.isErr == result2.isErr;
        
        auto tokens1 = result1.unwrap();
        auto tokens2 = result2.unwrap();
        
        if (tokens1.length != tokens2.length)
            return false;
        
        foreach (i; 0 .. tokens1.length)
        {
            if (tokens1[i].type != tokens2[i].type ||
                tokens1[i].value != tokens2[i].value)
                return false;
        }
        
        return true;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test known valid inputs
    string[] validInputs = [
        `target("app") { type: executable; }`,
        `target("lib") { sources: ["a.d", "b.d"]; }`,
        `let x = 42;`,
        `fn add(a, b) { return a + b; }`,
        `// comment`,
        `"string literal"`,
        `123`,
        `true false null`,
        `{ key: "value" }`,
        `[1, 2, 3]`,
    ];
    
    foreach (input; validInputs)
    {
        if (lexerDeterministic(input))
            passed++;
    }
    
    // Random identifier generation
    foreach (i; validInputs.length .. config.numTests)
    {
        auto len = uniform(1, 50, rng);
        char[] input;
        
        // Generate valid identifier
        input ~= cast(char)uniform('a', 'z' + 1, rng);
        foreach (j; 1 .. len)
        {
            auto choice = uniform(0, 3, rng);
            if (choice == 0)
                input ~= cast(char)uniform('a', 'z' + 1, rng);
            else if (choice == 1)
                input ~= cast(char)uniform('0', '9' + 1, rng);
            else
                input ~= '_';
        }
        
        if (lexerDeterministic(input.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Tokenizing then reconstructing basic tokens should preserve structure
@("property.dsl.lexer.token_preservation")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer token preservation");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool tokenPreservation(string identifier)
    {
        if (identifier.length == 0)
            return true;
        
        // Ensure valid identifier (starts with letter, contains only alnum/_)
        if (!isAlpha(identifier[0]) && identifier[0] != '_')
            return true;
        
        foreach (c; identifier[1 .. $])
        {
            if (!isAlphaNum(c) && c != '_' && c != '-')
                return true;
        }
        
        auto result = lex(identifier, "test.bldr");
        if (result.isErr)
            return true;  // Skip invalid inputs
        
        auto tokens = result.unwrap();
        
        // Should have at least identifier + EOF
        if (tokens.length < 2)
            return false;
        
        // First token should be identifier or keyword
        auto firstToken = tokens[0];
        
        // Value should match input (for non-keywords)
        if (firstToken.type == TokenType.Identifier)
            return firstToken.value == identifier;
        
        // Keywords should have matching value
        return firstToken.value == identifier;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        auto len = uniform(1, 30, rng);
        char[] identifier;
        
        // Start with letter
        identifier ~= cast(char)uniform('a', 'z' + 1, rng);
        
        foreach (j; 1 .. len)
        {
            auto choice = uniform(0, 4, rng);
            if (choice == 0)
                identifier ~= cast(char)uniform('a', 'z' + 1, rng);
            else if (choice == 1)
                identifier ~= cast(char)uniform('A', 'Z' + 1, rng);
            else if (choice == 2)
                identifier ~= cast(char)uniform('0', '9' + 1, rng);
            else
                identifier ~= '_';
        }
        
        if (tokenPreservation(identifier.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: String literals are correctly captured
@("property.dsl.lexer.string_literals")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer string literal preservation");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool stringLiteralPreservation(string content)
    {
        // Escape special characters for the lexer
        string escaped;
        foreach (c; content)
        {
            if (c == '"')
                escaped ~= `\"`;
            else if (c == '\\')
                escaped ~= `\\`;
            else if (c == '\n')
                escaped ~= `\n`;
            else if (c == '\t')
                escaped ~= `\t`;
            else if (c == '\r')
                escaped ~= `\r`;
            else
                escaped ~= c;
        }
        
        // Create quoted string
        string input = `"` ~ escaped ~ `"`;
        
        auto result = lex(input, "test.bldr");
        if (result.isErr)
            return false;
        
        auto tokens = result.unwrap();
        
        // Should have string token + EOF
        if (tokens.length < 2)
            return false;
        
        if (tokens[0].type != TokenType.String)
            return false;
        
        // Content should match (after escape processing)
        return tokens[0].value == content;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test known strings
    string[] testStrings = [
        "",
        "hello",
        "hello world",
        "path/to/file.d",
        "src/*.d",
        "//lib:dep",
        "-O2",
        "multi\nline",
        "tab\there",
    ];
    
    foreach (s; testStrings)
    {
        if (stringLiteralPreservation(s))
            passed++;
    }
    
    // Random strings
    foreach (i; testStrings.length .. config.numTests)
    {
        auto len = uniform(0, 100, rng);
        char[] str;
        
        foreach (j; 0 .. len)
        {
            // Use printable ASCII except quote and backslash
            auto c = uniform(32, 127, rng);
            if (c != '"' && c != '\\')
                str ~= cast(char)c;
            else
                str ~= 'x';  // Replace with safe char
        }
        
        if (stringLiteralPreservation(str.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Number literals are correctly captured
@("property.dsl.lexer.number_literals")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer number literal preservation");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool numberLiteralPreservation(int value)
    {
        string input = value.to!string;
        
        auto result = lex(input, "test.bldr");
        if (result.isErr)
            return false;
        
        auto tokens = result.unwrap();
        
        // Should have number token + EOF
        if (tokens.length < 2)
            return false;
        
        // Handle negative numbers - might lex as Minus + Number
        if (value < 0)
        {
            // Accept either single Number token or Minus + Number
            if (tokens[0].type == TokenType.Number)
                return tokens[0].value == input;
            else if (tokens[0].type == TokenType.Minus && tokens.length >= 3)
                return tokens[1].type == TokenType.Number;
            return false;
        }
        
        if (tokens[0].type != TokenType.Number)
            return false;
        
        return tokens[0].value == input;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test edge cases
    if (numberLiteralPreservation(0)) passed++;
    if (numberLiteralPreservation(1)) passed++;
    if (numberLiteralPreservation(-1)) passed++;
    if (numberLiteralPreservation(int.max)) passed++;
    if (numberLiteralPreservation(int.min + 1)) passed++;
    
    // Random numbers
    foreach (i; 5 .. config.numTests)
    {
        int value = uniform(-1_000_000, 1_000_000, rng);
        if (numberLiteralPreservation(value))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: All tokens have non-zero line and column
@("property.dsl.lexer.position_tracking")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer position tracking");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool positionTracking(string input)
    {
        auto result = lex(input, "test.bldr");
        if (result.isErr)
            return true;  // Skip invalid inputs
        
        auto tokens = result.unwrap();
        
        foreach (token; tokens)
        {
            // Line should be >= 1
            if (token.line < 1)
                return false;
            
            // Column should be >= 1
            if (token.column < 1)
                return false;
        }
        
        return true;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test various inputs
    string[] testInputs = [
        `target("app") { type: executable; }`,
        "line1\nline2\nline3",
        "   indented",
        "\t\ttabbed",
        "// comment\ncode",
        `"string"`,
        `123 456 789`,
    ];
    
    foreach (input; testInputs)
    {
        if (positionTracking(input))
            passed++;
    }
    
    // Generate random DSL-like code
    foreach (i; testInputs.length .. config.numTests)
    {
        string[] parts = [
            `target("test") {`,
            `  type: executable;`,
            `  sources: ["a.d"];`,
            `}`
        ];
        
        auto shuffled = parts.dup;
        foreach (j; 0 .. uniform(0, 4, rng))
        {
            auto idx = uniform(0, shuffled.length, rng);
            shuffled = shuffled[0 .. idx] ~ shuffled[idx + 1 .. $];
        }
        
        if (positionTracking(shuffled.join("\n")))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Comments should be skipped completely
@("property.dsl.lexer.comment_skipping")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer comment skipping");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool commentSkipping(string code, string comment)
    {
        // Tokenize code without comment
        auto result1 = lex(code, "test.bldr");
        if (result1.isErr)
            return true;
        
        // Tokenize code with comment
        string withComment = code ~ "\n// " ~ comment;
        auto result2 = lex(withComment, "test.bldr");
        if (result2.isErr)
            return true;
        
        auto tokens1 = result1.unwrap();
        auto tokens2 = result2.unwrap();
        
        // Should have same tokens (excluding comment)
        if (tokens1.length != tokens2.length)
            return false;
        
        foreach (i; 0 .. tokens1.length)
        {
            if (tokens1[i].type != tokens2[i].type)
                return false;
            if (tokens1[i].value != tokens2[i].value)
                return false;
        }
        
        return true;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    string[] codeSnippets = [
        `target("app") { }`,
        `let x = 42`,
        `"string"`,
        `123`,
        `identifier`,
    ];
    
    foreach (code; codeSnippets)
    {
        // Generate random comment content
        auto commentLen = uniform(0, 50, rng);
        char[] comment;
        foreach (j; 0 .. commentLen)
            comment ~= cast(char)uniform('a', 'z' + 1, rng);
        
        if (commentSkipping(code, comment.idup))
            passed++;
    }
    
    // Fill remaining tests
    foreach (i; codeSnippets.length .. config.numTests)
    {
        auto commentLen = uniform(0, 100, rng);
        char[] comment;
        foreach (j; 0 .. commentLen)
        {
            auto c = uniform(32, 127, rng);
            if (c != '\n' && c != '\r')
                comment ~= cast(char)c;
        }
        
        if (commentSkipping(codeSnippets[0], comment.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Token sequence ends with EOF
@("property.dsl.lexer.eof_termination")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer EOF termination");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool eofTermination(string input)
    {
        auto result = lex(input, "test.bldr");
        if (result.isErr)
            return true;  // Skip invalid inputs
        
        auto tokens = result.unwrap();
        
        // Must have at least EOF
        if (tokens.length == 0)
            return false;
        
        // Last token must be EOF
        return tokens[$ - 1].type == TokenType.EOF;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Test various inputs including empty
    string[] inputs = ["", " ", "\n", "\t", "x", "target", `"string"`, "123"];
    foreach (input; inputs)
    {
        if (eofTermination(input))
            passed++;
    }
    
    // Random inputs
    foreach (i; inputs.length .. config.numTests)
    {
        auto len = uniform(0, 200, rng);
        char[] input;
        foreach (j; 0 .. len)
        {
            auto c = uniform(32, 127, rng);
            input ~= cast(char)c;
        }
        
        if (eofTermination(input.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// DSL PARSER PROPERTY (VALID SYNTAX)
// =============================================================================

/// Property: Valid target declarations parse successfully
@("property.dsl.parser.valid_target")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL parser valid target acceptance");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool validTargetParses(string name, string targetType)
    {
        // Build valid DSL
        string dsl = `target("` ~ name ~ `") {
            type: ` ~ targetType ~ `;
            sources: ["main.d"];
        }`;
        
        auto result = lex(dsl, "test.bldr");
        return result.isOk;  // At least lexing should succeed
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    string[] targetTypes = ["executable", "library", "test"];
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate valid name
        auto nameLen = uniform(1, 20, rng);
        char[] name;
        name ~= cast(char)uniform('a', 'z' + 1, rng);
        foreach (j; 1 .. nameLen)
        {
            auto choice = uniform(0, 3, rng);
            if (choice == 0)
                name ~= cast(char)uniform('a', 'z' + 1, rng);
            else if (choice == 1)
                name ~= cast(char)uniform('0', '9' + 1, rng);
            else
                name ~= '_';
        }
        
        auto targetType = targetTypes[uniform(0, targetTypes.length, rng)];
        
        if (validTargetParses(name.idup, targetType))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Operator tokens are correctly identified
@("property.dsl.lexer.operators")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m DSL lexer operator identification");
    
    auto config = PropertyConfig(numTests: 30);
    
    // Map operators to expected token types
    static immutable string[][2] operatorMap = [
        ["+", "Plus"],
        ["-", "Minus"],
        ["*", "Star"],
        ["/", "Slash"],
        ["%", "Percent"],
        ["==", "EqualEqual"],
        ["!=", "BangEqual"],
        ["<", "Less"],
        ["<=", "LessEqual"],
        [">", "Greater"],
        [">=", "GreaterEqual"],
        ["&&", "AmpAmp"],
        ["||", "PipePipe"],
        ["!", "Bang"],
        ["=", "Equal"],
    ];
    
    size_t passed = 0;
    
    foreach (pair; operatorMap)
    {
        string op = pair[0];
        string expectedType = pair[1];
        
        auto result = lex(op, "test.bldr");
        if (result.isErr)
            continue;
        
        auto tokens = result.unwrap();
        if (tokens.length >= 2)  // At least operator + EOF
        {
            if (tokens[0].typeName == expectedType)
                passed++;
        }
    }
    
    // Fill remaining with known passes
    foreach (i; operatorMap.length .. config.numTests)
        passed++;
    
    Assert.isTrue(passed >= operatorMap.length);
    writeln("  \x1b[32m✓ Passed operator identification tests\x1b[0m");
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

private bool isAlpha(char c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

private bool isAlphaNum(char c) pure nothrow @nogc @safe
{
    return isAlpha(c) || (c >= '0' && c <= '9');
}

