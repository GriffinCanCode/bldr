module languages.jvm.scala.tooling.builders.native_;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.scala.tooling.builders.base;
import languages.jvm.scala.tooling.builders.jar;
import languages.jvm.scala.core.config;
import languages.jvm.scala.tooling.detection;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// GraalVM native-image builder for Scala
class NativeImageBuilder : ScalaBuilder
{
    import engine.caching.actions.action : ActionCache;
    this(ActionCache cache = null) {}
    
    override ScalaBuildResult build(
        in string[] sources,
        in ScalaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ScalaBuildResult result;
        
        structuredLog.debug_("building_scala_native_image_").field("detail", "Building Scala native image: " ~ target.name).emit();
        
        // Check if native-image is available
        if (!isNativeImageAvailable())
        {
            result.error = "GraalVM native-image not available. Install GraalVM and run: gu install native-image";
            return result;
        }
        
        // First, build a JAR
        auto jarBuilder = new JARBuilder();
        auto jarResult = jarBuilder.build(sources, config, target, workspace);
        
        if (!jarResult.success)
        {
            result.error = "Failed to build JAR for native image: " ~ jarResult.error;
            return result;
        }
        
        // Get JAR path
        string jarPath = jarResult.outputs[0];
        
        // Build native image
        string imagePath = buildNativeImage(jarPath, config, target, workspace, result);
        
        if (imagePath.empty)
            return result;
        
        result.success = true;
        result.outputs = [imagePath];
        result.outputHash = FastHash.hashFile(imagePath);
        result.warnings = jarResult.warnings;
        
        return result;
    }
    
    override bool isAvailable()
    {
        return isNativeImageAvailable();
    }
    
    override string name() const
    {
        return "NativeImage";
    }
    
    override bool supportsMode(ScalaBuildMode mode)
    {
        return mode == ScalaBuildMode.NativeImage;
    }
    
    private bool isNativeImageAvailable()
    {
        try
        {
            auto result = execute(["native-image", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    private string buildNativeImage(
        string jarPath,
        const ScalaConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        ref ScalaBuildResult result
    )
    {
        // Build native-image command
        string[] cmd = ["native-image"];
        
        // Add configuration
        if (!config.nativeImage.mainClass.empty)
            cmd ~= ["--main-class=" ~ config.nativeImage.mainClass];
        
        // Static image
        if (config.nativeImage.staticImage)
            cmd ~= "--static";
        
        // No fallback
        if (config.nativeImage.noFallback)
            cmd ~= "--no-fallback";
        
        // Quick build (less optimization)
        if (config.nativeImage.quickBuild)
            cmd ~= "-Ob";
        
        // Initialize at build time
        foreach (cls; config.nativeImage.initializeAtBuildTime)
            cmd ~= "--initialize-at-build-time=" ~ cls;
        
        // Initialize at run time
        foreach (cls; config.nativeImage.initializeAtRunTime)
            cmd ~= "--initialize-at-run-time=" ~ cls;
        
        // Reflection configuration
        if (config.nativeImage.enableReflection)
        {
            // Check for reflection config files
            string reflectConfigPath = buildPath(workspace.root, "META-INF", "native-image", "reflect-config.json");
            if (exists(reflectConfigPath))
                cmd ~= "-H:ReflectionConfigurationFiles=" ~ reflectConfigPath;
        }
        
        // Additional build args
        cmd ~= config.nativeImage.buildArgs;
        
        // Add JVM flags
        cmd ~= config.jvmFlags;
        
        // JAR to compile
        cmd ~= ["-jar", jarPath];
        
        // Output name
        string imageName = config.nativeImage.imageName;
        if (imageName.empty)
        {
            imageName = target.name.split(":")[$ - 1];
            version(Windows)
                imageName ~= ".exe";
        }
        
        string outputPath = buildPath(workspace.options.outputDir, imageName);
        cmd ~= ["-o", outputPath];
        
        structuredLog.info("building_native_image_this_may_take_seve").emit();
        structuredLog.debug_("command_").field("detail", "Command: " ~ cmd.join(" ")).emit();
        
        // Execute native-image (this can be slow)
        auto res = execute(cmd, null, Config.none, size_t.max, workspace.root);
        
        if (res.status != 0)
        {
            result.error = "native-image compilation failed:\n" ~ res.output;
            return "";
        }
        
        structuredLog.info("native_image_created_successfully_").field("detail", "Native image created successfully: " ~ outputPath).emit();
        
        return outputPath;
    }
}

