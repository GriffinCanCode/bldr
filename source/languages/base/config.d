module languages.base.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import languages.base.types;

/// Universal configuration fields present in ALL language configs
struct BaseConfig
{
    // Build metadata
    string entry;              // Entry point file
    string outputDir;          // Output directory
    string objDir = "obj";     // Intermediate files directory
    
    // Common flags
    string[] extraFlags;       // Language-specific extra flags
    string[] includeDirs;      // Include/import paths
    string[] defines;          // Preprocessor/compile-time definitions
    
    // Universal toggles
    Verbosity verbosity = Verbosity.Normal;
    bool debugInfo = false;
    size_t jobs = 0;           // Parallel jobs (0 = auto-detect)
    
    // Cross-compilation
    CrossCompileConfig cross;
    
    // Build behavior
    bool dryRun = false;       // Show what would be built
    bool force = false;        // Force rebuild everything
    bool incremental = true;   // Enable incremental builds
    
    // Error handling
    bool failFast = true;      // Stop on first error
    string[] warningFilters;   // Warnings to suppress
    bool warningsAsErrors = false;
}

/// Parse base configuration fields from JSON
/// Returns fields that were parsed (for logging)
string[] parseBaseConfig(ref BaseConfig config, JSONValue json)
{
    string[] parsed;
    
    // Entry point
    if (auto v = "entry" in json) { config.entry = (*v).str; parsed ~= "entry"; }
    
    // Output directories
    if (auto v = "outputDir" in json) { config.outputDir = (*v).str; parsed ~= "outputDir"; }
    else if (auto v = "output_dir" in json) { config.outputDir = (*v).str; parsed ~= "outputDir"; }
    
    if (auto v = "objDir" in json) { config.objDir = (*v).str; parsed ~= "objDir"; }
    else if (auto v = "obj_dir" in json) { config.objDir = (*v).str; parsed ~= "objDir"; }
    
    // Flags and includes
    if (auto v = "extraFlags" in json) { config.extraFlags = (*v).array.map!(e => e.str).array; parsed ~= "extraFlags"; }
    else if (auto v = "extra_flags" in json) { config.extraFlags = (*v).array.map!(e => e.str).array; parsed ~= "extraFlags"; }
    else if (auto v = "flags" in json) { config.extraFlags = (*v).array.map!(e => e.str).array; parsed ~= "extraFlags"; }
    
    if (auto v = "includeDirs" in json) { config.includeDirs = (*v).array.map!(e => e.str).array; parsed ~= "includeDirs"; }
    else if (auto v = "include_dirs" in json) { config.includeDirs = (*v).array.map!(e => e.str).array; parsed ~= "includeDirs"; }
    else if (auto v = "includes" in json) { config.includeDirs = (*v).array.map!(e => e.str).array; parsed ~= "includeDirs"; }
    
    if (auto v = "defines" in json) { config.defines = (*v).array.map!(e => e.str).array; parsed ~= "defines"; }
    else if (auto v = "definitions" in json) { config.defines = (*v).array.map!(e => e.str).array; parsed ~= "defines"; }
    
    // Verbosity
    if (auto v = "verbosity" in json)
    {
        string vs = (*v).str.toLower;
        config.verbosity = vs == "quiet" ? Verbosity.Quiet :
                          vs == "verbose" ? Verbosity.Verbose :
                          vs == "debug" ? Verbosity.Debug : Verbosity.Normal;
        parsed ~= "verbosity";
    }
    else if (auto v = "verbose" in json)
    {
        if ((*v).type == JSONType.true_) config.verbosity = Verbosity.Verbose;
        parsed ~= "verbose";
    }
    
    // Debug info
    if (auto v = "debugInfo" in json) { config.debugInfo = (*v).type == JSONType.true_; parsed ~= "debugInfo"; }
    else if (auto v = "debug_info" in json) { config.debugInfo = (*v).type == JSONType.true_; parsed ~= "debugInfo"; }
    else if (auto v = "debug" in json) { config.debugInfo = (*v).type == JSONType.true_; parsed ~= "debugInfo"; }
    
    // Jobs
    if (auto v = "jobs" in json) { config.jobs = (*v).integer.to!size_t; parsed ~= "jobs"; }
    
    // Cross-compilation
    if (auto v = "cross" in json)
    {
        auto obj = (*v).object;
        if (auto t = "targetTriple" in obj) config.cross.targetTriple = (*t).str;
        else if (auto t = "target_triple" in obj) config.cross.targetTriple = (*t).str;
        else if (auto t = "target" in obj) config.cross.targetTriple = (*t).str;
        if (auto a = "arch" in obj) config.cross.arch = (*a).str;
        if (auto o = "os" in obj) config.cross.os = (*o).str;
        if (auto s = "sysroot" in obj) config.cross.sysroot = (*s).str;
        if (auto p = "prefix" in obj) config.cross.prefix = (*p).str;
        parsed ~= "cross";
    }
    
    // Build behavior
    if (auto v = "dryRun" in json) { config.dryRun = (*v).type == JSONType.true_; parsed ~= "dryRun"; }
    else if (auto v = "dry_run" in json) { config.dryRun = (*v).type == JSONType.true_; parsed ~= "dryRun"; }
    
    if (auto v = "force" in json) { config.force = (*v).type == JSONType.true_; parsed ~= "force"; }
    
    if (auto v = "incremental" in json) { config.incremental = (*v).type == JSONType.true_; parsed ~= "incremental"; }
    
    // Error handling
    if (auto v = "failFast" in json) { config.failFast = (*v).type == JSONType.true_; parsed ~= "failFast"; }
    else if (auto v = "fail_fast" in json) { config.failFast = (*v).type == JSONType.true_; parsed ~= "failFast"; }
    
    if (auto v = "warningFilters" in json) { config.warningFilters = (*v).array.map!(e => e.str).array; parsed ~= "warningFilters"; }
    else if (auto v = "warning_filters" in json) { config.warningFilters = (*v).array.map!(e => e.str).array; parsed ~= "warningFilters"; }
    
    if (auto v = "warningsAsErrors" in json) { config.warningsAsErrors = (*v).type == JSONType.true_; parsed ~= "warningsAsErrors"; }
    else if (auto v = "warnings_as_errors" in json) { config.warningsAsErrors = (*v).type == JSONType.true_; parsed ~= "warningsAsErrors"; }
    
    return parsed;
}

