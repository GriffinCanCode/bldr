module infrastructure.config.parsing.unified;

import std.conv;
import std.algorithm;
import std.array;
import std.string;
import infrastructure.config.parsing.lexer;
import infrastructure.config.workspace.ast;
import infrastructure.config.schema.schema;
import infrastructure.config.scripting.evaluator;
import infrastructure.config.scripting.builtins;
import infrastructure.config.scripting.scopemanager;
import infrastructure.config.caching.parse;
import infrastructure.errors;
import languages.registry;

/// Unified Parser - Single source of truth for all Builder DSL parsing
/// 
/// Features:
/// - Parses expressions, statements, targets, repositories
/// - Integrates Tier 1 scripting (let, const, fn, for, if)
/// - Uses parse cache for performance
/// - Pratt parsing for expressions
/// - Recursive descent for statements
/// 
/// Design:
/// - Clean separation of concerns
/// - Single pass parsing
/// - Type-safe AST construction
/// - Comprehensive error reporting

class UnifiedParser
{
    private Token[] tokens;
    private size_t current;
    private string filePath;
    private string workspaceRoot;
    private Evaluator evaluator;
    private ParseCache cache;
    
    this(Token[] tokens, string filePath, string workspaceRoot, ParseCache cache = null)
    {
        this.tokens = tokens;
        this.filePath = filePath;
        this.workspaceRoot = workspaceRoot;
        this.evaluator = new Evaluator();
        this.cache = cache;
    }
    
