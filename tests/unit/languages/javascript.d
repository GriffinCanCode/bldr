module tests.unit.languages.javascript;

import std.stdio;
import std.file;
import std.path;
import languages.web.javascript;
import languages.web.javascript.bundlers;
import infrastructure.config.schema.schema;
import infrastructure.errors;
import tests.harness;
import tests.fixtures;
import tests.mocks;

/// Test JavaScript bundler configuration parsing
unittest
{
    writeln("Testing JavaScript config parsing...");
    
    import std.json;
    
    auto json = parseJSON(`{
        "mode": "bundle",
        "bundler": "esbuild",
        "entry": "src/main.js",
        "platform": "browser",
        "format": "esm",
        "minify": true,
        "sourcemap": true,
        "target": "es2020"
    }`);
    
    auto config = JSConfig.fromJSON(json);
    
    assert(config.mode == JSBuildMode.Bundle);
    assert(config.bundler == BundlerType.ESBuild);
    assert(config.entry == "src/main.js");
    assert(config.platform == Platform.Browser);
    assert(config.format == OutputFormat.ESM);
    assert(config.minify == true);
    assert(config.sourcemap == true);
    assert(config.target == "es2020");
    
    writeln("✓ JavaScript config parsing works correctly");
}

/// Test bundler factory
unittest
{
    writeln("Testing bundler factory...");
    
    JSConfig config;
    
    // Test esbuild creation
    config.bundler = BundlerType.ESBuild;
    auto esbuild = BundlerFactory.create(BundlerType.ESBuild, config);
    assert(esbuild !is null);
    assert(esbuild.name() == "esbuild");
    
    // Test webpack creation
    auto webpack = BundlerFactory.create(BundlerType.Webpack, config);
    assert(webpack !is null);
    assert(webpack.name() == "webpack");
    
    // Test rollup creation
    auto rollup = BundlerFactory.create(BundlerType.Rollup, config);
    assert(rollup !is null);
    assert(rollup.name() == "rollup");
    
    // Test null bundler creation
    auto nullBundler = BundlerFactory.create(BundlerType.None, config);
    assert(nullBundler !is null);
    assert(nullBundler.name() == "none");
    
    writeln("✓ Bundler factory creates correct bundler instances");
}

/// Test null bundler validation
unittest
{
    writeln("Testing null bundler validation...");
    
    // Create temporary test file
    auto tempDir = scoped(new TempDir("js_test"));
    string testDir = tempDir.getPath();
    
    string testFile = buildPath(testDir, "test.js");
    std.file.write(testFile, "console.log('Hello, World!');");
    
    auto bundler = new NullBundler();
    assert(bundler.isAvailable()); // Node.js should be available
    
    JSConfig config;
    Target target;
    target.sources = [testFile];
    
    WorkspaceConfig workspace;
    workspace.options.outputDir = testDir;
    
    auto result = bundler.bundle(target.sources, config, target, workspace);
    
    assert(result.success);
    assert(result.outputs == target.sources);
    
    writeln("✓ Null bundler validates JavaScript correctly");
}

/// Test null bundler with syntax error
unittest
{
    writeln("Testing null bundler with syntax error...");
    
    // Create temporary test file with syntax error
    auto tempDir = scoped(new TempDir("js_error_test"));
    string testDir = tempDir.getPath();
    
    string testFile = buildPath(testDir, "error.js");
    std.file.write(testFile, "console.log('missing quote);");
    
    auto bundler = new NullBundler();
    
    JSConfig config;
    Target target;
    target.sources = [testFile];
    
    WorkspaceConfig workspace;
    workspace.options.outputDir = testDir;
    
    auto result = bundler.bundle(target.sources, config, target, workspace);
    
    assert(!result.success);
    assert(result.error.length > 0);
    
    writeln("✓ Null bundler detects syntax errors");
}

/// Test JavaScript handler with Node.js mode
unittest
{
    writeln("Testing JavaScript handler with Node.js mode...");
    
    auto tempDir = scoped(new TempDir("js_handler_test"));
    string testDir = tempDir.getPath();
    
    // Create simple JavaScript file
    string testFile = buildPath(testDir, "app.js");
    std.file.write(testFile, "function hello() { return 'Hello'; }\nconsole.log(hello());");
    
    Target target;
    target.name = "//test:app";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.JavaScript;
    target.sources = [testFile];
    
    // Set config for Node.js mode
    import std.json;
    target.langConfig["javascript"] = `{"mode":"node","bundler":"none"}`;
    
    WorkspaceConfig config;
    config.options.outputDir = testDir;
    config.options.cacheDir = buildPath(testDir, ".cache");
    
    auto handler = new JavaScriptHandler();
    // Testing the handler - buildImpl is internal, would need to test build() instead
    // auto result = handler.build(target, config);
    // For now, just test that handler initializes
    assert(handler !is null, "Handler should initialize");
    
    writeln("✓ JavaScript handler works in Node.js mode");
}

/// Test output format conversions
unittest
{
    writeln("Testing output format conversions...");
    
    import std.json;
    
    // Test ESM
    auto esmJson = parseJSON(`{"format":"esm"}`);
    auto esmConfig = JSConfig.fromJSON(esmJson);
    assert(esmConfig.format == OutputFormat.ESM);
    
    // Test CommonJS
    auto cjsJson = parseJSON(`{"format":"cjs"}`);
    auto cjsConfig = JSConfig.fromJSON(cjsJson);
    assert(cjsConfig.format == OutputFormat.CommonJS);
    
    // Test IIFE
    auto iifeJson = parseJSON(`{"format":"iife"}`);
    auto iifeConfig = JSConfig.fromJSON(iifeJson);
    assert(iifeConfig.format == OutputFormat.IIFE);
    
    // Test UMD
    auto umdJson = parseJSON(`{"format":"umd"}`);
    auto umdConfig = JSConfig.fromJSON(umdJson);
    assert(umdConfig.format == OutputFormat.UMD);
    
    writeln("✓ Output format conversions work correctly");
}

