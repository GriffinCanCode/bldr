module tests.integration.link_propagation;

/// End-to-end proof that `deps` reaches the link line.
///
/// The unit tests in `tests.unit.languages.linking` cover the closure's shape:
/// transitivity, order, static versus shared, label resolution. These tests
/// cover the thing a unit test cannot assert — that a real compiler, given a
/// real Builderfile-shaped target graph, produces a binary whose symbols
/// resolved against a dependency's archive.
///
/// Each test builds in dependency order, the way the executor does, and then
/// runs the result: a binary that runs and prints the right answer is the only
/// evidence that the archive was actually linked and not merely named.

import std.algorithm : canFind;
import std.file : exists;
import std.path : buildPath;
import std.process : execute, executeShell;
import std.stdio : writeln;
import std.string : strip;
import infrastructure.config.schema.schema;
import languages.compiled.cpp.core.handler : CppHandler;
import tests.fixtures : TempDir, scoped;
import tests.harness : Assert;
import tests.mocks : testBuild;

/// Is there a C++ compiler to test with?
private bool hasCompiler()
{
    foreach (compiler; ["c++", "clang++", "g++"])
    {
        auto probe = executeShell("command -v " ~ compiler);
        if (probe.status == 0)
            return true;
    }
    return false;
}

private Target cppTarget(string name, TargetType type, string[] sources, string[] deps = null)
{
    Target target;
    target.name = name;
    target.type = type;
    target.language = TargetLanguage.Cpp;
    target.sources = sources;
    target.deps = deps;
    return target;
}

/// An executable whose `deps` name a library links against that library's
/// archive, and the resulting binary runs.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m link_propagation - Library dep is linked into the dependent");

    if (!hasCompiler())
    {
        writeln("\x1b[33m  ~ Skipped: no C++ compiler on PATH\x1b[0m");
        return;
    }

    auto tmp = scoped(new TempDir("link-e2e"));
    auto root = tmp.getPath();

    tmp.createFile("lib/math.h", "#pragma once\nint triple(int x);\n");
    tmp.createFile("lib/math.cpp", "#include \"math.h\"\nint triple(int x) { return x * 3; }\n");
    tmp.createFile("app/main.cpp", `
#include <cstdio>
#include "math.h"

int main() { printf("%d\n", triple(14)); return 0; }
`);

    auto lib = cppTarget("//lib:math", TargetType.Library, [buildPath(root, "lib/math.cpp")]);
    lib.includes = [buildPath(root, "lib")];

    auto app = cppTarget("//app:main", TargetType.Executable,
                         [buildPath(root, "app/main.cpp")], ["//lib:math"]);

    WorkspaceConfig config;
    config.root = root;
    config.options.outputDir = buildPath(root, "bin");
    config.targets = [lib, app];

    // Build in dependency order, as the executor does.
    auto libResult = testBuild(new CppHandler(), lib, config);
    Assert.isTrue(libResult.isOk, "library build failed");

    auto archive = buildPath(config.options.outputDir, "libmath.a");
    Assert.isTrue(archive.exists, "expected the library target to produce " ~ archive);

    auto appResult = testBuild(new CppHandler(), app, config);
    Assert.isTrue(appResult.isOk, "dependent failed to link against its dependency");

    // The dependent's headers came from the dependency's `includes`, and its
    // symbol came from the dependency's archive. Running it proves both.
    auto binary = buildPath(config.options.outputDir, "main");
    Assert.isTrue(binary.exists, "expected a linked executable at " ~ binary);

    auto run = execute([binary]);
    Assert.equal(run.status, 0);
    Assert.equal(run.output.strip, "42");

    writeln("\x1b[32m  ✓ Dependent links its dependency's archive and runs\x1b[0m");
}

