module engine.runtime.services.registry.handler;

import infrastructure.config.schema.schema : TargetLanguage;
import languages.base.base : LanguageHandler;
import languages.dynamic : SpecRegistry, SpecBasedHandler;
import languages.registry : parseLanguageName;
import infrastructure.errors;
import std.conv : to;
import core.sync.mutex : Mutex;
import infrastructure.utils.logging : structuredLog;

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
///
/// Handlers are NOT shared between builds. Every handler keeps per-build state
/// (parsed language config, resolved toolchain, output type), so handing the
/// same instance to targets running on different workers makes them overwrite
/// each other — a library target picks up an executable's output type and fails
/// to link. `get` therefore returns a fresh handler per call; only a handler an
/// caller registered explicitly is reused, because that is an explicit choice.
final class HandlerRegistry : IHandlerRegistry
{
    private LanguageHandler[TargetLanguage] registered;  // Explicit overrides only
    private SpecRegistry specRegistry;
    private Mutex registryMutex;
    
    this() @safe
    {
        registryMutex = new Mutex();
    }
    
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
            case TargetLanguage.WebAssembly:
                import languages.wasm : WebAssemblyHandler;
                return new WebAssemblyHandler();
            case TargetLanguage.CUDA:
                import languages.gpu.cuda : CUDAHandler;
                return new CUDAHandler();
            case TargetLanguage.ROCm:
                import languages.gpu.rocm : ROCmHandler;
                return new ROCmHandler();
            case TargetLanguage.Metal:
                import languages.gpu.metal : MetalHandler;
                return new MetalHandler();
            case TargetLanguage.FSharp:
                import languages.dotnet.fsharp : FSharpHandler;
                return new FSharpHandler();
            case TargetLanguage.CSS:
                import languages.web.css : CSSHandler;
                return new CSSHandler();
            case TargetLanguage.Generic:
                return null;
        }
    }
    
    /// Initialize registry and load dynamic language specs
    void initialize() @system
    {
        synchronized (registryMutex)
            initializeLocked();
    }
    
    /// Load dynamic language specs; caller must hold registryMutex
    private void initializeLocked() @system
    {
        // Initialize spec registry for dynamic languages
        specRegistry = new SpecRegistry();
        auto result = specRegistry.loadAll();
        
        if (result.isOk)
        {
            auto count = result.unwrap();
            if (count > 0)
                structuredLog.debug_("loaded_").field("detail", "Loaded " ~ count.to!string ~ " dynamic language specs").emit();
        }
    }
    
    LanguageHandler get(TargetLanguage language) @trusted
    {
        synchronized (registryMutex)
        {
            if (auto handler = language in registered)
                return *handler;
        }
        
        // Fresh instance: handlers are stateful and callers run concurrently
        return createHandler(language);
    }
    
    /// Get handler by string name (supports dynamic spec-based languages)
    LanguageHandler getByName(string langName) @trusted
    {
        import std.conv : to;
        
        // First try built-in language enum lookup
        auto language = parseLanguageName(langName);
        if (language != TargetLanguage.Generic)
            return get(language);
        
        // Spec-based dynamic language. The spec registry is immutable shared
        // data and is cached; the handler wrapping it is not.
        synchronized (registryMutex)
        {
            if (specRegistry is null)
                initializeLocked();
            
            if (auto spec = specRegistry.get(langName))
                return new SpecBasedHandler(*spec);
        }
        
        return null;
    }
    
    bool has(TargetLanguage language) @trusted
    {
        synchronized (registryMutex)
        {
            if (language in registered)
                return true;
        }
        
        return createHandler(language) !is null;
    }
    
    void register(TargetLanguage language, LanguageHandler handler) @trusted
    {
        synchronized (registryMutex)
            registered[language] = handler;
    }
    
    TargetLanguage[] languages() @trusted
    {
        synchronized (registryMutex)
            return registered.keys;
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

