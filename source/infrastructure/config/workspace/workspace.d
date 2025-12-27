module infrastructure.config.workspace.workspace;

import std.conv;
import std.algorithm;
import std.array;
import std.string;
import infrastructure.config.parsing.lexer;
import infrastructure.config.workspace.ast;
import infrastructure.config.schema.schema;
import infrastructure.errors;
import infrastructure.utils.logging : structuredLog;

/// Workspace-level configuration AST nodes

/// Workspace declaration
struct WorkspaceDecl
{
    string name;
    WorkspaceField[] fields;
    size_t line;
    size_t column;
    
    /// Get field by name
    const(WorkspaceField)* getField(string name) const
    {
        auto found = fields.find!(f => f.name == name);
        return found.empty ? null : &found.front;
    }
    
    /// Check if has field
    bool hasField(string name) const { return getField(name) !is null; }
}

/// Workspace field (similar to Field but for workspace config)
struct WorkspaceField
{
    string name;
    Expr value;
    size_t line;
    size_t column;
}

/// Root workspace file AST
struct WorkspaceFile
{
    WorkspaceDecl workspace;
    string filePath;
}

/// Parser for Builderspace files
struct WorkspaceParser
{
    private Token[] tokens;
    private size_t current;
    private string filePath;
    
    this(Token[] tokens, string filePath = "")
    {
        this.tokens = tokens;
        this.filePath = filePath;
    }
    
    /// Parse Builderspace file into AST
    BuildResult!WorkspaceFile parse()
    {
        auto workspaceResult = parseWorkspace();
        if (workspaceResult.isErr) return Err!(WorkspaceFile, BuildError)(workspaceResult.unwrapErr());
        
        return Ok!(WorkspaceFile, BuildError)(WorkspaceFile(workspaceResult.unwrap(), filePath));
    }
    
    /// Parse workspace declaration
    private BuildResult!WorkspaceDecl parseWorkspace()
    {
        auto token = peek();
        immutable line = token.line, col = token.column;
        
        // Expect: workspace keyword (identifier "workspace")
        if (!check(TokenType.Identifier) || peek().value != "workspace")
            return error!(WorkspaceDecl)("Expected 'workspace' keyword at start of Builderspace file");
        advance();
        
        if (!match(TokenType.LeftParen))
            return error!(WorkspaceDecl)("Expected '(' after 'workspace'");
        
        if (!check(TokenType.String))
            return error!(WorkspaceDecl)("Expected workspace name as string literal");
        
        string name = advance().value;
        
        if (!match(TokenType.RightParen))
            return error!(WorkspaceDecl)("Expected ')' after workspace name");
        
        if (!match(TokenType.LeftBrace))
            return error!(WorkspaceDecl)("Expected '{' to begin workspace body");
        
        // Parse fields
        WorkspaceField[] fields;
        while (!check(TokenType.RightBrace) && !isAtEnd())
        {
            auto fieldResult = parseField();
            if (fieldResult.isErr) return Err!(WorkspaceDecl, BuildError)(fieldResult.unwrapErr());
            fields ~= fieldResult.unwrap();
        }
        
        if (!match(TokenType.RightBrace))
            return error!(WorkspaceDecl)("Expected '}' to end workspace body");
        
        return Ok!(WorkspaceDecl, BuildError)(WorkspaceDecl(name, fields, line, col));
    }
    
    /// Parse field assignment
    private BuildResult!WorkspaceField parseField()
    {
        auto token = peek();
        immutable line = token.line, col = token.column;
        
        // Get field name (keyword or identifier)
        string fieldName = token.type == TokenType.Identifier ? advance().value :
            [TokenType.Type: "type", TokenType.Language: "language", TokenType.Sources: "sources",
             TokenType.Deps: "deps", TokenType.Flags: "flags", TokenType.Env: "env",
             TokenType.Output: "output", TokenType.Includes: "includes"].get(token.type, null);
        
        if (fieldName is null) return error!(WorkspaceField)("Expected field name");
        if (token.type != TokenType.Identifier) advance();
        
        if (!match(TokenType.Colon)) return error!(WorkspaceField)("Expected ':' after field name");
        
        auto valueResult = parseExpression();
        if (valueResult.isErr) return Err!(WorkspaceField, BuildError)(valueResult.unwrapErr());
        
        if (!match(TokenType.Semicolon)) return error!(WorkspaceField)("Expected ';' after field value");
        
        return Ok!(WorkspaceField, BuildError)(WorkspaceField(fieldName, valueResult.unwrap(), line, col));
    }
    
