module languages.compiled.d.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// D build modes
enum DBuildMode
{
    /// Standard compilation
    Compile,
    /// Build and run tests
    Test,
    /// Run after building
    Run,
    /// Build using dub
    Dub,
    /// Documentation generation
    Doc,
    /// Linting with dscanner
    Lint,
    /// Custom build
    Custom
}

/// D compiler selection
enum DCompiler
{
    /// Auto-detect (prefer ldc > dmd > gdc)
    Auto,
    /// LDC (LLVM D Compiler) - production builds
    LDC,
    /// DMD (Digital Mars D) - fast compilation
    DMD,
    /// GDC (GCC D Compiler) - GCC integration
    GDC,
    /// Custom compiler command
    Custom
}

/// Build configuration
enum BuildConfig
{
    /// Debug build (default for dub)
    Debug,
    /// Plain build
    Plain,
    /// Release build with bounds checks
    Release,
    /// Release build with inlining
    ReleaseNoBounds,
    /// Unit test build
    Unittest,
    /// Profile-guided build
    Profile,
    /// Code coverage build
    Cov,
    /// Unittest with coverage
    UnittestCov,
    /// Syntax check only
    SyntaxOnly
}

/// D compiler architecture
enum DArch
{
    /// x86 32-bit
    X86,
    /// x86 64-bit
    X86_64,
    /// ARM 32-bit
    ARM,
    /// ARM 64-bit (AArch64)
    AArch64,
    /// MIPS 32-bit
    MIPS,
    /// MIPS 64-bit
    MIPS64,
    /// PowerPC
    PPC,
    /// PowerPC 64-bit
    PPC64,
    /// RISC-V
    RISCV
}

/// Output types
enum OutputType
{
    /// Executable
    Executable,
    /// Static library
    StaticLib,
    /// Shared/dynamic library
    SharedLib,
    /// Object file
    Object
}

/// DUB package format
enum DubFormat
{
    /// JSON format (dub.json)
    JSON,
    /// SDLang format (dub.sdl)
    SDL
}

/// BetterC mode for C-compatible code
enum BetterCMode
{
    /// Standard D runtime
    Off,
    /// Minimal runtime (-betterC)
    BetterC
}

/// Code coverage tool
enum CoverageTool
{
    /// Built-in D coverage
    Builtin,
    /// LLVM coverage (llvm-cov)
    LLVMCov
}

/// DUB target type
enum DubTargetType
{
    /// Auto-detect from package
    Auto,
    /// Executable
    Executable,
    /// Library (static)
    Library,
    /// Shared library
    DynamicLibrary,
    /// Static library
    StaticLibrary,
    /// Source library (header-only equivalent)
    SourceLibrary,
    /// No output
    None
}

/// DUB configuration
struct DubConfig
{
    /// Path to dub.json or dub.sdl
    string packagePath;
    
    /// Package format
    DubFormat format = DubFormat.JSON;
    
    /// Build configuration (debug, release, etc.)
    string configuration;
    
    /// Specific package to build (in workspace)
    string package_;
    
    /// Build all packages in workspace
    bool workspace = false;
    
    /// Target type override
    DubTargetType targetType = DubTargetType.Auto;
    
    /// Compiler to use
    string compiler;
    
    /// Architecture to build for
    string arch;
    
    /// Build mode (build, run, test, etc.)
    string command = "build";
    
    /// DUB-specific flags
    string[] dubFlags;
    
    /// Combined (combine multiple packages into one)
    bool combined = false;
    
    /// Print commands instead of executing
    bool printCommands = false;
    
    /// Force rebuild
    bool force = false;
    
    /// Number of parallel jobs
    size_t jobs = 0; // 0 = auto
    
    /// Deep search for dependencies
    bool deep = false;
    
    /// Single file compilation
    bool single = false;
    
    /// Verbose output
    bool verbose = false;
    
    /// Very verbose output
    bool vverbose = false;
    
    /// Quiet output
    bool quiet = false;
    
    /// Verify dependencies
    bool verifyDeps = true;
    
    /// Skip registry
    bool skipRegistry = false;
    
    /// Specific registry URL
    string registry;
    
    /// Override path
    string[string] overrides;
}

/// Direct compiler configuration
struct CompilerConfig
{
    /// Compiler executable path
    string compilerPath;
    
    /// Optimization flags
    string[] optimizationFlags;
    
    /// Warning flags
    string[] warningFlags;
    
    /// Define symbols
    string[] defines;
    
    /// Version identifiers
    string[] versions;
    
    /// Debug identifiers
    string[] debugs;
    
    /// Import paths
    string[] importPaths;
    
    /// String import paths
    string[] stringImportPaths;
    
    /// Library paths
    string[] libPaths;
    
    /// Libraries to link
    string[] libs;
    
    /// Enable bounds checking
    bool boundsCheck = true;
    
