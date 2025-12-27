module languages.jvm.kotlin.tooling.builders.jar;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.jvm.kotlin.tooling.builders.base;
import languages.jvm.kotlin.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Standard JAR builder for Kotlin with action-level caching
class JARBuilder : KotlinBuilder
{
    private ActionCache actionCache;
    
    this(ActionCache cache = null)
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/kotlin", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
    }
    override KotlinBuildResult build(
        in string[] sources,
        in KotlinConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        KotlinBuildResult result;
        
        structuredLog.debug_("building_standard_kotlin_jar").emit();
        
        // Determine output path
        string outputPath;
        if (!target.outputPath.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name ~ ".jar");
        }
        
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Use Gradle if available and configured
        if (config.buildTool == KotlinBuildTool.Gradle)
        {
            return buildWithGradle(sources, config, target, workspace, outputPath);
        }
        
        // Use Maven if available and configured
        if (config.buildTool == KotlinBuildTool.Maven)
        {
            return buildWithMaven(sources, config, target, workspace, outputPath);
        }
        
        // Direct kotlinc compilation
        return buildWithKotlinC(sources, config, target, workspace, outputPath);
    }
    
    override bool isAvailable()
    {
        // Check if kotlinc is available
        auto result = execute(["kotlinc", "-version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "JAR";
    }
    
    override bool supportsMode(KotlinBuildMode mode)
    {
        return mode == KotlinBuildMode.JAR || mode == KotlinBuildMode.Compile;
    }
    
    private KotlinBuildResult buildWithGradle(
        const string[] sources,
        const KotlinConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string outputPath
    )
    {
        KotlinBuildResult result;
        
        import languages.jvm.kotlin.managers.gradle;
        
        string projectDir = ".";
        if (!sources.empty)
        {
            projectDir = dirName(sources[0]);
            // Navigate to project root (where build.gradle.kts is)
            while (!exists(buildPath(projectDir, "build.gradle.kts")) && 
                   !exists(buildPath(projectDir, "build.gradle")) &&
                   projectDir != dirName(projectDir))
            {
                projectDir = dirName(projectDir);
            }
        }
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["buildTool"] = "gradle";
        metadata["flags"] = target.flags.join(" ");
        metadata["projectDir"] = projectDir;
        metadata["languageVersion"] = config.languageVersion.toString();
        metadata["jvmTarget"] = config.jvmTarget.toString();
        
        // Collect all input files
        string[] inputFiles = sources.dup;
        auto buildFile = buildPath(projectDir, "build.gradle.kts");
        if (!exists(buildFile))
            buildFile = buildPath(projectDir, "build.gradle");
        if (exists(buildFile))
            inputFiles ~= buildFile;
        
        // Create action ID for Gradle build
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = "gradle-jar";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if Gradle build is cached
        if (actionCache.isCached(actionId, inputFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_gradle_jar_").field("detail", "  [Cached] Gradle JAR: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        bool success = GradleOps.jar(projectDir, true);
        
        if (success)
        {
            result.success = true;
            result.outputs = [outputPath];
            
            // Try to find the actual JAR in build/libs
            string libsDir = buildPath(projectDir, "build", "libs");
            if (exists(libsDir))
            {
                auto jars = dirEntries(libsDir, "*.jar", SpanMode.shallow)
                    .map!(e => e.name)
                    .array;
                if (!jars.empty)
                {
                    result.outputs = jars;
                    result.outputHash = FastHash.hashFile(jars[0]);
                }
            }
            
            // Update cache with success
            actionCache.update(
                actionId,
                inputFiles,
                result.outputs,
                metadata,
                true
            );
        }
        else
        {
            result.error = "Gradle JAR build failed";
            
            // Update cache with failure
            actionCache.update(
                actionId,
                inputFiles,
                [],
                metadata,
                false
            );
        }
        
        return result;
    }
    
    private KotlinBuildResult buildWithMaven(
        const string[] sources,
        const KotlinConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string outputPath
    )
    {
        KotlinBuildResult result;
        
        import languages.jvm.kotlin.managers.maven;
        
        string projectDir = ".";
        if (!sources.empty)
        {
            projectDir = dirName(sources[0]);
            // Navigate to project root (where pom.xml is)
            while (!exists(buildPath(projectDir, "pom.xml")) &&
                   projectDir != dirName(projectDir))
            {
                projectDir = dirName(projectDir);
            }
        }
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["buildTool"] = "maven";
        metadata["flags"] = target.flags.join(" ");
        metadata["projectDir"] = projectDir;
        metadata["skipTests"] = config.maven.skipTests.to!string;
        
        // Collect all input files
        string[] inputFiles = sources.dup;
        auto pomFile = buildPath(projectDir, "pom.xml");
        if (exists(pomFile))
            inputFiles ~= pomFile;
        
        // Create action ID for Maven build
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = "maven-jar";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if Maven build is cached
        if (actionCache.isCached(actionId, inputFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_maven_jar_").field("detail", "  [Cached] Maven JAR: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        bool success = MavenOps.package_(projectDir, config.maven.skipTests);
        
        if (success)
        {
            result.success = true;
            result.outputs = [outputPath];
            
            // Try to find the actual JAR in target/
            string targetDir = buildPath(projectDir, "target");
            if (exists(targetDir))
            {
                auto jars = dirEntries(targetDir, "*.jar", SpanMode.shallow)
                    .filter!(e => !e.name.endsWith("-sources.jar") && !e.name.endsWith("-javadoc.jar"))
                    .map!(e => e.name)
                    .array;
                if (!jars.empty)
                {
                    result.outputs = jars;
                    result.outputHash = FastHash.hashFile(jars[0]);
                }
            }
            
            // Update cache with success
            actionCache.update(
                actionId,
                inputFiles,
                result.outputs,
                metadata,
                true
            );
        }
        else
        {
            result.error = "Maven package failed";
            
            // Update cache with failure
            actionCache.update(
                actionId,
                inputFiles,
                [],
                metadata,
                false
            );
        }
        
        return result;
    }
    
    private KotlinBuildResult buildWithKotlinC(
        const string[] sources,
        const KotlinConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string outputPath
    )
    {
        KotlinBuildResult result;
        
        // Create temp directory for class files
        string outputDir = dirName(outputPath);
        auto tempClassDir = buildPath(outputDir, ".kotlin-classes-" ~ target.name.replace(":", "-"));
        if (!exists(tempClassDir))
            mkdirRecurse(tempClassDir);
        
        // Per-file compilation with caching
        auto compileResult = compileSourcesPerFile(sources, config, target, workspace, tempClassDir);
        if (!compileResult.success)
        {
            // Clean up temp directory
            if (exists(tempClassDir))
                rmdirRecurse(tempClassDir);
            return compileResult;
        }
        
        // Package into JAR with caching
        auto packageResult = packageToJAR(tempClassDir, outputPath, config, target);
        
        // Clean up temp directory
        if (exists(tempClassDir))
            rmdirRecurse(tempClassDir);
        
        return packageResult;
    }
    
    /// Compile Kotlin sources per-file with action-level caching
    private KotlinBuildResult compileSourcesPerFile(
        const string[] sources,
        const KotlinConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string outputDir
    )
    {
        KotlinBuildResult result;
        result.success = true;
        
        // Build classpath
        string[] classpaths = config.classpath.dup;
        foreach (dep; target.deps)
        {
            auto depTarget = workspace.findTarget(dep);
            if (depTarget !is null && !depTarget.outputPath.empty)
            {
                classpaths ~= buildPath(workspace.options.outputDir, depTarget.outputPath);
            }
        }
        
        // Build common metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = "kotlinc";
        metadata["languageVersion"] = config.languageVersion.toString();
        metadata["apiVersion"] = config.apiVersion.toString();
        metadata["jvmTarget"] = config.jvmTarget.toString();
        metadata["flags"] = (target.flags ~ config.compilerFlags).join(" ");
        metadata["classpath"] = classpaths.join(":");
        metadata["progressive"] = config.progressive.to!string;
        
        // Compile each source file
        foreach (source; sources)
        {
            // Create action ID for this compilation
            ActionId actionId;
            actionId.targetId = target.name;
            actionId.type = ActionType.Compile;
            actionId.subId = baseName(source);
            actionId.inputHash = FastHash.hashFile(source);
            
            // Expected output (Kotlin creates .class files from .kt)
            auto className = baseName(source, ".kt") ~ "Kt.class";
            auto classFile = buildPath(outputDir, className);
            
            // Check if this compilation is cached
            if (actionCache.isCached(actionId, [source], metadata))
            {
                // Check if class file exists (might be in subdirectory)
                bool classExists = false;
                if (exists(outputDir))
                {
                    foreach (entry; dirEntries(outputDir, "*.class", SpanMode.depth))
                    {
                        if (entry.name.indexOf(baseName(source, ".kt")) >= 0)
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
            
            // Build compile command for this file
            string[] cmd = ["kotlinc"];
            
            // Add language version
            if (config.languageVersion.major > 0)
                cmd ~= ["-language-version", config.languageVersion.toString()];
            
            // Add API version
            if (config.apiVersion.major > 0)
                cmd ~= ["-api-version", config.apiVersion.toString()];
            
            // Add JVM target
            if (config.platform == KotlinPlatform.JVM)
                cmd ~= ["-jvm-target", config.jvmTarget.toString()];
            
            // Add classpath
            if (!classpaths.empty)
            {
                version(Windows)
                    cmd ~= ["-classpath", classpaths.join(";")];
                else
                    cmd ~= ["-classpath", classpaths.join(":")];
            }
            
            // Add compiler flags
            cmd ~= target.flags;
            cmd ~= config.compilerFlags;
            
            // Enable progressive mode
            if (config.progressive)
                cmd ~= ["-progressive"];
            
            // Enable explicit API mode
            if (config.explicitApi)
                cmd ~= ["-Xexplicit-api=strict"];
            
            // Warnings
            if (config.allWarnings)
                cmd ~= ["-Xall-warnings"];
            if (config.warningsAsErrors)
                cmd ~= ["-Werror"];
            
            // Add source file
            cmd ~= [source];
            
            // Specify output directory
            cmd ~= ["-d", outputDir];
            
            structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ source).emit();
            
            // Execute compilation
            auto res = execute(cmd);
            
            bool success = (res.status == 0);
            
            // Collect output files
            string[] outputs;
            if (success && exists(outputDir))
            {
                foreach (entry; dirEntries(outputDir, "*.class", SpanMode.depth))
                {
                    if (entry.name.indexOf(baseName(source, ".kt")) >= 0)
                        outputs ~= entry.name;
                }
            }
            
            if (!success)
            {
                result.success = false;
                result.error = "Compilation failed for " ~ source ~ ": " ~ res.output;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    [source],
                    [],
                    metadata,
                    false
                );
                
                return result;
            }
            
            // Capture warnings
            if (!res.output.empty)
            {
                result.warnings ~= "In " ~ source ~ ": " ~ res.output;
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
        
        return result;
    }
    
    /// Package class files into JAR with action-level caching
    private KotlinBuildResult packageToJAR(
        string classDir,
        string outputPath,
        const KotlinConfig config,
        const Target target
    )
    {
        KotlinBuildResult result;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["operation"] = "jar-package";
        metadata["includeRuntime"] = config.packaging.includeRuntime.to!string;
        metadata["mainClass"] = config.packaging.mainClass;
        
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
            return result;
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
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Build jar command
        string[] cmd = ["jar", "cf", outputPath];
        
        // Add class files
        cmd ~= ["-C", classDir, "."];
        
        structuredLog.debug_("packaging_jar_").field("detail", "Packaging JAR: " ~ outputPath).emit();
        structuredLog.debug_("__command_").field("detail", "  Command: " ~ cmd.join(" ")).emit();
        
        // Execute jar command
        auto res = execute(cmd);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "JAR packaging failed: " ~ res.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                classFiles,
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        // Update cache with success
        actionCache.update(
            actionId,
            classFiles,
            [outputPath],
            metadata,
            true
        );
        
        return result;
    }
}

