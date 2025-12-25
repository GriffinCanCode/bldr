module infrastructure.toolchain.core.spec;

import std.conv : to;
import std.string : indexOf;
import std.array : empty;
import infrastructure.toolchain.core.platform;
import infrastructure.errors;

/// Toolchain type
enum ToolchainType
{
    Compiler,      // Compiler (gcc, clang, rustc, etc.)
    Linker,        // Linker (ld, lld, etc.)
    Archiver,      // Static library archiver (ar, lib, etc.)
    Assembler,     // Assembler (as, nasm, etc.)
    Interpreter,   // Interpreter (python, node, etc.)
    Runtime,       // Runtime environment (JVM, .NET, etc.)
    BuildTool,     // Build tool (make, ninja, cmake, etc.)
    PackageManager // Package manager (cargo, npm, pip, etc.)
}

/// Tool capability flags
enum Capability : ulong
{
    None = 0,
    CrossCompile = 1 << 0,     // Supports cross-compilation
    LTO = 1 << 1,              // Link-time optimization
    PGO = 1 << 2,              // Profile-guided optimization
    Incremental = 1 << 3,      // Incremental compilation
    ModernStd = 1 << 4,        // Modern language standards
    Debugging = 1 << 5,        // Debug info generation
    Optimization = 1 << 6,     // Optimization support
    Sanitizers = 1 << 7,       // Sanitizer support
    CodeCoverage = 1 << 8,     // Code coverage
    StaticAnalysis = 1 << 9,   // Static analysis
    Parallel = 1 << 10,        // Parallel builds
    DistCC = 1 << 11,          // Distributed compilation
    ColorDiag = 1 << 12,       // Colored diagnostics
    JSON = 1 << 13,            // JSON output
    Modules = 1 << 14,         // Module support
    Hermetic = 1 << 15         // Hermetic builds
}

/// Semantic version
struct Version
{
    uint major;
    uint minor;
    uint patch;
    string prerelease;
    
    /// Parse from string (e.g., "1.2.3", "4.5.6-beta")
    static BuildResult!Version parse(string str) @system
    {
        import std.array : empty;
        import std.string : split, strip, indexOf;
        import std.conv : to;
        
        if (str.empty)
            return Err!(Version, BuildError)(
                new SystemError("Empty version string", ErrorCode.InvalidInput));
        
        Version ver;
        
        // Split on prerelease marker
        auto prereleaseIdx = str.indexOf('-');
        if (prereleaseIdx >= 0)
        {
            ver.prerelease = str[prereleaseIdx + 1 .. $].strip();
            str = str[0 .. prereleaseIdx];
        }
        
        // Parse major.minor.patch
        auto parts = str.split(".");
        if (parts.length >= 1)
        {
            try { ver.major = parts[0].strip().to!uint; }
            catch (Exception) { return Err!(Version, BuildError)(
                new SystemError("Invalid version format", ErrorCode.InvalidInput)); }
        }
        if (parts.length >= 2)
        {
            try { ver.minor = parts[1].strip().to!uint; }
            catch (Exception) { return Err!(Version, BuildError)(
                new SystemError("Invalid version format", ErrorCode.InvalidInput)); }
        }
        if (parts.length >= 3)
        {
            try { ver.patch = parts[2].strip().to!uint; }
            catch (Exception) { return Err!(Version, BuildError)(
                new SystemError("Invalid version format", ErrorCode.InvalidInput)); }
        }
        
        return Ok!(Version, BuildError)(ver);
    }
    
    /// Convert to string
    string toString() const pure @safe
    {
        import std.format : format;
        
        if (prerelease.empty)
            return format("%d.%d.%d", major, minor, patch);
        else
            return format("%d.%d.%d-%s", major, minor, patch, prerelease);
    }
    
    /// Compare versions
    int opCmp(const Version other) const pure nothrow @nogc @safe
    {
        if (major != other.major)
            return major < other.major ? -1 : 1;
        if (minor != other.minor)
            return minor < other.minor ? -1 : 1;
        if (patch != other.patch)
            return patch < other.patch ? -1 : 1;
        
        // Prerelease versions are less than release versions
        if (prerelease.empty && !other.prerelease.empty)
            return 1;
        if (!prerelease.empty && other.prerelease.empty)
            return -1;
        
        return 0;
    }
    
    /// Equality
    bool opEquals(const Version other) const pure nothrow @nogc @safe
    {
        return major == other.major && 
               minor == other.minor && 
               patch == other.patch &&
               prerelease == other.prerelease;
    }
}

/// Toolchain tool specification
struct Tool
{
    string name;           // Tool name (e.g., "gcc", "clang")
    string path;           // Full path to executable
    Version version_;      // Tool version
    ToolchainType type;    // Tool type
    Capability capabilities; // Capability flags
    Platform[] supportedPlatforms; // Supported target platforms
    
