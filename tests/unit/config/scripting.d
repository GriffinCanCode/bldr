module tests.unit.config.scripting;

import std.stdio;
import infrastructure.config.scripting.types;
import infrastructure.config.scripting.scopemanager;
import infrastructure.config.scripting.builtins;
import infrastructure.config.scripting.evaluator;
import infrastructure.config.scripting.interpreter;
import infrastructure.config.workspace.ast;
import infrastructure.errors;

/// Value type tests
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.types - Value creation and access");
    
    // Null
    auto nullVal = Value.makeNull();
    assert(nullVal.isNull());
    assert(nullVal.type() == ValueType.Null);
    
    // Bool
    auto boolVal = Value.makeBool(true);
    assert(boolVal.isBool());
    assert(boolVal.asBool() == true);
    
    // Number
    auto numVal = Value.makeNumber(42.5);
    assert(numVal.isNumber());
    assert(numVal.asNumber() == 42.5);
    
    // String
    auto strVal = Value.makeString("hello");
    assert(strVal.isString());
    assert(strVal.asString() == "hello");
    
    // Array
    auto arrVal = Value.makeArray([Value.makeNumber(1), Value.makeNumber(2)]);
    assert(arrVal.isArray());
    assert(arrVal.asArray().length == 2);
    
    // Map
    Value[string] map;
    map["key"] = Value.makeString("value");
    auto mapVal = Value.makeMap(map);
    assert(mapVal.isMap());
    assert(mapVal.asMap()["key"].asString() == "value");
}

/// Value truthiness tests
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.types - Value truthiness");
    
    assert(!Value.makeNull().toBool());
    assert(!Value.makeBool(false).toBool());
    assert(Value.makeBool(true).toBool());
    assert(!Value.makeNumber(0).toBool());
    assert(Value.makeNumber(1).toBool());
    assert(!Value.makeString("").toBool());
    assert(Value.makeString("x").toBool());
    assert(!Value.makeArray([]).toBool());
    assert(Value.makeArray([Value.makeNull()]).toBool());
}

/// Value equality tests
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.types - Value equality");
    
    assert(Value.makeNull() == Value.makeNull());
    assert(Value.makeBool(true) == Value.makeBool(true));
    assert(Value.makeBool(true) != Value.makeBool(false));
    assert(Value.makeNumber(42) == Value.makeNumber(42));
    assert(Value.makeString("abc") == Value.makeString("abc"));
    
    auto arr1 = Value.makeArray([Value.makeNumber(1), Value.makeNumber(2)]);
    auto arr2 = Value.makeArray([Value.makeNumber(1), Value.makeNumber(2)]);
    assert(arr1 == arr2);
}

/// Scope manager tests
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.scopemanager - Basic operations");
    
    auto scope_ = new ScopeManager();
    
    // Define variable
    auto defResult = scope_.define("x", Value.makeNumber(10), false);
    assert(defResult.isOk);
    
    // Lookup variable
    auto lookupResult = scope_.lookup("x");
    assert(lookupResult.isOk);
    assert(lookupResult.unwrap().asNumber() == 10);
    
    // Assign to variable
    auto assignResult = scope_.assign("x", Value.makeNumber(20));
    assert(assignResult.isOk);
    assert(scope_.lookup("x").unwrap().asNumber() == 20);
    
    // Undefined variable
    assert(scope_.lookup("undefined").isErr);
}

/// Scope manager const tests
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.scopemanager - Const enforcement");
    
    auto scope_ = new ScopeManager();
    
    // Define const
    scope_.define("PI", Value.makeNumber(3.14159), true);
    
    // Cannot reassign const
    auto assignResult = scope_.assign("PI", Value.makeNumber(3.0));
    assert(assignResult.isErr);
    
    // Value unchanged
    assert(scope_.lookup("PI").unwrap().asNumber() == 3.14159);
}

/// Scope manager nested scopes
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.scopemanager - Nested scopes");
    
    auto scope_ = new ScopeManager();
    
    scope_.define("outer", Value.makeNumber(1), false);
    
    scope_.enterScope();
    scope_.define("inner", Value.makeNumber(2), false);
    
    // Both visible
    assert(scope_.lookup("outer").isOk);
    assert(scope_.lookup("inner").isOk);
    
    scope_.exitScope();
    
    // Only outer visible
    assert(scope_.lookup("outer").isOk);
    assert(scope_.lookup("inner").isErr);
}

