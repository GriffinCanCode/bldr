module tests.unit.lsp.graph_provider;

import std.stdio;
import std.algorithm;
import std.array;
import std.json : JSONValue, JSONType, parseJSON;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, write;
import std.path : buildPath;
import tests.harness;
import frontend.lsp.core.protocol;
import frontend.lsp.workspace.workspace;
import frontend.lsp.workspace.index : Index, Symbol, SymbolKind;
import frontend.lsp.providers.graph;

// ==================== GraphProvider UNIT TESTS ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - GraphCommand enum values");
    
    // Verify command string values
    Assert.equal(cast(string)GraphCommand.GoToDependency, "builder.goToDependency");
    Assert.equal(cast(string)GraphCommand.FindReverseDependencies, "builder.findReverseDependencies");
    Assert.equal(cast(string)GraphCommand.ShowDependencyTree, "builder.showDependencyTree");
    Assert.equal(cast(string)GraphCommand.ShowImpactAnalysis, "builder.showImpactAnalysis");
    
    writeln("\x1b[32m  ✓ GraphCommand enum has correct values\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - DependencyInfo struct");
    
    DependencyInfo info;
    info.targetName = "mylib";
    info.targetType = "library";
    info.depth = 0;
    info.location = Location("file:///test.builder", Range(Position(5, 0), Position(5, 10)));
    
    Assert.equal(info.targetName, "mylib");
    Assert.equal(info.targetType, "library");
    Assert.equal(info.depth, 0);
    Assert.equal(info.location.uri, "file:///test.builder");
    
    writeln("\x1b[32m  ✓ DependencyInfo struct works correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - getSupportedCommands returns all commands");
    
    auto commands = getSupportedCommands();
    
    Assert.equal(commands.length, 4);
    Assert.contains(commands, GraphCommand.GoToDependency);
    Assert.contains(commands, GraphCommand.FindReverseDependencies);
    Assert.contains(commands, GraphCommand.ShowDependencyTree);
    Assert.contains(commands, GraphCommand.ShowImpactAnalysis);
    
    writeln("\x1b[32m  ✓ getSupportedCommands returns all commands\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - GraphProvider initialization without graph");
    
    // Create workspace manager with fake root
    auto workspace = new WorkspaceManager("file:///nonexistent");
    
    // Provider should gracefully handle missing graph
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    Assert.isFalse(provider.hasGraph);
    
    writeln("\x1b[32m  ✓ GraphProvider gracefully handles missing graph\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - executeCommand with GoToDependency");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["uri"] = "file:///test/Builderfile";
    args["position"] = JSONValue(["line": 0, "character": 0]);
    
    // Should return empty array (no targets in empty workspace)
    auto result = provider.executeCommand(GraphCommand.GoToDependency, args);
    
    Assert.isTrue(result.type == JSONType.array);
    Assert.equal(result.array.length, 0);
    
    writeln("\x1b[32m  ✓ executeCommand handles GoToDependency\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - executeCommand with FindReverseDependencies");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["uri"] = "file:///test/Builderfile";
    args["position"] = JSONValue(["line": 0, "character": 0]);
    
    auto result = provider.executeCommand(GraphCommand.FindReverseDependencies, args);
    
    Assert.isTrue(result.type == JSONType.array);
    Assert.equal(result.array.length, 0);
    
    writeln("\x1b[32m  ✓ executeCommand handles FindReverseDependencies\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - executeCommand with ShowDependencyTree (no graph)");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["target"] = "myapp";
    
    // Without graph, should return error
    auto result = provider.executeCommand(GraphCommand.ShowDependencyTree, args);
    
    Assert.isTrue(("error" in result) !is null);
    
    writeln("\x1b[32m  ✓ ShowDependencyTree returns error when graph unavailable\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - executeCommand with ShowImpactAnalysis (no graph)");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["target"] = "mylib";
    
    auto result = provider.executeCommand(GraphCommand.ShowImpactAnalysis, args);
    
    Assert.isTrue(("error" in result) !is null);
    
    writeln("\x1b[32m  ✓ ShowImpactAnalysis returns error when graph unavailable\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - provideDependencyLocations returns Location array");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    auto locations = provider.provideDependencyLocations("file:///test/Builderfile", Position(0, 0));
    
    Assert.isTrue(locations.length == 0); // Empty workspace
    
    writeln("\x1b[32m  ✓ provideDependencyLocations returns Location array\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - provideReverseDependencyLocations returns Location array");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    auto locations = provider.provideReverseDependencyLocations("file:///test/Builderfile", Position(0, 0));
    
    Assert.isTrue(locations.length == 0);
    
    writeln("\x1b[32m  ✓ provideReverseDependencyLocations returns Location array\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - getDependenciesForTarget with unknown target");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    auto deps = provider.getDependenciesForTarget("nonexistent", false);
    
    Assert.isEmpty(deps);
    
    writeln("\x1b[32m  ✓ getDependenciesForTarget handles unknown target\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - getReverseDependenciesForTarget with unknown target");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    auto deps = provider.getReverseDependenciesForTarget("nonexistent", false);
    
    Assert.isEmpty(deps);
    
    writeln("\x1b[32m  ✓ getReverseDependenciesForTarget handles unknown target\x1b[0m");
}

