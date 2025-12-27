module infrastructure.toolchain.detection.language_detectors;

import infrastructure.toolchain.core.spec;
import infrastructure.toolchain.core.platform;
import infrastructure.toolchain.detection.detector;
import infrastructure.utils.logging;
import std.conv : to;
import std.range : empty;

/// Additional language-specific toolchain detectors

/// Go toolchain detector
class GoDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        auto goPath = ExecutableDetector.findInPath("go");
        if (goPath.empty)
            return [];
        
        auto goVer = ExecutableDetector.detectVersion(goPath, "version");
        
        Toolchain tc;
        tc.name = "go";
        tc.id = "go-" ~ goVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool go;
        go.name = "go";
        go.path = goPath;
        go.version_ = goVer;
        go.type = ToolchainType.Compiler;
        go.capabilities = Capability.CrossCompile | Capability.Incremental | 
                         Capability.StaticAnalysis | Capability.ModernStd |
                         Capability.Parallel;
        tc.tools ~= go;
        
        // Add gofmt
        auto gofmtPath = ExecutableDetector.findInPath("gofmt");
        if (!gofmtPath.empty)
        {
            Tool gofmt;
            gofmt.name = "gofmt";
            gofmt.path = gofmtPath;
            gofmt.version_ = goVer;
            gofmt.type = ToolchainType.BuildTool;
            tc.tools ~= gofmt;
        }
        
        return [tc];
    }
    
    override string name() const @safe
    {
        return "go-detector";
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

/// Python toolchain detector
class PythonDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        Toolchain[] toolchains;
        
        // Try python3 first
        auto py3Path = ExecutableDetector.findInPath("python3");
        if (!py3Path.empty)
        {
            toolchains ~= detectPython(py3Path, "python3");
        }
        
        // Try python
        auto pyPath = ExecutableDetector.findInPath("python");
        if (!pyPath.empty && pyPath != py3Path)
        {
            toolchains ~= detectPython(pyPath, "python");
        }
        
        return toolchains;
    }
    
    private Toolchain detectPython(string path, string name) @system
    {
        auto pyVer = ExecutableDetector.detectVersion(path, "--version");
        
        Toolchain tc;
        tc.name = name;
        tc.id = name ~ "-" ~ pyVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool python;
        python.name = name;
        python.path = path;
        python.version_ = pyVer;
        python.type = ToolchainType.Interpreter;
        python.capabilities = Capability.ModernStd | Capability.Debugging;
        tc.tools ~= python;
        
        // Add pip if available
        auto pipPath = ExecutableDetector.findInPath("pip3");
        if (pipPath.empty)
            pipPath = ExecutableDetector.findInPath("pip");
        
        if (!pipPath.empty)
        {
            Tool pip;
            pip.name = "pip";
            pip.path = pipPath;
            pip.type = ToolchainType.PackageManager;
            tc.tools ~= pip;
        }
        
        return tc;
    }
    
    override string name() const @safe
    {
        return "python-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [Platform.host()];
    }
}

/// Node.js toolchain detector
class NodeDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        auto nodePath = ExecutableDetector.findInPath("node");
        if (nodePath.empty)
            return [];
        
        auto nodeVer = ExecutableDetector.detectVersion(nodePath, "--version");
        
        Toolchain tc;
        tc.name = "node";
        tc.id = "node-" ~ nodeVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool node;
        node.name = "node";
        node.path = nodePath;
        node.version_ = nodeVer;
        node.type = ToolchainType.Runtime;
        node.capabilities = Capability.ModernStd | Capability.Debugging;
        tc.tools ~= node;
        
        // Add npm
        auto npmPath = ExecutableDetector.findInPath("npm");
        if (!npmPath.empty)
        {
            Tool npm;
            npm.name = "npm";
            npm.path = npmPath;
            npm.type = ToolchainType.PackageManager;
            tc.tools ~= npm;
        }
        
        // Add npx
        auto npxPath = ExecutableDetector.findInPath("npx");
        if (!npxPath.empty)
        {
            Tool npx;
            npx.name = "npx";
            npx.path = npxPath;
            npx.type = ToolchainType.BuildTool;
            tc.tools ~= npx;
        }
        
        return [tc];
    }
    
    override string name() const @safe
    {
        return "node-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [Platform.host()];
    }
}

/// Java/JDK toolchain detector
class JavaDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        auto javaPath = ExecutableDetector.findInPath("java");
        if (javaPath.empty)
            return [];
        
        auto javaVer = ExecutableDetector.detectVersion(javaPath, "-version");
        
        Toolchain tc;
        tc.name = "java";
        tc.id = "java-" ~ javaVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool java;
        java.name = "java";
        java.path = javaPath;
        java.version_ = javaVer;
        java.type = ToolchainType.Runtime;
        java.capabilities = Capability.Debugging | Capability.ModernStd;
        tc.tools ~= java;
        
        // Add javac
        auto javacPath = ExecutableDetector.findInPath("javac");
        if (!javacPath.empty)
        {
            Tool javac;
            javac.name = "javac";
            javac.path = javacPath;
            javac.version_ = javaVer;
            javac.type = ToolchainType.Compiler;
            javac.capabilities = Capability.Incremental | Capability.Optimization;
            tc.tools ~= javac;
        }
        
        return [tc];
    }
    
    override string name() const @safe
    {
        return "java-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [Platform.host()];
    }
}

