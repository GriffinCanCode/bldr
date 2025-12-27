module infrastructure.toolchain;

/// Platform/Toolchain Abstraction System
/// 
/// Provides unified platform and toolchain management for cross-compilation
/// and build tool configuration. This module consolidates toolchain detection,
/// version management, and cross-compilation support across all language handlers.
/// 
/// ## Core Concepts
/// 
/// **Platform**: OS + Architecture + ABI triple (e.g., x86_64-unknown-linux-gnu)
/// **Toolchain**: Collection of tools (compiler, linker, archiver, etc.)
/// **Tool**: Individual executable with version and capabilities
/// 
/// ## Usage
/// 
/// ```d
/// // Get current host platform
/// auto host = Platform.host();
/// 
/// // Parse target platform
/// auto target = Platform.parse("aarch64-unknown-linux-gnu");
/// 
/// // Auto-detect toolchains
/// auto registry = ToolchainRegistry.instance();
/// registry.initialize();
/// 
/// // Find toolchain for platform
/// auto toolchain = registry.findFor(target.unwrap());
/// 
/// // Resolve toolchain reference
/// auto tc = resolveToolchain("@toolchains//arm:gcc-11");
/// ```
/// 
/// ## DSL Integration
/// 
/// ```
/// target("app") {
///     type: executable;
///     platform: "linux-arm64";
///     toolchain: "@toolchains//arm:gcc-11";
///     sources: ["main.c"];
/// }
/// ```

// Core specifications (Platform, Toolchain, Tool, Version)
public import infrastructure.toolchain.core;

// Detection system (AutoDetector, language-specific detectors)
public import infrastructure.toolchain.detection;

// Registry system (ToolchainRegistry, constraint matching)
public import infrastructure.toolchain.registry;

// Provider system (Local, Repository-based providers)
public import infrastructure.toolchain.providers;

import infrastructure.errors : Result, BuildResult, BuildError, Ok, Err, SystemError, ErrorCode, Errors;
import std.range : empty;

/// Convenience function to get a toolchain by name with optional version constraint
BuildResult!Toolchain getToolchainByName(string name, string versionConstraint = "") @system
{
    auto registry = ToolchainRegistry.instance();
    registry.initialize();
    
    if (versionConstraint.empty)
    {
        auto toolchains = registry.getByName(name);
        if (toolchains.empty)
        {
            return Err!(Toolchain, BuildError)(
                Errors.system("Toolchain not found: " ~ name, Plugin.ToolNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        }
        // Return latest version
        return Ok!(Toolchain, BuildError)(toolchains[$ - 1]);
    }
    
    // Use constraint matching
    auto constraintResult = ToolchainConstraint.parse(name ~ "@" ~ versionConstraint);
    if (constraintResult.isErr)
        return Err!(Toolchain, BuildError)(constraintResult.unwrapErr());
    
    return registry.findMatching(constraintResult.unwrap());
}

/// Get compiler tool path for a toolchain by name
string getCompilerPath(string toolchainName) @system
{
    auto result = getToolchainByName(toolchainName);
    if (result.isErr)
        return "";
    
    auto tc = result.unwrap();
    auto compiler = tc.compiler();
    return compiler ? compiler.path : "";
}

