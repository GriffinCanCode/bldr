module engine.caching.targets.discovery;

import std.stdio;
import std.file : exists, mkdir, mkdirRecurse, readText, isFile, write;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import std.datetime;
import engine.graph;
import infrastructure.config.schema.schema : TargetId;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Discovery cache - caches discovery results for fast incremental builds
/// Allows skipping discovery phase if inputs haven't changed
final class DiscoveryCache
{
    private string cacheDir;
    private DiscoveryCacheEntry[string] entries; // Keyed by target ID
    private bool dirty;
    
    this(string cacheDir = ".builder-cache") @system
    {
        this.cacheDir = cacheDir;
        ensureCacheDir();
        load();
    }
    
    /// Cache discovery result for a target
    void cacheDiscovery(
        string targetId,
        string[] inputHashes,
        DiscoveryMetadata discovery
    ) @system
    {
        DiscoveryCacheEntry entry;
        entry.targetId = targetId;
        entry.inputHashes = inputHashes;
        entry.discovery = discovery;
        entry.timestamp = Clock.currTime;
        
        entries[targetId] = entry;
        dirty = true;
    }
    
    /// Check if discovery is cached and valid
    bool isCached(string targetId, string[] currentInputHashes) @system
    {
        if (targetId !in entries)
            return false;
        
        auto entry = entries[targetId];
        
        // Check if inputs match
        if (entry.inputHashes.length != currentInputHashes.length)
            return false;
        
        foreach (i, hash; currentInputHashes)
        {
            if (i >= entry.inputHashes.length || hash != entry.inputHashes[i])
                return false;
        }
        
        return true;
    }
    
    /// Get cached discovery result
    Result!(DiscoveryMetadata, string) getCached(string targetId) @system
    {
        if (targetId !in entries)
            return Result!(DiscoveryMetadata, string).err("Not cached");
        
        return Result!(DiscoveryMetadata, string).ok(entries[targetId].discovery);
    }
    
    /// Flush cache to disk
    void flush() @system
    {
        if (!dirty)
            return;
        
        try
        {
            auto cacheFile = buildPath(cacheDir, "discovery-cache.json");
            auto json = serializeToJson();
            write(cacheFile, json.toPrettyString());
            
            // Also save discovery history
            saveHistory();
            
            dirty = false;
            structuredLog.debug_("discovery_cache_flushed").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("discovery_cache_flush_failed").field("error", e.msg).emit();
        }
    }
    
    /// Clear cache
    void clear() @system
    {
        entries.clear();
        dirty = true;
        flush();
    }
    
    /// Get cache statistics
    struct Stats
    {
        size_t totalEntries;
        size_t totalDiscoveries;
        size_t totalTargetsDiscovered;
    }
    
    Stats getStats() const @system
    {
        Stats stats;
        stats.totalEntries = entries.length;
        
        foreach (entry; entries.values)
        {
            stats.totalDiscoveries++;
            stats.totalTargetsDiscovered += entry.discovery.newTargets.length;
        }
        
        return stats;
    }
    
    private void ensureCacheDir() @system
    {
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
    }
    
    private void load() @system
    {
        auto cacheFile = buildPath(cacheDir, "discovery-cache.json");
        if (!exists(cacheFile))
            return;
        
        try
        {
            auto jsonContent = readText(cacheFile);
            auto json = parseJSON(jsonContent);
            deserializeFromJson(json);
            
            structuredLog.debug_("discovery_cache_loaded").field("entries", entries.length).emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("discovery_cache_load_failed").field("error", e.msg).emit();
        }
    }
    
