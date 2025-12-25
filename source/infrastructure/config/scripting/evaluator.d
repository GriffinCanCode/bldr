module infrastructure.config.scripting.evaluator;

import std.conv;
import std.algorithm;
import std.array;
import std.string;
import infrastructure.config.scripting.types;
import infrastructure.config.scripting.scopemanager;
import infrastructure.config.scripting.builtins;
import infrastructure.config.workspace.ast;
import infrastructure.errors;

alias Closure = infrastructure.config.scripting.types.Closure;
alias Stmt = infrastructure.config.workspace.ast.Stmt;
alias Parameter = infrastructure.config.workspace.ast.Parameter;

/// Expression evaluator with type checking
class Evaluator
{
    private ScopeManager scope_;
    private BuiltinRegistry builtins;
    private bool typeCheckOnly;  // If true, only check types without evaluation
    private Value returnValue;   // Return value from function execution
    private bool hasReturned;    // Flag for early return control flow
    
    this() @system
    {
        scope_ = new ScopeManager();
        builtins = new BuiltinRegistry();
        typeCheckOnly = false;
        returnValue = Value.makeNull();
        hasReturned = false;
        
        // Register this evaluator's closure invoker for builtins (filter/map)
        import infrastructure.config.scripting.builtins : setClosureInvoker;
        setClosureInvoker(&this.invokeClosure);
    }
    
    /// Get scope manager
    ScopeManager scopeManager() pure nothrow @nogc @safe
    {
        return scope_;
    }
    
    /// Evaluate expression value from AST
    Result!(Value, BuildError) evaluate(Expr expr) @system
    {
        // Handle all expression types from the unified AST
        if (auto lit = cast(LiteralExpr)expr)
        {
            return evaluateLiteral(lit.value);
        }
        else if (auto ident = cast(IdentExpr)expr)
        {
            return evaluateIdentifier(ident.name);
        }
        else if (auto bin = cast(BinaryExpr)expr)
        {
            auto leftResult = evaluate(bin.left);
            if (leftResult.isErr)
                return leftResult;
            
            auto rightResult = evaluate(bin.right);
            if (rightResult.isErr)
                return rightResult;
            
            return evaluateBinary(bin.op, leftResult.unwrap(), rightResult.unwrap());
        }
        else if (auto unary = cast(UnaryExpr)expr)
        {
            auto operandResult = evaluate(unary.operand);
            if (operandResult.isErr)
                return operandResult;
            
            return evaluateUnary(unary.op, operandResult.unwrap());
        }
        else if (auto call = cast(CallExpr)expr)
        {
            Value[] args;
            foreach (arg; call.args)
            {
                auto argResult = evaluate(arg);
                if (argResult.isErr)
                    return argResult;
                args ~= argResult.unwrap();
            }
            return evaluateCall(call.callee, args);
        }
        else if (auto index = cast(IndexExpr)expr)
        {
            auto objectResult = evaluate(index.object);
            if (objectResult.isErr)
                return objectResult;
            
            auto indexResult = evaluate(index.index);
            if (indexResult.isErr)
                return indexResult;
            
            return evaluateIndex(objectResult.unwrap(), indexResult.unwrap());
        }
        else if (auto slice = cast(SliceExpr)expr)
        {
            auto objectResult = evaluate(slice.object);
            if (objectResult.isErr)
                return objectResult;
            
            Value start = Value.makeNull();
            if (slice.start)
            {
                auto startResult = evaluate(slice.start);
                if (startResult.isErr)
                    return startResult;
                start = startResult.unwrap();
            }
            
            Value end = Value.makeNull();
            if (slice.end)
            {
                auto endResult = evaluate(slice.end);
                if (endResult.isErr)
                    return endResult;
                end = endResult.unwrap();
            }
            
            return evaluateSlice(objectResult.unwrap(), start, end);
        }
        else if (auto member = cast(MemberExpr)expr)
        {
            auto objectResult = evaluate(member.object);
            if (objectResult.isErr)
                return objectResult;
            
            return evaluateMapAccess(objectResult.unwrap(), member.member);
        }
        else if (auto ternary = cast(TernaryExpr)expr)
        {
            auto conditionResult = evaluate(ternary.condition);
            if (conditionResult.isErr)
                return conditionResult;
            
            if (conditionResult.unwrap().toBool())
                return evaluate(ternary.trueExpr);
            else
                return evaluate(ternary.falseExpr);
        }
        else if (auto lambda = cast(LambdaExpr)expr)
        {
            // Create closure capturing current environment
            Closure closure;
            closure.name = "";  // Anonymous
            closure.params = lambda.params.map!(p => Parameter(p, null)).array;
            closure.body_ = [];
            closure.lambdaBody = lambda.body;
            closure.capturedEnv = captureCurrentEnv();
            
            return ok(Value.makeFunction(closure));
        }
        
        return err("Unknown expression type: " ~ expr.nodeType());
    }
    