    /// Parse expression - fully implemented with support for all literal types
    private BuildResult!Expr parseExpression()
    {
        return parseTernary();
    }
    
    /// Parse ternary conditional: condition ? trueExpr : falseExpr
    private BuildResult!Expr parseTernary()
    {
        auto exprResult = parseLogicalOr();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        if (match(TokenType.Question))
        {
            auto token = previous();
            auto loc = Location(filePath, token.line, token.column);
            
            auto trueResult = parseExpression();
            if (trueResult.isErr) return trueResult;
            
            if (!match(TokenType.Colon))
                return error!Expr("Expected ':' in ternary expression");
            
            auto falseResult = parseExpression();
            if (falseResult.isErr) return falseResult;
            
            return Ok!(Expr, BuildError)(new TernaryExpr(expr, trueResult.unwrap(), falseResult.unwrap(), loc));
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse logical OR: expr || expr
    private BuildResult!Expr parseLogicalOr()
    {
        auto exprResult = parseLogicalAnd();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        while (match(TokenType.PipePipe))
        {
            auto token = previous();
            auto loc = Location(filePath, token.line, token.column);
            auto rightResult = parseLogicalAnd();
            if (rightResult.isErr) return rightResult;
            expr = new BinaryExpr(expr, "||", rightResult.unwrap(), loc);
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse logical AND: expr && expr
    private BuildResult!Expr parseLogicalAnd()
    {
        auto exprResult = parseEquality();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        while (match(TokenType.AmpAmp))
        {
            auto token = previous();
            auto loc = Location(filePath, token.line, token.column);
            auto rightResult = parseEquality();
            if (rightResult.isErr) return rightResult;
            expr = new BinaryExpr(expr, "&&", rightResult.unwrap(), loc);
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse equality: expr == expr, expr != expr
    private BuildResult!Expr parseEquality()
    {
        auto exprResult = parseComparison();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        while (check(TokenType.EqualEqual) || check(TokenType.BangEqual))
        {
            auto token = advance();
            auto loc = Location(filePath, token.line, token.column);
            auto rightResult = parseComparison();
            if (rightResult.isErr) return rightResult;
            string op = token.type == TokenType.EqualEqual ? "==" : "!=";
            expr = new BinaryExpr(expr, op, rightResult.unwrap(), loc);
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse comparison: <, <=, >, >=
    private BuildResult!Expr parseComparison()
    {
        auto exprResult = parseAdditive();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        while (check(TokenType.Less) || check(TokenType.LessEqual) || 
               check(TokenType.Greater) || check(TokenType.GreaterEqual))
        {
            auto token = advance();
            auto loc = Location(filePath, token.line, token.column);
            auto rightResult = parseAdditive();
            if (rightResult.isErr) return rightResult;
            
            immutable string[TokenType] ops = [TokenType.Less: "<", TokenType.LessEqual: "<=",
                                                TokenType.Greater: ">", TokenType.GreaterEqual: ">="];
            expr = new BinaryExpr(expr, ops[token.type], rightResult.unwrap(), loc);
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse additive: + -
    private BuildResult!Expr parseAdditive()
    {
        auto exprResult = parseMultiplicative();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        while (check(TokenType.Plus) || check(TokenType.Minus))
        {
            auto token = advance();
            auto loc = Location(filePath, token.line, token.column);
            auto rightResult = parseMultiplicative();
            if (rightResult.isErr) return rightResult;
            string op = token.type == TokenType.Plus ? "+" : "-";
            expr = new BinaryExpr(expr, op, rightResult.unwrap(), loc);
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse multiplicative: * / %
    private BuildResult!Expr parseMultiplicative()
    {
        auto exprResult = parseUnary();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        while (check(TokenType.Star) || check(TokenType.Slash) || check(TokenType.Percent))
        {
            auto token = advance();
            auto loc = Location(filePath, token.line, token.column);
            auto rightResult = parseUnary();
            if (rightResult.isErr) return rightResult;
            
            immutable string[TokenType] ops = [TokenType.Star: "*", TokenType.Slash: "/", TokenType.Percent: "%"];
            expr = new BinaryExpr(expr, ops[token.type], rightResult.unwrap(), loc);
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse unary: ! -
    private BuildResult!Expr parseUnary()
    {
        if (check(TokenType.Bang) || check(TokenType.Minus))
        {
            auto token = advance();
            auto loc = Location(filePath, token.line, token.column);
            auto operandResult = parseUnary();
            if (operandResult.isErr) return operandResult;
            string op = token.type == TokenType.Bang ? "!" : "-";
            return Ok!(Expr, BuildError)(new UnaryExpr(op, operandResult.unwrap(), loc));
        }
        
        return parsePostfix();
    }
    
    /// Parse postfix: member access, indexing, calls
    private BuildResult!Expr parsePostfix()
    {
        auto exprResult = parsePrimary();
        if (exprResult.isErr) return exprResult;
        auto expr = exprResult.unwrap();
        
        while (true)
        {
            auto token = peek();
            auto loc = Location(filePath, token.line, token.column);
            
            if (match(TokenType.Dot))
            {
                // Member access: expr.member
                if (!check(TokenType.Identifier))
                    return error!Expr("Expected member name after '.'");
                auto member = advance().value;
                expr = new MemberExpr(expr, member, loc);
            }
            else if (match(TokenType.LeftBracket))
            {
                // Index or slice: expr[index] or expr[start:end]
                auto indexResult = parseExpression();
                if (indexResult.isErr) return indexResult;
                
                if (match(TokenType.Colon))
                {
                    // Slice
                    auto endResult = parseExpression();
                    if (endResult.isErr) return endResult;
                    if (!match(TokenType.RightBracket))
                        return error!Expr("Expected ']' after slice");
                    expr = new SliceExpr(expr, indexResult.unwrap(), endResult.unwrap(), loc);
                }
                else
                {
                    // Index
                    if (!match(TokenType.RightBracket))
                        return error!Expr("Expected ']' after index");
                    expr = new IndexExpr(expr, indexResult.unwrap(), loc);
                }
            }
            else if (match(TokenType.LeftParen))
            {
                // Function call: expr(args)
                Expr[] args;
                if (!check(TokenType.RightParen))
                {
                    do {
                        auto argResult = parseExpression();
                        if (argResult.isErr) return argResult;
                        args ~= argResult.unwrap();
                    } while (match(TokenType.Comma));
                }
                
                if (!match(TokenType.RightParen))
                    return error!Expr("Expected ')' after function arguments");
                
                // Extract callee name
                string callee;
                if (auto ident = cast(IdentExpr)expr)
                    callee = ident.name;
                else
                    return error!Expr("Function calls require identifier");
                
                expr = new CallExpr(callee, args, loc);
            }
            else
            {
                break;
            }
        }
        
        return Ok!(Expr, BuildError)(expr);
    }
    
    /// Parse primary: literals, identifiers, arrays, maps, grouped expressions
    private BuildResult!Expr parsePrimary()
    {
        auto token = peek();
        auto loc = Location(filePath, token.line, token.column);
        
        // String literal
        if (token.type == TokenType.String)
        {
            advance();
            return Ok!(Expr, BuildError)(new LiteralExpr(Literal.makeString(token.value), loc));
        }
        
        // Number literal
        if (token.type == TokenType.Number)
        {
            advance();
            try { return Ok!(Expr, BuildError)(new LiteralExpr(Literal.makeNumber(token.value.to!long), loc)); }
            catch (Exception) { return error!Expr("Invalid number: " ~ token.value); }
        }
        
        // Boolean and null literals
        if (token.type == TokenType.True) { advance(); return Ok!(Expr, BuildError)(new LiteralExpr(Literal.makeBool(true), loc)); }
        if (token.type == TokenType.False) { advance(); return Ok!(Expr, BuildError)(new LiteralExpr(Literal.makeBool(false), loc)); }
        if (token.type == TokenType.Null) { advance(); return Ok!(Expr, BuildError)(new LiteralExpr(Literal.makeNull(), loc)); }
        
        // Array literal: [elem1, elem2, ...]
        if (token.type == TokenType.LeftBracket)
        {
            advance();
            Literal[] elements;
            
            if (!check(TokenType.RightBracket))
            {
                do {
                    auto elemResult = parseExpression();
                    if (elemResult.isErr) return elemResult;
                    
                    // Convert expression to literal if possible
                    if (auto litExpr = cast(LiteralExpr)elemResult.unwrap())
                        elements ~= litExpr.value;
                    else
                        return error!Expr("Array elements must be literals in workspace config");
                } while (match(TokenType.Comma));
            }
            
            if (!match(TokenType.RightBracket))
                return error!Expr("Expected ']' after array elements");
            
            return Ok!(Expr, BuildError)(new LiteralExpr(Literal.makeArray(elements), loc));
        }
        
        // Map literal: {key: value, ...}
        if (token.type == TokenType.LeftBrace)
        {
            advance();
            Literal[string] pairs;
            
            if (!check(TokenType.RightBrace))
            {
                do {
                    // Parse key (must be string or identifier)
                    string key;
                    if (check(TokenType.String))
                    {
                        key = advance().value;
                    }
                    else if (check(TokenType.Identifier))
                    {
                        key = advance().value;
                    }
                    else
                    {
                        return error!Expr("Expected string or identifier as map key");
                    }
                    
                    if (!match(TokenType.Colon))
                        return error!Expr("Expected ':' after map key");
                    
                    auto valueResult = parseExpression();
                    if (valueResult.isErr) return valueResult;
                    
                    // Convert expression to literal
                    if (auto litExpr = cast(LiteralExpr)valueResult.unwrap())
                        pairs[key] = litExpr.value;
                    else
                        return error!Expr("Map values must be literals in workspace config");
                } while (match(TokenType.Comma));
            }
            
            if (!match(TokenType.RightBrace))
                return error!Expr("Expected '}' after map pairs");
            
            return Ok!(Expr, BuildError)(new LiteralExpr(Literal.makeMap(pairs), loc));
        }
        
        // Identifier
        if (token.type == TokenType.Identifier)
        {
            advance();
            return Ok!(Expr, BuildError)(new IdentExpr(token.value, loc));
        }
        
        // Grouped expression: (expr)
        if (token.type == TokenType.LeftParen)
        {
            advance();
            auto exprResult = parseExpression();
            if (exprResult.isErr) return exprResult;
            if (!match(TokenType.RightParen)) return error!Expr("Expected ')' after grouped expression");
            return exprResult;
        }
        
        return error!Expr("Expected expression");
    }
    
    /// Parsing utilities
    
    private bool match(TokenType type)
    {
        if (!check(type)) return false;
        advance();
        return true;
    }
    
    private bool check(TokenType type) const { return !isAtEnd() && peek().type == type; }
    
    private Token advance()
    {
        if (!isAtEnd()) current++;
        return previous();
    }
    
    private bool isAtEnd() const { return peek().type == TokenType.EOF; }
    
    private Token peek() const { return tokens[current]; }
    
    private Token previous() const { return tokens[current - 1]; }
    
    private BuildResult!T error(T)(string message)
    {
        auto token = peek();
        return Err!(T, BuildError)(
            Errors.parseAt(filePath, message, token.line, token.column)
                .withSuggestion("Check the Builderspace file syntax")
                .withSuggestion("See docs/architecture/DSL.md for Builderspace syntax reference")
                .withSuggestion("Review examples in the examples/ directory")
                .withSuggestion("Ensure all braces, parentheses, and quotes are properly matched")
                .withLocation(__FILE__, __LINE__)
                .build()
        );
    }
}

/// Semantic analyzer for workspace configuration
struct WorkspaceAnalyzer
{
    private string workspacePath;
    
    this(string workspacePath)
    {
        this.workspacePath = workspacePath;
    }
    
    /// Analyze and apply workspace configuration to WorkspaceConfig
    VoidBuildResult analyze(ref WorkspaceFile ast, ref WorkspaceConfig config)
    {
        auto decl = ast.workspace;
        
        // Parse build options
        if (auto field = decl.getField("cacheDir"))
        {
            auto litExpr = cast(LiteralExpr)field.value;
            if (!litExpr || litExpr.value.kind != LiteralKind.String)
                return error("Field 'cacheDir' must be a string");
            config.options.cacheDir = litExpr.value.asString();
        }
        
        if (auto field = decl.getField("outputDir"))
        {
            auto litExpr = cast(LiteralExpr)field.value;
            if (!litExpr || litExpr.value.kind != LiteralKind.String)
                return error("Field 'outputDir' must be a string");
            config.options.outputDir = litExpr.value.asString();
        }
        
        if (auto field = decl.getField("parallel"))
        {
            auto boolResult = extractBool(field.value);
            if (boolResult.isErr) return error("Field 'parallel' must be a boolean (true/false)");
            config.options.parallel = boolResult.unwrap();
        }
        
        if (auto field = decl.getField("incremental"))
        {
            auto boolResult = extractBool(field.value);
            if (boolResult.isErr) return error("Field 'incremental' must be a boolean (true/false)");
            config.options.incremental = boolResult.unwrap();
        }
        
        if (auto field = decl.getField("incrementalLinking"))
        {
            auto boolResult = extractBool(field.value);
            if (boolResult.isErr) return error("Field 'incrementalLinking' must be a boolean (true/false)");
            config.options.incrementalLinking = boolResult.unwrap();
        }
        
        if (auto field = decl.getField("verbose"))
        {
            auto boolResult = extractBool(field.value);
            if (boolResult.isErr) return error("Field 'verbose' must be a boolean (true/false)");
            config.options.verbose = boolResult.unwrap();
        }
        
        if (auto field = decl.getField("maxJobs"))
        {
            auto numResult = extractNumber(field.value);
            if (numResult.isErr) return error("Field 'maxJobs' must be a number");
            auto value = numResult.unwrap();
            if (value <= 0) return error("Field 'maxJobs' must be positive");
            config.options.maxJobs = cast(size_t)value;
        }
        
        // Parse global environment
        if (auto field = decl.getField("env"))
        {
            auto litExpr = cast(LiteralExpr)field.value;
            if (!litExpr || litExpr.value.kind != LiteralKind.Map)
                return error("Field 'env' must be a map of strings");
            auto result = litExpr.value.toStringMap();
            if (result.isErr) return error("Field 'env' must be a map of strings");
            config.globalEnv = result.unwrap();
        }
        
        // Parse checkpointing configuration
        if (auto field = decl.getField("checkpointing"))
        {
            auto boolResult = extractBool(field.value);
            if (boolResult.isOk)
            {
                config.checkpointing.enabled = boolResult.unwrap();
            }
            else if (auto litExpr = cast(LiteralExpr)field.value)
            {
                if (litExpr.value.kind != LiteralKind.Map)
                    return error("Field 'checkpointing' must be boolean or map");
                auto map = litExpr.value.asMap();
                if (auto enabled = "enabled" in map)
                {
                    auto res = extractBoolFromLiteral(*enabled);
                    if (res.isOk)
                        config.checkpointing.enabled = res.unwrap();
                }
                if (auto interval = "interval" in map)
                    if (interval.kind == LiteralKind.Number)
                        config.checkpointing.interval = cast(size_t)interval.asNumber();
                if (auto path = "path" in map)
                    if (path.kind == LiteralKind.String)
                        config.checkpointing.path = path.asString();
            }
            else return error("Field 'checkpointing' must be boolean or map");
        }
        
        // Parse retry configuration
        if (auto field = decl.getField("retry"))
        {
            auto boolResult = extractBool(field.value);
            if (boolResult.isOk)
            {
                config.retry.enabled = boolResult.unwrap();
            }
            else if (auto litExpr = cast(LiteralExpr)field.value)
            {
                if (litExpr.value.kind != LiteralKind.Map)
                    return error("Field 'retry' must be boolean or map");
                auto map = litExpr.value.asMap();
                if (auto enabled = "enabled" in map)
                {
                    auto res = extractBoolFromLiteral(*enabled);
                    if (res.isOk)
                        config.retry.enabled = res.unwrap();
                }
                if (auto maxAttempts = "maxAttempts" in map)
                    if (maxAttempts.kind == LiteralKind.Number)
                        config.retry.maxAttempts = cast(size_t)maxAttempts.asNumber();
                if (auto backoffMs = "backoffMs" in map)
                    if (backoffMs.kind == LiteralKind.Number)
                        config.retry.backoffMs = cast(size_t)backoffMs.asNumber();
                if (auto exponential = "exponential" in map)
                {
                    auto res = extractBoolFromLiteral(*exponential);
                    if (res.isOk)
                        config.retry.exponentialBackoff = res.unwrap();
                }
            }
            else return error("Field 'retry' must be boolean or map");
        }
        
        // Warn about unknown fields
        immutable knownFields = ["cacheDir", "outputDir", "parallel", "incremental", 
                                  "verbose", "maxJobs", "env", "name", "checkpointing", "retry"];
        
        foreach (field; decl.fields.filter!(f => !knownFields.canFind(f.name)))
        {
            import infrastructure.utils.logging;
            structuredLog.warning("unknown_builderspace_field_").field("detail", "Unknown Builderspace field '" ~ field.name ~ "' will be ignored").emit();
        }
        
        return VoidBuildResult.ok();
    }
    
    private VoidBuildResult error(string message)
    {
        return VoidBuildResult.err(
            Errors.parse(workspacePath, message, Parse.InvalidBuildFile)
                .withSuggestion("Verify the workspace configuration is valid")
                .withSuggestion("Check docs/architecture/DSL.md for valid workspace fields")
                .withSuggestion("Review Builderspace examples in the examples/ directory")
                .withLocation(__FILE__, __LINE__)
                .build()
        );
    }
    
    /// Extract boolean from expression (handles bool literals and strings)
    private BuildResult!bool extractBool(const Expr expr)
    {
        return expr ? extractBoolFromLiteral((cast(LiteralExpr)expr).value) :
            Err!(bool, BuildError)(
                Errors.parse("", "Expected boolean literal", Parse.InvalidFieldValue)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
    }
    
    /// Extract boolean from literal
    private BuildResult!bool extractBoolFromLiteral(Literal lit)
    {
        if (lit.kind == LiteralKind.Bool) return Ok!(bool, BuildError)(lit.asBool());
        
        if (lit.kind == LiteralKind.String)
        {
            immutable val = lit.asString().toLower;
            if (["true", "1", "yes"].canFind(val)) return Ok!(bool, BuildError)(true);
            if (["false", "0", "no"].canFind(val)) return Ok!(bool, BuildError)(false);
        }
        
        return Err!(bool, BuildError)(
            Errors.parse("", "Expected boolean value", Parse.InvalidFieldValue)
                .withLocation(__FILE__, __LINE__)
                .build()
        );
    }
    
    /// Extract number from expression
    private BuildResult!long extractNumber(const Expr expr)
    {
        auto litExpr = cast(LiteralExpr)expr;
        if (!litExpr) return Err!(long, BuildError)(
            Errors.parse("", "Expected number literal", Parse.InvalidFieldValue)
                .withLocation(__FILE__, __LINE__)
                .build()
        );
        
        if (litExpr.value.kind == LiteralKind.Number)
            return Ok!(long, BuildError)(litExpr.value.asNumber());
        
        if (litExpr.value.kind == LiteralKind.String)
        {
            try { return Ok!(long, BuildError)(litExpr.value.asString().to!long); }
            catch (Exception) { return Err!(long, BuildError)(
                Errors.parse("", "Invalid number format", Parse.InvalidFieldValue)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            ); }
        }
        
        return Err!(long, BuildError)(
            Errors.parse("", "Expected number value", Parse.InvalidFieldValue)
                .withLocation(__FILE__, __LINE__)
                .build()
        );
    }
}

/// High-level API for parsing Builderspace files
VoidBuildResult parseWorkspaceDSL(string source, string filePath, ref WorkspaceConfig config)
{
    auto lexResult = lex(source, filePath);
    if (lexResult.isErr) return VoidBuildResult.err(lexResult.unwrapErr());
    
    auto parser = WorkspaceParser(lexResult.unwrap(), filePath);
    auto parseResult = parser.parse();
    if (parseResult.isErr) return VoidBuildResult.err(parseResult.unwrapErr());
    
    auto ast = parseResult.unwrap();
    return WorkspaceAnalyzer(filePath).analyze(ast, config);
}

/// High-level Workspace class for convenient workspace management
class Workspace
{
    private string _rootPath;
    private string _name;
    private WorkspaceConfig _config;
    
    this(string rootPath)
    {
        import std.path : baseName;
        this._rootPath = rootPath;
        this._name = baseName(rootPath);
    }
    
    /// Load workspace from directory
    static Workspace load(string path)
    {
        import std.file : exists, isDir, readText;
        import std.path : buildPath;
        
        if (!exists(path) || !isDir(path)) return null;
        
        auto workspace = new Workspace(path);
        auto builderspacePath = buildPath(path, "Builderspace");
        
        if (exists(builderspacePath))
        {
            try
            {
                auto lexResult = lex(readText(builderspacePath), builderspacePath);
                if (lexResult.isOk)
                {
                    auto parser = WorkspaceParser(lexResult.unwrap(), builderspacePath);
                    auto parseResult = parser.parse();
                    
                    if (parseResult.isOk)
                    {
                        auto wsFile = parseResult.unwrap();
                        workspace._name = wsFile.workspace.name;
                        auto analyzer = WorkspaceAnalyzer(builderspacePath);
                        analyzer.analyze(wsFile, workspace._config);
                    }
                }
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging;
                structuredLog.warning("failed_to_parse_builderspace_file_at_").field("detail", "Failed to parse Builderspace file at " ~ builderspacePath ~ ": " ~ e.msg).emit();
            }
        }
        
        return workspace;
    }
    
    /// Get workspace name
    @property string name() const { return _name; }
    
    /// Get workspace root path
    @property string rootPath() const { return _rootPath; }
    
    /// Find all Builderfiles in workspace
    string[] findBuilderfiles()
    {
        import std.file : dirEntries, SpanMode, isFile;
        import std.algorithm : filter, map;
        import std.array : array;
        import std.path : baseName, relativePath;
        import infrastructure.utils.files.ignore : IgnoreRegistry;
        
        try
        {
            return dirEntries(_rootPath, SpanMode.depth)
                .filter!(e => e.isFile && e.name.baseName == "Builderfile" && 
                              !IgnoreRegistry.shouldIgnorePathAny(relativePath(e.name, _rootPath)))
                .map!(e => e.name)
                .array;
        }
        catch (Exception ex)
        {
            structuredLog.warning("failed_to_find_builderfiles_in_").field("detail", "Failed to find Builderfiles in " ~ _rootPath ~ ": " ~ ex.msg).emit();
            return [];
        }
    }
    
    /// Get workspace configuration
    @property ref WorkspaceConfig config()
    {
        return _config;
    }
}

