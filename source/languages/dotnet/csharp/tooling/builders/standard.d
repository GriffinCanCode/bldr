module languages.dotnet.csharp.tooling.builders.standard;

import std.stdio;
import std.file;
import std.path;
import std.range;
import std.algorithm;
import std.conv;
import languages.dotnet.csharp.tooling.builders.base;
import languages.dotnet.csharp.tooling.detection;
import languages.dotnet.csharp.managers.dotnet;
import languages.dotnet.csharp.core.config;
import infrastructure.analysis.targets.spec;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;
import engine.runtime.shutdown.shutdown : ShutdownCoordinator;

/// Standard builder using dotnet build with action-level caching
class StandardBuilder : CSharpBuilder
{
    private ActionCache actionCache;
    
    this(ActionCache cache = null)
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/csharp", cacheConfig);
            
            // Note: BuildServices handles cache cleanup via shutdown coordinator
        }
        else
        {
            actionCache = cache;
        }
    }
    
    override BuildResult build(
        in string[] sources,
        in CSharpConfig config,
        in Target target,
        in WorkspaceConfig workspaceConfig
    )
    {
        BuildResult result;
        
        structuredLog.info("building_with_standard_builder").emit();
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["buildTool"] = "dotnet";
        metadata["configuration"] = config.configuration;
        metadata["framework"] = config.framework.to!string;
        metadata["platform"] = config.platformTarget;
        metadata["optimize"] = config.optimize.to!string;
        
        // Collect input files
        string[] inputFiles = sources.dup;
        
        // Add project file if exists
        foreach (csproj; ["*.csproj", target.name ~ ".csproj"])
        {
            auto projFiles = dirEntries(workspaceConfig.root, csproj, SpanMode.shallow, false).array;
            if (!projFiles.empty)
            {
                inputFiles ~= projFiles[0].name;
                break;
            }
        }
        
        // Determine output path
        auto outputDir = config.outputPath.empty ? 
            buildPath(workspaceConfig.options.outputDir, config.configuration) : 
            config.outputPath;
        
        // Create action ID for dotnet build
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = "dotnet-build";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if build is cached
        if (actionCache.isCached(actionId, inputFiles, metadata))
        {
            // Find outputs
            if (exists(outputDir) && isDir(outputDir))
            {
                foreach (entry; dirEntries(outputDir, SpanMode.shallow))
                {
                    if (entry.name.endsWith(".dll") || entry.name.endsWith(".exe"))
                    {
                        result.outputs ~= entry.name;
                    }
                }
            }
            
            if (result.outputs.length > 0)
            {
                structuredLog.debug_("__cached_dotnet_build_").field("detail", "  [Cached] dotnet build: " ~ result.outputs[0]).emit();
                result.success = true;
                result.outputHash = FastHash.hashFile(result.outputs[0]);
                return result;
            }
        }
        
        // Use dotnet build
        bool success = DotNetOps.build(workspaceConfig.root, config);
        
        if (!success)
        {
            result.error = "Build failed";
            
            // Update cache with failure
            actionCache.update(
                actionId,
                inputFiles,
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        // Find outputs
        if (exists(outputDir) && isDir(outputDir))
        {
            // Find DLL or EXE
            foreach (entry; dirEntries(outputDir, SpanMode.shallow))
            {
                if (entry.name.endsWith(".dll") || entry.name.endsWith(".exe"))
                {
                    result.outputs ~= entry.name;
                }
            }
        }
        
        if (result.outputs.length > 0)
        {
            result.success = true;
            result.outputHash = FastHash.hashFile(result.outputs[0]);
            
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
            result.error = "No outputs found";
            
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
    
    override bool isAvailable()
    {
        return DotNetToolDetection.isDotNetAvailable();
    }
    
    override string name()
    {
        return "Standard Builder";
    }
}

