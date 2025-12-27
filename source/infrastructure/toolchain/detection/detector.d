module infrastructure.toolchain.detection.detector;

import std.process : execute, environment;
import std.file : exists;
import std.path : buildPath;
import std.string : strip, split, startsWith, indexOf;
import std.algorithm : map, filter;
import std.array : array, empty;
import std.regex : matchFirst, regex;
import std.conv : to;
import infrastructure.toolchain.core.spec;
import infrastructure.toolchain.core.platform;
import infrastructure.utils.logging;
import infrastructure.errors : ErrorCode, BuildError, BuildResult, Err, Ok, 
    VoidBuildResult, Errors;

/// Toolchain detector interface
interface ToolchainDetector
{
    /// Detect all available toolchains of this type
    Toolchain[] detect() @system;
    
    /// Get detector name
    string name() const @safe;
    
    /// Get supported platforms
    Platform[] supportedPlatforms() const @safe;
}

/// Generic executable-based toolchain detector
/// Uses version commands to detect tools
class ExecutableDetector : ToolchainDetector
{
    private string toolName;
    private string versionCommand;
    private ToolchainType toolType;
    
    this(string toolName, string versionCommand = "--version", ToolchainType toolType = ToolchainType.Compiler)
    {
        this.toolName = toolName;
        this.versionCommand = versionCommand;
        this.toolType = toolType;
    }
    
    override Toolchain[] detect() @system
    {
        auto path = findInPath(toolName);
        if (path.empty)
            return [];
        
        auto ver = detectVersion(path, versionCommand);
        
        Toolchain tc;
        tc.name = toolName;
        tc.id = toolName ~ "-" ~ ver.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool tool;
        tool.name = toolName;
        tool.path = path;
        tool.version_ = ver;
        tool.type = toolType;
        tool.capabilities = Capability.None;
        
        tc.tools = [tool];
        
        return [tc];
    }
    
    override string name() const @safe
    {
        return toolName ~ "-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [Platform.host()];
    }
    
    /// Find executable in PATH
    public static string findInPath(string executable) @system
    {
        version(Windows)
        {
            if (!executable.endsWith(".exe"))
                executable ~= ".exe";
        }
        
        auto pathEnv = environment.get("PATH", "");
        
        version(Windows)
            auto paths = pathEnv.split(";");
        else
            auto paths = pathEnv.split(":");
        
        foreach (dir; paths)
        {
            auto fullPath = buildPath(dir, executable);
            if (exists(fullPath))
                return fullPath;
        }
        
        // Try executing directly (might be in PATH but not found)
        try
        {
            auto res = execute([executable, "--version"]);
            if (res.status == 0)
                return executable;
        }
        catch (Exception) {}
        
        return "";
    }
    
    /// Detect version from version command output
    public static Version detectVersion(string executablePath, string versionCmd) @system
    {
        try
        {
            auto res = execute([executablePath, versionCmd]);
            if (res.status != 0)
                return Version(0, 0, 0);
            
            // Try to extract version from output (look for x.y.z pattern)
            auto versionMatch = matchFirst(res.output, regex(`(\d+)\.(\d+)\.(\d+)`));
            if (!versionMatch.empty && versionMatch.length >= 4)
            {
                import std.conv : to;
                Version ver;
                ver.major = versionMatch[1].to!uint;
                ver.minor = versionMatch[2].to!uint;
                ver.patch = versionMatch[3].to!uint;
                return ver;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_detect_version_").field("detail", "Failed to detect version: " ~ e.msg).emit();
        }
        
        return Version(0, 0, 0);
    }
}

/// GCC toolchain detector
class GCCDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        Toolchain[] toolchains;
        
        // Detect gcc and g++
        auto gccPath = ExecutableDetector.findInPath("gcc");
        auto gxxPath = ExecutableDetector.findInPath("g++");
        
        if (gccPath.empty && gxxPath.empty)
            return [];
        
        auto gccVer = ExecutableDetector.detectVersion(gccPath.empty ? gxxPath : gccPath, "--version");
        
        Toolchain tc;
        tc.name = "gcc";
        tc.id = "gcc-" ~ gccVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        // Add compiler tools
        if (!gccPath.empty)
        {
            Tool gcc;
            gcc.name = "gcc";
            gcc.path = gccPath;
            gcc.version_ = gccVer;
            gcc.type = ToolchainType.Compiler;
            gcc.capabilities = Capability.CrossCompile | Capability.LTO | 
                             Capability.Optimization | Capability.Debugging |
                             Capability.ColorDiag;
            tc.tools ~= gcc;
        }
        
