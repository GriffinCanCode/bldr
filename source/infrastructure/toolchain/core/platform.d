module infrastructure.toolchain.core.platform;

import std.string : toLower, startsWith;
import std.algorithm : canFind;
import std.array : empty;
import std.conv : to;
import infrastructure.errors;

/// Platform architecture
enum Arch
{
    X86,       // 32-bit x86
    X86_64,    // 64-bit x86
    ARM,       // 32-bit ARM
    ARM64,     // 64-bit ARM (aarch64)
    RISCV32,   // 32-bit RISC-V
    RISCV64,   // 64-bit RISC-V
    MIPS,      // MIPS
    PowerPC,   // PowerPC
    WASM32,    // WebAssembly 32-bit
    WASM64,    // WebAssembly 64-bit
    Unknown
}

/// Operating system
enum OS
{
    Linux,
    Darwin,    // macOS
    Windows,
    FreeBSD,
    OpenBSD,
    NetBSD,
    Solaris,
    Android,
    iOS,
    Web,       // WebAssembly target
    Unknown
}

/// ABI (Application Binary Interface)
enum ABI
{
    GNU,       // GNU libc
    MUSL,      // musl libc
    MSVC,      // Microsoft Visual C++
    MinGW,     // Minimalist GNU for Windows
    Darwin,    // macOS ABI
    Android,   // Android ABI
    EABI,      // Embedded ABI
    EABIHF,    // Embedded ABI Hard Float
    Unknown
}

/// Platform specification (OS + Architecture + ABI)
/// Represents a target platform for cross-compilation
struct Platform
{
    Arch arch;
    OS os;
    ABI abi;
    
    /// Create platform from components
    this(Arch arch, OS os, ABI abi = ABI.Unknown) pure nothrow @nogc @safe
    {
        this.arch = arch;
        this.os = os;
        this.abi = abi;
    }
    
    /// Parse from target triple (e.g., "x86_64-unknown-linux-gnu")
    static BuildResult!Platform parse(string triple) @system
    {
        import std.array : split;
        
        if (triple.empty)
            return Err!(Platform, BuildError)(
                new SystemError("Empty platform triple", ErrorCode.InvalidInput));
        
        auto parts = triple.split("-");
        if (parts.length < 2)
            return Err!(Platform, BuildError)(
                new SystemError("Invalid platform triple format: " ~ triple, ErrorCode.InvalidInput));
        
        Platform platform;
        
        // Parse architecture (first component)
        platform.arch = parseArch(parts[0]);
        
        // Parse OS (usually third component, but varies)
        if (parts.length >= 3)
            platform.os = parseOS(parts[2]);
        else
            platform.os = OS.Unknown;
        
        // Parse ABI (usually fourth component)
        if (parts.length >= 4)
            platform.abi = parseABI(parts[3]);
        else
            platform.abi = ABI.Unknown;
        
        return Ok!(Platform, BuildError)(platform);
    }
    
    /// Get current host platform
    static Platform host() @safe nothrow
    {
        Platform platform;
        
        // Detect architecture
        version(X86)
            platform.arch = Arch.X86;
        else version(X86_64)
            platform.arch = Arch.X86_64;
        else version(ARM)
            platform.arch = Arch.ARM;
        else version(AArch64)
            platform.arch = Arch.ARM64;
        else
            platform.arch = Arch.Unknown;
        
        // Detect OS
        version(linux)
            platform.os = OS.Linux;
        else version(OSX)
            platform.os = OS.Darwin;
        else version(Windows)
            platform.os = OS.Windows;
        else version(FreeBSD)
            platform.os = OS.FreeBSD;
        else version(OpenBSD)
            platform.os = OS.OpenBSD;
        else version(NetBSD)
            platform.os = OS.NetBSD;
        else version(Android)
            platform.os = OS.Android;
        else
            platform.os = OS.Unknown;
        
        // Detect ABI
        version(linux)
        {
            version(CRuntime_Musl)
                platform.abi = ABI.MUSL;
            else
                platform.abi = ABI.GNU;
        }
        else version(Windows)
        {
            version(CRuntime_Microsoft)
                platform.abi = ABI.MSVC;
            else
                platform.abi = ABI.MinGW;
        }
        else version(OSX)
            platform.abi = ABI.Darwin;
        else
            platform.abi = ABI.Unknown;
        
        return platform;
    }
    
    /// Convert to target triple string
    string toTriple() const pure @safe
    {
        import std.format : format;
        
        string archStr = archToString(arch);
        string osStr = osToString(os);
        string abiStr = abiToString(abi);
        
        // Standard format: arch-vendor-os-abi
        // Use "unknown" for vendor (most common)
        if (abi == ABI.Unknown)
            return format("%s-unknown-%s", archStr, osStr);
        else
            return format("%s-unknown-%s-%s", archStr, osStr, abiStr);
    }
    
    /// Check if cross-compiling (target ≠ host)
    bool isCross() const @safe nothrow
    {
        auto hostPlatform = host();
        return this.arch != hostPlatform.arch || 
               this.os != hostPlatform.os;
    }
    
    /// Check if compatible with another platform
    bool compatibleWith(Platform other) const pure nothrow @nogc @safe
    {
        // Same platform is always compatible
        if (this == other)
            return true;
        
        // x86_64 can run x86 code
        if (this.arch == Arch.X86_64 && other.arch == Arch.X86 && this.os == other.os)
            return true;
        
        // ARM64 can run ARM code (sometimes)
        if (this.arch == Arch.ARM64 && other.arch == Arch.ARM && this.os == other.os)
            return true;
        
        return false;
    }
    