/// Builtin string functions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.builtins - String functions");
    
    auto registry = new BuiltinRegistry();
    
    // upper
    auto upperFn = registry.get("upper").unwrap();
    auto upperResult = upperFn([Value.makeString("hello")]);
    assert(upperResult.isOk);
    assert(upperResult.unwrap().asString() == "HELLO");
    
    // lower
    auto lowerFn = registry.get("lower").unwrap();
    auto lowerResult = lowerFn([Value.makeString("WORLD")]);
    assert(lowerResult.isOk);
    assert(lowerResult.unwrap().asString() == "world");
    
    // trim
    auto trimFn = registry.get("trim").unwrap();
    auto trimResult = trimFn([Value.makeString("  spaces  ")]);
    assert(trimResult.isOk);
    assert(trimResult.unwrap().asString() == "spaces");
    
    // split
    auto splitFn = registry.get("split").unwrap();
    auto splitResult = splitFn([Value.makeString("a,b,c"), Value.makeString(",")]);
    assert(splitResult.isOk);
    auto splitArr = splitResult.unwrap().asArray();
    assert(splitArr.length == 3);
    assert(splitArr[0].asString() == "a");
    
    // join
    auto joinFn = registry.get("join").unwrap();
    auto joinResult = joinFn([
        Value.makeArray([Value.makeString("x"), Value.makeString("y")]),
        Value.makeString("-")
    ]);
    assert(joinResult.isOk);
    assert(joinResult.unwrap().asString() == "x-y");
}

/// Builtin array functions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.builtins - Array functions");
    
    auto registry = new BuiltinRegistry();
    
    // len
    auto lenFn = registry.get("len").unwrap();
    auto lenResult = lenFn([Value.makeArray([Value.makeNumber(1), Value.makeNumber(2), Value.makeNumber(3)])]);
    assert(lenResult.isOk);
    assert(lenResult.unwrap().asNumber() == 3);
    
    // append
    auto appendFn = registry.get("append").unwrap();
    auto appendResult = appendFn([
        Value.makeArray([Value.makeNumber(1)]),
        Value.makeNumber(2)
    ]);
    assert(appendResult.isOk);
    assert(appendResult.unwrap().asArray().length == 2);
    
    // range
    auto rangeFn = registry.get("range").unwrap();
    auto rangeResult = rangeFn([Value.makeNumber(0), Value.makeNumber(3)]);
    assert(rangeResult.isOk);
    auto rangeArr = rangeResult.unwrap().asArray();
    assert(rangeArr.length == 3);
    assert(rangeArr[0].asNumber() == 0);
    assert(rangeArr[2].asNumber() == 2);
}

/// Builtin type conversion functions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.builtins - Type conversions");
    
    auto registry = new BuiltinRegistry();
    
    // str
    auto strFn = registry.get("str").unwrap();
    auto strResult = strFn([Value.makeNumber(42)]);
    assert(strResult.isOk);
    assert(strResult.unwrap().asString() == "42");
    
    // int
    auto intFn = registry.get("int").unwrap();
    auto intResult = intFn([Value.makeString("123")]);
    assert(intResult.isOk);
    assert(intResult.unwrap().asNumber() == 123);
    
    // bool
    auto boolFn = registry.get("bool").unwrap();
    auto boolResult = boolFn([Value.makeString("x")]);
    assert(boolResult.isOk);
    assert(boolResult.unwrap().asBool() == true);
}

/// Builtin environment functions
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.builtins - Environment functions");
    
    auto registry = new BuiltinRegistry();
    
    // platform
    auto platformFn = registry.get("platform").unwrap();
    auto platformResult = platformFn([]);
    assert(platformResult.isOk);
    auto platform = platformResult.unwrap().asString();
    assert(platform == "linux" || platform == "darwin" || platform == "windows" || platform == "unknown");
    
    // arch
    auto archFn = registry.get("arch").unwrap();
    auto archResult = archFn([]);
    assert(archResult.isOk);
    auto arch = archResult.unwrap().asString();
    assert(arch == "x86_64" || arch == "arm64" || arch == "arm" || arch == "unknown");
    
    // env with default
    auto envFn = registry.get("env").unwrap();
    auto envResult = envFn([Value.makeString("NONEXISTENT_VAR_12345"), Value.makeString("default")]);
    assert(envResult.isOk);
    assert(envResult.unwrap().asString() == "default");
}

