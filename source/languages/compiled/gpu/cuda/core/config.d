module languages.compiled.gpu.cuda.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// CUDA GPU architecture targets
enum CUDAArch
{
    /// Auto-detect (uses nvcc default)
    Auto,
    /// Kepler (GTX 6xx, 7xx)
    SM_30, SM_35, SM_37,
    /// Maxwell (GTX 9xx)
    SM_50, SM_52, SM_53,
    /// Pascal (GTX 10xx)
    SM_60, SM_61, SM_62,
    /// Volta (V100)
    SM_70, SM_72,
    /// Turing (RTX 20xx)
    SM_75,
    /// Ampere (RTX 30xx, A100)
    SM_80, SM_86, SM_87,
    /// Ada Lovelace (RTX 40xx)
    SM_89,
    /// Hopper (H100)
    SM_90, SM_90a
}

/// CUDA optimization level
enum CUDAOptLevel
{
    /// No optimization (-O0)
    O0,
    /// Basic optimization (-O1)
    O1,
    /// Medium optimization (-O2)  
    O2,
    /// Aggressive optimization (-O3)
    O3,
    /// Fast math (-use_fast_math)
    Fast
}

/// CUDA output type
enum CUDAOutputType
{
    /// Compile to object file
    Object,
    /// Compile to PTX (portable)
    PTX,
    /// Compile to cubin (device binary)
    Cubin,
    /// Compile to fatbin (multi-arch)
    Fatbin,
    /// Device-link library
    DeviceLib,
    /// Host executable with embedded kernels
    Executable,
    /// Shared library
    SharedLib,
    /// Static library
    StaticLib
}

/// CUDA compiler configuration
struct CUDAConfig
{
    /// Target GPU architectures (generate code for multiple)
    CUDAArch[] archs = [CUDAArch.Auto];
    
    /// Optimization level
    CUDAOptLevel optLevel = CUDAOptLevel.O2;
    
    /// Output type
    CUDAOutputType outputType = CUDAOutputType.Object;
    
    /// Generate debug info (-g -G)
    bool debug_ = false;
    
    /// Generate line info for profiling (-lineinfo)
    bool lineInfo = false;
    
    /// Enable relocatable device code (-rdc=true)
    bool relocatable = false;
    
    /// Use fast math (--use_fast_math)
    bool fastMath = false;
    
    /// CUDA toolkit path (auto-detect if empty)
    string cudaPath;
    
    /// Include directories
    string[] includeDirs;
    
    /// Library directories
    string[] libDirs;
    
    /// Libraries to link
    string[] libs;
    
    /// Additional nvcc flags
    string[] nvccFlags;
    
    /// Additional host compiler flags
    string[] hostFlags;
    
    /// Host compiler (auto-detect if empty)
    string hostCompiler;
    
    /// C++ standard for host code
    string cxxStd = "c++17";
    
    /// Output directory
    string outputDir = "bin";
    
    /// Object file directory
    string objDir = ".builder-cache/cuda-obj";
    
    /// Enable verbose output
    bool verbose = false;
    
    /// Maximum register count per thread (0 = auto)
    uint maxRegCount = 0;
    
    /// Generate dependency file
    bool genDeps = true;
    
    /// Parse config from JSON
    static CUDAConfig fromJSON(JSONValue json) @system
    {
        CUDAConfig config;
        
        if ("arch" in json)
        {
            config.archs = [];
            if (json["arch"].type == JSONType.array)
            {
                foreach (a; json["arch"].array)
                    config.archs ~= parseArch(a.str);
            }
            else
                config.archs = [parseArch(json["arch"].str)];
        }
        
        if ("opt" in json)
            config.optLevel = parseOpt(json["opt"].str);
        
        if ("output" in json)
            config.outputType = parseOutput(json["output"].str);
        
        if ("debug" in json)
            config.debug_ = json["debug"].boolean;
        
        if ("lineInfo" in json || "line_info" in json)
            config.lineInfo = ("lineInfo" in json) ? json["lineInfo"].boolean : json["line_info"].boolean;
        
        if ("relocatable" in json || "rdc" in json)
            config.relocatable = ("relocatable" in json) ? json["relocatable"].boolean : json["rdc"].boolean;
        
        if ("fastMath" in json || "fast_math" in json)
            config.fastMath = ("fastMath" in json) ? json["fastMath"].boolean : json["fast_math"].boolean;
        
        if ("cudaPath" in json || "cuda_path" in json)
            config.cudaPath = ("cudaPath" in json) ? json["cudaPath"].str : json["cuda_path"].str;
        
        if ("include" in json || "includes" in json)
        {
            auto inc = ("include" in json) ? json["include"] : json["includes"];
            foreach (i; inc.array)
                config.includeDirs ~= i.str;
        }
        
        if ("libDirs" in json || "lib_dirs" in json)
        {
            auto ld = ("libDirs" in json) ? json["libDirs"] : json["lib_dirs"];
            foreach (l; ld.array)
                config.libDirs ~= l.str;
        }
        
        if ("libs" in json)
        {
            foreach (l; json["libs"].array)
                config.libs ~= l.str;
        }
        
        if ("nvccFlags" in json || "nvcc_flags" in json || "flags" in json)
        {
            auto flags = ("nvccFlags" in json) ? json["nvccFlags"] : 
                        ("nvcc_flags" in json) ? json["nvcc_flags"] : json["flags"];
            foreach (f; flags.array)
                config.nvccFlags ~= f.str;
        }
        
        if ("hostFlags" in json || "host_flags" in json)
        {
            auto flags = ("hostFlags" in json) ? json["hostFlags"] : json["host_flags"];
            foreach (f; flags.array)
                config.hostFlags ~= f.str;
        }
        
        if ("hostCompiler" in json || "host_compiler" in json)
            config.hostCompiler = ("hostCompiler" in json) ? json["hostCompiler"].str : json["host_compiler"].str;
        
        if ("cxxStd" in json || "cxx_std" in json || "std" in json)
        {
            auto std = ("cxxStd" in json) ? json["cxxStd"] : 
                      ("cxx_std" in json) ? json["cxx_std"] : json["std"];
            config.cxxStd = std.str;
        }
        
        if ("outputDir" in json || "output_dir" in json)
            config.outputDir = ("outputDir" in json) ? json["outputDir"].str : json["output_dir"].str;
        
        if ("verbose" in json)
            config.verbose = json["verbose"].boolean;
        
        if ("maxRegs" in json || "max_regs" in json)
            config.maxRegCount = cast(uint)(("maxRegs" in json) ? json["maxRegs"].integer : json["max_regs"].integer);
        
        return config;
    }
    
