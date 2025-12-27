module languages.gpu.metal.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import languages.base;
import languages.gpu.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// Metal-specific output types
enum MetalOutputType
{
    AIR,       // Intermediate representation
    MetalLib   // Final library
}

/// Metal platform targets
enum MetalPlatform
{
    MacOS,
    iOS,
    iOSSimulator,
    tvOS,
    tvOSSimulator
}

/// Metal standard versions
enum MetalStandard
{
    Metal10,
    Metal11,
    Metal12,
    Metal20,
    Metal21,
    Metal22,
    Metal23,
    Metal24,
    Metal30,
    Metal31
}

/// Apple Metal language handler - leverages BaseGPUHandler for common functionality
class MetalHandler : BaseGPUHandler
{
    private MetalPlatform platform = MetalPlatform.MacOS;
    private MetalStandard standard = MetalStandard.Metal24;
    private MetalOutputType outputType = MetalOutputType.MetalLib;
    
    this() { super(null); }
    
    override protected string languageId() const pure nothrow => "metal";
    
    override protected string[] configKeys() const pure nothrow => ["metal", "metalConfig"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "Xcode Command Line Tools not found. Install with: xcode-select --install";
    
    override protected bool isDeviceSource(string path) const pure nothrow =>
        path.endsWith(".metal");
    
    override protected string[] deviceExtensions() const pure nothrow => [".metal"];
    
    /// Only supported on macOS
    override protected LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        version(OSX)
        {
            return super.buildImplWithContext(context);
        }
        else
        {
            LanguageBuildResult result;
            result.error = "Metal compilation is only supported on macOS";
            return result;
        }
    }
    
    /// Detect xcrun
    override protected string detectToolkit(GPUConfig config) @system
    {
        return detectTool([], "", "xcrun");
    }
    
    /// Metal doesn't use traditional arch flags, return empty
    override protected string[] getArchFlags(GPUConfig config) pure nothrow => [];
    
    /// Build metal compile command
    override protected string[] buildDeviceCompileCmd(
        string source, string objFile, string toolPath, GPUConfig config
    ) pure nothrow
    {
        string[] cmd = [toolPath, "-sdk"];
        
        // SDK selection based on platform
        cmd ~= getSdkName();
        
        cmd ~= ["metal", "-c"];
        
        // Metal standard
        cmd ~= getStdFlag();
        
        // Debug info
        if (config.compiled.base.debugInfo)
            cmd ~= "-gline-tables-only";
        
        // Fast math
        if (config.fastMath)
            cmd ~= "-ffast-math";
        
        // Include directories
        foreach (inc; config.compiled.base.includeDirs)
            cmd ~= ["-I", inc];
        
        // Extra flags
        cmd ~= config.compiled.base.extraFlags;
        
        // Verbose
        if (config.compiled.base.verbosity >= Verbosity.Verbose)
            cmd ~= "-v";
        
        // Output and input
        cmd ~= ["-o", objFile, source];
        
        return cmd;
    }
    
    /// Host files not really applicable for Metal, just pass through
    override protected string[] buildHostCompileCmd(
        string source, string objFile, string toolPath, GPUConfig config
    ) pure nothrow
    {
        // Metal typically doesn't have separate host compilation
        return buildDeviceCompileCmd(source, objFile, toolPath, config);
    }
    
    /// Build metallib link command
    override protected string[] buildLinkCmd(
        string[] objects, string output, string toolPath, GPUConfig config, GPUOutputType gpuType
    ) pure nothrow
    {
        string[] cmd = [toolPath, "-sdk"];
        cmd ~= getSdkName();
        cmd ~= ["metallib", "-o", output];
        cmd ~= objects;
        return cmd;
    }
    
    /// Get output filename
    override protected string getOutputName(string name, GPUOutputType gpuType) const pure nothrow
    {
        final switch (outputType)
        {
            case MetalOutputType.AIR: return name ~ ".air";
            case MetalOutputType.MetalLib: return name ~ ".metallib";
        }
    }
    