/// Evaluator binary operations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.evaluator - Binary operations");
    
    auto eval = new Evaluator();
    
    // Arithmetic
    auto addResult = eval.evaluateBinary("+", Value.makeNumber(2), Value.makeNumber(3));
    assert(addResult.isOk);
    assert(addResult.unwrap().asNumber() == 5);
    
    auto subResult = eval.evaluateBinary("-", Value.makeNumber(10), Value.makeNumber(4));
    assert(subResult.isOk);
    assert(subResult.unwrap().asNumber() == 6);
    
    auto mulResult = eval.evaluateBinary("*", Value.makeNumber(3), Value.makeNumber(4));
    assert(mulResult.isOk);
    assert(mulResult.unwrap().asNumber() == 12);
    
    auto divResult = eval.evaluateBinary("/", Value.makeNumber(10), Value.makeNumber(2));
    assert(divResult.isOk);
    assert(divResult.unwrap().asNumber() == 5);
    
    // String concatenation
    auto concatResult = eval.evaluateBinary("+", Value.makeString("hello"), Value.makeString(" world"));
    assert(concatResult.isOk);
    assert(concatResult.unwrap().asString() == "hello world");
    
    // Comparison
    auto eqResult = eval.evaluateBinary("==", Value.makeNumber(5), Value.makeNumber(5));
    assert(eqResult.isOk);
    assert(eqResult.unwrap().asBool() == true);
    
    auto ltResult = eval.evaluateBinary("<", Value.makeNumber(3), Value.makeNumber(5));
    assert(ltResult.isOk);
    assert(ltResult.unwrap().asBool() == true);
    
    // Logical
    auto andResult = eval.evaluateBinary("&&", Value.makeBool(true), Value.makeBool(false));
    assert(andResult.isOk);
    assert(andResult.unwrap().asBool() == false);
    
    auto orResult = eval.evaluateBinary("||", Value.makeBool(true), Value.makeBool(false));
    assert(orResult.isOk);
    assert(orResult.unwrap().asBool() == true);
}

/// Evaluator unary operations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.evaluator - Unary operations");
    
    auto eval = new Evaluator();
    
    // Negation
    auto negResult = eval.evaluateUnary("-", Value.makeNumber(5));
    assert(negResult.isOk);
    assert(negResult.unwrap().asNumber() == -5);
    
    // Logical not
    auto notResult = eval.evaluateUnary("!", Value.makeBool(true));
    assert(notResult.isOk);
    assert(notResult.unwrap().asBool() == false);
}

/// Evaluator array operations
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.evaluator - Array operations");
    
    auto eval = new Evaluator();
    
    auto arr = Value.makeArray([Value.makeNumber(10), Value.makeNumber(20), Value.makeNumber(30)]);
    
    // Index
    auto indexResult = eval.evaluateIndex(arr, Value.makeNumber(1));
    assert(indexResult.isOk);
    assert(indexResult.unwrap().asNumber() == 20);
    
    // Slice
    auto sliceResult = eval.evaluateSlice(arr, Value.makeNumber(0), Value.makeNumber(2));
    assert(sliceResult.isOk);
    assert(sliceResult.unwrap().asArray().length == 2);
}

/// Evaluator variable management
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.evaluator - Variable management");
    
    auto eval = new Evaluator();
    
    // Define variable
    auto defResult = eval.defineVariable("myVar", Value.makeString("test"), false);
    assert(defResult.isOk);
    
    // Lookup via identifier expression
    auto identExpr = new IdentExpr("myVar", Location("test", 1, 1));
    auto evalResult = eval.evaluate(identExpr);
    assert(evalResult.isOk);
    assert(evalResult.unwrap().asString() == "test");
}

/// Evaluator function calls
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.evaluator - Built-in function calls");
    
    auto eval = new Evaluator();
    
    // Call upper()
    auto result = eval.evaluateCall("upper", [Value.makeString("test")]);
    assert(result.isOk);
    assert(result.unwrap().asString() == "TEST");
    
    // Call len()
    auto lenResult = eval.evaluateCall("len", [Value.makeArray([Value.makeNumber(1), Value.makeNumber(2)])]);
    assert(lenResult.isOk);
    assert(lenResult.unwrap().asNumber() == 2);
}

/// Closure tests
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.types - Closure creation");
    
    // Create a simple closure
    Closure closure;
    closure.name = "add";
    closure.params = [Parameter("a", null), Parameter("b", null)];
    closure.body_ = [];
    closure.lambdaBody = null;
    
    assert(closure.arity() == 2);
    assert(closure.paramNames() == ["a", "b"]);
    assert(!closure.isLambda());
}

/// TargetConfig conversion
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.types - TargetConfig");
    
    TargetConfig config;
    config.type = "library";
    config.language = "python";
    config.sources = ["src/*.py"];
    config.deps = ["dep1"];
    
    // Convert to Value
    auto value = config.toValue();
    assert(value.isMap());
    auto map = value.asMap();
    assert(map["type"].asString() == "library");
    assert(map["language"].asString() == "python");
    
    // Convert back
    auto configResult = TargetConfig.fromValue(value);
    assert(configResult.isOk);
    auto restored = configResult.unwrap();
    assert(restored.type == "library");
    assert(restored.language == "python");
}

/// Interpreter basic execution
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.scripting.interpreter - Basic statement execution");
    
    auto interp = new Interpreter();
    
    // Empty program
    auto result = interp.execute([]);
    assert(result.isOk);
    assert(result.unwrap().length == 0);
}

/// Summary test
unittest
{
    writeln("\x1b[32m[PASS]\x1b[0m config.scripting - All tests passed");
}
