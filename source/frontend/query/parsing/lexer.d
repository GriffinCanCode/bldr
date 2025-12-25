module frontend.query.parsing.lexer;

import std.ascii : isAlpha, isAlphaNum, isDigit, isWhite;
import std.string : strip;
import std.conv : to;
import infrastructure.errors;

/// Token types for bldrquery DSL
enum TokenType
{
    // Literals
    Identifier,
    String,
    Number,
    Pattern,        // //path/... or //path:target
    
    // Functions
    Deps,
    Rdeps,
    AllPaths,
    SomePath,
    Shortest,
    Kind,
    Attr,
    Filter,
    Siblings,
    BuildFiles,
    Let,
    
    // Operators
    Plus,           // +
    Ampersand,      // &
    Minus,          // -
    
    // Delimiters
    LeftParen,      // (
    RightParen,     // )
    Comma,          // ,
    Colon,          // :
    
    // Special
    EOF,
    Invalid
}

/// Token with position tracking
struct Token
{
    TokenType type;
    string value;
    size_t line;
    size_t column;
    
    bool isType(TokenType t) const pure nothrow @nogc @safe
    {
        return type == t;
    }
    
    string typeName() const @safe
    {
        return type.to!string;
    }
}

/// Lexer for bldrquery DSL
struct QueryLexer
{
    private string source;
    private size_t position;
    private size_t line = 1;
    private size_t column = 1;
    
    /// Keywords for O(1) lookup
    private static immutable string[string] keywords;
    
    shared static this()
    {
        keywords = [
            "deps": "deps",
            "rdeps": "rdeps",
            "allpaths": "allpaths",
            "somepath": "somepath",
            "shortest": "shortest",
            "kind": "kind",
            "attr": "attr",
            "filter": "filter",
            "siblings": "siblings",
            "buildfiles": "buildfiles",
            "let": "let"
        ];
    }
    
    this(string source) pure nothrow @safe
    {
        this.source = source.strip();
    }
    
    /// Tokenize entire source
    BuildResult!(Token[]) tokenize() @system
    {
        Token[] tokens;
        tokens.reserve(32);  // Typical query has < 32 tokens
        
        while (!isAtEnd())
        {
            skipWhitespace();
            if (isAtEnd())
                break;
            
            auto tokenResult = scanToken();
            if (tokenResult.isErr)
                return BuildResult!(Token[]).err(tokenResult.unwrapErr());
            
            auto token = tokenResult.unwrap();
            if (token.type != TokenType.Invalid)
                tokens ~= token;
        }
        
        tokens ~= Token(TokenType.EOF, "", line, column);
        return BuildResult!(Token[]).ok(tokens);
    }
    
    private BuildResult!Token scanToken() @system
    {
        char c = peek();
        
        // Target pattern: //...
        if (c == '/' && peekNext() == '/')
            return scanPattern();
        
        // String literals
        if (c == '"' || c == '\'')
            return scanString();
        
        // Numbers
        if (isDigit(c))
            return scanNumber();
        
        // Identifiers and keywords
        if (isAlpha(c) || c == '_')
            return scanIdentifier();
        
        // Operators and delimiters
        size_t startLine = line;
        size_t startCol = column;
        advance();
        
        switch (c)
        {
            case '(': return ok(TokenType.LeftParen, "(", startLine, startCol);
            case ')': return ok(TokenType.RightParen, ")", startLine, startCol);
            case ',': return ok(TokenType.Comma, ",", startLine, startCol);
            case ':': return ok(TokenType.Colon, ":", startLine, startCol);
            case '+': return ok(TokenType.Plus, "+", startLine, startCol);
            case '&': return ok(TokenType.Ampersand, "&", startLine, startCol);
            case '-':
                // Distinguish between minus operator and negative number
                if (isDigit(peek()))
                    return scanNumber(true);
                return ok(TokenType.Minus, "-", startLine, startCol);
            default:
                auto error = new ParseError("query", 
                    "Unexpected character '" ~ c ~ "' at column " ~ startCol.to!string, 
                    ErrorCode.ParseFailed);
                error.line = line;
                error.column = startCol;
                return BuildResult!Token.err(error);
        }
    }
    
