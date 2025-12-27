module languages.compiled.cpp.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// C++ standard versions
enum CppStandard
{
    Cpp98,
    Cpp03,
    Cpp11,
    Cpp14,
    Cpp17,
    Cpp20,
    Cpp23,
    Cpp26,
    GnuCpp98,
    GnuCpp03,
    GnuCpp11,
    GnuCpp14,
    GnuCpp17,
    GnuCpp20,
    GnuCpp23,
    GnuCpp26
}

/// C standard versions
enum CStandard
{
    C89,
    C90,
    C99,
    C11,
    C17,
    C23,
    GnuC89,
    GnuC90,
    GnuC99,
    GnuC11,
    GnuC17,
    GnuC23
}

/// Compiler selection
enum Compiler
{
    /// Auto-detect (prefer clang > gcc > msvc)
    Auto,
    /// GCC (g++/gcc)
    GCC,
    /// Clang (clang++/clang)
    Clang,
    /// MSVC (cl.exe)
    MSVC,
    /// Intel C++ Compiler
    Intel,
    /// Custom compiler command
    Custom
}

/// Build system integration
enum BuildSystem
{
    /// No build system (direct compilation)
    None,
    /// Auto-detect from project
    Auto,
    /// CMake
    CMake,
    /// GNU Make
    Make,
    /// Ninja
    Ninja,
    /// Bazel
    Bazel,
    /// Meson
    Meson,
    /// Xmake
    Xmake
}

/// Optimization levels
enum OptLevel
{
    /// No optimization (-O0)
    O0,
    /// Basic optimization (-O1)
    O1,
    /// Medium optimization (-O2)
    O2,
    /// Aggressive optimization (-O3)
    O3,
    /// Size optimization (-Os)
    Os,
    /// Fast optimization (-Ofast)
    Ofast,
    /// Debug optimization (-Og)
    Og
}

/// Link-time optimization modes
enum LtoMode
{
    /// No LTO
    Off,
    /// Thin LTO
    Thin,
    /// Full LTO
    Full
}

/// Output types
enum OutputType
{
    /// Executable binary
    Executable,
    /// Static library (.a, .lib)
    StaticLib,
    /// Shared library (.so, .dll, .dylib)
    SharedLib,
    /// Object files only
    Object,
    /// Header-only library
    HeaderOnly
}

/// Sanitizer options
enum Sanitizer
{
    None,
    Address,      // AddressSanitizer
    Thread,       // ThreadSanitizer
    Memory,       // MemorySanitizer
    UndefinedBehavior,  // UBSan
    Leak,         // LeakSanitizer
    HWAddress     // Hardware-assisted AddressSanitizer
}

/// Static analysis tools
enum StaticAnalyzer
{
    None,
    ClangTidy,
    CppCheck,
    PVSStudio,
    Coverity
}

/// Package manager integration
enum PackageManager
{
    None,
    Conan,
    Vcpkg,
    Hunter
}

/// Precompiled header strategy
enum PchStrategy
{
    None,
    Auto,    // Auto-detect common headers
    Manual   // User-specified PCH
}

/// Warning levels
enum WarningLevel
{
    None,     // No warnings
    Default,  // Compiler default
    Extra,    // More warnings (-Wall)
    All,      // All warnings (-Wall -Wextra)
    Pedantic, // Pedantic (-Wall -Wextra -pedantic)
    Error     // Warnings as errors (-Werror)
}

/// Runtime library linkage (MSVC)
enum RuntimeLib
{
    /// Auto-detect
    Auto,
    /// Multi-threaded DLL (/MD)
    MultiThreadedDLL,
    /// Multi-threaded DLL Debug (/MDd)
    MultiThreadedDebugDLL,
    /// Multi-threaded Static (/MT)
    MultiThreadedStatic,
    /// Multi-threaded Static Debug (/MTd)
    MultiThreadedDebugStatic
}

/// Cross-compilation configuration
struct CrossConfig
{
    /// Target triple (e.g., x86_64-linux-gnu)
    string targetTriple;
    
    /// Target architecture
    string arch;
    
    /// Target OS
    string os;
    
    /// Sysroot path
    string sysroot;
    
    /// Toolchain prefix
    string prefix;
    
    /// Is cross-compilation enabled
    bool isCross() const
    {
        return !targetTriple.empty || !arch.empty || !os.empty;
    }
}

/// Dependency configuration
struct DependencyConfig
{
    /// Package manager to use
    PackageManager manager = PackageManager.None;
    
    /// Conan remotes
    string[] conanRemotes;
    
    /// Vcpkg root
    string vcpkgRoot;
    
    /// Install dependencies automatically
    bool autoInstall = false;
    
    /// Build missing dependencies
    bool buildMissing = false;
}

/// PCH configuration
struct PchConfig
{
    /// Strategy for PCH
    PchStrategy strategy = PchStrategy.None;
    
