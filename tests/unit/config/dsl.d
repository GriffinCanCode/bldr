module tests.unit.config.dsl;

import std.stdio;
import std.path;
import std.file;
import std.algorithm;
import infrastructure.config.parsing.lexer;
import infrastructure.config.workspace.ast;
import infrastructure.config.parsing.unified;
import infrastructure.config.schema.schema;
import tests.harness;
import tests.fixtures;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.dsl - Lexer basic tokenization");
    
    string source = `target("app") { type: executable; }`;
    
    auto result = lex(source);
    Assert.isTrue(result.isOk);
    
    auto tokens = result.unwrap();
    Assert.isTrue(tokens.length > 0);
    
    // Verify token sequence
    Assert.equal(tokens[0].type, TokenType.Target);
    Assert.equal(tokens[1].type, TokenType.LeftParen);
    Assert.equal(tokens[2].type, TokenType.String);
    Assert.equal(tokens[2].value, "app");
    Assert.equal(tokens[3].type, TokenType.RightParen);
    Assert.equal(tokens[4].type, TokenType.LeftBrace);
    Assert.equal(tokens[5].type, TokenType.Type);
    Assert.equal(tokens[6].type, TokenType.Colon);
    Assert.equal(tokens[7].type, TokenType.Executable);
    Assert.equal(tokens[8].type, TokenType.Semicolon);
    Assert.equal(tokens[9].type, TokenType.RightBrace);
    
    writeln("\x1b[32m  ✓ Lexer tokenizes basic DSL correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.dsl - Lexer string literals");
    
    string source = `"hello" 'world' "escaped\"quote"`;
    
    auto result = lex(source);
    Assert.isTrue(result.isOk);
    
    auto tokens = result.unwrap();
    Assert.equal(tokens[0].type, TokenType.String);
    Assert.equal(tokens[0].value, "hello");
    Assert.equal(tokens[1].type, TokenType.String);
    Assert.equal(tokens[1].value, "world");
    Assert.equal(tokens[2].type, TokenType.String);
    Assert.equal(tokens[2].value, `escaped"quote`);
    
    writeln("\x1b[32m  ✓ Lexer handles string literals and escapes\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.dsl - Lexer comments");
    
    string source = `
        // Line comment
        target("app") {
            /* Block comment */
            type: executable; # Shell-style comment
        }
    `;
    
    auto result = lex(source);
    Assert.isTrue(result.isOk);
    
    auto tokens = result.unwrap();
    // Comments should be filtered out
    Assert.isTrue(tokens[0].type == TokenType.Target);
    
    writeln("\x1b[32m  ✓ Lexer handles comments correctly\x1b[0m");
}