        if (!gxxPath.empty)
        {
            Tool gxx;
            gxx.name = "g++";
            gxx.path = gxxPath;
            gxx.version_ = gccVer;
            gxx.type = ToolchainType.Compiler;
            gxx.capabilities = Capability.CrossCompile | Capability.LTO | 
                             Capability.Optimization | Capability.Debugging |
                             Capability.ColorDiag | Capability.Sanitizers;
            tc.tools ~= gxx;
        }
        
        // Add linker
        auto ldPath = ExecutableDetector.findInPath("ld");
        if (!ldPath.empty)
        {
            Tool ld;
            ld.name = "ld";
            ld.path = ldPath;
            ld.type = ToolchainType.Linker;
            ld.capabilities = Capability.LTO;
            tc.tools ~= ld;
        }
        
        // Add archiver
        auto arPath = ExecutableDetector.findInPath("ar");
        if (!arPath.empty)
        {
            Tool ar;
            ar.name = "ar";
            ar.path = arPath;
            ar.type = ToolchainType.Archiver;
            tc.tools ~= ar;
        }
        
        toolchains ~= tc;
        return toolchains;
    }
    
    override string name() const @safe
    {
        return "gcc-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        // GCC supports many platforms
        return [
            Platform(Arch.X86_64, OS.Linux, ABI.GNU),
            Platform(Arch.X86_64, OS.Darwin, ABI.Darwin),
            Platform(Arch.ARM64, OS.Linux, ABI.GNU),
            Platform(Arch.ARM, OS.Linux, ABI.GNU)
        ];
    }
}

/// Clang/LLVM toolchain detector
class ClangDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        Toolchain[] toolchains;
        
        auto clangPath = ExecutableDetector.findInPath("clang");
        auto clangxxPath = ExecutableDetector.findInPath("clang++");
        
        if (clangPath.empty && clangxxPath.empty)
            return [];
        
        auto clangVer = ExecutableDetector.detectVersion(
            clangPath.empty ? clangxxPath : clangPath, "--version");
        
        Toolchain tc;
        tc.name = "clang";
        tc.id = "clang-" ~ clangVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        // Add compiler tools
        if (!clangPath.empty)
        {
            Tool clang;
            clang.name = "clang";
            clang.path = clangPath;
            clang.version_ = clangVer;
            clang.type = ToolchainType.Compiler;
            clang.capabilities = Capability.CrossCompile | Capability.LTO | 
                               Capability.PGO | Capability.Optimization | 
                               Capability.Debugging | Capability.Sanitizers |
                               Capability.ColorDiag | Capability.JSON |
                               Capability.StaticAnalysis;
            tc.tools ~= clang;
        }
        
        if (!clangxxPath.empty)
        {
            Tool clangxx;
            clangxx.name = "clang++";
            clangxx.path = clangxxPath;
            clangxx.version_ = clangVer;
            clangxx.type = ToolchainType.Compiler;
            clangxx.capabilities = Capability.CrossCompile | Capability.LTO | 
                                 Capability.PGO | Capability.Optimization | 
                                 Capability.Debugging | Capability.Sanitizers |
                                 Capability.ColorDiag | Capability.JSON |
                                 Capability.StaticAnalysis | Capability.Modules;
            tc.tools ~= clangxx;
        }
        
        // Add lld linker if available
        auto lldPath = ExecutableDetector.findInPath("lld");
        if (!lldPath.empty)
        {
            Tool lld;
            lld.name = "lld";
            lld.path = lldPath;
            lld.type = ToolchainType.Linker;
            lld.capabilities = Capability.LTO | Capability.Parallel;
            tc.tools ~= lld;
        }
        
        // Add llvm-ar
        auto llvmArPath = ExecutableDetector.findInPath("llvm-ar");
        if (!llvmArPath.empty)
        {
            Tool llvmAr;
            llvmAr.name = "llvm-ar";
            llvmAr.path = llvmArPath;
            llvmAr.type = ToolchainType.Archiver;
            tc.tools ~= llvmAr;
        }
        
        toolchains ~= tc;
        return toolchains;
    }
    
    override string name() const @safe
    {
        return "clang-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        // Clang supports many platforms
        return [
            Platform(Arch.X86_64, OS.Linux, ABI.GNU),
            Platform(Arch.X86_64, OS.Darwin, ABI.Darwin),
            Platform(Arch.ARM64, OS.Linux, ABI.GNU),
            Platform(Arch.ARM64, OS.Darwin, ABI.Darwin),
            Platform(Arch.ARM, OS.Linux, ABI.GNU),
            Platform(Arch.WASM32, OS.Web, ABI.Unknown)
        ];
    }
}