    /// Evaluate a Literal to a Value
    private Result!(Value, BuildError) evaluateLiteral(Literal lit) @system
    {
        final switch (lit.kind)
        {
            case LiteralKind.Null:
                return ok(Value.makeNull());
            case LiteralKind.Bool:
                return ok(Value.makeBool(lit.asBool()));
            case LiteralKind.Number:
                return ok(Value.makeNumber(cast(double)lit.asNumber()));
            case LiteralKind.String:
                return ok(Value.makeString(lit.asString()));
            case LiteralKind.Array:
                Value[] arr;
                foreach (elem; lit.asArray())
                {
                    auto elemResult = evaluateLiteral(elem);
                    if (elemResult.isErr)
                        return elemResult;
                    arr ~= elemResult.unwrap();
                }
                return ok(Value.makeArray(arr));
            case LiteralKind.Map:
                Value[string] map;
                foreach (key, value; lit.asMap())
                {
                    auto valueResult = evaluateLiteral(value);
                    if (valueResult.isErr)
                        return Result!(Value, BuildError).err(valueResult.unwrapErr());
                    map[key] = valueResult.unwrap();
                }
                return ok(Value.makeMap(map));
        }
    }
    
    /// Evaluate string with interpolation ${expr}
    private string evaluateStringInterpolation(string str) @system
    {
        import std.regex;
        
        // Pattern: ${...}
        auto pattern = regex(r"\$\{([^}]+)\}");
        
        string result = str;
        foreach (match; matchAll(str, pattern))
        {
            auto expr = match[1];
            
            // Parse and evaluate the expression
            // For now, just lookup as variable
            auto lookupResult = scope_.lookup(expr);
            if (lookupResult.isOk)
            {
                import std.array : replaceInPlace = replace;
                auto value = lookupResult.unwrap();
                result = replaceInPlace(result, match[0], value.toString());
            }
        }
        
        return result;
    }
    
    /// Evaluate identifier (variable lookup)
    private Result!(Value, BuildError) evaluateIdentifier(string name) @system
    {
        // Check if it's a boolean literal
        if (name == "true")
            return Result!(Value, BuildError).ok(Value.makeBool(true));
        if (name == "false")
            return Result!(Value, BuildError).ok(Value.makeBool(false));
        if (name == "null")
            return Result!(Value, BuildError).ok(Value.makeNull());
        
        // Lookup in scope
        return scope_.lookup(name);
    }
    
    /// Evaluate array
    private Result!(Value, BuildError) evaluateArray(Expr[] elements) @system
    {
        Value[] result;
        result.reserve(elements.length);
        
        foreach (elem; elements)
        {
            auto evalResult = evaluate(elem);
            if (evalResult.isErr)
                return evalResult;
            result ~= evalResult.unwrap();
        }
        
        return Result!(Value, BuildError).ok(Value.makeArray(result));
    }
    
