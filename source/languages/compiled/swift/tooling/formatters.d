module languages.compiled.swift.tooling.formatters;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import infrastructure.utils.logging;

/// SwiftFormat runner
class SwiftFormatRunner
{
    /// Check if SwiftFormat is available
    static bool isAvailable()
    {
        auto res = execute(["swiftformat", "--version"]);
        return res.status == 0;
    }
    
    /// Get SwiftFormat version
    static string getVersion()
    {
        auto res = execute(["swiftformat", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Format Swift files
    auto format(
        string[] files,
        string configFile = "",
        bool checkOnly = false,
        bool inPlace = true
    )
    {
        string[] cmd = ["swiftformat"];
        
        // Config file
        if (!configFile.empty && exists(configFile))
            cmd ~= ["--config", configFile];
        
        // Check only (lint mode)
        if (checkOnly)
            cmd ~= ["--lint"];
        
        // In-place
        if (!inPlace && !checkOnly)
            cmd ~= ["--output", "stdout"];
        
        // Add files/directories
        cmd ~= files;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
}

/// Apple swift-format runner (official formatter)
class AppleSwiftFormatRunner
{
    /// Check if swift-format is available
    static bool isAvailable()
    {
        auto res = execute(["swift-format", "--version"]);
        return res.status == 0;
    }
    
    /// Get swift-format version
    static string getVersion()
    {
        auto res = execute(["swift-format", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Format Swift files
    auto format(
        string[] files,
        string configFile = "",
        bool checkOnly = false,
        bool inPlace = true
    )
    {
        string[] cmd = ["swift-format"];
        
        // Mode
        if (checkOnly)
            cmd ~= ["lint"];
        else
            cmd ~= ["format"];
        
        // Config file
        if (!configFile.empty && exists(configFile))
            cmd ~= ["--configuration", configFile];
        
        // In-place
        if (inPlace && !checkOnly)
            cmd ~= ["--in-place"];
        
        // Add files
        cmd ~= files;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
}

