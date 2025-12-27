module languages.gpu.rocm.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.process : environment;
import languages.base;
import languages.gpu.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// ROCm/HIP output types
enum ROCmOutputType
{
    Object,
    HIPFatbin,
    Executable,
    SharedLib,
    StaticLib
}

/// ROCm/HIP language handler - leverages BaseGPUHandler for common functionality
class ROCmHandler : BaseGPUHandler
{
    this() { super(null); }
    
    override protected string languageId() const pure nothrow => "rocm";
    
    override protected string[] configKeys() const pure nothrow => ["rocm", "hip", "rocmConfig", "hipConfig"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "ROCm toolkit not found. Install ROCm and ensure hipcc is in PATH.";
    
    override protected bool isDeviceSource(string path) const pure nothrow =>
        path.endsWith(".hip") || path.endsWith(".hip.cpp") || 
        path.endsWith(".cu");  // HIP can compile CUDA sources
    
    override protected string[] deviceExtensions() const pure nothrow => [".hip", ".hip.cpp", ".cu"];
    
    /// Detect hipcc from config, environment, or common paths
    override protected string detectToolkit(GPUConfig config) @system
    {
        // Config path
        if (!config.toolkitPath.empty)
        {
            auto hipcc = buildPath(config.toolkitPath, "bin", "hipcc");
            if (exists(hipcc)) return hipcc;
        }
        
        // Environment
        auto rocmPath = environment.get("ROCM_PATH", environment.get("HIP_PATH", ""));
        if (!rocmPath.empty)
        {
            auto hipcc = buildPath(rocmPath, "bin", "hipcc");
            if (exists(hipcc)) return hipcc;
        }
        
        // Common paths (Linux only)
        version(linux)
        {
            foreach (path; ["/opt/rocm/bin/hipcc", "/usr/local/rocm/bin/hipcc"])
                if (exists(path)) return path;
        }
        
        // PATH
        return detectTool([], "ROCM_PATH", "hipcc");
    }
    
    /// Get ROCm/AMD architecture flags (--offload-arch)
    override protected string[] getArchFlags(GPUConfig config) pure nothrow
    {
        if (config.architectures.empty)
            return ["--offload-arch=gfx906"];  // Default to gfx906 (MI50)
        
        string[] flags;
        foreach (arch; config.architectures)
        {
            // Support gfx format
            if (arch.startsWith("gfx"))
                flags ~= ["--offload-arch=" ~ arch];
            else
                flags ~= ["--offload-arch=gfx" ~ arch];
        }
        return flags;
    }
    
    /// Build hipcc compile command for device/host source
    override protected string[] buildDeviceCompileCmd(
        string source, string objFile, string toolPath, GPUConfig config
    ) pure nothrow
    {
        string[] cmd = [toolPath, "-c"];
        
        // Architecture
        cmd ~= getArchFlags(config);
        
        // Optimization
        cmd ~= config.compiled.optLevel.toFlag();
        
        // Debug info
        if (config.compiled.base.debugInfo)
            cmd ~= "-g";
        
        // Fast math
        if (config.fastMath)
            cmd ~= "-ffast-math";
        
        // C++ standard
        if (!config.cxxStd.empty)
            cmd ~= "-std=" ~ config.cxxStd;
        
        // Include directories
        foreach (inc; config.compiled.base.includeDirs)
            cmd ~= ["-I", inc];
        
        // Defines
        foreach (def; config.compiled.base.defines)
            cmd ~= ["-D", def];
        
        // Generate dependencies if requested
        if (config.genDeps)
        {
            string depFile = objFile.stripExtension ~ ".d";
            cmd ~= ["-MMD", "-MF", depFile];
        }
        
        // Extra flags
        cmd ~= config.compiled.base.extraFlags;
        
        // Verbose
        if (config.compiled.base.verbosity >= Verbosity.Verbose)
            cmd ~= "-v";
        
        // Output and input
        cmd ~= ["-o", objFile, source];
        
        return cmd;
    }
    
    /// Host compilation uses same hipcc command (it handles host code)
    override protected string[] buildHostCompileCmd(
        string source, string objFile, string toolPath, GPUConfig config
    ) pure nothrow
    {
        // HIP's hipcc handles host code compilation automatically
        return buildDeviceCompileCmd(source, objFile, toolPath, config);
    }
    
    /// Build link command
    override protected string[] buildLinkCmd(
        string[] objects, string output, string toolPath, GPUConfig config, GPUOutputType gpuType
    ) pure nothrow
    {
        ROCmOutputType outputType = cast(ROCmOutputType)gpuType;
        
        string[] cmd;
        
        if (outputType == ROCmOutputType.StaticLib)
        {
            // Use ar for static library
            cmd = ["ar", "rcs", output] ~ objects;
        }
        else
        {
            cmd = [toolPath];
            
            // Architecture
            cmd ~= getArchFlags(config);
            
            // Shared library
            if (outputType == ROCmOutputType.SharedLib)
                cmd ~= "-shared";
            
            // Library directories
            foreach (libDir; config.compiled.libDirs)
                cmd ~= ["-L", libDir];
            
            // Libraries
            foreach (lib; config.compiled.libs)
                cmd ~= "-l" ~ lib;
            
            // Output and objects
            cmd ~= ["-o", output] ~ objects;
        }
        
        return cmd;
    }
    
    /// Get output filename with extension
    override protected string getOutputName(string name, GPUOutputType gpuType) const pure nothrow
    {
        ROCmOutputType outputType = cast(ROCmOutputType)gpuType;
        
        final switch (outputType)
        {
            case ROCmOutputType.Object: return name ~ ".o";
            case ROCmOutputType.HIPFatbin: return name ~ ".hipfb";
            case ROCmOutputType.Executable: return name;
            case ROCmOutputType.SharedLib:
                version(OSX) return "lib" ~ name ~ ".dylib";
                else return "lib" ~ name ~ ".so";
            case ROCmOutputType.StaticLib:
                return "lib" ~ name ~ ".a";
        }
    }
}
