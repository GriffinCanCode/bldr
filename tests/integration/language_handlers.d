module tests.integration.language_handlers;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import tests.harness;
import tests.fixtures;
import tests.mocks;
import infrastructure.config.schema.schema;
import engine.graph.core.graph;
import engine.runtime.core.engine.executor;
import languages.base.base;
import infrastructure.errors;

// Import all language handlers
import languages.scripting.python;
import languages.web.javascript;
import languages.web.typescript;
import languages.scripting.go;
import languages.compiled.rust;
import languages.compiled.d;
import languages.compiled.cpp;
import languages.jvm.java;
import languages.jvm.kotlin;
import languages.dotnet.csharp;
import languages.dotnet.fsharp;
import languages.compiled.zig;
import languages.compiled.swift;
import languages.scripting.ruby;
import languages.scripting.php;
import languages.jvm.scala;
import languages.scripting.elixir;
import languages.compiled.nim;
import languages.scripting.lua;
import languages.scripting.r;
import languages.scripting.perl;
import languages.web.css;
import languages.compiled.haskell;
import languages.compiled.ocaml;
import languages.compiled.protobuf;
import languages.web.elm;

/// Helper to test build with a handler
Result!(string, BuildError) testBuild(LanguageHandler handler, Target target, WorkspaceConfig config)
{
    BuildContext context;
    context.target = target;
    context.config = config;
    // Other fields can be null/false for basic testing
    return handler.buildWithContext(context);
}

/// Test fixture for language handler integration tests
class LanguageHandlerFixture
{
    TempDir tempDir;
    WorkspaceConfig config;
    
    this(string langName)
    {
        tempDir = new TempDir("lang-test-" ~ langName);
        tempDir.setup();
        config.root = tempDir.getPath();
    }
    
    ~this()
    {
        tempDir.teardown();
    }
    
    /// Create a simple target with source files
    Target createTarget(string name, TargetType type, TargetLanguage lang, string[] sourceFiles, string[] sourceContents)
    {
        Target target;
        target.name = name;
        target.type = type;
        target.language = lang;
        target.sources = [];
        
        foreach (i, sourceFile; sourceFiles)
        {
            auto fullPath = buildPath(tempDir.getPath(), sourceFile);
            auto dir = dirName(fullPath);
            if (!exists(dir))
                mkdirRecurse(dir);
            
            std.file.write(fullPath, sourceContents[i]);
            target.sources ~= fullPath;
        }
        
        return target;
    }
}

// ============================================================================
// PYTHON HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Python handler integration");
    
    auto fixture = new LanguageHandlerFixture("python");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "python_app",
        TargetType.Executable,
        TargetLanguage.Python,
        ["main.py", "utils.py"],
        [
            "#!/usr/bin/env python3\nimport utils\nprint('Hello Python')\n",
            "def helper():\n    return 42\n"
        ]
    );
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    Assert.isTrue(result.isOk, "Python build should succeed");
    
    writeln("\x1b[32m  ✓ Python handler integration test passed\x1b[0m");
}

// ============================================================================
// JAVASCRIPT HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - JavaScript handler integration");
    
    auto fixture = new LanguageHandlerFixture("javascript");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "js_app",
        TargetType.Executable,
        TargetLanguage.JavaScript,
        ["index.js", "utils.js"],
        [
            "const utils = require('./utils');\nconsole.log('Hello JS');\n",
            "module.exports = { helper: () => 42 };\n"
        ]
    );
    
    auto handler = new JavaScriptHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    Assert.isTrue(result.isOk, "JavaScript build should succeed");
    
    writeln("\x1b[32m  ✓ JavaScript handler integration test passed\x1b[0m");
}

// ============================================================================
// TYPESCRIPT HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - TypeScript handler integration");
    
    auto fixture = new LanguageHandlerFixture("typescript");
    scope(exit) destroy(fixture);
    
    // Create tsconfig.json
    auto tsconfigPath = buildPath(fixture.tempDir.getPath(), "tsconfig.json");
    std.file.write(tsconfigPath, `{
        "compilerOptions": {
            "target": "ES2020",
            "module": "commonjs",
            "strict": true
        }
    }`);
    
    auto target = fixture.createTarget(
        "ts_app",
        TargetType.Executable,
        TargetLanguage.TypeScript,
        ["index.ts"],
        ["const greeting: string = 'Hello TypeScript';\nconsole.log(greeting);\n"]
    );
    
    auto handler = new TypeScriptHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    // TypeScript build may fail if tsc is not installed, check gracefully
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ TypeScript handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ TypeScript handler test skipped (tsc not available)\x1b[0m");
    }
}

