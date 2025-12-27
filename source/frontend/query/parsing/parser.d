module frontend.query.parsing.parser;

import std.conv : to;
import std.string : format;
import frontend.query.parsing.lexer;
import frontend.query.parsing.ast;
import infrastructure.errors : BuildResult, Errors, Parse, BuildError;

/// Recursive descent parser for bldrquery DSL
/// 
/// Grammar (in EBNF):
/// ```
/// query      := setExpr
/// setExpr    := primary (('+' | '&' | '-') primary)*
/// primary    := function | pattern | '(' query ')'
/// function   := FUNC '(' args ')'
/// args       := query (',' query)*
/// pattern    := PATTERN | STRING
/// ```
struct QueryParser
{
    private Token[] tokens;
    private size_t current = 0;
    
    this(Token[] tokens) pure nothrow @safe
    {
        this.tokens = tokens;
    }
    
    /// Parse tokens into AST
    BuildResult!QueryExpr parse() @system
    {
        if (tokens.length == 0)
            return BuildResult!QueryExpr.err(Errors.parse("N/A", "Empty query", Parse.InvalidInput).build());
        
        try
        {
            auto expr = parseSetExpr();
            
            if (!isAtEnd() && !check(TokenType.EOF))
                return BuildResult!QueryExpr.err(
                    Errors.parse("N/A", format("Unexpected token '%s' at line %d", peek().value, peek().line), 
                                 peek().line, 0, Parse.SyntaxError).build()
                );
            
            return BuildResult!QueryExpr.ok(expr);
        }
        catch (Exception e)
        {
            return BuildResult!QueryExpr.err(Errors.parse("N/A", e.msg, Parse.SyntaxError).build());
        }
    }
    
    /// Parse set expressions (union, intersect, except)
    private QueryExpr parseSetExpr() @safe
    {
        auto left = parsePrimary();
        
        while (!isAtEnd())
        {
            if (match(TokenType.Plus))
            {
                auto right = parsePrimary();
                left = new UnionExpr(left, right);
            }
            else if (match(TokenType.Ampersand))
            {
                auto right = parsePrimary();
                left = new IntersectExpr(left, right);
            }
            else if (match(TokenType.Minus))
            {
                auto right = parsePrimary();
                left = new ExceptExpr(left, right);
            }
            else
            {
                break;
            }
        }
        
        return left;
    }
    
    /// Parse primary expressions
    private QueryExpr parsePrimary() @safe
    {
        // Parenthesized expression
        if (match(TokenType.LeftParen))
        {
            auto expr = parseSetExpr();
            consume(TokenType.RightParen, "Expected ')' after expression");
            return expr;
        }
        
        // Function calls
        if (check(TokenType.Deps))
            return parseDeps();
        if (check(TokenType.Rdeps))
            return parseRdeps();
        if (check(TokenType.AllPaths))
            return parseAllPaths();
        if (check(TokenType.SomePath))
            return parseSomePath();
        if (check(TokenType.Shortest))
            return parseShortest();
        if (check(TokenType.Kind))
            return parseKind();
        if (check(TokenType.Attr))
            return parseAttr();
        if (check(TokenType.Filter))
            return parseFilter();
        if (check(TokenType.Siblings))
            return parseSiblings();
        if (check(TokenType.BuildFiles))
            return parseBuildFiles();
        if (check(TokenType.Let))
            return parseLet();
        
        // Pattern
        if (match(TokenType.Pattern))
            return new TargetPattern(previous().value);
        
        // String as pattern
        if (match(TokenType.String))
            return new TargetPattern(previous().value);
        
        throw Errors.parse("", format("Unexpected token '%s' at line %d", peek().value, peek().line), 
            Parse.Failed).build();
    }
    
    /// Parse deps(expr) or deps(expr, depth)
    private QueryExpr parseDeps() @safe
    {
        consume(TokenType.Deps, "Expected 'deps'");
        consume(TokenType.LeftParen, "Expected '(' after 'deps'");
        
        auto inner = parseSetExpr();
        int depth = -1;
        
        if (match(TokenType.Comma))
        {
            auto depthToken = consume(TokenType.Number, "Expected depth number");
            depth = depthToken.value.to!int;
        }
        
        consume(TokenType.RightParen, "Expected ')' after deps arguments");
        return new DepsExpr(inner, depth);
    }
    
    /// Parse rdeps(expr) or rdeps(expr, depth)
    private QueryExpr parseRdeps() @safe
    {
        consume(TokenType.Rdeps, "Expected 'rdeps'");
        consume(TokenType.LeftParen, "Expected '(' after 'rdeps'");
        
        auto inner = parseSetExpr();
        int depth = -1;
        
        if (match(TokenType.Comma))
        {
            auto depthToken = consume(TokenType.Number, "Expected depth number");
            depth = depthToken.value.to!int;
        }
        
        consume(TokenType.RightParen, "Expected ')' after rdeps arguments");
        return new RdepsExpr(inner, depth);
    }
    
    /// Parse allpaths(from, to)
    private QueryExpr parseAllPaths() @safe
    {
        consume(TokenType.AllPaths, "Expected 'allpaths'");
        consume(TokenType.LeftParen, "Expected '(' after 'allpaths'");
        
        auto from = parseSetExpr();
        consume(TokenType.Comma, "Expected ',' after first argument");
        auto to = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after allpaths arguments");
        return new AllPathsExpr(from, to);
    }
    