    /// Parse complete build file
    BuildResult!BuildFile parse() @system
    {
        BuildFile file;
        file.filePath = filePath;
        
        // Parse all top-level statements
        while (!isAtEnd())
        {
            auto stmtResult = parseTopLevel();
            if (stmtResult.isErr)
                return Err!(BuildFile, BuildError)(stmtResult.unwrapErr());
            
            file.statements ~= stmtResult.unwrap();
        }
        
        // Validate we have at least one target or repository
        if (file.statements.empty)
        {
            return Err!(BuildFile, BuildError)(
                Errors.parse(filePath, "Builderfile is empty", Parse.InvalidBuildFile)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        return Ok!(BuildFile, BuildError)(file);
    }
    
    // ========================================================================
    // TOP-LEVEL PARSING
    // ========================================================================
    
    private BuildResult!Stmt parseTopLevel() @system
    {
        auto token = peek();
        
        switch (token.type)
        {
            case TokenType.Target:
                return parseTargetDecl();
            case TokenType.Repository:
                return parseRepositoryDecl();
            case TokenType.Let:
            case TokenType.Const:
                return parseVarDecl();
            case TokenType.Fn:
                return parseFunctionDecl();
            case TokenType.Macro:
                return parseMacroDecl();
            case TokenType.If:
                return parseIfStmt();
            case TokenType.For:
                return parseForStmt();
            case TokenType.Import:
                return parseImportStmt();
            default:
                return error!Stmt("Unexpected token at top level: " ~ token.typeName());
        }
    }
    
    // ========================================================================
    // TARGET & REPOSITORY DECLARATIONS
    // ========================================================================
    
    private BuildResult!Stmt parseTargetDecl() @system
    {
        auto startToken = expect(TokenType.Target);
        auto loc = Location(filePath, startToken.line, startToken.column);
        
        if (!match(TokenType.LeftParen))
            return error!Stmt("Expected '(' after 'target'");
        
        if (!check(TokenType.String))
            return error!Stmt("Expected target name as string");
        
        string name = advance().value;
        
        if (name.strip().empty)
            return error!Stmt("Target name cannot be empty");
        
        if (!match(TokenType.RightParen))
            return error!Stmt("Expected ')' after target name");
        
        if (!match(TokenType.LeftBrace))
            return error!Stmt("Expected '{' to begin target body");
        
        Field[] fields;
        while (!check(TokenType.RightBrace) && !isAtEnd())
        {
            auto fieldResult = parseField();
            if (fieldResult.isErr)
                return Err!(Stmt, BuildError)(fieldResult.unwrapErr());
            fields ~= fieldResult.unwrap();
        }
        
        if (!match(TokenType.RightBrace))
            return error!Stmt("Expected '}' to end target body");
        
        return Ok!(Stmt, BuildError)(new TargetDeclStmt(name, fields, loc));
    }
    
    private BuildResult!Stmt parseRepositoryDecl() @system
    {
        auto startToken = expect(TokenType.Repository);
        auto loc = Location(filePath, startToken.line, startToken.column);
        
        if (!match(TokenType.LeftParen))
            return error!Stmt("Expected '(' after 'repository'");
        
        if (!check(TokenType.String))
            return error!Stmt("Expected repository name as string");
        
        string name = advance().value;
        
        if (name.strip().empty)
            return error!Stmt("Repository name cannot be empty");
        
        if (!match(TokenType.RightParen))
            return error!Stmt("Expected ')' after repository name");
        
        if (!match(TokenType.LeftBrace))
            return error!Stmt("Expected '{' to begin repository body");
        
        Field[] fields;
        while (!check(TokenType.RightBrace) && !isAtEnd())
        {
            auto fieldResult = parseField();
            if (fieldResult.isErr)
                return Err!(Stmt, BuildError)(fieldResult.unwrapErr());
            fields ~= fieldResult.unwrap();
        }
        
        if (!match(TokenType.RightBrace))
            return error!Stmt("Expected '}' to end repository body");
        
        return Ok!(Stmt, BuildError)(new RepositoryDeclStmt(name, fields, loc));
    }
    
    private BuildResult!Field parseField() @system
    {
        auto token = peek();
        auto loc = Location(filePath, token.line, token.column);
        
        // Field name (keyword or identifier)
        string fieldName;
        switch (token.type)
        {
            case TokenType.Type: fieldName = "type"; advance(); break;
            case TokenType.Language: fieldName = "language"; advance(); break;
            case TokenType.Sources: fieldName = "sources"; advance(); break;
            case TokenType.Deps: fieldName = "deps"; advance(); break;
            case TokenType.Flags: fieldName = "flags"; advance(); break;
            case TokenType.Env: fieldName = "env"; advance(); break;
            case TokenType.Output: fieldName = "output"; advance(); break;
            case TokenType.Includes: fieldName = "includes"; advance(); break;
            case TokenType.Config: fieldName = "config"; advance(); break;
            case TokenType.Identifier: fieldName = advance().value; break;
            default:
                return error!Field("Expected field name");
        }
        
        if (!match(TokenType.Colon))
            return error!Field("Expected ':' after field name");
        
        auto valueResult = parseExpression(0);
        if (valueResult.isErr)
            return Err!(Field, BuildError)(valueResult.unwrapErr());
        
        if (!match(TokenType.Semicolon))
            return error!Field("Expected ';' after field value");
        
        return Ok!(Field, BuildError)(Field(fieldName, valueResult.unwrap(), loc));
    }
    
    // ========================================================================
    // VARIABLE DECLARATIONS
    // ========================================================================
    
    private BuildResult!Stmt parseVarDecl() @system
    {
        auto token = advance();
        bool isConst = (token.type == TokenType.Const);
        auto loc = Location(filePath, token.line, token.column);
        
        if (!check(TokenType.Identifier))
            return error!Stmt("Expected variable name");
        
        string name = advance().value;
        
        if (!match(TokenType.Equal))
            return error!Stmt("Expected '=' in variable declaration");
        
        auto exprResult = parseExpression(0);
        if (exprResult.isErr)
            return Err!(Stmt, BuildError)(exprResult.unwrapErr());
        
        match(TokenType.Semicolon);  // Optional
        
        // Register variable in evaluator scope
        // Expression evaluation provided through scripting support
        
        return Ok!(Stmt, BuildError)(
            new VarDeclStmt(name, exprResult.unwrap(), isConst, loc));
    }
    
    // ========================================================================
    // FUNCTION DECLARATIONS
    // ========================================================================
    
    private BuildResult!Stmt parseFunctionDecl() @system
    {
        auto token = expect(TokenType.Fn);
        auto loc = Location(filePath, token.line, token.column);
        
        if (!check(TokenType.Identifier))
            return error!Stmt("Expected function name");
        
        string name = advance().value;
        
        if (!match(TokenType.LeftParen))
            return error!Stmt("Expected '(' after function name");
        
        Parameter[] params;
        if (!check(TokenType.RightParen))
        {
            do
            {
                if (peek().type == TokenType.Comma)
                    advance();
                
                if (!check(TokenType.Identifier))
                    return error!Stmt("Expected parameter name");
                
                Parameter param;
                param.name = advance().value;
                
                // Check for default value
                if (match(TokenType.Equal))
                {
                    auto defaultResult = parseExpression(0);
                    if (defaultResult.isErr)
                        return Err!(Stmt, BuildError)(defaultResult.unwrapErr());
                    param.defaultValue = defaultResult.unwrap();
                }
                
                params ~= param;
            } while (peek().type == TokenType.Comma);
        }
        
        if (!match(TokenType.RightParen))
            return error!Stmt("Expected ')' after parameters");
        
        if (!match(TokenType.LeftBrace))
            return error!Stmt("Expected '{' before function body");
        
        auto bodyResult = parseBlock();
        if (bodyResult.isErr)
            return Err!(Stmt, BuildError)(bodyResult.unwrapErr());
        
        return Ok!(Stmt, BuildError)(
            new FunctionDeclStmt(name, params, bodyResult.unwrap(), loc));
    }
    
    // ========================================================================
    // MACRO DECLARATIONS
    // ========================================================================
    
    private BuildResult!Stmt parseMacroDecl() @system
    {
        auto token = expect(TokenType.Macro);
        auto loc = Location(filePath, token.line, token.column);
        
        if (!check(TokenType.Identifier))
            return error!Stmt("Expected macro name");
        
        string name = advance().value;
        
        if (!match(TokenType.LeftParen))
            return error!Stmt("Expected '(' after macro name");
        
        string[] params;
        if (!check(TokenType.RightParen))
        {
            do
            {
                if (peek().type == TokenType.Comma)
                    advance();
                
                if (!check(TokenType.Identifier))
                    return error!Stmt("Expected parameter name");
                
                params ~= advance().value;
            } while (peek().type == TokenType.Comma);
        }
        
        if (!match(TokenType.RightParen))
            return error!Stmt("Expected ')' after parameters");
        
        if (!match(TokenType.LeftBrace))
            return error!Stmt("Expected '{' before macro body");
        
        auto bodyResult = parseBlock();
        if (bodyResult.isErr)
            return Err!(Stmt, BuildError)(bodyResult.unwrapErr());
        
        return Ok!(Stmt, BuildError)(
            new MacroDeclStmt(name, params, bodyResult.unwrap(), loc));
    }
    
    // ========================================================================
    // CONTROL FLOW
    // ========================================================================
    
    private BuildResult!Stmt parseIfStmt() @system
    {
        auto token = expect(TokenType.If);
        auto loc = Location(filePath, token.line, token.column);
        
        if (!match(TokenType.LeftParen))
            return error!Stmt("Expected '(' after 'if'");
        
        auto condResult = parseExpression(0);
        if (condResult.isErr)
            return Err!(Stmt, BuildError)(condResult.unwrapErr());
        
        if (!match(TokenType.RightParen))
            return error!Stmt("Expected ')' after condition");
        
        if (!match(TokenType.LeftBrace))
            return error!Stmt("Expected '{' after condition");
        
        auto thenResult = parseBlock();
        if (thenResult.isErr)
            return Err!(Stmt, BuildError)(thenResult.unwrapErr());
        
        Stmt[] elseBranch;
        if (match(TokenType.Else))
        {
            if (check(TokenType.If))
            {
                // else if
                auto elseIfResult = parseIfStmt();
                if (elseIfResult.isErr)
                    return Err!(Stmt, BuildError)(elseIfResult.unwrapErr());
                elseBranch = [elseIfResult.unwrap()];
            }
            else
            {
                if (!match(TokenType.LeftBrace))
                    return error!Stmt("Expected '{' after 'else'");
                
                auto elseResult = parseBlock();
                if (elseResult.isErr)
                    return Err!(Stmt, BuildError)(elseResult.unwrapErr());
                elseBranch = elseResult.unwrap();
            }
        }
        
        return Ok!(Stmt, BuildError)(
            new IfStmt(condResult.unwrap(), thenResult.unwrap(), elseBranch, loc));
    }
    
    private BuildResult!Stmt parseForStmt() @system
    {
        auto token = expect(TokenType.For);
        auto loc = Location(filePath, token.line, token.column);
        
        if (!check(TokenType.Identifier))
            return error!Stmt("Expected loop variable");
        
        string variable = advance().value;
        
        if (!match(TokenType.In))
            return error!Stmt("Expected 'in' after loop variable");
        
        auto iterableResult = parseExpression(0);
        if (iterableResult.isErr)
            return Err!(Stmt, BuildError)(iterableResult.unwrapErr());
        
        if (!match(TokenType.LeftBrace))
            return error!Stmt("Expected '{' before loop body");
        
        auto bodyResult = parseBlock();
        if (bodyResult.isErr)
            return Err!(Stmt, BuildError)(bodyResult.unwrapErr());
        
        return Ok!(Stmt, BuildError)(
            new ForStmt(variable, iterableResult.unwrap(), bodyResult.unwrap(), loc));
    }
    
    // ========================================================================
    // OTHER STATEMENTS
    // ========================================================================
    
    private BuildResult!Stmt parseImportStmt() @system
    {
        auto token = expect(TokenType.Import);
        auto loc = Location(filePath, token.line, token.column);
        
        if (!check(TokenType.Identifier) && !check(TokenType.String))
            return error!Stmt("Expected module path");
        
        string modulePath = advance().value;
        
        match(TokenType.Semicolon);
        
        return Ok!(Stmt, BuildError)(new ImportStmt(modulePath, loc));
    }
    
    private BuildResult!(Stmt[]) parseBlock() @system
    {
        Stmt[] stmts;
        
        while (!check(TokenType.RightBrace) && !isAtEnd())
        {
            auto stmtResult = parseStatement();
            if (stmtResult.isErr)
                return Err!(Stmt[], BuildError)(stmtResult.unwrapErr());
            stmts ~= stmtResult.unwrap();
        }
        
        if (!match(TokenType.RightBrace))
            return error!(Stmt[])("Expected '}' after block");
        
        return Ok!(Stmt[], BuildError)(stmts);
    }
    
    private BuildResult!Stmt parseStatement() @system
    {
        auto token = peek();
        
        switch (token.type)
        {
            case TokenType.Let:
            case TokenType.Const:
                return parseVarDecl();
            case TokenType.If:
                return parseIfStmt();
            case TokenType.For:
                return parseForStmt();
            case TokenType.Return:
                return parseReturnStmt();
            case TokenType.Target:
                return parseTargetDecl();
            default:
                return parseExprStmt();
        }
    }
    
    private BuildResult!Stmt parseReturnStmt() @system
    {
        auto token = expect(TokenType.Return);
        auto loc = Location(filePath, token.line, token.column);
        
        Expr value = null;
        if (!check(TokenType.Semicolon) && !isAtEnd())
        {
            auto valueResult = parseExpression(0);
            if (valueResult.isErr)
                return Err!(Stmt, BuildError)(valueResult.unwrapErr());
            value = valueResult.unwrap();
        }
        
        match(TokenType.Semicolon);
        
        return Ok!(Stmt, BuildError)(new ReturnStmt(value, loc));
    }
    
    private BuildResult!Stmt parseExprStmt() @system
    {
        auto token = peek();
        auto loc = Location(filePath, token.line, token.column);
        
        auto exprResult = parseExpression(0);
        if (exprResult.isErr)
            return Err!(Stmt, BuildError)(exprResult.unwrapErr());
        
        match(TokenType.Semicolon);
        
        return Ok!(Stmt, BuildError)(new ExprStmt(exprResult.unwrap(), loc));
    }
    
    // ========================================================================
    // EXPRESSION PARSING (Pratt Parser)
    // ========================================================================
    
    private BuildResult!Expr parseExpression(int minPrecedence) @system
    {
        auto leftResult = parsePrimary();
        if (leftResult.isErr)
            return leftResult;
        
        auto left = leftResult.unwrap();
        
        while (!isAtEnd())
        {
            auto token = peek();
            
            if (isBinaryOp(token.type))
            {
                int precedence = getPrecedence(token.type);
                if (precedence < minPrecedence)
                    break;
                
                advance();
                
                auto rightResult = parseExpression(precedence + 1);
                if (rightResult.isErr)
                    return rightResult;
                
                auto loc = Location(filePath, token.line, token.column);
                left = new BinaryExpr(left, token.value, rightResult.unwrap(), loc);
            }
            else if (token.type == TokenType.Question)
            {
                // Ternary
                int precedence = 3;
                if (precedence < minPrecedence)
                    break;
                
                advance();
                
                auto trueResult = parseExpression(0);
                if (trueResult.isErr)
                    return trueResult;
                
                if (!match(TokenType.Colon))
                    return error!Expr("Expected ':' in ternary");
                
                auto falseResult = parseExpression(precedence);
                if (falseResult.isErr)
                    return falseResult;
                
                auto loc = Location(filePath, token.line, token.column);
                left = new TernaryExpr(left, trueResult.unwrap(), falseResult.unwrap(), loc);
            }
            else if (token.type == TokenType.LeftBracket)
            {
                // Index or slice
                advance();
                
                auto loc = Location(filePath, token.line, token.column);
                
                if (match(TokenType.Colon))
                {
                    // Slice [:end]
                    Expr end = null;
                    if (!check(TokenType.RightBracket))
                    {
                        auto endResult = parseExpression(0);
                        if (endResult.isErr)
                            return endResult;
                        end = endResult.unwrap();
                    }
                    
                    if (!match(TokenType.RightBracket))
                        return error!Expr("Expected ']'");
                    
                    left = new SliceExpr(left, null, end, loc);
                }
                else
                {
                    auto indexResult = parseExpression(0);
                    if (indexResult.isErr)
                        return indexResult;
                    
                    if (match(TokenType.Colon))
                    {
                        // Slice [start:end]
                        Expr end = null;
                        if (!check(TokenType.RightBracket))
                        {
                            auto endResult = parseExpression(0);
                            if (endResult.isErr)
                                return endResult;
                            end = endResult.unwrap();
                        }
                        
                        if (!match(TokenType.RightBracket))
                            return error!Expr("Expected ']'");
                        
                        left = new SliceExpr(left, indexResult.unwrap(), end, loc);
                    }
                    else
                    {
                        if (!match(TokenType.RightBracket))
                            return error!Expr("Expected ']'");
                        
                        left = new IndexExpr(left, indexResult.unwrap(), loc);
                    }
                }
            }
            else if (token.type == TokenType.Dot)
            {
                advance();
                
                if (!check(TokenType.Identifier))
                    return error!Expr("Expected member name");
                
                auto loc = Location(filePath, token.line, token.column);
                string member = advance().value;
                left = new MemberExpr(left, member, loc);
            }
            else if (token.type == TokenType.LeftParen && cast(IdentExpr)left)
            {
                // Function call
                auto identExpr = cast(IdentExpr)left;
                advance();
                
                auto loc = Location(filePath, token.line, token.column);
                
                Expr[] args;
                if (!check(TokenType.RightParen))
                {
                    do
                    {
                        if (peek().type == TokenType.Comma)
                            advance();
                        
                        auto argResult = parseExpression(0);
                        if (argResult.isErr)
                            return argResult;
                        args ~= argResult.unwrap();
                    } while (peek().type == TokenType.Comma);
                }
                
                if (!match(TokenType.RightParen))
                    return error!Expr("Expected ')'");
                
                left = new CallExpr(identExpr.name, args, loc);
            }
            else
            {
                break;
            }
        }
        
        return Ok!(Expr, BuildError)(left);
    }
    
    private BuildResult!Expr parsePrimary() @system
    {
        auto token = peek();
        auto loc = Location(filePath, token.line, token.column);
        
        // Unary operators
        if (token.type == TokenType.Minus || token.type == TokenType.Bang)
        {
            advance();
            auto operandResult = parsePrimary();
            if (operandResult.isErr)
                return operandResult;
            
            return Ok!(Expr, BuildError)(
                new UnaryExpr(token.value, operandResult.unwrap(), loc));
        }
        
        // Parenthesized expression
        if (token.type == TokenType.LeftParen)
        {
            advance();
            auto exprResult = parseExpression(0);
            if (exprResult.isErr)
                return exprResult;
            
            if (!match(TokenType.RightParen))
                return error!Expr("Expected ')'");
            
            return exprResult;
        }
        
        // Lambda |params| expr
        if (token.type == TokenType.Pipe)
        {
            advance();
            
            string[] params;
            if (!check(TokenType.Pipe))
            {
                do
                {
                    if (peek().type == TokenType.Comma)
                        advance();
                    
                    if (!check(TokenType.Identifier))
                        return error!Expr("Expected parameter name");
                    params ~= advance().value;
                } while (peek().type == TokenType.Comma);
            }
            
            if (!match(TokenType.Pipe))
                return error!Expr("Expected '|'");
            
            auto bodyResult = parseExpression(0);
            if (bodyResult.isErr)
                return bodyResult;
            
            return Ok!(Expr, BuildError)(
                new LambdaExpr(params, bodyResult.unwrap(), loc));
        }
        
        // Literals
        if (token.type == TokenType.String)
        {
            advance();
            return Ok!(Expr, BuildError)(
                new LiteralExpr(Literal.makeString(token.value), loc));
        }
        
        if (token.type == TokenType.Number)
        {
            advance();
            return Ok!(Expr, BuildError)(
                new LiteralExpr(Literal.makeNumber(token.value.to!long), loc));
        }
        
        if (token.type == TokenType.True)
        {
            advance();
            return Ok!(Expr, BuildError)(
                new LiteralExpr(Literal.makeBool(true), loc));
        }
        
        if (token.type == TokenType.False)
        {
            advance();
            return Ok!(Expr, BuildError)(
                new LiteralExpr(Literal.makeBool(false), loc));
        }
        
        if (token.type == TokenType.Null)
        {
            advance();
            return Ok!(Expr, BuildError)(
                new LiteralExpr(Literal.makeNull(), loc));
        }
        
        if (token.type == TokenType.Identifier)
        {
            advance();
            return Ok!(Expr, BuildError)(new IdentExpr(token.value, loc));
        }
        
        // Type keywords used as values (e.g., type: library)
        if (token.type == TokenType.Executable || token.type == TokenType.Library ||
            token.type == TokenType.Test || token.type == TokenType.Custom)
        {
            advance();
            return Ok!(Expr, BuildError)(new IdentExpr(token.value, loc));
        }
        
        // Array literal
        if (token.type == TokenType.LeftBracket)
        {
            return parseArrayLiteral();
        }
        
        // Map literal
        if (token.type == TokenType.LeftBrace)
        {
            return parseMapLiteral();
        }
        
        return error!Expr("Expected expression");
    }
    
    private BuildResult!Expr parseArrayLiteral() @system
    {
        auto token = expect(TokenType.LeftBracket);
        auto loc = Location(filePath, token.line, token.column);
        
        Literal[] elements;
        
        if (!check(TokenType.RightBracket))
        {
            do
            {
                if (peek().type == TokenType.Comma)
                    advance();
                
                auto elemResult = parseExpression(0);
                if (elemResult.isErr)
                    return Err!(Expr, BuildError)(elemResult.unwrapErr());
                
                // Must be literal for now
                auto expr = elemResult.unwrap();
                if (auto litExpr = cast(LiteralExpr)expr)
                {
                    elements ~= litExpr.value;
                }
                else
                {
                    return error!Expr("Array elements must be literals");
                }
            } while (peek().type == TokenType.Comma);
        }
        
        if (!match(TokenType.RightBracket))
            return error!Expr("Expected ']'");
        
        return Ok!(Expr, BuildError)(
            new LiteralExpr(Literal.makeArray(elements), loc));
    }
    
    private BuildResult!Expr parseMapLiteral() @system
    {
        auto token = expect(TokenType.LeftBrace);
        auto loc = Location(filePath, token.line, token.column);
        
        Literal[string] pairs;
        
        if (!check(TokenType.RightBrace))
        {
            do
            {
                if (peek().type == TokenType.Comma)
                    advance();
                
                if (!check(TokenType.Identifier) && !check(TokenType.String))
                    return error!Expr("Expected key");
                
                string key = advance().value;
                
                if (!match(TokenType.Colon))
                    return error!Expr("Expected ':'");
                
                auto valueResult = parseExpression(0);
                if (valueResult.isErr)
                    return Err!(Expr, BuildError)(valueResult.unwrapErr());
                
                // Must be literal for now
                auto expr = valueResult.unwrap();
                if (auto litExpr = cast(LiteralExpr)expr)
                {
                    pairs[key] = litExpr.value;
                }
                else
                {
                    return error!Expr("Map values must be literals");
                }
            } while (peek().type == TokenType.Comma);
        }
        
        if (!match(TokenType.RightBrace))
            return error!Expr("Expected '}'");
        
        return Ok!(Expr, BuildError)(
            new LiteralExpr(Literal.makeMap(pairs), loc));
    }
    
    // ========================================================================
    // OPERATOR PRECEDENCE
    // ========================================================================
    
    private int getPrecedence(TokenType type) pure nothrow @nogc @safe
    {
        switch (type)
        {
            case TokenType.PipePipe: return 4;
            case TokenType.AmpAmp: return 5;
            case TokenType.EqualEqual:
            case TokenType.BangEqual: return 6;
            case TokenType.Less:
            case TokenType.LessEqual:
            case TokenType.Greater:
            case TokenType.GreaterEqual: return 7;
            case TokenType.Plus:
            case TokenType.Minus: return 8;
            case TokenType.Star:
            case TokenType.Slash:
            case TokenType.Percent: return 9;
            default: return 0;
        }
    }
    
    private bool isBinaryOp(TokenType type) pure nothrow @nogc @safe
    {
        switch (type)
        {
            case TokenType.Plus:
            case TokenType.Minus:
            case TokenType.Star:
            case TokenType.Slash:
            case TokenType.Percent:
            case TokenType.EqualEqual:
            case TokenType.BangEqual:
            case TokenType.Less:
            case TokenType.LessEqual:
            case TokenType.Greater:
            case TokenType.GreaterEqual:
            case TokenType.AmpAmp:
            case TokenType.PipePipe:
                return true;
            default:
                return false;
        }
    }
    
    // ========================================================================
    // HELPERS
    // ========================================================================
    
    private bool isAtEnd() const pure nothrow @safe
    {
        return current >= tokens.length || peek().type == TokenType.EOF;
    }
    
    private Token peek() const pure nothrow @nogc @safe
    {
        return current < tokens.length ? tokens[current] : Token(TokenType.EOF, "", 0, 0);
    }
    
    private Token advance() pure nothrow @safe
    {
        if (!isAtEnd())
            current++;
        return tokens[current - 1];
    }
    
    private Token expect(TokenType type) @trusted
    {
        if (!check(type))
            throw Errors.parse(filePath, "Expected " ~ type.to!string, Parse.Failed).build();
        return advance();
    }
    
    private bool match(TokenType type) pure nothrow @safe
    {
        if (check(type))
        {
            advance();
            return true;
        }
        return false;
    }
    
    private bool check(TokenType type) const pure nothrow @safe
    {
        return !isAtEnd() && peek().type == type;
    }
    
    private BuildResult!T error(T)(string message) @system
    {
        auto token = peek();
        auto err = Errors.parseAt(filePath, message, token.line, token.column)
            .withLocation(__FILE__, __LINE__)
            .build();
        err.extractSnippet();
        return Err!(T, BuildError)(err);
    }
}

/// High-level parsing API with caching
BuildResult!BuildFile parse(
    string source,
    string filePath,
    string workspaceRoot,
    ParseCache cache = null) @system
{
    // Check cache first
    if (cache !is null)
    {
        auto cached = cache.get(filePath);
        if (cached !is null)
            return Ok!(BuildFile, BuildError)(*cached);
    }
    
    // Lex
    auto lexResult = lex(source, filePath);
    if (lexResult.isErr)
        return Err!(BuildFile, BuildError)(lexResult.unwrapErr());
    
    // Parse
    auto parser = new UnifiedParser(lexResult.unwrap(), filePath, workspaceRoot, cache);
    auto parseResult = parser.parse();
    
    // Cache result
    if (cache !is null && parseResult.isOk)
    {
        cache.put(filePath, parseResult.unwrap());
    }
    
    return parseResult;
}

