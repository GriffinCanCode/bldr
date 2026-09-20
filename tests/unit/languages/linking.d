module tests.unit.languages.linking;

import std.algorithm : canFind, countUntil;
import std.file : mkdirRecurse, write;
import std.path : buildPath, isAbsolute;
import std.stdio : writeln;
import infrastructure.config.schema.schema;
import languages.base.linking;
import languages.base.types : OutputType;
import tests.fixtures : TempDir, scoped;
import tests.harness : Assert;

/// Build a workspace whose output directory exists on disk, so that predicted
/// artifacts can be made present or absent per test.
private WorkspaceConfig workspaceAt(string root, Target[] targets)
{
    WorkspaceConfig config;
    config.root = root;
    config.options.outputDir = buildPath(root, "bin");
    config.targets = targets;
    mkdirRecurse(config.options.outputDir);
    return config;
}

private Target library(string name, string[] deps = null, string[string] langConfig = null)
{
    Target target;
    target.name = name;
    target.type = TargetType.Library;
    target.language = TargetLanguage.Cpp;
    target.deps = deps;
    target.sources = ["src.cpp"];
    foreach (key, value; langConfig)
        target.langConfig[key] = value;
    return target;
}

private Target executable(string name, string[] deps = null)
{
    Target target;
    target.name = name;
    target.type = TargetType.Executable;
    target.language = TargetLanguage.Cpp;
    target.deps = deps;
    target.sources = ["main.cpp"];
    return target;
}

/// Write the artifact each library target is predicted to produce, so the
/// closure sees them as present.
private void materialize(in WorkspaceConfig config, in LinkClosure closure)
{
    foreach (input; closure.inputs)
        if (input.artifact.length)
            write(input.artifact, "archive");
}

/// A target with no deps contributes nothing to its own link line.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - No deps yields empty closure");

    auto tmp = scoped(new TempDir("link-none"));
    auto config = workspaceAt(tmp.getPath(), [executable("//app:main")]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.isTrue(closure.empty);
    Assert.isTrue(closure.artifacts().length == 0);
    Assert.isTrue(cFamilyLinkArgs(closure).length == 0);

    writeln("\x1b[32m  ✓ Empty closure for a dependency-free target\x1b[0m");
}

/// A library dep is predicted at the platform-correct archive name under the
/// workspace output directory — the same place its own builder writes it.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Direct library dep predicts its archive");

    auto tmp = scoped(new TempDir("link-direct"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:core"]),
        library("//lib:core")
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.equal(closure.inputs.length, 1UL);
    Assert.equal(closure.inputs[0].target, "//lib:core");
    Assert.isTrue(closure.inputs[0].direct);
    Assert.equal(closure.inputs[0].kind, LinkKind.Static);
    Assert.equal(closure.inputs[0].artifact,
                 buildPath(config.options.outputDir, artifactFileName("core", OutputType.StaticLib)));
    Assert.equal(closure.inputs[0].libName, "core");

    writeln("\x1b[32m  ✓ Predicted artifact matches the builder's own naming\x1b[0m");
}

/// The closure is transitive: a static archive records nothing about its own
/// dependencies, so they have to reach the final link line.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Closure is transitive");

    auto tmp = scoped(new TempDir("link-transitive"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:mid"]),
        library("//lib:mid", ["//lib:base"]),
        library("//lib:base")
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.equal(closure.inputs.length, 2UL);
    Assert.equal(closure.inputs[0].target, "//lib:mid");
    Assert.equal(closure.inputs[1].target, "//lib:base");
    Assert.isTrue(closure.inputs[0].direct);
    Assert.isFalse(closure.inputs[1].direct);

    writeln("\x1b[32m  ✓ Transitive dependency reaches the link line\x1b[0m");
}

/// Order is topological regardless of the order deps were declared in: the
/// linker reads archives once, left to right.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Order is topological, not declaration order");

    auto tmp = scoped(new TempDir("link-order"));

    // `base` is declared first but `front` depends on it, so `front` must
    // still be linked ahead of it.
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:base", "//lib:front"]),
        library("//lib:front", ["//lib:base"]),
        library("//lib:base")
    ]);

    auto closure = linkClosure(config.targets[0], config);
    auto names = closure.inputs;

    Assert.equal(names.length, 2UL);
    auto front = names.countUntil!(i => i.target == "//lib:front");
    auto base = names.countUntil!(i => i.target == "//lib:base");
    Assert.isTrue(front < base);

    writeln("\x1b[32m  ✓ Dependent precedes its dependency\x1b[0m");
}

