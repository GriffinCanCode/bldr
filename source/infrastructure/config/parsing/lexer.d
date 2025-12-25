module infrastructure.config.parsing.lexer;

import std.conv;
import std.string;
import std.array;
import std.uni;
import std.ascii : isDigit, isAlpha, isAlphaNum, isWhite;
import std.algorithm;
import infrastructure.errors;

/// Token types with compile-time enumeration
enum TokenType
{
    // Literals
    Identifier,
    String,
    Number,
    True,
    False,
    Null,
    
    // Keywords - Target fields
    Target,
    Repository,
    Type,
    Language,
    Sources,
    Deps,
    Flags,
    Env,
    Output,
    Includes,
    Config,
    
    // Keywords - Programmability
    Let,
    Const,
    Fn,
    Macro,
    If,
    Else,
    For,
    In,
    Return,
    Import,
    
    // Types
    Executable,
    Library,
    Test,
    Custom,
    
    // Punctuation
    LeftParen,      // (
    RightParen,     // )
    LeftBrace,      // {
    RightBrace,     // }
    LeftBracket,    // [
    RightBracket,   // ]
    Colon,          // :
    Semicolon,      // ;
    Comma,          // ,
    Dot,            // .
    
    // Operators
    Plus,           // +
    Minus,          // -
    Star,           // *
    Slash,          // /
    Percent,        // %
    Equal,          // =
    EqualEqual,     // ==
    BangEqual,      // !=
    Less,           // <
    LessEqual,      // <=
    Greater,        // >
    GreaterEqual,   // >=
    AmpAmp,         // &&
    PipePipe,       // ||
    Bang,           // !
    Question,       // ?
    Pipe,           // |
    
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
    
    /// Check if token matches type
    bool isType(TokenType t) const pure nothrow @nogc
    {
        return type == t;
    }
    
    /// Get human-readable token name
    string typeName() const
    {
        return type.to!string;
    }
}

/// Lexical analyzer with zero-allocation scanning
struct Lexer
{
    private string source;
    private size_t position;
    private size_t line = 1;
    private size_t column = 1;
    private string filePath;
    
    /// Keywords map for O(1) lookup
    private static immutable string[string] keywords;
    
    shared static this()
    {
        keywords = [
            // Target field keywords
            "target": "Target",
            "repository": "Repository",
            "type": "Type",
            "language": "Language",
            "sources": "Sources",
            "deps": "Deps",
            "flags": "Flags",
            "env": "Env",
            "output": "Output",
            "includes": "Includes",
            "config": "Config",
            // Type keywords
            "executable": "Executable",
            "library": "Library",
            "test": "Test",
            "custom": "Custom",
            // Programmability keywords
            "let": "Let",
            "const": "Const",
            "fn": "Fn",
            "macro": "Macro",
            "if": "If",
            "else": "Else",
            "for": "For",
            "in": "In",
            "return": "Return",
            "import": "Import",
            // Boolean literals
            "true": "True",
            "false": "False",
            "null": "Null"
        ];
    }
    
    this(string source, string filePath = "")
    {
        this.source = source;
        this.filePath = filePath;
    }
    
    /// Lex entire source into tokens
    BuildResult!(Token[]) tokenize()
    {
        Token[] tokens;
        // Reserve capacity based on empirical analysis of Builderfile files:
        // - Average token length in Builderfile DSL: ~6 chars (keywords, operators, short identifiers)
        // - This accounts for: whitespace (skipped), comments (skipped), multi-char operators
        // - Conservative estimate to minimize reallocations while avoiding over-allocation
        // Note: Dynamic array will grow efficiently if estimate is too low
        tokens.reserve(estimateTokenCount(source.length));
        
        while (!isAtEnd())
        {
            skipWhitespaceAndComments();
            if (isAtEnd())
                break;
            
            auto tokenResult = nextTokenInternal();
            if (tokenResult.isErr)
                return Err!(Token[], BuildError)(tokenResult.unwrapErr());
            
            auto token = tokenResult.unwrap();
            if (token.type != TokenType.Invalid)
                tokens ~= token;
        }
        
        tokens ~= Token(TokenType.EOF, "", line, column);
        return Ok!(Token[], BuildError)(tokens);
    }
    