    /// Manual PCH header file
    string header;
    
    /// PCH output file
    string output;
    
    /// Force PCH rebuild
    bool force = false;
}

/// Unity build configuration
struct UnityConfig
{
    /// Enable unity builds
    bool enabled = false;
    
    /// Files per unity file
    size_t filesPerUnit = 50;
    
    /// Unity file prefix
    string prefix = "unity_";
}

/// Code coverage configuration
struct CoverageConfig
{
    /// Enable code coverage
    bool enabled = false;
    
    /// Coverage tool (gcov, llvm-cov)
    string tool = "auto";
    
    /// Output format
    string format = "html";
    
    /// Output directory
    string outputDir = "coverage";
}

/// CPU target mode for architecture-specific optimizations
enum CpuTarget
{
    Generic,        // No arch-specific optimizations (default)
    Native,         // -march=native -mtune=native (best for local builds)
    Baseline,       // Baseline SIMD (SSE2 for x86_64, NEON for ARM64)
    Custom          // Custom -march/-mtune strings
}

/// Profile-Guided Optimization mode
enum PgoMode
{
    Off,            // No PGO
    Generate,       // Generate profile data (-fprofile-generate)
    Use,            // Use profile data (-fprofile-use)
    Sample,         // Sampling-based PGO (AutoFDO)
    Csir            // Context-sensitive IR PGO (LLVM)
}

/// Vectorization level
enum VectorizationLevel
{
    Off,            // Disable vectorization
    Default,        // Compiler default
    Aggressive,     // Aggressive loop vectorization
    FullSlp         // Full SLP + loop vectorization
}

/// Optimization preset - pre-configured optimization bundles
enum OptPreset
{
    None,           // No preset (manual configuration)
    Debug,          // O0, debug info, no optimizations
    Release,        // O2, strip, moderate optimizations
    ReleaseFast,    // O3, aggressive inlining, vectorization
    ReleaseNative,  // O3 + march=native + LTO thin
    ReleaseLto,     // O3 + full LTO + aggressive opts
    ProfileGen,     // O2 + profile generation
    ProfileUse,     // O3 + profile use + LTO
    MinSize         // Os + LTO thin + size opts
}

/// Advanced optimization configuration
/// Fine-grained control over compiler optimizations beyond -O levels
struct AdvancedOptConfig
{
    /// Optimization preset (overrides individual settings if not None)
    OptPreset preset = OptPreset.None;
    
    /// CPU target architecture
    CpuTarget cpuTarget = CpuTarget.Generic;
    
    /// Custom -march value (when cpuTarget == Custom)
    string march;
    
    /// Custom -mtune value (when cpuTarget == Custom)
    string mtune;
    
    /// Profile-guided optimization mode
    PgoMode pgo = PgoMode.Off;
    
    /// PGO profile directory (for generate/use)
    string pgoProfileDir = ".pgo-data";
    
    /// Vectorization level
    VectorizationLevel vectorization = VectorizationLevel.Default;
    
    /// Enable fast-math optimizations (may sacrifice IEEE compliance)
    bool fastMath = false;
    
    /// Enable loop unrolling
    bool unrollLoops = false;
    
    /// Enable aggressive function inlining
    bool aggressiveInline = false;
    
    /// Inline function size threshold (0 = compiler default)
    uint inlineThreshold = 0;
    
    /// Omit frame pointer (better perf, harder debugging)
    bool omitFramePointer = false;
    
    /// LTO partition mode (faster parallel LTO compilation)
    /// Options: "none", "one", "balanced", "max"
    string ltoPartition = "balanced";
    
    /// Enable Polly polyhedral optimizer (Clang only)
    bool polly = false;
    
    /// Enable BOLT post-link optimization (requires separate BOLT pass)
    bool bolt = false;
    
    /// BOLT profile data path
    string boltProfile;
    
    /// Strict aliasing optimization
    bool strictAliasing = true;
    
    /// Thread-local storage model (global-dynamic, local-dynamic, initial-exec, local-exec)
    string tlsModel;
    
    /// Enable sized deallocation (C++14+)
    bool sizedDeallocation = true;
    
    /// Stack protector level (none, basic, strong, all)
    string stackProtector = "strong";
    