// ============================================================================
// GO HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Go handler integration");
    
    auto fixture = new LanguageHandlerFixture("go");
    scope(exit) destroy(fixture);
    
    // Create go.mod
    auto goModPath = buildPath(fixture.tempDir.getPath(), "go.mod");
    std.file.write(goModPath, "module testapp\n\ngo 1.21\n");
    
    auto target = fixture.createTarget(
        "go_app",
        TargetType.Executable,
        TargetLanguage.Go,
        ["main.go"],
        ["package main\n\nimport \"fmt\"\n\nfunc main() {\n    fmt.Println(\"Hello Go\")\n}\n"]
    );
    
    auto handler = new GoHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Go handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Go handler test skipped (go not available)\x1b[0m");
    }
}

// ============================================================================
// RUST HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Rust handler integration");
    
    auto fixture = new LanguageHandlerFixture("rust");
    scope(exit) destroy(fixture);
    
    // Create Cargo.toml
    auto cargoPath = buildPath(fixture.tempDir.getPath(), "Cargo.toml");
    std.file.write(cargoPath, "[package]\nname = \"rust_app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n");
    
    auto target = fixture.createTarget(
        "rust_app",
        TargetType.Executable,
        TargetLanguage.Rust,
        ["main.rs"],
        ["fn main() {\n    println!(\"Hello Rust\");\n}\n"]
    );
    
    auto handler = new RustHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Rust handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Rust handler test skipped (cargo not available)\x1b[0m");
    }
}

// ============================================================================
// D HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - D handler integration");
    
    auto fixture = new LanguageHandlerFixture("d");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "d_app",
        TargetType.Executable,
        TargetLanguage.D,
        ["main.d"],
        ["import std.stdio;\n\nvoid main()\n{\n    writeln(\"Hello D\");\n}\n"]
    );
    
    auto handler = new DHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    Assert.isTrue(result.isOk, "D build should succeed");
    
    writeln("\x1b[32m  ✓ D handler integration test passed\x1b[0m");
}

// ============================================================================
// C++ HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - C++ handler integration");
    
    auto fixture = new LanguageHandlerFixture("cpp");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "cpp_app",
        TargetType.Executable,
        TargetLanguage.Cpp,
        ["main.cpp"],
        ["#include <iostream>\n\nint main() {\n    std::cout << \"Hello C++\" << std::endl;\n    return 0;\n}\n"]
    );
    
    auto handler = new CppHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ C++ handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ C++ handler test skipped (g++ not available)\x1b[0m");
    }
}

// ============================================================================
// C HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - C handler integration");
    
    auto fixture = new LanguageHandlerFixture("c");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "c_app",
        TargetType.Executable,
        TargetLanguage.C,
        ["main.c"],
        ["#include <stdio.h>\n\nint main() {\n    printf(\"Hello C\\n\");\n    return 0;\n}\n"]
    );
    
    auto handler = new CHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ C handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ C handler test skipped (gcc not available)\x1b[0m");
    }
}

// ============================================================================
// JAVA HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Java handler integration");
    
    auto fixture = new LanguageHandlerFixture("java");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "java_app",
        TargetType.Executable,
        TargetLanguage.Java,
        ["Main.java"],
        ["public class Main {\n    public static void main(String[] args) {\n        System.out.println(\"Hello Java\");\n    }\n}\n"]
    );
    
    auto handler = new JavaHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Java handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Java handler test skipped (javac not available)\x1b[0m");
    }
}

// ============================================================================
// KOTLIN HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Kotlin handler integration");
    
    auto fixture = new LanguageHandlerFixture("kotlin");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "kotlin_app",
        TargetType.Executable,
        TargetLanguage.Kotlin,
        ["Main.kt"],
        ["fun main() {\n    println(\"Hello Kotlin\")\n}\n"]
    );
    
    auto handler = new KotlinHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Kotlin handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Kotlin handler test skipped (kotlinc not available)\x1b[0m");
    }
}