    /// Enable inline expansion
    bool inline = false;
    
    /// Release mode
    bool release = false;
    
    /// Enable debug symbols
    bool debugSymbols = true;
    
    /// Enable profile instrumentation
    bool profile = false;
    
    /// Enable code coverage
    bool coverage = false;
    
    /// Unit test mode
    bool unittest_ = false;
    
    /// BetterC mode
    BetterCMode betterC = BetterCMode.Off;
    
    /// Enable deprecation warnings
    bool deprecations = true;
    
    /// Deprecations as errors
    bool deprecationErrors = false;
    
    /// Enable warnings
    bool warnings = true;
    
    /// Warnings as errors
    bool warningsAsErrors = false;
    
    /// Enable informational messages
    bool info = false;
    
    /// Check only (don't generate code)
    bool checkOnly = false;
    
    /// Verbose output
    bool verbose = false;
    
    /// Generate documentation
    bool doc = false;
    
    /// Documentation output directory
    string docDir = "docs";
    
    /// Documentation format
    string docFormat; // json, html
    
    /// Enable color output
    bool color = true;
    
    /// Generate JSON description
    bool json = false;
    
    /// JSON output file
    string jsonFile;
    
    /// Enable preview features
    string[] preview;
    
    /// Enable revert features
    string[] revert;
    
    /// Enable transition features
    string[] transition;
    
    /// DIP1000 memory safety
    bool dip1000 = false;
    
    /// DIP1008 throw without exception objects
    bool dip1008 = false;
    
    /// DIP25 sealed references
    bool dip25 = false;
    
    /// Enable all language extensions
    bool allExtensions = false;
    
    /// Target architecture
    DArch arch = DArch.X86_64;
    
    /// Custom target triple (for LDC/GDC)
    string targetTriple;
    
    /// Cross-compilation sysroot
    string sysroot;
    
    /// Position independent code
    bool pic = false;
    
    /// Position independent executable
    bool pie = false;
    
    /// LTO (Link Time Optimization) - LDC only
    bool lto = false;
    
    /// Link all libraries statically
    bool staticLink = false;
    
    /// Additional linker flags
    string[] linkerFlags;
    
    /// Enable stack stomping in debug
    bool stackStomp = false;
    
    /// Enable allocation profiling
    bool allocProfile = false;
}

/// Testing configuration
struct TestConfig
{
    /// Main function for tests
    string mainFile;
    
    /// Test filter pattern
    string filter;
    
    /// Run specific test
    string testName;
    
    /// Verbose test output
    bool verbose = false;
    
    /// Show coverage
    bool coverage = false;
    
    /// Coverage tool
    CoverageTool coverageTool = CoverageTool.Builtin;
    
    /// Coverage output directory
    string coverageDir = "coverage";
    
    /// Minimum coverage threshold
    float minCoverage = 0.0;
}

/// Tooling configuration
struct ToolingConfig
{
    /// Run dfmt formatter
    bool runFmt = false;
    
    /// Format check only (don't modify)
    bool fmtCheckOnly = false;
    
    /// dfmt configuration file
    string fmtConfig;
    
    /// Run dscanner linter
    bool runLint = false;
    
    /// dscanner configuration file
    string lintConfig;
    
    /// Lint style check
    bool lintStyleCheck = true;
    
    /// Lint syntax check
    bool lintSyntaxCheck = true;
    
    /// Report type for dscanner
    string lintReport = "stylish"; // json, sonarqube, stylish
    
    /// Run dub test
    bool runDubTest = false;
}

/// CPU target mode for D
enum DCpuTarget
{
    Generic,        // No CPU-specific optimizations
    Native,         // -mcpu=native (LDC) or auto-detect
    Custom          // Custom -mcpu value
}

/// PGO mode for D (LDC only)
enum DPgoMode
{
    Off,            // No PGO
    Generate,       // -fprofile-generate
    Use             // -fprofile-use
}

/// D optimization preset
enum DOptPreset
{
    None,           // Manual configuration
    Debug,          // Fast compile, full debug info
    ReleaseFast,    // Fast execution (LDC -O3, native CPU)
    ReleaseSmall,   // Small binary (-Os, strip)
    ReleaseLto,     // Max optimization (LTO, native, single codegen)
    ProfileGen,     // Generate PGO data
    ProfileUse      // Use PGO data + full optimization
}

/// Advanced D optimization configuration (primarily for LDC)
struct DAdvancedOpt
{
    /// Optimization preset
    DOptPreset preset = DOptPreset.None;
    
    /// CPU targeting
    DCpuTarget cpuTarget = DCpuTarget.Generic;
    
    /// Custom -mcpu value (when cpuTarget == Custom)
    string mcpu;
    
    /// CPU features to enable (e.g., "+avx2,+fma")
    string cpuFeatures;
    
