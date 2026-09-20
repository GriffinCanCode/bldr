module tests.integration.warm_cache_fidelity;

/// A second build must see the same workspace the first one did.
///
/// bldr persists three things between builds: the parsed workspace config
/// (`config.db`), the dependency graph topology (`graph.mmap`), and per-target
/// build hashes. Each of those was, at one point, narrower than the thing it
/// stood in for - and because a warm build trusts them instead of reparsing,
/// a field missing from a blob did not degrade a cache, it vanished from the
/// build. The symptom was a build system that did not rebuild on a source
/// change, which is the one thing it cannot get wrong.
///
/// These tests drive the persistence round-trip directly, so they fail on the
/// serialization gap rather than on the eventual compiler error.

import std.algorithm : canFind, sort;
import std.array : array;
import std.file : exists, mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln;
import engine.graph.caching.cache : GraphCache;
import engine.graph.core.graph : BuildGraph, ValidationMode;
import infrastructure.config.parsing.parser : ConfigParser;
import infrastructure.config.schema.schema;
import tests.fixtures : TempDir, scoped;
import tests.harness : Assert;

/// Write a workspace whose Builderfile exercises every target field that has
/// to survive a round trip.
private string writeWorkspace(TempDir tmp)
{
    tmp.createFile("lib/math.h", "#pragma once\nint triple(int x);\n");
    tmp.createFile("lib/math.cpp", "#include \"math.h\"\nint triple(int x) { return x * 3; }\n");
    tmp.createFile("app/main.cpp", "#include \"math.h\"\nint main() { return triple(14); }\n");

    // Nested language blocks (`cpp: { ... }`) do not parse today, so the
    // round trip is exercised with the fields the DSL can currently express.
    // langConfig is still asserted below, and becomes meaningful the moment
    // the parser accepts a language block.
    tmp.createFile("Builderfile", `
target("math") {
    type: library;
    language: cpp;
    sources: ["lib/math.cpp"];
    includes: ["lib"];
    flags: ["-DMATH_BUILD"];
    env: {"CC": "clang"};
}

target("app") {
    type: executable;
    language: cpp;
    sources: ["app/main.cpp"];
    deps: [":math"];
    includes: ["lib"];
    output: "app";
}
`);

    return tmp.getPath();
}

/// Everything the DSL declared has to come back out of the config cache. The
/// second build does not reparse, so whatever is missing here is missing from
/// the build itself.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m warm_cache_fidelity - Config cache round-trips every target field");

    auto tmp = scoped(new TempDir("warm-config"));
    auto root = writeWorkspace(tmp.get());

    // First parse populates the cache.
    auto cold = ConfigParser.parseWorkspace(root);
    Assert.isTrue(cold.isOk, "initial parse failed");
    auto coldConfig = cold.unwrap();
    ConfigParser.closeConfigIndex();

    // Second parse is served from it.
    auto warm = ConfigParser.parseWorkspace(root);
    Assert.isTrue(warm.isOk, "cached parse failed");
    auto warmConfig = warm.unwrap();
    ConfigParser.closeConfigIndex();

    Assert.equal(warmConfig.targets.length, coldConfig.targets.length);
    Assert.equal(warmConfig.root, coldConfig.root);

    foreach (ref expected; coldConfig.targets)
    {
        auto actual = warmConfig.findTarget(expected.name);
        Assert.isTrue(actual !is null, "target " ~ expected.name ~ " missing after a cached parse");

        Assert.equal(actual.type, expected.type);
        Assert.equal(actual.language, expected.language, "language lost for " ~ expected.name);
        Assert.equal(actual.sources, expected.sources);
        Assert.equal(actual.deps, expected.deps);
        Assert.equal(actual.includes, expected.includes, "includes lost for " ~ expected.name);
        Assert.equal(actual.flags, expected.flags, "flags lost for " ~ expected.name);
        Assert.equal(actual.outputPath, expected.outputPath);
        Assert.equal(actual.command, expected.command);
        Assert.equal(actual.workdir, expected.workdir);
        Assert.equal(actual.platform, expected.platform);
        Assert.equal(actual.toolchain, expected.toolchain);

        // A language block carries the whole language configuration; losing it
        // silently reverts a target to defaults.
        Assert.equal(actual.langConfig.length, expected.langConfig.length,
                     "langConfig lost for " ~ expected.name);
        foreach (key, value; expected.langConfig)
            Assert.equal(actual.langConfig.get(key, ""), value,
                         "langConfig[" ~ key ~ "] lost for " ~ expected.name);

        Assert.equal(actual.env.length, expected.env.length);
        foreach (key, value; expected.env)
            Assert.equal(actual.env.get(key, ""), value);
    }

    writeln("\x1b[32m  ✓ includes, flags and langConfig survive a cached parse\x1b[0m");
}

