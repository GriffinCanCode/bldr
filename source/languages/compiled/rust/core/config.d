module languages.compiled.rust.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// Rust build modes
enum RustBuildMode
{
    /// Standard compilation
    Compile,
    /// Check only (cargo check)
    Check,
    /// Build and test
    Test,
    /// Build documentation
    Doc,
    /// Run benchmarks
    Bench,
    /// Build examples
    Example,
    /// Custom build
    Custom
}

/// Cargo or direct rustc compilation
enum RustCompiler
{
    /// Auto-detect (prefer cargo if Cargo.toml exists)
    Auto,
    /// Use cargo
    Cargo,
    /// Use rustc directly
    Rustc
}

/// Build profile selection
enum RustProfile
{
    /// Development profile (debug, fast compile)
    Dev,
    /// Release profile (optimized)
    Release,
    /// Test profile
    Test,
    /// Benchmark profile
    Bench,
    /// Custom profile
    Custom
}

/// Rust edition
enum RustEdition
{
    Edition2015,
    Edition2018,
    Edition2021,
    Edition2024
}

/// Crate type
enum CrateType
{
    /// Binary executable
    Bin,
    /// Rust library (rlib)
    Lib,
    /// Rust library (rlib) - explicit
    Rlib,
    /// Dynamic library
    Dylib,
    /// C-compatible dynamic library
    Cdylib,
    /// Static library
    Staticlib,
    /// Procedural macro
    ProcMacro
}

/// Optimization level
enum OptLevel
{
    /// No optimization
    O0,
    /// Basic optimization
    O1,
    /// Medium optimization
    O2,
    /// Aggressive optimization
    O3,
    /// Size optimization
    Os,
    /// Size optimization (aggressive)
    Oz
}

/// Link-time optimization
enum LtoMode
{
    /// No LTO
    Off,
    /// Thin LTO
    Thin,
    /// Fat LTO
    Fat
}

/// Code generation units
enum Codegen
{
    /// Default
    Default,
    /// Single codegen unit (best optimization)
    Single,
    /// Custom number
    Custom
}

/// CPU target mode for architecture-specific optimizations
enum RustCpuTarget
{
    Generic,        // Target default CPU
    Native,         // -C target-cpu=native
    Custom          // Custom -C target-cpu=X
}

/// PGO mode for Rust
enum RustPgoMode
{
    Off,            // No PGO
    Generate,       // -C profile-generate
    Use             // -C profile-use
}

/// Rust optimization preset
enum RustOptPreset
{
    None,           // Manual configuration
    Dev,            // Fast compile, debug info
    Release,        // Standard release (opt-level=3)
    ReleaseFast,    // Max speed (native CPU, LTO thin)
    ReleaseLto,     // Max optimization (LTO fat, single codegen)
    ReleaseSmall,   // Min size (opt-level=z, LTO)
    ProfileGen,     // Generate PGO profile
    ProfileUse      // Use PGO profile + LTO
}

/// Advanced Rust optimization configuration
struct RustAdvancedOpt
{
    /// Optimization preset
    RustOptPreset preset = RustOptPreset.None;
    
    /// CPU targeting
    RustCpuTarget cpuTarget = RustCpuTarget.Generic;
    
    /// Custom target CPU (when cpuTarget == Custom)
    string targetCpu;
    
    /// Enable target features (e.g., "+avx2,+fma")
    string targetFeatures;
    
    /// PGO mode
    RustPgoMode pgo = RustPgoMode.Off;
    
    /// PGO profile directory
    string pgoProfileDir = ".pgo-data";
    
    /// Panic strategy (unwind or abort)
    string panic = "unwind";
    
    /// Enable overflow checks (false for max perf)
    bool overflowChecks = true;
    
    /// Strip symbols (none, debuginfo, symbols)
    string strip = "none";
    
    /// Embed bitcode for LTO
    bool embedBitcode = true;
    
    /// Split debug info
    bool splitDebuginfo = false;
    
    /// Remap path prefix for reproducible builds
    string remapPathPrefix;
    
    /// Enable inline assembly optimization
    bool inlineAsm = true;
    
    /// Force frame pointers (for profiling)
    bool forceFramePointers = false;
    
    /// Linker plugin LTO (cross-language LTO)
    bool linkerPluginLto = false;
    