    /// Override to use .air extension for intermediate files
    override protected GPUCompileResult compileDeviceFile(
        string source, string toolPath, GPUConfig config, string objDir, string targetName
    ) @system
    {
        GPUCompileResult result;
        
        // Metal uses .air for intermediate files, not .o
        string airFile = buildPath(objDir, baseName(source).stripExtension ~ ".air");
        string[] cmd = buildDeviceCompileCmd(source, airFile, toolPath, config);
        
        string[string] metadata;
        metadata["toolkit"] = "metal";
        metadata["platform"] = getSdkName();
        metadata["standard"] = getStdFlag();
        
        auto compileResult = compileFileWithCaching(source, objDir, cmd, targetName, metadata);
        
        // Fix the object file path to be .air
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.objects = compileResult.success ? [airFile] : [];
        result.warnings = compileResult.warnings;
        
        return result;
    }
    
    // ========== Metal-specific helpers ==========
    
    private string getSdkName() const pure nothrow
    {
        final switch (platform)
        {
            case MetalPlatform.MacOS: return "macosx";
            case MetalPlatform.iOS: return "iphoneos";
            case MetalPlatform.iOSSimulator: return "iphonesimulator";
            case MetalPlatform.tvOS: return "appletvos";
            case MetalPlatform.tvOSSimulator: return "appletvsimulator";
        }
    }
    
    private string getStdFlag() const pure nothrow
    {
        final switch (standard)
        {
            case MetalStandard.Metal10: return "-std=ios-metal1.0";
            case MetalStandard.Metal11: return "-std=ios-metal1.1";
            case MetalStandard.Metal12: return "-std=ios-metal1.2";
            case MetalStandard.Metal20: return "-std=metal2.0";
            case MetalStandard.Metal21: return "-std=metal2.1";
            case MetalStandard.Metal22: return "-std=metal2.2";
            case MetalStandard.Metal23: return "-std=metal2.3";
            case MetalStandard.Metal24: return "-std=metal2.4";
            case MetalStandard.Metal30: return "-std=metal3.0";
            case MetalStandard.Metal31: return "-std=metal3.1";
        }
    }
    
    /// Override parseGPUConfig to handle Metal-specific fields
    override protected GPUConfig parseGPUConfig(in Target target) @system
    {
        import std.json : parseJSON, JSONType;
        
        auto config = super.parseGPUConfig(target);
        
        // Parse Metal-specific fields
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    
                    // Platform
                    if (auto v = "platform" in json)
                    {
                        string p = (*v).str.toLower;
                        if (p == "macos" || p == "osx") platform = MetalPlatform.MacOS;
                        else if (p == "ios") platform = MetalPlatform.iOS;
                        else if (p == "ios-simulator" || p == "iossimulator") platform = MetalPlatform.iOSSimulator;
                        else if (p == "tvos") platform = MetalPlatform.tvOS;
                        else if (p == "tvos-simulator" || p == "tvossimulator") platform = MetalPlatform.tvOSSimulator;
                    }
                    
                    // Standard
                    if (auto v = "standard" in json)
                    {
                        string s = (*v).str.toLower.replace(".", "");
                        if (s == "metal10" || s == "10") standard = MetalStandard.Metal10;
                        else if (s == "metal11" || s == "11") standard = MetalStandard.Metal11;
                        else if (s == "metal12" || s == "12") standard = MetalStandard.Metal12;
                        else if (s == "metal20" || s == "20") standard = MetalStandard.Metal20;
                        else if (s == "metal21" || s == "21") standard = MetalStandard.Metal21;
                        else if (s == "metal22" || s == "22") standard = MetalStandard.Metal22;
                        else if (s == "metal23" || s == "23") standard = MetalStandard.Metal23;
                        else if (s == "metal24" || s == "24") standard = MetalStandard.Metal24;
                        else if (s == "metal30" || s == "30") standard = MetalStandard.Metal30;
                        else if (s == "metal31" || s == "31") standard = MetalStandard.Metal31;
                    }
                    
                    // Output type
                    if (auto v = "outputType" in json)
                    {
                        string o = (*v).str.toLower;
                        if (o == "air") outputType = MetalOutputType.AIR;
                        else if (o == "metallib" || o == "library") outputType = MetalOutputType.MetalLib;
                    }
                    
                    break;
                }
                catch (Exception) {}
            }
        }
        
        return config;
    }
}