/// The negative control. Without the dep, the identical sources must fail to
/// link — otherwise the test above would pass for some reason other than
/// propagation, and would keep passing if propagation regressed.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m link_propagation - Without the dep the same link fails");

    if (!hasCompiler())
    {
        writeln("\x1b[33m  ~ Skipped: no C++ compiler on PATH\x1b[0m");
        return;
    }

    auto tmp = scoped(new TempDir("link-e2e-neg"));
    auto root = tmp.getPath();

    tmp.createFile("lib/math.h", "#pragma once\nint triple(int x);\n");
    tmp.createFile("lib/math.cpp", "#include \"math.h\"\nint triple(int x) { return x * 3; }\n");
    tmp.createFile("app/main.cpp", `
#include <cstdio>
#include "math.h"

int main() { printf("%d\n", triple(14)); return 0; }
`);

    auto lib = cppTarget("//lib:math", TargetType.Library, [buildPath(root, "lib/math.cpp")]);
    lib.includes = [buildPath(root, "lib")];

    // Same sources, same include path, no `deps`.
    auto app = cppTarget("//app:orphan", TargetType.Executable,
                         [buildPath(root, "app/main.cpp")]);
    app.includes = [buildPath(root, "lib")];

    WorkspaceConfig config;
    config.root = root;
    config.options.outputDir = buildPath(root, "bin");
    config.targets = [lib, app];

    Assert.isTrue(testBuild(new CppHandler(), lib, config).isOk, "library build failed");

    auto appResult = testBuild(new CppHandler(), app, config);
    Assert.isTrue(appResult.isErr, "a dependent with no deps must not resolve triple()");

    writeln("\x1b[32m  ✓ Undeclared dependency still fails to link\x1b[0m");
}

/// A transitive dependency reaches the final binary. A static archive cannot
/// record its own dependencies, so linking only the direct dep would leave an
/// undefined symbol here.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m link_propagation - Transitive dep reaches the binary");

    if (!hasCompiler())
    {
        writeln("\x1b[33m  ~ Skipped: no C++ compiler on PATH\x1b[0m");
        return;
    }

    auto tmp = scoped(new TempDir("link-e2e-trans"));
    auto root = tmp.getPath();

    tmp.createFile("base/base.h", "#pragma once\nint base_value();\n");
    tmp.createFile("base/base.cpp", "#include \"base.h\"\nint base_value() { return 6; }\n");

    // `mid` calls into `base` but does not define base_value itself.
    tmp.createFile("mid/mid.h", "#pragma once\nint seven_times_base();\n");
    tmp.createFile("mid/mid.cpp",
        "#include \"mid.h\"\n#include \"base.h\"\nint seven_times_base() { return 7 * base_value(); }\n");

    tmp.createFile("app/main.cpp", `
#include <cstdio>
#include "mid.h"

int main() { printf("%d\n", seven_times_base()); return 0; }
`);

    auto base = cppTarget("//base:base", TargetType.Library, [buildPath(root, "base/base.cpp")]);
    base.includes = [buildPath(root, "base")];

    auto mid = cppTarget("//mid:mid", TargetType.Library,
                         [buildPath(root, "mid/mid.cpp")], ["//base:base"]);
    mid.includes = [buildPath(root, "mid")];

    // The app names only `mid`. `base` has to arrive transitively.
    auto app = cppTarget("//app:main", TargetType.Executable,
                         [buildPath(root, "app/main.cpp")], ["//mid:mid"]);

    WorkspaceConfig config;
    config.root = root;
    config.options.outputDir = buildPath(root, "bin");
    config.targets = [base, mid, app];

    Assert.isTrue(testBuild(new CppHandler(), base, config).isOk, "base build failed");
    Assert.isTrue(testBuild(new CppHandler(), mid, config).isOk, "mid build failed");

    auto appResult = testBuild(new CppHandler(), app, config);
    Assert.isTrue(appResult.isErr == false, "transitive dependency did not reach the link line");

    auto run = execute([buildPath(config.options.outputDir, "main")]);
    Assert.equal(run.status, 0);
    Assert.equal(run.output.strip, "42");

    writeln("\x1b[32m  ✓ Two-level dependency chain links and runs\x1b[0m");
}

