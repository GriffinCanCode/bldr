module infrastructure.config.scripting.types;

import std.variant;
import std.conv;
import std.algorithm;
import std.array;
import infrastructure.errors;

/// Type of value in the scripting system
enum ValueType
{
    Null,
    Bool,
    Number,
    String,
    Array,
    Map,
    Function,
    Target
}

/// Forward declaration for AST types
import infrastructure.config.workspace.ast : Stmt, Expr, Parameter;

/// Closure captures lexical environment for first-class functions
struct Closure
{
    string name;                    // Function name (empty for lambdas)
    Parameter[] params;             // Parameter definitions
    Stmt[] body_;                   // Function body statements
    Expr lambdaBody;                // Lambda expression body (for single-expr lambdas)
    Value[string] capturedEnv;      // Captured lexical environment
    
    /// Check if this is a lambda (single expression body)
    bool isLambda() const pure nothrow @nogc @safe { return lambdaBody !is null; }
    
    /// Get parameter count
    size_t arity() const pure nothrow @nogc @safe { return params.length; }
    
    /// Get parameter names (lazy range)
    auto paramNames() const pure @safe
    {
        import std.algorithm : map;
        return params.map!(p => p.name);
    }
}

/// Runtime value with dynamic type
struct Value
{
    private ValueType type_;
    private Variant data_;
    
    /// Create null value
    static Value makeNull() @safe
    {
        Value v;
        v.type_ = ValueType.Null;
        return v;
    }
    
    /// Create bool value
    static Value makeBool(bool b) @trusted
    {
        Value v;
        v.type_ = ValueType.Bool;
        v.data_ = b;
        return v;
    }
    
    /// Create number value
    static Value makeNumber(double n) @trusted
    {
        Value v;
        v.type_ = ValueType.Number;
        v.data_ = n;
        return v;
    }
    
    /// Create string value
    static Value makeString(string s) @trusted
    {
        Value v;
        v.type_ = ValueType.String;
        v.data_ = s;
        return v;
    }
    
    /// Create array value
    static Value makeArray(Value[] arr) @trusted
    {
        Value v;
        v.type_ = ValueType.Array;
        v.data_ = arr;
        return v;
    }
    
    /// Create map value
    static Value makeMap(Value[string] map) @trusted
    {
        Value v;
        v.type_ = ValueType.Map;
        v.data_ = map;
        return v;
    }
    
    /// Create target config value
    static Value makeTarget(TargetConfig config) @trusted
    {
        Value v;
        v.type_ = ValueType.Target;
        v.data_ = config;
        return v;
    }
    
    /// Create function/closure value (first-class functions)
    static Value makeFunction(Closure closure) @trusted
    {
        Value v;
        v.type_ = ValueType.Function;
        v.data_ = closure;
        return v;
    }
    
    /// Get type
    ValueType type() const pure nothrow @nogc @safe
    {
        return type_;
    }
    
