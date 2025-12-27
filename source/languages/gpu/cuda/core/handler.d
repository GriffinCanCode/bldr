module languages.gpu.cuda.core.handler;

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

/// CUDA-specific output types
enum CUDAOutputType
{
    Object,
    PTX,
    Cubin,
    Fatbin,
    DeviceLib,
    Executable,
    SharedLib,
    StaticLib
}

/// CUDA language handler - leverages BaseGPUHandler for common functionality
class CUDAHandler : BaseGPUHandler
{
    this() { super(null); }
    
    override protected string languageId() const pure nothrow => "cuda";
    
    override protected string[] configKeys() const pure nothrow => ["cuda", "cudaConfig"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "CUDA toolkit not found. Install CUDA toolkit and ensure nvcc is in PATH.";
    
    override protected bool isDeviceSource(string path) const pure nothrow =>
        path.endsWith(".cu") || path.endsWith(".cuh");
    
    override protected string[] deviceExtensions() const pure nothrow => [".cu", ".cuh"];
    
    /// Detect nvcc from config, environment, or common paths
    override protected string detectToolkit(GPUConfig config) @system
    {
        // Config path
        if (!config.toolkitPath.empty)
        {
            auto nvcc = buildPath(config.toolkitPath, "bin", "nvcc");
            if (exists(nvcc)) return nvcc;
        }
        
        // Environment
        auto cudaHome = environment.get("CUDA_HOME", environment.get("CUDA_PATH", ""));
        if (!cudaHome.empty)
        {
            auto nvcc = buildPath(cudaHome, "bin", "nvcc");
            if (exists(nvcc)) return nvcc;
        }
        
        // Common paths
        version(linux)
        {
            foreach (path; ["/usr/local/cuda/bin/nvcc", "/opt/cuda/bin/nvcc"])
                if (exists(path)) return path;
        }
        version(OSX)
        {
            foreach (path; ["/usr/local/cuda/bin/nvcc", "/opt/cuda/bin/nvcc"])
                if (exists(path)) return path;
        }
        version(Windows)
        {
            auto progFiles = environment.get("ProgramFiles", "C:\\Program Files");
            auto nvidiaPath = buildPath(progFiles, "NVIDIA GPU Computing Toolkit", "CUDA");
            if (exists(nvidiaPath))
            {
                import std.file : dirEntries, SpanMode;
                foreach (entry; dirEntries(nvidiaPath, SpanMode.shallow))
                {
                    auto nvcc = buildPath(entry.name, "bin", "nvcc.exe");
                    if (exists(nvcc)) return nvcc;
                }
            }
        }
        
        // PATH
        return detectTool([], "CUDA_HOME", "nvcc");
    }
    
    /// Get CUDA architecture flags (-gencode options)
    override protected string[] getArchFlags(GPUConfig config) pure nothrow
    {
        if (config.architectures.empty)
            return ["-arch=sm_50"];  // Default to sm_50
        
        string[] flags;
        foreach (arch; config.architectures)
        {
            // Support both sm_XX and compute_XX formats
            if (arch.startsWith("sm_") || arch.startsWith("compute_"))
            {
                string compute = arch.replace("sm_", "compute_");
                string sm = arch.replace("compute_", "sm_");
                flags ~= "-gencode";
                flags ~= "arch=" ~ compute ~ ",code=" ~ sm;
            }
            else
            {
                // Assume it's a simple arch like "50" -> sm_50
                flags ~= "-arch=sm_" ~ arch;
            }
        }
        return flags;
    }
    
    /// Build nvcc command for device source
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
            cmd ~= ["-g", "-G"];
        
        if (config.lineInfo)
            cmd ~= "-lineinfo";
        
        // Relocatable device code
        if (config.relocatable)
            cmd ~= "-rdc=true";
        
        // Fast math
        if (config.fastMath)
            cmd ~= "--use_fast_math";
        
        // Max registers
        if (config.maxRegisters > 0)
            cmd ~= ["--maxrregcount", config.maxRegisters.to!string];
        
        // C++ standard
        if (!config.cxxStd.empty)
            cmd ~= "-std=" ~ config.cxxStd;
        
        // Include directories
        foreach (inc; config.compiled.base.includeDirs)
            cmd ~= ["-I", inc];
        
        // Defines
        foreach (def; config.compiled.base.defines)
            cmd ~= ["-D", def];
        
        // Host compiler flags
        foreach (flag; config.hostFlags)
            cmd ~= ["-Xcompiler", flag];
        
        // Host compiler
        if (!config.hostCompiler.empty)
            cmd ~= ["-ccbin", config.hostCompiler];
        
        // Verbose
        if (config.compiled.base.verbosity >= Verbosity.Verbose)
            cmd ~= "-v";
        
        // Extra flags
        cmd ~= config.compiled.base.extraFlags;
        
        // Output and input
        cmd ~= ["-o", objFile, source];
        
        return cmd;
    }
    
