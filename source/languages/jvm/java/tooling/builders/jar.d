module languages.jvm.java.tooling.builders.jar;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import core.time : MonoTime;
import languages.jvm.java.tooling.builders.base;
import languages.jvm.java.core.config;
import languages.jvm.java.tooling.detection;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionId, ActionType;
import engine.workers.integration : JavaWorkerIntegration, shouldUsePersistentWorker;

/// Standard JAR builder with action-level caching for per-file compilation
class JARBuilder : JavaBuilder
{
    protected ActionCache actionCache;
    
    this(ActionCache actionCache = null)
    {
        this.actionCache = actionCache;
    }
    
    override JavaBuildResult build(
        in string[] sources,
        in JavaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        JavaBuildResult result;
        
        structuredLog.debug_("building_jar_").field("detail", "Building JAR: " ~ target.name).emit();
        
        // Determine output path
        string outputPath = getOutputPath(target, workspace, config);
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Create temporary build directory
        string tempDir = buildPath(outputDir, ".java-build-" ~ target.name.split(":")[$ - 1]);
        if (exists(tempDir))
            rmdirRecurse(tempDir);
        mkdirRecurse(tempDir);
        
        scope(failure)
        {
            // Clean up temp directory on failure
            if (exists(tempDir))
            {
                try {
                    rmdirRecurse(tempDir);
                }
                catch (Exception e) {
                    // Ignore cleanup errors
                }
            }
        }
        
        scope(success)
        {
            // Clean up temp directory on success
            if (exists(tempDir))
                rmdirRecurse(tempDir);
        }
        
        // Compile sources
        if (!compileSources(sources, tempDir, config, target, workspace, result))
            return result;
        
        // Create JAR
        if (!createJAR(tempDir, outputPath, config, target, result))
            return result;
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    override bool isAvailable()
    {
        return JavaToolDetection.isJavacAvailable() && JavaToolDetection.isJarAvailable();
    }
    
    override string name() const
    {
        return "JAR";
    }
    
    override bool supportsMode(JavaBuildMode mode)
    {
        return mode == JavaBuildMode.JAR || mode == JavaBuildMode.Compile;
    }
    
    protected bool compileSources(
        const string[] sources,
        string outputDir,
        const JavaConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        ref JavaBuildResult result
    )
    {
        structuredLog.info("compiling_java_sources").emit();
        
        string javacCmd = JavaToolDetection.getJavacCommand();
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["javac"] = javacCmd;
        if (config.sourceVersion.major > 0)
            metadata["source"] = config.sourceVersion.toString();
        if (config.targetVersion.major > 0)
            metadata["target"] = config.targetVersion.toString();
        metadata["encoding"] = config.encoding;
        metadata["warnings"] = config.warnings.to!string;
        metadata["enablePreview"] = config.enablePreview.to!string;
        metadata["compilerFlags"] = config.compilerFlags.join(" ");
        metadata["targetFlags"] = target.flags.join(" ");
        
        string classpath = buildClasspath(target, workspace, config);
        if (!classpath.empty)
            metadata["classpath"] = classpath;
        
        if (config.modules.enabled && !config.modules.modulePath.empty)
            metadata["modulePath"] = config.modules.modulePath.join(pathSeparator);
        
        // Build compiler options for persistent worker
        string[] options = buildCompilerOptions(config, target, classpath);
        
        // Try persistent worker for batch compilation (much faster for JVM)
        if (shouldUsePersistentWorker("jvm-javac"))
        {
            auto workerResult = JavaWorkerIntegration.compile(
                sources.dup,
                outputDir,
                classpath.empty ? [] : [classpath],
                options,
                true  // usePersistentWorker
            );
            
            if (workerResult.isOk)
            {
                auto r = workerResult.unwrap();
                if (r.success)
                {
                    structuredLog.info("__warm_worker_compiled_").field("detail", "  [Warm worker] Compiled " ~ sources.length.to!string ~ 
                               " files in " ~ r.executionTimeMs.to!string ~ "ms" ~
                               " (speedup: " ~ r.estimatedSpeedup().to!string ~ "x)").emit();
                    return true;
                }
                // Worker compiled but failed - report error
                result.error = r.output;
                return false;
            }
            // Worker unavailable, fall through to direct compilation
            structuredLog.debug_("persistent_worker_unavailable_using_dire").emit();
        }
        
        // Fallback: Compile per-file with action caching
        bool allSuccess = true;
        bool hasActionCache = actionCache !is null;
        
        foreach (source; sources)
        {
            string sourceBase = baseName(source, ".java");
            string expectedClass = buildPath(outputDir, sourceBase ~ ".class");
            
            ActionId actionId;
            actionId.targetId = target.name;
            actionId.type = ActionType.Compile;
            actionId.subId = source;
            actionId.inputHash = FastHash.hashFile(source);
            
            if (hasActionCache && actionCache.isCached(actionId, [source], metadata))
            {
                if (exists(expectedClass))
                {
                    structuredLog.debug_("__cached_").field("detail", "  [Cached] " ~ source).emit();
                    continue;
                }
            }
            
            // Direct compilation
            string[] cmd = [javacCmd, "-d", outputDir] ~ options ~ [source];
            
            structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ source).emit();
            
            auto compileRes = execute(cmd);
            bool success = compileRes.status == 0;
            
            if (hasActionCache)
            {
                string[] outputs = exists(expectedClass) ? [expectedClass] : [];
                actionCache.update(actionId, [source], outputs, metadata, success);
            }
            
            if (!success)
            {
                result.error = "javac failed on " ~ source ~ ":\n" ~ compileRes.output;
                allSuccess = false;
                break;
            }
            
            if (!compileRes.output.empty)
                result.warnings ~= compileRes.output.splitLines;
        }
        
        return allSuccess;
    }
    
