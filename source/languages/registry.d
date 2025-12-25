module languages.registry;

import infrastructure.config.schema.schema : TargetLanguage;
import std.algorithm : canFind;
import std.string : toLower;

/// Centralized registry for all language-related mappings
/// This module provides the single source of truth for:
/// - Language name aliases (string -> TargetLanguage)
/// - File extensions (string -> TargetLanguage)
/// - Supported language queries

/// Language name alias mapping
/// Maps common language name strings and abbreviations to TargetLanguage enum
private immutable string[][TargetLanguage] languageAliases;

/// File extension to language mapping
/// Maps file extensions (including the dot) to TargetLanguage enum
private immutable TargetLanguage[string] extensionMap;

/// Initialize registries at module load time
shared static this()
{
    import std.exception : assumeUnique;
    
    // Build language aliases map
    string[][TargetLanguage] aliases;
    
    aliases[TargetLanguage.D] = ["d"];
    aliases[TargetLanguage.Python] = ["python", "py"];
    aliases[TargetLanguage.JavaScript] = ["javascript", "js"];
    aliases[TargetLanguage.TypeScript] = ["typescript", "ts"];
    aliases[TargetLanguage.Go] = ["go"];
    aliases[TargetLanguage.Rust] = ["rust", "rs"];
    aliases[TargetLanguage.Cpp] = ["cpp", "c++"];
    aliases[TargetLanguage.C] = ["c"];
    aliases[TargetLanguage.Java] = ["java"];
    aliases[TargetLanguage.Kotlin] = ["kotlin", "kt"];
    aliases[TargetLanguage.CSharp] = ["csharp", "cs", "c#"];
    aliases[TargetLanguage.FSharp] = ["fsharp", "fs", "f#"];
    aliases[TargetLanguage.Zig] = ["zig"];
    aliases[TargetLanguage.Swift] = ["swift"];
    aliases[TargetLanguage.Ruby] = ["ruby", "rb"];
    aliases[TargetLanguage.Perl] = ["perl", "pl"];
    aliases[TargetLanguage.PHP] = ["php"];
    aliases[TargetLanguage.Scala] = ["scala"];
    aliases[TargetLanguage.Elixir] = ["elixir", "ex"];
    aliases[TargetLanguage.Gleam] = ["gleam"];
    aliases[TargetLanguage.Nim] = ["nim"];
    aliases[TargetLanguage.Lua] = ["lua"];
    aliases[TargetLanguage.R] = ["r"];
    aliases[TargetLanguage.CSS] = ["css"];
    aliases[TargetLanguage.Protobuf] = ["protobuf", "proto"];
    aliases[TargetLanguage.OCaml] = ["ocaml", "ml"];
    aliases[TargetLanguage.Haskell] = ["haskell", "hs"];
    aliases[TargetLanguage.Elm] = ["elm"];
    aliases[TargetLanguage.Generic] = ["generic"];
    
    languageAliases = cast(immutable) aliases;
    
    // Build extension map
    TargetLanguage[string] extensions;
    
    // D
    extensions[".d"] = TargetLanguage.D;
    
    // Python
    extensions[".py"] = TargetLanguage.Python;
    
    // JavaScript
    extensions[".js"] = TargetLanguage.JavaScript;
    extensions[".jsx"] = TargetLanguage.JavaScript;
    extensions[".mjs"] = TargetLanguage.JavaScript;
    extensions[".cjs"] = TargetLanguage.JavaScript;
    
    // TypeScript
    extensions[".ts"] = TargetLanguage.TypeScript;
    extensions[".tsx"] = TargetLanguage.TypeScript;
    extensions[".mts"] = TargetLanguage.TypeScript;
    extensions[".cts"] = TargetLanguage.TypeScript;
    
    // Go
    extensions[".go"] = TargetLanguage.Go;
    
    // Rust
    extensions[".rs"] = TargetLanguage.Rust;
    
    // C++
    extensions[".cpp"] = TargetLanguage.Cpp;
    extensions[".cc"] = TargetLanguage.Cpp;
    extensions[".cxx"] = TargetLanguage.Cpp;
    extensions[".c++"] = TargetLanguage.Cpp;
    extensions[".hpp"] = TargetLanguage.Cpp;
    extensions[".hxx"] = TargetLanguage.Cpp;
    extensions[".hh"] = TargetLanguage.Cpp;
    
    // C
    extensions[".c"] = TargetLanguage.C;
    extensions[".h"] = TargetLanguage.C;
    
    // Java
    extensions[".java"] = TargetLanguage.Java;
    
    // Kotlin
    extensions[".kt"] = TargetLanguage.Kotlin;
    extensions[".kts"] = TargetLanguage.Kotlin;
    
    // C#
    extensions[".cs"] = TargetLanguage.CSharp;
    
    // F#
    extensions[".fs"] = TargetLanguage.FSharp;
    extensions[".fsi"] = TargetLanguage.FSharp;
    extensions[".fsx"] = TargetLanguage.FSharp;
    
    // Zig
    extensions[".zig"] = TargetLanguage.Zig;
    
    // Swift
    extensions[".swift"] = TargetLanguage.Swift;
    
    // Ruby
    extensions[".rb"] = TargetLanguage.Ruby;
    
    // Perl
    extensions[".pl"] = TargetLanguage.Perl;
    extensions[".pm"] = TargetLanguage.Perl;
    extensions[".t"] = TargetLanguage.Perl;
    
    // PHP
    extensions[".php"] = TargetLanguage.PHP;
    
    // Scala
    extensions[".scala"] = TargetLanguage.Scala;
    extensions[".sc"] = TargetLanguage.Scala;
    
    // Elixir
    extensions[".ex"] = TargetLanguage.Elixir;
    extensions[".exs"] = TargetLanguage.Elixir;
    
    // Gleam
    extensions[".gleam"] = TargetLanguage.Gleam;
    
    // Nim
    extensions[".nim"] = TargetLanguage.Nim;
    
    // Lua
    extensions[".lua"] = TargetLanguage.Lua;
    
    // R
    extensions[".r"] = TargetLanguage.R;
    extensions[".R"] = TargetLanguage.R;
    
    // CSS
    extensions[".css"] = TargetLanguage.CSS;
    extensions[".scss"] = TargetLanguage.CSS;
    extensions[".sass"] = TargetLanguage.CSS;
    extensions[".less"] = TargetLanguage.CSS;
    
    // Protocol Buffers
    extensions[".proto"] = TargetLanguage.Protobuf;
    
    // OCaml
    extensions[".ml"] = TargetLanguage.OCaml;
    extensions[".mli"] = TargetLanguage.OCaml;
    extensions[".mll"] = TargetLanguage.OCaml;
    extensions[".mly"] = TargetLanguage.OCaml;
    
    // Haskell
    extensions[".hs"] = TargetLanguage.Haskell;
    extensions[".lhs"] = TargetLanguage.Haskell;
    extensions[".hsc"] = TargetLanguage.Haskell;
    
    // Elm
    extensions[".elm"] = TargetLanguage.Elm;
    
    extensionMap = cast(immutable) extensions;
}