/// Configuration for compiled languages (C++, Rust, D, Swift, Zig, etc.)
struct CompiledConfig
{
    BaseConfig base;
    
    // Optimization
    OptLevel optLevel = OptLevel.O2;
    LtoMode lto = LtoMode.Off;
    
    // Code generation
    bool pic = false;          // Position independent code
    bool pie = false;          // Position independent executable
    bool strip = false;        // Strip symbols
    
    // Warnings
    WarningLevel warnings = WarningLevel.Extra;
    
    // Linking
    string[] libDirs;
    string[] libs;
    string[] sysLibs;
    string[] linkerFlags;
    
    // Sanitizers
    Sanitizer[] sanitizers;
    
    // Output
    OutputType outputType = OutputType.Executable;
    string output;             // Override output name
    
    // Compilation database
    bool compileCommands = false;
}

/// Parse compiled language config fields from JSON
string[] parseCompiledConfig(ref CompiledConfig config, JSONValue json)
{
    string[] parsed = parseBaseConfig(config.base, json);
    
    // Optimization level
    if (auto v = "optLevel" in json) { config.optLevel = parseOptLevel((*v).str); parsed ~= "optLevel"; }
    else if (auto v = "opt_level" in json) { config.optLevel = parseOptLevel((*v).str); parsed ~= "optLevel"; }
    else if (auto v = "optimization" in json) { config.optLevel = parseOptLevel((*v).str); parsed ~= "optLevel"; }
    
    // LTO
    if (auto v = "lto" in json)
    {
        if ((*v).type == JSONType.true_) config.lto = LtoMode.Full;
        else if ((*v).type == JSONType.string) config.lto = parseLtoMode((*v).str);
        parsed ~= "lto";
    }
    
    // Code generation flags
    if (auto v = "pic" in json) { config.pic = (*v).type == JSONType.true_; parsed ~= "pic"; }
    if (auto v = "pie" in json) { config.pie = (*v).type == JSONType.true_; parsed ~= "pie"; }
    if (auto v = "strip" in json) { config.strip = (*v).type == JSONType.true_; parsed ~= "strip"; }
    
    // Warnings
    if (auto v = "warnings" in json) { config.warnings = parseWarningLevel((*v).str); parsed ~= "warnings"; }
    else if (auto v = "warning_level" in json) { config.warnings = parseWarningLevel((*v).str); parsed ~= "warnings"; }
    
    // Linking
    if (auto v = "libDirs" in json) { config.libDirs = (*v).array.map!(e => e.str).array; parsed ~= "libDirs"; }
    else if (auto v = "lib_dirs" in json) { config.libDirs = (*v).array.map!(e => e.str).array; parsed ~= "libDirs"; }
    
    if (auto v = "libs" in json) { config.libs = (*v).array.map!(e => e.str).array; parsed ~= "libs"; }
    else if (auto v = "libraries" in json) { config.libs = (*v).array.map!(e => e.str).array; parsed ~= "libs"; }
    
    if (auto v = "sysLibs" in json) { config.sysLibs = (*v).array.map!(e => e.str).array; parsed ~= "sysLibs"; }
    else if (auto v = "sys_libs" in json) { config.sysLibs = (*v).array.map!(e => e.str).array; parsed ~= "sysLibs"; }
    
    if (auto v = "linkerFlags" in json) { config.linkerFlags = (*v).array.map!(e => e.str).array; parsed ~= "linkerFlags"; }
    else if (auto v = "linker_flags" in json) { config.linkerFlags = (*v).array.map!(e => e.str).array; parsed ~= "linkerFlags"; }
    else if (auto v = "ldflags" in json) { config.linkerFlags = (*v).array.map!(e => e.str).array; parsed ~= "linkerFlags"; }
    
    // Sanitizers
    if (auto v = "sanitizers" in json)
    {
        foreach (san; (*v).array)
        {
            string s = san.str.toLower;
            if (s == "address") config.sanitizers ~= Sanitizer.Address;
            else if (s == "thread") config.sanitizers ~= Sanitizer.Thread;
            else if (s == "memory") config.sanitizers ~= Sanitizer.Memory;
            else if (s == "ub" || s == "undefined") config.sanitizers ~= Sanitizer.UndefinedBehavior;
            else if (s == "leak") config.sanitizers ~= Sanitizer.Leak;
            else if (s == "hwaddress") config.sanitizers ~= Sanitizer.HWAddress;
        }
        parsed ~= "sanitizers";
    }
    
    // Output type
    if (auto v = "outputType" in json) { config.outputType = parseOutputType((*v).str); parsed ~= "outputType"; }
    else if (auto v = "output_type" in json) { config.outputType = parseOutputType((*v).str); parsed ~= "outputType"; }
    
    if (auto v = "output" in json) { config.output = (*v).str; parsed ~= "output"; }
    
    if (auto v = "compileCommands" in json) { config.compileCommands = (*v).type == JSONType.true_; parsed ~= "compileCommands"; }
    else if (auto v = "compile_commands" in json) { config.compileCommands = (*v).type == JSONType.true_; parsed ~= "compileCommands"; }
    
    return parsed;
}