    /// Parse somepath(from, to)
    private QueryExpr parseSomePath() @safe
    {
        consume(TokenType.SomePath, "Expected 'somepath'");
        consume(TokenType.LeftParen, "Expected '(' after 'somepath'");
        
        auto from = parseSetExpr();
        consume(TokenType.Comma, "Expected ',' after first argument");
        auto to = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after somepath arguments");
        return new SomePathExpr(from, to);
    }
    
    /// Parse shortest(from, to)
    private QueryExpr parseShortest() @safe
    {
        consume(TokenType.Shortest, "Expected 'shortest'");
        consume(TokenType.LeftParen, "Expected '(' after 'shortest'");
        
        auto from = parseSetExpr();
        consume(TokenType.Comma, "Expected ',' after first argument");
        auto to = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after shortest arguments");
        return new ShortestPathExpr(from, to);
    }
    
    /// Parse kind(type, expr)
    private QueryExpr parseKind() @safe
    {
        consume(TokenType.Kind, "Expected 'kind'");
        consume(TokenType.LeftParen, "Expected '(' after 'kind'");
        
        Token kindToken;
        if (match(TokenType.String))
            kindToken = previous();
        else if (match(TokenType.Identifier))
            kindToken = previous();
        else
            throw Errors.parse("", "Expected kind type (string or identifier)", Parse.Failed).build();
        
        consume(TokenType.Comma, "Expected ',' after kind type");
        auto inner = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after kind arguments");
        return new KindExpr(kindToken.value, inner);
    }
    
    /// Parse attr(name, value, expr)
    private QueryExpr parseAttr() @safe
    {
        consume(TokenType.Attr, "Expected 'attr'");
        consume(TokenType.LeftParen, "Expected '(' after 'attr'");
        
        auto nameToken = consume(TokenType.String, "Expected attribute name");
        consume(TokenType.Comma, "Expected ',' after attribute name");
        auto valueToken = consume(TokenType.String, "Expected attribute value");
        consume(TokenType.Comma, "Expected ',' after attribute value");
        auto inner = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after attr arguments");
        return new AttrExpr(nameToken.value, valueToken.value, inner);
    }
    
    /// Parse filter(attr, regex, expr)
    private QueryExpr parseFilter() @safe
    {
        consume(TokenType.Filter, "Expected 'filter'");
        consume(TokenType.LeftParen, "Expected '(' after 'filter'");
        
        auto attrToken = consume(TokenType.String, "Expected attribute name");
        consume(TokenType.Comma, "Expected ',' after attribute name");
        auto regexToken = consume(TokenType.String, "Expected regex pattern");
        consume(TokenType.Comma, "Expected ',' after regex");
        auto inner = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after filter arguments");
        return new FilterExpr(attrToken.value, regexToken.value, inner);
    }
    
    /// Parse siblings(expr)
    private QueryExpr parseSiblings() @safe
    {
        consume(TokenType.Siblings, "Expected 'siblings'");
        consume(TokenType.LeftParen, "Expected '(' after 'siblings'");
        
        auto inner = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after siblings argument");
        return new SiblingsExpr(inner);
    }
    
    /// Parse buildfiles(pattern)
    private QueryExpr parseBuildFiles() @safe
    {
        consume(TokenType.BuildFiles, "Expected 'buildfiles'");
        consume(TokenType.LeftParen, "Expected '(' after 'buildfiles'");
        
        Token patternToken;
        if (match(TokenType.String))
            patternToken = previous();
        else if (match(TokenType.Pattern))
            patternToken = previous();
        else
            throw Errors.parse("", "Expected pattern (string or target pattern)", Parse.Failed).build();
        
        consume(TokenType.RightParen, "Expected ')' after buildfiles argument");
        return new BuildFilesExpr(patternToken.value);
    }
    
    /// Parse let(var, value, body)
    private QueryExpr parseLet() @safe
    {
        consume(TokenType.Let, "Expected 'let'");
        consume(TokenType.LeftParen, "Expected '(' after 'let'");
        
        auto varToken = consume(TokenType.Identifier, "Expected variable name");
        consume(TokenType.Comma, "Expected ',' after variable name");
        auto value = parseSetExpr();
        consume(TokenType.Comma, "Expected ',' after value expression");
        auto body = parseSetExpr();
        
        consume(TokenType.RightParen, "Expected ')' after let arguments");
        return new LetExpr(varToken.value, value, body);
    }
    
    /// Helper methods
    
    private bool match(TokenType type) pure nothrow @safe
    {
        if (check(type))
        {
            advance();
            return true;
        }
        return false;
    }
    
    private bool check(TokenType type) const pure nothrow @nogc @safe
    {
        if (isAtEnd())
            return false;
        return peek().type == type;
    }
    
    private Token advance() pure nothrow @safe
    {
        if (!isAtEnd())
            current++;
        return previous();
    }
    
    private bool isAtEnd() const pure nothrow @nogc @safe
    {
        return current >= tokens.length || peek().type == TokenType.EOF;
    }
    
    private Token peek() const pure nothrow @nogc @safe
    {
        if (current >= tokens.length)
            return Token(TokenType.EOF, "", 0, 0);
        return tokens[current];
    }
    
    private Token previous() const pure nothrow @nogc @safe
    {
        if (current == 0)
            return Token(TokenType.Invalid, "", 0, 0);
        return tokens[current - 1];
    }
    
    private Token consume(TokenType type, string message) @safe
    {
        if (check(type))
            return advance();
        
        throw Errors.parse("", format("%s at line %d (got '%s')", message, peek().line, peek().value), 
            Parse.Failed).build();
    }
}