    private BuildResult!Token scanPattern() @system
    {
        size_t startLine = line;
        size_t startCol = column;
        string value;
        
        // Consume "//"
        advance();
        advance();
        value = "//";
        
        // Pattern can contain: alphanumeric, -, _, /, :, ., *
        while (!isAtEnd())
        {
            char c = peek();
            if (isAlphaNum(c) || c == '-' || c == '_' || c == '/' || 
                c == ':' || c == '.' || c == '*')
            {
                value ~= c;
                advance();
            }
            else
            {
                break;
            }
        }
        
        return ok(TokenType.Pattern, value, startLine, startCol);
    }
    
    private BuildResult!Token scanString() @system
    {
        size_t startLine = line;
        size_t startCol = column;
        char quote = peek();
        advance();  // Opening quote
        
        string value;
        while (!isAtEnd() && peek() != quote)
        {
            if (peek() == '\\')
            {
                advance();
                if (isAtEnd())
                {
                    auto error = new ParseError("query", 
                        "Unterminated string", 
                        ErrorCode.ParseFailed);
                    error.line = startLine;
                    return BuildResult!Token.err(error);
                }
                
                // Handle escape sequences
                char escaped = peek();
                switch (escaped)
                {
                    case 'n': value ~= '\n'; break;
                    case 't': value ~= '\t'; break;
                    case 'r': value ~= '\r'; break;
                    case '\\': value ~= '\\'; break;
                    case '"': value ~= '"'; break;
                    case '\'': value ~= '\''; break;
                    default: value ~= escaped; break;
                }
                advance();
            }
            else
            {
                value ~= peek();
                advance();
            }
        }
        
        if (isAtEnd())
        {
            auto error = new ParseError("query", 
                "Unterminated string", 
                ErrorCode.ParseFailed);
            error.line = startLine;
            return BuildResult!Token.err(error);
        }
        
        advance();  // Closing quote
        return ok(TokenType.String, value, startLine, startCol);
    }
    
    private BuildResult!Token scanNumber(bool negative = false) @system
    {
        size_t startLine = line;
        size_t startCol = column;
        string value = negative ? "-" : "";
        
        while (!isAtEnd() && isDigit(peek()))
        {
            value ~= peek();
            advance();
        }
        
        return ok(TokenType.Number, value, startLine, startCol);
    }
    
    private BuildResult!Token scanIdentifier() @system
    {
        size_t startLine = line;
        size_t startCol = column;
        string value;
        
        while (!isAtEnd() && (isAlphaNum(peek()) || peek() == '_'))
        {
            value ~= peek();
            advance();
        }
        
        // Check if it's a keyword
        if (auto keywordType = value in keywords)
        {
            switch (*keywordType)
            {
                case "deps": return ok(TokenType.Deps, value, startLine, startCol);
                case "rdeps": return ok(TokenType.Rdeps, value, startLine, startCol);
                case "allpaths": return ok(TokenType.AllPaths, value, startLine, startCol);
                case "somepath": return ok(TokenType.SomePath, value, startLine, startCol);
                case "shortest": return ok(TokenType.Shortest, value, startLine, startCol);
                case "kind": return ok(TokenType.Kind, value, startLine, startCol);
                case "attr": return ok(TokenType.Attr, value, startLine, startCol);
                case "filter": return ok(TokenType.Filter, value, startLine, startCol);
                case "siblings": return ok(TokenType.Siblings, value, startLine, startCol);
                case "buildfiles": return ok(TokenType.BuildFiles, value, startLine, startCol);
                case "let": return ok(TokenType.Let, value, startLine, startCol);
                default: break;
            }
        }
        
        return ok(TokenType.Identifier, value, startLine, startCol);
    }
    
    private void skipWhitespace() @safe
    {
        while (!isAtEnd() && isWhite(peek()))
            advance();
    }
    
    private bool isAtEnd() const pure nothrow @nogc @safe
    {
        return position >= source.length;
    }
    
    private char peek() const pure nothrow @nogc @safe
    {
        if (isAtEnd())
            return '\0';
        return source[position];
    }
    
    private char peekNext() const pure nothrow @nogc @safe
    {
        if (position + 1 >= source.length)
            return '\0';
        return source[position + 1];
    }
    
    private void advance() pure nothrow @safe
    {
        if (!isAtEnd())
        {
            if (source[position] == '\n')
            {
                line++;
                column = 1;
            }
            else
            {
                column++;
            }
            position++;
        }
    }
    
    private BuildResult!Token ok(TokenType type, string value, size_t line, size_t column) 
        const pure nothrow @system
    {
        return BuildResult!Token.ok(Token(type, value, line, column));
    }
}