    /// Check if null
    bool isNull() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.Null;
    }
    
    /// Check if bool
    bool isBool() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.Bool;
    }
    
    /// Check if number
    bool isNumber() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.Number;
    }
    
    /// Check if string
    bool isString() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.String;
    }
    
    /// Check if array
    bool isArray() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.Array;
    }
    
    /// Check if map
    bool isMap() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.Map;
    }
    
    /// Check if target
    bool isTarget() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.Target;
    }
    
    /// Check if function/closure
    bool isFunction() const pure nothrow @nogc @safe
    {
        return type_ == ValueType.Function;
    }
    
    /// Get as bool (throws if not bool)
    bool asBool() const @trusted
    {
        if (!isBool())
            throw new Exception("Value is not a bool");
        return data_.get!bool;
    }
    
    /// Get as number (throws if not number)
    double asNumber() const @trusted
    {
        if (!isNumber())
            throw new Exception("Value is not a number");
        return data_.get!double;
    }
    
    /// Get as string (throws if not string)
    string asString() const @trusted
    {
        if (!isString())
            throw new Exception("Value is not a string");
        return data_.get!string;
    }
    
    /// Get as array (throws if not array)
    Value[] asArray() const @trusted
    {
        if (!isArray())
            throw new Exception("Value is not an array");
        return cast(Value[])data_.get!(Value[]);
    }
    
    /// Get as map (throws if not map)
    Value[string] asMap() const @trusted
    {
        if (!isMap())
            throw new Exception("Value is not a map");
        return cast(Value[string])data_.get!(Value[string]);
    }
    
    /// Get as target (throws if not target)
    TargetConfig asTarget() const @trusted
    {
        if (!isTarget())
            throw new Exception("Value is not a target");
        return cast(TargetConfig)data_.get!TargetConfig;
    }
    
    /// Get as closure (throws if not function)
    Closure asClosure() const @trusted
    {
        if (!isFunction())
            throw new Exception("Value is not a function");
        return cast(Closure)data_.get!Closure;
    }
    
    /// Convert to bool (truthiness)
    bool toBool() const @trusted
    {
        switch (type_)
        {
            case ValueType.Null:
                return false;
            case ValueType.Bool:
                return asBool();
            case ValueType.Number:
                return asNumber() != 0.0;
            case ValueType.String:
                return asString().length > 0;
            case ValueType.Array:
                return asArray().length > 0;
            case ValueType.Map:
                return asMap().length > 0;
            case ValueType.Function:
            case ValueType.Target:
                return true;
            default:
                return false;
        }
    }
    
    /// Convert to string representation
    string toString() const @trusted
    {
        switch (type_)
        {
            case ValueType.Null:
                return "null";
            case ValueType.Bool:
                return asBool() ? "true" : "false";
            case ValueType.Number:
                return asNumber().to!string;
            case ValueType.String:
                return asString();
            case ValueType.Array:
                return "[" ~ asArray().map!(v => v.toString()).join(", ") ~ "]";
            case ValueType.Map:
                string[] pairs;
                foreach (k, v; asMap())
                    pairs ~= k ~ ": " ~ v.toString();
                return "{" ~ pairs.join(", ") ~ "}";
            case ValueType.Target:
                return "<target>";
            case ValueType.Function:
                auto closure = asClosure();
                return closure.name.length ? "<fn " ~ closure.name ~ ">" : "<lambda>";
            default:
                return "<unknown>";
        }
    }
    
    /// Equality comparison
    bool opEquals(const Value other) const @trusted
    {
        if (type_ != other.type_)
            return false;
        
        switch (type_)
        {
            case ValueType.Null:
                return true;
            case ValueType.Bool:
                return asBool() == other.asBool();
            case ValueType.Number:
                return asNumber() == other.asNumber();
            case ValueType.String:
                return asString() == other.asString();
            case ValueType.Array:
                auto a1 = asArray();
                auto a2 = other.asArray();
                if (a1.length != a2.length)
                    return false;
                foreach (i; 0 .. a1.length)
                    if (a1[i] != a2[i])
                        return false;
                return true;
            case ValueType.Map:
                auto m1 = asMap();
                auto m2 = other.asMap();
                if (m1.length != m2.length)
                    return false;
                foreach (k, v; m1)
                    if (k !in m2 || m2[k] != v)
                        return false;
                return true;
            default:
                return false;
        }
    }
}

/// Target configuration (build target definition)
struct TargetConfig
{
    string type;
    string language;
    string[] sources;
    string[] deps;
    string[] flags;
    string[string] env;
    string output;
    string[string] config;
    
    /// Convert to Value map representation
    Value toValue() const @trusted
    {
        Value[string] map;
        map["type"] = Value.makeString(type);
        if (language.length > 0)
            map["language"] = Value.makeString(language);
        if (sources.length > 0)
            map["sources"] = Value.makeArray(sources.map!(s => Value.makeString(s)).array);
        if (deps.length > 0)
            map["deps"] = Value.makeArray(deps.map!(d => Value.makeString(d)).array);
        if (flags.length > 0)
            map["flags"] = Value.makeArray(flags.map!(f => Value.makeString(f)).array);
        if (env.length > 0)
        {
            Value[string] envMap;
            foreach (k, v; env)
                envMap[k] = Value.makeString(v);
            map["env"] = Value.makeMap(envMap);
        }
        if (output.length > 0)
            map["output"] = Value.makeString(output);
        if (config.length > 0)
        {
            Value[string] configMap;
            foreach (k, v; config)
                configMap[k] = Value.makeString(v);
            map["config"] = Value.makeMap(configMap);
        }
        return Value.makeMap(map);
    }
    
