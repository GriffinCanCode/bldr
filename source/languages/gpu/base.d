module languages.gpu.base;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.regex;
import languages.base.base;
import languages.base.compiled;
import languages.base.types;
import languages.base.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// GPU output types (shared across CUDA, Metal, ROCm)
enum GPUOutputType
{
    Object,        // .o
    PTX,           // CUDA PTX
    Cubin,         // CUDA binary
    Fatbin,        // CUDA fat binary
    AIR,           // Metal AIR
    MetalLib,      // Metal library
    HIPFatbin,     // ROCm fat binary
    DeviceLib,     // Device link object
    Executable,    // Host executable
    SharedLib,     // Shared library
    StaticLib      // Static library
}

/// GPU compile result
struct GPUCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string[] objects;
    string outputHash;
    bool hadWarnings;
    string[] warnings;
}

/// Base handler for GPU languages (CUDA, Metal, ROCm)
abstract class BaseGPUHandler : BaseCompiledHandler
{
    this(ActionCache cache = null) { super(cache); }
    
    /// Build the target with full context
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_gpu_target_").field("detail", "Building " ~ languageId() ~ " target: " ~ target.name).emit();
        
        // Parse GPU configuration
        GPUConfig gpuConfig = parseGPUConfig(target);
        
        // Detect toolkit
        auto toolPath = detectToolkit(gpuConfig);
        if (toolPath.empty)
        {
            result.error = toolkitNotFoundError();
            return result;
        }
        
        structuredLog.info("using_toolkit_").field("detail", "Using " ~ languageId() ~ " toolkit: " ~ toolPath).emit();
        
        // Setup directories
        string outDir = gpuConfig.compiled.base.outputDir.empty 
            ? config.options.outputDir 
            : gpuConfig.compiled.base.outputDir;
        string objDir = gpuConfig.compiled.base.objDir;
        
        if (!exists(outDir)) mkdirRecurse(outDir);
        if (!exists(objDir)) mkdirRecurse(objDir);
        
        // Determine output type from target type
        GPUOutputType outputType = determineOutputType(target.type, gpuConfig);
        
        // Separate device and host sources
        string[] deviceSources, hostSources;
        separateSources(target.sources, deviceSources, hostSources);
        
        // Compile device sources
        string[] allObjects;
        foreach (source; deviceSources)
        {
            auto compileResult = compileDeviceFile(source, toolPath, gpuConfig, objDir, target.name);
            if (!compileResult.success)
            {
                result.error = compileResult.error;
                return result;
            }
            allObjects ~= compileResult.objects;
        }
        
        // Compile host sources
        foreach (source; hostSources)
        {
            auto compileResult = compileHostFile(source, toolPath, gpuConfig, objDir, target.name);
            if (!compileResult.success)
            {
                result.error = compileResult.error;
                return result;
            }
            allObjects ~= compileResult.objects;
        }
        
        // Link if needed
        if (needsLinking(outputType))
        {
            auto linkResult = linkGPUObjects(allObjects, target, config, gpuConfig, toolPath, outputType);
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
            auto testResult = runTests(result.outputs[0]);
            if (!testResult.success)
            {
                result.success = false;
                result.error = testResult.error;
                return result;
            }
        }
        
        // Record dependencies for incremental compilation
        if (context.depRecorder !is null)
        {
            foreach (source; target.sources)
            {
                if (isDeviceSource(source))
                {
                    auto deps = parseDependencyFile(source, objDir);
                    context.depRecorder(source, deps);
                }
            }
        }
        
