module infrastructure.config.macros.loader;

import std.array : join;
import std.algorithm;
import infrastructure.config.macros.api;
import infrastructure.config.schema.schema : Target;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Macro function type
alias MacroFunction = Target[] delegate(string[]);

/// Registry for D-based macros
final class MacroRegistry
{
    private static MacroRegistry _instance;
    private MacroFunction[string] macros;
    
    /// Get singleton instance
    static MacroRegistry instance() @trusted
    {
        if (_instance is null)
        {
            _instance = new MacroRegistry();
        }
        return _instance;
    }
    
    private this() @safe
    {
    }
    
    /// Register a macro function
    void register(Func)(string name, Func fn) @trusted
    {
        macros[name] = delegate Target[](string[] args) {
            return fn(args);
        };
        structuredLog.debug_("registered_macro_").field("detail", "Registered macro: " ~ name).emit();
    }
    
    /// Check if macro exists
    bool has(string name) const @safe
    {
        return (name in macros) !is null;
    }
    
    /// Call a macro
    BuildResult!(Target[]) call(string name, string[] args) @trusted
    {
        if (name !in macros)
            return typeof(return).err(
                Errors.parse("", "Unknown macro: " ~ name, Parse.InvalidConfiguration));
        
        try
        {
            return typeof(return).ok(macros[name](args));
        }
        catch (Exception e)
        {
            return typeof(return).err(
                Errors.parse("", "Macro '" ~ name ~ "' failed: " ~ e.msg, Language.MacroExpansionFailed));
        }
    }
    
    /// Get list of registered macros
    string[] list() const @safe
    {
        return macros.keys;
    }
    
    /// Clear all registered macros
    void clear() @safe
    {
        macros.clear();
    }
}

/// Dynamic macro loader from compiled .d files
struct MacroLoader
{
    /// Load macros from a D source file
    static BuildResult!bool loadFromFile(string filename) @system
    {
        import std.file : exists, readText, tempDir, write;
        import std.process : execute, ProcessException;
        import std.path : buildPath, absolutePath, dirName, baseName, stripExtension;
        import std.string : strip;
        import std.uuid : randomUUID;
        
        if (!exists(filename))
            return typeof(return).err(
                Errors.io(filename, "Macro file not found: " ~ filename, IO.FileNotFound));
        
        structuredLog.info("loading_and_compiling_macros_from_").field("detail", "Loading and compiling macros from: " ~ filename).emit();
        
        // 1. Generate unique shared library name
        immutable libName = "macro_" ~ stripExtension(baseName(filename)) ~ "_" ~ randomUUID().toString()[0..8];
        immutable sharedLibPath = buildPath(tempDir(), "builder_macros", libName ~ ".so");
        
        // 2. Create output directory
        try
        {
            import std.file : mkdirRecurse;
            mkdirRecurse(dirName(sharedLibPath));
        }
        catch (Exception e)
        {
            return typeof(return).err(
                Errors.io(dirName(sharedLibPath), "Failed to create macro library directory: " ~ e.msg, IO.FileWriteFailed));
        }
        
        // 3. Compile D source to shared library
        auto compileResult = compileMacroLibrary(filename, sharedLibPath);
        if (compileResult.isErr)
            return typeof(return).err(compileResult.unwrapErr());
        
        // 4. Load shared library dynamically
        auto loadResult = loadMacroLibrary(sharedLibPath);
        if (loadResult.isErr)
            return typeof(return).err(loadResult.unwrapErr());
        
        structuredLog.info("successfully_loaded_macros_from_").field("detail", "Successfully loaded macros from: " ~ filename).emit();
        return typeof(return).ok(true);
    }
    