    /// Get nvcc arch flag string (e.g., "-arch=sm_80")
    string[] getArchFlags() const pure @safe
    {
        string[] flags;
        
        foreach (arch; archs)
        {
            if (arch == CUDAArch.Auto)
                continue;  // Let nvcc auto-detect
            
            string archStr = archToString(arch);
            flags ~= "-gencode";
            flags ~= "arch=compute_" ~ archStr[3..$] ~ ",code=" ~ archStr;
        }
        
        return flags;
    }
    
    private static CUDAArch parseArch(string s) pure @safe
    {
        switch (s.toLower.replace("_", "").replace("-", ""))
        {
            case "auto": return CUDAArch.Auto;
            case "sm30": return CUDAArch.SM_30;
            case "sm35": return CUDAArch.SM_35;
            case "sm37": return CUDAArch.SM_37;
            case "sm50": return CUDAArch.SM_50;
            case "sm52": return CUDAArch.SM_52;
            case "sm53": return CUDAArch.SM_53;
            case "sm60": return CUDAArch.SM_60;
            case "sm61": return CUDAArch.SM_61;
            case "sm62": return CUDAArch.SM_62;
            case "sm70": return CUDAArch.SM_70;
            case "sm72": return CUDAArch.SM_72;
            case "sm75": return CUDAArch.SM_75;
            case "sm80": return CUDAArch.SM_80;
            case "sm86": return CUDAArch.SM_86;
            case "sm87": return CUDAArch.SM_87;
            case "sm89": return CUDAArch.SM_89;
            case "sm90": return CUDAArch.SM_90;
            case "sm90a": return CUDAArch.SM_90a;
            default: return CUDAArch.Auto;
        }
    }
    
    private static CUDAOptLevel parseOpt(string s) pure @safe
    {
        switch (s.toLower)
        {
            case "0", "o0": return CUDAOptLevel.O0;
            case "1", "o1": return CUDAOptLevel.O1;
            case "2", "o2": return CUDAOptLevel.O2;
            case "3", "o3": return CUDAOptLevel.O3;
            case "fast": return CUDAOptLevel.Fast;
            default: return CUDAOptLevel.O2;
        }
    }
    
    private static CUDAOutputType parseOutput(string s) pure @safe
    {
        switch (s.toLower)
        {
            case "object", "obj", "o": return CUDAOutputType.Object;
            case "ptx": return CUDAOutputType.PTX;
            case "cubin": return CUDAOutputType.Cubin;
            case "fatbin": return CUDAOutputType.Fatbin;
            case "devicelib", "device_lib": return CUDAOutputType.DeviceLib;
            case "executable", "exe": return CUDAOutputType.Executable;
            case "shared", "sharedlib", "so", "dylib": return CUDAOutputType.SharedLib;
            case "static", "staticlib", "a", "lib": return CUDAOutputType.StaticLib;
            default: return CUDAOutputType.Object;
        }
    }
    
    private static string archToString(CUDAArch arch) pure nothrow @safe
    {
        final switch (arch)
        {
            case CUDAArch.Auto: return "auto";
            case CUDAArch.SM_30: return "sm_30";
            case CUDAArch.SM_35: return "sm_35";
            case CUDAArch.SM_37: return "sm_37";
            case CUDAArch.SM_50: return "sm_50";
            case CUDAArch.SM_52: return "sm_52";
            case CUDAArch.SM_53: return "sm_53";
            case CUDAArch.SM_60: return "sm_60";
            case CUDAArch.SM_61: return "sm_61";
            case CUDAArch.SM_62: return "sm_62";
            case CUDAArch.SM_70: return "sm_70";
            case CUDAArch.SM_72: return "sm_72";
            case CUDAArch.SM_75: return "sm_75";
            case CUDAArch.SM_80: return "sm_80";
            case CUDAArch.SM_86: return "sm_86";
            case CUDAArch.SM_87: return "sm_87";
            case CUDAArch.SM_89: return "sm_89";
            case CUDAArch.SM_90: return "sm_90";
            case CUDAArch.SM_90a: return "sm_90a";
        }
    }
}

