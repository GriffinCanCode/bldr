module languages.compiled.gpu.rocm.core.handler;

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
import languages.compiled.gpu.rocm.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// ROCm/HIP build result
struct ROCmBuildResult
{
    bool success;
    string error;
    string[] outputs;
    string[] objects;
    string outputHash;
}

/// ROCm/HIP language handler with hipcc integration
class ROCmHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"rocm";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_rocm_target_").field("detail", "Building ROCm target: " ~ target.name).emit();
        
        ROCmConfig rocmConfig = parseROCmConfig(target);
        
        auto hipccPath = detectHipcc(rocmConfig);
        if (hipccPath.empty)
        {
            result.error = "ROCm toolkit not found. Install ROCm and ensure hipcc is in PATH.";
            return result;
        }
        
        structuredLog.info("using_hipcc_").field("detail", "Using hipcc: " ~ hipccPath).emit();
        
        string outDir = rocmConfig.outputDir.empty ? config.options.outputDir : rocmConfig.outputDir;
        string objDir = rocmConfig.objDir;
        
        if (!exists(outDir)) mkdirRecurse(outDir);
        if (!exists(objDir)) mkdirRecurse(objDir);
        
        final switch (target.type)
        {
            case TargetType.Executable:
                rocmConfig.outputType = ROCmOutputType.Executable;
                break;
            case TargetType.Library:
                if (rocmConfig.outputType == ROCmOutputType.Object)
                    rocmConfig.outputType = ROCmOutputType.StaticLib;
                break;
            case TargetType.Test:
                rocmConfig.outputType = ROCmOutputType.Executable;
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                break;
        }
        
        // Compile sources
        string[] allObjects;
        
        foreach (source; target.sources)
        {
            auto compileResult = compileFile(source, hipccPath, rocmConfig, objDir);
            
            if (!compileResult.success)
            {
                result.error = compileResult.error;
                return result;
            }
            
            allObjects ~= compileResult.objects;
        }
        
        // Link
        if (rocmConfig.outputType != ROCmOutputType.Object)
        {
            auto linkResult = linkObjects(allObjects, target, config, rocmConfig, hipccPath);
            
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
        
        // Run tests if test target
        if (target.type == TargetType.Test && result.outputs.length > 0)
        {
            auto res = execute([result.outputs[0]]);
            if (res.status != 0)
            {
                result.success = false;
                result.error = "ROCm tests failed: " ~ res.output;
                return result;
            }
        }
        
        result.success = true;
        
        // Record dependencies
        if (context.depRecorder !is null)
        {
            foreach (source; target.sources)
            {
                auto deps = parseDependencyFile(source, objDir);
                context.depRecorder(source, deps);
            }
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        ROCmConfig rocmConfig = parseROCmConfig(target);
        string outDir = rocmConfig.outputDir.empty ? config.options.outputDir : rocmConfig.outputDir;
        auto name = target.name.split(":")[$ - 1];
        
        final switch (rocmConfig.outputType)
        {
            case ROCmOutputType.Object:
                return [buildPath(outDir, name ~ ".o")];
            case ROCmOutputType.Executable:
                return [buildPath(outDir, name)];
            case ROCmOutputType.SharedLib:
                version(OSX) return [buildPath(outDir, "lib" ~ name ~ ".dylib")];
                else return [buildPath(outDir, "lib" ~ name ~ ".so")];
            case ROCmOutputType.StaticLib:
                return [buildPath(outDir, "lib" ~ name ~ ".a")];
            case ROCmOutputType.HIPFatbin:
                return [buildPath(outDir, name ~ ".hipfb")];
        }
    }
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        Import[] imports;
        foreach (source; sources)
        {
            if (!exists(source)) continue;
            try
            {
                auto content = readText(source);
                auto includeRegex = regex(`#include\s*[<"]([^>"]+)[>"]`);
                foreach (match; matchAll(content, includeRegex))
                {
                    Import imp;
                    imp.name = match[1];
                    imp.module_ = baseName(match[1]);
                    imp.isExternal = match.hit.canFind('<');
                    imp.source = source;
                    imports ~= imp;
                }
            }
            catch (Exception) {}
        }
        return imports;
    }
    
    private ROCmBuildResult compileFile(
        string source, string hipccPath, in ROCmConfig config, string objDir
    ) @system
    {
        ROCmBuildResult result;
        
        string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
        string depFile = buildPath(objDir, baseName(source).stripExtension ~ ".d");
        
        string[] cmd = [hipccPath, "-c"];
        
        // Architecture
        cmd ~= config.getArchFlags();
        
        // Optimization
        final switch (config.optLevel)
        {
            case ROCmOptLevel.O0: cmd ~= "-O0"; break;
            case ROCmOptLevel.O1: cmd ~= "-O1"; break;
            case ROCmOptLevel.O2: cmd ~= "-O2"; break;
            case ROCmOptLevel.O3: cmd ~= "-O3"; break;
            case ROCmOptLevel.Fast: cmd ~= ["-O3", "-ffast-math"]; break;
        }
        
        if (config.debug_) cmd ~= "-g";
        if (config.fastMath && config.optLevel != ROCmOptLevel.Fast) cmd ~= "-ffast-math";
        if (!config.cxxStd.empty) cmd ~= "-std=" ~ config.cxxStd;
        
        foreach (inc; config.includeDirs) cmd ~= ["-I", inc];
        
        if (config.genDeps) cmd ~= ["-MMD", "-MF", depFile];
        
        cmd ~= config.hipccFlags;
        
        if (config.verbose) cmd ~= "-v";
        
        cmd ~= ["-o", objFile, source];
        
        structuredLog.debug_("compiling_rocm_").field("detail", "Compiling: " ~ source).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "ROCm compilation failed for " ~ source ~ ":\n" ~ res.output;
            return result;
        }
        
        result.success = true;
        result.objects = [objFile];
        return result;
    }
    
    private ROCmBuildResult linkObjects(
        string[] objects, in Target target, in WorkspaceConfig config,
        in ROCmConfig rocmConfig, string hipccPath
    ) @system
    {
        ROCmBuildResult result;
        
        string outDir = rocmConfig.outputDir.empty ? config.options.outputDir : rocmConfig.outputDir;
        auto name = target.name.split(":")[$ - 1];
        string outputFile;
        
        final switch (rocmConfig.outputType)
        {
            case ROCmOutputType.Executable:
                outputFile = buildPath(outDir, name);
                break;
            case ROCmOutputType.SharedLib:
                version(OSX) outputFile = buildPath(outDir, "lib" ~ name ~ ".dylib");
                else outputFile = buildPath(outDir, "lib" ~ name ~ ".so");
                break;
            case ROCmOutputType.StaticLib:
                outputFile = buildPath(outDir, "lib" ~ name ~ ".a");
                break;
            case ROCmOutputType.Object:
            case ROCmOutputType.HIPFatbin:
                result.success = true;
                result.outputs = objects;
                return result;
        }
        
        string[] cmd;
        
        if (rocmConfig.outputType == ROCmOutputType.StaticLib)
            cmd = ["ar", "rcs", outputFile] ~ objects;
        else
        {
            cmd = [hipccPath];
            cmd ~= rocmConfig.getArchFlags();
            
            if (rocmConfig.outputType == ROCmOutputType.SharedLib)
                cmd ~= "-shared";
            
            foreach (libDir; rocmConfig.libDirs) cmd ~= ["-L", libDir];
            foreach (lib; rocmConfig.libs) cmd ~= "-l" ~ lib;
            
            cmd ~= ["-o", outputFile] ~ objects;
        }
        
        structuredLog.info("linking_rocm_").field("detail", "Linking: " ~ outputFile).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "ROCm linking failed:\n" ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        if (exists(outputFile)) result.outputHash = FastHash.hashFile(outputFile);
        
        return result;
    }
    
    private ROCmConfig parseROCmConfig(in Target target) @system
    {
        ROCmConfig config;
        
        string configKey;
        if ("rocm" in target.langConfig) configKey = "rocm";
        else if ("hip" in target.langConfig) configKey = "hip";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = ROCmConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_rocm_config_").field("detail", e.msg).emit();
            }
        }
        
        if (!target.flags.empty) config.hipccFlags ~= target.flags;
        if (!target.includes.empty) config.includeDirs ~= target.includes;
        
        return config;
    }
    
    private string detectHipcc(in ROCmConfig config) @system
    {
        if (!config.rocmPath.empty)
        {
            auto hipcc = buildPath(config.rocmPath, "bin", "hipcc");
            if (exists(hipcc)) return hipcc;
        }
        
        import std.process : environment;
        auto rocmHome = environment.get("ROCM_PATH", environment.get("HIP_PATH", ""));
        if (!rocmHome.empty)
        {
            auto hipcc = buildPath(rocmHome, "bin", "hipcc");
            if (exists(hipcc)) return hipcc;
        }
        
        version(linux)
        {
            foreach (path; ["/opt/rocm/bin/hipcc", "/usr/local/rocm/bin/hipcc"])
                if (exists(path)) return path;
        }
        
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        return ExecutableDetector.findInPath("hipcc");
    }
    
    private string[] parseDependencyFile(string source, string objDir) @system
    {
        string depFile = buildPath(objDir, baseName(source).stripExtension ~ ".d");
        if (!exists(depFile)) return [];
        
        try
        {
            auto content = readText(depFile).replace("\\\n", " ");
            string[] deps;
            
            foreach (line; content.splitLines())
            {
                auto colonIdx = line.indexOf(':');
                if (colonIdx >= 0) line = line[colonIdx + 1 .. $];
                
                foreach (dep; line.split())
                {
                    auto d = dep.strip;
                    if (!d.empty && exists(d) && d != source)
                        deps ~= d;
                }
            }
            return deps;
        }
        catch (Exception) { return []; }
    }
}

