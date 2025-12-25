module infrastructure.config.scripting.expander;

import std.array;
import std.algorithm;
import std.conv : to;
import infrastructure.config.scripting.types;
import infrastructure.config.scripting.evaluator;
import infrastructure.config.workspace.ast;
import infrastructure.errors;

/// Macro definition
struct MacroDefinition
{
    string name;
    string[] parameters;
    Statement[] body;  // Macro body statements
}

/// Macro expander for generating code at parse time
class MacroExpander
{
    private MacroDefinition[string] macros;
    private Evaluator evaluator;
    
    this(Evaluator evaluator) pure nothrow @safe
    {
        this.evaluator = evaluator;
    }
    
    /// Define macro
    VoidBuildResult define(string name, string[] params, Statement[] body) @trusted
    {
        MacroDefinition macro_;
        macro_.name = name;
        macro_.parameters = params;
        macro_.body = body;
        
        macros[name] = macro_;
        return VoidBuildResult.ok();
    }
    
    /// Check if macro is defined
    bool isDefined(string name) const pure nothrow @trusted
    {
        return (name in macros) !is null;
    }
    
    /// Expand macro call
    BuildResult!(TargetDeclStmt[]) expand(string name, Value[] args) @system
    {
        if (name !in macros)
        {
            auto error = new ParseError("Undefined macro '" ~ name ~ "'", null);
            error.addSuggestion("Define macro with 'macro " ~ name ~ "(...) { ... }'");
            return BuildResult!(TargetDeclStmt[]).err(error);
        }
        
        auto macro_ = macros[name];
        
        // Check arity
        if (args.length != macro_.parameters.length)
        {
            auto error = new ParseError(
                "Macro '" ~ name ~ "' expects " ~ macro_.parameters.length.to!string ~
                " arguments, got " ~ args.length.to!string,
                null
            );
            return BuildResult!(TargetDeclStmt[]).err(error);
        }
        
        // Create new scope for macro expansion
        evaluator.enterScope();
        scope(exit) evaluator.exitScope();
        
        // Bind arguments to parameters
        foreach (i, param; macro_.parameters)
        {
            auto defineResult = evaluator.defineVariable(param, args[i], true);
            if (defineResult.isErr)
                return BuildResult!(TargetDeclStmt[]).err(defineResult.unwrapErr());
        }
        
        // Execute macro body and collect generated targets
        TargetDeclStmt[] targets;
        
        foreach (stmt; macro_.body)
        {
            auto result = executeStatement(stmt);
            if (result.isErr)
                return BuildResult!(TargetDeclStmt[]).err(result.unwrapErr());
            
            targets ~= result.unwrap();
        }
        
        return BuildResult!(TargetDeclStmt[]).ok(targets);
    }
    
    /// Execute statement and return generated targets
    private BuildResult!(TargetDeclStmt[]) executeStatement(Statement stmt) @system
    {
        final switch (stmt.type)
        {
            case StatementType.TargetDeclStmt:
                // Return target declaration directly
                if (stmt.targetDecl !is null)
                    return BuildResult!(TargetDeclStmt[]).ok([stmt.targetDecl]);
                return BuildResult!(TargetDeclStmt[]).ok([]);
                
            case StatementType.ForLoop:
                return executeForLoop(stmt);
                
            case StatementType.IfStatement:
                return executeIfStatement(stmt);
                
            case StatementType.LetDecl:
                // Variable declarations don't generate targets, just evaluate
                return BuildResult!(TargetDeclStmt[]).ok([]);
                
            case StatementType.Assignment:
                // Assignments don't generate targets
                return BuildResult!(TargetDeclStmt[]).ok([]);
        }
    }
    
    /// Execute for loop and collect generated targets
    private BuildResult!(TargetDeclStmt[]) executeForLoop(Statement stmt) @system
    {
        // Evaluate iterable expression
        auto iterableResult = evaluator.evaluate(stmt.loopIterable);
        if (iterableResult.isErr)
            return BuildResult!(TargetDeclStmt[]).err(iterableResult.unwrapErr());
        
        auto iterable = iterableResult.unwrap();
        if (!iterable.isArray())
        {
            auto error = new ParseError("For loop requires array iterable", null);
            return BuildResult!(TargetDeclStmt[]).err(error);
        }
        
        TargetDeclStmt[] targets;
        
        // Enter loop scope
        evaluator.enterScope();
        scope(exit) evaluator.exitScope();
        
        // Iterate over array elements
        foreach (elem; iterable.asArray())
        {
            // Bind loop variable
            auto defineResult = evaluator.defineVariable(stmt.loopVar, elem, false);
            if (defineResult.isErr)
                return BuildResult!(TargetDeclStmt[]).err(defineResult.unwrapErr());
            
            // Execute loop body
            foreach (bodyStmt; stmt.loopBody)
            {
                auto result = executeStatement(bodyStmt);
                if (result.isErr)
                    return result;
                targets ~= result.unwrap();
            }
        }
        
        return BuildResult!(TargetDeclStmt[]).ok(targets);
    }
    
    /// Execute if statement and return targets from appropriate branch
    private BuildResult!(TargetDeclStmt[]) executeIfStatement(Statement stmt) @system
    {
        // Evaluate condition
        auto condResult = evaluator.evaluate(stmt.condition);
        if (condResult.isErr)
            return BuildResult!(TargetDeclStmt[]).err(condResult.unwrapErr());
        
        TargetDeclStmt[] targets;
        auto branch = condResult.unwrap().toBool() ? stmt.thenBranch : stmt.elseBranch;
        
        foreach (branchStmt; branch)
        {
            auto result = executeStatement(branchStmt);
            if (result.isErr)
                return result;
            targets ~= result.unwrap();
        }
        
        return BuildResult!(TargetDeclStmt[]).ok(targets);
    }
}

/// Statement AST node (extensible structure)
struct Statement
{
    StatementType type;
    
    // For target declarations
    TargetDeclStmt targetDecl;
    
    // For loops
    string loopVar;
    Expr loopIterable;
    Statement[] loopBody;
    
    // For conditionals
    Expr condition;
    Statement[] thenBranch;
    Statement[] elseBranch;
}

enum StatementType
{
    TargetDeclStmt,
    ForLoop,
    IfStatement,
    LetDecl,
    Assignment
}

