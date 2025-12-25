module languages.compiled.cpp.builders.base;

import std.range;
import std.string;
import std.conv;
import languages.compiled.cpp.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import engine.caching.actions.action : ActionCache;

/// Base interface for C++ builders
interface CppBuilder
{
    /// Build C++ project
    CppCompileResult build(
        in string[] sources,
        in CppConfig config,
        in Target target,
        in WorkspaceConfig workspace
    );
    
    /// Check if builder is available on system
    bool isAvailable();
    
    /// Get builder name
    string name() const;
    
    /// Get builder version
    string getVersion();
    
    /// Supports specific features
    bool supportsFeature(string feature);
}

/// Factory for creating C++ builders
class CppBuilderFactory
{
    /// Create builder based on build system and compiler with optional action cache
    static CppBuilder create(CppConfig config, ActionCache cache = null)
    {
        import languages.compiled.cpp.builders.direct;
        import languages.compiled.cpp.builders.cmake;
        import languages.compiled.cpp.builders.make;
        import languages.compiled.cpp.builders.ninja;
        
        // If build system is specified, use it
        if (config.buildSystem != BuildSystem.None && config.buildSystem != BuildSystem.Auto)
        {
            return createBuildSystem(config.buildSystem, config, cache);
        }
        
        // Auto-detect build system
        auto buildSystem = config.buildSystem;
        if (buildSystem == BuildSystem.Auto)
        {
            buildSystem = detectBuildSystem();
        }
        
        // If no build system, use direct compilation
        if (buildSystem == BuildSystem.None)
        {
            return new DirectBuilder(config, cache);
        }
        
        return createBuildSystem(buildSystem, config, cache);
    }
    
    /// Create builder for specific build system with optional action cache
    private static CppBuilder createBuildSystem(BuildSystem buildSystem, CppConfig config, ActionCache cache)
    {
        import languages.compiled.cpp.builders.direct;
        import languages.compiled.cpp.builders.cmake;
        import languages.compiled.cpp.builders.make;
        import languages.compiled.cpp.builders.ninja;
        
        final switch (buildSystem)
        {
            case BuildSystem.None:
                return new DirectBuilder(config, cache);
            case BuildSystem.Auto:
                return create(config, cache);
            case BuildSystem.CMake:
                auto cmake = new CMakeBuilder(config);
                if (cmake.isAvailable())
                    return cmake;
                return new DirectBuilder(config, cache);
            case BuildSystem.Make:
                auto make = new MakeBuilder(config);
                if (make.isAvailable())
                    return make;
                return new DirectBuilder(config, cache);
            case BuildSystem.Ninja:
                auto ninja = new NinjaBuilder(config);
                if (ninja.isAvailable())
                    return ninja;
                return new DirectBuilder(config, cache);
            case BuildSystem.Bazel:
                import languages.compiled.cpp.builders.bazel;
                return new BazelBuilder(config);
            case BuildSystem.Meson:
                import languages.compiled.cpp.builders.meson;
                return new MesonBuilder(config);
            case BuildSystem.Xmake:
                import languages.compiled.cpp.builders.xmake;
                return new XmakeBuilder(config);
        }
    }
    
    /// Detect build system from current directory
    private static BuildSystem detectBuildSystem()
    {
        import std.file : exists, getcwd;
        import std.path : buildPath;
        
        string cwd = getcwd();
        
        // Check for CMakeLists.txt
        if (exists(buildPath(cwd, "CMakeLists.txt")))
            return BuildSystem.CMake;
        
        // Check for Makefile
        if (exists(buildPath(cwd, "Makefile")) || exists(buildPath(cwd, "makefile")))
            return BuildSystem.Make;
        
        // Check for build.ninja
        if (exists(buildPath(cwd, "build.ninja")))
            return BuildSystem.Ninja;
        
        // Check for Bazel BUILD/WORKSPACE
        if (exists(buildPath(cwd, "BUILD")) || exists(buildPath(cwd, "WORKSPACE")))
            return BuildSystem.Bazel;
        
        // Check for meson.build
        if (exists(buildPath(cwd, "meson.build")))
            return BuildSystem.Meson;
        
        // Check for xmake.lua
        if (exists(buildPath(cwd, "xmake.lua")))
            return BuildSystem.Xmake;
        
        // No build system detected
        return BuildSystem.None;
    }
}

/// Base builder with common functionality
abstract class BaseCppBuilder : CppBuilder
{
    protected CppConfig config;
    
    this(CppConfig config)
    {
        this.config = config;
    }
    
    abstract CppCompileResult build(
        in string[] sources,
        in CppConfig config,
        in Target target,
        in WorkspaceConfig workspace
    );
    
    abstract bool isAvailable();
    abstract string name() const;
    abstract string getVersion();
    
    bool supportsFeature(string feature)
    {
        // Base implementation: common features
        switch (feature)
        {
            case "compile":
            case "link":
                return true;
            default:
                return false;
        }
    }
    