/// A diamond yields each library once, still after everything that needs it.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Diamond deduplicates and stays ordered");

    auto tmp = scoped(new TempDir("link-diamond"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:left", "//lib:right"]),
        library("//lib:left", ["//lib:common"]),
        library("//lib:right", ["//lib:common"]),
        library("//lib:common")
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.equal(closure.inputs.length, 3UL);

    auto left = closure.inputs.countUntil!(i => i.target == "//lib:left");
    auto right = closure.inputs.countUntil!(i => i.target == "//lib:right");
    auto common = closure.inputs.countUntil!(i => i.target == "//lib:common");

    Assert.isTrue(left < common);
    Assert.isTrue(right < common);

    writeln("\x1b[32m  ✓ Shared dependency appears once, after both dependents\x1b[0m");
}

/// Static versus shared is the dependency's own declaration, and a shared
/// dependency also contributes an absolute rpath.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Shared dep is classified from its own config");

    auto tmp = scoped(new TempDir("link-shared"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:dyn"]),
        library("//lib:dyn", null, ["cpp": `{"outputType": "shared"}`])
    ]);

    auto closure = linkClosure(config.targets[0], config);
    Assert.equal(closure.inputs[0].kind, LinkKind.Shared);
    Assert.equal(closure.inputs[0].artifact,
                 buildPath(config.options.outputDir, artifactFileName("dyn", OutputType.SharedLib)));

    materialize(config, closure);
    closure = linkClosure(config.targets[0], config);

    auto args = cFamilyLinkArgs(closure);
    Assert.isTrue(args.canFind("-L" ~ config.options.outputDir));
    Assert.isTrue(args.canFind("-ldyn"));

    auto rpaths = closure.rpathDirs();
    Assert.equal(rpaths.length, 1UL);
    Assert.isTrue(rpaths[0].isAbsolute);

    writeln("\x1b[32m  ✓ Shared dep links by name and carries an absolute rpath\x1b[0m");
}

/// A header-only dependency exports include directories and nothing to link.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Header-only dep contributes includes only");

    auto tmp = scoped(new TempDir("link-headers"));
    auto headerLib = library("//lib:hdr");
    headerLib.sources = ["include/only.hpp"];
    headerLib.includes = ["include"];

    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:hdr"]),
        headerLib
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.equal(closure.inputs.length, 1UL);
    Assert.equal(closure.inputs[0].kind, LinkKind.HeaderOnly);
    Assert.equal(closure.artifacts().length, 0UL);
    Assert.equal(closure.absent.length, 0UL);
    Assert.isTrue(closure.includeDirs().canFind("include"));
    Assert.equal(cFamilyLinkArgs(closure).length, 0UL);

    writeln("\x1b[32m  ✓ Header-only dep adds an include dir and no link input\x1b[0m");
}

/// Traversal stops at anything that is not a library: a dep on a tool is an
/// ordering edge, and the tool's own libraries are not the dependent's.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Non-library dep stops traversal");

    auto tmp = scoped(new TempDir("link-stop"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//tools:codegen"]),
        executable("//tools:codegen", ["//lib:internal"]),
        library("//lib:internal")
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.isTrue(closure.empty);

    writeln("\x1b[32m  ✓ Ordering-only dep contributes nothing to the link line\x1b[0m");
}

/// A cyclic dependency terminates rather than recursing forever. The graph
/// rejects cycles before a build starts; the closure must not hang if asked.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Cycle terminates");

    auto tmp = scoped(new TempDir("link-cycle"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:a"]),
        library("//lib:a", ["//lib:b"]),
        library("//lib:b", ["//lib:a"])
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.equal(closure.inputs.length, 2UL);

    writeln("\x1b[32m  ✓ Cyclic deps resolve to a finite closure\x1b[0m");
}

/// Labels resolve the way the graph resolves them, so the link line and the
/// build order cannot disagree about which target a label names.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Relative, absolute and external labels");

    auto tmp = scoped(new TempDir("link-labels"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", [":sibling", "//lib:core", "@ext//pkg:thing"]),
        library("//app:sibling"),
        library("//lib:core")
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.equal(closure.inputs.length, 2UL);
    Assert.isTrue(closure.inputs.canFind!(i => i.target == "//app:sibling"));
    Assert.isTrue(closure.inputs.canFind!(i => i.target == "//lib:core"));

    // An external repository label is not a target this build produced.
    Assert.isTrue(closure.unresolved.canFind("@ext//pkg:thing"));

    writeln("\x1b[32m  ✓ `:name` resolves in-package, `@repo` is left alone\x1b[0m");
}

/// A dependency whose artifact is not on disk is reported and skipped, not
/// passed to the linker as a path that does not exist.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Absent artifact is reported, not linked");

    auto tmp = scoped(new TempDir("link-absent"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:core"]),
        library("//lib:core")
    ]);

    auto closure = linkClosure(config.targets[0], config);

    Assert.isFalse(closure.inputs[0].present);
    Assert.equal(closure.artifacts().length, 0UL);
    Assert.equal(closure.absent.length, 1UL);
    Assert.isTrue(closure.absent[0].canFind("//lib:core"));
    Assert.equal(cFamilyLinkArgs(closure).length, 0UL);

    // Once the dependency has actually been built, it links.
    write(closure.inputs[0].artifact, "archive");
    closure = linkClosure(config.targets[0], config);

    Assert.isTrue(closure.inputs[0].present);
    Assert.equal(closure.artifacts().length, 1UL);
    Assert.equal(closure.absent.length, 0UL);

    writeln("\x1b[32m  ✓ Unbuilt dependency degrades to today's behaviour with a warning\x1b[0m");
}

/// An explicit output name in the dependency's language block wins, because
/// that is what its builder writes.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Explicit output overrides the default name");

    auto tmp = scoped(new TempDir("link-output"));
    auto custom = buildPath(tmp.getPath(), "custom", "weird-name.a");
    mkdirRecurse(buildPath(tmp.getPath(), "custom"));

    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:core"]),
        library("//lib:core", null, ["cpp": `{"output": "` ~ custom ~ `"}`])
    ]);

    auto closure = linkClosure(config.targets[0], config);
    Assert.equal(closure.inputs[0].artifact, custom);

    writeln("\x1b[32m  ✓ Declared output path is where the dependency is looked for\x1b[0m");
}