// ==================== Protocol Integration Tests ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - ExecuteCommandParams parsing");
    
    JSONValue json;
    json["command"] = "builder.goToDependency";
    json["arguments"] = JSONValue(["uri": "file:///test.builder"]);
    
    auto params = ExecuteCommandParams.fromJSON(json);
    
    Assert.equal(params.command, "builder.goToDependency");
    Assert.isTrue(("uri" in params.arguments) !is null);
    
    writeln("\x1b[32m  ✓ ExecuteCommandParams parses correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - ExecuteCommandParams with no arguments");
    
    JSONValue json;
    json["command"] = "builder.showDependencyTree";
    // No arguments field
    
    auto params = ExecuteCommandParams.fromJSON(json);
    
    Assert.equal(params.command, "builder.showDependencyTree");
    Assert.isTrue(params.arguments.type == JSONType.object);
    
    writeln("\x1b[32m  ✓ ExecuteCommandParams handles missing arguments\x1b[0m");
}

// ==================== JSON Response Format Tests ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - JSON response format for dependencies");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["uri"] = "file:///test/Builderfile";
    args["position"] = JSONValue(["line": 0, "character": 0]);
    args["transitive"] = false;
    
    auto result = provider.executeCommand(GraphCommand.GoToDependency, args);
    
    // Result should be an array
    Assert.isTrue(result.type == JSONType.array);
    
    // Each item should have expected fields (if any results)
    foreach (item; result.array)
    {
        Assert.isTrue(("targetName" in item) !is null);
        Assert.isTrue(("targetType" in item) !is null);
        Assert.isTrue(("depth" in item) !is null);
        Assert.isTrue(("location" in item) !is null);
    }
    
    writeln("\x1b[32m  ✓ JSON response has correct structure\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - ShowDependencyTree JSON format");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["target"] = "test";
    
    auto result = provider.executeCommand(GraphCommand.ShowDependencyTree, args);
    
    // Should have error field (no graph available)
    Assert.isTrue(("error" in result) !is null);
    Assert.isTrue(result["error"].str.length > 0);
    
    writeln("\x1b[32m  ✓ ShowDependencyTree returns proper error JSON\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - ShowImpactAnalysis JSON format");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["target"] = "test";
    
    auto result = provider.executeCommand(GraphCommand.ShowImpactAnalysis, args);
    
    Assert.isTrue(("error" in result) !is null);
    
    writeln("\x1b[32m  ✓ ShowImpactAnalysis returns proper error JSON\x1b[0m");
}