/// Parse language from string name or alias
/// Returns TargetLanguage.Generic if not recognized
/// 
/// Examples:
///   parseLanguageName("python") -> TargetLanguage.Python
///   parseLanguageName("py") -> TargetLanguage.Python
///   parseLanguageName("c++") -> TargetLanguage.Cpp
pure @system
TargetLanguage parseLanguageName(string langName)
{
    if (langName.length == 0)
        return TargetLanguage.Generic;
    
    string normalized = langName.toLower;
    
    // Search through all language aliases
    foreach (lang, aliases; languageAliases)
    {
        if (aliases.canFind(normalized))
            return lang;
    }
    
    return TargetLanguage.Generic;
}

/// Infer language from file extension
/// Returns TargetLanguage.Generic if not recognized
/// 
/// Examples:
///   inferLanguageFromExtension(".py") -> TargetLanguage.Python
///   inferLanguageFromExtension(".tsx") -> TargetLanguage.TypeScript
pure nothrow @system
TargetLanguage inferLanguageFromExtension(string extension)
{
    if (auto lang = extension in extensionMap)
        return *lang;
    return TargetLanguage.Generic;
}

/// Get all file extensions for a given language
/// Returns empty array if language has no known extensions
/// 
/// Examples:
///   getLanguageExtensions(TargetLanguage.Python) -> [".py"]
///   getLanguageExtensions(TargetLanguage.TypeScript) -> [".ts", ".tsx", ".mts", ".cts"]
pure @system
string[] getLanguageExtensions(TargetLanguage language)
{
    string[] result;
    
    foreach (ext, lang; extensionMap)
    {
        if (lang == language)
            result ~= ext;
    }
    
    return result;
}