    /// Get compiler command for source file
    protected string getCompilerCommand(string source, CppConfig config)
    {
        import std.path : extension;
        import infrastructure.toolchain.core.spec;
        import infrastructure.toolchain.registry.registry : ToolchainRegistry;
        import infrastructure.toolchain.core.platform : Platform;
        
        // Get compiler from registry
        auto registry = ToolchainRegistry.instance();
        registry.initialize();
        auto result = registry.findFor(Platform.host(), ToolchainType.Compiler);
        if (result.isErr)
            return config.compiler == Compiler.Clang ? "clang++" : "g++"; // Fallback
        
        auto toolchain = result.unwrap();
        auto compiler = toolchain.compiler();
        string compilerPath = compiler !is null ? compiler.path : "g++";
        
        string ext = extension(source).toLower;
        
        // Determine if C or C++
        bool isCpp = (ext == ".cpp" || ext == ".cxx" || ext == ".cc" || 
                     ext == ".C" || ext == ".c++" || ext == ".hpp" || ext == ".hxx");
        
        // For C++, use g++ or clang++
        if (isCpp && compiler !is null)
        {
            if (compiler.name == "gcc" || compiler.name == "g++")
            {
                import std.string : replace;
                return compilerPath.replace("gcc", "g++");
            }
            else if (compiler.name == "clang" || compiler.name == "clang++")
            {
                import std.string : replace;
                return compilerPath.replace("clang", "clang++");
            }
        }
        
        return compilerPath;
    }
    
    /// Build compiler flags from config
    string[] buildCompilerFlags(in CppConfig config, bool isCpp)
    {
        import std.conv : to;
        
        string[] flags;
        
        // Standard
        if (isCpp)
        {
            flags ~= getStandardFlag(config.cppStandard);
        }
        else
        {
            flags ~= getCStandardFlag(config.cStandard);
        }
        
        // Optimization
        flags ~= getOptimizationFlag(config.optLevel);
        
        // Warnings
        flags ~= getWarningFlags(config.warnings);
        
        // Debug info
        if (config.debugInfo)
        {
            flags ~= "-g";
        }
        
        // PIC/PIE
        if (config.pic || config.outputType == OutputType.SharedLib)
        {
            flags ~= "-fPIC";
        }
        if (config.pie && config.outputType == OutputType.Executable)
        {
            flags ~= "-fPIE";
        }
        
        // Exceptions
        if (!config.exceptions && isCpp)
        {
            flags ~= "-fno-exceptions";
        }
        
        // RTTI
        if (!config.rtti && isCpp)
        {
            flags ~= "-fno-rtti";
        }
        
        // LTO
        if (config.lto != LtoMode.Off)
        {
            flags ~= getLtoFlag(config.lto);
        }
        
        // Sanitizers
        foreach (sanitizer; config.sanitizers)
        {
            flags ~= getSanitizerFlag(sanitizer);
        }
        
        // Color diagnostics
        if (config.colorDiagnostics)
        {
            flags ~= "-fdiagnostics-color=always";
        }
        
        // Time report
        if (config.timeReport)
        {
            flags ~= "-ftime-report";
        }
        
        // Modules (C++20)
        if (config.modules && isCpp)
        {
            flags ~= "-fmodules";
        }
        
        // Include directories
        foreach (inc; config.includeDirs)
        {
            flags ~= "-I" ~ inc;
        }
        
        // Defines
        foreach (def; config.defines)
        {
            flags ~= "-D" ~ def;
        }
        
        // Custom flags
        flags ~= config.compilerFlags;
        
        return flags;
    }
    
    /// Build linker flags from config
    protected string[] buildLinkerFlags(in CppConfig config)
    {
        string[] flags;
        
        // Library directories
        foreach (libDir; config.libDirs)
        {
            flags ~= "-L" ~ libDir;
        }
        
        // Libraries
        foreach (lib; config.libs)
        {
            flags ~= "-l" ~ lib;
        }
        
        // System libraries
        foreach (sysLib; config.sysLibs)
        {
            flags ~= "-l" ~ sysLib;
        }
        
        // PIE
        if (config.pie && config.outputType == OutputType.Executable)
        {
            flags ~= "-pie";
        }
        
        // Strip
        if (config.strip)
        {
            flags ~= "-s";
        }
        
        // LTO
        if (config.lto != LtoMode.Off)
        {
            flags ~= getLtoFlag(config.lto);
        }
        
        // Sanitizers (need to be linked too)
        foreach (sanitizer; config.sanitizers)
        {
            flags ~= getSanitizerFlag(sanitizer);
        }
        
        // Custom linker flags
        flags ~= config.linkerFlags;
        
        return flags;
    }
    