    /// Evaluate map
    private Result!(Value, BuildError) evaluateMap(Expr[string] map) @system
    {
        Value[string] result;
        
        foreach (key, value; map)
        {
            auto evalResult = evaluate(value);
            if (evalResult.isErr)
                return Result!(Value, BuildError).err(evalResult.unwrapErr());
            result[key] = evalResult.unwrap();
        }
        
        return Result!(Value, BuildError).ok(Value.makeMap(result));
    }
    
    /// Evaluate binary operation
    Result!(Value, BuildError) evaluateBinary(string op, Value left, Value right) @system
    {
        switch (op)
        {
            // Arithmetic
            case "+":
                if (left.isNumber() && right.isNumber())
                    return ok(Value.makeNumber(left.asNumber() + right.asNumber()));
                else if (left.isString() && right.isString())
                    return ok(Value.makeString(left.asString() ~ right.asString()));
                else if (left.isArray() && right.isArray())
                    return ok(Value.makeArray(left.asArray() ~ right.asArray()));
                else
                    return err("Cannot add " ~ left.type().to!string ~ " and " ~ right.type().to!string);
            
            case "-":
                if (left.isNumber() && right.isNumber())
                    return ok(Value.makeNumber(left.asNumber() - right.asNumber()));
                else
                    return err("Cannot subtract non-numbers");
            
            case "*":
                if (left.isNumber() && right.isNumber())
                    return ok(Value.makeNumber(left.asNumber() * right.asNumber()));
                else
                    return err("Cannot multiply non-numbers");
            
            case "/":
                if (left.isNumber() && right.isNumber())
                {
                    if (right.asNumber() == 0.0)
                        return err("Division by zero");
                    return ok(Value.makeNumber(left.asNumber() / right.asNumber()));
                }
                else
                    return err("Cannot divide non-numbers");
            
            case "%":
                if (left.isNumber() && right.isNumber())
                {
                    if (right.asNumber() == 0.0)
                        return err("Modulo by zero");
                    return ok(Value.makeNumber(left.asNumber() % right.asNumber()));
                }
                else
                    return err("Cannot modulo non-numbers");
            
            // Comparison
            case "==":
                return ok(Value.makeBool(left == right));
            
            case "!=":
                return ok(Value.makeBool(left != right));
            
            case "<":
                if (left.isNumber() && right.isNumber())
                    return ok(Value.makeBool(left.asNumber() < right.asNumber()));
                else if (left.isString() && right.isString())
                    return ok(Value.makeBool(left.asString() < right.asString()));
                else
                    return err("Cannot compare non-comparable types");
            
            case "<=":
                if (left.isNumber() && right.isNumber())
                    return ok(Value.makeBool(left.asNumber() <= right.asNumber()));
                else if (left.isString() && right.isString())
                    return ok(Value.makeBool(left.asString() <= right.asString()));
                else
                    return err("Cannot compare non-comparable types");
            
            case ">":
                if (left.isNumber() && right.isNumber())
                    return ok(Value.makeBool(left.asNumber() > right.asNumber()));
                else if (left.isString() && right.isString())
                    return ok(Value.makeBool(left.asString() > right.asString()));
                else
                    return err("Cannot compare non-comparable types");
            
            case ">=":
                if (left.isNumber() && right.isNumber())
                    return ok(Value.makeBool(left.asNumber() >= right.asNumber()));
                else if (left.isString() && right.isString())
                    return ok(Value.makeBool(left.asString() >= right.asString()));
                else
                    return err("Cannot compare non-comparable types");
            
            // Logical
            case "&&":
                return ok(Value.makeBool(left.toBool() && right.toBool()));
            
            case "||":
                return ok(Value.makeBool(left.toBool() || right.toBool()));
            
            default:
                return err("Unknown binary operator: " ~ op);
        }
    }
    
    /// Evaluate unary operation
    Result!(Value, BuildError) evaluateUnary(string op, Value operand) @system
    {
        switch (op)
        {
            case "-":
                if (operand.isNumber())
                    return ok(Value.makeNumber(-operand.asNumber()));
                else
                    return err("Cannot negate non-number");
            
            case "!":
                return ok(Value.makeBool(!operand.toBool()));
            
            default:
                return err("Unknown unary operator: " ~ op);
        }
    }
    