    /// Build nvcc command for host source (C/C++ with CUDA runtime linkage)
    override protected string[] buildHostCompileCmd(
        string source, string objFile, string toolPath, GPUConfig config
    ) pure nothrow
    {
        string[] cmd = [toolPath, "-c"];
        
        // Optimization
        cmd ~= config.compiled.optLevel.toFlag();
        
        // Debug
        if (config.compiled.base.debugInfo)
            cmd ~= "-g";
        
        // C++ standard
        if (!config.cxxStd.empty)
            cmd ~= "-std=" ~ config.cxxStd;
        
        // Includes
        foreach (inc; config.compiled.base.includeDirs)
            cmd ~= ["-I", inc];
        
        // Host flags
        foreach (flag; config.hostFlags)
            cmd ~= ["-Xcompiler", flag];
        
        // Host compiler
        if (!config.hostCompiler.empty)
            cmd ~= ["-ccbin", config.hostCompiler];
        
        cmd ~= ["-o", objFile, source];
        
        return cmd;
    }
    
    /// Build link command
    override protected string[] buildLinkCmd(
        string[] objects, string output, string toolPath, GPUConfig config, GPUOutputType outputType
    ) pure nothrow
    {
        string[] cmd;
        
        if (outputType == GPUOutputType.StaticLib)
        {
            // Use ar for static library
            version(Windows)
                cmd = ["lib", "/OUT:" ~ output] ~ objects;
            else
                cmd = ["ar", "rcs", output] ~ objects;
        }
        else
        {
            cmd = [toolPath];
            
            // Device link if relocatable
            if (config.relocatable)
                cmd ~= "-dlink";
            
            // Shared library
            if (outputType == GPUOutputType.SharedLib)
                cmd ~= "-shared";
            
            // Architecture
            cmd ~= getArchFlags(config);
            
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
    override protected string getOutputName(string name, GPUOutputType outputType) const pure nothrow
    {
        final switch (outputType)
        {
            case GPUOutputType.Object: return name ~ ".o";
            case GPUOutputType.PTX: return name ~ ".ptx";
            case GPUOutputType.Cubin: return name ~ ".cubin";
            case GPUOutputType.Fatbin: return name ~ ".fatbin";
            case GPUOutputType.DeviceLib: return name ~ ".dlink.o";
            case GPUOutputType.Executable: return name;
            case GPUOutputType.SharedLib:
                version(Windows) return name ~ ".dll";
                else version(OSX) return "lib" ~ name ~ ".dylib";
                else return "lib" ~ name ~ ".so";
            case GPUOutputType.StaticLib:
                version(Windows) return name ~ ".lib";
                else return "lib" ~ name ~ ".a";
            // Metal/ROCm specific - not applicable for CUDA
            case GPUOutputType.AIR: return name ~ ".air";
            case GPUOutputType.MetalLib: return name ~ ".metallib";
            case GPUOutputType.HIPFatbin: return name ~ ".hipfatbin";
        }
    }
}
