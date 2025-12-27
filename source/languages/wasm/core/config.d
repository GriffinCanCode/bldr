module languages.wasm.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// WASM/WASI runtime environment
enum WasmRuntime
{
    Auto,       /// Auto-detect available runtime
    Wasmtime,   /// Wasmtime (Bytecode Alliance)
    Wasmer,     /// Wasmer runtime
    Wasm3,      /// Wasm3 interpreter
    Node,       /// Node.js WASM runtime
    Browser,    /// Browser environment (via emrun/serve)
    Native      /// Native execution (WASI only)
}

/// Source language for WASM compilation
enum WasmSourceLang
{
    Auto,       /// Auto-detect from source
    Rust,       /// Rust via wasm-pack/cargo
    C,          /// C via Emscripten/clang
    Cpp,        /// C++ via Emscripten/clang
    Go,         /// Go via TinyGo
    Zig,        /// Zig native WASM support
    AssemblyScript, /// AssemblyScript (TS subset)
    Wat,        /// WebAssembly Text Format
    Wasm        /// Precompiled WASM binary
}

/// WASM toolchain selection
enum WasmToolchain
{
    Auto,       /// Auto-detect best toolchain
    WasmPack,   /// wasm-pack (Rust)
    Emscripten, /// Emscripten (C/C++)
    Clang,      /// Clang with WASM target
    TinyGo,     /// TinyGo (Go)
    Zig,        /// Zig compiler
    AssemblyScript, /// asc compiler
    Wat2Wasm    /// wat2wasm from wabt
}

/// WASM optimization level
enum WasmOptLevel
{
    None,       /// No optimization (debug)
    O1,         /// Basic optimization
    O2,         /// Standard optimization
    O3,         /// Aggressive optimization
    Os,         /// Optimize for size
    Oz          /// Aggressively optimize for size
}

/// WASI capability/permission
enum WasiCapability
{
    FileRead,   /// Read files from host
    FileWrite,  /// Write files to host
    Stdout,     /// Standard output
    Stderr,     /// Standard error
    Stdin,      /// Standard input
    Network,    /// Network access (experimental)
    Env,        /// Environment variables
    Args,       /// Command line arguments
    Clock,      /// Clock/time access
    Random      /// Random number generation
}

/// WASI directory mapping
struct WasiDirMapping
{
    string guest;   /// Path in WASM module
    string host;    /// Path on host filesystem
    bool readonly;  /// Mount as read-only
}

/// WASI configuration
struct WasiConfig
{
    bool enabled = true;                    /// Enable WASI
    WasiCapability[] capabilities;          /// Enabled capabilities
    WasiDirMapping[] dirMappings;          /// Directory mappings (preopens)
    string[string] envVars;                /// Environment variables to pass
    string[] args;                         /// Arguments to pass
    size_t maxMemoryMB = 256;              /// Max memory in MB
    bool inheritStdio = true;              /// Inherit stdio from host
}

/// WASM memory configuration
struct WasmMemoryConfig
{
    size_t initialPages = 256;   /// Initial memory (pages * 64KB)
    size_t maxPages = 4096;      /// Maximum memory (pages * 64KB)
    bool shared_ = false;        /// Enable shared memory
    bool memory64 = false;       /// Enable memory64 proposal
}

/// WASM feature flags (proposals)
struct WasmFeatures
{
    bool simd = false;           /// SIMD support
    bool threads = false;        /// Threading support
    bool multiValue = true;      /// Multi-value returns
    bool bulkMemory = true;      /// Bulk memory operations
    bool referenceTypes = false; /// Reference types
    bool tailCall = false;       /// Tail call optimization
    bool exceptions = false;     /// Exception handling
    bool gc = false;             /// Garbage collection
    bool memory64 = false;       /// 64-bit memory
    bool relaxedSimd = false;    /// Relaxed SIMD
    bool componentModel = false; /// Component model (wit-bindgen)
}

/// WebAssembly build configuration
struct WasmConfig
{
    /// Source language
    WasmSourceLang sourceLang = WasmSourceLang.Auto;
    
    /// Toolchain selection
    WasmToolchain toolchain = WasmToolchain.Auto;
    
    /// Runtime for execution
    WasmRuntime runtime = WasmRuntime.Auto;
    
    /// Optimization level
    WasmOptLevel optimize = WasmOptLevel.O2;
    
    /// Output file name (without extension)
    string outputName;
    
    /// Output directory
    string outputDir = "wasm-out";
    
