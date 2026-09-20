module languages.base.linking;

import std.algorithm;
import std.array;
import std.file : exists;
import std.json;
import std.path;
import std.range : retro;
import std.string;
import infrastructure.config.schema.schema;
import languages.base.config : parseOutputType;
import languages.base.types : OutputType;

/// Dependency link propagation.
///
/// `deps` in a Builderfile used to mean one thing only: build that target
/// first. This module supplies the other half of the meaning — a dependency
/// that produces a library contributes that library to the dependent's link
/// line. The model is stated once, here, so that every language emitter
/// agrees on it:
///
/// - TRANSITIVITY is full. A static archive records nothing about its own
///   dependencies, so everything reachable has to be flattened onto the final
///   link line; linking only the direct deps leaves undefined symbols.
/// - ORDER is topological, dependents ahead of dependencies. `ld` resolves an
///   archive in a single left-to-right pass and only pulls the members that
///   satisfy symbols it has already seen, so a library must appear after
///   everything that needs it.
/// - STATIC vs SHARED is decided by the dependency's own declared output type,
///   never the dependent's. A shared dependency also contributes an rpath,
///   without which the binary links and then fails to start.
/// - TRAVERSAL STOPS at anything that is not a library. A dep on an executable
///   or a codegen step is an ordering edge and nothing more.
/// - PER-LANGUAGE spelling is the emitter's job. This module decides *what* to
///   link; `cFamilyLinkArgs` and friends decide how to say it.

/// How a dependency's artifact enters a link line.
enum LinkKind
{
    /// Archive, spliced into the dependent at link time
    Static,
    /// Shared object, resolved at load time and so needing an rpath
    Shared,
    /// Headers only — contributes include directories and nothing to link
    HeaderOnly
}

/// Platform-correct file name for a target's build artifact.
///
/// One definition on purpose. The builders name what they write with this and
/// `linkClosure` predicts what a dependency wrote with it; were the two ever
/// to disagree, a dependent would link against a path nothing produces.
string artifactFileName(string base, OutputType type) pure nothrow @safe
{
    final switch (type)
    {
        case OutputType.Executable:
            version (Windows) return base ~ ".exe";
            else return base;
        case OutputType.StaticLib:
            version (Windows) return base ~ ".lib";
            else return "lib" ~ base ~ ".a";
        case OutputType.SharedLib:
            version (Windows) return base ~ ".dll";
            else version (OSX) return "lib" ~ base ~ ".dylib";
            else return "lib" ~ base ~ ".so";
        case OutputType.Object:
            return base ~ ".o";
        case OutputType.HeaderOnly:
            return base;
    }
}

/// One library a dependency contributes to a dependent's link line.
struct LinkInput
{
    /// Fully-qualified name of the dependency that produces this
    string target;
    TargetLanguage language;
    LinkKind kind;
    /// Path the dependency's builder writes its artifact to
    string artifact;
    /// Header directories the dependency declares, propagated to the dependent
    string[] includeDirs;
    /// Named in the dependent's own `deps` rather than reached transitively
    bool direct;
    /// Artifact is on disk
    bool present;

    /// Directory to search for this library
    string libDir() const @safe => artifact.dirName;

    /// Library name as `-l` spells it: `libfoo.a` becomes `foo`.
    string libName() const @safe
    {
        auto stem = artifact.baseName;
        // A versioned shared object leaves a second extension behind
        // (libfoo.so.1 -> libfoo.so), so strip until it stops changing.
        while (stem.extension.length)
            stem = stem.stripExtension;
        return stem.chompPrefix("lib");
    }

    /// Contributes something to the link command
    bool linkable() const @safe => kind != LinkKind.HeaderOnly && present;
}

/// The ordered set of libraries reachable through a target's `deps`.
struct LinkClosure
{
    /// Topological order: a dependent always precedes its dependencies
    LinkInput[] inputs;
    /// `deps` labels that named no target in this workspace
    string[] unresolved;
    /// Library deps whose artifact is not on disk, so cannot be linked
    string[] absent;

    bool empty() const @safe => inputs.length == 0;

    /// Artifact paths in link order — also the extra inputs a link action
    /// depends on, so that a rebuilt dependency invalidates the cached link.
    string[] artifacts() const @safe
    {
        string[] paths;
        foreach (input; inputs)
            if (input.linkable)
                paths ~= input.artifact;
        return paths;
    }

    /// Library names, for callers that track linked libraries by name
    string[] libNames() const @safe
    {
        string[] names;
        foreach (input; inputs)
            if (input.linkable)
                names ~= input.libName;
        return names;
    }