    /// Equality comparison
    bool opEquals(const Platform other) const pure nothrow @nogc @safe
    {
        return arch == other.arch && os == other.os && abi == other.abi;
    }
    
    /// Hash for use in associative arrays
    size_t toHash() const pure nothrow @nogc @safe
    {
        return cast(size_t)arch * 1000 + cast(size_t)os * 100 + cast(size_t)abi;
    }
}

/// Parse architecture from string
private Arch parseArch(string str) @safe
{
    str = str.toLower();
    
    if (str == "x86" || str == "i386" || str == "i686")
        return Arch.X86;
    if (str == "x86_64" || str == "x64" || str == "amd64")
        return Arch.X86_64;
    if (str == "arm" || str == "armv7" || str == "armv7l")
        return Arch.ARM;
    if (str == "arm64" || str == "aarch64" || str == "armv8")
        return Arch.ARM64;
    if (str == "riscv32")
        return Arch.RISCV32;
    if (str == "riscv64")
        return Arch.RISCV64;
    if (str == "mips")
        return Arch.MIPS;
    if (str == "powerpc" || str == "ppc")
        return Arch.PowerPC;
    if (str == "wasm32")
        return Arch.WASM32;
    if (str == "wasm64")
        return Arch.WASM64;
    
    return Arch.Unknown;
}

/// Parse OS from string
private OS parseOS(string str) @safe
{
    str = str.toLower();
    
    if (str == "linux")
        return OS.Linux;
    if (str == "darwin" || str == "macos" || str == "osx")
        return OS.Darwin;
    if (str == "windows" || str == "win32" || str == "win64")
        return OS.Windows;
    if (str == "freebsd")
        return OS.FreeBSD;
    if (str == "openbsd")
        return OS.OpenBSD;
    if (str == "netbsd")
        return OS.NetBSD;
    if (str == "solaris")
        return OS.Solaris;
    if (str == "android")
        return OS.Android;
    if (str == "ios")
        return OS.iOS;
    if (str == "web" || str == "emscripten")
        return OS.Web;
    
    return OS.Unknown;
}

/// Parse ABI from string
private ABI parseABI(string str) @safe
{
    str = str.toLower();
    
    if (str == "gnu")
        return ABI.GNU;
    if (str == "musl")
        return ABI.MUSL;
    if (str == "msvc")
        return ABI.MSVC;
    if (str == "mingw")
        return ABI.MinGW;
    if (str == "darwin")
        return ABI.Darwin;
    if (str == "android")
        return ABI.Android;
    if (str == "eabi")
        return ABI.EABI;
    if (str == "eabihf")
        return ABI.EABIHF;
    
    return ABI.Unknown;
}

/// Convert architecture to string
private string archToString(Arch arch) pure nothrow @safe
{
    final switch (arch)
    {
        case Arch.X86: return "i686";
        case Arch.X86_64: return "x86_64";
        case Arch.ARM: return "arm";
        case Arch.ARM64: return "aarch64";
        case Arch.RISCV32: return "riscv32";
        case Arch.RISCV64: return "riscv64";
        case Arch.MIPS: return "mips";
        case Arch.PowerPC: return "powerpc";
        case Arch.WASM32: return "wasm32";
        case Arch.WASM64: return "wasm64";
        case Arch.Unknown: return "unknown";
    }
}

/// Convert OS to string
private string osToString(OS os) pure nothrow @safe
{
    final switch (os)
    {
        case OS.Linux: return "linux";
        case OS.Darwin: return "darwin";
        case OS.Windows: return "windows";
        case OS.FreeBSD: return "freebsd";
        case OS.OpenBSD: return "openbsd";
        case OS.NetBSD: return "netbsd";
        case OS.Solaris: return "solaris";
        case OS.Android: return "android";
        case OS.iOS: return "ios";
        case OS.Web: return "web";
        case OS.Unknown: return "unknown";
    }
}

/// Convert ABI to string
private string abiToString(ABI abi) pure nothrow @safe
{
    final switch (abi)
    {
        case ABI.GNU: return "gnu";
        case ABI.MUSL: return "musl";
        case ABI.MSVC: return "msvc";
        case ABI.MinGW: return "mingw";
        case ABI.Darwin: return "darwin";
        case ABI.Android: return "android";
        case ABI.EABI: return "eabi";
        case ABI.EABIHF: return "eabihf";
        case ABI.Unknown: return "";
    }
}

@system unittest
{
    // Test platform parsing
    auto result = Platform.parse("x86_64-unknown-linux-gnu");
    assert(result.isOk);
    
    auto platform = result.unwrap();
    assert(platform.arch == Arch.X86_64);
    assert(platform.os == OS.Linux);
    assert(platform.abi == ABI.GNU);
    
    // Test round-trip
    assert(platform.toTriple() == "x86_64-unknown-linux-gnu");
    
    // Test host detection
    auto hostPlatform = Platform.host();
    assert(hostPlatform.arch != Arch.Unknown);
    assert(hostPlatform.os != OS.Unknown);
}

@system unittest
{
    // Test cross-compilation detection
    auto host = Platform(Arch.X86_64, OS.Linux, ABI.GNU);
    auto armTarget = Platform(Arch.ARM64, OS.Linux, ABI.GNU);
    
    assert(armTarget.isCross());  // Different arch = cross compile
    
    // Test compatibility
    auto x86 = Platform(Arch.X86, OS.Linux, ABI.GNU);
    auto x86_64 = Platform(Arch.X86_64, OS.Linux, ABI.GNU);
    
    assert(x86_64.compatibleWith(x86));  // x86_64 can run x86
    assert(!x86.compatibleWith(x86_64)); // x86 cannot run x86_64
}