    /// Entry function (default: _start for WASI, main for browser)
    string entryPoint;
    
    /// Export all functions (not just main/start)
    bool exportAll = false;
    
    /// Generate source maps
    bool sourceMaps = false;
    
    /// Strip debug info
    bool strip = false;
    
    /// Enable LTO
    bool lto = false;
    
    /// Memory configuration
    WasmMemoryConfig memory;
    
    /// Feature flags
    WasmFeatures features;
    
    /// WASI configuration
    WasiConfig wasi;
    
    /// Additional compiler flags
    string[] compilerFlags;
    
    /// Additional linker flags
    string[] linkerFlags;
    
    /// Import bindings file (wit/interface)
    string bindingsFile;
    
    /// Generate JavaScript glue code
    bool jsGlue = false;
    
    /// JavaScript glue output path
    string jsGluePath;
    
    /// Bundle as ES module
    bool esModule = true;
    
    /// Enable async instantiation
    bool async = true;
    
    /// Environment variables
    string[string] env;
    
    /// Parse from JSON
    static WasmConfig fromJSON(JSONValue json)
    {
        WasmConfig config;
        
        // Source language
        if ("sourceLang" in json || "source_lang" in json || "source" in json)
        {
            string key = "sourceLang" in json ? "sourceLang" : 
                        ("source_lang" in json ? "source_lang" : "source");
            string srcStr = json[key].str.toLower;
            switch (srcStr)
            {
                case "auto": config.sourceLang = WasmSourceLang.Auto; break;
                case "rust", "rs": config.sourceLang = WasmSourceLang.Rust; break;
                case "c": config.sourceLang = WasmSourceLang.C; break;
                case "cpp", "c++", "cxx": config.sourceLang = WasmSourceLang.Cpp; break;
                case "go", "tinygo": config.sourceLang = WasmSourceLang.Go; break;
                case "zig": config.sourceLang = WasmSourceLang.Zig; break;
                case "assemblyscript", "as", "asc": config.sourceLang = WasmSourceLang.AssemblyScript; break;
                case "wat", "wast": config.sourceLang = WasmSourceLang.Wat; break;
                case "wasm": config.sourceLang = WasmSourceLang.Wasm; break;
                default: break;
            }
        }
        
        // Toolchain
        if ("toolchain" in json)
        {
            string tcStr = json["toolchain"].str.toLower;
            switch (tcStr)
            {
                case "auto": config.toolchain = WasmToolchain.Auto; break;
                case "wasm-pack", "wasmpack": config.toolchain = WasmToolchain.WasmPack; break;
                case "emscripten", "emcc": config.toolchain = WasmToolchain.Emscripten; break;
                case "clang": config.toolchain = WasmToolchain.Clang; break;
                case "tinygo": config.toolchain = WasmToolchain.TinyGo; break;
                case "zig": config.toolchain = WasmToolchain.Zig; break;
                case "assemblyscript", "asc": config.toolchain = WasmToolchain.AssemblyScript; break;
                case "wat2wasm", "wabt": config.toolchain = WasmToolchain.Wat2Wasm; break;
                default: break;
            }
        }
        
        // Runtime
        if ("runtime" in json)
        {
            string rtStr = json["runtime"].str.toLower;
            switch (rtStr)
            {
                case "auto": config.runtime = WasmRuntime.Auto; break;
                case "wasmtime": config.runtime = WasmRuntime.Wasmtime; break;
                case "wasmer": config.runtime = WasmRuntime.Wasmer; break;
                case "wasm3": config.runtime = WasmRuntime.Wasm3; break;
                case "node", "nodejs": config.runtime = WasmRuntime.Node; break;
                case "browser", "web": config.runtime = WasmRuntime.Browser; break;
                case "native": config.runtime = WasmRuntime.Native; break;
                default: break;
            }
        }
        
        // Optimization
        if ("optimize" in json || "opt" in json)
        {
            string key = "optimize" in json ? "optimize" : "opt";
            auto optVal = json[key];
            if (optVal.type == JSONType.string)
            {
                string optStr = optVal.str.toLower;
                switch (optStr)
                {
                    case "none", "0", "debug": config.optimize = WasmOptLevel.None; break;
                    case "1", "o1": config.optimize = WasmOptLevel.O1; break;
                    case "2", "o2": config.optimize = WasmOptLevel.O2; break;
                    case "3", "o3": config.optimize = WasmOptLevel.O3; break;
                    case "s", "os", "size": config.optimize = WasmOptLevel.Os; break;
                    case "z", "oz", "minsize": config.optimize = WasmOptLevel.Oz; break;
                    default: break;
                }
            }
        }
        
        // String fields
        if ("outputName" in json || "output_name" in json || "name" in json)
        {
            string key = "outputName" in json ? "outputName" : 
                        ("output_name" in json ? "output_name" : "name");
            config.outputName = json[key].str;
        }
        if ("outputDir" in json || "output_dir" in json || "outdir" in json)
        {
            string key = "outputDir" in json ? "outputDir" : 
                        ("output_dir" in json ? "output_dir" : "outdir");
            config.outputDir = json[key].str;
        }
        if ("entryPoint" in json || "entry_point" in json || "entry" in json)
        {
            string key = "entryPoint" in json ? "entryPoint" : 
                        ("entry_point" in json ? "entry_point" : "entry");
            config.entryPoint = json[key].str;
        }
        if ("bindingsFile" in json || "bindings_file" in json || "bindings" in json)
        {
            string key = "bindingsFile" in json ? "bindingsFile" : 
                        ("bindings_file" in json ? "bindings_file" : "bindings");
            config.bindingsFile = json[key].str;
        }
        if ("jsGluePath" in json || "js_glue_path" in json)
        {
            string key = "jsGluePath" in json ? "jsGluePath" : "js_glue_path";
            config.jsGluePath = json[key].str;
        }
        
        // Boolean fields
        if ("exportAll" in json || "export_all" in json)
        {
            string key = "exportAll" in json ? "exportAll" : "export_all";
            config.exportAll = json[key].type == JSONType.true_;
        }
        if ("sourceMaps" in json || "source_maps" in json)
        {
            string key = "sourceMaps" in json ? "sourceMaps" : "source_maps";
            config.sourceMaps = json[key].type == JSONType.true_;
        }
        if ("strip" in json)
            config.strip = json["strip"].type == JSONType.true_;
        if ("lto" in json)
            config.lto = json["lto"].type == JSONType.true_;
        if ("jsGlue" in json || "js_glue" in json)
        {
            string key = "jsGlue" in json ? "jsGlue" : "js_glue";
            config.jsGlue = json[key].type == JSONType.true_;
        }
        if ("esModule" in json || "es_module" in json)
        {
            string key = "esModule" in json ? "esModule" : "es_module";
            config.esModule = json[key].type == JSONType.true_;
        }
        if ("async" in json)
            config.async = json["async"].type == JSONType.true_;
        
        // Memory configuration
        if ("memory" in json)
        {
            auto mem = json["memory"];
            if ("initialPages" in mem || "initial_pages" in mem || "initial" in mem)
            {
                string key = "initialPages" in mem ? "initialPages" : 
                            ("initial_pages" in mem ? "initial_pages" : "initial");
                config.memory.initialPages = mem[key].integer.to!size_t;
            }
            if ("maxPages" in mem || "max_pages" in mem || "max" in mem)
            {
                string key = "maxPages" in mem ? "maxPages" : 
                            ("max_pages" in mem ? "max_pages" : "max");
                config.memory.maxPages = mem[key].integer.to!size_t;
            }
            if ("shared" in mem)
                config.memory.shared_ = mem["shared"].type == JSONType.true_;
            if ("memory64" in mem)
                config.memory.memory64 = mem["memory64"].type == JSONType.true_;
        }
        
        // Features configuration
        if ("features" in json)
        {
            auto feat = json["features"];
            if ("simd" in feat)
                config.features.simd = feat["simd"].type == JSONType.true_;
            if ("threads" in feat)
                config.features.threads = feat["threads"].type == JSONType.true_;
            if ("multiValue" in feat || "multi_value" in feat)
            {
                string key = "multiValue" in feat ? "multiValue" : "multi_value";
                config.features.multiValue = feat[key].type == JSONType.true_;
            }
            if ("bulkMemory" in feat || "bulk_memory" in feat)
            {
                string key = "bulkMemory" in feat ? "bulkMemory" : "bulk_memory";
                config.features.bulkMemory = feat[key].type == JSONType.true_;
            }
            if ("referenceTypes" in feat || "reference_types" in feat)
            {
                string key = "referenceTypes" in feat ? "referenceTypes" : "reference_types";
                config.features.referenceTypes = feat[key].type == JSONType.true_;
            }
            if ("tailCall" in feat || "tail_call" in feat)
            {
                string key = "tailCall" in feat ? "tailCall" : "tail_call";
                config.features.tailCall = feat[key].type == JSONType.true_;
            }
            if ("exceptions" in feat)
                config.features.exceptions = feat["exceptions"].type == JSONType.true_;
            if ("gc" in feat)
                config.features.gc = feat["gc"].type == JSONType.true_;
            if ("memory64" in feat)
                config.features.memory64 = feat["memory64"].type == JSONType.true_;
            if ("relaxedSimd" in feat || "relaxed_simd" in feat)
            {
                string key = "relaxedSimd" in feat ? "relaxedSimd" : "relaxed_simd";
                config.features.relaxedSimd = feat[key].type == JSONType.true_;
            }
            if ("componentModel" in feat || "component_model" in feat)
            {
                string key = "componentModel" in feat ? "componentModel" : "component_model";
                config.features.componentModel = feat[key].type == JSONType.true_;
            }
        }
        
        // WASI configuration
        if ("wasi" in json)
        {
            auto w = json["wasi"];
            if ("enabled" in w)
                config.wasi.enabled = w["enabled"].type == JSONType.true_;
            if ("maxMemoryMB" in w || "max_memory_mb" in w || "maxMemory" in w)
            {
                string key = "maxMemoryMB" in w ? "maxMemoryMB" : 
                            ("max_memory_mb" in w ? "max_memory_mb" : "maxMemory");
                config.wasi.maxMemoryMB = w[key].integer.to!size_t;
            }
            if ("inheritStdio" in w || "inherit_stdio" in w)
            {
                string key = "inheritStdio" in w ? "inheritStdio" : "inherit_stdio";
                config.wasi.inheritStdio = w[key].type == JSONType.true_;
            }
            if ("capabilities" in w)
            {
                foreach (cap; w["capabilities"].array)
                {
                    string capStr = cap.str.toLower;
                    switch (capStr)
                    {
                        case "fileread", "file_read", "read": 
                            config.wasi.capabilities ~= WasiCapability.FileRead; break;
                        case "filewrite", "file_write", "write": 
                            config.wasi.capabilities ~= WasiCapability.FileWrite; break;
                        case "stdout": config.wasi.capabilities ~= WasiCapability.Stdout; break;
                        case "stderr": config.wasi.capabilities ~= WasiCapability.Stderr; break;
                        case "stdin": config.wasi.capabilities ~= WasiCapability.Stdin; break;
                        case "network", "net": 
                            config.wasi.capabilities ~= WasiCapability.Network; break;
                        case "env": config.wasi.capabilities ~= WasiCapability.Env; break;
                        case "args": config.wasi.capabilities ~= WasiCapability.Args; break;
                        case "clock", "time": 
                            config.wasi.capabilities ~= WasiCapability.Clock; break;
                        case "random": config.wasi.capabilities ~= WasiCapability.Random; break;
                        default: break;
                    }
                }
            }
            if ("dirs" in w || "dirMappings" in w || "preopens" in w)
            {
                string key = "dirs" in w ? "dirs" : 
                            ("dirMappings" in w ? "dirMappings" : "preopens");
                foreach (dirMap; w[key].array)
                {
                    WasiDirMapping mapping;
                    if ("guest" in dirMap) mapping.guest = dirMap["guest"].str;
                    if ("host" in dirMap) mapping.host = dirMap["host"].str;
                    if ("readonly" in dirMap) 
                        mapping.readonly = dirMap["readonly"].type == JSONType.true_;
                    config.wasi.dirMappings ~= mapping;
                }
            }
            if ("env" in w)
            {
                foreach (string key, value; w["env"].object)
                    config.wasi.envVars[key] = value.str;
            }
            if ("args" in w)
            {
                foreach (arg; w["args"].array)
                    config.wasi.args ~= arg.str;
            }
        }
        
        // Array fields
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
        
        // Environment variables
        if ("env" in json)
        {
            foreach (string key, value; json["env"].object)
                config.env[key] = value.str;
        }
        
        return config;
    }
}

/// WASM compilation result
struct WasmCompileResult
{
    bool success;
    string error;
    string[] outputs;      /// Primary output files (.wasm)
    string[] artifacts;    /// Secondary artifacts (.js, .d.ts, .wat)
    string outputHash;
    bool hadWarnings;
    string[] warnings;
    size_t wasmSizeBytes;  /// Size of compiled WASM
}


