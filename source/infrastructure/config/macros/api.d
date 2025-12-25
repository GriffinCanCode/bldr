module infrastructure.config.macros.api;

import std.array;
import std.algorithm;
import infrastructure.config.schema.schema;
import infrastructure.errors;

/// Macro API for target generation
/// Provides high-level D interface for building targets programmatically

/// Target builder for fluent API
struct TargetBuilder
{
    private Target target;
    
    /// Create new target builder
    static TargetBuilder create(string name) pure @system
    {
        TargetBuilder builder;
        builder.target.name = name;
        return builder;
    }
    
    /// Set target type
    TargetBuilder type(TargetType type) pure @system
    {
        this.target.type = type;
        return this;
    }
    
    /// Set language
    TargetBuilder language(string lang) pure @system
    {
        import std.conv : to;
        import std.uni : toLower;
        import std.algorithm : startsWith;
        
        // Convert string to TargetLanguage enum
        switch (lang.toLower())
        {
            case "d": this.target.language = TargetLanguage.D; break;
            case "python": case "py": this.target.language = TargetLanguage.Python; break;
            case "javascript": case "js": this.target.language = TargetLanguage.JavaScript; break;
            case "typescript": case "ts": this.target.language = TargetLanguage.TypeScript; break;
            case "go": this.target.language = TargetLanguage.Go; break;
            case "rust": case "rs": this.target.language = TargetLanguage.Rust; break;
            case "cpp": case "c++": case "cxx": this.target.language = TargetLanguage.Cpp; break;
            case "c": this.target.language = TargetLanguage.C; break;
            case "java": this.target.language = TargetLanguage.Java; break;
            case "kotlin": case "kt": this.target.language = TargetLanguage.Kotlin; break;
            case "csharp": case "c#": case "cs": this.target.language = TargetLanguage.CSharp; break;
            case "fsharp": case "f#": case "fs": this.target.language = TargetLanguage.FSharp; break;
            case "zig": this.target.language = TargetLanguage.Zig; break;
            case "swift": this.target.language = TargetLanguage.Swift; break;
            case "ruby": case "rb": this.target.language = TargetLanguage.Ruby; break;
            case "perl": case "pl": this.target.language = TargetLanguage.Perl; break;
            case "php": this.target.language = TargetLanguage.PHP; break;
            case "scala": this.target.language = TargetLanguage.Scala; break;
            case "elixir": case "ex": this.target.language = TargetLanguage.Elixir; break;
            case "nim": this.target.language = TargetLanguage.Nim; break;
            case "lua": this.target.language = TargetLanguage.Lua; break;
            case "r": this.target.language = TargetLanguage.R; break;
            case "css": this.target.language = TargetLanguage.CSS; break;
            case "protobuf": case "proto": this.target.language = TargetLanguage.Protobuf; break;
            case "ocaml": case "ml": this.target.language = TargetLanguage.OCaml; break;
            case "haskell": case "hs": this.target.language = TargetLanguage.Haskell; break;
            case "elm": this.target.language = TargetLanguage.Elm; break;
            default: this.target.language = TargetLanguage.Generic; break;
        }
        return this;
    }
    
    /// Set sources
    TargetBuilder sources(string[] srcs) pure @system
    {
        this.target.sources = srcs;
        return this;
    }
    
    /// Set dependencies
    TargetBuilder deps(string[] dependencies) pure @system
    {
        this.target.deps = dependencies;
        return this;
    }
    
    /// Set compiler flags
    TargetBuilder flags(string[] compilerFlags) pure @system
    {
        this.target.flags = compilerFlags;
        return this;
    }
    
    /// Set environment variables
    TargetBuilder env(string[string] environment) pure @system
    {
        this.target.env = environment;
        return this;
    }
    
    /// Set output path
    TargetBuilder output(string path) pure @system
    {
        this.target.outputPath = path;
        return this;
    }
    
    /// Build final target
    Target build() pure @system
    {
        return target;
    }
}

/// Helper functions for common patterns

/// Create executable target
Target executable(string name, string[] sources, string language = "") pure @system
{
    return TargetBuilder.create(name)
        .type(TargetType.Executable)
        .language(language)
        .sources(sources)
        .build();
}

/// Create library target
Target library(string name, string[] sources, string language = "") pure @system
{
    return TargetBuilder.create(name)
        .type(TargetType.Library)
        .language(language)
        .sources(sources)
        .build();
}

/// Create test target
Target test(string name, string[] sources, string[] deps = []) pure @system
{
    return TargetBuilder.create(name)
        .type(TargetType.Test)
        .sources(sources)
        .deps(deps)
        .build();
}

/// Generate targets from template (lazy range)
auto generateTargets(T)(T[] items, Target delegate(T) fn) pure @system
{
    return items.map!fn;
}

/// Glob-based target generation
Target[] targetsFromGlob(string pattern, TargetType type, string language) @system
{
    import infrastructure.utils.files.glob : GlobMatcher;
    import std.file : getcwd;
    import std.path : baseName, stripExtension;
    
    auto files = GlobMatcher.match([pattern], getcwd());
    return files.map!(file =>
        TargetBuilder.create(file.baseName.stripExtension)
            .type(type)
            .language(language)
            .sources([file])
            .build()
    ).array;
}

/// Platform-specific target configuration
Target platformTarget(string name, string[string] platformConfigs) @system
{
    string platform;
    version (linux)
        platform = "linux";
    else version (OSX)
        platform = "darwin";
    else version (Windows)
        platform = "windows";
    else
        platform = "unknown";
    
    auto builder = TargetBuilder.create(name);
    
    if (platform in platformConfigs)
    {
        // Parse platform config (simplified)
        builder = builder.sources([platformConfigs[platform]]);
    }
    
    return builder.build();
}

/// Macro context for accessing build environment
struct MacroContext
{
    string workspaceRoot;
    string[string] environment;
    string[] availableLanguages;
    
    /// Get environment variable
    string getEnv(string key, string defaultValue = "") const pure nothrow @safe
    {
        return (key in environment) ? environment[key] : defaultValue;
    }
    
    /// Check if language is available
    bool hasLanguage(string lang) const pure @safe
    {
        return availableLanguages.canFind(lang);
    }
}

/// Macro registration interface
interface MacroProvider
{
    /// Get macro name
    string name() const pure nothrow @safe;
    
    /// Execute macro and return generated targets
    Target[] execute(MacroContext context) @system;
    
    /// Get macro description
    string description() const pure nothrow @safe;
}

/// Base class for user-defined macros
abstract class BaseMacro : MacroProvider
{
    private string name_;
    private string description_;
    
    this(string name, string description) pure nothrow @safe
    {
        this.name_ = name;
        this.description_ = description;
    }
    
    override string name() const pure nothrow @safe
    {
        return name_;
    }
    
    override string description() const pure nothrow @safe
    {
        return description_;
    }
}