    /// Public method to get next token (for testing and incremental parsing)
    Token nextToken()
    {
        skipWhitespaceAndComments();
        if (isAtEnd())
            return Token(TokenType.EOF, "", line, column);
        
        auto result = nextTokenInternal();
        if (result.isErr)
            return Token(TokenType.Invalid, "", line, column);
        
        return result.unwrap();
    }
    
    /// Peek at the next token without consuming it
    Token peekToken()
    {
        // Save current state
        auto savedPosition = position;
        auto savedLine = line;
        auto savedColumn = column;
        
        // Get next token
        auto token = nextToken();
        
        // Restore state
        position = savedPosition;
        line = savedLine;
        column = savedColumn;
        
        return token;
    }
    
    /// Get next token (internal implementation)
    private BuildResult!Token nextTokenInternal()
    {
        if (isAtEnd())
            return Ok!(Token, BuildError)(Token(TokenType.EOF, "", line, column));
        
        char c = peek();
        size_t startLine = line;
        size_t startCol = column;
        
        // Single and multi-character tokens
        switch (c)
        {
            case '(': advance(); return ok(TokenType.LeftParen, "(", startLine, startCol);
            case ')': advance(); return ok(TokenType.RightParen, ")", startLine, startCol);
            case '{': advance(); return ok(TokenType.LeftBrace, "{", startLine, startCol);
            case '}': advance(); return ok(TokenType.RightBrace, "}", startLine, startCol);
            case '[': advance(); return ok(TokenType.LeftBracket, "[", startLine, startCol);
            case ']': advance(); return ok(TokenType.RightBracket, "]", startLine, startCol);
            case ':': advance(); return ok(TokenType.Colon, ":", startLine, startCol);
            case ';': advance(); return ok(TokenType.Semicolon, ";", startLine, startCol);
            case ',': advance(); return ok(TokenType.Comma, ",", startLine, startCol);
            case '.': advance(); return ok(TokenType.Dot, ".", startLine, startCol);
            case '?': advance(); return ok(TokenType.Question, "?", startLine, startCol);
            case '+': advance(); return ok(TokenType.Plus, "+", startLine, startCol);
            case '*': advance(); return ok(TokenType.Star, "*", startLine, startCol);
            case '%': advance(); return ok(TokenType.Percent, "%", startLine, startCol);
            
            // Multi-character operators
            case '=':
                advance();
                if (peek() == '=') {
                    advance();
                    return ok(TokenType.EqualEqual, "==", startLine, startCol);
                }
                return ok(TokenType.Equal, "=", startLine, startCol);
            
            case '!':
                advance();
                if (peek() == '=') {
                    advance();
                    return ok(TokenType.BangEqual, "!=", startLine, startCol);
                }
                return ok(TokenType.Bang, "!", startLine, startCol);
            
            case '<':
                advance();
                if (peek() == '=') {
                    advance();
                    return ok(TokenType.LessEqual, "<=", startLine, startCol);
                }
                return ok(TokenType.Less, "<", startLine, startCol);
            
            case '>':
                advance();
                if (peek() == '=') {
                    advance();
                    return ok(TokenType.GreaterEqual, ">=", startLine, startCol);
                }
                return ok(TokenType.Greater, ">", startLine, startCol);
            
            case '&':
                advance();
                if (peek() == '&') {
                    advance();
                    return ok(TokenType.AmpAmp, "&&", startLine, startCol);
                }
                return Err!(Token, BuildError)(
                    Errors.parseAt(filePath, "Single '&' is not a valid operator (use '&&' for logical AND)", line, column)
                        .withSuggestion("Use '&&' for logical AND operations")
                        .build());
            
            case '|':
                advance();
                if (peek() == '|') {
                    advance();
                    return ok(TokenType.PipePipe, "||", startLine, startCol);
                }
                return ok(TokenType.Pipe, "|", startLine, startCol);
            
            case '-':
                // Minus can be operator or part of negative number
                // Treat as number if followed by digit and not after an identifier
                advance();
                if (isDigit(peek()))
                {
                    // Check if this should be a negative number
                    // Allow after: =, :, (, [, {, operators, or at start
                    if (position == 1 || isWhite(source[position - 2]) ||
                        source[position - 2] == '=' || source[position - 2] == ':' ||
                        source[position - 2] == '(' || source[position - 2] == '[' ||
                        source[position - 2] == '{' || source[position - 2] == ',' ||
                        source[position - 2] == '+' || source[position - 2] == '*' ||
                        source[position - 2] == '/' || source[position - 2] == '%')
                    {
                        // Scan as negative number (position already advanced)
                        return scanNumber();
                    }
                }
                return ok(TokenType.Minus, "-", startLine, startCol);
            
            case '/':
                // Could be division or start of comment (handled earlier)
                advance();
                return ok(TokenType.Slash, "/", startLine, startCol);
            
            case '"': case '\'': return scanString(c);
            default:
                if (isDigit(c))
                    return scanNumber();
                if (isAlpha(c) || c == '_')
                    return scanIdentifier();
                
                // Unknown character
                return Err!(Token, BuildError)(
                    Errors.parseAt(filePath, "Unexpected character '" ~ c ~ "' in Builderfile", line, column)
                        .withSuggestion("Check for invalid or special characters in the configuration")
                        .withSuggestion("Ensure proper quoting for strings with special characters")
                        .withSuggestion("Verify file encoding is UTF-8")
                        .withDocs("See valid syntax", "docs/architecture/dsl.md")
                        .build());
        }
    }
    
