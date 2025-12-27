module engine.caching.incremental.filter;

import std.algorithm;
import std.array;
import std.conv;
import engine.caching.incremental.dependency;
import engine.caching.actions.action;
import infrastructure.utils.logging;

/// Smart file filter for operations (lint, format, analyze)
/// Reuses incremental infrastructure to skip unchanged files
struct IncrementalFilter
{
    private DependencyCache depCache;
    private ActionCache actionCache;
    
    /// Initialize with caches
    static IncrementalFilter create(DependencyCache depCache, ActionCache actionCache) @safe
    {
        IncrementalFilter filter;
        filter.depCache = depCache;
        filter.actionCache = actionCache;
        return filter;
    }
    
    /// Filter files for operation based on changes
    /// Returns: files that actually need processing
    string[] filterFiles(
        string[] allFiles,
        string[] changedFiles,
        ActionType operationType,
        string[string] metadata
    ) @system
    {
        if (changedFiles.empty || depCache is null) return allFiles;
        
        auto affectedFiles = depCache.analyzeChanges(changedFiles).filesToRebuild;
        bool[string] needsProcessing;
        
        foreach (file; allFiles)
        {
            if (affectedFiles.canFind(file))
            {
                needsProcessing[file] = true;
                continue;
            }
            
            if (actionCache !is null)
            {
                import infrastructure.utils.files.hash;
                ActionId actionId = {
                    targetId: "filter",
                    type: operationType,
                    subId: file,
                    inputHash: FastHash.hashFile(file)
                };
                
                if (!actionCache.isCached(actionId, [file], metadata))
                    needsProcessing[file] = true;
            }
            else
            {
                needsProcessing[file] = true;
            }
        }
        
        auto result = needsProcessing.keys;
        
        if (result.length < allFiles.length)
        {
            structuredLog.info("incremental_filter")
                .field("to_process", result.length)
                .field("total", allFiles.length)
                .emit();
        }
        
        return result;
    }
}