    /// Build compiler flags from this config
    string[] toFlags(Compiler compiler) const pure
    {
        string[] flags;
        
        // CPU targeting
        final switch (cpuTarget) with (CpuTarget)
        {
            case Generic: break;
            case Native:
                flags ~= ["-march=native", "-mtune=native"];
                break;
            case Baseline:
                // SSE2 baseline for x86_64
                version (X86_64) flags ~= "-march=x86-64";
                break;
            case Custom:
                if (march.length) flags ~= "-march=" ~ march;
                if (mtune.length) flags ~= "-mtune=" ~ mtune;
                break;
        }
        
        // PGO flags
        final switch (pgo) with (PgoMode)
        {
            case Off: break;
            case Generate:
                flags ~= compiler == Compiler.Clang || compiler == Compiler.Auto
                    ? "-fprofile-generate=" ~ pgoProfileDir
                    : "-fprofile-dir=" ~ pgoProfileDir ~ " -fprofile-generate";
                break;
            case Use:
                flags ~= compiler == Compiler.Clang || compiler == Compiler.Auto
                    ? "-fprofile-use=" ~ pgoProfileDir
                    : "-fprofile-dir=" ~ pgoProfileDir ~ " -fprofile-use -fprofile-correction";
                break;
            case Sample:
                // AutoFDO / sampling PGO (Clang)
                flags ~= "-fprofile-sample-use=" ~ pgoProfileDir ~ "/profile.afdo";
                break;
            case Csir:
                // Context-sensitive IR PGO (LLVM)
                flags ~= ["-fcs-profile-generate=" ~ pgoProfileDir];
                break;
        }
        
        // Vectorization
        final switch (vectorization) with (VectorizationLevel)
        {
            case Off:
                flags ~= ["-fno-vectorize", "-fno-slp-vectorize"];
                break;
            case Default: break;
            case Aggressive:
                flags ~= ["-fvectorize", "-fslp-vectorize", "-fvectorize-interleave=4"];
                break;
            case FullSlp:
                flags ~= ["-fvectorize", "-fslp-vectorize", "-fvectorize-interleave=8",
                          "-mllvm", "-slp-vectorize-hor=true"];
                break;
        }
        
        // Fast math
        if (fastMath) flags ~= "-ffast-math";
        
        // Loop unrolling
        if (unrollLoops) flags ~= "-funroll-loops";
        
        // Aggressive inlining
        if (aggressiveInline)
        {
            flags ~= "-finline-functions";
            if (inlineThreshold > 0)
                flags ~= "-finline-limit=" ~ inlineThreshold.to!string;
        }
        
        // Frame pointer
        if (omitFramePointer) flags ~= "-fomit-frame-pointer";
        
        // LTO partitioning (Clang)
        if (ltoPartition.length && ltoPartition != "none")
            flags ~= "-flto-partition=" ~ ltoPartition;
        
        // Polly
        if (polly) flags ~= ["-mllvm", "-polly"];
        
        // Strict aliasing
        if (!strictAliasing) flags ~= "-fno-strict-aliasing";
        
        // TLS model
        if (tlsModel.length) flags ~= "-ftls-model=" ~ tlsModel;
        
        // Sized deallocation
        if (sizedDeallocation) flags ~= "-fsized-deallocation";
        
        // Stack protector
        if (stackProtector.length)
        {
            if (stackProtector == "none") flags ~= "-fno-stack-protector";
            else if (stackProtector == "basic") flags ~= "-fstack-protector";
            else if (stackProtector == "strong") flags ~= "-fstack-protector-strong";
            else if (stackProtector == "all") flags ~= "-fstack-protector-all";
        }
        
        return flags;
    }
    
    /// Apply preset, returning modified config
    static AdvancedOptConfig fromPreset(OptPreset preset) pure
    {
        AdvancedOptConfig cfg;
        cfg.preset = preset;
        
        final switch (preset) with (OptPreset)
        {
            case None: break;
            case Debug:
                cfg.omitFramePointer = false;
                cfg.strictAliasing = false;
                break;
            case Release:
                cfg.omitFramePointer = true;
                break;
            case ReleaseFast:
                cfg.unrollLoops = true;
                cfg.aggressiveInline = true;
                cfg.omitFramePointer = true;
                cfg.vectorization = VectorizationLevel.Aggressive;
                break;
            case ReleaseNative:
                cfg.cpuTarget = CpuTarget.Native;
                cfg.unrollLoops = true;
                cfg.aggressiveInline = true;
                cfg.omitFramePointer = true;
                cfg.vectorization = VectorizationLevel.Aggressive;
                break;
            case ReleaseLto:
                cfg.cpuTarget = CpuTarget.Native;
                cfg.unrollLoops = true;
                cfg.aggressiveInline = true;
                cfg.omitFramePointer = true;
                cfg.vectorization = VectorizationLevel.FullSlp;
                cfg.polly = true;
                break;
            case ProfileGen:
                cfg.pgo = PgoMode.Generate;
                break;
            case ProfileUse:
                cfg.pgo = PgoMode.Use;
                cfg.cpuTarget = CpuTarget.Native;
                cfg.unrollLoops = true;
                cfg.aggressiveInline = true;
                cfg.vectorization = VectorizationLevel.Aggressive;
                break;
            case MinSize:
                cfg.omitFramePointer = true;
                cfg.sizedDeallocation = true;
                break;
        }
        
        return cfg;
    }
}

/// C/C++ configuration
struct CppConfig
{
    /// Compiler selection
    Compiler compiler = Compiler.Auto;
    
