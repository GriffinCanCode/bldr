module infrastructure.config.scripting.builtins;

import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.path;
import std.file;
import std.process : environment;
import std.range;
import infrastructure.config.scripting.types;
import infrastructure.utils.files.glob;
import infrastructure.errors;

/// Closure invoker delegate for higher-order functions
alias ClosureInvoker = BuildResult!Value delegate(Closure, Value[]) @system;

/// Module-level evaluator context for closure invocation in builtins
private ClosureInvoker closureInvoker_;

/// Set the closure invoker (called by Evaluator on init)
void setClosureInvoker(ClosureInvoker invoker) @system
{
    closureInvoker_ = invoker;
}

/// Invoke a closure with arguments (used by filter/map)
private BuildResult!Value invokeClosure(Closure closure, Value[] args) @system
{
    if (closureInvoker_ is null)
        return err("Closure invoker not initialized");
    return closureInvoker_(closure, args);
}

/// Built-in function registry
class BuiltinRegistry
{
    private BuiltinFunction[string] functions;
    private FunctionSignature[string] signatures;
    
    this() @system
    {
        registerStandardLibrary();
    }
    
    /// Register standard library functions
    private void registerStandardLibrary() @system
    {
        // String operations
        register("upper", &builtinUpper, ["str"], [ValueType.String], ValueType.String);
        register("lower", &builtinLower, ["str"], [ValueType.String], ValueType.String);
        register("trim", &builtinTrim, ["str"], [ValueType.String], ValueType.String);
        register("split", &builtinSplit, ["str", "sep"], [ValueType.String, ValueType.String], ValueType.Array);
        register("join", &builtinJoin, ["arr", "sep"], [ValueType.Array, ValueType.String], ValueType.String);
        register("replace", &builtinReplace, ["str", "old", "new"], 
                 [ValueType.String, ValueType.String, ValueType.String], ValueType.String);
        register("startsWith", &builtinStartsWith, ["str", "prefix"], 
                 [ValueType.String, ValueType.String], ValueType.Bool);
        register("endsWith", &builtinEndsWith, ["str", "suffix"], 
                 [ValueType.String, ValueType.String], ValueType.Bool);
        register("contains", &builtinContains, ["str", "substr"], 
                 [ValueType.String, ValueType.String], ValueType.Bool);
        
        // Array operations
        register("len", &builtinLen, ["collection"], [ValueType.Array], ValueType.Number);
        register("append", &builtinAppend, ["arr", "elem"], [ValueType.Array, ValueType.Null], ValueType.Array);
        register("filter", &builtinFilter, ["arr", "fn"], [ValueType.Array, ValueType.Function], ValueType.Array);
        register("map", &builtinMap, ["arr", "fn"], [ValueType.Array, ValueType.Function], ValueType.Array);
        register("range", &builtinRange, ["start", "end"], [ValueType.Number, ValueType.Number], ValueType.Array);
        
        // Type conversions
        register("str", &builtinStr, ["value"], [ValueType.Null], ValueType.String);
        register("int", &builtinInt, ["value"], [ValueType.Null], ValueType.Number);
        register("bool", &builtinBool, ["value"], [ValueType.Null], ValueType.Bool);
        
        // File operations
        register("glob", &builtinGlob, ["pattern"], [ValueType.String], ValueType.Array);
        register("fileExists", &builtinFileExists, ["path"], [ValueType.String], ValueType.Bool);
        register("readFile", &builtinReadFile, ["path"], [ValueType.String], ValueType.String);
        register("basename", &builtinBasename, ["path"], [ValueType.String], ValueType.String);
        register("dirname", &builtinDirname, ["path"], [ValueType.String], ValueType.String);
        register("stripExtension", &builtinStripExtension, ["path"], [ValueType.String], ValueType.String);
        
        // Environment
        register("env", &builtinEnv, ["name", "default"], 
                 [ValueType.String, ValueType.String], ValueType.String);
        register("platform", &builtinPlatform, [], [], ValueType.String);
        register("arch", &builtinArch, [], [], ValueType.String);
    }
    
    /// Register function
    private void register(
        string name,
        BuiltinFunction fn,
        string[] paramNames,
        ValueType[] paramTypes,
        ValueType returnType
    ) @system
    {
        functions[name] = fn;
        
        FunctionSignature sig;
        sig.name = name;
        sig.paramNames = paramNames;
        sig.paramTypes = paramTypes;
        sig.returnType = returnType;
        sig.isVariadic = false;
        signatures[name] = sig;
    }
    
