module languages.compiled.gpu.rocm.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// AMD GPU architecture targets
enum ROCmArch
{
    /// Auto-detect
    Auto,
    /// Vega (MI25, Radeon VII)
    GFX900, GFX906,
    /// CDNA (MI100)
    GFX908,
    /// CDNA2 (MI200 series)
    GFX90A,
    /// RDNA2 (RX 6000 series)
    GFX1030, GFX1031, GFX1032,
    /// RDNA3 (RX 7000 series)
    GFX1100, GFX1101, GFX1102,
    /// CDNA3 (MI300)
    GFX940, GFX941, GFX942
}

/// ROCm optimization level
enum ROCmOptLevel { O0, O1, O2, O3, Fast }

/// ROCm output type
enum ROCmOutputType { Object, Executable, SharedLib, StaticLib, HIPFatbin }

/// ROCm/HIP compiler configuration
struct ROCmConfig
{
    ROCmArch[] archs = [ROCmArch.Auto];
    ROCmOptLevel optLevel = ROCmOptLevel.O2;
    ROCmOutputType outputType = ROCmOutputType.Object;
    bool debug_ = false;
    bool fastMath = false;
    string rocmPath;
    string[] includeDirs;
    string[] libDirs;
    string[] libs;
    string[] hipccFlags;
    string[] hostFlags;
    string cxxStd = "c++17";
    string outputDir = "bin";
    string objDir = ".builder-cache/rocm-obj";
    bool verbose = false;
    bool genDeps = true;
    
    static ROCmConfig fromJSON(JSONValue json) @system
    {
        ROCmConfig config;
        
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
        
        if ("opt" in json) config.optLevel = parseOpt(json["opt"].str);
        if ("output" in json) config.outputType = parseOutput(json["output"].str);
        if ("debug" in json) config.debug_ = json["debug"].boolean;
        if ("fastMath" in json || "fast_math" in json)
            config.fastMath = ("fastMath" in json) ? json["fastMath"].boolean : json["fast_math"].boolean;
        if ("rocmPath" in json || "rocm_path" in json)
            config.rocmPath = ("rocmPath" in json) ? json["rocmPath"].str : json["rocm_path"].str;
        
        if ("include" in json || "includes" in json)
        {
            auto inc = ("include" in json) ? json["include"] : json["includes"];
            foreach (i; inc.array)
                config.includeDirs ~= i.str;
        }
        
        if ("libs" in json)
            foreach (l; json["libs"].array) config.libs ~= l.str;
        
        if ("flags" in json || "hipccFlags" in json)
        {
            auto flags = ("flags" in json) ? json["flags"] : json["hipccFlags"];
            foreach (f; flags.array) config.hipccFlags ~= f.str;
        }
        
        if ("std" in json) config.cxxStd = json["std"].str;
        if ("outputDir" in json) config.outputDir = json["outputDir"].str;
        if ("verbose" in json) config.verbose = json["verbose"].boolean;
        
        return config;
    }
    
    string[] getArchFlags() const pure @safe
    {
        string[] flags;
        foreach (arch; archs)
        {
            if (arch == ROCmArch.Auto) continue;
            flags ~= "--offload-arch=" ~ archToString(arch);
        }
        return flags;
    }
    
    private static ROCmArch parseArch(string s) pure @safe
    {
        switch (s.toLower.replace("_", "").replace("-", ""))
        {
            case "auto": return ROCmArch.Auto;
            case "gfx900": return ROCmArch.GFX900;
            case "gfx906": return ROCmArch.GFX906;
            case "gfx908": return ROCmArch.GFX908;
            case "gfx90a": return ROCmArch.GFX90A;
            case "gfx1030": return ROCmArch.GFX1030;
            case "gfx1031": return ROCmArch.GFX1031;
            case "gfx1032": return ROCmArch.GFX1032;
            case "gfx1100": return ROCmArch.GFX1100;
            case "gfx1101": return ROCmArch.GFX1101;
            case "gfx1102": return ROCmArch.GFX1102;
            case "gfx940": return ROCmArch.GFX940;
            case "gfx941": return ROCmArch.GFX941;
            case "gfx942": return ROCmArch.GFX942;
            default: return ROCmArch.Auto;
        }
    }
    
    private static ROCmOptLevel parseOpt(string s) pure @safe
    {
        switch (s.toLower) {
            case "0", "o0": return ROCmOptLevel.O0;
            case "1", "o1": return ROCmOptLevel.O1;
            case "2", "o2": return ROCmOptLevel.O2;
            case "3", "o3": return ROCmOptLevel.O3;
            case "fast": return ROCmOptLevel.Fast;
            default: return ROCmOptLevel.O2;
        }
    }
    
    private static ROCmOutputType parseOutput(string s) pure @safe
    {
        switch (s.toLower) {
            case "object", "obj": return ROCmOutputType.Object;
            case "executable", "exe": return ROCmOutputType.Executable;
            case "shared", "so": return ROCmOutputType.SharedLib;
            case "static", "a": return ROCmOutputType.StaticLib;
            case "fatbin": return ROCmOutputType.HIPFatbin;
            default: return ROCmOutputType.Object;
        }
    }
    
    private static string archToString(ROCmArch arch) pure nothrow @safe
    {
        final switch (arch) {
            case ROCmArch.Auto: return "auto";
            case ROCmArch.GFX900: return "gfx900";
            case ROCmArch.GFX906: return "gfx906";
            case ROCmArch.GFX908: return "gfx908";
            case ROCmArch.GFX90A: return "gfx90a";
            case ROCmArch.GFX1030: return "gfx1030";
            case ROCmArch.GFX1031: return "gfx1031";
            case ROCmArch.GFX1032: return "gfx1032";
            case ROCmArch.GFX1100: return "gfx1100";
            case ROCmArch.GFX1101: return "gfx1101";
            case ROCmArch.GFX1102: return "gfx1102";
            case ROCmArch.GFX940: return "gfx940";
            case ROCmArch.GFX941: return "gfx941";
            case ROCmArch.GFX942: return "gfx942";
        }
    }
}