    /// Evaluate function call
    Result!(Value, BuildError) evaluateCall(string name, Value[] args) @system
    {
        // Check if it's a built-in function
        if (builtins.has(name))
        {
            auto fnResult = builtins.get(name);
            if (fnResult.isErr)
                return Result!(Value, BuildError).err(fnResult.unwrapErr());
            
            auto fn = fnResult.unwrap();
            return fn(args);
        }
        
        // Check if it's a user-defined function
        auto lookupResult = scope_.lookup(name);
        if (lookupResult.isErr)
        {
            auto error = new ParseError("Undefined function '" ~ name ~ "'", null);
            error.addSuggestion("Define function with 'fn " ~ name ~ "(...) { ... }'");
            error.addSuggestion("Or use a built-in function: " ~ builtins.functionNames().join(", "));
            return Result!(Value, BuildError).err(error);
        }
        
        auto fnValue = lookupResult.unwrap();
        if (!fnValue.isFunction())
            return err("'" ~ name ~ "' is not callable");
        
        return invokeClosure(fnValue.asClosure(), args);
    }
    
    /// Invoke a closure with arguments, setting up proper scope
    Result!(Value, BuildError) invokeClosure(Closure closure, Value[] args) @system
    {
        // Validate argument count
        if (args.length < closure.arity())
        {
            size_t required = 0;
            foreach (p; closure.params)
                if (!p.hasDefault()) required++;
            
            if (args.length < required)
                return err("Function '" ~ closure.name ~ "' expects " ~ required.to!string ~ 
                          " arguments, got " ~ args.length.to!string);
        }
        
        // Enter function scope with captured environment
        scope_.enterScope();
        scope(exit) scope_.exitScope();
        
        // Restore captured closure environment
        foreach (name, value; closure.capturedEnv)
            scope_.define(name, value, true);
        
        // Bind parameters
        foreach (i, param; closure.params)
        {
            Value argValue = (i < args.length) ? args[i] 
                : (param.hasDefault() ? evaluate(param.defaultValue).unwrap() : Value.makeNull());
            auto defResult = scope_.define(param.name, argValue, false);
            if (defResult.isErr)
                return Result!(Value, BuildError).err(defResult.unwrapErr());
        }
        
        // Handle lambda (single expression body)
        if (closure.isLambda())
            return evaluate(closure.lambdaBody);
        
        // Execute function body statements
        returnValue = Value.makeNull();
        hasReturned = false;
        
        foreach (stmt; closure.body_)
        {
            auto result = executeStmt(stmt);
            if (result.isErr)
                return Result!(Value, BuildError).err(result.unwrapErr());
            if (hasReturned)
                break;
        }
        
        return ok(returnValue);
    }
    