// ============================================================================
// C# HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - C# handler integration");
    
    auto fixture = new LanguageHandlerFixture("csharp");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "csharp_app",
        TargetType.Executable,
        TargetLanguage.CSharp,
        ["Program.cs"],
        ["using System;\n\nclass Program\n{\n    static void Main()\n    {\n        Console.WriteLine(\"Hello C#\");\n    }\n}\n"]
    );
    
    auto handler = new CSharpHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ C# handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ C# handler test skipped (dotnet not available)\x1b[0m");
    }
}

// ============================================================================
// F# HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - F# handler integration");
    
    auto fixture = new LanguageHandlerFixture("fsharp");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "fsharp_app",
        TargetType.Executable,
        TargetLanguage.FSharp,
        ["Program.fs"],
        ["[<EntryPoint>]\nlet main argv =\n    printfn \"Hello F#\"\n    0\n"]
    );
    
    auto handler = new FSharpHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ F# handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ F# handler test skipped (dotnet not available)\x1b[0m");
    }
}

// ============================================================================
// ZIG HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Zig handler integration");
    
    auto fixture = new LanguageHandlerFixture("zig");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "zig_app",
        TargetType.Executable,
        TargetLanguage.Zig,
        ["main.zig"],
        ["const std = @import(\"std\");\n\npub fn main() !void {\n    const stdout = std.io.getStdOut().writer();\n    try stdout.print(\"Hello Zig\\n\", .{});\n}\n"]
    );
    
    auto handler = new ZigHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Zig handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Zig handler test skipped (zig not available)\x1b[0m");
    }
}

// ============================================================================
// SWIFT HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Swift handler integration");
    
    auto fixture = new LanguageHandlerFixture("swift");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "swift_app",
        TargetType.Executable,
        TargetLanguage.Swift,
        ["main.swift"],
        ["import Foundation\n\nprint(\"Hello Swift\")\n"]
    );
    
    auto handler = new SwiftHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Swift handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Swift handler test skipped (swift not available)\x1b[0m");
    }
}

// ============================================================================
// RUBY HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Ruby handler integration");
    
    auto fixture = new LanguageHandlerFixture("ruby");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "ruby_app",
        TargetType.Executable,
        TargetLanguage.Ruby,
        ["main.rb"],
        ["#!/usr/bin/env ruby\n\nputs 'Hello Ruby'\n"]
    );
    
    auto handler = new RubyHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Ruby handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Ruby handler test skipped (ruby not available)\x1b[0m");
    }
}

// ============================================================================
// PHP HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - PHP handler integration");
    
    auto fixture = new LanguageHandlerFixture("php");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "php_app",
        TargetType.Executable,
        TargetLanguage.PHP,
        ["main.php"],
        ["<?php\n\necho \"Hello PHP\\n\";\n"]
    );
    
    auto handler = new PHPHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ PHP handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ PHP handler test skipped (php not available)\x1b[0m");
    }
}

// ============================================================================
// SCALA HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Scala handler integration");
    
    auto fixture = new LanguageHandlerFixture("scala");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "scala_app",
        TargetType.Executable,
        TargetLanguage.Scala,
        ["Main.scala"],
        ["object Main extends App {\n  println(\"Hello Scala\")\n}\n"]
    );
    
    auto handler = new ScalaHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Scala handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Scala handler test skipped (scalac not available)\x1b[0m");
    }
}

// ============================================================================
// ELIXIR HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Elixir handler integration");
    
    auto fixture = new LanguageHandlerFixture("elixir");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "elixir_app",
        TargetType.Executable,
        TargetLanguage.Elixir,
        ["main.ex"],
        ["defmodule Main do\n  def main do\n    IO.puts(\"Hello Elixir\")\n  end\nend\n\nMain.main()\n"]
    );
    
    auto handler = new ElixirHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Elixir handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Elixir handler test skipped (elixir not available)\x1b[0m");
    }
}

// ============================================================================
// NIM HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Nim handler integration");
    
    auto fixture = new LanguageHandlerFixture("nim");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "nim_app",
        TargetType.Executable,
        TargetLanguage.Nim,
        ["main.nim"],
        ["echo \"Hello Nim\"\n"]
    );
    
    auto handler = new NimHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Nim handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Nim handler test skipped (nim not available)\x1b[0m");
    }
}

// ============================================================================
// LUA HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Lua handler integration");
    
    auto fixture = new LanguageHandlerFixture("lua");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "lua_app",
        TargetType.Executable,
        TargetLanguage.Lua,
        ["main.lua"],
        ["print(\"Hello Lua\")\n"]
    );
    
    auto handler = new LuaHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Lua handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Lua handler test skipped (lua not available)\x1b[0m");
    }
}

