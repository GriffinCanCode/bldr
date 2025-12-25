module infrastructure.config.scripting.interpreter;

import std.array;
import std.algorithm;
import std.conv;
import infrastructure.config.scripting.types;
import infrastructure.config.scripting.evaluator;
import infrastructure.config.scripting.expander;
import infrastructure.config.workspace.ast;
import infrastructure.errors;

// Need Closure from types for first-class functions
alias Closure = infrastructure.config.scripting.types.Closure;

/// Statement interpreter that executes Tier 1 programmability features
/// 
/// This interpreter:
/// - Executes variable declarations (let, const)
/// - Evaluates expressions using the Evaluator
/// - Executes control flow (if, for)
/// - Handles function and macro definitions
/// - Returns generated targets
class Interpreter
{
    private Evaluator evaluator;
    private MacroExpander expander;
    private TargetDeclStmt[] generatedTargets;
    
    this() @system
    {
        evaluator = new Evaluator();
        expander = new MacroExpander(evaluator);
        generatedTargets = [];
    }
    
    /// Execute program (list of statements) and return generated targets
    Result!(TargetDeclStmt[], BuildError) execute(Stmt[] statements) @system
    {
        foreach (stmt; statements)
        {
            auto result = executeStatement(stmt);
            if (result.isErr)
                return Result!(TargetDeclStmt[], BuildError).err(result.unwrapErr());
        }
        
        return Result!(TargetDeclStmt[], BuildError).ok(generatedTargets);
    }
    
    /// Execute single statement
    private Result!BuildError executeStatement(Stmt stmt) @system
    {
        if (auto varDecl = cast(VarDeclStmt)stmt)
            return executeVarDecl(varDecl);
        else if (auto funcDecl = cast(FunctionDeclStmt)stmt)
            return executeFunctionDecl(funcDecl);
        else if (auto macroDecl = cast(MacroDeclStmt)stmt)
            return executeMacroDecl(macroDecl);
        else if (auto ifStmt = cast(IfStmt)stmt)
            return executeIfStmt(ifStmt);
        else if (auto forStmt = cast(ForStmt)stmt)
            return executeForStmt(forStmt);
        else if (auto returnStmt = cast(ReturnStmt)stmt)
            return executeReturnStmt(returnStmt);
        else if (auto importStmt = cast(ImportStmt)stmt)
            return executeImportStmt(importStmt);
        else if (auto targetStmt = cast(TargetDeclStmt)stmt)
            return executeTargetStmt(targetStmt);
        else if (auto exprStmt = cast(ExprStmt)stmt)
            return executeExprStmt(exprStmt);
        else if (auto blockStmt = cast(BlockStmt)stmt)
            return executeBlockStmt(blockStmt);
        else
            return err("Unknown statement type");
    }
    
    /// Execute variable declaration
    private Result!BuildError executeVarDecl(VarDeclStmt stmt) @system
    {
        // Evaluate initializer
        auto valueResult = evaluateExpr(stmt.initializer);
        if (valueResult.isErr)
            return Result!BuildError.err(valueResult.unwrapErr());
        
        // Define variable
        return evaluator.defineVariable(stmt.name, valueResult.unwrap(), stmt.isConst);
    }
    
    /// Execute function declaration - creates closure capturing current scope
    private Result!BuildError executeFunctionDecl(FunctionDeclStmt stmt) @system
    {
        // Capture current lexical environment for closure
        Closure closure;
        closure.name = stmt.name;
        closure.params = stmt.params;
        closure.body_ = stmt.body;
        closure.lambdaBody = null;
        closure.capturedEnv = captureEnvironment();
        
        // Store as first-class function value
        auto fnValue = Value.makeFunction(closure);
        return evaluator.defineVariable(stmt.name, fnValue, true);  // Functions are immutable
    }
    
    /// Capture current scope for closures
    private Value[string] captureEnvironment() @system
    {
        Value[string] env;
        foreach (name; evaluator.scopeManager().definedNames())
        {
            auto lookupResult = evaluator.scopeManager().lookup(name);
            if (lookupResult.isOk)
                env[name] = lookupResult.unwrap();
        }
        return env;
    }
    
