module infrastructure.config.macros.loader;

import std.array : join;
import std.algorithm;
import infrastructure.config.macros.api;
import infrastructure.config.schema.schema : Target;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

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
        Logger.debugLog("Registered macro: " ~ name);
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
        {
            import infrastructure.errors.types.types : ParseError;
            return typeof(return).err(new ParseError(
                "",
                "Unknown macro: " ~ name,
                ErrorCode.InvalidConfiguration
            ));
        }
        
        try
        {
            auto result = macros[name](args);
            return typeof(return).ok(result);
        }
        catch (Exception e)
        {
            import infrastructure.errors.types.types : ParseError;
            return typeof(return).err(new ParseError(
                "",
                "Macro '" ~ name ~ "' failed: " ~ e.msg,
                ErrorCode.MacroExpansionFailed
            ));
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
        {
            import infrastructure.errors.types.types : IOError;
            return typeof(return).err(new IOError(
                filename,
                "Macro file not found: " ~ filename,
                ErrorCode.FileNotFound
            ));
        }
        
        Logger.info("Loading and compiling macros from: " ~ filename);
        
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
            import infrastructure.errors.types.types : IOError;
            return typeof(return).err(new IOError(
                dirName(sharedLibPath),
                "Failed to create macro library directory: " ~ e.msg,
                ErrorCode.FileWriteFailed
            ));
        }
        
        // 3. Compile D source to shared library
        auto compileResult = compileMacroLibrary(filename, sharedLibPath);
        if (compileResult.isErr)
            return typeof(return).err(compileResult.unwrapErr());
        
        // 4. Load shared library dynamically
        auto loadResult = loadMacroLibrary(sharedLibPath);
        if (loadResult.isErr)
            return typeof(return).err(loadResult.unwrapErr());
        
        Logger.info("Successfully loaded macros from: " ~ filename);
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
        {
            import infrastructure.errors.types.types : SystemError;
            return VoidBuildResult.err(new SystemError(
                "No D compiler found (dmd or ldc2 required for macro compilation)",
                ErrorCode.CompilationFailed
            ));
        }
        
        string[] compilerArgs = [
            compiler,
            "-shared",                    // Build shared library
            "-fPIC",                      // Position-independent code
            "-of=" ~ outputLib,           // Output file
            "-I=source",                  // Include source directory
            "-version=MacroCompilation",  // Signal this is a macro build
            sourceFile
        ];
        
        Logger.debugLog("Compiling macro: " ~ compilerArgs.join(" "));
        
        auto result = execute(compilerArgs);
        if (result.status != 0)
        {
            import infrastructure.errors.types.types : compilationError;
            return VoidBuildResult.err(compilationError(
                sourceFile,
                "Macro compilation failed",
                format("Compiler output:\n%s", result.output)
            ));
        }
        
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
        {
            import infrastructure.errors.types.types : IOError;
            return VoidBuildResult.err(new IOError(
                libPath,
                "Compiled macro library not found",
                ErrorCode.FileNotFound
            ));
        }
        
        // Load shared library
        void* handle = dlopen(toStringz(libPath), RTLD_LAZY | RTLD_LOCAL);
        if (handle is null)
        {
            import infrastructure.errors.types.types : SystemError;
            import std.format : format;
            auto errorMsg = fromStringz(dlerror());
            return VoidBuildResult.err(new SystemError(
                format("Failed to load macro library: %s", errorMsg),
                ErrorCode.MacroLoadFailed
            ));
        }
        
        // Look for registration function: extern(C) void registerMacros(MacroRegistry)
        alias RegisterFunc = extern(C) void function(MacroRegistry);
        auto registerFunc = cast(RegisterFunc)dlsym(handle, "registerMacros");
        
        if (registerFunc is null)
        {
            import infrastructure.errors.types.types : SystemError;
            dlclose(handle);
            return VoidBuildResult.err(new SystemError(
                "Macro library missing 'registerMacros' function",
                ErrorCode.MacroExpansionFailed
            ));
        }
        
        // Call registration function to register all macros
        try
        {
            registerFunc(MacroRegistry.instance());
        }
        catch (Exception e)
        {
            import infrastructure.errors.types.types : SystemError;
            import std.format : format;
            dlclose(handle);
            return VoidBuildResult.err(new SystemError(
                format("Macro registration failed: %s", e.msg),
                ErrorCode.MacroLoadFailed
            ));
        }
        
        // Keep library loaded (store handle for cleanup if needed)
        Logger.debugLog("Loaded macro library: " ~ libPath);
        return Ok!BuildError();
    }
    
    /// Load macros from a directory
    static BuildResult!bool loadFromDirectory(string dir) @system
    {
        import std.file : dirEntries, SpanMode, exists;
        import std.path : extension;
        import std.algorithm : filter, each;
        
        if (!exists(dir))
        {
            import infrastructure.errors.types.types : IOError;
            return typeof(return).err(new IOError(
                dir,
                "Macro directory not found: " ~ dir,
                ErrorCode.FileNotFound
            ));
        }
        
        try
        {
            dirEntries(dir, "*.d", SpanMode.shallow)
                .filter!(f => f.isFile)
                .each!(f => loadFromFile(f.name));
            
            return typeof(return).ok(true);
        }
        catch (Exception e)
        {
            import infrastructure.errors.types.types : ParseError;
            return typeof(return).err(new ParseError(
                dir,
                "Failed to load macros from directory: " ~ e.msg,
                ErrorCode.MacroLoadFailed
            ));
        }
    }
}