    /// Execute statement (for function body execution)
    private Result!BuildError executeStmt(Stmt stmt) @system
    {
        import infrastructure.config.workspace.ast : ReturnStmt, VarDeclStmt, ExprStmt, 
            IfStmt, ForStmt, BlockStmt;
        
        if (auto ret = cast(ReturnStmt)stmt)
        {
            if (ret.value)
            {
                auto result = evaluate(ret.value);
                if (result.isErr)
                    return Result!BuildError.err(result.unwrapErr());
                returnValue = result.unwrap();
            }
            hasReturned = true;
            return Result!BuildError.ok();
        }
        else if (auto varDecl = cast(VarDeclStmt)stmt)
        {
            auto valResult = evaluate(varDecl.initializer);
            if (valResult.isErr)
                return Result!BuildError.err(valResult.unwrapErr());
            return scope_.define(varDecl.name, valResult.unwrap(), varDecl.isConst);
        }
        else if (auto exprStmt = cast(ExprStmt)stmt)
        {
            auto result = evaluate(exprStmt.expr);
            if (result.isErr)
                return Result!BuildError.err(result.unwrapErr());
            return Result!BuildError.ok();
        }
        else if (auto ifStmt = cast(IfStmt)stmt)
        {
            auto condResult = evaluate(ifStmt.condition);
            if (condResult.isErr)
                return Result!BuildError.err(condResult.unwrapErr());
            
            auto branch = condResult.unwrap().toBool() ? ifStmt.thenBranch : ifStmt.elseBranch;
            foreach (s; branch)
            {
                auto r = executeStmt(s);
                if (r.isErr) return r;
                if (hasReturned) break;
            }
            return Result!BuildError.ok();
        }
        else if (auto forStmt = cast(ForStmt)stmt)
        {
            auto iterResult = evaluate(forStmt.iterable);
            if (iterResult.isErr)
                return Result!BuildError.err(iterResult.unwrapErr());
            
            if (!iterResult.unwrap().isArray())
                return Result!BuildError.err(new ParseError("For loop requires array", null));
            
            scope_.enterScope();
            scope(exit) scope_.exitScope();
            
            foreach (elem; iterResult.unwrap().asArray())
            {
                scope_.define(forStmt.variable, elem, false);
                foreach (s; forStmt.body)
                {
                    auto r = executeStmt(s);
                    if (r.isErr) return r;
                    if (hasReturned) break;
                }
                if (hasReturned) break;
            }
            return Result!BuildError.ok();
        }
        else if (auto block = cast(BlockStmt)stmt)
        {
            scope_.enterScope();
            scope(exit) scope_.exitScope();
            foreach (s; block.stmts)
            {
                auto r = executeStmt(s);
                if (r.isErr) return r;
                if (hasReturned) break;
            }
            return Result!BuildError.ok();
        }
        
        return Result!BuildError.ok();
    }
    
    /// Evaluate array indexing
    Result!(Value, BuildError) evaluateIndex(Value array, Value index) @system
    {
        if (!array.isArray())
            return err("Can only index arrays");
        
        if (!index.isNumber())
            return err("Array index must be a number");
        
        auto arr = array.asArray();
        auto idx = cast(size_t)index.asNumber();
        
        if (idx >= arr.length)
            return err("Array index " ~ idx.to!string ~ " out of bounds (length: " ~ arr.length.to!string ~ ")");
        
        return ok(arr[idx]);
    }
    
    /// Evaluate array slicing [start:end]
    Result!(Value, BuildError) evaluateSlice(Value array, Value start, Value end) @system
    {
        if (!array.isArray())
            return err("Can only slice arrays");
        
        auto arr = array.asArray();
        size_t startIdx = 0;
        size_t endIdx = arr.length;
        
        if (!start.isNull())
        {
            if (!start.isNumber())
                return err("Slice start must be a number");
            startIdx = cast(size_t)start.asNumber();
        }
        
        if (!end.isNull())
        {
            if (!end.isNumber())
                return err("Slice end must be a number");
            endIdx = cast(size_t)end.asNumber();
        }
        
        if (startIdx > endIdx || endIdx > arr.length)
            return err("Invalid slice range");
        
        return ok(Value.makeArray(arr[startIdx .. endIdx]));
    }
    
    /// Evaluate map access
    Result!(Value, BuildError) evaluateMapAccess(Value map, string key) @system
    {
        if (!map.isMap())
            return err("Can only access maps with []");
        
        auto m = map.asMap();
        if (key !in m)
            return err("Map key '" ~ key ~ "' not found");
        
        return ok(m[key]);
    }
    
    /// Evaluate ternary operator: condition ? trueExpr : falseExpr
    Result!(Value, BuildError) evaluateTernary(Value condition, Value trueVal, Value falseVal) @system
    {
        if (condition.toBool())
            return ok(trueVal);
        else
            return ok(falseVal);
    }
    
    /// Define variable (let or const)
    Result!BuildError defineVariable(string name, Value value, bool isConst) @system
    {
        return scope_.define(name, value, isConst);
    }
    
