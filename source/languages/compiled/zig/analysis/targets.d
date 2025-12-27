module languages.compiled.zig.analysis.targets;

import std.string;
import std.algorithm;
import std.array;
import std.json;
import std.process;
import infrastructure.utils.logging;

/// Target information
struct TargetInfo
{
    /// Target triple (e.g., x86_64-linux-gnu)
    string triple;
    
    /// CPU architecture
    string arch;
    
    /// Operating system
    string os;
    
    /// ABI
    string abi;
    
    /// Available CPUs for this architecture
    string[] availableCpus;
    
    /// Available features for this CPU
    string[] availableFeatures;
    
    /// Is this target available
    bool isAvailable() const pure nothrow
    {
        return !triple.empty;
    }
}

/// Cross-compilation target manager
class TargetManager
{
    private static TargetInfo[string] cachedTargets;
    private static bool initialized = false;
    
    /// Initialize target cache
    static void initialize()
    {
        if (initialized)
            return;
        
        auto targets = queryAvailableTargets();
        foreach (target; targets)
        {
            cachedTargets[target.triple] = target;
        }
        
        initialized = true;
    }
    
    /// Get available targets
    static TargetInfo[] getAvailableTargets()
    {
        initialize();
        return cachedTargets.values;
    }
    
    /// Get target by triple
    static TargetInfo getTarget(string triple)
    {
        initialize();
        return cachedTargets.get(triple, TargetInfo.init);
    }
    
    /// Check if target is available
    static bool isTargetAvailable(string triple)
    {
        initialize();
        return (triple in cachedTargets) !is null;
    }
    
    /// Query available targets from zig
    private static TargetInfo[] queryAvailableTargets()
    {
        TargetInfo[] targets;
        
        auto res = execute(["zig", "targets"]);
        if (res.status != 0)
        {
            structuredLog.warning("failed_to_query_zig_targets").emit();
            return targets;
        }
        
        try
        {
            auto json = parseJSON(res.output);
            
            // Parse target information
            if ("cpus" in json && json["cpus"].type == JSONType.object)
            {
                foreach (string arch, cpuInfo; json["cpus"].object)
                {
                    // Each architecture has available CPUs
                    if (cpuInfo.type == JSONType.object)
                    {
                        TargetInfo target;
                        target.arch = arch;
                        target.availableCpus = cpuInfo.object.keys;
                        targets ~= target;
                    }
                }
            }
            
            // Parse available target triples
            if ("libc" in json && json["libc"].type == JSONType.array)
            {
                foreach (triple; json["libc"].array)
                {
                    if (triple.type == JSONType.string)
                    {
                        TargetInfo target;
                        target.triple = triple.str;
                        parseTriple(target);
                        targets ~= target;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_zig_targets_output_").field("detail", "Failed to parse zig targets output: " ~ e.msg).emit();
        }
        
        return targets;
    }
    
    /// Parse target triple into components
    private static void parseTriple(ref TargetInfo target)
    {
        auto parts = target.triple.split("-");
        if (parts.length >= 1)
            target.arch = parts[0];
        if (parts.length >= 2)
            target.os = parts[1];
        if (parts.length >= 3)
            target.abi = parts[2];
    }
    
    /// Suggest common targets
    static string[] getCommonTargets()
    {
        return [
            // x86_64
            "x86_64-linux-gnu",
            "x86_64-linux-musl",
            "x86_64-windows-gnu",
            "x86_64-windows-msvc",
            "x86_64-macos-none",
            "x86_64-freebsd-gnu",
            
            // ARM64
            "aarch64-linux-gnu",
            "aarch64-linux-musl",
            "aarch64-macos-none",
            "aarch64-windows-gnu",
            
            // ARM
            "arm-linux-gnueabihf",
            "arm-linux-musleabihf",
            
            // RISC-V
            "riscv64-linux-gnu",
            "riscv64-linux-musl",
            
            // WASM
            "wasm32-wasi-musl",
            "wasm32-freestanding-musl",
            
            // Other
            "i386-linux-gnu",
            "mips64-linux-gnuabi64",
            "powerpc64le-linux-gnu",
            "s390x-linux-gnu"
        ];
    }
    
    /// Get native target triple
    static string getNativeTarget()
    {
        // Query current host target
        auto res = execute(["zig", "env"]);
        if (res.status != 0)
            return "";
        
        try
        {
            auto json = parseJSON(res.output);
            if ("target" in json && json["target"].type == JSONType.string)
                return json["target"].str;
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_get_native_target_").field("detail", "Failed to get native target: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Validate target triple format
    static bool isValidTriple(string triple)
    {
        if (triple.empty)
            return false;
        
        // Basic format check: arch-os-abi or arch-os
        auto parts = triple.split("-");
        return parts.length >= 2 && parts.length <= 4;
    }
    
    /// Normalize target triple
    static string normalizeTriple(string triple)
    {
        return triple.strip.toLower;
    }
    
    /// Get target description
    static string describeTarget(string triple)
    {
        auto target = getTarget(triple);
        if (!target.isAvailable())
            return "Unknown target: " ~ triple;
        
        return "Architecture: " ~ target.arch ~
               ", OS: " ~ target.os ~
               ", ABI: " ~ target.abi;
    }
}

/// CPU feature manager
class CpuFeatureManager
{
    /// Get available CPU features for architecture
    static string[] getAvailableFeatures(string arch)
    {
        string[] features;
        
        auto res = execute(["zig", "targets"]);
        if (res.status != 0)
            return features;
        
        try
        {
            auto json = parseJSON(res.output);
            
            if ("cpus" in json && arch in json["cpus"].object)
            {
                auto cpuInfo = json["cpus"][arch];
                
                // Extract features from CPU info
                if (cpuInfo.type == JSONType.object)
                {
                    foreach (string cpu, info; cpuInfo.object)
                    {
                        if (info.type == JSONType.object && "features" in info)
                        {
                            if (info["features"].type == JSONType.array)
                            {
                                foreach (feature; info["features"].array)
                                {
                                    if (feature.type == JSONType.string)
                                    {
                                        string feat = feature.str;
                                        if (!features.canFind(feat))
                                            features ~= feat;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_get_cpu_features_").field("detail", "Failed to get CPU features: " ~ e.msg).emit();
        }
        
        return features;
    }
    
    /// Get baseline features for CPU
    static string[] getBaselineFeatures(string cpu)
    {
        // Baseline features are always enabled
        return ["baseline"];
    }
    
    /// Get native CPU features
    static string getNativeCpu()
    {
        return "native";
    }
    
    /// Parse feature string (+feature1-feature2)
    static string[] parseFeatureString(string features)
    {
        string[] result;
        
        // Features are specified as +feature or -feature
        // We'll extract just the feature names
        foreach (feat; features.split(","))
        {
            feat = feat.strip;
            if (feat.length > 1)
            {
                if (feat[0] == '+' || feat[0] == '-')
                    result ~= feat[1 .. $];
                else
                    result ~= feat;
            }
        }
        
        return result;
    }
    
    /// Build feature string from list
    static string buildFeatureString(string[] features, string[] disabledFeatures = [])
    {
        string[] parts;
        
        foreach (feat; features)
            parts ~= "+" ~ feat;
        
        foreach (feat; disabledFeatures)
            parts ~= "-" ~ feat;
        
        return parts.join(",");
    }
}


