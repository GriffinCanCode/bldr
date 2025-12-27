module languages.jvm.java.tooling.builders.native_;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.jvm.java.tooling.builders.base;
import languages.jvm.java.tooling.builders.jar;
import languages.jvm.java.core.config;
import languages.jvm.java.tooling.detection;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// GraalVM Native Image builder
class NativeImageBuilder : JARBuilder
{
    this(ActionCache actionCache = null)
    {
        super(actionCache);
    }
    
    override string name() const
    {
        return "NativeImage";
    }
    
    override bool supportsMode(JavaBuildMode mode)
    {
        return mode == JavaBuildMode.NativeImage;
    }
    
    override bool isAvailable()
    {
        return super.isAvailable() && JavaToolDetection.isNativeImageAvailable();
    }
    
    override JavaBuildResult build(
        in string[] sources,
        in JavaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        JavaBuildResult result;
        
        if (!isAvailable())
        {
            result.error = "GraalVM native-image tool not found. Install GraalVM and native-image component.";
            return result;
        }
        
        if (!config.nativeImage.enabled)
        {
            result.error = "Native image build not enabled in configuration";
            return result;
        }
        
        structuredLog.debug_("building_native_image_").field("detail", "Building Native Image: " ~ target.name).emit();
        
        // First, build a regular JAR
        string outputPath = getOutputPath(target, workspace, config);
        string outputDir = dirName(outputPath);
        string jarPath = buildPath(outputDir, target.name.split(":")[$ - 1] ~ "-temp.jar");
        
        // Create a mutable copy of target for JAR building
        import infrastructure.config.schema.schema : Target;
        Target mutableTarget = cast(Target) target;
        string originalOutput = mutableTarget.outputPath;
        mutableTarget.outputPath = jarPath;
        
        auto jarResult = super.build(sources, config, mutableTarget, workspace);
        
        if (!jarResult.success)
        {
            result.error = "Failed to build JAR for native image: " ~ jarResult.error;
            return result;
        }
        
        // Now build native image from JAR
        if (!buildNativeImage(jarPath, outputPath, config, result))
        {
            // Clean up temp JAR
            if (exists(jarPath))
                remove(jarPath);
            return result;
        }
        
        // Clean up temp JAR
        if (exists(jarPath))
            remove(jarPath);
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    private bool buildNativeImage(
        string jarPath,
        string outputPath,
        const JavaConfig config,
        ref JavaBuildResult result
    )
    {
        structuredLog.info("building_graalvm_native_image").emit();
        
        string[] cmd = ["native-image"];
        
        // Add main class
        if (!config.nativeImage.mainClass.empty)
            cmd ~= ["-cp", jarPath, config.nativeImage.mainClass];
        else if (!config.packaging.mainClass.empty)
            cmd ~= ["-cp", jarPath, config.packaging.mainClass];
        else
            cmd ~= ["-jar", jarPath];
        
        // Output name
        string imageName = config.nativeImage.imageName;
        if (imageName.empty)
            imageName = baseName(outputPath).stripExtension;
        
        cmd ~= ["-o", outputPath];
        
        // Static linking
        if (config.nativeImage.staticImage)
            cmd ~= "--static";
        
        // No fallback
        if (config.nativeImage.noFallback)
            cmd ~= "--no-fallback";
        
        // Initialize at build time
        if (!config.nativeImage.initializeAtBuildTime.empty)
        {
            foreach (cls; config.nativeImage.initializeAtBuildTime)
                cmd ~= ["--initialize-at-build-time=" ~ cls];
        }
        
        // Initialize at run time
        if (!config.nativeImage.initializeAtRunTime.empty)
        {
            foreach (cls; config.nativeImage.initializeAtRunTime)
                cmd ~= ["--initialize-at-run-time=" ~ cls];
        }
        
        // Enable reflection
        if (config.nativeImage.enableReflection)
        {
            // Look for reflect-config.json in resources
            string[] configDirs = [
                "src/main/resources/META-INF/native-image",
                "resources/META-INF/native-image",
                "META-INF/native-image"
            ];
            
            foreach (dir; configDirs)
            {
                if (exists(dir))
                {
                    cmd ~= ["-H:ReflectionConfigurationFiles=" ~ buildPath(dir, "reflect-config.json")];
                    break;
                }
            }
        }
        
        // Add custom build arguments
        cmd ~= config.nativeImage.buildArgs;
        
        // Verbose output
        if (config.warnings)
            cmd ~= "--verbose";
        
        structuredLog.debug_("native_image_command_").field("detail", "Native image command: " ~ cmd.join(" ")).emit();
        structuredLog.info("building_native_image_this_may_take_seve").emit();
        
        auto nativeRes = execute(cmd);
        
        if (nativeRes.status != 0)
        {
            result.error = "native-image failed:\n" ~ nativeRes.output;
            return false;
        }
        
        if (!nativeRes.output.empty)
            result.warnings ~= nativeRes.output.splitLines;
        
        structuredLog.info("native_image_built_successfully").emit();
        
        return true;
    }
    
    protected override string getOutputPath(const Target target, const WorkspaceConfig workspace, const JavaConfig config)
    {
        if (!target.outputPath.empty)
            return buildPath(workspace.options.outputDir, target.outputPath);
        
        string name = target.name.split(":")[$ - 1];
        
        // Native executables don't have .jar extension
        version(Windows)
            name ~= ".exe";
        
        return buildPath(workspace.options.outputDir, name);
    }
}

