module languages.compiled.gpu.metal.core.config;

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

/// Metal target platform
enum MetalPlatform { MacOS, iOS, iOSSimulator, tvOS, tvOSSimulator }

/// Metal language version
enum MetalVersion { V1_0, V1_1, V1_2, V2_0, V2_1, V2_2, V2_3, V2_4, V3_0, V3_1 }

/// Metal output type
enum MetalOutputType { AIR, MetalLib }

/// Metal compiler configuration
struct MetalConfig
{
    MetalPlatform platform = MetalPlatform.MacOS;
    MetalVersion version_ = MetalVersion.V3_0;
    MetalOutputType outputType = MetalOutputType.MetalLib;
    bool debug_ = false;
    bool fastMath = false;
    string[] includeDirs;
    string[] metalFlags;
    string outputDir = "bin";
    string objDir = ".builder-cache/metal-obj";
    bool verbose = false;
    string minOSVersion;
    
    static MetalConfig fromJSON(JSONValue json) @system
    {
        MetalConfig config;
        
        if ("platform" in json) config.platform = parsePlatform(json["platform"].str);
        if ("version" in json) config.version_ = parseVersion(json["version"].str);
        if ("output" in json) config.outputType = parseOutput(json["output"].str);
        if ("debug" in json) config.debug_ = json["debug"].boolean;
        if ("fastMath" in json) config.fastMath = json["fastMath"].boolean;
        
        if ("include" in json || "includes" in json)
        {
            auto inc = ("include" in json) ? json["include"] : json["includes"];
            foreach (i; inc.array) config.includeDirs ~= i.str;
        }
        
        if ("flags" in json)
            foreach (f; json["flags"].array) config.metalFlags ~= f.str;
        
        if ("outputDir" in json) config.outputDir = json["outputDir"].str;
        if ("verbose" in json) config.verbose = json["verbose"].boolean;
        if ("minOSVersion" in json) config.minOSVersion = json["minOSVersion"].str;
        
        return config;
    }
    
    string getStdFlag() const pure @safe
    {
        final switch (version_)
        {
            case MetalVersion.V1_0: return "-std=ios-metal1.0";
            case MetalVersion.V1_1: return "-std=ios-metal1.1";
            case MetalVersion.V1_2: return "-std=ios-metal1.2";
            case MetalVersion.V2_0: return "-std=metal2.0";
            case MetalVersion.V2_1: return "-std=metal2.1";
            case MetalVersion.V2_2: return "-std=metal2.2";
            case MetalVersion.V2_3: return "-std=metal2.3";
            case MetalVersion.V2_4: return "-std=metal2.4";
            case MetalVersion.V3_0: return "-std=metal3.0";
            case MetalVersion.V3_1: return "-std=metal3.1";
        }
    }
    
    private static MetalPlatform parsePlatform(string s) pure @safe
    {
        switch (s.toLower) {
            case "macos", "osx": return MetalPlatform.MacOS;
            case "ios": return MetalPlatform.iOS;
            case "ios-sim", "iossimulator": return MetalPlatform.iOSSimulator;
            case "tvos": return MetalPlatform.tvOS;
            case "tvos-sim", "tvossimulator": return MetalPlatform.tvOSSimulator;
            default: return MetalPlatform.MacOS;
        }
    }
    
    private static MetalVersion parseVersion(string s) pure @safe
    {
        switch (s.replace(".", "")) {
            case "10": return MetalVersion.V1_0;
            case "11": return MetalVersion.V1_1;
            case "12": return MetalVersion.V1_2;
            case "20": return MetalVersion.V2_0;
            case "21": return MetalVersion.V2_1;
            case "22": return MetalVersion.V2_2;
            case "23": return MetalVersion.V2_3;
            case "24": return MetalVersion.V2_4;
            case "30": return MetalVersion.V3_0;
            case "31": return MetalVersion.V3_1;
            default: return MetalVersion.V3_0;
        }
    }
    
    private static MetalOutputType parseOutput(string s) pure @safe
    {
        switch (s.toLower) {
            case "air": return MetalOutputType.AIR;
            case "metallib", "lib": return MetalOutputType.MetalLib;
            default: return MetalOutputType.MetalLib;
        }
    }
}

