module languages.jvm.scala.tooling.builders.jar;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import std.regex;
import languages.jvm.scala.tooling.builders.base;
import languages.jvm.scala.core.config;
import languages.jvm.scala.tooling.detection;
import languages.jvm.scala.tooling.info;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Standard JAR builder using scalac with action-level caching
class JARBuilder : ScalaBuilder
{
    private ActionCache actionCache;
    
    this(ActionCache cache = null)
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/scala", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
    }
    override ScalaBuildResult build(
        in string[] sources,
        in ScalaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ScalaBuildResult result;
        
        structuredLog.debug_("building_scala_jar_").field("detail", "Building Scala JAR: " ~ target.name).emit();
        
        // Determine output path
        string outputPath = getOutputPath(target, workspace);
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Create temp directory for class files
        auto tempDir = buildPath(outputDir, ".scala-build-" ~ target.name.replace(":", "-"));
        if (!exists(tempDir))
            mkdirRecurse(tempDir);
        
        scope(failure)
        {
            // Clean up temp directory on failure
            if (exists(tempDir))
                rmdirRecurse(tempDir);
        }
        
        scope(success)
        {
            // Clean up temp directory on success
            if (exists(tempDir))
                rmdirRecurse(tempDir);
        }
        
        // Compile sources
        bool compiled = compileSources(sources, tempDir, config, target, workspace, result);
        if (!compiled)
            return result;
        
        // Package into JAR
        bool packaged = packageJAR(tempDir, outputPath, config, target, result);
        if (!packaged)
            return result;
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    override bool isAvailable()
    {
        return ScalaToolDetection.isScalacAvailable();
    }
    
    override string name() const
    {
        return "JAR";
    }
    
    override bool supportsMode(ScalaBuildMode mode)
    {
        return mode == ScalaBuildMode.JAR || mode == ScalaBuildMode.Compile;
    }
    
    private bool compileSources(
        const string[] sources,
        string outputDir,
        const ScalaConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        ref ScalaBuildResult result
    )
    {
        // Build classpath
        string cp = buildClasspath(target, workspace);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = "scalac";
        metadata["version"] = format("%d.%d.%d", config.versionInfo.major, config.versionInfo.minor, config.versionInfo.patch);
        metadata["target"] = config.compiler.target;
        metadata["flags"] = (target.flags ~ buildCompilerOptions(config)).join(" ");
        metadata["classpath"] = cp;
        
        // Compile each source file with per-file caching
        foreach (source; sources)
        {
            // Create action ID for this compilation
            ActionId actionId;
            actionId.targetId = target.name;
            actionId.type = ActionType.Compile;
            actionId.subId = baseName(source);
            actionId.inputHash = FastHash.hashFile(source);
            
            // Check if this compilation is cached
            if (actionCache.isCached(actionId, [source], metadata))
            {
                // Check if class files exist
                bool classExists = false;
                if (exists(outputDir))
                {
                    auto baseName_ = baseName(source, ".scala");
                    foreach (entry; dirEntries(outputDir, "*.class", SpanMode.depth))
                    {
                        if (entry.name.indexOf(baseName_) >= 0)
                        {
                            classExists = true;
                            break;
                        }
                    }
                }
                
                if (classExists)
                {
                    structuredLog.debug_("__cached_").field("detail", "  [Cached] " ~ source).emit();
                    continue;
                }
            }
            
            // Build scalac command for this file
            string[] cmd = [ScalaToolDetection.getScalacCommand()];
            
            // Output directory
            cmd ~= ["-d", outputDir];
            
            // Classpath
            if (!cp.empty)
                cmd ~= ["-classpath", cp];
            
            // Add compiler options
            cmd ~= buildCompilerOptions(config);
            
            // Add target flags
            cmd ~= target.flags;
            
            // Add this source file
            cmd ~= [source];
            
            structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ source).emit();
            
            // Execute compilation
            auto compileRes = execute(cmd);
            
            bool success = (compileRes.status == 0);
            
            // Collect output files
            string[] outputs;
            if (success && exists(outputDir))
            {
                auto baseName_ = baseName(source, ".scala");
                foreach (entry; dirEntries(outputDir, "*.class", SpanMode.depth))
                {
                    if (entry.name.indexOf(baseName_) >= 0)
                        outputs ~= entry.name;
                }
            }
            
            if (!success)
            {
                result.error = "Scala compilation failed for " ~ source ~ ":\n" ~ compileRes.output;
                result.compilerMessages ~= compileRes.output;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    [source],
                    [],
                    metadata,
                    false
                );
                
                return false;
            }
            
            // Capture warnings
            if (!compileRes.output.empty)
            {
                result.warnings ~= "In " ~ source ~ ": " ~ compileRes.output;
                result.compilerMessages ~= compileRes.output;
            }
            
            // Update cache with success
            actionCache.update(
                actionId,
                [source],
                outputs,
                metadata,
                true
            );
        }
        
        return true;
    }
    
    private bool packageJAR(
        string classDir,
        string outputPath,
        const ScalaConfig config,
        const Target target,
        ref ScalaBuildResult result
    )
    {
        // Build metadata for cache validation
        string[string] metadata;
        metadata["operation"] = "jar-package";
        metadata["targetType"] = target.type.to!string;
        
        // Collect all class files as inputs
        string[] classFiles;
        if (exists(classDir))
        {
            foreach (entry; dirEntries(classDir, "*.class", SpanMode.depth))
                classFiles ~= entry.name;
        }
        
        if (classFiles.empty)
        {
            result.error = "No class files found to package";
            return false;
        }
        
        // Create action ID for packaging
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = baseName(outputPath);
        actionId.inputHash = FastHash.hashStrings(classFiles);
        
        // Check if packaging is cached
        if (actionCache.isCached(actionId, classFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_jar_package_").field("detail", "  [Cached] JAR package: " ~ outputPath).emit();
            return true;
        }
        
        // Build jar command
        string[] cmd = ["jar"];
        
        // Create with manifest if needed
        if (target.type == TargetType.Executable)
        {
            // Find main class
            string mainClass = detectMainClass(classDir, config);
            if (mainClass.empty)
            {
                structuredLog.warning("no_main_class_found_for_executable").emit();
            }
            else
            {
                // Create manifest
                string manifestPath = buildPath(classDir, "MANIFEST.MF");
                createManifest(manifestPath, mainClass);
                cmd ~= ["cfm", outputPath, manifestPath];
            }
        }
        else
        {
            cmd ~= ["cf", outputPath];
        }
        
        // Add class files
        cmd ~= ["-C", classDir, "."];
        
        structuredLog.debug_("jar_command_").field("detail", "JAR command: " ~ cmd.join(" ")).emit();
        
        // Execute jar packaging
        auto jarRes = execute(cmd);
        
        bool success = (jarRes.status == 0);
        
        if (!success)
        {
            result.error = "JAR creation failed:\n" ~ jarRes.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                classFiles,
                [],
                metadata,
                false
            );
            
            return false;
        }
        
        // Update cache with success
        actionCache.update(
            actionId,
            classFiles,
            [outputPath],
            metadata,
            true
        );
        
        return true;
    }
    
    private string[] buildCompilerOptions(const ScalaConfig config)
    {
        string[] options;
        
        // Version-specific
        if (config.versionInfo.isScala3())
        {
            // Scala 3 options
            if (config.compiler.experimental)
                options ~= "-experimental";
            
            if (config.compiler.explainTypes)
                options ~= "-explain";
            
            if (config.compiler.safeInit)
                options ~= "-Ysafe-init";
        }
        else
        {
            // Scala 2 options
            if (config.compiler.optimization != OptimizationLevel.None)
            {
                auto optOpts = ScalaInfoDetector.getOptimizationOptions(
                    config.compiler.optimization, 
                    config.versionInfo
                );
                options ~= optOpts;
            }
        }
        
        // Common options
        if (config.compiler.deprecation)
            options ~= "-deprecation";
        
        if (config.compiler.feature)
            options ~= "-feature";
        
        if (config.compiler.unchecked)
            options ~= "-unchecked";
        
        if (config.compiler.warnings)
        {
            if (config.compiler.warningsAsErrors)
                options ~= "-Xfatal-warnings";
        }
        
        // Target JVM
        if (!config.compiler.target.empty)
            options ~= ["-target:jvm-" ~ config.compiler.target];
        
        // Encoding
        options ~= ["-encoding", config.compiler.encoding];
        
        // Language features
        foreach (feature; config.compiler.languageFeatures)
            options ~= "-language:" ~ feature;
        
        // Plugins
        foreach (plugin; config.compiler.plugins)
            options ~= ["-Xplugin:" ~ plugin];
        
        // Additional options
        options ~= config.compiler.options;
        
        return options;
    }
    
    private string buildClasspath(const Target target, const WorkspaceConfig workspace)
    {
        string[] paths;
        
        // Add dependency outputs
        foreach (dep; target.deps)
        {
            auto depTarget = workspace.findTarget(dep);
            if (depTarget !is null)
            {
                string depOutput = buildPath(workspace.options.outputDir, depTarget.outputPath);
                if (depOutput.empty)
                    depOutput = buildPath(workspace.options.outputDir, dep.split(":")[$ - 1] ~ ".jar");
                paths ~= depOutput;
            }
        }
        
        // Add explicit classpath
        // paths ~= config.classpath;
        
        version(Windows)
            return paths.join(";");
        else
            return paths.join(":");
    }
    
    private string detectMainClass(string classDir, const ScalaConfig config)
    {
        import std.file : dirEntries, SpanMode;
        import std.algorithm : endsWith;
        
        structuredLog.debug_("scanning_for_main_class_in_").field("detail", "Scanning for main class in: " ~ classDir).emit();
        
        // Search for .class files
        foreach (entry; dirEntries(classDir, SpanMode.depth))
        {
            if (!entry.isFile || !entry.name.endsWith(".class"))
                continue;
            
            // Get class name from path
            string relPath = entry.name[classDir.length + 1 .. $];
            if (relPath.startsWith("./"))
                relPath = relPath[2 .. $];
            
            // Convert path to class name (remove .class and replace / with .)
            string className = relPath[0 .. $ - 6].replace("/", ".").replace("\\", ".");
            
            // Skip inner classes and anonymous classes (containing $)
            if (className.indexOf('$') >= 0)
                continue;
            
            // Check if this class has a main method
            if (hasMainMethod(className, classDir))
            {
                structuredLog.debug_("found_main_class_").field("detail", "Found main class: " ~ className).emit();
                return className;
            }
        }
        
        structuredLog.debug_("no_main_class_detected").emit();
        return "";
    }
    
    /// Check if a class has a public static void main(String[]) method
    private bool hasMainMethod(string className, string classDir)
    {
        import std.regex;
        
        try
        {
            // Use javap to inspect the class
            auto result = execute(["javap", "-cp", classDir, "-public", className]);
            
            if (result.status == 0)
            {
                // Look for main method signature (both Java and Scala styles)
                // Java: public static void main(java.lang.String[])
                // Scala: public static void main(java.lang.String[])
                auto javaMainRe = regex(`public\s+static\s+void\s+main\s*\(\s*java\.lang\.String\s*\[\s*\]\s*\)`);
                if (!matchFirst(result.output, javaMainRe).empty)
                    return true;
                
                // Scala App trait style (extends scala.App)
                auto scalaAppRe = regex(`extends\s+scala\.App`);
                if (!matchFirst(result.output, scalaAppRe).empty)
                    return true;
            }
        }
        catch (Exception e)
        {
            structuredLog.debug_("error_checking_class_").field("detail", "Error checking class " ~ className ~ ": " ~ e.msg).emit();
        }
        
        return false;
    }
    
    private void createManifest(string path, string mainClass)
    {
        auto f = File(path, "w");
        f.writeln("Manifest-Version: 1.0");
        f.writeln("Main-Class: " ~ mainClass);
        f.close();
    }
    
    private string getOutputPath(const Target target, const WorkspaceConfig workspace)
    {
        if (!target.outputPath.empty)
            return buildPath(workspace.options.outputDir, target.outputPath);
        
        string name = target.name.split(":")[$ - 1];
        return buildPath(workspace.options.outputDir, name ~ ".jar");
    }
}