    /// PGO mode (LDC only)
    DPgoMode pgo = DPgoMode.Off;
    
    /// PGO profile directory
    string pgoProfileDir = ".pgo-data";
    
    /// Enable LTO (Link Time Optimization)
    bool lto = false;
    
    /// LTO mode: "full" or "thin"
    string ltoMode = "thin";
    
    /// Fast math optimizations
    bool fastMath = false;
    
    /// Disable bounds checking
    bool noBoundsCheck = false;
    
    /// Enable function inlining
    bool inlining = true;
    
    /// Enable cross-module inlining (LDC)
    bool crossModuleInline = false;
    
    /// Enable flattening (LDC)
    bool flattening = false;
    
    /// Enable loop unrolling
    bool unrollLoops = false;
    
    /// Enable vectorization
    bool vectorize = true;
    
    /// Strip debug info from release
    bool strip = false;
    
    /// Frame pointer (for profiling)
    bool framePointer = false;
    
    /// Single-object compilation (better LTO)
    bool singleObj = false;
    
    /// Convert to compiler flags (LDC format)
    string[] toLdcFlags() const pure
    {
        string[] flags;
        
        // CPU targeting
        final switch (cpuTarget) with (DCpuTarget)
        {
            case Generic: break;
            case Native:
                flags ~= "-mcpu=native";
                break;
            case Custom:
                if (mcpu.length)
                    flags ~= "-mcpu=" ~ mcpu;
                break;
        }
        
        // CPU features
        if (cpuFeatures.length)
            flags ~= "-mattr=" ~ cpuFeatures;
        
        // PGO
        final switch (pgo) with (DPgoMode)
        {
            case Off: break;
            case Generate:
                flags ~= "-fprofile-generate=" ~ pgoProfileDir;
                break;
            case Use:
                flags ~= "-fprofile-use=" ~ pgoProfileDir ~ "/default.profdata";
                break;
        }
        
        // LTO
        if (lto)
        {
            if (ltoMode == "full")
                flags ~= "-flto=full";
            else
                flags ~= "-flto=thin";
        }
        
        // Fast math
        if (fastMath)
            flags ~= "-ffast-math";
        
        // Bounds checking
        if (noBoundsCheck)
            flags ~= "--boundscheck=off";
        
        // Inlining
        if (!inlining)
            flags ~= "-O0"; // Disable inlining via O0 (crude but effective)
        
        // Cross-module inlining
        if (crossModuleInline)
            flags ~= "--enable-cross-module-inlining";
        
        // Flattening
        if (flattening)
            flags ~= "--enable-inlining";
        
        // Vectorization
        if (!vectorize)
            flags ~= "-vectorize=false";
        
        // Frame pointer
        if (framePointer)
            flags ~= "-frame-pointer=all";
        
        // Single object
        if (singleObj)
            flags ~= "-singleobj";
        
        return flags;
    }
    
    /// Apply preset
    static DAdvancedOpt fromPreset(DOptPreset preset) pure
    {
        DAdvancedOpt cfg;
        cfg.preset = preset;
        
        final switch (preset) with (DOptPreset)
        {
            case None: break;
            case Debug:
                cfg.inlining = false;
                cfg.vectorize = false;
                break;
            case ReleaseFast:
                cfg.cpuTarget = DCpuTarget.Native;
                cfg.inlining = true;
                cfg.vectorize = true;
                cfg.unrollLoops = true;
                break;
            case ReleaseSmall:
                cfg.strip = true;
                cfg.inlining = true;
                break;
            case ReleaseLto:
                cfg.cpuTarget = DCpuTarget.Native;
                cfg.lto = true;
                cfg.ltoMode = "full";
                cfg.crossModuleInline = true;
                cfg.singleObj = true;
                cfg.inlining = true;
                cfg.vectorize = true;
                cfg.unrollLoops = true;
                break;
            case ProfileGen:
                cfg.pgo = DPgoMode.Generate;
                break;
            case ProfileUse:
                cfg.pgo = DPgoMode.Use;
                cfg.cpuTarget = DCpuTarget.Native;
                cfg.lto = true;
                cfg.inlining = true;
                cfg.vectorize = true;
                break;
        }
        
        return cfg;
    }
}

/// D-specific build configuration
struct DConfig
{
    /// Build mode
    DBuildMode mode = DBuildMode.Compile;
    
    /// Compiler selection
    DCompiler compiler = DCompiler.Auto;
    
    /// Custom compiler path
    string customCompiler;
    
    /// Build configuration
    BuildConfig buildConfig = BuildConfig.Release;
    
    /// Output type
    OutputType outputType = OutputType.Executable;
    
    /// Entry point file
    string entry;
    
    /// Output directory
    string outputDir = "bin";
    
    /// Output name
    string outputName;
    
    /// DUB configuration
    DubConfig dub;
    
    /// Direct compiler configuration
    CompilerConfig compilerConfig;
    
