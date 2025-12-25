module tests.unit.properties.ast_invariants;

import std.algorithm;
import std.array;
import std.conv;
import std.random;
import std.stdio;
import tests.harness;
import tests.property;
import infrastructure.utils.serialization;
import infrastructure.config.caching.schema;
import infrastructure.config.workspace.ast : Location, Literal, LiteralKind;

version(unittest):

// =============================================================================
// AST LOCATION ROUNDTRIP PROPERTIES
// =============================================================================

/// Property: Location serialize/deserialize roundtrip preserves all fields
@("property.ast.location.roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Location roundtrip");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool locationRoundtrip(string file, ulong line, ulong column)
    {
        SerializableLocation original;
        original.file = file.length > 0 ? file : "test.d";
        original.line = line > 0 ? line : 1;
        original.column = column > 0 ? column : 1;
        
        // Serialize
        ubyte[] serialized = Codec.serialize(original);
        
        // Deserialize
        auto result = () @trusted { return Codec.deserialize!SerializableLocation(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        // Verify all fields match
        return deserialized.file == original.file &&
               deserialized.line == original.line &&
               deserialized.column == original.column;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate random file path
        auto pathLen = uniform(5, 50, rng);
        char[] path;
        foreach (j; 0 .. pathLen)
        {
            auto choice = uniform(0, 4, rng);
            if (choice == 0)
                path ~= '/';
            else if (choice == 1)
                path ~= '.';
            else
                path ~= cast(char)uniform('a', 'z' + 1, rng);
        }
        
        ulong line = uniform(1, 10000, rng);
        ulong column = uniform(1, 500, rng);
        
        if (locationRoundtrip(path.idup, line, column))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// AST LITERAL ROUNDTRIP PROPERTIES
// =============================================================================

/// Property: Null literal roundtrip
@("property.ast.literal.null_roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Null literal roundtrip");
    
    auto config = PropertyConfig(numTests: 10);
    
    static bool nullLiteralRoundtrip()
    {
        SerializableLiteral original;
        original.kind = cast(uint)LiteralKind.Null;
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableLiteral(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        return deserialized.kind == cast(uint)LiteralKind.Null;
    }
    
    size_t passed = 0;
    foreach (i; 0 .. config.numTests)
    {
        if (nullLiteralRoundtrip())
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Boolean literal roundtrip
@("property.ast.literal.bool_roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Boolean literal roundtrip");
    
    auto config = PropertyConfig(numTests: 20);
    
    static bool boolLiteralRoundtrip(bool value)
    {
        SerializableLiteral original;
        original.kind = cast(uint)LiteralKind.Bool;
        original.boolValue = value;
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableLiteral(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        return deserialized.kind == cast(uint)LiteralKind.Bool &&
               deserialized.boolValue == value;
    }
    
    size_t passed = 0;
    
    // Test both true and false
    if (boolLiteralRoundtrip(true)) passed++;
    if (boolLiteralRoundtrip(false)) passed++;
    
    // Fill remaining tests
    Mt19937 rng = Mt19937(42);
    foreach (i; 2 .. config.numTests)
    {
        if (boolLiteralRoundtrip(uniform(0, 2, rng) == 1))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Number literal roundtrip
@("property.ast.literal.number_roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Number literal roundtrip");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool numberLiteralRoundtrip(long value)
    {
        SerializableLiteral original;
        original.kind = cast(uint)LiteralKind.Number;
        original.numberValue = value;
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableLiteral(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        return deserialized.kind == cast(uint)LiteralKind.Number &&
               deserialized.numberValue == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Edge cases
    if (numberLiteralRoundtrip(0)) passed++;
    if (numberLiteralRoundtrip(1)) passed++;
    if (numberLiteralRoundtrip(-1)) passed++;
    if (numberLiteralRoundtrip(long.max)) passed++;
    if (numberLiteralRoundtrip(long.min)) passed++;
    
    // Random values
    foreach (i; 5 .. config.numTests)
    {
        uint high = uniform!uint(rng);
        uint low = uniform!uint(rng);
        long value = (cast(long)high << 32) | low;
        
        if (numberLiteralRoundtrip(value))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: String literal roundtrip
@("property.ast.literal.string_roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST String literal roundtrip");
    
    auto config = PropertyConfig(numTests: 100);
    
    static bool stringLiteralRoundtrip(string value)
    {
        SerializableLiteral original;
        original.kind = cast(uint)LiteralKind.String;
        original.stringValue = value;
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableLiteral(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        return deserialized.kind == cast(uint)LiteralKind.String &&
               deserialized.stringValue == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    // Edge cases
    if (stringLiteralRoundtrip("")) passed++;
    if (stringLiteralRoundtrip("a")) passed++;
    if (stringLiteralRoundtrip("hello world")) passed++;
    if (stringLiteralRoundtrip("path/to/file.d")) passed++;
    if (stringLiteralRoundtrip("//lib:dependency")) passed++;
    
    // Random strings
    foreach (i; 5 .. config.numTests)
    {
        auto strLen = uniform(0, 200, rng);
        char[] str;
        foreach (j; 0 .. strLen)
            str ~= cast(char)uniform(32, 127, rng);
        
        if (stringLiteralRoundtrip(str.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// AST FIELD ROUNDTRIP PROPERTIES
// =============================================================================

/// Property: SerializableField roundtrip preserves all data
@("property.ast.field.roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Field roundtrip");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool fieldRoundtrip(string name, string file, ulong line, string value)
    {
        SerializableField original;
        original.name = name.length > 0 ? name : "field";
        original.loc.file = file.length > 0 ? file : "test.d";
        original.loc.line = line > 0 ? line : 1;
        original.loc.column = 1;
        original.value.exprType = cast(uint)ExprType.Literal;
        original.value.literal.kind = cast(uint)LiteralKind.String;
        original.value.literal.stringValue = value;
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableField(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        return deserialized.name == original.name &&
               deserialized.loc.file == original.loc.file &&
               deserialized.loc.line == original.loc.line &&
               deserialized.value.literal.stringValue == value;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    string[] fieldNames = ["type", "sources", "deps", "flags", "output", "language"];
    
    foreach (i; 0 .. config.numTests)
    {
        auto name = fieldNames[uniform(0, fieldNames.length, rng)];
        
        auto fileLen = uniform(5, 30, rng);
        char[] file;
        foreach (j; 0 .. fileLen)
            file ~= cast(char)uniform('a', 'z' + 1, rng);
        file ~= ".d";
        
        ulong line = uniform(1, 1000, rng);
        
        auto valueLen = uniform(1, 50, rng);
        char[] value;
        foreach (j; 0 .. valueLen)
            value ~= cast(char)uniform('a', 'z' + 1, rng);
        
        if (fieldRoundtrip(name, file.idup, line, value.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// AST TARGET ROUNDTRIP PROPERTIES
// =============================================================================

/// Property: SerializableTarget roundtrip preserves all data
@("property.ast.target.roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Target roundtrip");
    
    auto config = PropertyConfig(numTests: 30);
    
    static bool targetRoundtrip(string name, string[] sources)
    {
        SerializableTarget original;
        original.name = name.length > 0 ? name : "target";
        original.loc.file = "Builderfile";
        original.loc.line = 1;
        original.loc.column = 1;
        
        // Add type field
        SerializableField typeField;
        typeField.name = "type";
        typeField.loc = original.loc;
        typeField.value.exprType = cast(uint)ExprType.Ident;
        typeField.value.identifier = "executable";
        original.fields ~= typeField;
        
        // Add sources field
        if (sources.length > 0)
        {
            SerializableField sourcesField;
            sourcesField.name = "sources";
            sourcesField.loc = original.loc;
            sourcesField.value.exprType = cast(uint)ExprType.Literal;
            sourcesField.value.literal.kind = cast(uint)LiteralKind.Array;
            
            foreach (src; sources)
            {
                SerializableLiteral elem;
                elem.kind = cast(uint)LiteralKind.String;
                elem.stringValue = src;
                sourcesField.value.literal.arrayValue ~= elem;
            }
            original.fields ~= sourcesField;
        }
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableTarget(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        // Verify name matches
        if (deserialized.name != original.name)
            return false;
        
        // Verify field count matches
        if (deserialized.fields.length != original.fields.length)
            return false;
        
        // Verify type field
        if (deserialized.fields.length > 0)
        {
            if (deserialized.fields[0].name != "type")
                return false;
            if (deserialized.fields[0].value.identifier != "executable")
                return false;
        }
        
        return true;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate target name
        auto nameLen = uniform(3, 20, rng);
        char[] name;
        foreach (j; 0 .. nameLen)
            name ~= cast(char)uniform('a', 'z' + 1, rng);
        
        // Generate sources
        auto srcCount = uniform(0, 10, rng);
        string[] sources;
        foreach (j; 0 .. srcCount)
            sources ~= "src/file" ~ j.to!string ~ ".d";
        
        if (targetRoundtrip(name.idup, sources))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// AST BUILD FILE ROUNDTRIP PROPERTIES
// =============================================================================

/// Property: SerializableBuildFile roundtrip preserves all data
@("property.ast.buildfile.roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST BuildFile roundtrip");
    
    auto config = PropertyConfig(numTests: 20);
    
    static bool buildFileRoundtrip(string filePath, string[] targetNames)
    {
        SerializableBuildFile original;
        original.filePath = filePath.length > 0 ? filePath : "Builderfile";
        
        // Create targets
        foreach (name; targetNames)
        {
            SerializableTarget target;
            target.name = name;
            target.loc.file = original.filePath;
            target.loc.line = 1;
            target.loc.column = 1;
            
            // Add type field
            SerializableField typeField;
            typeField.name = "type";
            typeField.loc = target.loc;
            typeField.value.exprType = cast(uint)ExprType.Ident;
            typeField.value.identifier = "library";
            target.fields ~= typeField;
            
            original.targets ~= target;
        }
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableBuildFile(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        // Verify file path
        if (deserialized.filePath != original.filePath)
            return false;
        
        // Verify target count
        if (deserialized.targets.length != original.targets.length)
            return false;
        
        // Verify target names
        foreach (i, target; deserialized.targets)
        {
            if (target.name != original.targets[i].name)
                return false;
        }
        
        return true;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate file path
        auto pathLen = uniform(5, 30, rng);
        char[] path;
        foreach (j; 0 .. pathLen)
        {
            auto choice = uniform(0, 3, rng);
            if (choice == 0)
                path ~= '/';
            else
                path ~= cast(char)uniform('a', 'z' + 1, rng);
        }
        path ~= "/Builderfile";
        
        // Generate target names
        auto targetCount = uniform(1, 5, rng);
        string[] targets;
        foreach (j; 0 .. targetCount)
        {
            auto nameLen = uniform(3, 15, rng);
            char[] name;
            foreach (k; 0 .. nameLen)
                name ~= cast(char)uniform('a', 'z' + 1, rng);
            targets ~= name.idup;
        }
        
        if (buildFileRoundtrip(path.idup, targets))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// AST EXPRESSION ROUNDTRIP PROPERTIES
// =============================================================================

/// Property: Identifier expression roundtrip
@("property.ast.expr.ident_roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Identifier expression roundtrip");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool identExprRoundtrip(string name)
    {
        SerializableExpr original;
        original.exprType = cast(uint)ExprType.Ident;
        original.identifier = name.length > 0 ? name : "x";
        original.loc.file = "test.d";
        original.loc.line = 1;
        original.loc.column = 1;
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableExpr(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        return deserialized.exprType == cast(uint)ExprType.Ident &&
               deserialized.identifier == original.identifier;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        // Generate valid identifier
        auto len = uniform(1, 30, rng);
        char[] name;
        name ~= cast(char)uniform('a', 'z' + 1, rng);
        foreach (j; 1 .. len)
        {
            auto choice = uniform(0, 3, rng);
            if (choice == 0)
                name ~= cast(char)uniform('a', 'z' + 1, rng);
            else if (choice == 1)
                name ~= cast(char)uniform('0', '9' + 1, rng);
            else
                name ~= '_';
        }
        
        if (identExprRoundtrip(name.idup))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

/// Property: Binary expression operators roundtrip
@("property.ast.expr.binary_roundtrip")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST Binary expression roundtrip");
    
    auto config = PropertyConfig(numTests: 50);
    
    static bool binaryExprRoundtrip(string op)
    {
        SerializableExpr original;
        original.exprType = cast(uint)ExprType.Binary;
        original.binaryOp = op;
        original.loc.file = "test.d";
        original.loc.line = 1;
        original.loc.column = 1;
        
        ubyte[] serialized = Codec.serialize(original);
        
        auto result = () @trusted { return Codec.deserialize!SerializableExpr(serialized); }();
        if (result.isErr)
            return false;
        
        auto deserialized = result.unwrap();
        
        return deserialized.exprType == cast(uint)ExprType.Binary &&
               deserialized.binaryOp == op;
    }
    
    string[] operators = ["+", "-", "*", "/", "%", "==", "!=", "<", "<=", ">", ">=", "&&", "||"];
    
    size_t passed = 0;
    
    // Test all operators
    foreach (op; operators)
    {
        if (binaryExprRoundtrip(op))
            passed++;
    }
    
    // Fill remaining tests
    Mt19937 rng = Mt19937(42);
    foreach (i; operators.length .. config.numTests)
    {
        auto op = operators[uniform(0, operators.length, rng)];
        if (binaryExprRoundtrip(op))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

// =============================================================================
// SERIALIZATION DETERMINISM PROPERTIES
// =============================================================================

/// Property: Serializing same AST twice produces identical bytes
@("property.ast.determinism")
unittest
{
    writeln("\x1b[36m[PROPERTY TEST]\x1b[0m AST serialization determinism");
    
    auto config = PropertyConfig(numTests: 30);
    
    static bool astDeterministic(string targetName, string[] sources)
    {
        SerializableBuildFile ast;
        ast.filePath = "Builderfile";
        
        SerializableTarget target;
        target.name = targetName.length > 0 ? targetName : "test";
        target.loc.file = "Builderfile";
        target.loc.line = 1;
        target.loc.column = 1;
        
        // Add sources
        SerializableField sourcesField;
        sourcesField.name = "sources";
        sourcesField.loc = target.loc;
        sourcesField.value.exprType = cast(uint)ExprType.Literal;
        sourcesField.value.literal.kind = cast(uint)LiteralKind.Array;
        
        foreach (src; sources)
        {
            SerializableLiteral elem;
            elem.kind = cast(uint)LiteralKind.String;
            elem.stringValue = src;
            sourcesField.value.literal.arrayValue ~= elem;
        }
        target.fields ~= sourcesField;
        ast.targets ~= target;
        
        // Serialize multiple times
        ubyte[] s1 = Codec.serialize(ast);
        ubyte[] s2 = Codec.serialize(ast);
        ubyte[] s3 = Codec.serialize(ast);
        
        return s1 == s2 && s2 == s3;
    }
    
    Mt19937 rng = Mt19937(config.seed);
    size_t passed = 0;
    
    foreach (i; 0 .. config.numTests)
    {
        auto nameLen = uniform(3, 20, rng);
        char[] name;
        foreach (j; 0 .. nameLen)
            name ~= cast(char)uniform('a', 'z' + 1, rng);
        
        auto srcCount = uniform(0, 10, rng);
        string[] sources;
        foreach (j; 0 .. srcCount)
            sources ~= "src/file" ~ j.to!string ~ ".d";
        
        if (astDeterministic(name.idup, sources))
            passed++;
    }
    
    Assert.equal(passed, config.numTests);
    writeln("  \x1b[32m✓ Passed " ~ config.numTests.to!string ~ " tests\x1b[0m");
}