    /// Build compiler options from config
    private string[] buildCompilerOptions(
        const JavaConfig config,
        const Target target,
        string classpath
    )
    {
        string[] opts;
        
        if (config.sourceVersion.major > 0)
            opts ~= ["-source", config.sourceVersion.toString()];
        if (config.targetVersion.major > 0)
            opts ~= ["-target", config.targetVersion.toString()];
        
        opts ~= ["-encoding", config.encoding];
        
        if (config.warnings)
            opts ~= "-Xlint:all";
        if (config.warningsAsErrors)
            opts ~= "-Werror";
        if (config.deprecation)
            opts ~= "-Xlint:deprecation";
        if (config.enablePreview)
            opts ~= "--enable-preview";
        
        if (!classpath.empty)
            opts ~= ["-cp", classpath];
        
        if (config.modules.enabled && !config.modules.modulePath.empty)
            opts ~= ["--module-path", config.modules.modulePath.join(pathSeparator)];
        
        if (config.processors.enabled)
        {
            if (!config.processors.processorPath.empty)
                opts ~= ["--processor-path", config.processors.processorPath.join(pathSeparator)];
            if (!config.processors.processors.empty)
                opts ~= ["-processor", config.processors.processors.join(",")];
        }
        
        opts ~= config.compilerFlags;
        opts ~= target.flags;
        
        return opts;
    }
    