/// Get all supported language names (primary name only, not aliases)
/// Excludes Generic
pure @system
string[] getSupportedLanguageNames()
{
    string[] names;
    
    foreach (lang, aliases; languageAliases)
    {
        if (lang != TargetLanguage.Generic && aliases.length > 0)
            names ~= aliases[0]; // First alias is the primary name
    }
    
    return names;
}

/// Get all language aliases for a given language
/// Returns empty array if no aliases defined
pure @system
string[] getLanguageAliases(TargetLanguage language)
{
    if (auto aliases = language in languageAliases)
        return (*aliases).dup;
    return [];
}

/// Check if a language is supported (has aliases/extensions defined)
pure nothrow @system
bool isLanguageSupported(TargetLanguage language)
{
    return (language in languageAliases) !is null;
}

/// Get primary display name for a language
pure @system
string getLanguageDisplayName(TargetLanguage language)
{
    if (auto aliases = language in languageAliases)
    {
        if ((*aliases).length > 0)
            return (*aliases)[0];
    }
    
    import std.conv : to;
    return language.to!string;
}

/// Get user-friendly label for a language (suitable for UI display)
/// This returns nicely formatted names like "C++", "C#", "JavaScript/TypeScript", etc.
pure nothrow @system
string getLanguageLabel(TargetLanguage language)
{
    switch (language)
    {
        case TargetLanguage.D: return "D";
        case TargetLanguage.Python: return "Python";
        case TargetLanguage.JavaScript: return "JavaScript";
        case TargetLanguage.TypeScript: return "TypeScript";
        case TargetLanguage.Go: return "Go";
        case TargetLanguage.Rust: return "Rust";
        case TargetLanguage.Cpp: return "C++";
        case TargetLanguage.C: return "C";
        case TargetLanguage.Java: return "Java";
        case TargetLanguage.Kotlin: return "Kotlin";
        case TargetLanguage.CSharp: return "C#";
        case TargetLanguage.FSharp: return "F#";
        case TargetLanguage.Zig: return "Zig";
        case TargetLanguage.Swift: return "Swift";
        case TargetLanguage.Ruby: return "Ruby";
        case TargetLanguage.Perl: return "Perl";
        case TargetLanguage.PHP: return "PHP";
        case TargetLanguage.Scala: return "Scala";
        case TargetLanguage.Elixir: return "Elixir";
        case TargetLanguage.Gleam: return "Gleam";
        case TargetLanguage.Nim: return "Nim";
        case TargetLanguage.Lua: return "Lua";
        case TargetLanguage.R: return "R";
        case TargetLanguage.CSS: return "CSS";
        case TargetLanguage.Protobuf: return "Protobuf";
        case TargetLanguage.OCaml: return "OCaml";
        case TargetLanguage.Haskell: return "Haskell";
        case TargetLanguage.Elm: return "Elm";
        case TargetLanguage.Generic: return "Generic";
        default: return "Unknown";
    }
}

/// Language category for organization and display
enum LanguageCategory
{
    Compiled,
    Scripting,
    JVM,
    DotNet,
    Web
}