/// Zig toolchain detector
class ZigDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        auto zigPath = ExecutableDetector.findInPath("zig");
        if (zigPath.empty)
            return [];
        
        auto zigVer = ExecutableDetector.detectVersion(zigPath, "version");
        
        Toolchain tc;
        tc.name = "zig";
        tc.id = "zig-" ~ zigVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool zig;
        zig.name = "zig";
        zig.path = zigPath;
        zig.version_ = zigVer;
        zig.type = ToolchainType.Compiler;
        zig.capabilities = Capability.CrossCompile | Capability.LTO | 
                          Capability.Optimization | Capability.Debugging |
                          Capability.StaticAnalysis | Capability.Hermetic;
        tc.tools ~= zig;
        
        return [tc];
    }
    
    override string name() const @safe
    {
        return "zig-detector";
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

/// D language compiler detector
class DCompilerDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        Toolchain[] toolchains;
        
        // Try LDC (LLVM-based D compiler)
        auto ldcPath = ExecutableDetector.findInPath("ldc2");
        if (!ldcPath.empty)
        {
            toolchains ~= detectDCompiler(ldcPath, "ldc2", "ldc");
        }
        
        // Try DMD (reference compiler)
        auto dmdPath = ExecutableDetector.findInPath("dmd");
        if (!dmdPath.empty)
        {
            toolchains ~= detectDCompiler(dmdPath, "dmd", "dmd");
        }
        
        // Try GDC (GCC-based)
        auto gdcPath = ExecutableDetector.findInPath("gdc");
        if (!gdcPath.empty)
        {
            toolchains ~= detectDCompiler(gdcPath, "gdc", "gdc");
        }
        
        return toolchains;
    }
    
    private Toolchain detectDCompiler(string path, string name, string tcName) @system
    {
        auto dVer = ExecutableDetector.detectVersion(path, "--version");
        
        Toolchain tc;
        tc.name = tcName;
        tc.id = tcName ~ "-" ~ dVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool dcomp;
        dcomp.name = name;
        dcomp.path = path;
        dcomp.version_ = dVer;
        dcomp.type = ToolchainType.Compiler;
        dcomp.capabilities = Capability.Incremental | Capability.Optimization | 
                           Capability.Debugging | Capability.ModernStd |
                           Capability.StaticAnalysis;
        
        // LDC has more capabilities
        if (tcName == "ldc")
        {
            dcomp.capabilities |= Capability.LTO | Capability.PGO | 
                                Capability.CrossCompile;
        }
        
        tc.tools ~= dcomp;
        
        // Add dub (D package manager)
        auto dubPath = ExecutableDetector.findInPath("dub");
        if (!dubPath.empty)
        {
            Tool dub;
            dub.name = "dub";
            dub.path = dubPath;
            dub.type = ToolchainType.PackageManager;
            tc.tools ~= dub;
        }
        
        return tc;
    }
    
    override string name() const @safe
    {
        return "d-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [
            Platform(Arch.X86_64, OS.Linux, ABI.GNU),
            Platform(Arch.X86_64, OS.Darwin, ABI.Darwin),
            Platform(Arch.X86_64, OS.Windows, ABI.MSVC)
        ];
    }
}

/// CMake build tool detector
class CMakeDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        auto cmakePath = ExecutableDetector.findInPath("cmake");
        if (cmakePath.empty)
            return [];
        
        auto cmakeVer = ExecutableDetector.detectVersion(cmakePath, "--version");
        
        Toolchain tc;
        tc.name = "cmake";
        tc.id = "cmake-" ~ cmakeVer.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool cmake;
        cmake.name = "cmake";
        cmake.path = cmakePath;
        cmake.version_ = cmakeVer;
        cmake.type = ToolchainType.BuildTool;
        cmake.capabilities = Capability.CrossCompile | Capability.Parallel;
        tc.tools ~= cmake;
        
        // Add ninja if available
        auto ninjaPath = ExecutableDetector.findInPath("ninja");
        if (!ninjaPath.empty)
        {
            Tool ninja;
            ninja.name = "ninja";
            ninja.path = ninjaPath;
            ninja.type = ToolchainType.BuildTool;
            ninja.capabilities = Capability.Parallel | Capability.Incremental;
            tc.tools ~= ninja;
        }
        
        return [tc];
    }
    
    override string name() const @safe
    {
        return "cmake-detector";
    }
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [Platform.host()];
    }
}

/// Register all additional detectors with AutoDetector
void registerAllDetectors(AutoDetector detector) @system
{
    detector.register(new GoDetector());
    detector.register(new PythonDetector());
    detector.register(new NodeDetector());
    detector.register(new JavaDetector());
    detector.register(new ZigDetector());
    detector.register(new DCompilerDetector());
    detector.register(new CMakeDetector());
}