    /// Assign to variable
    Result!BuildError assignVariable(string name, Value value) @system
    {
        return scope_.assign(name, value);
    }
    
    /// Enter new scope
    void enterScope() pure nothrow @safe
    {
        scope_.enterScope();
    }
    
    /// Exit scope
    void exitScope() @trusted
    {
        scope_.exitScope();
    }
    
    /// Get type information for expression (without evaluation)
    Result!(ScriptTypeInfo, BuildError) inferType(Expr expr) @system
    {
        // Comprehensive type inference for all expression types
        if (auto lit = cast(LiteralExpr)expr)
        {
            return inferLiteralType(lit.value);
        }
        else if (auto ident = cast(IdentExpr)expr)
        {
            // Lookup identifier type in scope
            auto lookupResult = scope_.lookup(ident.name);
            if (lookupResult.isOk)
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(lookupResult.unwrap().type()));
            return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Null));
        }
        else if (auto bin = cast(BinaryExpr)expr)
        {
            // Infer binary expression result type
            auto leftResult = inferType(bin.left);
            if (leftResult.isErr)
                return leftResult;
            
            auto rightResult = inferType(bin.right);
            if (rightResult.isErr)
                return rightResult;
            
            // Most binary ops preserve numeric/string types
            if (bin.op == "+" || bin.op == "-" || bin.op == "*" || bin.op == "/" || bin.op == "%")
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Number));
            else if (bin.op == "==" || bin.op == "!=" || bin.op == "<" || bin.op == ">" || 
                     bin.op == "<=" || bin.op == ">=" || bin.op == "&&" || bin.op == "||")
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Bool));
            
            return leftResult;
        }
        else if (auto unary = cast(UnaryExpr)expr)
        {
            if (unary.op == "!")
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Bool));
            else if (unary.op == "-")
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Number));
            
            return inferType(unary.operand);
        }
        else if (auto call = cast(CallExpr)expr)
        {
            // Function calls - would need function signature registry for proper inference
            // For now, assume returns null
            return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Null));
        }
        else if (auto index = cast(IndexExpr)expr)
        {
            // Array indexing - return element type (unknown for now)
            return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Null));
        }
        else if (auto slice = cast(SliceExpr)expr)
        {
            // Slicing returns array
            return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Array));
        }
        else if (auto member = cast(MemberExpr)expr)
        {
            // Member access - type depends on object structure
            return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Null));
        }
        else if (auto ternary = cast(TernaryExpr)expr)
        {
            // Ternary returns type of branches (assume true branch)
            return inferType(ternary.trueExpr);
        }
        else if (auto lambda = cast(LambdaExpr)expr)
        {
            return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Function));
        }
        
        return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Null));
    }
    
    /// Infer type of a Literal
    private Result!(ScriptTypeInfo, BuildError) inferLiteralType(Literal lit) @system
    {
        final switch (lit.kind)
        {
            case LiteralKind.Null:
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Null));
            case LiteralKind.Bool:
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Bool));
            case LiteralKind.Number:
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Number));
            case LiteralKind.String:
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.String));
            case LiteralKind.Array:
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Array));
            case LiteralKind.Map:
                return Result!(ScriptTypeInfo, BuildError).ok(ScriptTypeInfo.simple(ValueType.Map));
        }
    }
    
    /// Capture current scope for closures
    private Value[string] captureCurrentEnv() @system
    {
        Value[string] env;
        foreach (name; scope_.definedNames())
        {
            auto lookupResult = scope_.lookup(name);
            if (lookupResult.isOk)
                env[name] = lookupResult.unwrap();
        }
        return env;
    }
    
    // Helper methods
    
    private Result!(Value, BuildError) ok(Value v) @system
    {
        return Result!(Value, BuildError).ok(v);
    }
    
    private Result!(Value, BuildError) err(string msg) @system
    {
        auto error = new ParseError(msg, null);
        return Result!(Value, BuildError).err(error);
    }
}

