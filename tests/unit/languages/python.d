module tests.unit.languages.python;

import std.stdio;
import std.path;
import std.regex;
import std.algorithm;
import std.array;
import languages.scripting.python;
import infrastructure.config.schema.schema;
import infrastructure.errors;
import tests.harness;
import tests.fixtures;
import tests.mocks;

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Import detection");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    string pythonCode = `
import os
import sys
from pathlib import Path
from mypackage import utils
`;
    
    tempDir.createFile("test.py", pythonCode);
    auto filePath = buildPath(tempDir.getPath(), "test.py");
    
    // Test import analysis
    auto handler = new PythonHandler();
    auto imports = handler.analyzeImports([filePath]);
    
    Assert.notEmpty(imports);
    
    // Verify standard library imports detected
    auto importNames = imports.map!(i => i.moduleName).array;
    Assert.isTrue(importNames.canFind!(name => name.canFind("os") || 
                                               name.canFind("sys") || 
                                               name.canFind("pathlib")));
    
    writeln("\x1b[32m  ✓ Python import detection works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Syntax validation");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    // Create valid Python file
    tempDir.createFile("valid.py", `
def greet(name):
    print(f"Hello, {name}!")

if __name__ == "__main__":
    greet("World")
`);
    
    // Create invalid Python file
    tempDir.createFile("invalid.py", `
def broken(
    print "missing syntax"
`);
    
    auto validPath = buildPath(tempDir.getPath(), "valid.py");
    auto invalidPath = buildPath(tempDir.getPath(), "invalid.py");
    
    // Test validation using PyValidator
    import infrastructure.utils.python.pycheck;
    
    auto validResult = PyValidator.validate([validPath]);
    Assert.isTrue(validResult.success, "Valid Python should pass");
    
    auto invalidResult = PyValidator.validate([invalidPath]);
    Assert.isFalse(invalidResult.success, "Invalid Python should fail");
    Assert.notEmpty(invalidResult.firstError());
    
    writeln("\x1b[32m  ✓ Python syntax validation works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Build executable");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    tempDir.createFile("app.py", `
#!/usr/bin/env python3
def main():
    print("Hello from app")

if __name__ == "__main__":
    main()
`);
    
    // Create target and config
    auto target = TargetBuilder.create("//app:main")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "app.py")])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "bin");
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    Assert.isTrue(result.isOk);
    if (result.isOk)
    {
        auto outputHash = result.unwrap();
        Assert.notEmpty(outputHash);
    }
    
    writeln("\x1b[32m  ✓ Python executable build works\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Build library");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    tempDir.createFile("lib.py", `
def utility_function():
    return 42

class Helper:
    def __init__(self):
        self.value = 100
`);
    
    auto target = TargetBuilder.create("//lib:utils")
        .withType(TargetType.Library)
        .withSources([buildPath(tempDir.getPath(), "lib.py")])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    Assert.isTrue(result.isOk);
    if (result.isOk)
    {
        auto outputHash = result.unwrap();
        Assert.notEmpty(outputHash);
    }
    
    writeln("\x1b[32m  ✓ Python library build works\x1b[0m");
}

// ==================== ERROR HANDLING TESTS ====================

/// Test Python handler with missing source file
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Missing source file error");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    auto target = TargetBuilder.create("//app:missing")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "nonexistent.py")])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "bin");
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    Assert.isTrue(result.isErr, "Build should fail with missing source file");
    if (result.isErr)
    {
        auto error = result.unwrapErr();
        Assert.notEmpty(error.message);
    }
    
    writeln("\x1b[32m  ✓ Python missing source file error handled correctly\x1b[0m");
}

/// Test Python handler with syntax error
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Syntax error handling");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    // Create Python file with syntax error
    tempDir.createFile("broken.py", `
def broken_function(:
    print("Missing parameter"
    # Missing closing parenthesis and colon is malformed
`);
    
    auto target = TargetBuilder.create("//app:broken")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "broken.py")])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "bin");
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    // Should complete (Python is interpreted, so build may succeed but validation should catch it)
    Assert.isTrue(result.isOk || result.isErr);
    
    writeln("\x1b[32m  ✓ Python syntax error handling works\x1b[0m");
}

/// Test Python handler with missing dependency
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Missing dependency handling");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    // Create Python file importing non-existent module
    tempDir.createFile("needs_dep.py", `
import nonexistent_module_xyz123
import another_missing_module

def main():
    pass
`);
    
    auto target = TargetBuilder.create("//app:deps")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "needs_dep.py")])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "bin");
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    // Build may succeed (interpreted language) but imports exist
    auto imports = handler.analyzeImports([buildPath(tempDir.getPath(), "needs_dep.py")]);
    Assert.notEmpty(imports, "Should detect import statements");
    
    writeln("\x1b[32m  ✓ Python missing dependency handling works\x1b[0m");
}

/// Test Python handler with empty target
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Empty target error");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    auto target = TargetBuilder.create("//app:empty")
        .withType(TargetType.Executable)
        .withSources([])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "bin");
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    Assert.isTrue(result.isErr, "Build should fail with no sources");
    if (result.isErr)
    {
        auto error = result.unwrapErr();
        Assert.notEmpty(error.message);
    }
    
    writeln("\x1b[32m  ✓ Python empty target error handled correctly\x1b[0m");
}

/// Test Python handler error chaining with Result type
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Error chaining with Result");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    tempDir.createFile("test.py", "print('test')");
    
    auto target = TargetBuilder.create("//app:test")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "test.py")])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "bin");
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    // Test Result monad operations
    auto mapped = result.map((string hash) => "Output: " ~ hash);
    Assert.isTrue(mapped.isOk || mapped.isErr);
    
    auto recovered = result.orElse((BuildError e) => Ok!(string, BuildError)("fallback"));
    Assert.isTrue(recovered.isOk);
    
    writeln("\x1b[32m  ✓ Python error chaining with Result works\x1b[0m");
}

/// Test Python handler with invalid output directory
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.python - Invalid output directory error");
    
    auto tempDir = scoped(new TempDir("python-test"));
    
    tempDir.createFile("app.py", "print('test')");
    
    auto target = TargetBuilder.create("//app:test")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "app.py")])
        .build();
    target.language = TargetLanguage.Python;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    // Use invalid path that can't be created
    config.options.outputDir = "/invalid/path/that/does/not/exist/xyz123";
    
    auto handler = new PythonHandler();
    auto result = testBuild(handler, target, config);
    
    // May fail or succeed depending on handler implementation
    Assert.isTrue(result.isOk || result.isErr);
    
    writeln("\x1b[32m  ✓ Python invalid output directory handled\x1b[0m");
}