    /// Custom compiler command
    string customCompiler;
    
    /// Build system
    BuildSystem buildSystem = BuildSystem.None;
    
    /// C++ standard
    CppStandard cppStandard = CppStandard.Cpp17;
    
    /// C standard (for .c files)
    CStandard cStandard = CStandard.C11;
    
    /// Output type
    OutputType outputType = OutputType.Executable;
    
    /// Optimization level
    OptLevel optLevel = OptLevel.O2;
    
    /// Link-time optimization
    LtoMode lto = LtoMode.Off;
    
    /// Warning level
    WarningLevel warnings = WarningLevel.Extra;
    
    /// Position independent code
    bool pic = false;
    
    /// Position independent executable
    bool pie = false;
    
    /// Enable debug symbols
    bool debugInfo = false;
    
    /// Strip symbols after build
    bool strip = false;
    
    /// Include directories
    string[] includeDirs;
    
    /// Library directories
    string[] libDirs;
    
    /// Libraries to link
    string[] libs;
    
    /// System libraries
    string[] sysLibs;
    
    /// Definitions (-D flags)
    string[] defines;
    
    /// Compiler flags
    string[] compilerFlags;
    
    /// Linker flags
    string[] linkerFlags;
    
    /// Entry point (for main file)
    string entry;
    
    /// Output name
    string output;
    
    /// Intermediate directory
    string objDir = "obj";
    
    /// Enable exceptions
    bool exceptions = true;
    
    /// Enable RTTI
    bool rtti = true;
    
    /// Sanitizers to enable
    Sanitizer[] sanitizers;
    
    /// Static analyzer
    StaticAnalyzer analyzer = StaticAnalyzer.None;
    
    /// Format code with clang-format
    bool format = false;
    
    /// clang-format style
    string formatStyle = "LLVM";
    
    /// Cross-compilation settings
    CrossConfig cross;
    
    /// Dependency management
    DependencyConfig deps;
    
    /// Precompiled headers
    PchConfig pch;
    
    /// Unity builds
    UnityConfig unity;
    
    /// Code coverage
    CoverageConfig coverage;
    
    /// Advanced optimizations (CPU targeting, PGO, vectorization, etc.)
    AdvancedOptConfig advancedOpt;
    
    /// Runtime library (MSVC)
    RuntimeLib runtimeLib = RuntimeLib.Auto;
    
    /// Parallel compilation jobs
    size_t jobs = 0; // 0 = auto-detect
    
    /// CMake generator
    string cmakeGenerator;
    
    /// CMake build type
    string cmakeBuildType;
    
    /// CMake options
    string[] cmakeOptions;
    
    /// Verbose output
    bool verbose = false;
    
    /// Color diagnostics
    bool colorDiagnostics = true;
    
    /// Time report
    bool timeReport = false;
    
    /// Compilation database
    bool compileCommands = false;
    
    /// Module support (C++20)
    bool modules = false;
    
    /// Coroutines support (C++20)
    bool coroutines = true;
    
    /// Concepts support (C++20)
    bool concepts = true;
    