    /// Run-time search paths for the shared dependencies. Absolute, because a
    /// relative rpath resolves against the working directory of whoever runs
    /// the binary rather than the workspace.
    ///
    /// Empty on Windows, which has no rpath: a DLL is found through the
    /// loader's own search order, so there is nothing to record at link time.
    string[] rpathDirs() const @safe
    {
        version (Windows) return [];
        
        string[] dirs;
        foreach (input; inputs)
        {
            if (!input.linkable || input.kind != LinkKind.Shared)
                continue;
            try
                dirs ~= input.libDir.absolutePath.buildNormalizedPath;
            catch (Exception)
                dirs ~= input.libDir;
        }
        return dedup_(dirs);
    }

    /// Header directories the dependencies export, deduplicated
    string[] includeDirs() const @safe
    {
        string[] dirs;
        foreach (input; inputs)
            dirs ~= input.includeDirs.dup;
        return dedup_(dirs);
    }

    /// Content fingerprint of the linked artifacts.
    ///
    /// Link caches key on the object files; a dependency's archive changing
    /// under a stable set of objects has to invalidate them too, and this is
    /// what makes that visible.
    string fingerprint() const @system
    {
        import infrastructure.utils.files.hash : FastHash;

        auto linked = artifacts();
        if (linked.empty)
            return "";
        return FastHash.hashStrings(linked.map!(a => a ~ ":" ~ FastHash.hashFile(a)).array);
    }
}

/// Collect the libraries a target must link because its `deps` produce them.
LinkClosure linkClosure(in Target target, in WorkspaceConfig workspace) @system
{
    LinkClosure closure;
    bool[string] visited;
    bool[string] onPath;
    bool[string] directNames;
    LinkInput[] postorder;

    void walk(string label, string from, bool isDirect)
    {
        auto dep = findDep(label, from, workspace);
        if (dep is null)
        {
            closure.unresolved ~= label;
            return;
        }

        // Not a library: an ordering edge, and its own deps are its business.
        if (dep.type != TargetType.Library)
            return;

        auto name = dep.name;
        if (isDirect)
            directNames[name] = true;

        // onPath breaks a cycle. The graph rejects cycles before a build
        // starts, so this is unreachable during one, but the closure must
        // still terminate for any caller that has not been through the graph.
        if (name in visited || name in onPath)
            return;
        onPath[name] = true;

        foreach (child; dep.deps)
            walk(child, name, false);

        onPath.remove(name);
        visited[name] = true;
        // Record after descending: a post-order walk, reversed, is a
        // topological order, which is the order the linker needs.
        postorder ~= linkInputFor(*dep, workspace);
    }

    foreach (label; target.deps)
        walk(label, target.name, true);

    closure.inputs = postorder.retro.array;
    foreach (ref input; closure.inputs)
    {
        input.direct = (input.target in directNames) !is null;
        if (input.kind != LinkKind.HeaderOnly && !input.present)
            closure.absent ~= input.target ~ " (" ~ input.artifact ~ ")";
    }

    return closure;
}

// ============================================================================
// Per-toolchain spelling
// ============================================================================

/// Spell a closure for a gcc/clang-style driver.
///
/// Static archives go on the command line by path rather than as `-lfoo`,
/// because a `-l` search can find a same-named system library in preference to
/// the one this build just produced. Shared libraries do need `-L`/`-l`, plus
/// an rpath, or the binary links and then fails to load.
string[] cFamilyLinkArgs(in LinkClosure closure, bool rpath = true) @safe
{
    string[] args;

    foreach (input; closure.inputs)
    {
        if (!input.linkable)
            continue;

        final switch (input.kind)
        {
            case LinkKind.Static:
                args ~= input.artifact;
                break;
            case LinkKind.Shared:
                args ~= ["-L" ~ input.libDir, "-l" ~ input.libName];
                break;
            case LinkKind.HeaderOnly:
                break;
        }
    }

    if (rpath)
        foreach (dir; closure.rpathDirs)
            args ~= "-Wl,-rpath," ~ dir;

    return args;
}

/// Spell a closure for `zig build-exe` / `build-lib`, which take archives
/// positionally and search shared libraries the same way a C driver does.
string[] zigLinkArgs(in LinkClosure closure) @safe
{
    string[] args;

    foreach (input; closure.inputs)
    {
        if (!input.linkable)
            continue;

        final switch (input.kind)
        {
            case LinkKind.Static:
                args ~= input.artifact;
                break;
            case LinkKind.Shared:
                args ~= ["-L" ~ input.libDir, "-l" ~ input.libName];
                break;
            case LinkKind.HeaderOnly:
                break;
        }
    }

    // zig drives its own linker, so the rpath goes through the same
    // `-rpath` spelling it accepts directly rather than via -Wl.
    foreach (dir; closure.rpathDirs)
        args ~= ["-rpath", dir];

    return args;
}

/// Spell a closure for dmd/ldc/gdc, which route linker arguments through `-L`.
///
/// The D compilers accept an archive as a command-line input directly, which
/// keeps static deps on the same footing as the C family.
string[] dLinkArgs(in LinkClosure closure) @safe
{
    string[] args;

    foreach (input; closure.inputs)
    {
        if (!input.linkable)
            continue;

        final switch (input.kind)
        {
            case LinkKind.Static:
                args ~= input.artifact;
                break;
            case LinkKind.Shared:
                args ~= ["-L-L" ~ input.libDir, "-L-l" ~ input.libName];
                break;
            case LinkKind.HeaderOnly:
                break;
        }
    }

    foreach (dir; closure.rpathDirs)
        args ~= "-L-Wl,-rpath," ~ dir;

    return args;
}