    /// Create from Value map representation
    static BuildResult!TargetConfig fromValue(Value v) @trusted
    {
        if (!v.isMap())
        {
            return BuildResult!TargetConfig.err(
                Errors.parse("", "Target configuration must be a map")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        TargetConfig config;
        auto map = v.asMap();
        
        // Required: type
        if ("type" !in map)
        {
            return BuildResult!TargetConfig.err(
                Errors.parse("", "Target must have 'type' field")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        config.type = map["type"].asString();
        
        // Optional fields
        if ("language" in map && map["language"].isString())
            config.language = map["language"].asString();
        
        if ("sources" in map && map["sources"].isArray())
            config.sources = map["sources"].asArray().map!(v => v.asString()).array;
        
        if ("deps" in map && map["deps"].isArray())
            config.deps = map["deps"].asArray().map!(v => v.asString()).array;
        
        if ("flags" in map && map["flags"].isArray())
            config.flags = map["flags"].asArray().map!(v => v.asString()).array;
        
        if ("env" in map && map["env"].isMap())
        {
            foreach (k, val; map["env"].asMap())
                config.env[k] = val.asString();
        }
        
        if ("output" in map && map["output"].isString())
            config.output = map["output"].asString();
        
        if ("config" in map && map["config"].isMap())
        {
            foreach (k, val; map["config"].asMap())
                config.config[k] = val.asString();
        }
        
        return BuildResult!TargetConfig.ok(config);
    }
}

/// Function signature for type checking
struct FunctionSignature
{
    string name;
    string[] paramNames;
    ValueType[] paramTypes;
    ValueType returnType;
    bool isVariadic;
    
    /// Check if call is valid
    bool isValidCall(size_t argCount) const pure nothrow @nogc @safe
    {
        if (isVariadic)
            return argCount >= paramNames.length;
        return argCount == paramNames.length;
    }
}

/// Built-in function type
alias BuiltinFunction = BuildResult!Value function(Value[] args) @system;

/// Type information for expressions
struct ScriptTypeInfo
{
    ValueType valueType;
    ScriptTypeInfo[] elementTypes;  // For array elements
    ScriptTypeInfo[string] fieldTypes;  // For map fields
    
    /// Create simple type
    static ScriptTypeInfo simple(ValueType type) pure nothrow @safe
    {
        ScriptTypeInfo info;
        info.valueType = type;
        return info;
    }
    
    /// Create array type
    static ScriptTypeInfo array(ValueType elementType) pure nothrow @safe
    {
        ScriptTypeInfo info;
        info.valueType = ValueType.Array;
        info.elementTypes = [ScriptTypeInfo.simple(elementType)];
        return info;
    }
    
    /// Create map type
    static ScriptTypeInfo map(ValueType keyType, ValueType valueType) pure nothrow @safe
    {
        ScriptTypeInfo info;
        info.valueType = ValueType.Map;
        // Store key and value types in elementTypes for simplicity
        info.elementTypes = [ScriptTypeInfo.simple(keyType), ScriptTypeInfo.simple(valueType)];
        return info;
    }
    
    /// Check if type is compatible with another
    bool isCompatibleWith(const ScriptTypeInfo other) const pure nothrow @safe
    {
        if (valueType == ValueType.Null || other.valueType == ValueType.Null)
            return true;  // Null is compatible with everything
        
        return valueType == other.valueType;
    }
    
    /// Get type name for error messages
    string typeName() const pure nothrow @safe
    {
        final switch (valueType)
        {
            case ValueType.Null: return "null";
            case ValueType.Bool: return "bool";
            case ValueType.Number: return "number";
            case ValueType.String: return "string";
            case ValueType.Array: return "array";
            case ValueType.Map: return "map";
            case ValueType.Function: return "function";
            case ValueType.Target: return "target";
        }
    }
}