    private string getStandardFlag(CppStandard std)
    {
        final switch (std)
        {
            case CppStandard.Cpp98: return "-std=c++98";
            case CppStandard.Cpp03: return "-std=c++03";
            case CppStandard.Cpp11: return "-std=c++11";
            case CppStandard.Cpp14: return "-std=c++14";
            case CppStandard.Cpp17: return "-std=c++17";
            case CppStandard.Cpp20: return "-std=c++20";
            case CppStandard.Cpp23: return "-std=c++23";
            case CppStandard.Cpp26: return "-std=c++26";
            case CppStandard.GnuCpp98: return "-std=gnu++98";
            case CppStandard.GnuCpp03: return "-std=gnu++03";
            case CppStandard.GnuCpp11: return "-std=gnu++11";
            case CppStandard.GnuCpp14: return "-std=gnu++14";
            case CppStandard.GnuCpp17: return "-std=gnu++17";
            case CppStandard.GnuCpp20: return "-std=gnu++20";
            case CppStandard.GnuCpp23: return "-std=gnu++23";
            case CppStandard.GnuCpp26: return "-std=gnu++26";
        }
    }
    
    private string getCStandardFlag(CStandard std)
    {
        final switch (std)
        {
            case CStandard.C89: return "-std=c89";
            case CStandard.C90: return "-std=c90";
            case CStandard.C99: return "-std=c99";
            case CStandard.C11: return "-std=c11";
            case CStandard.C17: return "-std=c17";
            case CStandard.C23: return "-std=c23";
            case CStandard.GnuC89: return "-std=gnu89";
            case CStandard.GnuC90: return "-std=gnu90";
            case CStandard.GnuC99: return "-std=gnu99";
            case CStandard.GnuC11: return "-std=gnu11";
            case CStandard.GnuC17: return "-std=gnu17";
            case CStandard.GnuC23: return "-std=gnu23";
        }
    }
    
    private string getOptimizationFlag(OptLevel opt)
    {
        final switch (opt)
        {
            case OptLevel.O0: return "-O0";
            case OptLevel.O1: return "-O1";
            case OptLevel.O2: return "-O2";
            case OptLevel.O3: return "-O3";
            case OptLevel.Os: return "-Os";
            case OptLevel.Ofast: return "-Ofast";
            case OptLevel.Og: return "-Og";
        }
    }
    
    private string[] getWarningFlags(WarningLevel level)
    {
        final switch (level)
        {
            case WarningLevel.None: return [];
            case WarningLevel.Default: return [];
            case WarningLevel.Extra: return ["-Wall"];
            case WarningLevel.All: return ["-Wall", "-Wextra"];
            case WarningLevel.Pedantic: return ["-Wall", "-Wextra", "-pedantic"];
            case WarningLevel.Error: return ["-Wall", "-Wextra", "-Werror"];
        }
    }
    
    private string getLtoFlag(LtoMode lto)
    {
        final switch (lto)
        {
            case LtoMode.Off: return "";
            case LtoMode.Thin: return "-flto=thin";
            case LtoMode.Full: return "-flto";
        }
    }
    
    private string getSanitizerFlag(Sanitizer san)
    {
        final switch (san)
        {
            case Sanitizer.None: return "";
            case Sanitizer.Address: return "-fsanitize=address";
            case Sanitizer.Thread: return "-fsanitize=thread";
            case Sanitizer.Memory: return "-fsanitize=memory";
            case Sanitizer.UndefinedBehavior: return "-fsanitize=undefined";
            case Sanitizer.Leak: return "-fsanitize=leak";
            case Sanitizer.HWAddress: return "-fsanitize=hwaddress";
        }
    }
}

/// Module-level helper to build compiler flags (for use without class instance)
string[] buildCompilerFlags(in CppConfig config, bool isCpp)
{
    import std.conv : to;
    
    string[] flags;
    
    // Standard
    final switch (isCpp ? config.cppStandard : CppStandard.Cpp14) // Convert to string-based comparison
    {
        case CppStandard.Cpp98: flags ~= "-std=c++98"; break;
        case CppStandard.Cpp11: flags ~= "-std=c++11"; break;
        case CppStandard.Cpp14: flags ~= "-std=c++14"; break;
        case CppStandard.Cpp17: flags ~= "-std=c++17"; break;
        case CppStandard.Cpp20: flags ~= "-std=c++20"; break;
        case CppStandard.Cpp23: flags ~= "-std=c++23"; break;
    }
    
    // Optimization
    final switch (config.optLevel)
    {
        case OptimizationLevel.Debug: flags ~= "-O0"; break;
        case OptimizationLevel.Release: flags ~= "-O2"; break;
        case OptimizationLevel.Speed: flags ~= "-O3"; break;
        case OptimizationLevel.Size: flags ~= "-Os"; break;
        case OptimizationLevel.Custom: break;
    }
    
    // Debug info
    if (config.debugInfo) flags ~= "-g";
    
    // Warnings
    foreach (warn; config.warnings) flags ~= warn;
    
    // Defines
    foreach (def; config.defines) flags ~= "-D" ~ def;
    
    // Includes  
    foreach (inc; config.includeDirs) flags ~= "-I" ~ inc;
    
    return flags;
}