    /// Execute macro declaration
    private Result!BuildError executeMacroDecl(MacroDeclStmt stmt) @system
    {
        // Register macro with expander
        // Convert Stmt[] to Statement[] (old format)
        Statement[] body;
        foreach (s; stmt.body)
        {
            body ~= convertToLegacyStatement(s);
        }
        
        return expander.define(stmt.name, stmt.params, body);
    }
    
    /// Convert new unified Stmt to legacy Statement format
    private Statement convertToLegacyStatement(Stmt stmt) @system
    {
        Statement legacyStmt;
        
        if (auto targetDecl = cast(TargetDeclStmt)stmt)
        {
            legacyStmt.type = StatementType.TargetDeclStmt;
            legacyStmt.targetDecl = targetDecl;
        }
        else if (auto forStmt = cast(ForStmt)stmt)
        {
            legacyStmt.type = StatementType.ForLoop;
            legacyStmt.loopVar = forStmt.variable;
            legacyStmt.loopIterable = forStmt.iterable;
            foreach (s; forStmt.body)
                legacyStmt.loopBody ~= convertToLegacyStatement(s);
        }
        else if (auto ifStmt = cast(IfStmt)stmt)
        {
            legacyStmt.type = StatementType.IfStatement;
            legacyStmt.condition = ifStmt.condition;
            foreach (s; ifStmt.thenBranch)
                legacyStmt.thenBranch ~= convertToLegacyStatement(s);
            foreach (s; ifStmt.elseBranch)
                legacyStmt.elseBranch ~= convertToLegacyStatement(s);
        }
        else if (auto varDecl = cast(VarDeclStmt)stmt)
        {
            legacyStmt.type = varDecl.isConst ? StatementType.LetDecl : StatementType.LetDecl;
            // For variables, would need to extend Statement struct if needed
        }
        
        return legacyStmt;
    }
    
    /// Execute if statement
    private Result!BuildError executeIfStmt(IfStmt stmt) @system
    {
        // Evaluate condition
        auto conditionResult = evaluateExpr(stmt.condition);
        if (conditionResult.isErr)
            return Result!BuildError.err(conditionResult.unwrapErr());
        
        bool condition = conditionResult.unwrap().toBool();
        
        // Execute appropriate branch
        if (condition)
        {
            foreach (s; stmt.thenBranch)
            {
                auto result = executeStatement(s);
                if (result.isErr)
                    return result;
            }
        }
        else if (stmt.elseBranch.length > 0)
        {
            foreach (s; stmt.elseBranch)
            {
                auto result = executeStatement(s);
                if (result.isErr)
                    return result;
            }
        }
        
        return Result!BuildError.ok();
    }
    
    /// Execute for loop
    private Result!BuildError executeForStmt(ForStmt stmt) @system
    {
        // Evaluate iterable
        auto iterableResult = evaluateExpr(stmt.iterable);
        if (iterableResult.isErr)
            return Result!BuildError.err(iterableResult.unwrapErr());
        
        auto iterable = iterableResult.unwrap();
        
        // Check if iterable is array
        if (!iterable.isArray())
        {
            auto error = new ParseError("For loop requires an array to iterate over", null);
            return Result!BuildError.err(error);
        }
        
        auto array = iterable.asArray();
        
        // Enter new scope for loop
        evaluator.enterScope();
        scope(exit) evaluator.exitScope();
        
        // Iterate over array
        foreach (element; array)
        {
            // Bind loop variable
            auto defineResult = evaluator.defineVariable(stmt.variable, element, false);
            if (defineResult.isErr)
                return defineResult;
            
            // Execute loop body
            foreach (s; stmt.body)
            {
                auto result = executeStatement(s);
                if (result.isErr)
                    return result;
            }
        }
        
        return Result!BuildError.ok();
    }
    