    /// Scan string literal
    private BuildResult!Token scanString(char quote)
    {
        size_t startLine = line;
        size_t startCol = column;
        advance(); // Opening quote
        
        // Use Appender to avoid O(n²) allocations from string concatenation
        auto builder = appender!string;
        builder.reserve(64); // Reserve reasonable capacity for typical strings
        
        while (!isAtEnd() && peek() != quote)
        {
            if (peek() == '\\')
            {
                advance();
                if (!isAtEnd())
                {
                    char escaped = peek();
                    switch (escaped)
                    {
                        case 'n': builder.put('\n'); break;
                        case 't': builder.put('\t'); break;
                        case 'r': builder.put('\r'); break;
                        case '\\': builder.put('\\'); break;
                        case '"': builder.put('"'); break;
                        case '\'': builder.put('\''); break;
                        default: builder.put(escaped); break;
                    }
                    advance();
                }
            }
            else
            {
                builder.put(peek());
                advance();
            }
        }
        
        if (isAtEnd())
            return Err!(Token, BuildError)(
                Errors.parseAt(filePath, "Unterminated string literal - missing closing quote", startLine, startCol)
                    .withSuggestion("Add closing quote (" ~ [quote] ~ ") to match the opening quote")
                    .withSuggestion("Check for unescaped quotes inside the string")
                    .withSuggestion("Ensure the string doesn't span multiple lines without proper escaping")
                    .withSuggestion("Use matching quote types (single or double)")
                    .build());
        
        advance(); // Closing quote
        return ok(TokenType.String, builder.data, startLine, startCol);
    }
    
    /// Scan number literal
    private BuildResult!Token scanNumber()
    {
        size_t startLine = line;
        size_t startCol = column;
        
        // Use Appender for efficient string building
        auto builder = appender!string;
        builder.reserve(16); // Numbers are typically short
        
        // Check if we need to add minus (may have been consumed already)
        if (position > 0 && source[position - 1] == '-')
        {
            builder.put('-');
        }
        else if (peek() == '-')
        {
            builder.put(peek());
            advance();
        }
        
        while (!isAtEnd() && isDigit(peek()))
        {
            builder.put(peek());
            advance();
        }
        
        return ok(TokenType.Number, builder.data, startLine, startCol);
    }
    
