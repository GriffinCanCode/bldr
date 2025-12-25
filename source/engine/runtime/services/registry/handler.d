module engine.runtime.services.registry.handler;

import infrastructure.config.schema.schema : TargetLanguage;
import languages.base.base : LanguageHandler;
import languages.dynamic : SpecRegistry, SpecBasedHandler;
import languages.registry : parseLanguageName;
import infrastructure.errors;
import std.conv : to;

/// Handler registry interface
interface IHandlerRegistry
{
    /// Get handler for language
    LanguageHandler get(TargetLanguage language);
    
    /// Check if handler exists for language
    bool has(TargetLanguage language);
    
    /// Register handler for language
    void register(TargetLanguage language, LanguageHandler handler);
    
    /// Get all registered languages
    TargetLanguage[] languages();
    
    /// Get handler by string name (supports dynamic languages)
    LanguageHandler getByName(string langName);
}

/// Concrete handler registry implementation
/// Manages language handler lifecycle with lazy per-language loading
/// Extended to support spec-based dynamic languages
final class HandlerRegistry : IHandlerRegistry
{
    private LanguageHandler[TargetLanguage] handlers;
    private LanguageHandler[string] dynamicHandlers;  // For spec-based languages
    private SpecRegistry specRegistry;
    
    /// Create handler on-demand for a specific language
    private LanguageHandler createHandler(TargetLanguage language) @trusted
    {
        final switch (language)
        {
            case TargetLanguage.Python:
                import languages.scripting.python : PythonHandler;
                return new PythonHandler();
            case TargetLanguage.JavaScript:
                import languages.web.javascript : JavaScriptHandler;
                return new JavaScriptHandler();
            case TargetLanguage.TypeScript:
                import languages.web.typescript : TypeScriptHandler;
                return new TypeScriptHandler();
            case TargetLanguage.Elm:
                import languages.web.elm : ElmHandler;
                return new ElmHandler();
            case TargetLanguage.Go:
                import languages.scripting.go : GoHandler;
                return new GoHandler();
            case TargetLanguage.Rust:
                import languages.compiled.rust : RustHandler;
                return new RustHandler();
            case TargetLanguage.D:
                import languages.compiled.d : DHandler;
                return new DHandler();
            case TargetLanguage.Cpp:
                import languages.compiled.cpp : CppHandler;
                return new CppHandler();
            case TargetLanguage.C:
                import languages.compiled.cpp : CHandler;
                return new CHandler();
            case TargetLanguage.Java:
                import languages.jvm.java : JavaHandler;
                return new JavaHandler();
            case TargetLanguage.Kotlin:
                import languages.jvm.kotlin : KotlinHandler;
                return new KotlinHandler();
            case TargetLanguage.Scala:
                import languages.jvm.scala : ScalaHandler;
                return new ScalaHandler();
            case TargetLanguage.CSharp:
                import languages.dotnet.csharp : CSharpHandler;
                return new CSharpHandler();
            case TargetLanguage.Zig:
                import languages.compiled.zig : ZigHandler;
                return new ZigHandler();
            case TargetLanguage.Swift:
                import languages.compiled.swift : SwiftHandler;
                return new SwiftHandler();
            case TargetLanguage.Ruby:
                import languages.scripting.ruby : RubyHandler;
                return new RubyHandler();
            case TargetLanguage.Perl:
                import languages.scripting.perl : PerlHandler;
                return new PerlHandler();
            case TargetLanguage.PHP:
                import languages.scripting.php : PHPHandler;
                return new PHPHandler();
            case TargetLanguage.Elixir:
                import languages.scripting.elixir : ElixirHandler;
                return new ElixirHandler();
            case TargetLanguage.Gleam:
                import languages.scripting.gleam : GleamHandler;
                return new GleamHandler();
            case TargetLanguage.Nim:
                import languages.compiled.nim : NimHandler;
                return new NimHandler();
            case TargetLanguage.Lua:
                import languages.scripting.lua : LuaHandler;
                return new LuaHandler();
            case TargetLanguage.R:
                import languages.scripting.r : RHandler;
                return new RHandler();
            case TargetLanguage.Haskell:
                import languages.compiled.haskell : HaskellHandler;
                return new HaskellHandler();
            case TargetLanguage.OCaml:
                import languages.compiled.ocaml : OCamlHandler;
                return new OCamlHandler();
            case TargetLanguage.Protobuf:
                import languages.compiled.protobuf : ProtobufHandler;
                return new ProtobufHandler();
            case TargetLanguage.FSharp:
            case TargetLanguage.CSS:
            case TargetLanguage.Generic:
                return null;
        }
    }
    
    /// Initialize registry and load dynamic language specs
    void initialize() @system
    {
        // Initialize spec registry for dynamic languages
        specRegistry = new SpecRegistry();
        auto result = specRegistry.loadAll();
        
        if (result.isOk)
        {
            import infrastructure.utils.logging.logger : Logger;
            auto count = result.unwrap();
            if (count > 0)
                Logger.debugLog("Loaded " ~ count.to!string ~ " dynamic language specs");
        }
    }
    
    LanguageHandler get(TargetLanguage language) @trusted
    {
        // Check if already cached
        if (auto handler = language in handlers)
            return *handler;
        
        // Create handler on-demand
        auto handler = createHandler(language);
        if (handler !is null)
            handlers[language] = handler;
        
        return handler;
    }
    
    /// Get handler by string name (supports dynamic spec-based languages)
    LanguageHandler getByName(string langName) @trusted
    {
        import std.conv : to;
        
        // First try built-in language enum lookup
        auto language = parseLanguageName(langName);
        if (language != TargetLanguage.Generic)
        {
            return get(language);
        }
        
        // Check if already cached as dynamic handler
        if (auto handler = langName in dynamicHandlers)
            return *handler;
        
        // Try spec-based dynamic language
        if (specRegistry is null)
            initialize();
        
        if (auto spec = specRegistry.get(langName))
        {
            auto handler = new SpecBasedHandler(*spec);
            dynamicHandlers[langName] = handler;
            return handler;
        }
        
        return null;
    }
    
    bool has(TargetLanguage language) @trusted
    {
        // Check cache first
        if (language in handlers)
            return true;
        
        // For uncached handlers, check if we can create one
        return createHandler(language) !is null;
    }
    
    void register(TargetLanguage language, LanguageHandler handler) @trusted
    {
        handlers[language] = handler;
    }
    
    TargetLanguage[] languages() @trusted
    {
        return handlers.keys;
    }
}

/// Null handler registry for testing
final class NullHandlerRegistry : IHandlerRegistry
{
    LanguageHandler get(TargetLanguage language) @trusted
    {
        return null;
    }
    
    LanguageHandler getByName(string langName) @trusted
    {
        return null;
    }
    
    bool has(TargetLanguage language) @trusted
    {
        return false;
    }
    
    void register(TargetLanguage language, LanguageHandler handler) @trusted
    {
    }
    
    TargetLanguage[] languages() @trusted
    {
        return [];
    }
}