    /// Check if function exists
    bool has(string name) const pure nothrow @trusted
    {
        return (name in functions) !is null;
    }
    
    /// Get function
    BuildResult!BuiltinFunction get(string name) @trusted
    {
        if (name !in functions)
        {
            return BuildResult!BuiltinFunction.err(
                Errors.parse("", "Undefined function '" ~ name ~ "'")
                    .withSuggestion("Check function name spelling")
                    .withSuggestion("Use one of the built-in functions: " ~ functions.keys.join(", "))
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        return BuildResult!BuiltinFunction.ok(functions[name]);
    }
    
    /// Get signature
    BuildResult!FunctionSignature getSignature(string name) @trusted
    {
        if (name !in signatures)
        {
            return BuildResult!FunctionSignature.err(
                Errors.parse("", "Undefined function '" ~ name ~ "'")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        return BuildResult!FunctionSignature.ok(signatures[name]);
    }
    
    /// List all function names
    string[] functionNames() const @trusted
    {
        return functions.keys;
    }
}

// String operations

private BuildResult!Value builtinUpper(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("upper() expects 1 string argument");
    return ok(Value.makeString(args[0].asString().toUpper()));
}

private BuildResult!Value builtinLower(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("lower() expects 1 string argument");
    return ok(Value.makeString(args[0].asString().toLower()));
}

private BuildResult!Value builtinTrim(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("trim() expects 1 string argument");
    return ok(Value.makeString(args[0].asString().strip()));
}

private BuildResult!Value builtinSplit(Value[] args) @system
{
    if (args.length != 2 || !args[0].isString() || !args[1].isString())
        return err("split() expects 2 string arguments");
    
    auto parts = args[0].asString().split(args[1].asString());
    auto result = parts.map!(p => Value.makeString(p)).array;
    return ok(Value.makeArray(result));
}

private BuildResult!Value builtinJoin(Value[] args) @system
{
    if (args.length != 2 || !args[0].isArray() || !args[1].isString())
        return err("join() expects array and string arguments");
    
    auto arr = args[0].asArray();
    auto sep = args[1].asString();
    auto strings = arr.map!(v => v.toString()).array;
    return ok(Value.makeString(strings.join(sep)));
}

private BuildResult!Value builtinReplace(Value[] args) @system
{
    if (args.length != 3 || !args[0].isString() || !args[1].isString() || !args[2].isString())
        return err("replace() expects 3 string arguments");
    
    auto result = args[0].asString().replace(args[1].asString(), args[2].asString());
    return ok(Value.makeString(result));
}

private BuildResult!Value builtinStartsWith(Value[] args) @system
{
    if (args.length != 2 || !args[0].isString() || !args[1].isString())
        return err("startsWith() expects 2 string arguments");
    
    auto result = args[0].asString().startsWith(args[1].asString());
    return ok(Value.makeBool(result));
}

private BuildResult!Value builtinEndsWith(Value[] args) @system
{
    if (args.length != 2 || !args[0].isString() || !args[1].isString())
        return err("endsWith() expects 2 string arguments");
    
    auto result = args[0].asString().endsWith(args[1].asString());
    return ok(Value.makeBool(result));
}

private BuildResult!Value builtinContains(Value[] args) @system
{
    if (args.length != 2 || !args[0].isString() || !args[1].isString())
        return err("contains() expects 2 string arguments");
    
    auto result = args[0].asString().canFind(args[1].asString());
    return ok(Value.makeBool(result));
}

// Array operations

private BuildResult!Value builtinLen(Value[] args) @system
{
    if (args.length != 1)
        return err("len() expects 1 argument");
    
    if (args[0].isArray())
        return ok(Value.makeNumber(args[0].asArray().length));
    else if (args[0].isString())
        return ok(Value.makeNumber(args[0].asString().length));
    else if (args[0].isMap())
        return ok(Value.makeNumber(args[0].asMap().length));
    else
        return err("len() expects array, string, or map");
}

private BuildResult!Value builtinAppend(Value[] args) @system
{
    if (args.length != 2 || !args[0].isArray())
        return err("append() expects array and element");
    
    auto arr = args[0].asArray().dup;
    arr ~= args[1];
    return ok(Value.makeArray(arr));
}

private BuildResult!Value builtinFilter(Value[] args) @system
{
    if (args.length != 2)
        return err("filter() expects 2 arguments: array and predicate");
    
    if (!args[0].isArray())
        return err("filter() expects an array as first argument");
    
    auto arr = args[0].asArray();
    Value[] filtered;
    
    // Handle closure/lambda predicate
    if (args[1].isFunction())
    {
        auto closure = args[1].asClosure();
        foreach (elem; arr)
        {
            auto result = invokeClosure(closure, [elem]);
            if (result.isErr)
                return result;
            if (result.unwrap().toBool())
                filtered ~= elem;
        }
    }
    // Handle string expression predicate (legacy support)
    else if (args[1].isString())
    {
        immutable predicateExpr = args[1].asString();
        foreach (elem; arr)
        {
            auto evalResult = evaluatePredicateExpression(predicateExpr, elem);
            if (evalResult.isErr)
                return evalResult;
            if (evalResult.unwrap().toBool())
                filtered ~= elem;
        }
    }
    else
    {
        return err("filter() expects a function or string expression as predicate");
    }
    
    return ok(Value.makeArray(filtered));
}

private BuildResult!Value builtinMap(Value[] args) @system
{
    if (args.length != 2)
        return err("map() expects 2 arguments: array and transform function");
    
    if (!args[0].isArray())
        return err("map() expects an array as first argument");
    
    auto arr = args[0].asArray();
    Value[] mapped;
    
    // Handle closure/lambda transform
    if (args[1].isFunction())
    {
        auto closure = args[1].asClosure();
        foreach (elem; arr)
        {
            auto result = invokeClosure(closure, [elem]);
            if (result.isErr)
                return result;
            mapped ~= result.unwrap();
        }
    }
    // Handle string expression transform (legacy support)
    else if (args[1].isString())
    {
        immutable transformExpr = args[1].asString();
        foreach (elem; arr)
        {
            auto evalResult = evaluateTransformExpression(transformExpr, elem);
            if (evalResult.isErr)
                return evalResult;
            mapped ~= evalResult.unwrap();
        }
    }
    else
    {
        return err("map() expects a function or string expression as transform");
    }
    
    return ok(Value.makeArray(mapped));
}

/// Evaluate predicate expression with 'it' variable bound to element
private BuildResult!Value evaluatePredicateExpression(string expr, Value elem) @system
{
    import std.algorithm : canFind, startsWith, endsWith;
    import std.string : strip;
    
    immutable trimmedExpr = expr.strip();
    
    // Handle common patterns without full parser
    // Pattern: "it > N", "it < N", "it == value", etc.
    if (trimmedExpr.canFind("it"))
    {
        // Simple comparison operators
        if (trimmedExpr.canFind(">"))
        {
            auto parts = trimmedExpr.split(">");
            if (parts.length == 2 && parts[0].strip() == "it")
            {
                try
                {
                    immutable threshold = parts[1].strip().to!double;
                    if (elem.isNumber())
                        return ok(Value.makeBool(elem.asNumber() > threshold));
                }
                catch (Exception) {}
            }
        }
        else if (trimmedExpr.canFind("<"))
        {
            auto parts = trimmedExpr.split("<");
            if (parts.length == 2 && parts[0].strip() == "it")
            {
                try
                {
                    immutable threshold = parts[1].strip().to!double;
                    if (elem.isNumber())
                        return ok(Value.makeBool(elem.asNumber() < threshold));
                }
                catch (Exception) {}
            }
        }
        else if (trimmedExpr.canFind("=="))
        {
            auto parts = trimmedExpr.split("==");
            if (parts.length == 2 && parts[0].strip() == "it")
            {
                immutable compareStr = parts[1].strip();
                if (compareStr.startsWith("\"") && compareStr.endsWith("\""))
                {
                    immutable value = compareStr[1..$-1];
                    if (elem.isString())
                        return ok(Value.makeBool(elem.asString() == value));
                }
                else
                {
                    try
                    {
                        immutable value = compareStr.to!double;
                        if (elem.isNumber())
                            return ok(Value.makeBool(elem.asNumber() == value));
                    }
                    catch (Exception) {}
                }
            }
        }
        else if (trimmedExpr.canFind("!="))
        {
            auto parts = trimmedExpr.split("!=");
            if (parts.length == 2 && parts[0].strip() == "it")
            {
                immutable compareStr = parts[1].strip();
                if (compareStr.startsWith("\"") && compareStr.endsWith("\""))
                {
                    immutable value = compareStr[1..$-1];
                    if (elem.isString())
                        return ok(Value.makeBool(elem.asString() != value));
                }
                else
                {
                    try
                    {
                        immutable value = compareStr.to!double;
                        if (elem.isNumber())
                            return ok(Value.makeBool(elem.asNumber() != value));
                    }
                    catch (Exception) {}
                }
            }
        }
        // Pattern: "it.startsWith(X)", "it.endsWith(X)", "it.contains(X)"
        else if (trimmedExpr.canFind("startsWith"))
        {
            auto idx = trimmedExpr.indexOf("startsWith(");
            if (idx != -1)
            {
                auto endIdx = trimmedExpr.indexOf(")", idx);
                if (endIdx != -1)
                {
                    auto arg = trimmedExpr[idx+11..endIdx].strip();
                    if (arg.startsWith("\"") && arg.endsWith("\"") && elem.isString())
                    {
                        immutable prefix = arg[1..$-1];
                        return ok(Value.makeBool(elem.asString().startsWith(prefix)));
                    }
                }
            }
        }
        else if (trimmedExpr.canFind("endsWith"))
        {
            auto idx = trimmedExpr.indexOf("endsWith(");
            if (idx != -1)
            {
                auto endIdx = trimmedExpr.indexOf(")", idx);
                if (endIdx != -1)
                {
                    auto arg = trimmedExpr[idx+9..endIdx].strip();
                    if (arg.startsWith("\"") && arg.endsWith("\"") && elem.isString())
                    {
                        immutable suffix = arg[1..$-1];
                        return ok(Value.makeBool(elem.asString().endsWith(suffix)));
                    }
                }
            }
        }
        else if (trimmedExpr.canFind("contains"))
        {
            auto idx = trimmedExpr.indexOf("contains(");
            if (idx != -1)
            {
                auto endIdx = trimmedExpr.indexOf(")", idx);
                if (endIdx != -1)
                {
                    auto arg = trimmedExpr[idx+9..endIdx].strip();
                    if (arg.startsWith("\"") && arg.endsWith("\"") && elem.isString())
                    {
                        immutable substr = arg[1..$-1];
                        return ok(Value.makeBool(elem.asString().canFind(substr)));
                    }
                }
            }
        }
    }
    
    return err("Unsupported predicate expression: " ~ expr);
}

/// Evaluate transform expression with 'it' variable bound to element
private BuildResult!Value evaluateTransformExpression(string expr, Value elem) @system
{
    import std.algorithm : startsWith, endsWith;
    import std.string : strip, toUpper, toLower;
    
    immutable trimmedExpr = expr.strip();
    
    // Handle common patterns
    if (trimmedExpr.canFind("it"))
    {
        // Pattern: "it * 2", "it + 10", etc.
        if (trimmedExpr.canFind("*"))
        {
            auto parts = trimmedExpr.split("*");
            if (parts.length == 2 && parts[0].strip() == "it")
            {
                try
                {
                    immutable factor = parts[1].strip().to!double;
                    if (elem.isNumber())
                        return ok(Value.makeNumber(elem.asNumber() * factor));
                }
                catch (Exception) {}
            }
        }
        else if (trimmedExpr.canFind("+"))
        {
            auto parts = trimmedExpr.split("+");
            if (parts.length == 2 && parts[0].strip() == "it")
            {
                try
                {
                    immutable addend = parts[1].strip().to!double;
                    if (elem.isNumber())
                        return ok(Value.makeNumber(elem.asNumber() + addend));
                }
                catch (Exception) {}
            }
        }
        else if (trimmedExpr.canFind("-"))
        {
            auto parts = trimmedExpr.split("-");
            if (parts.length == 2 && parts[0].strip() == "it")
            {
                try
                {
                    immutable subtrahend = parts[1].strip().to!double;
                    if (elem.isNumber())
                        return ok(Value.makeNumber(elem.asNumber() - subtrahend));
                }
                catch (Exception) {}
            }
        }
        // Pattern: "it.upper()", "it.lower()", etc.
        else if (trimmedExpr == "it.upper()" || trimmedExpr == "it.toUpper()")
        {
            if (elem.isString())
                return ok(Value.makeString(elem.asString().toUpper()));
        }
        else if (trimmedExpr == "it.lower()" || trimmedExpr == "it.toLower()")
        {
            if (elem.isString())
                return ok(Value.makeString(elem.asString().toLower()));
        }
        else if (trimmedExpr == "it.trim()" || trimmedExpr == "it.strip()")
        {
            if (elem.isString())
                return ok(Value.makeString(elem.asString().strip()));
        }
        else if (trimmedExpr == "it")
        {
            // Identity transform
            return ok(elem);
        }
    }
    
    return err("Unsupported transform expression: " ~ expr);
}

private BuildResult!Value builtinRange(Value[] args) @system
{
    if (args.length != 2 || !args[0].isNumber() || !args[1].isNumber())
        return err("range() expects 2 number arguments");
    
    auto start = cast(int)args[0].asNumber();
    auto end = cast(int)args[1].asNumber();
    
    Value[] result;
    foreach (i; start .. end)
        result ~= Value.makeNumber(i);
    
    return ok(Value.makeArray(result));
}

// Type conversions

private BuildResult!Value builtinStr(Value[] args) @system
{
    if (args.length != 1)
        return err("str() expects 1 argument");
    return ok(Value.makeString(args[0].toString()));
}

private BuildResult!Value builtinInt(Value[] args) @system
{
    if (args.length != 1)
        return err("int() expects 1 argument");
    
    if (args[0].isNumber())
        return ok(Value.makeNumber(cast(int)args[0].asNumber()));
    else if (args[0].isString())
    {
        try
        {
            auto num = args[0].asString().to!int;
            return ok(Value.makeNumber(num));
        }
        catch (Exception e)
        {
            return err("Cannot convert '" ~ args[0].asString() ~ "' to int");
        }
    }
    else
        return err("int() expects number or string");
}

private BuildResult!Value builtinBool(Value[] args) @system
{
    if (args.length != 1)
        return err("bool() expects 1 argument");
    return ok(Value.makeBool(args[0].toBool()));
}

// File operations

private BuildResult!Value builtinGlob(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("glob() expects 1 string argument");
    
    try
    {
        auto pattern = args[0].asString();
        import infrastructure.utils.files.glob : GlobMatcher;
        import std.file : getcwd;
        auto files = GlobMatcher.match([pattern], getcwd());
        auto result = files.map!(f => Value.makeString(f)).array;
        return ok(Value.makeArray(result));
    }
    catch (Exception e)
    {
        return err("glob() failed: " ~ e.msg);
    }
}

private BuildResult!Value builtinFileExists(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("fileExists() expects 1 string argument");
    
    auto path = args[0].asString();
    auto exists = std.file.exists(path);
    return ok(Value.makeBool(exists));
}

private BuildResult!Value builtinReadFile(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("readFile() expects 1 string argument");
    
    try
    {
        auto path = args[0].asString();
        auto content = std.file.readText(path);
        return ok(Value.makeString(content));
    }
    catch (Exception e)
    {
        return err("readFile() failed: " ~ e.msg);
    }
}

private BuildResult!Value builtinBasename(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("basename() expects 1 string argument");
    
    auto result = baseName(args[0].asString());
    return ok(Value.makeString(result));
}

private BuildResult!Value builtinDirname(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("dirname() expects 1 string argument");
    
    auto result = dirName(args[0].asString());
    return ok(Value.makeString(result));
}

private BuildResult!Value builtinStripExtension(Value[] args) @system
{
    if (args.length != 1 || !args[0].isString())
        return err("stripExtension() expects 1 string argument");
    
    auto result = stripExtension(args[0].asString());
    return ok(Value.makeString(result));
}

// Environment

private BuildResult!Value builtinEnv(Value[] args) @system
{
    if (args.length < 1 || args.length > 2 || !args[0].isString())
        return err("env() expects 1-2 arguments (name, default)");
    
    auto name = args[0].asString();
    auto value = environment.get(name, null);
    
    if (value is null)
    {
        if (args.length == 2 && args[1].isString())
            value = args[1].asString();
        else
            value = "";
    }
    
    return ok(Value.makeString(value));
}

private BuildResult!Value builtinPlatform(Value[] args) @system
{
    if (args.length != 0)
        return err("platform() expects no arguments");
    
    version (linux)
        return ok(Value.makeString("linux"));
    else version (OSX)
        return ok(Value.makeString("darwin"));
    else version (Windows)
        return ok(Value.makeString("windows"));
    else
        return ok(Value.makeString("unknown"));
}

private BuildResult!Value builtinArch(Value[] args) @system
{
    if (args.length != 0)
        return err("arch() expects no arguments");
    
    version (X86_64)
        return ok(Value.makeString("x86_64"));
    else version (AArch64)
        return ok(Value.makeString("arm64"));
    else version (ARM)
        return ok(Value.makeString("arm"));
    else
        return ok(Value.makeString("unknown"));
}

// Helpers

private BuildResult!Value ok(Value v) @system
{
    return BuildResult!Value.ok(v);
}

private BuildResult!Value err(string msg) @system
{
    return BuildResult!Value.err(
        Errors.parse("", msg)
            .withLocation(__FILE__, __LINE__)
            .build()
    );
}