/// GPU-specific configuration (CUDA, Metal, ROCm)
struct GPUConfig
{
    CompiledConfig compiled;
    
    // Architecture targeting
    string[] architectures;    // sm_70, gfx908, metal3, etc.
    bool genCode = false;      // Generate final code vs IR
    
    // GPU optimizations
    bool fastMath = false;
    int maxRegisters = 0;      // 0 = unlimited
    bool relocatable = false;  // Relocatable device code
    bool lineInfo = false;     // Line info for profiling
    
    // Host compiler integration
    string hostCompiler;
    string[] hostFlags;
    string cxxStd;             // C++ standard for host code
    
    // Dependencies
    bool genDeps = true;       // Generate dependency files
    
    // Toolkit paths
    string toolkitPath;        // CUDA_HOME, ROCM_PATH, etc.
}

/// Parse GPU config fields
string[] parseGPUConfig(ref GPUConfig config, JSONValue json)
{
    string[] parsed = parseCompiledConfig(config.compiled, json);
    
    // Architectures
    if (auto v = "architectures" in json) { config.architectures = (*v).array.map!(e => e.str).array; parsed ~= "architectures"; }
    else if (auto v = "arch" in json)
    {
        if ((*v).type == JSONType.array) config.architectures = (*v).array.map!(e => e.str).array;
        else config.architectures = [(*v).str];
        parsed ~= "arch";
    }
    else if (auto v = "gpu_arch" in json) { config.architectures = (*v).array.map!(e => e.str).array; parsed ~= "architectures"; }
    
    // GPU flags
    if (auto v = "genCode" in json) { config.genCode = (*v).type == JSONType.true_; parsed ~= "genCode"; }
    else if (auto v = "gen_code" in json) { config.genCode = (*v).type == JSONType.true_; parsed ~= "genCode"; }
    
    if (auto v = "fastMath" in json) { config.fastMath = (*v).type == JSONType.true_; parsed ~= "fastMath"; }
    else if (auto v = "fast_math" in json) { config.fastMath = (*v).type == JSONType.true_; parsed ~= "fastMath"; }
    
    if (auto v = "maxRegisters" in json) { config.maxRegisters = (*v).integer.to!int; parsed ~= "maxRegisters"; }
    else if (auto v = "max_registers" in json) { config.maxRegisters = (*v).integer.to!int; parsed ~= "maxRegisters"; }
    else if (auto v = "maxrregcount" in json) { config.maxRegisters = (*v).integer.to!int; parsed ~= "maxRegisters"; }
    
    if (auto v = "relocatable" in json) { config.relocatable = (*v).type == JSONType.true_; parsed ~= "relocatable"; }
    else if (auto v = "rdc" in json) { config.relocatable = (*v).type == JSONType.true_; parsed ~= "relocatable"; }
    
    if (auto v = "lineInfo" in json) { config.lineInfo = (*v).type == JSONType.true_; parsed ~= "lineInfo"; }
    else if (auto v = "line_info" in json) { config.lineInfo = (*v).type == JSONType.true_; parsed ~= "lineInfo"; }
    
    // Host compiler
    if (auto v = "hostCompiler" in json) { config.hostCompiler = (*v).str; parsed ~= "hostCompiler"; }
    else if (auto v = "host_compiler" in json) { config.hostCompiler = (*v).str; parsed ~= "hostCompiler"; }
    else if (auto v = "ccbin" in json) { config.hostCompiler = (*v).str; parsed ~= "hostCompiler"; }
    
    if (auto v = "hostFlags" in json) { config.hostFlags = (*v).array.map!(e => e.str).array; parsed ~= "hostFlags"; }
    else if (auto v = "host_flags" in json) { config.hostFlags = (*v).array.map!(e => e.str).array; parsed ~= "hostFlags"; }
    
    if (auto v = "cxxStd" in json) { config.cxxStd = (*v).str; parsed ~= "cxxStd"; }
    else if (auto v = "cxx_std" in json) { config.cxxStd = (*v).str; parsed ~= "cxxStd"; }
    else if (auto v = "std" in json) { config.cxxStd = (*v).str; parsed ~= "cxxStd"; }
    
    // Dependencies
    if (auto v = "genDeps" in json) { config.genDeps = (*v).type == JSONType.true_; parsed ~= "genDeps"; }
    else if (auto v = "gen_deps" in json) { config.genDeps = (*v).type == JSONType.true_; parsed ~= "genDeps"; }
    
    // Toolkit path
    if (auto v = "toolkitPath" in json) { config.toolkitPath = (*v).str; parsed ~= "toolkitPath"; }
    else if (auto v = "toolkit_path" in json) { config.toolkitPath = (*v).str; parsed ~= "toolkitPath"; }
    else if (auto v = "cudaPath" in json) { config.toolkitPath = (*v).str; parsed ~= "toolkitPath"; }
    else if (auto v = "rocmPath" in json) { config.toolkitPath = (*v).str; parsed ~= "toolkitPath"; }
    
    return parsed;
}