    protected bool createJAR(
        string classDir,
        string outputPath,
        const JavaConfig config,
        const Target target,
        ref JavaBuildResult result
    )
    {
        structuredLog.info("creating_jar_").field("detail", "Creating JAR: " ~ outputPath).emit();
        
        string jarCmd = JavaToolDetection.getJarCommand();
        string[] cmd = [jarCmd];
        
        // Auto-detect main class for executable JARs if not specified
        string mainClass = config.packaging.mainClass;
        if (mainClass.empty && target.type == TargetType.Executable)
        {
            mainClass = detectMainClass(classDir);
            if (!mainClass.empty)
            {
                structuredLog.debug_("autodetected_main_class_").field("detail", "Auto-detected main class: " ~ mainClass).emit();
            }
        }
        
        // Determine if this is an executable JAR
        bool isExecutable = !mainClass.empty;
        bool hasManifestAttrs = !config.packaging.manifestAttributes.empty;
        
        // Build JAR command flags
        // Order matters: c=create, f=file, m=manifest, e=entry(main)
        // Note: 'i' (index) cannot be combined with 'c' in short-form commands
        string flags = "cf";
        
        // Decide whether to use manifest file or 'e' flag
        // Use manifest file if there are custom attributes, otherwise use 'e' flag for simplicity
        bool useManifestFile = hasManifestAttrs || isExecutable;
        string manifestFile;
        
        if (useManifestFile)
        {
            flags ~= "m";
            manifestFile = buildPath(classDir, "MANIFEST.MF");
            createManifestWithMainClass(manifestFile, config, mainClass);
        }
        
        // Add flags and output path
        cmd ~= [flags, outputPath];
        
        // Add manifest file if using it
        if (useManifestFile)
            cmd ~= manifestFile;
        
        // Add classes
        cmd ~= ["-C", classDir, "."];
        
        structuredLog.debug_("jar_command_").field("detail", "JAR command: " ~ cmd.join(" ")).emit();
        
        auto jarRes = execute(cmd);
        
        if (jarRes.status != 0)
        {
            result.error = "jar creation failed:\n" ~ jarRes.output;
            return false;
        }
        
        // Add index if requested (must be done after JAR creation)
        if (config.packaging.createIndex)
        {
            structuredLog.debug_("adding_index_to_jar").emit();
            string[] indexCmd = [jarCmd, "i", outputPath];
            auto indexRes = execute(indexCmd);
            
            if (indexRes.status != 0)
            {
                // Index creation is not critical, just log warning
                structuredLog.warning("failed_to_create_jar_index_").field("detail", "Failed to create JAR index: " ~ indexRes.output).emit();
            }
        }
        
        return true;
    }
    
    protected void createManifestWithMainClass(string manifestPath, const JavaConfig config, string mainClass)
    {
        auto f = File(manifestPath, "w");
        
        f.writeln("Manifest-Version: 1.0");
        
        if (!mainClass.empty)
            f.writeln("Main-Class: " ~ mainClass);
        
        foreach (key, value; config.packaging.manifestAttributes)
            f.writeln(key ~ ": " ~ value);
        
        f.close();
    }
    
    /// Auto-detect main class by searching for classes with public static void main(String[]) method
    protected string detectMainClass(string classDir)
    {
        import std.file : dirEntries, SpanMode;
        import std.algorithm : endsWith;
        
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
            
            // Skip inner classes (containing $)
            if (className.indexOf('$') >= 0)
                continue;
            
            // Check if this class has a main method using javap
            if (hasMainMethod(className, classDir))
            {
                return className;
            }
        }
        
        return "";
    }
    
    /// Check if a class has a public static void main(String[]) method
    private bool hasMainMethod(string className, string classDir)
    {
        try
        {
            // Use javap to inspect the class
            auto result = execute(["javap", "-cp", classDir, "-public", className]);
            
            if (result.status == 0)
            {
                // Look for main method signature
                auto regex = regex(`public\s+static\s+void\s+main\s*\(\s*java\.lang\.String\s*\[\s*\]\s*\)`);
                return !matchFirst(result.output, regex).empty;
            }
        }
        catch (Exception e)
        {
            // Ignore errors
        }
        
        return false;
    }
    
    protected string buildClasspath(const Target target, const WorkspaceConfig workspace, const JavaConfig config)
    {
        string[] paths;
        
        // Add explicitly configured classpath
        paths ~= config.classpath;
        
        // Add dependencies
        foreach (dep; target.deps)
        {
            auto depTarget = workspace.findTarget(dep);
            if (depTarget !is null)
            {
                // Find the output JAR of the dependency
                string depOutput = getOutputPath(*depTarget, workspace, config);
                if (exists(depOutput))
                    paths ~= depOutput;
            }
        }
        
        version(Windows)
            return paths.join(";");
        else
            return paths.join(":");
    }
    
    protected string pathSeparator()
    {
        version(Windows)
            return ";";
        else
            return ":";
    }
    
    protected string getOutputPath(const Target target, const WorkspaceConfig workspace, const JavaConfig config)
    {
        if (!target.outputPath.empty)
            return buildPath(workspace.options.outputDir, target.outputPath);
        
        string name = target.name.split(":")[$ - 1];
        return buildPath(workspace.options.outputDir, name ~ ".jar");
    }
}