/// Each toolchain family spells the same closure in its own dialect.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Per-toolchain spelling");

    auto tmp = scoped(new TempDir("link-spelling"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:stat", "//lib:dyn"]),
        library("//lib:stat"),
        library("//lib:dyn", null, ["cpp": `{"outputType": "shared"}`])
    ]);

    materialize(config, linkClosure(config.targets[0], config));
    auto closure = linkClosure(config.targets[0], config);

    auto statArchive = buildPath(config.options.outputDir, artifactFileName("stat", OutputType.StaticLib));

    // C family: archives by path so a `-l` search cannot prefer a system
    // library of the same name; shared libraries by -L/-l plus an rpath.
    auto cArgs = cFamilyLinkArgs(closure);
    Assert.isTrue(cArgs.canFind(statArchive));
    Assert.isTrue(cArgs.canFind("-ldyn"));
    Assert.isTrue(cArgs.canFind!(a => a.canFind("-Wl,-rpath,")));

    // D routes linker arguments through -L.
    auto dArgs = dLinkArgs(closure);
    Assert.isTrue(dArgs.canFind(statArchive));
    Assert.isTrue(dArgs.canFind("-L-ldyn"));

    // zig drives its own linker and takes -rpath directly.
    auto zArgs = zigLinkArgs(closure);
    Assert.isTrue(zArgs.canFind(statArchive));
    Assert.isTrue(zArgs.canFind("-ldyn"));
    Assert.isTrue(zArgs.canFind("-rpath"));

    writeln("\x1b[32m  ✓ C, D and zig emit the same closure in their own dialects\x1b[0m");
}

/// The fingerprint tracks artifact content, which is what lets a link cache
/// notice a rebuilt dependency under an unchanged set of objects.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Fingerprint follows artifact content");

    auto tmp = scoped(new TempDir("link-fingerprint"));
    auto config = workspaceAt(tmp.getPath(), [
        executable("//app:main", ["//lib:core"]),
        library("//lib:core")
    ]);

    auto predicted = linkClosure(config.targets[0], config);
    Assert.equal(predicted.fingerprint(), "");

    write(predicted.inputs[0].artifact, "first");
    auto before = linkClosure(config.targets[0], config).fingerprint();

    write(predicted.inputs[0].artifact, "second");
    auto after = linkClosure(config.targets[0], config).fingerprint();

    Assert.notEqual(before, after);

    writeln("\x1b[32m  ✓ Rebuilt dependency changes the link fingerprint\x1b[0m");
}

/// `-l` names drop the platform prefix and every extension, so a versioned
/// shared object is still spelled `-lfoo`.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m languages.linking - Library name derivation");

    LinkInput input;
    input.artifact = buildPath("bin", "libfoo.so.1");
    Assert.equal(input.libName, "foo");

    input.artifact = buildPath("bin", "libfoo.a");
    Assert.equal(input.libName, "foo");

    input.artifact = buildPath("bin", "foo.lib");
    Assert.equal(input.libName, "foo");

    writeln("\x1b[32m  ✓ libfoo.so.1, libfoo.a and foo.lib all name `foo`\x1b[0m");
}