/// A dependency declared `shared` links by name and carries an rpath, so the
/// binary both links and starts. A missing rpath fails only at run time, which
/// is why this test runs the binary rather than checking it exists.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m link_propagation - Shared dependency links and loads");

    if (!hasCompiler())
    {
        writeln("\x1b[33m  ~ Skipped: no C++ compiler on PATH\x1b[0m");
        return;
    }

    auto tmp = scoped(new TempDir("link-e2e-shared"));
    auto root = tmp.getPath();

    tmp.createFile("lib/greet.h", "#pragma once\nint answer();\n");
    tmp.createFile("lib/greet.cpp", "#include \"greet.h\"\nint answer() { return 42; }\n");
    tmp.createFile("app/main.cpp", `
#include <cstdio>
#include "greet.h"

int main() { printf("%d\n", answer()); return 0; }
`);

    auto lib = cppTarget("//lib:greet", TargetType.Library, [buildPath(root, "lib/greet.cpp")]);
    lib.includes = [buildPath(root, "lib")];
    lib.langConfig["cpp"] = `{"outputType": "shared"}`;

    auto app = cppTarget("//app:main", TargetType.Executable,
                         [buildPath(root, "app/main.cpp")], ["//lib:greet"]);

    WorkspaceConfig config;
    config.root = root;
    config.options.outputDir = buildPath(root, "bin");
    config.targets = [lib, app];

    Assert.isTrue(testBuild(new CppHandler(), lib, config).isOk, "shared library build failed");

    // The declaration has to actually produce a shared library, or the
    // dependent's classification of it would be a fiction.
    version (OSX) auto sharedName = "libgreet.dylib";
    else auto sharedName = "libgreet.so";
    Assert.isTrue(buildPath(config.options.outputDir, sharedName).exists,
                  "expected a shared library at " ~ sharedName);

    Assert.isTrue(testBuild(new CppHandler(), app, config).isOk,
                  "dependent failed to link against a shared dependency");

    auto run = execute([buildPath(config.options.outputDir, "main")]);
    Assert.equal(run.status, 0, "binary linked but did not load: " ~ run.output);
    Assert.equal(run.output.strip, "42");

    writeln("\x1b[32m  ✓ Shared dependency resolves at link time and at load time\x1b[0m");
}

/// A rebuilt dependency invalidates the dependent's cached link. Without the
/// dependency archives feeding link-cache validation, the dependent would keep
/// its stale binary because its own objects never changed.
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m link_propagation - Rebuilt dependency relinks the dependent");

    if (!hasCompiler())
    {
        writeln("\x1b[33m  ~ Skipped: no C++ compiler on PATH\x1b[0m");
        return;
    }

    auto tmp = scoped(new TempDir("link-e2e-cache"));
    auto root = tmp.getPath();

    tmp.createFile("lib/val.h", "#pragma once\nint value();\n");
    tmp.createFile("lib/val.cpp", "#include \"val.h\"\nint value() { return 1; }\n");
    tmp.createFile("app/main.cpp", `
#include <cstdio>
#include "val.h"

int main() { printf("%d\n", value()); return 0; }
`);

    auto lib = cppTarget("//lib:val", TargetType.Library, [buildPath(root, "lib/val.cpp")]);
    lib.includes = [buildPath(root, "lib")];

    auto app = cppTarget("//app:main", TargetType.Executable,
                         [buildPath(root, "app/main.cpp")], ["//lib:val"]);

    WorkspaceConfig config;
    config.root = root;
    config.options.outputDir = buildPath(root, "bin");
    config.targets = [lib, app];

    Assert.isTrue(testBuild(new CppHandler(), lib, config).isOk, "library build failed");
    Assert.isTrue(testBuild(new CppHandler(), app, config).isOk, "dependent build failed");

    auto binary = buildPath(config.options.outputDir, "main");
    Assert.equal(execute([binary]).output.strip, "1");

    // Change only the dependency. The dependent's own sources and objects are
    // untouched, so only the archive can drive the relink.
    tmp.createFile("lib/val.cpp", "#include \"val.h\"\nint value() { return 2; }\n");

    Assert.isTrue(testBuild(new CppHandler(), lib, config).isOk, "library rebuild failed");
    Assert.isTrue(testBuild(new CppHandler(), app, config).isOk, "dependent relink failed");

    Assert.equal(execute([binary]).output.strip, "2");

    writeln("\x1b[32m  ✓ Changed dependency is not hidden behind a cached link\x1b[0m");
}