/// Get the category for a language
pure nothrow @system
LanguageCategory getLanguageCategory(TargetLanguage language)
{
    switch (language)
    {
        case TargetLanguage.C:
        case TargetLanguage.Cpp:
        case TargetLanguage.D:
        case TargetLanguage.Zig:
        case TargetLanguage.Rust:
        case TargetLanguage.Go:
        case TargetLanguage.Nim:
        case TargetLanguage.OCaml:
        case TargetLanguage.Haskell:
        case TargetLanguage.Swift:
        case TargetLanguage.Protobuf:
            return LanguageCategory.Compiled;
            
        case TargetLanguage.Python:
        case TargetLanguage.Ruby:
        case TargetLanguage.Perl:
        case TargetLanguage.PHP:
        case TargetLanguage.Lua:
        case TargetLanguage.R:
        case TargetLanguage.Elixir:
        case TargetLanguage.Gleam:
            return LanguageCategory.Scripting;
            
        case TargetLanguage.Java:
        case TargetLanguage.Kotlin:
        case TargetLanguage.Scala:
            return LanguageCategory.JVM;
            
        case TargetLanguage.CSharp:
        case TargetLanguage.FSharp:
            return LanguageCategory.DotNet;
            
        case TargetLanguage.JavaScript:
        case TargetLanguage.TypeScript:
        case TargetLanguage.CSS:
        case TargetLanguage.Elm:
            return LanguageCategory.Web;
            
        default:
            return LanguageCategory.Scripting;
    }
}

/// Get all languages in a specific category
pure @system
TargetLanguage[] getLanguagesByCategory(LanguageCategory category)
{
    TargetLanguage[] result;
    
    import std.traits : EnumMembers;
    static foreach (lang; EnumMembers!TargetLanguage)
    {
        if (getLanguageCategory(lang) == category && lang != TargetLanguage.Generic)
            result ~= lang;
    }
    
    return result;
}

/// Get formatted list of language names for a category (for help text)
pure @system
string getLanguageCategoryList(LanguageCategory category)
{
    import std.algorithm : map;
    import std.array : join;
    
    auto languages = getLanguagesByCategory(category);
    return languages.map!(l => getLanguageLabel(l)).join(", ");
}

// Unit tests
unittest
{
    // Test language name parsing
    assert(parseLanguageName("python") == TargetLanguage.Python);
    assert(parseLanguageName("py") == TargetLanguage.Python);
    assert(parseLanguageName("Python") == TargetLanguage.Python);
    assert(parseLanguageName("c++") == TargetLanguage.Cpp);
    assert(parseLanguageName("cpp") == TargetLanguage.Cpp);
    assert(parseLanguageName("c#") == TargetLanguage.CSharp);
    assert(parseLanguageName("csharp") == TargetLanguage.CSharp);
    assert(parseLanguageName("f#") == TargetLanguage.FSharp);
    assert(parseLanguageName("unknown") == TargetLanguage.Generic);
    
    // Test extension inference
    assert(inferLanguageFromExtension(".py") == TargetLanguage.Python);
    assert(inferLanguageFromExtension(".js") == TargetLanguage.JavaScript);
    assert(inferLanguageFromExtension(".jsx") == TargetLanguage.JavaScript);
    assert(inferLanguageFromExtension(".ts") == TargetLanguage.TypeScript);
    assert(inferLanguageFromExtension(".tsx") == TargetLanguage.TypeScript);
    assert(inferLanguageFromExtension(".rs") == TargetLanguage.Rust);
    assert(inferLanguageFromExtension(".go") == TargetLanguage.Go);
    assert(inferLanguageFromExtension(".cpp") == TargetLanguage.Cpp);
    assert(inferLanguageFromExtension(".hpp") == TargetLanguage.Cpp);
    assert(inferLanguageFromExtension(".cs") == TargetLanguage.CSharp);
    assert(inferLanguageFromExtension(".fs") == TargetLanguage.FSharp);
    assert(inferLanguageFromExtension(".unknown") == TargetLanguage.Generic);
    
    // Test get extensions
    auto pyExts = getLanguageExtensions(TargetLanguage.Python);
    assert(pyExts.length == 1);
    assert(pyExts.canFind(".py"));
    
    auto jsExts = getLanguageExtensions(TargetLanguage.JavaScript);
    assert(jsExts.length >= 4);
    assert(jsExts.canFind(".js"));
    assert(jsExts.canFind(".jsx"));
    
    // Test language support check
    assert(isLanguageSupported(TargetLanguage.Python));
    assert(isLanguageSupported(TargetLanguage.FSharp));
    assert(isLanguageSupported(TargetLanguage.CSS));
    
    // Test display names
    assert(getLanguageDisplayName(TargetLanguage.Python) == "python");
    assert(getLanguageDisplayName(TargetLanguage.JavaScript) == "javascript");
}