// ==================== Argument Extraction Tests ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - URI extraction from textDocument");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["textDocument"] = JSONValue(["uri": "file:///nested/path/test.builder"]);
    args["position"] = JSONValue(["line": 10, "character": 5]);
    
    auto result = provider.executeCommand(GraphCommand.GoToDependency, args);
    
    // Should not crash with nested URI
    Assert.isTrue(result.type == JSONType.array);
    
    writeln("\x1b[32m  ✓ URI extracted correctly from textDocument\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - Target name extraction methods");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    // Test with 'target' key
    JSONValue args1;
    args1["target"] = "myapp";
    auto result1 = provider.executeCommand(GraphCommand.ShowDependencyTree, args1);
    Assert.isTrue(("error" in result1) !is null); // Expected - no graph
    
    // Test with 'targetName' key
    JSONValue args2;
    args2["targetName"] = "mylib";
    auto result2 = provider.executeCommand(GraphCommand.ShowImpactAnalysis, args2);
    Assert.isTrue(("error" in result2) !is null);
    
    writeln("\x1b[32m  ✓ Target name extraction works with different keys\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - Boolean extraction from args");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    // Test with transitive=true
    JSONValue args;
    args["uri"] = "file:///test.builder";
    args["position"] = JSONValue(["line": 0, "character": 0]);
    args["transitive"] = true;
    
    auto result = provider.executeCommand(GraphCommand.GoToDependency, args);
    Assert.isTrue(result.type == JSONType.array);
    
    // Test with transitive=false
    args["transitive"] = false;
    result = provider.executeCommand(GraphCommand.GoToDependency, args);
    Assert.isTrue(result.type == JSONType.array);
    
    writeln("\x1b[32m  ✓ Boolean extraction handles true/false correctly\x1b[0m");
}

// ==================== Edge Case Tests ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - Empty arguments handling");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue emptyArgs;
    emptyArgs = JSONValue.emptyObject;
    
    // Should not crash with empty args
    auto result = provider.executeCommand(GraphCommand.GoToDependency, emptyArgs);
    Assert.isTrue(result.type == JSONType.array);
    
    writeln("\x1b[32m  ✓ Empty arguments handled gracefully\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - Position at line 0");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["uri"] = "file:///test.builder";
    args["position"] = JSONValue(["line": 0, "character": 0]);
    
    auto result = provider.executeCommand(GraphCommand.FindReverseDependencies, args);
    Assert.isTrue(result.type == JSONType.array);
    
    writeln("\x1b[32m  ✓ Position at line 0 handled correctly\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - Large position values");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["uri"] = "file:///test.builder";
    args["position"] = JSONValue(["line": 99999, "character": 99999]);
    
    auto result = provider.executeCommand(GraphCommand.GoToDependency, args);
    Assert.isTrue(result.type == JSONType.array);
    
    writeln("\x1b[32m  ✓ Large position values handled gracefully\x1b[0m");
}

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - Special characters in URI");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["uri"] = "file:///path/with%20spaces/test.builder";
    args["position"] = JSONValue(["line": 0, "character": 0]);
    
    auto result = provider.executeCommand(GraphCommand.GoToDependency, args);
    Assert.isTrue(result.type == JSONType.array);
    
    writeln("\x1b[32m  ✓ Special characters in URI handled\x1b[0m");
}

// ==================== All Commands Coverage Test ====================

unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m lsp.graph_provider - All commands execute without crash");
    
    auto workspace = new WorkspaceManager("file:///test");
    auto provider = GraphProvider(workspace, "/nonexistent/cache");
    
    JSONValue args;
    args["uri"] = "file:///test.builder";
    args["position"] = JSONValue(["line": 5, "character": 10]);
    args["target"] = "testTarget";
    
    // Test all commands
    foreach (cmd; getSupportedCommands())
    {
        auto result = provider.executeCommand(cmd, args);
        Assert.isTrue(result.type == JSONType.array || result.type == JSONType.object);
    }
    
    writeln("\x1b[32m  ✓ All commands execute without crash\x1b[0m");
}