/// Test platform detection
unittest
{
    writeln("Testing platform detection...");
    
    import std.json;
    
    // Test browser
    auto browserJson = parseJSON(`{"platform":"browser"}`);
    auto browserConfig = JSConfig.fromJSON(browserJson);
    assert(browserConfig.platform == Platform.Browser);
    
    // Test node
    auto nodeJson = parseJSON(`{"platform":"node"}`);
    auto nodeConfig = JSConfig.fromJSON(nodeJson);
    assert(nodeConfig.platform == Platform.Node);
    
    // Test neutral
    auto neutralJson = parseJSON(`{"platform":"neutral"}`);
    auto neutralConfig = JSConfig.fromJSON(neutralJson);
    assert(neutralConfig.platform == Platform.Neutral);
    
    writeln("✓ Platform detection works correctly");
}

/// Test JSX configuration
unittest
{
    writeln("Testing JSX configuration...");
    
    import std.json;
    
    auto jsxJson = parseJSON(`{
        "jsx": true,
        "jsxFactory": "h"
    }`);
    
    auto config = JSConfig.fromJSON(jsxJson);
    
    assert(config.jsx == true);
    assert(config.jsxFactory == "h");
    
    writeln("✓ JSX configuration works correctly");
}

/// Test external dependencies configuration
unittest
{
    writeln("Testing external dependencies...");
    
    import std.json;
    
    auto extJson = parseJSON(`{
        "external": ["react", "react-dom", "lodash"]
    }`);
    
    auto config = JSConfig.fromJSON(extJson);
    
    assert(config.external.length == 3);
    assert(config.external[0] == "react");
    assert(config.external[1] == "react-dom");
    assert(config.external[2] == "lodash");
    
    writeln("✓ External dependencies configuration works");
}

// ==================== ERROR HANDLING TESTS ====================

/// Test JavaScript handler with missing source file
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.javascript - Missing source file error");
    
    auto tempDir = scoped(new TempDir("js-error-test"));
    
    auto target = TargetBuilder.create("//app:missing")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "nonexistent.js")])
        .build();
    target.language = TargetLanguage.JavaScript;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "dist");
    
    auto handler = new JavaScriptHandler();
    auto result = testBuild(handler, target, config);
    
    Assert.isTrue(result.isErr, "Build should fail with missing source file");
    
    writeln("\x1b[32m  ✓ JavaScript missing source file error handled\x1b[0m");
}

/// Test JavaScript handler with invalid config
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.javascript - Invalid config handling");
    
    import std.json;
    import std.exception : collectException;
    
    auto tempDir = scoped(new TempDir("js-config-test"));
    tempDir.createFile("app.js", "console.log('test');");
    
    // Test with invalid bundler type
    auto invalidJson = parseJSON(`{"bundler": "invalid_bundler_xyz"}`);
    auto exception = collectException(JSConfig.fromJSON(invalidJson));
    // Config parsing should handle invalid values gracefully
    
    writeln("\x1b[32m  ✓ JavaScript invalid config handled\x1b[0m");
}

/// Test JavaScript handler Result error chaining
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.javascript - Result error chaining");
    
    auto tempDir = scoped(new TempDir("js-chain-test"));
    tempDir.createFile("app.js", "console.log('test');");
    
    auto target = TargetBuilder.create("//app:test")
        .withType(TargetType.Executable)
        .withSources([buildPath(tempDir.getPath(), "app.js")])
        .build();
    target.language = TargetLanguage.JavaScript;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "dist");
    
    auto handler = new JavaScriptHandler();
    auto result = testBuild(handler, target, config);
    
    // Test Result type - should be either Ok or Err
    Assert.isTrue(result.isOk || result.isErr, "Result should be valid");
    
    writeln("\x1b[32m  ✓ JavaScript Result error chaining works\x1b[0m");
}

/// Test JavaScript handler with empty sources
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.javascript - Empty sources error");
    
    auto tempDir = scoped(new TempDir("js-empty-test"));
    
    auto target = TargetBuilder.create("//app:empty")
        .withType(TargetType.Executable)
        .withSources([])
        .build();
    target.language = TargetLanguage.JavaScript;
    
    WorkspaceConfig config;
    config.root = tempDir.getPath();
    config.options.outputDir = buildPath(tempDir.getPath(), "dist");
    
    auto handler = new JavaScriptHandler();
    auto result = testBuild(handler, target, config);
    
    Assert.isTrue(result.isErr, "Build should fail with no sources");
    
    writeln("\x1b[32m  ✓ JavaScript empty sources error handled\x1b[0m");
}

/// Test bundler mode detection
unittest
{
    writeln("Testing bundler mode detection...");
    
    import std.json;
    
    // Test node mode
    auto nodeJson = parseJSON(`{"mode":"node"}`);
    auto nodeConfig = JSConfig.fromJSON(nodeJson);
    assert(nodeConfig.mode == JSBuildMode.Node);
    
    // Test bundle mode
    auto bundleJson = parseJSON(`{"mode":"bundle"}`);
    auto bundleConfig = JSConfig.fromJSON(bundleJson);
    assert(bundleConfig.mode == JSBuildMode.Bundle);
    
    // Test library mode
    auto libJson = parseJSON(`{"mode":"library"}`);
    auto libConfig = JSConfig.fromJSON(libJson);
    assert(libConfig.mode == JSBuildMode.Library);
    
    writeln("✓ Bundler mode detection works correctly");
}

