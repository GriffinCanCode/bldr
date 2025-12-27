module languages.compiled.swift.managers.toolchain;

import std.process;
import std.string;
import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.conv;
import std.regex;
import infrastructure.utils.logging;

/// Swift toolchain information
struct Toolchain
{
    string name;
    string path;
    string version_;
    string llvmVersion;
    bool isDefault;
    bool isXcode;
    bool isSnapshot;
}

/// Swift target triple information
struct TargetTriple
{
    string name;
    string arch;      // arm64, x86_64, etc.
    string vendor;    // apple, unknown, pc, etc.
    string system;    // macosx, linux, windows, etc.
    string abi;       // macho, elf, etc.
}

/// SDK information
struct SDK
{
    string name;
    string path;
    string version_;
    string platform;
}

/// Swift toolchain manager
class SwiftToolchainManager
{
    /// Check if Swift is available
    static bool isSwiftAvailable()
    {
        auto res = execute(["swift", "--version"]);
        return res.status == 0;
    }
    
    /// Get Swift version
    static string getSwiftVersion()
    {
        auto res = execute(["swift", "--version"]);
        if (res.status == 0)
        {
            auto lines = res.output.split("\n");
            if (!lines.empty)
            {
                // Parse version from "Swift version X.Y.Z"
                auto match = lines[0].matchFirst(regex(`Swift version ([\d.]+)`));
                if (!match.empty)
                    return match[1];
                return lines[0].strip;
            }
        }
        return "unknown";
    }
    
    /// Get Swift compiler path
    static string getSwiftcPath()
    {
        version(Windows)
        {
            auto res = execute(["where", "swiftc"]);
        }
        else
        {
            auto res = execute(["which", "swiftc"]);
        }
        
        if (res.status == 0)
            return res.output.strip;
        return "";
    }
    
    /// Get Swift installation path
    static string getSwiftPath()
    {
        auto swiftcPath = getSwiftcPath();
        if (!swiftcPath.empty)
        {
            // swiftc is typically in bin/ directory
            return dirName(dirName(swiftcPath));
        }
        return "";
    }
    