    /// Convert RUSTFLAGS based on config
    string[] toRustcFlags() const pure
    {
        string[] flags;
        
        // CPU targeting
        final switch (cpuTarget) with (RustCpuTarget)
        {
            case Generic: break;
            case Native:
                flags ~= "-C target-cpu=native";
                break;
            case Custom:
                if (targetCpu.length)
                    flags ~= "-C target-cpu=" ~ targetCpu;
                break;
        }
        
        // Target features
        if (targetFeatures.length)
            flags ~= "-C target-feature=" ~ targetFeatures;
        
        // PGO
        final switch (pgo) with (RustPgoMode)
        {
            case Off: break;
            case Generate:
                flags ~= "-C profile-generate=" ~ pgoProfileDir;
                break;
            case Use:
                flags ~= "-C profile-use=" ~ pgoProfileDir ~ "/merged.profdata";
                break;
        }
        
        // Panic strategy
        if (panic == "abort")
            flags ~= "-C panic=abort";
        
        // Overflow checks
        if (!overflowChecks)
            flags ~= "-C overflow-checks=no";
        
        // Strip
        if (strip != "none")
            flags ~= "-C strip=" ~ strip;
        
        // Embed bitcode
        if (!embedBitcode)
            flags ~= "-C embed-bitcode=no";
        
        // Split debuginfo
        if (splitDebuginfo)
            flags ~= "-C split-debuginfo=packed";
        
        // Remap path
        if (remapPathPrefix.length)
            flags ~= "--remap-path-prefix=" ~ remapPathPrefix;
        
        // Force frame pointers
        if (forceFramePointers)
            flags ~= "-C force-frame-pointers=yes";
        
        // Linker plugin LTO
        if (linkerPluginLto)
            flags ~= "-C linker-plugin-lto";
        
        return flags;
    }
    
    /// Apply preset
    static RustAdvancedOpt fromPreset(RustOptPreset preset) pure
    {
        RustAdvancedOpt cfg;
        cfg.preset = preset;
        
        final switch (preset) with (RustOptPreset)
        {
            case None: break;
            case Dev:
                cfg.overflowChecks = true;
                break;
            case Release:
                cfg.panic = "unwind";
                break;
            case ReleaseFast:
                cfg.cpuTarget = RustCpuTarget.Native;
                cfg.panic = "abort";
                cfg.overflowChecks = false;
                cfg.strip = "symbols";
                break;
            case ReleaseLto:
                cfg.cpuTarget = RustCpuTarget.Native;
                cfg.panic = "abort";
                cfg.overflowChecks = false;
                cfg.strip = "symbols";
                cfg.embedBitcode = true;
                break;
            case ReleaseSmall:
                cfg.panic = "abort";
                cfg.strip = "symbols";
                break;
            case ProfileGen:
                cfg.pgo = RustPgoMode.Generate;
                break;
            case ProfileUse:
                cfg.pgo = RustPgoMode.Use;
                cfg.cpuTarget = RustCpuTarget.Native;
                cfg.panic = "abort";
                cfg.overflowChecks = false;
                break;
        }
        
        return cfg;
    }
}

/// Rust-specific configuration
struct RustConfig
{
    /// Build mode
    RustBuildMode mode = RustBuildMode.Compile;
    
    /// Compiler selection
    RustCompiler compiler = RustCompiler.Auto;
    
    /// Build profile
    RustProfile profile = RustProfile.Release;
    
    /// Custom profile name (when profile = Custom)
    string customProfile;
    
    /// Rust edition
    RustEdition edition = RustEdition.Edition2021;
    
    /// Crate type
    CrateType crateType = CrateType.Bin;
    
    /// Entry point (main.rs or lib.rs)
    string entry;
    
    /// Output directory (target/)
    string targetDir;
    
    /// Optimization level
    OptLevel optLevel = OptLevel.O3;
    
    /// Enable LTO
    LtoMode lto = LtoMode.Off;
    
    /// Code generation units
    Codegen codegen = Codegen.Default;
    
    /// Custom codegen units (when codegen = Custom)
    size_t codegenUnits = 16;
    
    /// Enable debug info
    bool debugInfo = false;
    
    /// Enable incremental compilation
    bool incremental = true;
    
    /// Target triple for cross-compilation
    string target;
    
    /// Features to enable
    string[] features;
    
    /// Enable all features
    bool allFeatures = false;
    