// Helper functions for parsing enums

private OptLevel parseOptLevel(string s)
{
    switch (s.toLower)
    {
        case "0": case "o0": return OptLevel.O0;
        case "1": case "o1": return OptLevel.O1;
        case "2": case "o2": return OptLevel.O2;
        case "3": case "o3": return OptLevel.O3;
        case "s": case "os": return OptLevel.Os;
        case "z": case "oz": return OptLevel.Oz;
        case "fast": case "ofast": return OptLevel.Ofast;
        case "g": case "og": return OptLevel.Og;
        default: return OptLevel.O2;
    }
}

private LtoMode parseLtoMode(string s)
{
    switch (s.toLower)
    {
        case "off": case "false": case "no": return LtoMode.Off;
        case "thin": return LtoMode.Thin;
        case "full": case "fat": case "true": case "yes": return LtoMode.Full;
        default: return LtoMode.Off;
    }
}

private WarningLevel parseWarningLevel(string s)
{
    switch (s.toLower)
    {
        case "none": return WarningLevel.None;
        case "default": return WarningLevel.Default;
        case "extra": return WarningLevel.Extra;
        case "all": return WarningLevel.All;
        case "pedantic": return WarningLevel.Pedantic;
        case "error": return WarningLevel.Error;
        default: return WarningLevel.Extra;
    }
}