    /// Get host target triple
    static string getHostTarget()
    {
        auto res = execute(["swift", "-print-target-info"]);
        if (res.status != 0)
            return "";
        
        try
        {
            import std.json;
            auto json = parseJSON(res.output);
            if (auto target = "target" in json)
            {
                if (auto triple = "triple" in *target)
                    return triple.str;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_target_info_").field("detail", "Failed to parse target info: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Get supported target triples
    static TargetTriple[] getSupportedTargets()
    {
        TargetTriple[] targets;
        
        auto res = execute(["swift", "-print-target-info"]);
        if (res.status != 0)
            return targets;
        
        try
        {
            import std.json;
            auto json = parseJSON(res.output);
            
            // Add host target
            if (auto target = "target" in json)
            {
                if (auto triple = "triple" in *target)
                {
                    TargetTriple t;
                    t.name = triple.str;
                    parseTargetTriple(t);
                    targets ~= t;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_target_info_").field("detail", "Failed to parse target info: " ~ e.msg).emit();
        }
        
        return targets;
    }
    
    /// Get LLVM version
    static string getLLVMVersion()
    {
        auto res = execute(["swift", "--version"]);
        if (res.status != 0)
            return "";
        
        foreach (line; res.output.split("\n"))
        {
            // Look for "Target: " or "LLVM: "
            auto match = line.matchFirst(regex(`LLVM\s+version\s+([\d.]+)`));
            if (!match.empty)
                return match[1];
        }
        
        return "";
    }
    
    /// List available toolchains
    static Toolchain[] listToolchains()
    {
        Toolchain[] toolchains;
        
        // Add system Swift
        if (isSwiftAvailable())
        {
            Toolchain tc;
            tc.name = "system";
            tc.path = getSwiftPath();
            tc.version_ = getSwiftVersion();
            tc.llvmVersion = getLLVMVersion();
            tc.isDefault = true;
            toolchains ~= tc;
        }
        
        // Check for Xcode Swift
        version(OSX)
        {
            auto xcodeSwift = getXcodeSwiftPath();
            if (!xcodeSwift.empty && xcodeSwift != getSwiftPath())
            {
                Toolchain tc;
                tc.name = "xcode";
                tc.path = xcodeSwift;
                tc.version_ = getXcodeSwiftVersion();
                tc.isXcode = true;
                toolchains ~= tc;
            }
            
            // Check for other Xcode toolchains
            auto xcodeToolchains = listXcodeToolchains();
            toolchains ~= xcodeToolchains;
        }
        
        return toolchains;
    }
    
    /// Get Xcode Swift path (macOS only)
    version(OSX)
    {
        static string getXcodeSwiftPath()
        {
            auto res = execute(["xcrun", "--find", "swiftc"]);
            if (res.status == 0)
            {
                string swiftcPath = res.output.strip;
                return dirName(dirName(swiftcPath));
            }
            return "";
        }
        
        static string getXcodeSwiftVersion()
        {
            auto res = execute(["xcrun", "swift", "--version"]);
            if (res.status == 0)
            {
                auto lines = res.output.split("\n");
                if (!lines.empty)
                {
                    auto match = lines[0].matchFirst(regex(`Swift version ([\d.]+)`));
                    if (!match.empty)
                        return match[1];
                    return lines[0].strip;
                }
            }
            return "unknown";
        }
        
        static Toolchain[] listXcodeToolchains()
        {
            Toolchain[] toolchains;
            
            string toolchainsDir = buildPath(
                environment.get("HOME", ""),
                "Library/Developer/Toolchains"
            );
            
            if (exists(toolchainsDir) && isDir(toolchainsDir))
            {
                foreach (entry; dirEntries(toolchainsDir, SpanMode.shallow))
                {
                    if (entry.isDir && entry.name.endsWith(".xctoolchain"))
                    {
                        Toolchain tc;
                        tc.name = baseName(entry.name, ".xctoolchain");
                        tc.path = entry.name;
                        tc.isXcode = true;
                        
                        // Check if it's a snapshot
                        if (tc.name.toLower.canFind("snapshot"))
                            tc.isSnapshot = true;
                        
                        // Try to get version
                        string swiftPath = buildPath(entry.name, "usr/bin/swift");
                        if (exists(swiftPath))
                        {
                            auto res = execute([swiftPath, "--version"]);
                            if (res.status == 0)
                            {
                                auto lines = res.output.split("\n");
                                if (!lines.empty)
                                {
                                    auto match = lines[0].matchFirst(regex(`Swift version ([\d.]+)`));
                                    if (!match.empty)
                                        tc.version_ = match[1];
                                }
                            }
                        }
                        
                        toolchains ~= tc;
                    }
                }
            }
            
            return toolchains;
        }
    }
    
    private static void parseTargetTriple(ref TargetTriple target)
    {
        // Parse target triple: arch-vendor-system-abi
        // Example: x86_64-apple-macosx, arm64-apple-ios
        
        auto parts = target.name.split("-");
        if (parts.length >= 1)
            target.arch = parts[0];
        if (parts.length >= 2)
            target.vendor = parts[1];
        if (parts.length >= 3)
            target.system = parts[2];
        if (parts.length >= 4)
            target.abi = parts[3];
    }
}

/// SDK manager (for Apple platforms)
class SDKManager
{
    version(OSX)
    {
        /// Check if xcrun is available
        static bool isAvailable()
        {
            auto res = execute(["xcrun", "--version"]);
            return res.status == 0;
        }
        
        /// Get SDK path for platform
        static string getSDKPath(string platform = "macosx")
        {
            auto res = execute(["xcrun", "--sdk", platform, "--show-sdk-path"]);
            if (res.status == 0)
                return res.output.strip;
            return "";
        }
        
        /// Get SDK version
        static string getSDKVersion(string platform = "macosx")
        {
            auto res = execute(["xcrun", "--sdk", platform, "--show-sdk-version"]);
            if (res.status == 0)
                return res.output.strip;
            return "";
        }
        
        /// Get SDK platform path
        static string getSDKPlatformPath(string platform = "macosx")
        {
            auto res = execute(["xcrun", "--sdk", platform, "--show-sdk-platform-path"]);
            if (res.status == 0)
                return res.output.strip;
            return "";
        }
        
        /// List available SDKs
        static SDK[] listSDKs()
        {
            SDK[] sdks;
            
            auto res = execute(["xcodebuild", "-showsdks"]);
            if (res.status != 0)
                return sdks;
            
            foreach (line; res.output.split("\n"))
            {
                // Parse SDK line: "iOS 17.0 -sdk iphoneos17.0"
                auto match = line.matchFirst(regex(`(\w+\s+[\d.]+)\s+-sdk\s+(\w+)`));
                if (!match.empty)
                {
                    SDK sdk;
                    sdk.name = match[2];
                    
                    // Extract platform
                    if (sdk.name.startsWith("macosx"))
                        sdk.platform = "macOS";
                    else if (sdk.name.startsWith("iphoneos"))
                        sdk.platform = "iOS";
                    else if (sdk.name.startsWith("iphonesimulator"))
                        sdk.platform = "iOS Simulator";
                    else if (sdk.name.startsWith("appletvos"))
                        sdk.platform = "tvOS";
                    else if (sdk.name.startsWith("appletvsimulator"))
                        sdk.platform = "tvOS Simulator";
                    else if (sdk.name.startsWith("watchos"))
                        sdk.platform = "watchOS";
                    else if (sdk.name.startsWith("watchsimulator"))
                        sdk.platform = "watchOS Simulator";
                    
                    // Get path
                    sdk.path = getSDKPath(sdk.name);
                    sdk.version_ = getSDKVersion(sdk.name);
                    
                    sdks ~= sdk;
                }
            }
            
            return sdks;
        }
    }
}

/// Xcode interface (macOS only)
class XcodeManager
{
    version(OSX)
    {
        /// Check if Xcode is installed
        static bool isInstalled()
        {
            auto res = execute(["xcodebuild", "-version"]);
            return res.status == 0;
        }
        
        /// Get Xcode version
        static string getVersion()
        {
            auto res = execute(["xcodebuild", "-version"]);
            if (res.status == 0)
            {
                auto lines = res.output.split("\n");
                if (!lines.empty)
                {
                    // Parse "Xcode X.Y.Z"
                    auto match = lines[0].matchFirst(regex(`Xcode ([\d.]+)`));
                    if (!match.empty)
                        return match[1];
                    return lines[0].strip;
                }
            }
            return "unknown";
        }
        
        /// Get Xcode path
        static string getPath()
        {
            auto res = execute(["xcode-select", "-p"]);
            if (res.status == 0)
                return res.output.strip;
            return "";
        }
        
        /// Get Xcode build version
        static string getBuildVersion()
        {
            auto res = execute(["xcodebuild", "-version"]);
            if (res.status == 0)
            {
                auto lines = res.output.split("\n");
                if (lines.length >= 2)
                {
                    // Parse "Build version XXXXX"
                    auto match = lines[1].matchFirst(regex(`Build version (\w+)`));
                    if (!match.empty)
                        return match[1];
                }
            }
            return "";
        }
    }
}