/// The graph cache stores topology. A restored graph has to carry edges in
/// both directions, because the scheduler releases a target by walking its
/// dependency's dependents - with only forward edges every dependent waits on
/// a counter nobody decrements and is dropped from the build without a word.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m warm_cache_fidelity - Restored graph keeps edges in both directions");

    auto tmp = scoped(new TempDir("warm-graph"));
    auto root = tmp.getPath();
    tmp.createFile("Builderfile", "# placeholder\n");
    auto configFiles = [buildPath(root, "Builderfile")];

    Target lib;
    lib.name = "//lib:core";
    lib.type = TargetType.Library;
    lib.language = TargetLanguage.Cpp;

    Target app;
    app.name = "//app:main";
    app.type = TargetType.Executable;
    app.language = TargetLanguage.Cpp;
    app.deps = ["//lib:core"];

    auto graph = new BuildGraph(ValidationMode.Deferred, 2);
    Assert.isTrue(graph.addTarget(lib).isOk);
    Assert.isTrue(graph.addTarget(app).isOk);
    Assert.isTrue(graph.addDependency("//app:main", "//lib:core").isOk);

    auto cache = new GraphCache(buildPath(root, ".builder-cache"));
    cache.put(graph, configFiles);

    auto restored = cache.getGraph(configFiles);
    Assert.isTrue(restored.isOk, "graph did not come back from the cache");

    auto reloaded = restored.unwrap();
    auto restoredApp = reloaded.getNodeByKey("//app:main");
    auto restoredLib = reloaded.getNodeByKey("//lib:core");

    Assert.notNull(restoredApp);
    Assert.notNull(restoredLib);

    // Forward edge: the dependent knows what it waits for.
    Assert.equal(restoredApp.dependencyIds.length, 1UL, "forward edge lost");
    Assert.equal(restoredApp.dependencyIds[0].toString(), "//lib:core");

    // Reverse edge: the dependency knows who to release.
    Assert.equal(restoredLib.dependentIds.length, 1UL, "reverse edge lost");
    Assert.equal(restoredLib.dependentIds[0].toString(), "//app:main");

    writeln("\x1b[32m  ✓ A restored dependency can still release its dependents\x1b[0m");
}

/// A graph restored from the cache must not be taken as the definition of its
/// targets. The mapped node record holds an id, a type and edges; the sources
/// are not in it, and a target that reports no sources reads as a target with
/// nothing to check for changes.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m warm_cache_fidelity - Cached graph is topology, not target definitions");

    auto tmp = scoped(new TempDir("warm-topology"));
    auto root = tmp.getPath();
    tmp.createFile("Builderfile", "# placeholder\n");
    tmp.createFile("a.cpp", "int main() { return 0; }\n");
    auto configFiles = [buildPath(root, "Builderfile")];

    Target solo;
    solo.name = "//app:solo";
    solo.type = TargetType.Executable;
    solo.language = TargetLanguage.Cpp;
    solo.sources = [buildPath(root, "a.cpp")];
    solo.includes = ["include"];

    auto graph = new BuildGraph(ValidationMode.Deferred, 1);
    Assert.isTrue(graph.addTarget(solo).isOk);

    auto cache = new GraphCache(buildPath(root, ".builder-cache"));
    cache.put(graph, configFiles);

    auto restored = cache.getGraph(configFiles);
    Assert.isTrue(restored.isOk);

    auto node = restored.unwrap().getNodeByKey("//app:solo");
    Assert.notNull(node);

    // This is the shape of the format, asserted so that nobody later reads a
    // restored node's target as authoritative: the analyzer rehydrates target
    // definitions from the freshly parsed config for exactly this reason.
    Assert.isTrue(node.target.sources.length == 0,
                  "the mapped record does not carry sources; if it now does, " ~
                  "the analyzer's rehydration step should be revisited");

    writeln("\x1b[32m  ✓ Restored nodes carry topology only, as the format intends\x1b[0m");
}