    /// Execute return statement - sets return value for function exit
    private Result!BuildError executeReturnStmt(ReturnStmt stmt) @system
    {
        // Return statements are handled by the evaluator's executeStmt
        // This path is for top-level returns (which are no-ops outside functions)
        if (stmt.value)
        {
            auto result = evaluateExpr(stmt.value);
            if (result.isErr)
                return Result!BuildError.err(result.unwrapErr());
            // Top-level return - value is discarded
        }
        return Result!BuildError.ok();
    }
    
    /// Execute import statement (Tier 2 - D macros)
    private Result!BuildError executeImportStmt(ImportStmt stmt) @system
    {
        // Import statements for Tier 2 macros - not yet implemented
        return Result!BuildError.ok();
    }
    
    /// Execute target statement
    private Result!BuildError executeTargetStmt(TargetDeclStmt stmt) @system
    {
        // Evaluate expressions in target fields before passing to semantic analyzer
        auto expandedTarget = expandTargetExpressions(stmt);
        if (expandedTarget.isErr)
            return Result!BuildError.err(expandedTarget.unwrapErr());
        
        generatedTargets ~= expandedTarget.unwrap();
        return Result!BuildError.ok();
    }
    
    /// Expand expressions in target fields (resolve variables, concatenations, etc.)
    private Result!(TargetDeclStmt, BuildError) expandTargetExpressions(TargetDeclStmt stmt) @system
    {
        import infrastructure.config.workspace.ast : Field, Location;
        
        Field[] expandedFields;
        foreach (field; stmt.fields)
        {
            auto expandedValue = expandExpr(field.value);
            if (expandedValue.isErr)
                return Result!(TargetDeclStmt, BuildError).err(expandedValue.unwrapErr());
            expandedFields ~= Field(field.name, expandedValue.unwrap(), field.loc);
        }
        
        return Result!(TargetDeclStmt, BuildError).ok(
            new TargetDeclStmt(stmt.name, expandedFields, stmt.location()));
    }
    
    /// Expand expression - evaluate variables and create literal expression
    private Result!(Expr, BuildError) expandExpr(Expr expr) @system
    {
        import infrastructure.config.workspace.ast : LiteralExpr, Literal, LiteralKind, Location;
        
        auto valueResult = evaluateExpr(expr);
        if (valueResult.isErr)
            return Result!(Expr, BuildError).err(valueResult.unwrapErr());
        
        auto value = valueResult.unwrap();
        return Result!(Expr, BuildError).ok(valueToExpr(value, expr.location()));
    }
    
    /// Convert Value to Expr (for expanded target fields)
    private Expr valueToExpr(Value value, Location loc) @system
    {
        import infrastructure.config.workspace.ast : LiteralExpr, Literal, LiteralKind;
        
        final switch (value.type())
        {
            case ValueType.Null:
                return new LiteralExpr(Literal.makeNull(), loc);
            case ValueType.Bool:
                return new LiteralExpr(Literal.makeBool(value.asBool()), loc);
            case ValueType.Number:
                return new LiteralExpr(Literal.makeNumber(cast(long)value.asNumber()), loc);
            case ValueType.String:
                return new LiteralExpr(Literal.makeString(value.asString()), loc);
            case ValueType.Array:
                Literal[] elements;
                foreach (elem; value.asArray())
                    elements ~= exprToLiteral(valueToExpr(elem, loc));
                return new LiteralExpr(Literal.makeArray(elements), loc);
            case ValueType.Map:
                Literal[string] pairs;
                foreach (k, v; value.asMap())
                    pairs[k] = exprToLiteral(valueToExpr(v, loc));
                return new LiteralExpr(Literal.makeMap(pairs), loc);
            case ValueType.Function:
            case ValueType.Target:
                // Functions and targets can't be directly converted to literals
                return new LiteralExpr(Literal.makeNull(), loc);
        }
    }
    
    /// Extract Literal from LiteralExpr
    private Literal exprToLiteral(Expr expr) @system
    {
        import infrastructure.config.workspace.ast : LiteralExpr;
        if (auto lit = cast(LiteralExpr)expr)
            return lit.value;
        return Literal.makeNull();
    }
    