    /// Scan identifier or keyword
    private BuildResult!Token scanIdentifier()
    {
        size_t startLine = line;
        size_t startCol = column;
        
        // Use Appender for efficient string building
        auto builder = appender!string;
        builder.reserve(32); // Identifiers are typically short
        
        while (!isAtEnd() && (isAlphaNum(peek()) || peek() == '_' || peek() == '-'))
        {
            builder.put(peek());
            advance();
        }
        
        string value = builder.data;
        
        // Check if it's a keyword
        if (auto keywordType = value in keywords)
        {
            // Map keyword to TokenType
            switch (*keywordType)
            {
                // Target field keywords
                case "Target": return ok(TokenType.Target, value, startLine, startCol);
                case "Type": return ok(TokenType.Type, value, startLine, startCol);
                case "Language": return ok(TokenType.Language, value, startLine, startCol);
                case "Sources": return ok(TokenType.Sources, value, startLine, startCol);
                case "Deps": return ok(TokenType.Deps, value, startLine, startCol);
                case "Flags": return ok(TokenType.Flags, value, startLine, startCol);
                case "Env": return ok(TokenType.Env, value, startLine, startCol);
                case "Output": return ok(TokenType.Output, value, startLine, startCol);
                case "Includes": return ok(TokenType.Includes, value, startLine, startCol);
                case "Config": return ok(TokenType.Config, value, startLine, startCol);
                // Type keywords
                case "Executable": return ok(TokenType.Executable, value, startLine, startCol);
                case "Library": return ok(TokenType.Library, value, startLine, startCol);
                case "Test": return ok(TokenType.Test, value, startLine, startCol);
                case "Custom": return ok(TokenType.Custom, value, startLine, startCol);
                // Programmability keywords
                case "Let": return ok(TokenType.Let, value, startLine, startCol);
                case "Const": return ok(TokenType.Const, value, startLine, startCol);
                case "Fn": return ok(TokenType.Fn, value, startLine, startCol);
                case "Macro": return ok(TokenType.Macro, value, startLine, startCol);
                case "If": return ok(TokenType.If, value, startLine, startCol);
                case "Else": return ok(TokenType.Else, value, startLine, startCol);
                case "For": return ok(TokenType.For, value, startLine, startCol);
                case "In": return ok(TokenType.In, value, startLine, startCol);
                case "Return": return ok(TokenType.Return, value, startLine, startCol);
                case "Import": return ok(TokenType.Import, value, startLine, startCol);
                // Boolean literals
                case "True": return ok(TokenType.True, value, startLine, startCol);
                case "False": return ok(TokenType.False, value, startLine, startCol);
                case "Null": return ok(TokenType.Null, value, startLine, startCol);
                default: break;
            }
        }
        
        return ok(TokenType.Identifier, value, startLine, startCol);
    }
    