// ============================================================================
// Internals
// ============================================================================

/// Resolve a `deps` label the way the graph does, so that the link line and
/// the build order can never disagree about which target a label names.
private const(Target)* findDep(string label, string from, in WorkspaceConfig workspace) @system
{
    // External repository: whatever it is, this build did not produce it.
    if (label.startsWith("@"))
        return null;

    if (label.startsWith("//"))
        return workspace.findTarget(label);

    auto colon = from.lastIndexOf(':');
    auto pkg = colon >= 0 ? from[0 .. colon] : from;

    if (label.startsWith(":"))
        return workspace.findTarget(pkg ~ label);

    // Bare name: literal first, then same package, matching the two spellings
    // DependencyResolver accepts.
    if (auto found = workspace.findTarget(label))
        return found;
    return workspace.findTarget(pkg ~ ":" ~ label);
}

private LinkInput linkInputFor(in Target dep, in WorkspaceConfig workspace) @system
{
    LinkInput input;
    input.target = dep.name;
    input.language = dep.language;
    input.kind = linkKindFor(dep);
    input.includeDirs = dep.includes.dup;

    if (input.kind != LinkKind.HeaderOnly)
    {
        input.artifact = artifactPath(dep, workspace, input.kind);
        input.present = input.artifact.exists;
    }

    return input;
}

/// Classify a library dependency as static or shared.
private LinkKind linkKindFor(in Target dep) @system
{
    // Headers alone cannot be archived, and the C++ handler already treats
    // such a target as header-only; agree with it rather than predict an
    // archive that never gets written.
    if (!dep.sources.empty && dep.sources.all!(s => s.extension.toLower.among(".h", ".hpp", ".hxx", ".hh", ".inl")))
        return LinkKind.HeaderOnly;

    final switch (declaredOutputType(dep))
    {
        case OutputType.SharedLib:
            return LinkKind.Shared;
        case OutputType.HeaderOnly:
            return LinkKind.HeaderOnly;
        // A library target declaring no output type, or declaring one that
        // makes no sense for a library, archives. This mirrors the handlers,
        // which coerce a library's Executable default to StaticLib.
        case OutputType.StaticLib:
        case OutputType.Executable:
        case OutputType.Object:
            return LinkKind.Static;
    }
}

/// The output type a target declares in its own language block.
///
/// Every block is examined rather than mapping language to key name, so that a
/// language gains dependency linking without an edit here.
private OutputType declaredOutputType(in Target dep) @system
{
    foreach (block; languageBlocks(dep))
        foreach (key; ["outputType", "output_type"])
            if (auto v = key in block)
                if (v.type == JSONType.string)
                    return parseOutputType(v.str);

    return OutputType.StaticLib;
}

/// Predict where a dependency's builder writes its artifact.
///
/// The precedence mirrors what the builders actually do: an explicit `output`
/// path in the language block wins, then the DSL's `output:` name relative to
/// the output directory, then the platform-default library name.
private string artifactPath(in Target dep, in WorkspaceConfig workspace, LinkKind kind) @system
{
    foreach (block; languageBlocks(dep))
        if (auto v = "output" in block)
            if (v.type == JSONType.string && v.str.length)
                return v.str;

    auto outDir = workspace.options.outputDir;

    if (!dep.outputPath.empty)
        return buildPath(outDir, dep.outputPath);

    auto colon = dep.name.lastIndexOf(':');
    auto base = colon >= 0 ? dep.name[colon + 1 .. $] : dep.name;

    return buildPath(outDir, artifactFileName(base, kind == LinkKind.Shared
        ? OutputType.SharedLib
        : OutputType.StaticLib));
}

/// A target's parsed language-config blocks, in sorted key order.
///
/// Sorted rather than in hash order: two blocks could in principle declare the
/// same key, and a build system may not resolve that differently from one run
/// to the next. Values that are not JSON objects — `command`, say — are skipped.
private JSONValue[] languageBlocks(in Target dep) @system
{
    JSONValue[] blocks;

    foreach (key; dep.langConfig.keys.dup.sort)
    {
        JSONValue json;
        try
            json = parseJSON(dep.langConfig[key]);
        catch (Exception)
            continue;

        if (json.type == JSONType.object)
            blocks ~= json;
    }

    return blocks;
}

/// Order-preserving deduplication
private string[] dedup_(string[] values) @safe
{
    string[] result;
    bool[string] seen;

    foreach (value; values)
    {
        if (value.empty || value in seen)
            continue;
        seen[value] = true;
        result ~= value;
    }

    return result;
}