    /// Test configuration
    TestConfig test;
    
    /// Tooling configuration
    ToolingConfig tooling;
    
    /// Advanced optimizations (LDC-specific)
    DAdvancedOpt advancedOpt;
    
    /// Environment variables
    string[string] env;
    
    /// Parse from JSON
    static DConfig fromJSON(JSONValue json)
    {
        DConfig config;
        
        // Mode
        if ("mode" in json)
        {
            string modeStr = json["mode"].str.toLower;
            switch (modeStr)
            {
                case "compile": config.mode = DBuildMode.Compile; break;
                case "test": config.mode = DBuildMode.Test; break;
                case "run": config.mode = DBuildMode.Run; break;
                case "dub": config.mode = DBuildMode.Dub; break;
                case "doc": config.mode = DBuildMode.Doc; break;
                case "lint": config.mode = DBuildMode.Lint; break;
                case "custom": config.mode = DBuildMode.Custom; break;
                default: config.mode = DBuildMode.Compile; break;
            }
        }
        
        // Compiler
        if ("compiler" in json)
        {
            string compilerStr = json["compiler"].str.toLower;
            switch (compilerStr)
            {
                case "auto": config.compiler = DCompiler.Auto; break;
                case "ldc": case "ldc2": config.compiler = DCompiler.LDC; break;
                case "dmd": config.compiler = DCompiler.DMD; break;
                case "gdc": config.compiler = DCompiler.GDC; break;
                case "custom": config.compiler = DCompiler.Custom; break;
                default: config.compiler = DCompiler.Auto; break;
            }
        }
        
        // Build configuration
        if ("buildConfig" in json || "build_config" in json)
        {
            string key = "buildConfig" in json ? "buildConfig" : "build_config";
            string buildStr = json[key].str.toLower;
            switch (buildStr)
            {
                case "debug": config.buildConfig = BuildConfig.Debug; break;
                case "plain": config.buildConfig = BuildConfig.Plain; break;
                case "release": config.buildConfig = BuildConfig.Release; break;
                case "release-nobounds": case "releasenobounds": 
                    config.buildConfig = BuildConfig.ReleaseNoBounds; break;
                case "unittest": config.buildConfig = BuildConfig.Unittest; break;
                case "profile": config.buildConfig = BuildConfig.Profile; break;
                case "cov": case "coverage": config.buildConfig = BuildConfig.Cov; break;
                case "unittest-cov": case "unittestcov": 
                    config.buildConfig = BuildConfig.UnittestCov; break;
                case "syntax": case "syntaxonly": 
                    config.buildConfig = BuildConfig.SyntaxOnly; break;
                default: config.buildConfig = BuildConfig.Release; break;
            }
        }
        
        // Output type
        if ("outputType" in json || "output_type" in json)
        {
            string key = "outputType" in json ? "outputType" : "output_type";
            string typeStr = json[key].str.toLower;
            switch (typeStr)
            {
                case "exe": case "executable": config.outputType = OutputType.Executable; break;
                case "lib": case "staticlib": config.outputType = OutputType.StaticLib; break;
                case "dylib": case "sharedlib": config.outputType = OutputType.SharedLib; break;
                case "obj": case "object": config.outputType = OutputType.Object; break;
                default: config.outputType = OutputType.Executable; break;
            }
        }
        
        // String fields
        if ("entry" in json) config.entry = json["entry"].str;
        if ("outputDir" in json || "output_dir" in json)
        {
            string key = "outputDir" in json ? "outputDir" : "output_dir";
            config.outputDir = json[key].str;
        }
        if ("outputName" in json || "output_name" in json)
        {
            string key = "outputName" in json ? "outputName" : "output_name";
            config.outputName = json[key].str;
        }
        if ("customCompiler" in json || "custom_compiler" in json)
        {
            string key = "customCompiler" in json ? "customCompiler" : "custom_compiler";
            config.customCompiler = json[key].str;
        }
        
        // DUB configuration
        if ("dub" in json)
        {
            auto dub = json["dub"];
            if ("packagePath" in dub || "package_path" in dub)
            {
                string key = "packagePath" in dub ? "packagePath" : "package_path";
                config.dub.packagePath = dub[key].str;
            }
            if ("configuration" in dub) config.dub.configuration = dub["configuration"].str;
            if ("package" in dub) config.dub.package_ = dub["package"].str;
            if ("compiler" in dub) config.dub.compiler = dub["compiler"].str;
            if ("arch" in dub) config.dub.arch = dub["arch"].str;
            if ("command" in dub) config.dub.command = dub["command"].str;
            if ("registry" in dub) config.dub.registry = dub["registry"].str;
            
            if ("workspace" in dub) config.dub.workspace = dub["workspace"].type == JSONType.true_;
            if ("combined" in dub) config.dub.combined = dub["combined"].type == JSONType.true_;
            if ("printCommands" in dub || "print_commands" in dub)
            {
                string key = "printCommands" in dub ? "printCommands" : "print_commands";
                config.dub.printCommands = dub[key].type == JSONType.true_;
            }
            if ("force" in dub) config.dub.force = dub["force"].type == JSONType.true_;
            if ("deep" in dub) config.dub.deep = dub["deep"].type == JSONType.true_;
            if ("single" in dub) config.dub.single = dub["single"].type == JSONType.true_;
            if ("verbose" in dub) config.dub.verbose = dub["verbose"].type == JSONType.true_;
            if ("vverbose" in dub) config.dub.vverbose = dub["vverbose"].type == JSONType.true_;
            if ("quiet" in dub) config.dub.quiet = dub["quiet"].type == JSONType.true_;
            if ("verifyDeps" in dub || "verify_deps" in dub)
            {
                string key = "verifyDeps" in dub ? "verifyDeps" : "verify_deps";
                config.dub.verifyDeps = dub[key].type == JSONType.true_;
            }
            if ("skipRegistry" in dub || "skip_registry" in dub)
            {
                string key = "skipRegistry" in dub ? "skipRegistry" : "skip_registry";
                config.dub.skipRegistry = dub[key].type == JSONType.true_;
            }
            
            if ("jobs" in dub) config.dub.jobs = dub["jobs"].integer.to!size_t;
            if ("dubFlags" in dub || "dub_flags" in dub)
            {
                string key = "dubFlags" in dub ? "dubFlags" : "dub_flags";
                config.dub.dubFlags = dub[key].array.map!(e => e.str).array;
            }
            
            if ("overrides" in dub)
            {
                foreach (string okey, value; dub["overrides"].object)
                {
                    config.dub.overrides[okey] = value.str;
                }
            }
        }
        
        // Compiler configuration
        if ("compilerConfig" in json || "compiler_config" in json)
        {
            string ckey = "compilerConfig" in json ? "compilerConfig" : "compiler_config";
            auto cc = json[ckey];
            
            if ("compilerPath" in cc || "compiler_path" in cc)
            {
                string key = "compilerPath" in cc ? "compilerPath" : "compiler_path";
                config.compilerConfig.compilerPath = cc[key].str;
            }
            if ("docDir" in cc || "doc_dir" in cc)
            {
                string key = "docDir" in cc ? "docDir" : "doc_dir";
                config.compilerConfig.docDir = cc[key].str;
            }
            if ("docFormat" in cc || "doc_format" in cc)
            {
                string key = "docFormat" in cc ? "docFormat" : "doc_format";
                config.compilerConfig.docFormat = cc[key].str;
            }
            if ("jsonFile" in cc || "json_file" in cc)
            {
                string key = "jsonFile" in cc ? "jsonFile" : "json_file";
                config.compilerConfig.jsonFile = cc[key].str;
            }
            if ("targetTriple" in cc || "target_triple" in cc)
            {
                string key = "targetTriple" in cc ? "targetTriple" : "target_triple";
                config.compilerConfig.targetTriple = cc[key].str;
            }
            if ("sysroot" in cc) config.compilerConfig.sysroot = cc["sysroot"].str;
            
            // Boolean fields
            if ("boundsCheck" in cc || "bounds_check" in cc)
            {
                string key = "boundsCheck" in cc ? "boundsCheck" : "bounds_check";
                config.compilerConfig.boundsCheck = cc[key].type == JSONType.true_;
            }
            if ("inline" in cc) config.compilerConfig.inline = cc["inline"].type == JSONType.true_;
            if ("release" in cc) config.compilerConfig.release = cc["release"].type == JSONType.true_;
            if ("debugSymbols" in cc || "debug_symbols" in cc)
            {
                string key = "debugSymbols" in cc ? "debugSymbols" : "debug_symbols";
                config.compilerConfig.debugSymbols = cc[key].type == JSONType.true_;
            }
            if ("profile" in cc) config.compilerConfig.profile = cc["profile"].type == JSONType.true_;
            if ("coverage" in cc) config.compilerConfig.coverage = cc["coverage"].type == JSONType.true_;
            if ("unittest" in cc) config.compilerConfig.unittest_ = cc["unittest"].type == JSONType.true_;
            if ("deprecations" in cc) config.compilerConfig.deprecations = cc["deprecations"].type == JSONType.true_;
            if ("deprecationErrors" in cc || "deprecation_errors" in cc)
            {
                string key = "deprecationErrors" in cc ? "deprecationErrors" : "deprecation_errors";
                config.compilerConfig.deprecationErrors = cc[key].type == JSONType.true_;
            }
            if ("warnings" in cc) config.compilerConfig.warnings = cc["warnings"].type == JSONType.true_;
            if ("warningsAsErrors" in cc || "warnings_as_errors" in cc)
            {
                string key = "warningsAsErrors" in cc ? "warningsAsErrors" : "warnings_as_errors";
                config.compilerConfig.warningsAsErrors = cc[key].type == JSONType.true_;
            }
            if ("info" in cc) config.compilerConfig.info = cc["info"].type == JSONType.true_;
            if ("checkOnly" in cc || "check_only" in cc)
            {
                string key = "checkOnly" in cc ? "checkOnly" : "check_only";
                config.compilerConfig.checkOnly = cc[key].type == JSONType.true_;
            }
            if ("verbose" in cc) config.compilerConfig.verbose = cc["verbose"].type == JSONType.true_;
            if ("doc" in cc) config.compilerConfig.doc = cc["doc"].type == JSONType.true_;
            if ("color" in cc) config.compilerConfig.color = cc["color"].type == JSONType.true_;
            if ("json" in cc) config.compilerConfig.json = cc["json"].type == JSONType.true_;
            if ("dip1000" in cc) config.compilerConfig.dip1000 = cc["dip1000"].type == JSONType.true_;
            if ("dip1008" in cc) config.compilerConfig.dip1008 = cc["dip1008"].type == JSONType.true_;
            if ("dip25" in cc) config.compilerConfig.dip25 = cc["dip25"].type == JSONType.true_;
            if ("allExtensions" in cc || "all_extensions" in cc)
            {
                string key = "allExtensions" in cc ? "allExtensions" : "all_extensions";
                config.compilerConfig.allExtensions = cc[key].type == JSONType.true_;
            }
            if ("pic" in cc) config.compilerConfig.pic = cc["pic"].type == JSONType.true_;
            if ("pie" in cc) config.compilerConfig.pie = cc["pie"].type == JSONType.true_;
            if ("lto" in cc) config.compilerConfig.lto = cc["lto"].type == JSONType.true_;
            if ("staticLink" in cc || "static_link" in cc)
            {
                string key = "staticLink" in cc ? "staticLink" : "static_link";
                config.compilerConfig.staticLink = cc[key].type == JSONType.true_;
            }
            if ("stackStomp" in cc || "stack_stomp" in cc)
            {
                string key = "stackStomp" in cc ? "stackStomp" : "stack_stomp";
                config.compilerConfig.stackStomp = cc[key].type == JSONType.true_;
            }
            if ("allocProfile" in cc || "alloc_profile" in cc)
            {
                string key = "allocProfile" in cc ? "allocProfile" : "alloc_profile";
                config.compilerConfig.allocProfile = cc[key].type == JSONType.true_;
            }
            
            // BetterC mode
            if ("betterC" in cc || "better_c" in cc)
            {
                string key = "betterC" in cc ? "betterC" : "better_c";
                if (cc[key].type == JSONType.true_)
                    config.compilerConfig.betterC = BetterCMode.BetterC;
                else if (cc[key].type == JSONType.false_)
                    config.compilerConfig.betterC = BetterCMode.Off;
            }
            
            // Array fields
            if ("optimizationFlags" in cc || "optimization_flags" in cc)
            {
                string key = "optimizationFlags" in cc ? "optimizationFlags" : "optimization_flags";
                config.compilerConfig.optimizationFlags = cc[key].array.map!(e => e.str).array;
            }
            if ("warningFlags" in cc || "warning_flags" in cc)
            {
                string key = "warningFlags" in cc ? "warningFlags" : "warning_flags";
                config.compilerConfig.warningFlags = cc[key].array.map!(e => e.str).array;
            }
            if ("defines" in cc)
                config.compilerConfig.defines = cc["defines"].array.map!(e => e.str).array;
            if ("versions" in cc)
                config.compilerConfig.versions = cc["versions"].array.map!(e => e.str).array;
            if ("debugs" in cc)
                config.compilerConfig.debugs = cc["debugs"].array.map!(e => e.str).array;
            if ("importPaths" in cc || "import_paths" in cc)
            {
                string key = "importPaths" in cc ? "importPaths" : "import_paths";
                config.compilerConfig.importPaths = cc[key].array.map!(e => e.str).array;
            }
            if ("stringImportPaths" in cc || "string_import_paths" in cc)
            {
                string key = "stringImportPaths" in cc ? "stringImportPaths" : "string_import_paths";
                config.compilerConfig.stringImportPaths = cc[key].array.map!(e => e.str).array;
            }
            if ("libPaths" in cc || "lib_paths" in cc)
            {
                string key = "libPaths" in cc ? "libPaths" : "lib_paths";
                config.compilerConfig.libPaths = cc[key].array.map!(e => e.str).array;
            }
            if ("libs" in cc)
                config.compilerConfig.libs = cc["libs"].array.map!(e => e.str).array;
            if ("linkerFlags" in cc || "linker_flags" in cc)
            {
                string key = "linkerFlags" in cc ? "linkerFlags" : "linker_flags";
                config.compilerConfig.linkerFlags = cc[key].array.map!(e => e.str).array;
            }
            if ("preview" in cc)
                config.compilerConfig.preview = cc["preview"].array.map!(e => e.str).array;
            if ("revert" in cc)
                config.compilerConfig.revert = cc["revert"].array.map!(e => e.str).array;
            if ("transition" in cc)
                config.compilerConfig.transition = cc["transition"].array.map!(e => e.str).array;
        }
        
        // Test configuration
        if ("test" in json)
        {
            auto test = json["test"];
            if ("mainFile" in test || "main_file" in test)
            {
                string key = "mainFile" in test ? "mainFile" : "main_file";
                config.test.mainFile = test[key].str;
            }
            if ("filter" in test) config.test.filter = test["filter"].str;
            if ("testName" in test || "test_name" in test)
            {
                string key = "testName" in test ? "testName" : "test_name";
                config.test.testName = test[key].str;
            }
            if ("coverageDir" in test || "coverage_dir" in test)
            {
                string key = "coverageDir" in test ? "coverageDir" : "coverage_dir";
                config.test.coverageDir = test[key].str;
            }
            
            if ("verbose" in test) config.test.verbose = test["verbose"].type == JSONType.true_;
            if ("coverage" in test) config.test.coverage = test["coverage"].type == JSONType.true_;
            
            if ("minCoverage" in test || "min_coverage" in test)
            {
                string key = "minCoverage" in test ? "minCoverage" : "min_coverage";
                config.test.minCoverage = test[key].floating.to!float;
            }
        }
        
        // Tooling configuration
        if ("tooling" in json)
        {
            auto tooling = json["tooling"];
            if ("fmtConfig" in tooling || "fmt_config" in tooling)
            {
                string key = "fmtConfig" in tooling ? "fmtConfig" : "fmt_config";
                config.tooling.fmtConfig = tooling[key].str;
            }
            if ("lintConfig" in tooling || "lint_config" in tooling)
            {
                string key = "lintConfig" in tooling ? "lintConfig" : "lint_config";
                config.tooling.lintConfig = tooling[key].str;
            }
            if ("lintReport" in tooling || "lint_report" in tooling)
            {
                string key = "lintReport" in tooling ? "lintReport" : "lint_report";
                config.tooling.lintReport = tooling[key].str;
            }
            
            if ("runFmt" in tooling || "run_fmt" in tooling)
            {
                string key = "runFmt" in tooling ? "runFmt" : "run_fmt";
                config.tooling.runFmt = tooling[key].type == JSONType.true_;
            }
            if ("fmtCheckOnly" in tooling || "fmt_check_only" in tooling)
            {
                string key = "fmtCheckOnly" in tooling ? "fmtCheckOnly" : "fmt_check_only";
                config.tooling.fmtCheckOnly = tooling[key].type == JSONType.true_;
            }
            if ("runLint" in tooling || "run_lint" in tooling)
            {
                string key = "runLint" in tooling ? "runLint" : "run_lint";
                config.tooling.runLint = tooling[key].type == JSONType.true_;
            }
            if ("lintStyleCheck" in tooling || "lint_style_check" in tooling)
            {
                string key = "lintStyleCheck" in tooling ? "lintStyleCheck" : "lint_style_check";
                config.tooling.lintStyleCheck = tooling[key].type == JSONType.true_;
            }
            if ("lintSyntaxCheck" in tooling || "lint_syntax_check" in tooling)
            {
                string key = "lintSyntaxCheck" in tooling ? "lintSyntaxCheck" : "lint_syntax_check";
                config.tooling.lintSyntaxCheck = tooling[key].type == JSONType.true_;
            }
            if ("runDubTest" in tooling || "run_dub_test" in tooling)
            {
                string key = "runDubTest" in tooling ? "runDubTest" : "run_dub_test";
                config.tooling.runDubTest = tooling[key].type == JSONType.true_;
            }
        }
        
        // Environment variables
        if ("env" in json)
        {
            foreach (string ekey, value; json["env"].object)
            {
                config.env[ekey] = value.str;
            }
        }
        
        // Advanced optimizations
        if ("advancedOpt" in json || "advanced_opt" in json || "optimization" in json)
        {
            string optKey = "advancedOpt" in json ? "advancedOpt" : 
                           ("advanced_opt" in json ? "advanced_opt" : "optimization");
            auto optObj = json[optKey].object;
            
            // Preset
            if ("preset" in optObj)
            {
                string presetStr = optObj["preset"].str.toLower.replace("-", "").replace("_", "");
                switch (presetStr)
                {
                    case "debug": config.advancedOpt = DAdvancedOpt.fromPreset(DOptPreset.Debug); break;
                    case "releasefast": config.advancedOpt = DAdvancedOpt.fromPreset(DOptPreset.ReleaseFast); break;
                    case "releasesmall": config.advancedOpt = DAdvancedOpt.fromPreset(DOptPreset.ReleaseSmall); break;
                    case "releaselto": config.advancedOpt = DAdvancedOpt.fromPreset(DOptPreset.ReleaseLto); break;
                    case "profilegen": config.advancedOpt = DAdvancedOpt.fromPreset(DOptPreset.ProfileGen); break;
                    case "profileuse": config.advancedOpt = DAdvancedOpt.fromPreset(DOptPreset.ProfileUse); break;
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
                    case "generic": config.advancedOpt.cpuTarget = DCpuTarget.Generic; break;
                    case "native": config.advancedOpt.cpuTarget = DCpuTarget.Native; break;
                    case "custom": config.advancedOpt.cpuTarget = DCpuTarget.Custom; break;
                    default: break;
                }
            }
            if ("mcpu" in optObj)
                config.advancedOpt.mcpu = optObj["mcpu"].str;
            if ("cpuFeatures" in optObj || "cpu_features" in optObj)
            {
                string cfKey = "cpuFeatures" in optObj ? "cpuFeatures" : "cpu_features";
                config.advancedOpt.cpuFeatures = optObj[cfKey].str;
            }
            
            // PGO
            if ("pgo" in optObj)
            {
                string pgoStr = optObj["pgo"].str.toLower;
                switch (pgoStr)
                {
                    case "off": config.advancedOpt.pgo = DPgoMode.Off; break;
                    case "generate": case "gen": config.advancedOpt.pgo = DPgoMode.Generate; break;
                    case "use": config.advancedOpt.pgo = DPgoMode.Use; break;
                    default: break;
                }
            }
            if ("pgoProfileDir" in optObj || "pgo_profile_dir" in optObj)
            {
                string pdKey = "pgoProfileDir" in optObj ? "pgoProfileDir" : "pgo_profile_dir";
                config.advancedOpt.pgoProfileDir = optObj[pdKey].str;
            }
            
            // LTO
            if ("lto" in optObj)
                config.advancedOpt.lto = optObj["lto"].type == JSONType.true_;
            if ("ltoMode" in optObj || "lto_mode" in optObj)
            {
                string lmKey = "ltoMode" in optObj ? "ltoMode" : "lto_mode";
                config.advancedOpt.ltoMode = optObj[lmKey].str;
            }
            
            // Boolean flags
            if ("fastMath" in optObj || "fast_math" in optObj)
            {
                string fmKey = "fastMath" in optObj ? "fastMath" : "fast_math";
                config.advancedOpt.fastMath = optObj[fmKey].type == JSONType.true_;
            }
            if ("noBoundsCheck" in optObj || "no_bounds_check" in optObj)
            {
                string nbKey = "noBoundsCheck" in optObj ? "noBoundsCheck" : "no_bounds_check";
                config.advancedOpt.noBoundsCheck = optObj[nbKey].type == JSONType.true_;
            }
            if ("inlining" in optObj)
                config.advancedOpt.inlining = optObj["inlining"].type == JSONType.true_;
            if ("crossModuleInline" in optObj || "cross_module_inline" in optObj)
            {
                string cmKey = "crossModuleInline" in optObj ? "crossModuleInline" : "cross_module_inline";
                config.advancedOpt.crossModuleInline = optObj[cmKey].type == JSONType.true_;
            }
            if ("flattening" in optObj)
                config.advancedOpt.flattening = optObj["flattening"].type == JSONType.true_;
            if ("unrollLoops" in optObj || "unroll_loops" in optObj)
            {
                string ulKey = "unrollLoops" in optObj ? "unrollLoops" : "unroll_loops";
                config.advancedOpt.unrollLoops = optObj[ulKey].type == JSONType.true_;
            }
            if ("vectorize" in optObj)
                config.advancedOpt.vectorize = optObj["vectorize"].type == JSONType.true_;
            if ("strip" in optObj)
                config.advancedOpt.strip = optObj["strip"].type == JSONType.true_;
            if ("framePointer" in optObj || "frame_pointer" in optObj)
            {
                string fpKey = "framePointer" in optObj ? "framePointer" : "frame_pointer";
                config.advancedOpt.framePointer = optObj[fpKey].type == JSONType.true_;
            }
            if ("singleObj" in optObj || "single_obj" in optObj)
            {
                string soKey = "singleObj" in optObj ? "singleObj" : "single_obj";
                config.advancedOpt.singleObj = optObj[soKey].type == JSONType.true_;
            }
        }
        
        return config;
    }
}

/// D compilation result
struct DCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string[] artifacts; // Documentation, coverage reports, etc.
    string outputHash;
    bool hadWarnings;
    string[] warnings;
    bool hadLintIssues;
    string[] lintIssues;
    float coveragePercent = 0.0;
}