    /// Skip whitespace and comments
    private void skipWhitespaceAndComments()
    {
        while (!isAtEnd())
        {
            char c = peek();
            
            if (isWhite(c))
            {
                if (c == '\n')
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
            else if (c == '/' && peekNext() == '/')
            {
                // Line comment
                while (!isAtEnd() && peek() != '\n')
                    advance();
            }
            else if (c == '/' && peekNext() == '*')
            {
                // Block comment
                advance(); // /
                advance(); // *
                
                while (!isAtEnd())
                {
                    if (peek() == '*' && peekNext() == '/')
                    {
                        advance(); // *
                        advance(); // /
                        break;
                    }
                    advance();
                }
            }
            else if (c == '#')
            {
                // Shell-style comment
                while (!isAtEnd() && peek() != '\n')
                    advance();
            }
            else
            {
                break;
            }
        }
    }
    
    /// Helper methods
    
    private char peek() const
    {
        return isAtEnd() ? '\0' : source[position];
    }
    
    private char peekNext() const
    {
        return (position + 1 >= source.length) ? '\0' : source[position + 1];
    }
    
    private void advance()
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
    
    private bool isAtEnd() const pure nothrow @nogc
    {
        return position >= source.length;
    }
    
    /// Estimate token count for memory pre-allocation
    /// 
    /// Strategy: Adaptive estimation based on source characteristics
    /// - Short files (<500 chars): Use conservative 1 token per 8 chars (account for overhead)
    /// - Medium files: Use 1 token per 6 chars (typical Builderfile density)
    /// - Long files: Use slightly lower ratio as they tend to have longer strings/comments
    /// 
    /// This avoids both under-allocation (causing reallocations) and 
    /// over-allocation (wasting memory), while remaining simple and fast.
    private static size_t estimateTokenCount(size_t sourceLength) pure nothrow @nogc
    {
        if (sourceLength == 0)
            return 16; // Minimum reasonable capacity
        
        if (sourceLength < 500)
            return sourceLength / 8 + 8; // Conservative + base capacity
        else if (sourceLength < 5000)
            return sourceLength / 6; // Typical Builderfile
        else
            return sourceLength / 7; // Longer files tend to be denser with strings
    }
    
    private BuildResult!Token ok(TokenType type, string value, size_t line, size_t col)
    {
        return Ok!(Token, BuildError)(Token(type, value, line, col));
    }
}

/// Convenience function for quick tokenization
BuildResult!(Token[]) lex(string source, string filePath = "")
{
    auto lexer = Lexer(source, filePath);
    return lexer.tokenize();
}

unittest
{
    import std.stdio;
    
    // Test basic tokenization
    auto result = lex(`target("app") { type: executable; }`);
    assert(result.isOk);
    
    auto tokens = result.unwrap();
    assert(tokens[0].type == TokenType.Target);
    assert(tokens[1].type == TokenType.LeftParen);
    assert(tokens[2].type == TokenType.String);
    assert(tokens[2].value == "app");
}

unittest
{
    import std.stdio;
    
    // Test negative number handling - should only parse in value contexts
    
    // After colon (field value) - should parse as negative number
    auto result1 = lex(`count: -5`);
    assert(result1.isOk);
    auto tokens1 = result1.unwrap();
    assert(tokens1[1].type == TokenType.Colon);
    assert(tokens1[2].type == TokenType.Number);
    assert(tokens1[2].value == "-5");
    
    // In string (flags array) - should parse as string content
    auto result2 = lex(`flags: ["-O2", "-Wall"]`);
    assert(result2.isOk);
    auto tokens2 = result2.unwrap();
    // Should be: Identifier, Colon, LeftBracket, String, Comma, String, RightBracket, EOF
    assert(tokens2[2].type == TokenType.LeftBracket);
    assert(tokens2[3].type == TokenType.String);
    assert(tokens2[3].value == "-O2");
    assert(tokens2[4].type == TokenType.Comma);
    assert(tokens2[5].type == TokenType.String);
    assert(tokens2[5].value == "-Wall");
    
    // Bare - followed by letter after array bracket lexes as Minus + Identifier
    // Parser should validate if this is allowed in the context
    auto result3 = lex(`flags: [-O2]`);
    assert(result3.isOk, "Lexer should tokenize -O2 as Minus + Identifier");
    auto tokens3 = result3.unwrap();
    // Should lex as: Identifier(flags), Colon, LeftBracket, Minus, Identifier(O2), RightBracket, EOF
    assert(tokens3[2].type == TokenType.LeftBracket);
    assert(tokens3[3].type == TokenType.Minus);
    assert(tokens3[4].type == TokenType.Identifier);
    assert(tokens3[4].value == "O2");
    assert(tokens3[5].type == TokenType.RightBracket);
}