    /// Execute expression statement
    private Result!BuildError executeExprStmt(ExprStmt stmt) @system
    {
        // Evaluate expression (for side effects, like macro calls)
        auto result = evaluateExpr(stmt.expr);
        if (result.isErr)
            return Result!BuildError.err(result.unwrapErr());
        
        return Result!BuildError.ok();
    }
    
    /// Execute block statement
    private Result!BuildError executeBlockStmt(BlockStmt stmt) @system
    {
        // Enter new scope
        evaluator.enterScope();
        scope(exit) evaluator.exitScope();
        
        // Execute all statements in block
        foreach (s; stmt.stmts)
        {
            auto result = executeStatement(s);
            if (result.isErr)
                return result;
        }
        
        return Result!BuildError.ok();
    }
    
    /// Evaluate expression (bridge between Expr and Value)
    private Result!(Value, BuildError) evaluateExpr(Expr expr) @system
    {
        if (auto litExpr = cast(LiteralExpr)expr)
        {
            // Evaluate literal using existing evaluator
            return evaluator.evaluate(litExpr);
        }
        else if (auto binaryExpr = cast(BinaryExpr)expr)
        {
            auto leftResult = evaluateExpr(binaryExpr.left);
            if (leftResult.isErr)
                return leftResult;
            
            auto rightResult = evaluateExpr(binaryExpr.right);
            if (rightResult.isErr)
                return rightResult;
            
            return evaluator.evaluateBinary(binaryExpr.op, leftResult.unwrap(), rightResult.unwrap());
        }
        else if (auto unaryExpr = cast(UnaryExpr)expr)
        {
            auto operandResult = evaluateExpr(unaryExpr.operand);
            if (operandResult.isErr)
                return operandResult;
            
            return evaluator.evaluateUnary(unaryExpr.op, operandResult.unwrap());
        }
        else if (auto callExpr = cast(CallExpr)expr)
        {
            // Evaluate arguments
            Value[] argValues;
            foreach (arg; callExpr.args)
            {
                auto argResult = evaluateExpr(arg);
                if (argResult.isErr)
                    return Result!(Value, BuildError).err(argResult.unwrapErr());
                argValues ~= argResult.unwrap();
            }
            
            return evaluator.evaluateCall(callExpr.callee, argValues);
        }
        else if (auto indexExpr = cast(IndexExpr)expr)
        {
            auto objectResult = evaluateExpr(indexExpr.object);
            if (objectResult.isErr)
                return objectResult;
            
            auto indexResult = evaluateExpr(indexExpr.index);
            if (indexResult.isErr)
                return indexResult;
            
            return evaluator.evaluateIndex(objectResult.unwrap(), indexResult.unwrap());
        }
        else if (auto sliceExpr = cast(SliceExpr)expr)
        {
            auto objectResult = evaluateExpr(sliceExpr.object);
            if (objectResult.isErr)
                return objectResult;
            
            Value start = Value.makeNull();
            if (sliceExpr.start)
            {
                auto startResult = evaluateExpr(sliceExpr.start);
                if (startResult.isErr)
                    return startResult;
                start = startResult.unwrap();
            }
            
            Value end = Value.makeNull();
            if (sliceExpr.end)
            {
                auto endResult = evaluateExpr(sliceExpr.end);
                if (endResult.isErr)
                    return endResult;
                end = endResult.unwrap();
            }
            
            return evaluator.evaluateSlice(objectResult.unwrap(), start, end);
        }
        else if (auto ternaryExpr = cast(TernaryExpr)expr)
        {
            auto conditionResult = evaluateExpr(ternaryExpr.condition);
            if (conditionResult.isErr)
                return conditionResult;
            
            if (conditionResult.unwrap().toBool())
            {
                return evaluateExpr(ternaryExpr.trueExpr);
            }
            else
            {
                return evaluateExpr(ternaryExpr.falseExpr);
            }
        }
        else
        {
            auto error = new ParseError("Unsupported expression type for evaluation", null);
            return Result!(Value, BuildError).err(error);
        }
    }
    
    // Helper methods
    
    private Result!BuildError err(string msg) @system
    {
        auto error = new ParseError(msg, null);
        return Result!BuildError.err(error);
    }
}