    /// Disable default features
    bool noDefaultFeatures = false;
    
    /// Package to build (in workspace)
    string package_;
    
    /// Build all packages in workspace
    bool workspace = false;
    
    /// Exclude packages from workspace build
    string[] exclude;
    
    /// Path to Cargo.toml
    string manifest;
    
    /// Build for release
    bool release = true;
    
    /// Number of parallel jobs
    size_t jobs = 0; // 0 = auto
    
    /// Keep going after first error
    bool keepGoing = false;
    
    /// Verbosity level (0-3)
    size_t verbose = 0;
    
    /// Use color in output
    string color = "auto"; // auto, always, never
    
    /// Frozen lockfile
    bool frozen = false;
    
    /// Locked lockfile
    bool locked = false;
    
    /// Offline mode
    bool offline = false;
    
    /// Additional rustc flags
    string[] rustcFlags;
    
    /// Additional cargo flags
    string[] cargoFlags;
    
    /// Environment variables
    string[string] env;
    
    /// Run clippy (linter)
    bool clippy = false;
    
    /// Clippy options
    string[] clippyFlags;
    
    /// Run rustfmt (formatter)
    bool fmt = false;
    
    /// Generate documentation
    bool doc = false;
    
    /// Open documentation in browser
    bool docOpen = false;
    
    /// Build dependencies only
    bool buildDeps = false;
    
    /// Specific binary to build
    string bin;
    
    /// Specific example to build
    string example;
    
    /// Specific test to run
    string test;
    
    /// Specific benchmark to run
    string bench;
    
    /// Test options
    string[] testFlags;
    
    /// Benchmark options
    string[] benchFlags;
    
    /// Use specific toolchain
    string toolchain;
    
    /// Install toolchain if missing
    bool installToolchain = false;
    
    /// Use cargo-expand for macro expansion
    bool expand = false;
    
    /// Use cargo-tree for dependency tree
    bool tree = false;
    
    /// Output format for cargo-tree
    string treeFormat;
    
    /// Path mappings for remapping
    string[string] remap;
    
    /// Advanced optimization settings
    RustAdvancedOpt advancedOpt;
    