        result.success = true;
        return result;
    }
    
    /// Get outputs for target
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        GPUConfig gpuConfig = parseGPUConfig(target);
        string outDir = gpuConfig.compiled.base.outputDir.empty 
            ? config.options.outputDir 
            : gpuConfig.compiled.base.outputDir;
        
        GPUOutputType outputType = determineOutputType(target.type, gpuConfig);
        auto name = target.name.split(":")[$ - 1];
        
        return [buildPath(outDir, getOutputName(name, outputType))];
    }
    
    /// Analyze imports in source files
    override Import[] analyzeImports(in string[] sources) @system
    {
        Import[] imports;
        foreach (source; sources)
        {
            if (!exists(source)) continue;
            try
            {
                auto content = readText(source);
                imports ~= parseIncludes(content, source);
            }
            catch (Exception) {}
        }
        return imports;
    }
    
    // ========== Abstract methods to be implemented by subclasses ==========
    
    /// Detect toolkit path (nvcc, hipcc, xcrun)
    protected abstract string detectToolkit(GPUConfig config) @system;
    
    /// Get architecture flags for compilation
    protected abstract string[] getArchFlags(GPUConfig config) pure nothrow;
    
    /// Get error message when toolkit not found
    protected abstract string toolkitNotFoundError() const pure nothrow;
    
    /// Check if file is a device source
    protected abstract bool isDeviceSource(string path) const pure nothrow;
    
    /// Get device source file extensions
    protected abstract string[] deviceExtensions() const pure nothrow;
    
    /// Build compile command for device source
    protected abstract string[] buildDeviceCompileCmd(
        string source, string objFile, string toolPath, GPUConfig config
    ) pure nothrow;
    
    /// Build compile command for host source
    protected abstract string[] buildHostCompileCmd(
        string source, string objFile, string toolPath, GPUConfig config
    ) pure nothrow;
    
    /// Build link command
    protected abstract string[] buildLinkCmd(
        string[] objects, string output, string toolPath, GPUConfig config, GPUOutputType outputType
    ) pure nothrow;
    
    /// Get output filename with appropriate extension
    protected abstract string getOutputName(string name, GPUOutputType outputType) const pure nothrow;
    
    // ========== Common implementation ==========
    
    /// Parse GPU config from target
    protected GPUConfig parseGPUConfig(in Target target) @system
    {
        import std.json : parseJSON;
        
        GPUConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    parseGPUConfig(config, json);
                    break;
                }
                catch (Exception e)
                {
                    structuredLog.warning("config_parse_failed_").field("detail", "Using defaults: " ~ e.msg).emit();
                }
            }
        }
        
        // Apply target flags and includes
        if (!target.flags.empty) config.compiled.base.extraFlags ~= target.flags;
        if (!target.includes.empty) config.compiled.base.includeDirs ~= target.includes;
        
        return config;
    }
    
    /// Config keys to try when parsing
    protected abstract string[] configKeys() const pure nothrow;
    
    /// Separate sources into device and host files
    protected void separateSources(const(string[]) sources, ref string[] device, ref string[] host)
    {
        foreach (source; sources)
        {
            if (isDeviceSource(source))
                device ~= source;
            else if (source.endsWith(".cpp") || source.endsWith(".cc") || source.endsWith(".c") || source.endsWith(".cxx"))
                host ~= source;
        }
    }
    
    /// Compile device source file
    protected GPUCompileResult compileDeviceFile(
        string source, string toolPath, GPUConfig config, string objDir, string targetName
    ) @system
    {
        GPUCompileResult result;
        
        string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
        string[] cmd = buildDeviceCompileCmd(source, objFile, toolPath, config);
        
        // Use base class caching
        string[string] metadata;
        metadata["toolkit"] = languageId();
        metadata["arch"] = config.architectures.join(",");
        
        auto compileResult = compileFileWithCaching(source, objDir, cmd, targetName, metadata);
        
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.objects = compileResult.success ? [compileResult.objectFile] : [];
        result.warnings = compileResult.warnings;
        
        return result;
    }
    
    /// Compile host source file
    protected GPUCompileResult compileHostFile(
        string source, string toolPath, GPUConfig config, string objDir, string targetName
    ) @system
    {
        GPUCompileResult result;
        
        string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
        string[] cmd = buildHostCompileCmd(source, objFile, toolPath, config);
        
        string[string] metadata;
        metadata["toolkit"] = languageId();
        metadata["type"] = "host";
        
        auto compileResult = compileFileWithCaching(source, objDir, cmd, targetName, metadata);
        
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.objects = compileResult.success ? [compileResult.objectFile] : [];
        result.warnings = compileResult.warnings;
        
        return result;
    }
    
    /// Link GPU objects
    protected GPUCompileResult linkGPUObjects(
        string[] objects,
        in Target target,
        in WorkspaceConfig config,
        GPUConfig gpuConfig,
        string toolPath,
        GPUOutputType outputType
    ) @system
    {
        GPUCompileResult result;
        
        string outDir = gpuConfig.compiled.base.outputDir.empty 
            ? config.options.outputDir 
            : gpuConfig.compiled.base.outputDir;
        
        auto name = target.name.split(":")[$ - 1];
        string outputFile = buildPath(outDir, getOutputName(name, outputType));
        
        string[] cmd = buildLinkCmd(objects, outputFile, toolPath, gpuConfig, outputType);
        
        auto linkResult = linkObjects(objects, outputFile, cmd);
        
        result.success = linkResult.success;
        result.error = linkResult.error;
        result.outputs = linkResult.success ? [linkResult.output] : [];
        result.outputHash = linkResult.outputHash;
        result.warnings = linkResult.warnings;
        
        return result;
    }
    
    /// Determine output type from target type
    protected GPUOutputType determineOutputType(TargetType type, GPUConfig config)
    {
        final switch (type)
        {
            case TargetType.Executable:
            case TargetType.Test:
                return GPUOutputType.Executable;
            case TargetType.Library:
                return GPUOutputType.StaticLib;
            case TargetType.Custom:
            case TargetType.Shell:
                return GPUOutputType.Object;
        }
    }
    
    /// Check if output type needs linking
    protected bool needsLinking(GPUOutputType type) const pure nothrow
    {
        return type == GPUOutputType.Executable ||
               type == GPUOutputType.SharedLib ||
               type == GPUOutputType.StaticLib;
    }
    
    /// Run test executable
    protected GPUCompileResult runTests(string testExe) @system
    {
        GPUCompileResult result;
        
        structuredLog.info("running_gpu_tests_").field("detail", "Running tests: " ~ testExe).emit();
        
        auto res = execute([testExe]);
        
        if (res.status != 0)
        {
            result.error = languageId() ~ " tests failed: " ~ res.output;
            return result;
        }
        
        structuredLog.info("gpu_tests_passed").emit();
        result.success = true;
        return result;
    }
}

