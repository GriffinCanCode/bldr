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