    /// Parse from JSON
    static RustConfig fromJSON(JSONValue json)
    {
        RustConfig config;
        
        // Mode
        if ("mode" in json)
        {
            string modeStr = json["mode"].str.toLower;
            switch (modeStr)
            {
                case "compile": config.mode = RustBuildMode.Compile; break;
                case "check": config.mode = RustBuildMode.Check; break;
                case "test": config.mode = RustBuildMode.Test; break;
                case "doc": config.mode = RustBuildMode.Doc; break;
                case "bench": config.mode = RustBuildMode.Bench; break;
                case "example": config.mode = RustBuildMode.Example; break;
                case "custom": config.mode = RustBuildMode.Custom; break;
                default: config.mode = RustBuildMode.Compile; break;
            }
        }
        
        // Compiler
        if ("compiler" in json)
        {
            string compilerStr = json["compiler"].str.toLower;
            switch (compilerStr)
            {
                case "auto": config.compiler = RustCompiler.Auto; break;
                case "cargo": config.compiler = RustCompiler.Cargo; break;
                case "rustc": config.compiler = RustCompiler.Rustc; break;
                default: config.compiler = RustCompiler.Auto; break;
            }
        }
        
        // Profile
        if ("profile" in json)
        {
            string profileStr = json["profile"].str.toLower;
            switch (profileStr)
            {
                case "dev": case "debug": config.profile = RustProfile.Dev; break;
                case "release": config.profile = RustProfile.Release; break;
                case "test": config.profile = RustProfile.Test; break;
                case "bench": config.profile = RustProfile.Bench; break;
                case "custom": config.profile = RustProfile.Custom; break;
                default: config.profile = RustProfile.Release; break;
            }
        }
        
        // Edition
        if ("edition" in json)
        {
            string editionStr = json["edition"].str;
            switch (editionStr)
            {
                case "2015": config.edition = RustEdition.Edition2015; break;
                case "2018": config.edition = RustEdition.Edition2018; break;
                case "2021": config.edition = RustEdition.Edition2021; break;
                case "2024": config.edition = RustEdition.Edition2024; break;
                default: config.edition = RustEdition.Edition2021; break;
            }
        }
        
        // Crate type
        if ("crateType" in json || "crate_type" in json)
        {
            string key = "crateType" in json ? "crateType" : "crate_type";
            string typeStr = json[key].str.toLower;
            switch (typeStr)
            {
                case "bin": config.crateType = CrateType.Bin; break;
                case "lib": config.crateType = CrateType.Lib; break;
                case "rlib": config.crateType = CrateType.Rlib; break;
                case "dylib": config.crateType = CrateType.Dylib; break;
                case "cdylib": config.crateType = CrateType.Cdylib; break;
                case "staticlib": config.crateType = CrateType.Staticlib; break;
                case "proc-macro": case "proc_macro": config.crateType = CrateType.ProcMacro; break;
                default: config.crateType = CrateType.Bin; break;
            }
        }
        
        // Optimization level
        if ("optLevel" in json || "opt_level" in json)
        {
            string key = "optLevel" in json ? "optLevel" : "opt_level";
            string optStr = json[key].str.toLower;
            switch (optStr)
            {
                case "0": case "o0": config.optLevel = OptLevel.O0; break;
                case "1": case "o1": config.optLevel = OptLevel.O1; break;
                case "2": case "o2": config.optLevel = OptLevel.O2; break;
                case "3": case "o3": config.optLevel = OptLevel.O3; break;
                case "s": case "os": config.optLevel = OptLevel.Os; break;
                case "z": case "oz": config.optLevel = OptLevel.Oz; break;
                default: config.optLevel = OptLevel.O3; break;
            }
        }
        
        // LTO
        if ("lto" in json)
        {
            string ltoStr = json["lto"].str.toLower;
            switch (ltoStr)
            {
                case "off": case "false": case "no": config.lto = LtoMode.Off; break;
                case "thin": config.lto = LtoMode.Thin; break;
                case "fat": case "true": case "yes": config.lto = LtoMode.Fat; break;
                default: config.lto = LtoMode.Off; break;
            }
        }
        
        // String fields
        if ("entry" in json) config.entry = json["entry"].str;
        if ("targetDir" in json || "target_dir" in json)
        {
            string key = "targetDir" in json ? "targetDir" : "target_dir";
            config.targetDir = json[key].str;
        }
        if ("customProfile" in json || "custom_profile" in json)
        {
            string key = "customProfile" in json ? "customProfile" : "custom_profile";
            config.customProfile = json[key].str;
        }
        if ("target" in json) config.target = json["target"].str;
        if ("package" in json) config.package_ = json["package"].str;
        if ("manifest" in json) config.manifest = json["manifest"].str;
        if ("color" in json) config.color = json["color"].str;
        if ("bin" in json) config.bin = json["bin"].str;
        if ("example" in json) config.example = json["example"].str;
        if ("test" in json) config.test = json["test"].str;
        if ("bench" in json) config.bench = json["bench"].str;
        if ("toolchain" in json) config.toolchain = json["toolchain"].str;
        if ("treeFormat" in json || "tree_format" in json)
        {
            string key = "treeFormat" in json ? "treeFormat" : "tree_format";
            config.treeFormat = json[key].str;
        }
        
        // Codegen
        if ("codegen" in json)
        {
            auto cg = json["codegen"];
            if (cg.type == JSONType.string)
            {
                string cgStr = cg.str.toLower;
                if (cgStr == "single" || cgStr == "1")
                    config.codegen = Codegen.Single;
            }
            else if (cg.type == JSONType.integer)
            {
                config.codegen = Codegen.Custom;
                config.codegenUnits = cg.integer.to!size_t;
            }
        }
        if ("codegenUnits" in json || "codegen_units" in json)
        {
            string key = "codegenUnits" in json ? "codegenUnits" : "codegen_units";
            config.codegenUnits = json[key].integer.to!size_t;
            if (config.codegen == Codegen.Default)
                config.codegen = Codegen.Custom;
        }
        
        // Numeric fields
        if ("jobs" in json) config.jobs = json["jobs"].integer.to!size_t;
        if ("verbose" in json) config.verbose = json["verbose"].integer.to!size_t;
        
        // Boolean fields
        if ("debugInfo" in json || "debug_info" in json)
        {
            string key = "debugInfo" in json ? "debugInfo" : "debug_info";
            config.debugInfo = json[key].type == JSONType.true_;
        }
        if ("incremental" in json) config.incremental = json["incremental"].type == JSONType.true_;
        if ("allFeatures" in json || "all_features" in json)
        {
            string key = "allFeatures" in json ? "allFeatures" : "all_features";
            config.allFeatures = json[key].type == JSONType.true_;
        }
        if ("noDefaultFeatures" in json || "no_default_features" in json)
        {
            string key = "noDefaultFeatures" in json ? "noDefaultFeatures" : "no_default_features";
            config.noDefaultFeatures = json[key].type == JSONType.true_;
        }
        if ("workspace" in json) config.workspace = json["workspace"].type == JSONType.true_;
        if ("release" in json) config.release = json["release"].type == JSONType.true_;
        if ("keepGoing" in json || "keep_going" in json)
        {
            string key = "keepGoing" in json ? "keepGoing" : "keep_going";
            config.keepGoing = json[key].type == JSONType.true_;
        }
        if ("frozen" in json) config.frozen = json["frozen"].type == JSONType.true_;
        if ("locked" in json) config.locked = json["locked"].type == JSONType.true_;
        if ("offline" in json) config.offline = json["offline"].type == JSONType.true_;
        if ("clippy" in json) config.clippy = json["clippy"].type == JSONType.true_;
        if ("fmt" in json) config.fmt = json["fmt"].type == JSONType.true_;
        if ("doc" in json) config.doc = json["doc"].type == JSONType.true_;
        if ("docOpen" in json || "doc_open" in json)
        {
            string key = "docOpen" in json ? "docOpen" : "doc_open";
            config.docOpen = json[key].type == JSONType.true_;
        }
        if ("buildDeps" in json || "build_deps" in json)
        {
            string key = "buildDeps" in json ? "buildDeps" : "build_deps";
            config.buildDeps = json[key].type == JSONType.true_;
        }
        if ("installToolchain" in json || "install_toolchain" in json)
        {
            string key = "installToolchain" in json ? "installToolchain" : "install_toolchain";
            config.installToolchain = json[key].type == JSONType.true_;
        }
        if ("expand" in json) config.expand = json["expand"].type == JSONType.true_;
        if ("tree" in json) config.tree = json["tree"].type == JSONType.true_;
        
        // Array fields
        if ("features" in json)
            config.features = json["features"].array.map!(e => e.str).array;
        if ("exclude" in json)
            config.exclude = json["exclude"].array.map!(e => e.str).array;
        if ("rustcFlags" in json || "rustc_flags" in json)
        {
            string key = "rustcFlags" in json ? "rustcFlags" : "rustc_flags";
            config.rustcFlags = json[key].array.map!(e => e.str).array;
        }
        if ("cargoFlags" in json || "cargo_flags" in json)
        {
            string key = "cargoFlags" in json ? "cargoFlags" : "cargo_flags";
            config.cargoFlags = json[key].array.map!(e => e.str).array;
        }
        if ("clippyFlags" in json || "clippy_flags" in json)
        {
            string key = "clippyFlags" in json ? "clippyFlags" : "clippy_flags";
            config.clippyFlags = json[key].array.map!(e => e.str).array;
        }
        if ("testFlags" in json || "test_flags" in json)
        {
            string key = "testFlags" in json ? "testFlags" : "test_flags";
            config.testFlags = json[key].array.map!(e => e.str).array;
        }
        if ("benchFlags" in json || "bench_flags" in json)
        {
            string key = "benchFlags" in json ? "benchFlags" : "bench_flags";
            config.benchFlags = json[key].array.map!(e => e.str).array;
        }
        
        // Map fields
        if ("env" in json)
        {
            foreach (string key, value; json["env"].object)
            {
                config.env[key] = value.str;
            }
        }
        if ("remap" in json)
        {
            foreach (string key, value; json["remap"].object)
            {
                config.remap[key] = value.str;
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
                    case "dev": case "debug": config.advancedOpt = RustAdvancedOpt.fromPreset(RustOptPreset.Dev); break;
                    case "release": config.advancedOpt = RustAdvancedOpt.fromPreset(RustOptPreset.Release); break;
                    case "releasefast": config.advancedOpt = RustAdvancedOpt.fromPreset(RustOptPreset.ReleaseFast); break;
                    case "releaselto": config.advancedOpt = RustAdvancedOpt.fromPreset(RustOptPreset.ReleaseLto); break;
                    case "releasesmall": config.advancedOpt = RustAdvancedOpt.fromPreset(RustOptPreset.ReleaseSmall); break;
                    case "profilegen": config.advancedOpt = RustAdvancedOpt.fromPreset(RustOptPreset.ProfileGen); break;
                    case "profileuse": config.advancedOpt = RustAdvancedOpt.fromPreset(RustOptPreset.ProfileUse); break;
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
                    case "generic": config.advancedOpt.cpuTarget = RustCpuTarget.Generic; break;
                    case "native": config.advancedOpt.cpuTarget = RustCpuTarget.Native; break;
                    case "custom": config.advancedOpt.cpuTarget = RustCpuTarget.Custom; break;
                    default: break;
                }
            }
            if ("targetCpu" in optObj || "target_cpu" in optObj)
            {
                string tcKey = "targetCpu" in optObj ? "targetCpu" : "target_cpu";
                config.advancedOpt.targetCpu = optObj[tcKey].str;
            }
            if ("targetFeatures" in optObj || "target_features" in optObj)
            {
                string tfKey = "targetFeatures" in optObj ? "targetFeatures" : "target_features";
                config.advancedOpt.targetFeatures = optObj[tfKey].str;
            }
            
            // PGO
            if ("pgo" in optObj)
            {
                string pgoStr = optObj["pgo"].str.toLower;
                switch (pgoStr)
                {
                    case "off": config.advancedOpt.pgo = RustPgoMode.Off; break;
                    case "generate": case "gen": config.advancedOpt.pgo = RustPgoMode.Generate; break;
                    case "use": config.advancedOpt.pgo = RustPgoMode.Use; break;
                    default: break;
                }
            }
            if ("pgoProfileDir" in optObj || "pgo_profile_dir" in optObj)
            {
                string pdKey = "pgoProfileDir" in optObj ? "pgoProfileDir" : "pgo_profile_dir";
                config.advancedOpt.pgoProfileDir = optObj[pdKey].str;
            }
            
            // String fields
            if ("panic" in optObj) config.advancedOpt.panic = optObj["panic"].str;
            if ("strip" in optObj) config.advancedOpt.strip = optObj["strip"].str;
            if ("remapPathPrefix" in optObj || "remap_path_prefix" in optObj)
            {
                string rpKey = "remapPathPrefix" in optObj ? "remapPathPrefix" : "remap_path_prefix";
                config.advancedOpt.remapPathPrefix = optObj[rpKey].str;
            }
            
            // Boolean fields
            if ("overflowChecks" in optObj || "overflow_checks" in optObj)
            {
                string ocKey = "overflowChecks" in optObj ? "overflowChecks" : "overflow_checks";
                config.advancedOpt.overflowChecks = optObj[ocKey].type == JSONType.true_;
            }
            if ("embedBitcode" in optObj || "embed_bitcode" in optObj)
            {
                string ebKey = "embedBitcode" in optObj ? "embedBitcode" : "embed_bitcode";
                config.advancedOpt.embedBitcode = optObj[ebKey].type == JSONType.true_;
            }
            if ("splitDebuginfo" in optObj || "split_debuginfo" in optObj)
            {
                string sdKey = "splitDebuginfo" in optObj ? "splitDebuginfo" : "split_debuginfo";
                config.advancedOpt.splitDebuginfo = optObj[sdKey].type == JSONType.true_;
            }
            if ("forceFramePointers" in optObj || "force_frame_pointers" in optObj)
            {
                string ffpKey = "forceFramePointers" in optObj ? "forceFramePointers" : "force_frame_pointers";
                config.advancedOpt.forceFramePointers = optObj[ffpKey].type == JSONType.true_;
            }
            if ("linkerPluginLto" in optObj || "linker_plugin_lto" in optObj)
            {
                string lplKey = "linkerPluginLto" in optObj ? "linkerPluginLto" : "linker_plugin_lto";
                config.advancedOpt.linkerPluginLto = optObj[lplKey].type == JSONType.true_;
            }
        }
        
        return config;
    }
}

/// Rust compilation result
struct RustCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string[] artifacts; // Additional artifacts (libs, etc.)
    string outputHash;
    bool hadWarnings;
    string[] warnings;
    bool hadClippyIssues;
    string[] clippyIssues;
}


