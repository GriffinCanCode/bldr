module languages.jvm.kotlin.tooling.builders.native_;

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
import engine.linking.incremental;

/// Kotlin/Native builder for native executables with incremental linking support
class NativeBuilder : KotlinBuilder
{
    private ActionCache actionCache;
    private IncrementalLinker incLinker;
    private bool useIncrementalLink;
    
    this(ActionCache cache = null, bool enableIncrementalLink = true) @system
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/kotlin-native", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
        
        // Initialize incremental linker (Kotlin/Native uses LLVM -> LLD support)
        incLinker = new IncrementalLinker(".builder-cache/linking/kotlin-native", actionCache);
        useIncrementalLink = enableIncrementalLink && incLinker.isIncrementalAvailable();
        
        if (useIncrementalLink)
            structuredLog.debug_("kotlin_native_incremental_link_enabled")
                .field("linker", incLinker.getLinkerConfig().type.to!string)
                .emit();
    }
    
    override KotlinBuildResult build(
        in string[] sources,
        in KotlinConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        KotlinBuildResult result;
        
        structuredLog.debug_("building_kotlinnative_executable").emit();
        
        // Determine output path
        string outputPath;
        if (!target.outputPath.empty)
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name);
        }
        
        string outputDir = dirName(outputPath);
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["nativeTarget"] = config.native.target;
        metadata["optimization"] = config.native.optimization;
        metadata["staticLink"] = config.native.staticLink.to!string;
        metadata["compilerFlags"] = config.compilerFlags.join(" ");
        metadata["libraries"] = config.native.libraries.join(",");
        
        // Create action ID for compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = baseName(outputPath);
        actionId.inputHash = FastHash.hashStrings(sources);
        
        // Check if compilation is cached
        if (actionCache !is null && actionCache.isCached(actionId, sources, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_kotlin_native_").field("detail", "  [Cached] Kotlin/Native: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Analyze for incremental linking
        auto linkAnalysis = incLinker.analyze(outputPath, sources, config.native.libraries, config.compilerFlags.join(" "));
        bool doIncremental = useIncrementalLink && linkAnalysis.canIncrementalLink();
        
        if (doIncremental)
            structuredLog.info("kotlin_native_incremental_link")
                .field("output", baseName(outputPath))
                .field("changed", linkAnalysis.changedObjects.length)
                .field("total", sources.length)
                .emit();
        
        // Build with kotlin-native compiler
        string[] cmd = ["kotlinc-native"];
        
        // Add target platform
        if (!config.native.target.empty)
            cmd ~= ["-target", config.native.target];
        
        // Optimization
        if (config.native.optimization == "release")
            cmd ~= ["-opt"];
        else if (config.native.optimization == "debug")
            cmd ~= ["-g"];
        
        // Libraries
        foreach (lib; config.native.libraries)
            cmd ~= ["-l", lib];
        
        // Include directories
        foreach (incDir; config.native.includeDirs)
            cmd ~= ["-includedir", incDir];
        
        // Static linking
        if (config.native.staticLink)
            cmd ~= ["-Xstatic-framework"];
        
        // C interop
        if (config.native.cinterop && !config.native.cinteropDef.empty)
            cmd ~= ["-cinterop", config.native.cinteropDef];
        
        // Add incremental linker flags via -Xlinker (Kotlin/Native uses LLVM)
        if (doIncremental)
        {
            auto incFlags = incLinker.getLinkerFlags(linkAnalysis);
            foreach (flag; incFlags)
                cmd ~= ["-Xlinker", flag];
        }
        
        // Compiler flags
        cmd ~= config.compilerFlags;
        
        // Add sources
        cmd ~= sources;
        
        // Output
        cmd ~= ["-o", outputPath];
        
        structuredLog.debug_("executing_").field("detail", "Executing: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "kotlin-native compilation failed: " ~ res.output;
            if (actionCache !is null)
                actionCache.update(actionId, sources, [], metadata, false);
            incLinker.invalidate(outputPath);
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        
        if (exists(outputPath))
            result.outputHash = FastHash.hashFile(outputPath);
        
        // Update caches
        if (actionCache !is null)
            actionCache.update(actionId, sources, [outputPath], metadata, true);
        incLinker.recordLink(outputPath, sources, config.native.libraries, 
                           config.compilerFlags.join(" "), doIncremental);
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto result = execute(["kotlinc-native", "-version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "Native";
    }
    
    override bool supportsMode(KotlinBuildMode mode)
    {
        return mode == KotlinBuildMode.Native;
    }
}

