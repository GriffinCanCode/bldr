module infrastructure.toolchain.detection.gpu_detectors;

import std.process : execute, environment;
import std.file : exists;
import std.path : buildPath;
import std.range : empty;
import std.string : strip, split, indexOf;
import std.regex : matchFirst, regex;
import std.conv : to;
import infrastructure.toolchain.core.spec;
import infrastructure.toolchain.core.platform;
import infrastructure.toolchain.detection.detector;
import infrastructure.utils.logging;

/// NVIDIA CUDA toolchain detector (nvcc)
class CUDADetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        auto nvccPath = findNvcc();
        if (nvccPath.empty)
            return [];
        
        auto ver = detectNvccVersion(nvccPath);
        
        Toolchain tc;
        tc.name = "cuda";
        tc.id = "cuda-" ~ ver.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        // nvcc compiler
        Tool nvcc;
        nvcc.name = "nvcc";
        nvcc.path = nvccPath;
        nvcc.version_ = ver;
        nvcc.type = ToolchainType.Compiler;
        nvcc.capabilities = Capability.CrossCompile | Capability.Optimization | Capability.Debugging;
        tc.tools ~= nvcc;
        
        // Try to find nvlink
        auto cudaDir = getCUDADir(nvccPath);
        if (!cudaDir.empty)
        {
            auto nvlinkPath = buildPath(cudaDir, "bin", "nvlink");
            version(Windows) nvlinkPath ~= ".exe";
            
            if (exists(nvlinkPath))
            {
                Tool nvlink;
                nvlink.name = "nvlink";
                nvlink.path = nvlinkPath;
                nvlink.version_ = ver;
                nvlink.type = ToolchainType.Linker;
                tc.tools ~= nvlink;
            }
        }
        
        structuredLog.debug_("detected_cuda_").field("detail", "Detected CUDA " ~ ver.toString()).emit();
        
        return [tc];
    }
    
    override string name() const @safe => "cuda-detector";
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [
            Platform(Arch.X86_64, OS.Linux, ABI.GNU),
            Platform(Arch.X86_64, OS.Windows, ABI.MSVC),
            Platform(Arch.ARM64, OS.Linux, ABI.GNU)
        ];
    }
    
    private string findNvcc() @system
    {
        // Check environment
        auto cudaHome = environment.get("CUDA_HOME", environment.get("CUDA_PATH", ""));
        if (!cudaHome.empty)
        {
            auto nvcc = buildPath(cudaHome, "bin", "nvcc");
            version(Windows) nvcc ~= ".exe";
            if (exists(nvcc)) return nvcc;
        }
        
        // Common paths
        version(linux)
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
        
        return ExecutableDetector.findInPath("nvcc");
    }
    
    private Version detectNvccVersion(string nvccPath) @system
    {
        try
        {
            auto res = execute([nvccPath, "--version"]);
            if (res.status != 0) return Version(0, 0, 0);
            
            // Parse "release X.Y, VX.Y.Z"
            auto match = matchFirst(res.output, regex(`release (\d+)\.(\d+), V(\d+)\.(\d+)\.(\d+)`));
            if (!match.empty && match.length >= 6)
            {
                return Version(
                    match[3].to!uint,
                    match[4].to!uint,
                    match[5].to!uint
                );
            }
        }
        catch (Exception) {}
        return Version(0, 0, 0);
    }
    
    private string getCUDADir(string nvccPath) @system
    {
        import std.path : dirName;
        auto binDir = dirName(nvccPath);
        return dirName(binDir);  // Go up from bin/
    }
}

/// AMD ROCm/HIP toolchain detector (hipcc)
class ROCmDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        auto hipccPath = findHipcc();
        if (hipccPath.empty)
            return [];
        
        auto ver = detectHipccVersion(hipccPath);
        
        Toolchain tc;
        tc.name = "rocm";
        tc.id = "rocm-" ~ ver.toString();
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool hipcc;
        hipcc.name = "hipcc";
        hipcc.path = hipccPath;
        hipcc.version_ = ver;
        hipcc.type = ToolchainType.Compiler;
        hipcc.capabilities = Capability.CrossCompile | Capability.Optimization | Capability.Debugging;
        tc.tools ~= hipcc;
        
        structuredLog.debug_("detected_rocm_").field("detail", "Detected ROCm " ~ ver.toString()).emit();
        
        return [tc];
    }
    
    override string name() const @safe => "rocm-detector";
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [Platform(Arch.X86_64, OS.Linux, ABI.GNU)];
    }
    
    private string findHipcc() @system
    {
        auto rocmPath = environment.get("ROCM_PATH", environment.get("HIP_PATH", ""));
        if (!rocmPath.empty)
        {
            auto hipcc = buildPath(rocmPath, "bin", "hipcc");
            if (exists(hipcc)) return hipcc;
        }
        
        version(linux)
        {
            foreach (path; ["/opt/rocm/bin/hipcc", "/usr/local/rocm/bin/hipcc"])
                if (exists(path)) return path;
        }
        
        return ExecutableDetector.findInPath("hipcc");
    }
    
    private Version detectHipccVersion(string hipccPath) @system
    {
        try
        {
            auto res = execute([hipccPath, "--version"]);
            if (res.status != 0) return Version(0, 0, 0);
            
            auto match = matchFirst(res.output, regex(`HIP version: (\d+)\.(\d+)\.(\d+)`));
            if (!match.empty && match.length >= 4)
            {
                return Version(match[1].to!uint, match[2].to!uint, match[3].to!uint);
            }
        }
        catch (Exception) {}
        return Version(0, 0, 0);
    }
}

/// Apple Metal toolchain detector
class MetalDetector : ToolchainDetector
{
    override Toolchain[] detect() @system
    {
        version(OSX)
        {
            auto xcrunPath = ExecutableDetector.findInPath("xcrun");
            if (xcrunPath.empty)
                return [];
            
            // Verify metal compiler is available
            try
            {
                auto res = execute([xcrunPath, "-sdk", "macosx", "metal", "--version"]);
                if (res.status != 0) return [];
                
                auto ver = parseMetalVersion(res.output);
                
                Toolchain tc;
                tc.name = "metal";
                tc.id = "metal-" ~ ver.toString();
                tc.host = Platform.host();
                tc.target = Platform.host();
                
                Tool metal;
                metal.name = "metal";
                metal.path = xcrunPath;  // Use xcrun as the entry point
                metal.version_ = ver;
                metal.type = ToolchainType.Compiler;
                metal.capabilities = Capability.Optimization | Capability.Debugging;
                tc.tools ~= metal;
                
                structuredLog.debug_("detected_metal_").field("detail", "Detected Metal " ~ ver.toString()).emit();
                
                return [tc];
            }
            catch (Exception) {}
        }
        return [];
    }
    
    override string name() const @safe => "metal-detector";
    
    override Platform[] supportedPlatforms() const @safe
    {
        return [
            Platform(Arch.X86_64, OS.Darwin, ABI.Darwin),
            Platform(Arch.ARM64, OS.Darwin, ABI.Darwin)
        ];
    }
    
    private Version parseMetalVersion(string output) @system
    {
        auto match = matchFirst(output, regex(`(\d+)\.(\d+)\.(\d+)`));
        if (!match.empty && match.length >= 4)
        {
            return Version(match[1].to!uint, match[2].to!uint, match[3].to!uint);
        }
        return Version(0, 0, 0);
    }
}

/// Register GPU detectors with auto-detector
void registerGPUDetectors(AutoDetector detector) @system
{
    detector.register(new CUDADetector());
    detector.register(new ROCmDetector());
    detector.register(new MetalDetector());
}

