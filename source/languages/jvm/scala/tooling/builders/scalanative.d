module languages.jvm.scala.tooling.builders.scalanative;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv : to, octal;
import languages.jvm.scala.tooling.builders.base;
import languages.jvm.scala.core.config;
import languages.jvm.scala.tooling.detection;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;
import engine.linking.incremental;

/// Scala Native builder - compiles Scala to native binary via LLVM with incremental linking
class ScalaNativeBuilder : ScalaBuilder
{
    private ActionCache actionCache;
    private IncrementalLinker incLinker;
    private bool useIncrementalLink;
    
    this(ActionCache cache = null, bool enableIncrementalLink = true) @system
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/scala-native", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
        
        // Initialize incremental linker (Scala Native uses LLVM -> LLD support)
        incLinker = new IncrementalLinker(".builder-cache/linking/scala-native", actionCache);
        useIncrementalLink = enableIncrementalLink && incLinker.isIncrementalAvailable();
        
        if (useIncrementalLink)
            structuredLog.debug_("scala_native_incremental_link_enabled")
                .field("linker", incLinker.getLinkerConfig().type.to!string)
                .emit();
    }
    
    override ScalaBuildResult build(
        in string[] sources,
        in ScalaConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        ScalaBuildResult result;
        
        structuredLog.debug_("building_scala_native_target_").field("detail", "Building Scala Native target: " ~ target.name).emit();
        
        // Detect build tool
        ScalaBuildTool buildTool = config.buildTool;
        if (buildTool == ScalaBuildTool.Auto)
            buildTool = ScalaToolDetection.detectBuildTool(workspace.root);
        
        // Use sbt for Scala Native
        if (buildTool == ScalaBuildTool.SBT)
            return buildWithSbt(target, config, workspace, sources, result);
        
        // Use Mill for Scala Native
        if (buildTool == ScalaBuildTool.Mill)
            return buildWithMill(target, config, workspace, sources, result);
        
        result.error = "Scala Native requires sbt or Mill build tool";
        return result;
    }
    
    override bool isAvailable()
    {
        return ScalaToolDetection.isSBTAvailable() || 
               ScalaToolDetection.isMillAvailable();
    }
    
    override string name() const
    {
        return "ScalaNative";
    }
    
    override bool supportsMode(ScalaBuildMode mode)
    {
        return mode == ScalaBuildMode.ScalaNative;
    }
    
    private ScalaBuildResult buildWithSbt(
        const Target target,
        const ScalaConfig config,
        const WorkspaceConfig workspace,
        in string[] sources,
        ScalaBuildResult result
    )
    {
        string outputPath = getOutputPath(target, workspace);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["buildTool"] = "sbt";
        metadata["scalaVersion"] = config.versionInfo.binaryVersion();
        metadata["mode"] = "native";
        
        // Create action ID for compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "sbt-nativeLink";
        actionId.inputHash = FastHash.hashStrings(sources);
        
        // Check if compilation is cached
        if (actionCache !is null && actionCache.isCached(actionId, sources, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_scala_native_sbt_").field("detail", "  [Cached] Scala Native (sbt): " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Analyze for incremental linking
        auto linkAnalysis = incLinker.analyze(outputPath, sources, [], "");
        bool doIncremental = useIncrementalLink && linkAnalysis.canIncrementalLink();
        
        if (doIncremental)
            structuredLog.info("scala_native_incremental_link")
                .field("output", baseName(outputPath))
                .field("changed", linkAnalysis.changedObjects.length)
                .field("total", sources.length)
                .emit();
        
        string[] cmd = ["sbt"];
        
        // Scala Native link task (incremental is handled by sbt-scala-native plugin)
        cmd ~= "nativeLink";
        
        structuredLog.info("running_sbt_nativelink").emit();
        structuredLog.debug_("command_").field("detail", "Command: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, workspace.root);
        
        if (res.status != 0)
        {
            result.error = "Scala Native compilation failed:\n" ~ res.output;
            if (actionCache !is null)
                actionCache.update(actionId, sources, [], metadata, false);
            incLinker.invalidate(outputPath);
            return result;
        }
        
        // Find generated binary
        string targetDir = buildPath(workspace.root, "target", "scala-" ~ config.versionInfo.binaryVersion());
        string binary = findNativeBinary(targetDir);
        
        if (binary.empty)
        {
            result.error = "Could not find generated native binary";
            return result;
        }
        
        // Copy to output location
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        copy(binary, outputPath);
        
        // Make executable on Unix
        version(Posix)
        {
            execute(["chmod", "+x", outputPath]);
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        // Update caches
        if (actionCache !is null)
            actionCache.update(actionId, sources, [outputPath], metadata, true);
        incLinker.recordLink(outputPath, sources, [], "", doIncremental);
        
        return result;
    }
    
    private ScalaBuildResult buildWithMill(
        const Target target,
        const ScalaConfig config,
        const WorkspaceConfig workspace,
        in string[] sources,
        ScalaBuildResult result
    )
    {
        string outputPath = getOutputPath(target, workspace);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["buildTool"] = "mill";
        metadata["scalaVersion"] = config.versionInfo.binaryVersion();
        metadata["mode"] = "native";
        
        // Create action ID for compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "mill-nativeLink";
        actionId.inputHash = FastHash.hashStrings(sources);
        
        // Check if compilation is cached
        if (actionCache !is null && actionCache.isCached(actionId, sources, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_scala_native_mill_").field("detail", "  [Cached] Scala Native (mill): " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Analyze for incremental linking
        auto linkAnalysis = incLinker.analyze(outputPath, sources, [], "");
        bool doIncremental = useIncrementalLink && linkAnalysis.canIncrementalLink();
        
        if (doIncremental)
            structuredLog.info("scala_native_incremental_link")
                .field("output", baseName(outputPath))
                .field("changed", linkAnalysis.changedObjects.length)
                .field("total", sources.length)
                .emit();
        
        string[] cmd = ["mill"];
        
        // Mill Scala Native task
        cmd ~= target.name ~ ".nativeLink";
        
        structuredLog.info("running_mill_nativelink").emit();
        structuredLog.debug_("command_").field("detail", "Command: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, workspace.root);
        
        if (res.status != 0)
        {
            result.error = "Scala Native compilation failed:\n" ~ res.output;
            if (actionCache !is null)
                actionCache.update(actionId, sources, [], metadata, false);
            incLinker.invalidate(outputPath);
            return result;
        }
        
        // Mill output is typically in out/ directory
        string outDir = buildPath(workspace.root, "out");
        string binary = findNativeBinary(outDir);
        
        if (binary.empty)
        {
            result.error = "Could not find generated native binary";
            return result;
        }
        
        // Copy to output location
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        copy(binary, outputPath);
        
        // Make executable on Unix
        version(Posix)
        {
            execute(["chmod", "+x", outputPath]);
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        // Update caches
        if (actionCache !is null)
            actionCache.update(actionId, sources, [outputPath], metadata, true);
        incLinker.recordLink(outputPath, sources, [], "", doIncremental);
        
        return result;
    }
    
    private string findNativeBinary(string searchDir)
    {
        if (!exists(searchDir) || !isDir(searchDir))
            return "";
        
        try
        {
            foreach (entry; dirEntries(searchDir, SpanMode.depth))
            {
                if (entry.isFile)
                {
                    string name = baseName(entry.name);
                    // Look for executable files without extensions or with .out
                    version(Windows)
                    {
                        if (name.endsWith(".exe"))
                            return entry.name;
                    }
                    else
                    {
                        // Check if file is executable
                        auto perms = getAttributes(entry.name);
                        if ((perms & octal!111) != 0) // Check execute bits
                            return entry.name;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("error_searching_for_native_binary_").field("detail", "Error searching for native binary: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    private string getOutputPath(const Target target, const WorkspaceConfig workspace)
    {
        if (!target.outputPath.empty)
            return buildPath(workspace.options.outputDir, target.outputPath);
        
        string name = target.name.split(":")[$ - 1];
        version(Windows)
            name ~= ".exe";
        
        return buildPath(workspace.options.outputDir, name);
    }
}

