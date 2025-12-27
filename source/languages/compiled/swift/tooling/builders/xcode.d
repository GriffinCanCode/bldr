module languages.compiled.swift.tooling.builders.xcode;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.compiled.swift.config;
import languages.compiled.swift.tooling.builders.base;
import languages.compiled.swift.managers.toolchain;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

version(OSX)
{
    /// Xcode build system builder (macOS only)
    class XcodeBuilder : SwiftBuilder
    {
        SwiftBuildResult build(
            in string[] sources,
            in SwiftConfig config,
            in Target target,
            in WorkspaceConfig workspace
        )
        {
            SwiftBuildResult result;
            
            // Build with xcodebuild
            string[] cmd = ["xcodebuild"];
            
            // Configuration
            string configuration = config.buildConfig == SwiftBuildConfig.Debug ? "Debug" : "Release";
            cmd ~= ["-configuration", configuration];
            
            // Scheme or target
            if (!config.xcodeScheme.empty)
                cmd ~= ["-scheme", config.xcodeScheme];
            else if (!config.target.empty)
                cmd ~= ["-target", config.target];
            
            // SDK
            if (!config.sdk.empty)
                cmd ~= ["-sdk", config.sdk];
            
            // Arch
            if (!config.arch.empty)
                cmd ~= ["-arch", config.arch];
            
            // Destination (for iOS/tvOS/watchOS)
            foreach (platform; config.platforms)
            {
                string destination = getPlatformDestination(platform);
                if (!destination.empty)
                {
                    cmd ~= ["-destination", destination];
                    break;
                }
            }
            
            // Build action
            cmd ~= ["build"];
            
            structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
            
            auto res = execute(cmd, config.env);
            
            if (res.status != 0)
            {
                result.error = "xcodebuild failed: " ~ res.output;
                return result;
            }
            
            result.success = true;
            result.outputs = []; // xcodebuild outputs are in DerivedData
            result.outputHash = FastHash.hashStrings(sources);
            
            return result;
        }
        
        bool isAvailable()
        {
            return XcodeManager.isInstalled();
        }
        
        string name() const
        {
            return "xcodebuild";
        }
        
        string getVersion()
        {
            return XcodeManager.getVersion();
        }
        
        bool supportsFeature(string feature)
        {
            switch (feature)
            {
                case "xcode":
                case "ios":
                case "macos":
                case "tvos":
                case "watchos":
                    return true;
                default:
                    return false;
            }
        }
        
        private string getPlatformDestination(PlatformTarget platform)
        {
            final switch (platform.platform)
            {
                case SwiftPlatform.macOS:
                    return "platform=macOS";
                case SwiftPlatform.iOS:
                    return "platform=iOS";
                case SwiftPlatform.iOSSimulator:
                    return "platform=iOS Simulator";
                case SwiftPlatform.tvOS:
                    return "platform=tvOS";
                case SwiftPlatform.watchOS:
                    return "platform=watchOS";
                case SwiftPlatform.Linux:
                case SwiftPlatform.Windows:
                case SwiftPlatform.Android:
                    return "";
            }
        }
    }
}
else
{
    /// Stub for non-macOS platforms
    class XcodeBuilder : SwiftBuilder
    {
        SwiftBuildResult build(
            in string[] sources,
            in SwiftConfig config,
            in Target target,
            in WorkspaceConfig workspace
        )
        {
            SwiftBuildResult result;
            result.error = "Xcode builder only available on macOS";
            return result;
        }
        
        bool isAvailable()
        {
            return false;
        }
        
        string name() const
        {
            return "xcodebuild";
        }
        
        string getVersion()
        {
            return "unavailable";
        }
        
        bool supportsFeature(string feature)
        {
            return false;
        }
    }
}

