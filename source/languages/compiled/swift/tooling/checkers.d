module languages.compiled.swift.tooling.checkers;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import infrastructure.utils.logging;
import languages.compiled.swift.config : SwiftPlatform;

/// SwiftLint runner
class SwiftLintRunner
{
    /// Check if SwiftLint is available
    static bool isAvailable()
    {
        auto res = execute(["swiftlint", "version"]);
        return res.status == 0;
    }
    
    /// Get SwiftLint version
    static string getVersion()
    {
        auto res = execute(["swiftlint", "version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Lint Swift files
    auto lint(
        string[] paths,
        string configFile = "",
        bool strict = false,
        string[] enableRules = [],
        string[] disableRules = []
    )
    {
        string[] cmd = ["swiftlint", "lint"];
        
        // Config file
        if (!configFile.empty && exists(configFile))
            cmd ~= ["--config", configFile];
        
        // Strict mode
        if (strict)
            cmd ~= ["--strict"];
        
        // Enable rules
        foreach (rule; enableRules)
            cmd ~= ["--enable-rule", rule];
        
        // Disable rules
        foreach (rule; disableRules)
            cmd ~= ["--disable-rule", rule];
        
        // Add paths
        cmd ~= ["--path"];
        cmd ~= paths;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
    
    /// Analyze Swift files (deeper analysis than lint)
    auto analyze(
        string[] paths,
        string configFile = "",
        string compilerLogPath = ""
    )
    {
        string[] cmd = ["swiftlint", "analyze"];
        
        // Config file
        if (!configFile.empty && exists(configFile))
            cmd ~= ["--config", configFile];
        
        // Compiler log path
        if (!compilerLogPath.empty)
            cmd ~= ["--compiler-log-path", compilerLogPath];
        
        // Add paths
        cmd ~= ["--path"];
        cmd ~= paths;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
    
    /// Autocorrect violations
    auto autocorrect(
        string[] paths,
        string configFile = ""
    )
    {
        string[] cmd = ["swiftlint", "autocorrect"];
        
        // Config file
        if (!configFile.empty && exists(configFile))
            cmd ~= ["--config", configFile];
        
        // Add paths
        cmd ~= ["--path"];
        cmd ~= paths;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
}

/// Swift-DocC documentation generator
class DocCRunner
{
    /// Check if Swift-DocC is available
    static bool isAvailable()
    {
        // DocC is integrated into Swift 5.5+
        auto res = execute(["swift", "package", "plugin", "--list"]);
        if (res.status == 0 && res.output.canFind("generate-documentation"))
            return true;
        
        // Check for standalone docc
        auto doccRes = execute(["docc", "--version"]);
        return doccRes.status == 0;
    }
    
    /// Get DocC version
    static string getVersion()
    {
        auto res = execute(["docc", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "integrated";
    }
    
    /// Generate documentation
    auto generate(
        string packagePath,
        string outputPath = ".docs",
        string hostingBasePath = ""
    )
    {
        string[] cmd = ["swift", "package"];
        
        // Use plugin
        cmd ~= ["--allow-writing-to-directory", outputPath];
        cmd ~= ["generate-documentation"];
        cmd ~= ["--output-path", outputPath];
        
        // Hosting base path
        if (!hostingBasePath.empty)
            cmd ~= ["--hosting-base-path", hostingBasePath];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, null, Config.none, size_t.max, packagePath);
    }
    
    /// Preview documentation
    auto preview(string packagePath)
    {
        string[] cmd = ["swift", "package", "preview-documentation"];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, null, Config.none, size_t.max, packagePath);
    }
}

/// XCFramework builder
class XCFrameworkBuilder
{
    /// Check if xcodebuild is available
    static bool isAvailable()
    {
        version(OSX)
        {
            auto res = execute(["xcodebuild", "-version"]);
            return res.status == 0;
        }
        else
        {
            return false;
        }
    }
    
    version(OSX)
    {
        /// Create XCFramework
        auto create(
            string productName,
            string outputPath,
            SwiftPlatform[] platforms
        )
        {
            import languages.compiled.swift.config;
            
            string[] cmd = ["xcodebuild", "-create-xcframework"];
            
            // Add frameworks for each platform
            foreach (platform; platforms)
            {
                string frameworkPath = buildFrameworkPath(productName, platform);
                if (exists(frameworkPath))
                {
                    cmd ~= ["-framework", frameworkPath];
                }
            }
            
            // Output
            cmd ~= ["-output", outputPath];
            
            structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
            
            return execute(cmd);
        }
        
        private string buildFrameworkPath(string productName, SwiftPlatform platform)
        {
            // This is a simplified version - actual paths depend on build configuration
            string platformName;
            final switch (platform)
            {
                case SwiftPlatform.macOS:
                    platformName = "macosx";
                    break;
                case SwiftPlatform.iOS:
                    platformName = "iphoneos";
                    break;
                case SwiftPlatform.iOSSimulator:
                    platformName = "iphonesimulator";
                    break;
                case SwiftPlatform.tvOS:
                    platformName = "appletvos";
                    break;
                case SwiftPlatform.watchOS:
                    platformName = "watchos";
                    break;
                case SwiftPlatform.Linux:
                case SwiftPlatform.Windows:
                case SwiftPlatform.Android:
                    return "";
            }
            
            return buildPath(".build", platformName, productName ~ ".framework");
        }
    }
}