    /// Parse from JSON
    static CppConfig fromJSON(JSONValue json)
    {
        CppConfig config;
        
        // Compiler
        if ("compiler" in json)
        {
            string compilerStr = json["compiler"].str.toLower;
            switch (compilerStr)
            {
                case "auto": config.compiler = Compiler.Auto; break;
                case "gcc": config.compiler = Compiler.GCC; break;
                case "clang": config.compiler = Compiler.Clang; break;
                case "msvc": config.compiler = Compiler.MSVC; break;
                case "intel": config.compiler = Compiler.Intel; break;
                case "custom": config.compiler = Compiler.Custom; break;
                default: config.compiler = Compiler.Auto; break;
            }
        }
        
        // Build system
        if ("buildSystem" in json || "build_system" in json)
        {
            string key = "buildSystem" in json ? "buildSystem" : "build_system";
            string bsStr = json[key].str.toLower;
            switch (bsStr)
            {
                case "none": config.buildSystem = BuildSystem.None; break;
                case "auto": config.buildSystem = BuildSystem.Auto; break;
                case "cmake": config.buildSystem = BuildSystem.CMake; break;
                case "make": config.buildSystem = BuildSystem.Make; break;
                case "ninja": config.buildSystem = BuildSystem.Ninja; break;
                case "bazel": config.buildSystem = BuildSystem.Bazel; break;
                case "meson": config.buildSystem = BuildSystem.Meson; break;
                case "xmake": config.buildSystem = BuildSystem.Xmake; break;
                default: config.buildSystem = BuildSystem.None; break;
            }
        }
        
        // Standards
        if ("cppStandard" in json || "cpp_standard" in json || "std" in json)
        {
            string key = "cppStandard" in json ? "cppStandard" : ("cpp_standard" in json ? "cpp_standard" : "std");
            string stdStr = json[key].str.toLower.replace("-", "").replace("+", "");
            switch (stdStr)
            {
                case "c98": case "98": config.cppStandard = CppStandard.Cpp98; break;
                case "c03": case "03": config.cppStandard = CppStandard.Cpp03; break;
                case "c11": case "11": config.cppStandard = CppStandard.Cpp11; break;
                case "c14": case "14": config.cppStandard = CppStandard.Cpp14; break;
                case "c17": case "17": config.cppStandard = CppStandard.Cpp17; break;
                case "c20": case "20": config.cppStandard = CppStandard.Cpp20; break;
                case "c23": case "23": config.cppStandard = CppStandard.Cpp23; break;
                case "c26": case "26": config.cppStandard = CppStandard.Cpp26; break;
                case "gnuc11": case "gnu11": config.cppStandard = CppStandard.GnuCpp11; break;
                case "gnuc14": case "gnu14": config.cppStandard = CppStandard.GnuCpp14; break;
                case "gnuc17": case "gnu17": config.cppStandard = CppStandard.GnuCpp17; break;
                case "gnuc20": case "gnu20": config.cppStandard = CppStandard.GnuCpp20; break;
                case "gnuc23": case "gnu23": config.cppStandard = CppStandard.GnuCpp23; break;
                default: config.cppStandard = CppStandard.Cpp17; break;
            }
        }
        
        // Optimization
        if ("optLevel" in json || "opt_level" in json || "optimization" in json)
        {
            string key = "optLevel" in json ? "optLevel" : ("opt_level" in json ? "opt_level" : "optimization");
            string optStr = json[key].str.toLower;
            switch (optStr)
            {
                case "0": case "o0": config.optLevel = OptLevel.O0; break;
                case "1": case "o1": config.optLevel = OptLevel.O1; break;
                case "2": case "o2": config.optLevel = OptLevel.O2; break;
                case "3": case "o3": config.optLevel = OptLevel.O3; break;
                case "s": case "os": config.optLevel = OptLevel.Os; break;
                case "fast": case "ofast": config.optLevel = OptLevel.Ofast; break;
                case "g": case "og": config.optLevel = OptLevel.Og; break;
                default: config.optLevel = OptLevel.O2; break;
            }
        }
        
        // LTO
        if ("lto" in json)
        {
            auto ltoValue = json["lto"];
            if (ltoValue.type == JSONType.true_)
                config.lto = LtoMode.Full;
            else if (ltoValue.type == JSONType.string)
            {
                string ltoStr = ltoValue.str.toLower;
                switch (ltoStr)
                {
                    case "off": case "false": case "no": config.lto = LtoMode.Off; break;
                    case "thin": config.lto = LtoMode.Thin; break;
                    case "full": case "fat": case "true": case "yes": config.lto = LtoMode.Full; break;
                    default: config.lto = LtoMode.Off; break;
                }
            }
        }
        
        // Warning level
        if ("warnings" in json || "warning_level" in json)
        {
            string key = "warnings" in json ? "warnings" : "warning_level";
            string warnStr = json[key].str.toLower;
            switch (warnStr)
            {
                case "none": config.warnings = WarningLevel.None; break;
                case "default": config.warnings = WarningLevel.Default; break;
                case "extra": config.warnings = WarningLevel.Extra; break;
                case "all": config.warnings = WarningLevel.All; break;
                case "pedantic": config.warnings = WarningLevel.Pedantic; break;
                case "error": config.warnings = WarningLevel.Error; break;
                default: config.warnings = WarningLevel.Extra; break;
            }
        }
        
        // String fields
        if ("customCompiler" in json || "custom_compiler" in json)
        {
            string key = "customCompiler" in json ? "customCompiler" : "custom_compiler";
            config.customCompiler = json[key].str;
        }
        if ("entry" in json) config.entry = json["entry"].str;
        if ("output" in json) config.output = json["output"].str;
        if ("objDir" in json || "obj_dir" in json)
        {
            string key = "objDir" in json ? "objDir" : "obj_dir";
            config.objDir = json[key].str;
        }
        if ("formatStyle" in json || "format_style" in json)
        {
            string key = "formatStyle" in json ? "formatStyle" : "format_style";
            config.formatStyle = json[key].str;
        }
        if ("cmakeGenerator" in json || "cmake_generator" in json)
        {
            string key = "cmakeGenerator" in json ? "cmakeGenerator" : "cmake_generator";
            config.cmakeGenerator = json[key].str;
        }
        if ("cmakeBuildType" in json || "cmake_build_type" in json)
        {
            string key = "cmakeBuildType" in json ? "cmakeBuildType" : "cmake_build_type";
            config.cmakeBuildType = json[key].str;
        }
        
        // Numeric fields
        if ("jobs" in json) config.jobs = json["jobs"].integer.to!size_t;
        
        // Boolean fields
        if ("pic" in json) config.pic = json["pic"].type == JSONType.true_;
        if ("pie" in json) config.pie = json["pie"].type == JSONType.true_;
        if ("debugInfo" in json || "debug_info" in json || "debug" in json)
        {
            string key = "debugInfo" in json ? "debugInfo" : ("debug_info" in json ? "debug_info" : "debug");
            config.debugInfo = json[key].type == JSONType.true_;
        }
        if ("strip" in json) config.strip = json["strip"].type == JSONType.true_;
        if ("exceptions" in json) config.exceptions = json["exceptions"].type == JSONType.true_;
        if ("rtti" in json) config.rtti = json["rtti"].type == JSONType.true_;
        if ("format" in json) config.format = json["format"].type == JSONType.true_;
        if ("verbose" in json) config.verbose = json["verbose"].type == JSONType.true_;
        if ("colorDiagnostics" in json || "color_diagnostics" in json || "color" in json)
        {
            string key = "colorDiagnostics" in json ? "colorDiagnostics" : 
                        ("color_diagnostics" in json ? "color_diagnostics" : "color");
            config.colorDiagnostics = json[key].type == JSONType.true_;
        }
        if ("timeReport" in json || "time_report" in json)
        {
            string key = "timeReport" in json ? "timeReport" : "time_report";
            config.timeReport = json[key].type == JSONType.true_;
        }
        if ("compileCommands" in json || "compile_commands" in json)
        {
            string key = "compileCommands" in json ? "compileCommands" : "compile_commands";
            config.compileCommands = json[key].type == JSONType.true_;
        }
        if ("modules" in json) config.modules = json["modules"].type == JSONType.true_;
        if ("coroutines" in json) config.coroutines = json["coroutines"].type == JSONType.true_;
        if ("concepts" in json) config.concepts = json["concepts"].type == JSONType.true_;
        
        // Array fields
        if ("includeDirs" in json || "include_dirs" in json || "includes" in json)
        {
            string key = "includeDirs" in json ? "includeDirs" : 
                        ("include_dirs" in json ? "include_dirs" : "includes");
            config.includeDirs = json[key].array.map!(e => e.str).array;
        }
        if ("libDirs" in json || "lib_dirs" in json || "library_dirs" in json)
        {
            string key = "libDirs" in json ? "libDirs" : 
                        ("lib_dirs" in json ? "lib_dirs" : "library_dirs");
            config.libDirs = json[key].array.map!(e => e.str).array;
        }
        if ("libs" in json || "libraries" in json)
        {
            string key = "libs" in json ? "libs" : "libraries";
            config.libs = json[key].array.map!(e => e.str).array;
        }
        if ("sysLibs" in json || "sys_libs" in json || "system_libraries" in json)
        {
            string key = "sysLibs" in json ? "sysLibs" : 
                        ("sys_libs" in json ? "sys_libs" : "system_libraries");
            config.sysLibs = json[key].array.map!(e => e.str).array;
        }
        if ("defines" in json || "definitions" in json)
        {
            string key = "defines" in json ? "defines" : "definitions";
            config.defines = json[key].array.map!(e => e.str).array;
        }
        if ("compilerFlags" in json || "compiler_flags" in json || "cflags" in json)
        {
            string key = "compilerFlags" in json ? "compilerFlags" : 
                        ("compiler_flags" in json ? "compiler_flags" : "cflags");
            config.compilerFlags = json[key].array.map!(e => e.str).array;
        }
        if ("linkerFlags" in json || "linker_flags" in json || "ldflags" in json)
        {
            string key = "linkerFlags" in json ? "linkerFlags" : 
                        ("linker_flags" in json ? "linker_flags" : "ldflags");
            config.linkerFlags = json[key].array.map!(e => e.str).array;
        }
        if ("cmakeOptions" in json || "cmake_options" in json)
        {
            string key = "cmakeOptions" in json ? "cmakeOptions" : "cmake_options";
            config.cmakeOptions = json[key].array.map!(e => e.str).array;
        }
        
        // Sanitizers
        if ("sanitizers" in json)
        {
            foreach (san; json["sanitizers"].array)
            {
                string sanStr = san.str.toLower;
                switch (sanStr)
                {
                    case "address": config.sanitizers ~= Sanitizer.Address; break;
                    case "thread": config.sanitizers ~= Sanitizer.Thread; break;
                    case "memory": config.sanitizers ~= Sanitizer.Memory; break;
                    case "ub": case "undefined": config.sanitizers ~= Sanitizer.UndefinedBehavior; break;
                    case "leak": config.sanitizers ~= Sanitizer.Leak; break;
                    case "hwaddress": config.sanitizers ~= Sanitizer.HWAddress; break;
                    default: break;
                }
            }
        }
        
        // Static analyzer
        if ("analyzer" in json || "static_analyzer" in json)
        {
            string key = "analyzer" in json ? "analyzer" : "static_analyzer";
            string anaStr = json[key].str.toLower;
            switch (anaStr)
            {
                case "none": config.analyzer = StaticAnalyzer.None; break;
                case "clang-tidy": case "clangtidy": config.analyzer = StaticAnalyzer.ClangTidy; break;
                case "cppcheck": config.analyzer = StaticAnalyzer.CppCheck; break;
                case "pvs-studio": case "pvsstudio": config.analyzer = StaticAnalyzer.PVSStudio; break;
                case "coverity": config.analyzer = StaticAnalyzer.Coverity; break;
                default: config.analyzer = StaticAnalyzer.None; break;
            }
        }
        
        // Cross-compilation
        if ("cross" in json)
        {
            auto crossObj = json["cross"].object;
            if ("targetTriple" in crossObj || "target_triple" in crossObj || "target" in crossObj)
            {
                string key = "targetTriple" in crossObj ? "targetTriple" : 
                            ("target_triple" in crossObj ? "target_triple" : "target");
                config.cross.targetTriple = crossObj[key].str;
            }
            if ("arch" in crossObj) config.cross.arch = crossObj["arch"].str;
            if ("os" in crossObj) config.cross.os = crossObj["os"].str;
            if ("sysroot" in crossObj) config.cross.sysroot = crossObj["sysroot"].str;
            if ("prefix" in crossObj) config.cross.prefix = crossObj["prefix"].str;
        }
        
        // Precompiled headers
        if ("pch" in json)
        {
            auto pchObj = json["pch"].object;
            if ("strategy" in pchObj)
            {
                string stratStr = pchObj["strategy"].str.toLower;
                switch (stratStr)
                {
                    case "none": config.pch.strategy = PchStrategy.None; break;
                    case "auto": config.pch.strategy = PchStrategy.Auto; break;
                    case "manual": config.pch.strategy = PchStrategy.Manual; break;
                    default: config.pch.strategy = PchStrategy.None; break;
                }
            }
            if ("header" in pchObj) config.pch.header = pchObj["header"].str;
            if ("output" in pchObj) config.pch.output = pchObj["output"].str;
            if ("force" in pchObj) config.pch.force = pchObj["force"].type == JSONType.true_;
        }
        
        // Unity builds
        if ("unity" in json)
        {
            auto unityObj = json["unity"].object;
            if ("enabled" in unityObj) config.unity.enabled = unityObj["enabled"].type == JSONType.true_;
            if ("filesPerUnit" in unityObj || "files_per_unit" in unityObj)
            {
                string key = "filesPerUnit" in unityObj ? "filesPerUnit" : "files_per_unit";
                config.unity.filesPerUnit = unityObj[key].integer.to!size_t;
            }
            if ("prefix" in unityObj) config.unity.prefix = unityObj["prefix"].str;
        }
        
        // Advanced optimizations
        if ("advancedOpt" in json || "advanced_opt" in json || "optimization" in json)
        {
            string key = "advancedOpt" in json ? "advancedOpt" : 
                        ("advanced_opt" in json ? "advanced_opt" : "optimization");
            auto optObj = json[key].object;
            
            // Preset (shortcut for common configurations)
            if ("preset" in optObj)
            {
                string presetStr = optObj["preset"].str.toLower.replace("-", "").replace("_", "");
                switch (presetStr)
                {
                    case "debug": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.Debug); break;
                    case "release": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.Release); break;
                    case "releasefast": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.ReleaseFast); break;
                    case "releasenative": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.ReleaseNative); break;
                    case "releaselto": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.ReleaseLto); break;
                    case "profilegen": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.ProfileGen); break;
                    case "profileuse": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.ProfileUse); break;
                    case "minsize": config.advancedOpt = AdvancedOptConfig.fromPreset(OptPreset.MinSize); break;
                    default: break;
                }
            }
            
            // CPU targeting
            if ("cpuTarget" in optObj || "cpu_target" in optObj || "cpu" in optObj)
            {
                string cpuKey = "cpuTarget" in optObj ? "cpuTarget" : 
                               ("cpu_target" in optObj ? "cpu_target" : "cpu");
                string cpuStr = optObj[cpuKey].str.toLower;
                switch (cpuStr)
                {
                    case "generic": config.advancedOpt.cpuTarget = CpuTarget.Generic; break;
                    case "native": config.advancedOpt.cpuTarget = CpuTarget.Native; break;
                    case "baseline": config.advancedOpt.cpuTarget = CpuTarget.Baseline; break;
                    case "custom": config.advancedOpt.cpuTarget = CpuTarget.Custom; break;
                    default: break;
                }
            }
            if ("march" in optObj) config.advancedOpt.march = optObj["march"].str;
            if ("mtune" in optObj) config.advancedOpt.mtune = optObj["mtune"].str;
            
            // PGO
            if ("pgo" in optObj)
            {
                string pgoStr = optObj["pgo"].str.toLower;
                switch (pgoStr)
                {
                    case "off": config.advancedOpt.pgo = PgoMode.Off; break;
                    case "generate": case "gen": config.advancedOpt.pgo = PgoMode.Generate; break;
                    case "use": config.advancedOpt.pgo = PgoMode.Use; break;
                    case "sample": case "autofdo": config.advancedOpt.pgo = PgoMode.Sample; break;
                    case "csir": config.advancedOpt.pgo = PgoMode.Csir; break;
                    default: break;
                }
            }
            if ("pgoProfileDir" in optObj || "pgo_profile_dir" in optObj)
            {
                string pgoKey = "pgoProfileDir" in optObj ? "pgoProfileDir" : "pgo_profile_dir";
                config.advancedOpt.pgoProfileDir = optObj[pgoKey].str;
            }
            
            // Vectorization
            if ("vectorization" in optObj || "vectorize" in optObj)
            {
                string vecKey = "vectorization" in optObj ? "vectorization" : "vectorize";
                string vecStr = optObj[vecKey].str.toLower;
                switch (vecStr)
                {
                    case "off": config.advancedOpt.vectorization = VectorizationLevel.Off; break;
                    case "default": config.advancedOpt.vectorization = VectorizationLevel.Default; break;
                    case "aggressive": config.advancedOpt.vectorization = VectorizationLevel.Aggressive; break;
                    case "fullslp": case "full": config.advancedOpt.vectorization = VectorizationLevel.FullSlp; break;
                    default: break;
                }
            }
            
            // Boolean flags
            if ("fastMath" in optObj || "fast_math" in optObj)
            {
                string fmKey = "fastMath" in optObj ? "fastMath" : "fast_math";
                config.advancedOpt.fastMath = optObj[fmKey].type == JSONType.true_;
            }
            if ("unrollLoops" in optObj || "unroll_loops" in optObj)
            {
                string ulKey = "unrollLoops" in optObj ? "unrollLoops" : "unroll_loops";
                config.advancedOpt.unrollLoops = optObj[ulKey].type == JSONType.true_;
            }
            if ("aggressiveInline" in optObj || "aggressive_inline" in optObj)
            {
                string aiKey = "aggressiveInline" in optObj ? "aggressiveInline" : "aggressive_inline";
                config.advancedOpt.aggressiveInline = optObj[aiKey].type == JSONType.true_;
            }
            if ("inlineThreshold" in optObj || "inline_threshold" in optObj)
            {
                string itKey = "inlineThreshold" in optObj ? "inlineThreshold" : "inline_threshold";
                config.advancedOpt.inlineThreshold = optObj[itKey].integer.to!uint;
            }
            if ("omitFramePointer" in optObj || "omit_frame_pointer" in optObj)
            {
                string ofpKey = "omitFramePointer" in optObj ? "omitFramePointer" : "omit_frame_pointer";
                config.advancedOpt.omitFramePointer = optObj[ofpKey].type == JSONType.true_;
            }
            if ("polly" in optObj)
                config.advancedOpt.polly = optObj["polly"].type == JSONType.true_;
            if ("bolt" in optObj)
                config.advancedOpt.bolt = optObj["bolt"].type == JSONType.true_;
            if ("boltProfile" in optObj || "bolt_profile" in optObj)
            {
                string bpKey = "boltProfile" in optObj ? "boltProfile" : "bolt_profile";
                config.advancedOpt.boltProfile = optObj[bpKey].str;
            }
            if ("strictAliasing" in optObj || "strict_aliasing" in optObj)
            {
                string saKey = "strictAliasing" in optObj ? "strictAliasing" : "strict_aliasing";
                config.advancedOpt.strictAliasing = optObj[saKey].type == JSONType.true_;
            }
            if ("ltoPartition" in optObj || "lto_partition" in optObj)
            {
                string lpKey = "ltoPartition" in optObj ? "ltoPartition" : "lto_partition";
                config.advancedOpt.ltoPartition = optObj[lpKey].str;
            }
            if ("tlsModel" in optObj || "tls_model" in optObj)
            {
                string tlsKey = "tlsModel" in optObj ? "tlsModel" : "tls_model";
                config.advancedOpt.tlsModel = optObj[tlsKey].str;
            }
            if ("stackProtector" in optObj || "stack_protector" in optObj)
            {
                string spKey = "stackProtector" in optObj ? "stackProtector" : "stack_protector";
                config.advancedOpt.stackProtector = optObj[spKey].str;
            }
        }
        
        return config;
    }
}

/// C/C++ compilation result
struct CppCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string[] objects;      // Intermediate object files
    string[] artifacts;    // Additional artifacts (PCH, etc.)
    string outputHash;
    bool hadWarnings;
    string[] warnings;
    bool hadAnalyzerIssues;
    string[] analyzerIssues;
    string compileCommands; // Path to compile_commands.json
}