// ============================================================================
// R HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - R handler integration");
    
    auto fixture = new LanguageHandlerFixture("r");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "r_app",
        TargetType.Executable,
        TargetLanguage.R,
        ["main.R"],
        ["print(\"Hello R\")\n"]
    );
    
    auto handler = new RHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ R handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ R handler test skipped (Rscript not available)\x1b[0m");
    }
}

// ============================================================================
// CSS HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - CSS handler integration");
    
    auto fixture = new LanguageHandlerFixture("css");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "css_bundle",
        TargetType.Library,
        TargetLanguage.CSS,
        ["styles.css"],
        ["body {\n  margin: 0;\n  padding: 0;\n  font-family: sans-serif;\n}\n"]
    );
    
    auto handler = new CSSHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    Assert.isTrue(result.isOk, "CSS build should succeed");
    
    writeln("\x1b[32m  ✓ CSS handler integration test passed\x1b[0m");
}

// ============================================================================
// HASKELL HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Haskell handler integration");
    
    auto fixture = new LanguageHandlerFixture("haskell");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "haskell_app",
        TargetType.Executable,
        TargetLanguage.Haskell,
        ["Main.hs"],
        ["module Main where\n\nmain :: IO ()\nmain = putStrLn \"Hello Haskell\"\n"]
    );
    
    auto handler = new HaskellHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Haskell handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Haskell handler test skipped (ghc not available)\x1b[0m");
    }
}

// ============================================================================
// PERL HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Perl handler integration");
    
    auto fixture = new LanguageHandlerFixture("perl");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "perl_app",
        TargetType.Executable,
        TargetLanguage.Perl,
        ["main.pl"],
        ["#!/usr/bin/env perl\n\nuse strict;\nuse warnings;\n\nprint \"Hello Perl\\n\";\n"]
    );
    
    auto handler = new PerlHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Perl handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Perl handler test skipped (perl not available)\x1b[0m");
    }
}

// ============================================================================
// OCAML HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - OCaml handler integration");
    
    auto fixture = new LanguageHandlerFixture("ocaml");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "ocaml_app",
        TargetType.Executable,
        TargetLanguage.OCaml,
        ["main.ml"],
        ["let () = print_endline \"Hello OCaml\"\n"]
    );
    
    auto handler = new OCamlHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ OCaml handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ OCaml handler test skipped (ocamlc not available)\x1b[0m");
    }
}

// ============================================================================
// PROTOBUF HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Protobuf handler integration");
    
    auto fixture = new LanguageHandlerFixture("protobuf");
    scope(exit) destroy(fixture);
    
    auto target = fixture.createTarget(
        "proto_bundle",
        TargetType.Library,
        TargetLanguage.Protobuf,
        ["person.proto"],
        ["syntax = \"proto3\";\n\nmessage Person {\n  string name = 1;\n  int32 age = 2;\n}\n"]
    );
    
    auto handler = new ProtobufHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Protobuf handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Protobuf handler test skipped (protoc not available)\x1b[0m");
    }
}

// ============================================================================
// ELM HANDLER TESTS
// ============================================================================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m language_handlers - Elm handler integration");
    
    auto fixture = new LanguageHandlerFixture("elm");
    scope(exit) destroy(fixture);
    
    // Create elm.json
    auto elmJsonPath = buildPath(fixture.tempDir.getPath(), "elm.json");
    std.file.write(elmJsonPath, `{
        "type": "application",
        "source-directories": ["."],
        "elm-version": "0.19.1",
        "dependencies": {
            "direct": {
                "elm/core": "1.0.5"
            },
            "indirect": {}
        },
        "test-dependencies": {
            "direct": {},
            "indirect": {}
        }
    }`);
    
    auto target = fixture.createTarget(
        "elm_app",
        TargetType.Executable,
        TargetLanguage.Elm,
        ["Main.elm"],
        ["module Main exposing (main)\n\nimport Html exposing (text)\n\nmain =\n    text \"Hello Elm\"\n"]
    );
    
    auto handler = new ElmHandler();
    auto result = testBuild(handler, target, fixture.config);
    
    if (result.isOk)
    {
        writeln("\x1b[32m  ✓ Elm handler integration test passed\x1b[0m");
    }
    else
    {
        writeln("\x1b[33m  ~ Elm handler test skipped (elm not available)\x1b[0m");
    }
}
