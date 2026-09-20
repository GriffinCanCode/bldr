module tests.unit.config.parser;

import std.stdio;
import std.path;
import std.file;
import std.json;
import std.algorithm;
import infrastructure.config.parsing.parser;
import infrastructure.config.schema.schema;
import tests.harness;
import tests.fixtures;
import infrastructure.errors;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Parse valid Builderfile");

    auto tempDir = scoped(new TempDir("config-test"));

    // Create a valid Builderfile in DSL format (simple, no complex deps)
    string builderfileContent = `
target("test-app") {
    type: executable;
    language: python;
    sources: ["main.py", "utils.py"];
}
`;

    tempDir.createFile("Builderfile", builderfileContent);
    tempDir.createFile("main.py", "# Main file");
    tempDir.createFile("utils.py", "# Utils file");

    // Parse the workspace
    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk);

    auto workspace = wsResult.unwrap();
    Assert.notEmpty(workspace.targets);
    auto target = workspace.targets[0];

    Assert.isTrue(target.name.canFind("test-app"));
    Assert.equal(target.type, TargetType.Executable);
    Assert.equal(target.language, TargetLanguage.Python);
    Assert.equal(target.sources.length, 2);

    writeln("\x1b[32m  ✓ Builderfile parsing works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Multiple targets");

    auto tempDir = scoped(new TempDir("config-test"));

    // Create Builderfile with multiple targets in DSL format
    string builderfileContent = `
target("lib") {
    type: library;
    sources: ["lib.py"];
}

target("app") {
    type: executable;
    sources: ["app.py"];
}
`;

    tempDir.createFile("Builderfile", builderfileContent);
    tempDir.createFile("lib.py", "# Library");
    tempDir.createFile("app.py", "# Application");

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk);

    auto workspace = wsResult.unwrap();
    Assert.equal(workspace.targets.length, 2);
    Assert.isTrue(workspace.targets[0].name.canFind("lib"));
    Assert.isTrue(workspace.targets[1].name.canFind("app"));

    writeln("\x1b[32m  ✓ Multiple targets parsed correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Language inference");

    auto tempDir = scoped(new TempDir("parser-test"));

    // Create Builderfile without explicit language in DSL format
    string builderfileContent = `
target("inferred") {
    type: executable;
    sources: ["main.py"];
}
`;

    tempDir.createFile("Builderfile", builderfileContent);
    tempDir.createFile("main.py", "# Python file");

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk);

    auto workspace = wsResult.unwrap();
    Assert.notEmpty(workspace.targets);
    auto target = workspace.targets[0];

    // Language should be inferred from .py extension
    Assert.equal(target.language, TargetLanguage.Python);

    writeln("\x1b[32m  ✓ Language inference works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Glob expansion");

    auto tempDir = scoped(new TempDir("parser-test"));

    // Create multiple source files
    tempDir.createFile("src/a.py", "# A");
    tempDir.createFile("src/b.py", "# B");
    tempDir.createFile("src/c.py", "# C");

    // Create Builderfile with glob pattern in DSL format
    string builderfileContent = `
target("globbed") {
    type: library;
    sources: ["src/*.py"];
}
`;

    tempDir.createFile("Builderfile", builderfileContent);

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk);

    auto workspace = wsResult.unwrap();
    Assert.notEmpty(workspace.targets);
    auto target = workspace.targets[0];

    // Glob should expand to all .py files
    Assert.isTrue(target.sources.length >= 3);

    writeln("\x1b[32m  ✓ Glob pattern expansion works\x1b[0m");
}

/// Language blocks are written the way the rest of a target body is written -
/// `key: value;` per line, no separator after the closing brace. Every
/// language config in the docs and in examples/ uses that shape, so a parser
/// that only accepted JSON-style commas left every one of them unreadable and
/// `langConfig` permanently empty.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Language block with semicolons");

    auto tempDir = scoped(new TempDir("parser-langblock"));
    tempDir.createFile("main.cpp", "int main() { return 0; }");
    tempDir.createFile("Builderfile", `
target("app") {
    type: executable;
    language: cpp;
    sources: ["main.cpp"];
    cpp: {
        std: "c++20";
        optLevel: "O3";
    }
}
`);

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk, "a semicolon-separated language block must parse");

    auto workspace = wsResult.unwrap();
    Assert.notEmpty(workspace.targets);

    auto block = workspace.targets[0].langConfig.get("cpp", "");
    Assert.isTrue(block.length > 0, "cpp block did not reach langConfig");

    auto json = parseJSON(block);
    Assert.equal(json["std"].str, "c++20");
    Assert.equal(json["optLevel"].str, "O3");

    writeln("\x1b[32m  ✓ `cpp: { std: \"c++20\"; }` reaches langConfig\x1b[0m");
}

