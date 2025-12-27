module languages.compiled.gpu.metal.core.handler;

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
import languages.compiled.gpu.metal.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// Metal build result
struct MetalBuildResult
{
    bool success;
    string error;
    string[] outputs;
    string[] objects;
    string outputHash;
}

/// Apple Metal language handler
class MetalHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"metal";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        version(OSX)
        {
            structuredLog.debug_("building_metal_target_").field("detail", "Building Metal target: " ~ target.name).emit();
            
            MetalConfig metalConfig = parseMetalConfig(target);
            
            // Verify xcrun is available
            auto xcrunPath = detectXcrun();
            if (xcrunPath.empty)
            {
                result.error = "Xcode Command Line Tools not found. Install with: xcode-select --install";
                return result;
            }
            
            string outDir = metalConfig.outputDir.empty ? config.options.outputDir : metalConfig.outputDir;
            string objDir = metalConfig.objDir;
            
            if (!exists(outDir)) mkdirRecurse(outDir);
            if (!exists(objDir)) mkdirRecurse(objDir);
            
            // Compile .metal to .air
            string[] airFiles;
            
            foreach (source; target.sources)
            {
                if (!source.endsWith(".metal")) continue;
                
                auto compileResult = compileToAIR(source, xcrunPath, metalConfig, objDir);
                
                if (!compileResult.success)
                {
                    result.error = compileResult.error;
                    return result;
                }
                
                airFiles ~= compileResult.outputs;
            }
            
            // Link .air to .metallib
            if (metalConfig.outputType == MetalOutputType.MetalLib && !airFiles.empty)
            {
                auto linkResult = linkToMetalLib(airFiles, target, config, metalConfig, xcrunPath);
                
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
                result.outputs = airFiles;
                if (!airFiles.empty && exists(airFiles[0]))
                    result.outputHash = FastHash.hashFile(airFiles[0]);
            }
            
            result.success = true;
            
            // Record dependencies
            if (context.depRecorder !is null)
            {
                foreach (source; target.sources)
                {
                    auto deps = parseMetalIncludes(source);
                    context.depRecorder(source, deps);
                }
            }
        }
        else
        {
            result.error = "Metal compilation is only supported on macOS";
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        MetalConfig metalConfig = parseMetalConfig(target);
        string outDir = metalConfig.outputDir.empty ? config.options.outputDir : metalConfig.outputDir;
        auto name = target.name.split(":")[$ - 1];
        
        final switch (metalConfig.outputType)
        {
            case MetalOutputType.AIR:
                return [buildPath(outDir, name ~ ".air")];
            case MetalOutputType.MetalLib:
                return [buildPath(outDir, name ~ ".metallib")];
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
    
    private MetalBuildResult compileToAIR(
        string source, string xcrunPath, in MetalConfig config, string objDir
    ) @system
    {
        MetalBuildResult result;
        
        string airFile = buildPath(objDir, baseName(source).stripExtension ~ ".air");
        
        string[] cmd = [xcrunPath, "-sdk"];
        
        // SDK selection based on platform
        final switch (config.platform)
        {
            case MetalPlatform.MacOS: cmd ~= "macosx"; break;
            case MetalPlatform.iOS: cmd ~= "iphoneos"; break;
            case MetalPlatform.iOSSimulator: cmd ~= "iphonesimulator"; break;
            case MetalPlatform.tvOS: cmd ~= "appletvos"; break;
            case MetalPlatform.tvOSSimulator: cmd ~= "appletvsimulator"; break;
        }
        
        cmd ~= "metal";
        cmd ~= "-c";
        cmd ~= config.getStdFlag();
        
        if (config.debug_) cmd ~= "-gline-tables-only";
        if (config.fastMath) cmd ~= "-ffast-math";
        
        foreach (inc; config.includeDirs) cmd ~= ["-I", inc];
        
        cmd ~= config.metalFlags;
        
        if (config.verbose) cmd ~= "-v";
        
        cmd ~= ["-o", airFile, source];
        
        structuredLog.debug_("compiling_metal_").field("detail", "Compiling: " ~ source).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Metal compilation failed for " ~ source ~ ":\n" ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [airFile];
        return result;
    }
    
    private MetalBuildResult linkToMetalLib(
        string[] airFiles, in Target target, in WorkspaceConfig config,
        in MetalConfig metalConfig, string xcrunPath
    ) @system
    {
        MetalBuildResult result;
        
        string outDir = metalConfig.outputDir.empty ? config.options.outputDir : metalConfig.outputDir;
        auto name = target.name.split(":")[$ - 1];
        string outputFile = buildPath(outDir, name ~ ".metallib");
        
        string[] cmd = [xcrunPath, "-sdk"];
        
        final switch (metalConfig.platform)
        {
            case MetalPlatform.MacOS: cmd ~= "macosx"; break;
            case MetalPlatform.iOS: cmd ~= "iphoneos"; break;
            case MetalPlatform.iOSSimulator: cmd ~= "iphonesimulator"; break;
            case MetalPlatform.tvOS: cmd ~= "appletvos"; break;
            case MetalPlatform.tvOSSimulator: cmd ~= "appletvsimulator"; break;
        }
        
        cmd ~= "metallib";
        cmd ~= ["-o", outputFile];
        cmd ~= airFiles;
        
        structuredLog.info("linking_metallib_").field("detail", "Linking: " ~ outputFile).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Metal linking failed:\n" ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        if (exists(outputFile)) result.outputHash = FastHash.hashFile(outputFile);
        
        return result;
    }
    
    private MetalConfig parseMetalConfig(in Target target) @system
    {
        MetalConfig config;
        
        if ("metal" in target.langConfig)
        {
            try
            {
                auto json = parseJSON(target.langConfig["metal"]);
                config = MetalConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_metal_config_").field("detail", e.msg).emit();
            }
        }
        
        if (!target.flags.empty) config.metalFlags ~= target.flags;
        if (!target.includes.empty) config.includeDirs ~= target.includes;
        
        return config;
    }
    
    private string detectXcrun() @system
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        return ExecutableDetector.findInPath("xcrun");
    }
    
    private string[] parseMetalIncludes(string sourceFile) @system
    {
        if (!exists(sourceFile)) return [];
        
        try
        {
            auto content = readText(sourceFile);
            string[] deps;
            auto includeRegex = regex(`#include\s*"([^"]+)"`);
            
            foreach (match; matchAll(content, includeRegex))
            {
                auto incPath = buildPath(dirName(sourceFile), match[1]);
                if (exists(incPath)) deps ~= incPath;
            }
            
            return deps;
        }
        catch (Exception) { return []; }
    }
}