/// Rust toolchain detector (rustc + cargo)
class RustDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        Toolchain[] toolchains;
        
        auto rustcPath = ExecutableDetector.findInPath("rustc");
        if (rustcPath.empty)
            return [];
        
        auto rustcVer = ExecutableDetector.detectVersion(rustcPath, "--version");
        
        Toolchain tc;
        tc.name = "rust";
        tc.id = "rust-" ~ rustcVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        // Add rustc
        Tool rustc;
        rustc.name = "rustc";
        rustc.path = rustcPath;
        rustc.version_ = rustcVer;
        rustc.type = ToolchainType.Compiler;
        rustc.capabilities = Capability.CrossCompile | Capability.LTO | 
                           Capability.Incremental | Capability.ModernStd |
                           Capability.Debugging | Capability.Optimization |
                           Capability.JSON | Capability.ColorDiag;
        tc.tools ~= rustc;
        
        // Add cargo
        auto cargoPath = ExecutableDetector.findInPath("cargo");
        if (!cargoPath.empty)
        {
            Tool cargo;
            cargo.name = "cargo";
            cargo.path = cargoPath;
            cargo.version_ = rustcVer;
            cargo.type = ToolchainType.PackageManager;
            cargo.capabilities = Capability.Incremental | Capability.Parallel |
                               Capability.JSON;
            tc.tools ~= cargo;
        }
        
        toolchains ~= tc;
        return toolchains;
    }
    
    override string name() const @safe
    {
        return "rust-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [
            Platform(Arch.X86_64, OS.Linux, ABI.GNU),
            Platform(Arch.X86_64, OS.Darwin, ABI.Darwin),
            Platform(Arch.X86_64, OS.Windows, ABI.MSVC),
            Platform(Arch.ARM64, OS.Linux, ABI.GNU),
            Platform(Arch.ARM64, OS.Darwin, ABI.Darwin),
            Platform(Arch.WASM32, OS.Web, ABI.Unknown)
        ];
    }
}

/// Auto-detect all available toolchains
class AutoDetector
{
    private ToolchainDetector[] detectors;
    
    this()
    {
        // Register common detectors
        detectors = [
            cast(ToolchainDetector)new GCCDetector(),
            cast(ToolchainDetector)new ClangDetector(),
            cast(ToolchainDetector)new RustDetector()
        ];
        
        // Register additional detectors
        import infrastructure.toolchain.detection.language_detectors : registerAllDetectors;
        registerAllDetectors(this);
    }
    
    /// Add custom detector
    void register(ToolchainDetector detector)
    {
        detectors ~= detector;
    }
    
    /// Detect all toolchains
    Toolchain[] detectAll() @system
    {
        Toolchain[] allToolchains;
        
        foreach (detector; detectors)
        {
            try
            {
                auto detected = detector.detect();
                allToolchains ~= detected;
                
                structuredLog.debug_("detected_").field("detail", "Detected " ~ detected.length.to!string ~ 
                          " toolchain(s) via " ~ detector.name()).emit();
            }
            catch (Exception e)
            {
                structuredLog.warning("detector_").field("detail", "Detector " ~ detector.name() ~ " failed: " ~ e.msg).emit();
            }
        }
        
        return allToolchains;
    }
    
    /// Find best toolchain for platform and type
    const(Toolchain)* findBest(Platform platform, ToolchainType type = ToolchainType.Compiler) @system
    {
        auto toolchains = detectAll();
        
        // Filter by platform support
        foreach (ref tc; toolchains)
        {
            if (!tc.tools.empty && tc.tools[0].type == type)
            {
                // Check if toolchain can build for target platform
                if (platform == tc.target || platform.compatibleWith(tc.target))
                    return &tc;
            }
        }
        
        return null;
    }
}

@system unittest
{
    import std.stdio : writeln;
    
    writeln("Testing toolchain detection...");
    
    auto detector = new AutoDetector();
    auto toolchains = detector.detectAll();
    
    writeln("Found " ~ toolchains.length.to!string ~ " toolchain(s)");
    
    foreach (tc; toolchains)
    {
        writeln("  - " ~ tc.id);
        writeln("    Tools: " ~ tc.tools.length.to!string);
        writeln("    Complete: " ~ tc.isComplete().to!string);
    }
}