    /// Compile D source file to shared library
    private static VoidBuildResult compileMacroLibrary(string sourceFile, string outputLib) @system
    {
        import std.process : execute;
        import std.format : format;
        
        // Build D compiler command (use dmd or ldc2)
        string compiler = findDCompiler();
        if (compiler.length == 0)
            return VoidBuildResult.err(
                Errors.system("No D compiler found (dmd or ldc2 required for macro compilation)", Language.CompilationFailed));
        
        string[] compilerArgs = [
            compiler,
            "-shared",                    // Build shared library
            "-fPIC",                      // Position-independent code
            "-of=" ~ outputLib,           // Output file
            "-I=source",                  // Include source directory
            "-version=MacroCompilation",  // Signal this is a macro build
            sourceFile
        ];
        
        structuredLog.debug_("compiling_macro_").field("detail", "Compiling macro: " ~ compilerArgs.join(" ")).emit();
        
        auto result = execute(compilerArgs);
        if (result.status != 0)
            return VoidBuildResult.err(compilationError(
                sourceFile, "Macro compilation failed", format("Compiler output:\n%s", result.output)));
        
        return Ok!BuildError();
    }
    
    /// Find available D compiler
    private static string findDCompiler() @system
    {
        import std.process : execute;
        import std.string : strip;
        
        // Try ldc2 first (better optimization)
        auto ldcResult = execute(["which", "ldc2"]);
        if (ldcResult.status == 0 && ldcResult.output.strip().length > 0)
            return "ldc2";
        
        // Fall back to dmd
        auto dmdResult = execute(["which", "dmd"]);
        if (dmdResult.status == 0 && dmdResult.output.strip().length > 0)
            return "dmd";
        
        return "";
    }
    
    /// Load shared library and register macros
    private static VoidBuildResult loadMacroLibrary(string libPath) @system
    {
        import std.file : exists;
        import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, dlerror, RTLD_LAZY, RTLD_LOCAL;
        import std.string : toStringz, fromStringz;
        
        if (!exists(libPath))
            return VoidBuildResult.err(
                Errors.io(libPath, "Compiled macro library not found", IO.FileNotFound));
        
        // Load shared library
        void* handle = dlopen(toStringz(libPath), RTLD_LAZY | RTLD_LOCAL);
        if (handle is null)
        {
            import std.format : format;
            auto errorMsg = fromStringz(dlerror());
            return VoidBuildResult.err(
                Errors.system(format("Failed to load macro library: %s", errorMsg), Language.MacroLoadFailed));
        }
        
        // Look for registration function: extern(C) void registerMacros(MacroRegistry)
        alias RegisterFunc = extern(C) void function(MacroRegistry);
        auto registerFunc = cast(RegisterFunc)dlsym(handle, "registerMacros");
        
        if (registerFunc is null)
        {
            dlclose(handle);
            return VoidBuildResult.err(
                Errors.system("Macro library missing 'registerMacros' function", Language.MacroExpansionFailed));
        }
        
        // Call registration function to register all macros
        try
        {
            registerFunc(MacroRegistry.instance());
        }
        catch (Exception e)
        {
            import std.format : format;
            dlclose(handle);
            return VoidBuildResult.err(
                Errors.system(format("Macro registration failed: %s", e.msg), Language.MacroLoadFailed));
        }
        
        // Keep library loaded (store handle for cleanup if needed)
        structuredLog.debug_("loaded_macro_library_").field("detail", "Loaded macro library: " ~ libPath).emit();
        return Ok!BuildError();
    }
    
    /// Load macros from a directory
    static BuildResult!bool loadFromDirectory(string dir) @system
    {
        import std.file : dirEntries, SpanMode, exists;
        import std.path : extension;
        import std.algorithm : filter, each;
        
        if (!exists(dir))
            return typeof(return).err(
                Errors.io(dir, "Macro directory not found: " ~ dir, IO.FileNotFound));
        
        try
        {
            dirEntries(dir, "*.d", SpanMode.shallow)
                .filter!(f => f.isFile)
                .each!(f => loadFromFile(f.name));
            
            return typeof(return).ok(true);
        }
        catch (Exception e)
        {
            return typeof(return).err(
                Errors.parse(dir, "Failed to load macros from directory: " ~ e.msg, Language.MacroLoadFailed));
        }
    }
}
