module languages.compiled.gpu.cuda.core.handler;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.string;
import std.regex;
import languages.base.base;
import languages.base.mixins;
import languages.compiled.gpu.cuda.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// CUDA build result
struct CUDABuildResult
{
    bool success;
    string error;
    string[] outputs;
    string[] objects;
    string outputHash;
    bool hadWarnings;
    string[] warnings;
}

/// CUDA language handler with nvcc integration and dependency tracking
class CUDAHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"cuda";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_cuda_target_").field("detail", "Building CUDA target: " ~ target.name).emit();
        
        // Parse CUDA configuration
        CUDAConfig cudaConfig = parseCUDAConfig(target);
        
        // Detect CUDA toolkit
        auto nvccPath = detectNvcc(cudaConfig);
        if (nvccPath.empty)
        {
            result.error = "CUDA toolkit not found. Install CUDA toolkit and ensure nvcc is in PATH.";
            return result;
        }
        
        structuredLog.info("using_nvcc_").field("detail", "Using nvcc: " ~ nvccPath).emit();
        
        // Create output directories
        string outDir = cudaConfig.outputDir.empty ? config.options.outputDir : cudaConfig.outputDir;
        string objDir = cudaConfig.objDir;
        
        if (!exists(outDir))
            mkdirRecurse(outDir);
        if (!exists(objDir))
            mkdirRecurse(objDir);
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, cudaConfig, nvccPath);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, cudaConfig, nvccPath);
                break;
            case TargetType.Test:
                result = buildAndRunTests(target, config, cudaConfig, nvccPath);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, cudaConfig, nvccPath);
                break;
        }
        
        // Record dependencies for incremental compilation
        if (result.success && context.depRecorder !is null)
        {
            foreach (source; target.sources)
            {
                if (source.endsWith(".cu") || source.endsWith(".cuh"))
                {
                    auto deps = parseDependencyFile(source, objDir);
                    context.depRecorder(source, deps);
                }
            }
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        CUDAConfig cudaConfig = parseCUDAConfig(target);
        string[] outputs;
        
        string outDir = cudaConfig.outputDir.empty ? config.options.outputDir : cudaConfig.outputDir;
        auto name = target.name.split(":")[$ - 1];
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(outDir, target.outputPath);
        }
        else
        {
            final switch (cudaConfig.outputType)
            {
                case CUDAOutputType.Object:
                    outputs ~= buildPath(outDir, name ~ ".o");
                    break;
                case CUDAOutputType.PTX:
                    outputs ~= buildPath(outDir, name ~ ".ptx");
                    break;
                case CUDAOutputType.Cubin:
                    outputs ~= buildPath(outDir, name ~ ".cubin");
                    break;
                case CUDAOutputType.Fatbin:
                    outputs ~= buildPath(outDir, name ~ ".fatbin");
                    break;
                case CUDAOutputType.DeviceLib:
                    outputs ~= buildPath(outDir, name ~ ".dlink.o");
                    break;
                case CUDAOutputType.Executable:
                    outputs ~= buildPath(outDir, name);
                    break;
                case CUDAOutputType.SharedLib:
                    version(Windows)
                        outputs ~= buildPath(outDir, name ~ ".dll");
                    else version(OSX)
                        outputs ~= buildPath(outDir, "lib" ~ name ~ ".dylib");
                    else
                        outputs ~= buildPath(outDir, "lib" ~ name ~ ".so");
                    break;
                case CUDAOutputType.StaticLib:
                    version(Windows)
                        outputs ~= buildPath(outDir, name ~ ".lib");
                    else
                        outputs ~= buildPath(outDir, "lib" ~ name ~ ".a");
                    break;
            }
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = parseCUDAIncludes(content, source);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_").field("detail", "Failed to analyze " ~ source ~ ": " ~ e.msg).emit();
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        CUDAConfig cudaConfig,
        string nvccPath
    ) @system
    {
        cudaConfig.outputType = CUDAOutputType.Executable;
        return compileTarget(target, config, cudaConfig, nvccPath);
    }
    
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        CUDAConfig cudaConfig,
        string nvccPath
    ) @system
    {
        if (cudaConfig.outputType == CUDAOutputType.Object)
            cudaConfig.outputType = CUDAOutputType.StaticLib;
        return compileTarget(target, config, cudaConfig, nvccPath);
    }
    
    private LanguageBuildResult buildAndRunTests(
        in Target target,
        in WorkspaceConfig config,
        CUDAConfig cudaConfig,
        string nvccPath
    ) @system
    {
        LanguageBuildResult result;
        
        // Build test executable
        cudaConfig.outputType = CUDAOutputType.Executable;
        auto buildResult = compileTarget(target, config, cudaConfig, nvccPath);
        
        if (!buildResult.success)
            return buildResult;
        
        // Run tests
        if (!buildResult.outputs.empty)
        {
            string testExe = buildResult.outputs[0];
            structuredLog.info("running_cuda_tests_").field("detail", "Running CUDA tests: " ~ testExe).emit();
            
            auto res = execute([testExe]);
            
            if (res.status != 0)
            {
                result.error = "CUDA tests failed: " ~ res.output;
                return result;
            }
            
            structuredLog.info("cuda_tests_passed").emit();
        }
        
        result.success = true;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        return result;
    }
    
    private LanguageBuildResult buildCustom(
        in Target target,
        in WorkspaceConfig config,
        CUDAConfig cudaConfig,
        string nvccPath
    ) @system
    {
        return compileTarget(target, config, cudaConfig, nvccPath);
    }
    
    private LanguageBuildResult compileTarget(
        in Target target,
        in WorkspaceConfig config,
        CUDAConfig cudaConfig,
        string nvccPath
    ) @system
    {
        LanguageBuildResult result;
        
        // Separate .cu and host files
        string[] cuFiles;
        string[] hostFiles;
        
        foreach (source; target.sources)
        {
            if (source.endsWith(".cu"))
                cuFiles ~= source;
            else if (source.endsWith(".cpp") || source.endsWith(".cc") || source.endsWith(".c"))
                hostFiles ~= source;
        }
        
        string outDir = cudaConfig.outputDir.empty ? config.options.outputDir : cudaConfig.outputDir;
        string objDir = cudaConfig.objDir;
        string[] allObjects;
        
        // Compile .cu files
        foreach (source; cuFiles)
        {
            auto compileResult = compileCUDAFile(source, nvccPath, cudaConfig, objDir, target.name);
            
            if (!compileResult.success)
            {
                result.error = compileResult.error;
                return result;
            }
            
            allObjects ~= compileResult.objects;
        }
        
        // Compile host C++ files with nvcc (for CUDA runtime linkage)
        foreach (source; hostFiles)
        {
            auto compileResult = compileHostFile(source, nvccPath, cudaConfig, objDir, target.name);
            
            if (!compileResult.success)
            {
                result.error = compileResult.error;
                return result;
            }
            
            allObjects ~= compileResult.objects;
        }
        
        // Link if needed
        if (cudaConfig.outputType == CUDAOutputType.Executable ||
            cudaConfig.outputType == CUDAOutputType.SharedLib ||
            cudaConfig.outputType == CUDAOutputType.StaticLib)
        {
            auto linkResult = linkObjects(allObjects, target, config, cudaConfig, nvccPath);
            
            if (!linkResult.success)
            {
                result.error = linkResult.error;
                return result;
            }
            
            result.outputs = linkResult.outputs;
            result.outputHash = linkResult.outputHash;
        }
        else
        {
            result.outputs = allObjects;
            if (!allObjects.empty && exists(allObjects[0]))
                result.outputHash = FastHash.hashFile(allObjects[0]);
        }
        
        result.success = true;
        return result;
    }
    
    private CUDABuildResult compileCUDAFile(
        string source,
        string nvccPath,
        in CUDAConfig config,
        string objDir,
        string targetName
    ) @system
    {
        CUDABuildResult result;
        
        string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
        string depFile = buildPath(objDir, baseName(source).stripExtension ~ ".d");
        
        // Build nvcc command
        string[] cmd = [nvccPath];
        
        // Compilation mode
        cmd ~= "-c";
        
        // Architecture flags
        cmd ~= config.getArchFlags();
        
        // Optimization
        final switch (config.optLevel)
        {
            case CUDAOptLevel.O0: cmd ~= "-O0"; break;
            case CUDAOptLevel.O1: cmd ~= "-O1"; break;
            case CUDAOptLevel.O2: cmd ~= "-O2"; break;
            case CUDAOptLevel.O3: cmd ~= "-O3"; break;
            case CUDAOptLevel.Fast: cmd ~= ["-O3", "--use_fast_math"]; break;
        }
        
        // Debug info
        if (config.debug_)
            cmd ~= ["-g", "-G"];
        
        if (config.lineInfo)
            cmd ~= "-lineinfo";
        
        // Relocatable device code
        if (config.relocatable)
            cmd ~= "-rdc=true";
        
        // Fast math
        if (config.fastMath && config.optLevel != CUDAOptLevel.Fast)
            cmd ~= "--use_fast_math";
        
        // Max registers
        if (config.maxRegCount > 0)
            cmd ~= ["--maxrregcount", config.maxRegCount.to!string];
        
        // C++ standard
        if (!config.cxxStd.empty)
            cmd ~= "-std=" ~ config.cxxStd;
        
        // Include directories
        foreach (inc; config.includeDirs)
            cmd ~= ["-I", inc];
        
        // Dependency generation
        if (config.genDeps)
            cmd ~= ["-M", "-MF", depFile];
        
        // Additional flags
        cmd ~= config.nvccFlags;
        
        // Host compiler flags
        foreach (flag; config.hostFlags)
            cmd ~= ["-Xcompiler", flag];
        
        // Host compiler
        if (!config.hostCompiler.empty)
            cmd ~= ["-ccbin", config.hostCompiler];
        
        // Verbose
        if (config.verbose)
            cmd ~= "-v";
        
        // Output
        cmd ~= ["-o", objFile];
        
        // Input
        cmd ~= source;
        
        structuredLog.debug_("compiling_cuda_").field("detail", "Compiling: " ~ source).emit();
        structuredLog.debug_("nvcc_command_").field("detail", cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "CUDA compilation failed for " ~ source ~ ":\n" ~ res.output;
            return result;
        }
        
        // Check for warnings
        if (!res.output.empty && res.output.canFind("warning"))
        {
            result.hadWarnings = true;
            result.warnings ~= res.output;
        }
        
        result.success = true;
        result.objects = [objFile];
        return result;
    }
    
    private CUDABuildResult compileHostFile(
        string source,
        string nvccPath,
        in CUDAConfig config,
        string objDir,
        string targetName
    ) @system
    {
        CUDABuildResult result;
        
        string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
        
        // Build nvcc command for host file
        string[] cmd = [nvccPath];
        cmd ~= "-c";
        
        // Optimization
        final switch (config.optLevel)
        {
            case CUDAOptLevel.O0: cmd ~= "-O0"; break;
            case CUDAOptLevel.O1: cmd ~= "-O1"; break;
            case CUDAOptLevel.O2: cmd ~= "-O2"; break;
            case CUDAOptLevel.O3: cmd ~= "-O3"; break;
            case CUDAOptLevel.Fast: cmd ~= "-O3"; break;
        }
        
        if (config.debug_)
            cmd ~= "-g";
        
        if (!config.cxxStd.empty)
            cmd ~= "-std=" ~ config.cxxStd;
        
        foreach (inc; config.includeDirs)
            cmd ~= ["-I", inc];
        
        foreach (flag; config.hostFlags)
            cmd ~= ["-Xcompiler", flag];
        
        if (!config.hostCompiler.empty)
            cmd ~= ["-ccbin", config.hostCompiler];
        
        cmd ~= ["-o", objFile];
        cmd ~= source;
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Host compilation failed for " ~ source ~ ":\n" ~ res.output;
            return result;
        }
        
        result.success = true;
        result.objects = [objFile];
        return result;
    }
    
    private CUDABuildResult linkObjects(
        string[] objects,
        in Target target,
        in WorkspaceConfig config,
        in CUDAConfig cudaConfig,
        string nvccPath
    ) @system
    {
        CUDABuildResult result;
        
        string outDir = cudaConfig.outputDir.empty ? config.options.outputDir : cudaConfig.outputDir;
        auto name = target.name.split(":")[$ - 1];
        string outputFile;
        
        // Determine output file
        final switch (cudaConfig.outputType)
        {
            case CUDAOutputType.Executable:
                outputFile = buildPath(outDir, name);
                break;
            case CUDAOutputType.SharedLib:
                version(Windows)
                    outputFile = buildPath(outDir, name ~ ".dll");
                else version(OSX)
                    outputFile = buildPath(outDir, "lib" ~ name ~ ".dylib");
                else
                    outputFile = buildPath(outDir, "lib" ~ name ~ ".so");
                break;
            case CUDAOutputType.StaticLib:
                version(Windows)
                    outputFile = buildPath(outDir, name ~ ".lib");
                else
                    outputFile = buildPath(outDir, "lib" ~ name ~ ".a");
                break;
            case CUDAOutputType.Object:
            case CUDAOutputType.PTX:
            case CUDAOutputType.Cubin:
            case CUDAOutputType.Fatbin:
            case CUDAOutputType.DeviceLib:
                result.success = true;
                result.outputs = objects;
                return result;
        }
        
        string[] cmd;
        
        if (cudaConfig.outputType == CUDAOutputType.StaticLib)
        {
            // Use ar for static library
            version(Windows)
                cmd = ["lib", "/OUT:" ~ outputFile] ~ objects;
            else
                cmd = ["ar", "rcs", outputFile] ~ objects;
        }
        else
        {
            // Use nvcc for linking
            cmd = [nvccPath];
            
            // Device link if relocatable
            if (cudaConfig.relocatable)
                cmd ~= "-dlink";
            
            // Shared library flag
            if (cudaConfig.outputType == CUDAOutputType.SharedLib)
                cmd ~= "-shared";
            
            // Architecture flags
            cmd ~= cudaConfig.getArchFlags();
            
            // Library directories
            foreach (libDir; cudaConfig.libDirs)
                cmd ~= ["-L", libDir];
            
            // Libraries
            foreach (lib; cudaConfig.libs)
                cmd ~= "-l" ~ lib;
            
            // Output
            cmd ~= ["-o", outputFile];
            
            // Objects
            cmd ~= objects;
        }
        
        structuredLog.info("linking_cuda_").field("detail", "Linking: " ~ outputFile).emit();
        structuredLog.debug_("link_command_").field("detail", cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "CUDA linking failed:\n" ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        
        if (exists(outputFile))
            result.outputHash = FastHash.hashFile(outputFile);
        
        return result;
    }
    
    private CUDAConfig parseCUDAConfig(in Target target) @system
    {
        CUDAConfig config;
        
        string configKey;
        if ("cuda" in target.langConfig)
            configKey = "cuda";
        else if ("cudaConfig" in target.langConfig)
            configKey = "cudaConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = CUDAConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_cuda_config_").field("detail", "Using defaults: " ~ e.msg).emit();
            }
        }
        
        // Apply target flags
        if (!target.flags.empty)
            config.nvccFlags ~= target.flags;
        
        // Apply target includes
        if (!target.includes.empty)
            config.includeDirs ~= target.includes;
        
        return config;
    }
    
    private string detectNvcc(in CUDAConfig config) @system
    {
        // Check config path first
        if (!config.cudaPath.empty)
        {
            auto nvcc = buildPath(config.cudaPath, "bin", "nvcc");
            if (exists(nvcc))
                return nvcc;
        }
        
        // Check environment variable
        import std.process : environment;
        auto cudaHome = environment.get("CUDA_HOME", environment.get("CUDA_PATH", ""));
        if (!cudaHome.empty)
        {
            auto nvcc = buildPath(cudaHome, "bin", "nvcc");
            if (exists(nvcc))
                return nvcc;
        }
        
        // Check common paths
        version(linux)
        {
            foreach (path; ["/usr/local/cuda/bin/nvcc", "/opt/cuda/bin/nvcc"])
            {
                if (exists(path))
                    return path;
            }
        }
        version(OSX)
        {
            foreach (path; ["/usr/local/cuda/bin/nvcc", "/opt/cuda/bin/nvcc"])
            {
                if (exists(path))
                    return path;
            }
        }
        version(Windows)
        {
            // Try Program Files paths
            auto progFiles = environment.get("ProgramFiles", "C:\\Program Files");
            auto nvidiaPath = buildPath(progFiles, "NVIDIA GPU Computing Toolkit", "CUDA");
            if (exists(nvidiaPath))
            {
                // Find latest version
                foreach (entry; dirEntries(nvidiaPath, SpanMode.shallow))
                {
                    auto nvcc = buildPath(entry.name, "bin", "nvcc.exe");
                    if (exists(nvcc))
                        return nvcc;
                }
            }
        }
        
        // Try PATH
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        return ExecutableDetector.findInPath("nvcc");
    }
    
    private string[] parseDependencyFile(string source, string objDir) @system
    {
        string depFile = buildPath(objDir, baseName(source).stripExtension ~ ".d");
        
        if (!exists(depFile))
            return [];
        
        try
        {
            auto content = readText(depFile);
            string[] deps;
            
            // Parse Makefile-style dependency format
            // target: dep1 dep2 dep3 \
            //         dep4 dep5
            auto lines = content.replace("\\\n", " ").splitLines();
            
            foreach (line; lines)
            {
                auto colonIdx = line.indexOf(':');
                if (colonIdx >= 0)
                    line = line[colonIdx + 1 .. $];
                
                foreach (dep; line.split())
                {
                    auto d = dep.strip;
                    if (!d.empty && exists(d) && d != source)
                        deps ~= d;
                }
            }
            
            return deps;
        }
        catch (Exception e)
        {
            return [];
        }
    }
    
    private Import[] parseCUDAIncludes(string content, string sourceFile) @system
    {
        Import[] imports;
        
        // Match #include "..." and #include <...>
        auto includeRegex = regex(`#include\s*[<"]([^>"]+)[>"]`);
        
        foreach (match; matchAll(content, includeRegex))
        {
            Import imp;
            imp.name = match[1];
            imp.module_ = baseName(match[1]);
            imp.isExternal = match.hit.canFind('<');
            imp.source = sourceFile;
            imports ~= imp;
        }
        
        return imports;
    }
}