    /// Check if tool has capability
    bool hasCapability(Capability cap) const pure nothrow @nogc @safe
    {
        return (capabilities & cap) != 0;
    }
    
    /// Check if tool supports platform
    bool supportsPlatform(Platform platform) const @safe
    {
        if (supportedPlatforms.empty)
            return true; // Assume universal support if not specified
        
        foreach (supported; supportedPlatforms)
        {
            if (supported == platform || supported.compatibleWith(platform))
                return true;
        }
        return false;
    }
    
    /// Check if tool is available (executable exists)
    bool isAvailable() const @safe
    {
        import std.file : exists;
        return !path.empty && exists(path);
    }
}

/// Complete toolchain specification (collection of tools)
struct Toolchain
{
    string name;           // Toolchain name (e.g., "gcc-11", "llvm-15")
    string id;             // Unique identifier
    Platform host;         // Host platform (where toolchain runs)
    Platform target;       // Target platform (what it builds for)
    Tool[] tools;          // Tools in this toolchain
    string[string] env;    // Environment variables to set
    string sysroot;        // System root for headers/libraries
    
    /// Get tool by type
    const(Tool)* getTool(ToolchainType type) const @system
    {
        foreach (ref tool; tools)
        {
            if (tool.type == type)
                return &tool;
        }
        return null;
    }
    
    /// Get tool by name
    const(Tool)* getToolByName(string name) const @system
    {
        foreach (ref tool; tools)
        {
            if (tool.name == name)
                return &tool;
        }
        return null;
    }
    
    /// Check if toolchain supports cross-compilation
    bool isCross() const nothrow @safe
    {
        return target.isCross();
    }
    
    /// Check if all tools are available
    bool isComplete() const @safe
    {
        foreach (ref tool; tools)
        {
            if (!tool.isAvailable())
                return false;
        }
        return true;
    }
    
    /// Get compiler tool (convenience)
    const(Tool)* compiler() const @system
    {
        return getTool(ToolchainType.Compiler);
    }
    
    /// Get linker tool (convenience)
    const(Tool)* linker() const @system
    {
        return getTool(ToolchainType.Linker);
    }
}

/// Toolchain reference (for DSL)
/// Format: "@toolchains//path:name" or "name"
struct ToolchainRef
{
    string name;       // Toolchain name
    string path;       // Optional path within toolchains workspace
    bool isExternal;   // External reference (@toolchains//)
    
    /// Parse toolchain reference
    static BuildResult!ToolchainRef parse(string str) @system
    {
        import std.string : startsWith, indexOf, strip;
        
        if (str.empty)
            return Err!(ToolchainRef, BuildError)(
                new SystemError("Empty toolchain reference", ErrorCode.InvalidInput));
        
        ToolchainRef ref_;
        str = str.strip();
        
        // Check for external reference
        if (str.startsWith("@toolchains//"))
        {
            ref_.isExternal = true;
            str = str[13 .. $]; // Remove "@toolchains//"
            
            // Parse path:name
            auto colonIdx = str.indexOf(":");
            if (colonIdx >= 0)
            {
                ref_.path = str[0 .. colonIdx];
                ref_.name = str[colonIdx + 1 .. $];
            }
            else
            {
                ref_.name = str;
            }
        }
        else
        {
            // Simple name reference
            ref_.isExternal = false;
            ref_.name = str;
        }
        
        return Ok!(ToolchainRef, BuildError)(ref_);
    }
    
    /// Convert to string
    string toString() const pure @safe
    {
        if (isExternal)
        {
            if (path.empty)
                return "@toolchains//:" ~ name;
            else
                return "@toolchains//" ~ path ~ ":" ~ name;
        }
        else
        {
            return name;
        }
    }
}

@system unittest
{
    // Test version parsing
    auto ver = Version.parse("1.2.3");
    assert(ver.isOk);
    assert(ver.unwrap().major == 1);
    assert(ver.unwrap().minor == 2);
    assert(ver.unwrap().patch == 3);
    
    // Test version comparison
    auto v1 = Version(1, 0, 0);
    auto v2 = Version(2, 0, 0);
    assert(v1 < v2);
    
    // Test version with prerelease
    auto beta = Version.parse("3.0.0-beta");
    assert(beta.isOk);
    assert(beta.unwrap().prerelease == "beta");
}

@system unittest
{
    // Test toolchain reference parsing
    auto ref1 = ToolchainRef.parse("@toolchains//arm:gcc");
    assert(ref1.isOk);
    assert(ref1.unwrap().isExternal);
    assert(ref1.unwrap().path == "arm");
    assert(ref1.unwrap().name == "gcc");
    
    auto ref2 = ToolchainRef.parse("local-gcc");
    assert(ref2.isOk);
    assert(!ref2.unwrap().isExternal);
    assert(ref2.unwrap().name == "local-gcc");
}