private OutputType parseOutputType(string s)
{
    switch (s.toLower)
    {
        case "executable": case "exe": case "bin": return OutputType.Executable;
        case "static": case "staticlib": case "static_lib": return OutputType.StaticLib;
        case "shared": case "sharedlib": case "shared_lib": case "dll": case "dylib": case "so": return OutputType.SharedLib;
        case "object": case "obj": return OutputType.Object;
        case "header": case "headeronly": case "header_only": return OutputType.HeaderOnly;
        default: return OutputType.Executable;
    }
}

/// Convert optimization level to compiler flag
string toFlag(OptLevel opt) pure nothrow
{
    final switch (opt)
    {
        case OptLevel.O0: return "-O0";
        case OptLevel.O1: return "-O1";
        case OptLevel.O2: return "-O2";
        case OptLevel.O3: return "-O3";
        case OptLevel.Os: return "-Os";
        case OptLevel.Oz: return "-Oz";
        case OptLevel.Ofast: return "-Ofast";
        case OptLevel.Og: return "-Og";
    }
}

/// Convert LTO mode to compiler flag
string toFlag(LtoMode lto) pure nothrow
{
    final switch (lto)
    {
        case LtoMode.Off: return "";
        case LtoMode.Thin: return "-flto=thin";
        case LtoMode.Full: return "-flto";
    }
}

/// Convert warning level to compiler flags
string[] toFlags(WarningLevel level) pure nothrow
{
    final switch (level)
    {
        case WarningLevel.None: return [];
        case WarningLevel.Default: return [];
        case WarningLevel.Extra: return ["-Wall"];
        case WarningLevel.All: return ["-Wall", "-Wextra"];
        case WarningLevel.Pedantic: return ["-Wall", "-Wextra", "-Wpedantic"];
        case WarningLevel.Error: return ["-Wall", "-Wextra", "-Werror"];
    }
}

/// Convert sanitizer to compiler flag
string toFlag(Sanitizer san) pure nothrow
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