/// The JSON-ish spelling keeps working; the two are interchangeable.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Language block with commas");

    auto tempDir = scoped(new TempDir("parser-langcomma"));
    tempDir.createFile("main.cpp", "int main() { return 0; }");
    tempDir.createFile("Builderfile", `
target("app") {
    type: executable;
    language: cpp;
    sources: ["main.cpp"];
    cpp: { std: "c++17", optLevel: "O2" };
}
`);

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk, "a comma-separated language block must still parse");

    auto json = parseJSON(wsResult.unwrap().targets[0].langConfig.get("cpp", "{}"));
    Assert.equal(json["std"].str, "c++17");
    Assert.equal(json["optLevel"].str, "O2");

    writeln("\x1b[32m  ✓ Commas and semicolons are interchangeable\x1b[0m");
}

/// The shape the GPU examples use: arrays, booleans and strings together.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Language block with mixed value types");

    auto tempDir = scoped(new TempDir("parser-langmixed"));
    tempDir.createFile("k.cu", "// kernel");
    tempDir.createFile("Builderfile", `
target("kernels") {
    type: library;
    language: cuda;
    sources: ["k.cu"];
    cuda: {
        arch: ["sm_80", "sm_90"];
        opt: "O3";
        fastMath: true;
    }
}
`);

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk, "the shipped GPU example shape must parse");

    auto json = parseJSON(wsResult.unwrap().targets[0].langConfig.get("cuda", "{}"));
    Assert.equal(json["arch"].array.length, 2UL);
    Assert.equal(json["arch"].array[0].str, "sm_80");
    Assert.equal(json["opt"].str, "O3");
    Assert.isTrue(json["fastMath"].boolean);

    writeln("\x1b[32m  ✓ Arrays, strings and booleans all survive the block\x1b[0m");
}

/// Accepting both separators must not mean accepting none: two entries run
/// together are a typo, not a grammar.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Missing separator is still an error");

    auto tempDir = scoped(new TempDir("parser-langbad"));
    tempDir.createFile("main.cpp", "int main() { return 0; }");
    tempDir.createFile("Builderfile", `
target("app") {
    type: executable;
    language: cpp;
    sources: ["main.cpp"];
    cpp: { std: "c++20" optLevel: "O3" }
}
`);

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath(), AggregationPolicy.CollectAll);
    Assert.isTrue(wsResult.isErr, "entries with no separator must be rejected");

    writeln("\x1b[32m  ✓ Run-together entries are rejected\x1b[0m");
}

/// `workspace "name"` opens several of the shipped examples. It is a bare
/// declaration with no body, so the parser has to accept it at top level and
/// carry the name through rather than rejecting the whole file.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Workspace declaration");

    auto tempDir = scoped(new TempDir("parser-workspace"));
    tempDir.createFile("main.cpp", "int main() { return 0; }");
    tempDir.createFile("Builderfile", `
workspace "cuda-kernels"

target("app") {
    type: executable;
    language: cpp;
    sources: ["main.cpp"];
}
`);

    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath());
    Assert.isTrue(wsResult.isOk, "a workspace declaration must not fail the file");

    auto workspace = wsResult.unwrap();
    Assert.equal(workspace.name, "cuda-kernels");
    Assert.equal(workspace.targets.length, 1);

    writeln("\x1b[32m  ✓ `workspace \"name\"` parses and reaches WorkspaceConfig\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m config.parser - Invalid JSON handling");

    auto tempDir = scoped(new TempDir("parser-test"));

    // Create invalid JSON
    tempDir.createFile("Builderfile", "{ invalid json }");

    // Parser should handle gracefully with CollectAll policy
    // When ALL files fail, it returns an error (complete failure)
    auto wsResult = ConfigParser.parseWorkspace(tempDir.getPath(), AggregationPolicy.CollectAll);

    // With CollectAll, if all files fail, we get an error
    // This is correct behavior - complete failure should return Err
    Assert.isTrue(wsResult.isErr);

    writeln("\x1b[32m  ✓ Invalid JSON handled gracefully\x1b[0m");
}