    private JSONValue serializeToJson() @system
    {
        JSONValue json = JSONValue.emptyObject;
        JSONValue[] entriesJson;
        
        foreach (entry; entries.values)
        {
            JSONValue entryJson = JSONValue.emptyObject;
            entryJson["targetId"] = entry.targetId;
            entryJson["inputHashes"] = JSONValue(entry.inputHashes);
            entryJson["timestamp"] = entry.timestamp.toISOExtString();
            
            // Serialize discovery metadata
            JSONValue discoveryJson = JSONValue.emptyObject;
            discoveryJson["originTarget"] = entry.discovery.originTarget.toString();
            discoveryJson["discoveredOutputs"] = JSONValue(entry.discovery.discoveredOutputs);
            
            JSONValue[] dependentsJson;
            foreach (dep; entry.discovery.discoveredDependents)
            {
                dependentsJson ~= JSONValue(dep.toString());
            }
            discoveryJson["discoveredDependents"] = JSONValue(dependentsJson);
            
            // Simplified: Don't serialize full targets (too complex)
            discoveryJson["newTargetsCount"] = entry.discovery.newTargets.length;
            
            discoveryJson["metadata"] = JSONValue(entry.discovery.metadata);
            
            entryJson["discovery"] = discoveryJson;
            entriesJson ~= entryJson;
        }
        
        json["entries"] = JSONValue(entriesJson);
        json["version"] = "1.0";
        
        return json;
    }
    
    private void deserializeFromJson(JSONValue json) @system
    {
        entries.clear();
        
        if ("entries" !in json)
            return;
        
        foreach (entryJson; json["entries"].array)
        {
            DiscoveryCacheEntry entry;
            entry.targetId = entryJson["targetId"].str;
            
            foreach (hash; entryJson["inputHashes"].array)
            {
                entry.inputHashes ~= hash.str;
            }
            
            entry.timestamp = SysTime.fromISOExtString(entryJson["timestamp"].str);
            
            // Deserialize discovery (partial - targets not included)
            auto discoveryJson = entryJson["discovery"];
            entry.discovery.originTarget = TargetId(discoveryJson["originTarget"].str);
            
            foreach (output; discoveryJson["discoveredOutputs"].array)
            {
                entry.discovery.discoveredOutputs ~= output.str;
            }
            
            foreach (dep; discoveryJson["discoveredDependents"].array)
            {
                entry.discovery.discoveredDependents ~= TargetId(dep.str);
            }
            
            foreach (key, value; discoveryJson["metadata"].object)
            {
                entry.discovery.metadata[key] = value.str;
            }
            
            entries[entry.targetId] = entry;
        }
    }
    
    private void saveHistory() @system
    {
        try
        {
            auto historyFile = buildPath(cacheDir, "discovery-history.json");
            
            // Load existing history
            JSONValue history;
            if (exists(historyFile))
            {
                history = parseJSON(readText(historyFile));
            }
            else
            {
                history = JSONValue.emptyObject;
                history["discoveries"] = JSONValue.emptyArray;
            }
            
            // Append new discoveries
            foreach (entry; entries.values)
            {
                JSONValue discoveryRecord = JSONValue.emptyObject;
                discoveryRecord["origin"] = entry.targetId;
                discoveryRecord["timestamp"] = entry.timestamp.toISOExtString();
                discoveryRecord["outputs"] = JSONValue(entry.discovery.discoveredOutputs);
                
                JSONValue[] targetsJson;
                foreach (target; entry.discovery.newTargets)
                {
                    targetsJson ~= JSONValue(target.name);
                }
                discoveryRecord["newTargets"] = JSONValue(targetsJson);
                discoveryRecord["metadata"] = JSONValue(entry.discovery.metadata);
                
                history["discoveries"].array ~= discoveryRecord;
            }
            
            // Limit history size
            if (history["discoveries"].array.length > 100)
            {
                history["discoveries"].array = history["discoveries"].array[$-100..$];
            }
            
            write(historyFile, history.toPrettyString());
        }
        catch (Exception e)
        {
            structuredLog.warning("discovery_history_save_failed").field("error", e.msg).emit();
        }
    }
}

/// Discovery cache entry
private struct DiscoveryCacheEntry
{
    string targetId;
    string[] inputHashes;
    DiscoveryMetadata discovery;
    SysTime timestamp;
}


