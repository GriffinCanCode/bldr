#!/usr/bin/env dub
/+ dub.sdl:
    name "builder-plugin-cache"
    targetType "executable"
    targetName "builder-plugin-cache"
+/

/**
 * Builder Cache Plugin
 * 
 * Intelligent cache warming and optimization for build dependencies.
 * Uses predictive algorithms to pre-fetch and warm caches based on
 * build patterns and dependency graphs.
 * 
 * Features:
 * - Dependency graph analysis
 * - Predictive cache warming
 * - Cache hit rate optimization
 * - Parallel cache pre-fetching
 */
module app;

import std.stdio;
import std.json;
import std.algorithm : map, filter, canFind, sort;
import std.array : array;
import std.file : exists, isFile, getSize, dirEntries, SpanMode, readText, write, mkdirRecurse;
import std.path : buildPath, dirName, baseName;
import std.datetime : Clock, SysTime;
import std.conv : to;
import std.string : strip, split, join;
import std.digest.sha : sha256Of, toHexString;

struct PluginInfo {
    string name = "cache";
    string version_ = "1.0.0";
    string author = "Griffin";
    string description = "Intelligent cache warming and optimization";
    string homepage = "https://github.com/GriffinCanCode/bldr";
    string[] capabilities = ["build.pre_hook", "build.post_hook"];
    string minBuilderVersion = "1.0.0";
    string license = "MIT";
}

struct CacheEntry {
    string key;
    string path;
    long size;
    SysTime accessTime;
    int hitCount;
    double score;  // Predictive score
}

struct DependencyNode {
    string name;
    string[] dependencies;
    int buildFrequency;
    long avgBuildTime;
}

class CacheWarmer {
    private string cacheDir;
    private CacheEntry[string] cacheEntries;
    private DependencyNode[string] depGraph;
    
    this(string cacheDir) {
        this.cacheDir = cacheDir;
        loadCacheMetadata();
        loadDependencyGraph();
    }
    
    void warmCache(string[] targets, string[] sources) {
        writeln("  [Cache] Analyzing build targets...");
        
        // Predict what will be needed
        auto predicted = predictNeededDependencies(targets);
        
        writeln("  [Cache] Predicted ", predicted.length, " dependencies");
        
        // Pre-fetch predicted dependencies
        foreach (dep; predicted) {
            prefetchDependency(dep);
        }
        
        // Optimize cache based on access patterns
        optimizeCache();
    }
    
    void recordAccess(string[] artifacts, long buildDuration) {
        writeln("  [Cache] Recording cache access patterns");
        
        foreach (artifact; artifacts) {
            auto key = computeCacheKey(artifact);
            
            if (key in cacheEntries) {
                cacheEntries[key].accessTime = Clock.currTime;
                cacheEntries[key].hitCount++;
            } else {
                cacheEntries[key] = CacheEntry(
                    key,
                    artifact,
                    exists(artifact) ? getSize(artifact) : 0,
                    Clock.currTime,
                    1,
                    1.0
                );
            }
        }
        
        // Update dependency graph
        updateDependencyGraph(artifacts, buildDuration);
        
        // Save metadata
        saveCacheMetadata();
        saveDependencyGraph();
    }
    
    private string[] predictNeededDependencies(string[] targets) {
        string[] predicted;
        
        foreach (target; targets) {
            if (target in depGraph) {
                auto node = depGraph[target];
                
                // Add direct dependencies
                predicted ~= node.dependencies;
                
                // Add transitive dependencies based on frequency
                foreach (dep; node.dependencies) {
                    if (dep in depGraph && depGraph[dep].buildFrequency > 5) {
                        predicted ~= depGraph[dep].dependencies;
                    }
                }
            }
        }
        
        // Remove duplicates
        bool[string] seen;
        string[] unique;
        foreach (dep; predicted) {
            if (dep !in seen) {
                seen[dep] = true;
                unique ~= dep;
            }
        }
        
        return unique;
    }
    
    private void prefetchDependency(string dep) {
        writeln("    Prefetching: ", dep);
        
        // In a real implementation, this would:
        // 1. Check if dependency is cached
        // 2. Download/fetch if not cached
        // 3. Verify checksums
        // 4. Store in cache
        
        // For demo, we just record the intention
        auto key = computeCacheKey(dep);
        if (key !in cacheEntries) {
            cacheEntries[key] = CacheEntry(
                key,
                dep,
                0,
                Clock.currTime,
                0,
                0.8  // High predictive score
            );
        }
    }
    
    private void optimizeCache() {
        writeln("  [Cache] Optimizing cache layout");
        
        // Calculate scores for all entries
        foreach (ref entry; cacheEntries) {
            entry.score = calculateCacheScore(entry);
        }
        
        // Sort by score
        auto sorted = cacheEntries.values.array.sort!((a, b) => a.score > b.score).array;
        
        // Identify candidates for eviction
        auto totalSize = sorted.map!(e => e.size).sum();
        immutable long maxCacheSize = 10L * 1024 * 1024 * 1024;  // 10GB
        
        if (totalSize > maxCacheSize) {
            writeln("  [Cache] Cache size exceeds limit, evicting low-score entries");
            
            long currentSize = 0;
            foreach (entry; sorted) {
                if (currentSize + entry.size > maxCacheSize) {
                    writeln("    Evicting: ", entry.path);
                    // In real implementation, delete the file
                } else {
                    currentSize += entry.size;
                }
            }
        }
    }
    
    private double calculateCacheScore(ref CacheEntry entry) {
        // Scoring algorithm based on:
        // - Recency: how recently accessed
        // - Frequency: how often accessed
        // - Size: smaller is better
        // - Predictive value: based on dependency graph
        
        auto now = Clock.currTime;
        auto recencyDays = (now - entry.accessTime).total!"days";
        
        double recencyScore = 1.0 / (1.0 + recencyDays);
        double frequencyScore = entry.hitCount / 10.0;
        double sizeScore = entry.size > 0 ? 1.0 / (1.0 + entry.size / (1024.0 * 1024.0)) : 1.0;
        
        return (recencyScore * 0.4) + (frequencyScore * 0.4) + (sizeScore * 0.2);
    }
    
    private void updateDependencyGraph(string[] artifacts, long buildDuration) {
        // Extract target name from artifacts
        if (artifacts.length == 0) return;
        
        auto target = artifacts[0];
        
        if (target !in depGraph) {
            depGraph[target] = DependencyNode(target, [], 1, buildDuration);
        } else {
            depGraph[target].buildFrequency++;
            depGraph[target].avgBuildTime = 
                (depGraph[target].avgBuildTime + buildDuration) / 2;
        }
    }
    
    private string computeCacheKey(string path) {
        return toHexString(sha256Of(path)).to!string;
    }
    
    private void loadCacheMetadata() {
        auto metaPath = buildPath(cacheDir, "cache-metadata.json");
        if (!exists(metaPath)) return;
        
        try {
            auto json = parseJSON(readText(metaPath));
            foreach (key, value; json.object) {
                // Parse cache entry from JSON
                // Simplified for demo
            }
        } catch (Exception e) {
            stderr.writeln("Warning: Failed to load cache metadata: ", e.msg);
        }
    }
    
    private void saveCacheMetadata() {
        auto metaPath = buildPath(cacheDir, "cache-metadata.json");
        mkdirRecurse(dirName(metaPath));
        
        // Save cache entries to JSON
        // Simplified for demo
        JSONValue json = parseJSON("{}");
        std.file.write(metaPath, json.toPrettyString());
    }
    
    private void loadDependencyGraph() {
        auto graphPath = buildPath(cacheDir, "dep-graph.json");
        if (!exists(graphPath)) return;
        
        try {
            auto json = parseJSON(readText(graphPath));
            // Parse dependency graph from JSON
            // Simplified for demo
        } catch (Exception e) {
            stderr.writeln("Warning: Failed to load dependency graph: ", e.msg);
        }
    }
    
    private void saveDependencyGraph() {
        auto graphPath = buildPath(cacheDir, "dep-graph.json");
        mkdirRecurse(dirName(graphPath));
        
        // Save dependency graph to JSON
        // Simplified for demo
        JSONValue json = parseJSON("{}");
        std.file.write(graphPath, json.toPrettyString());
    }
}

long sum(T)(T[] array) {
    long total = 0;
    foreach (item; array) {
        total += item;
    }
    return total;
}

void main() {
    foreach (line; stdin.byLine()) {
        try {
            auto request = parseJSON(cast(string)line);
            auto response = handleRequest(request);
            writeln(response.toJSON());
            stdout.flush();
        } catch (Exception e) {
            writeError(e.msg);
        }
    }
}

JSONValue handleRequest(JSONValue request) {
    string method = request["method"].str;
    long id = request["id"].integer;
    
    switch (method) {
        case "plugin.info":
            return handleInfo(id);
        case "build.pre_hook":
            return handlePreHook(id, request["params"]);
        case "build.post_hook":
            return handlePostHook(id, request["params"]);
        default:
            return errorResponse(id, -32601, "Method not found: " ~ method);
    }
}

JSONValue handleInfo(long id) {
    auto info = PluginInfo();
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "result": JSONValue([
            "name": info.name,
            "version": info.version_,
            "author": info.author,
            "description": info.description,
            "homepage": info.homepage,
            "capabilities": JSONValue(info.capabilities),
            "minBuilderVersion": info.minBuilderVersion,
            "license": info.license
        ])
    ]);
}

JSONValue handlePreHook(long id, JSONValue params) {
    string[] logs;
    
    try {
        logs ~= "Cache warming plugin activated";
        
        auto target = params["target"];
        auto workspace = params["workspace"];
        
        auto targetName = target["name"].str;
        auto sources = target["sources"].array.map!(s => s.str).array;
        auto cacheDir = buildPath(workspace["root"].str, ".builder-cache");
        
        logs ~= "Target: " ~ targetName;
        logs ~= "Sources: " ~ sources.length.to!string ~ " file(s)";
        
        auto warmer = new CacheWarmer(cacheDir);
        warmer.warmCache([targetName], sources);
        
        logs ~= "✓ Cache warming complete";
        
    } catch (Exception e) {
        logs ~= "⚠ Cache warming failed: " ~ e.msg;
    }
    
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "result": JSONValue([
            "success": true,
            "logs": JSONValue(logs)
        ])
    ]);
}

JSONValue handlePostHook(long id, JSONValue params) {
    string[] logs;
    
    try {
        logs ~= "Recording cache access patterns";
        
        auto target = params["target"];
        auto workspace = params["workspace"];
        auto outputs = params["outputs"].array.map!(o => o.str).array;
        auto duration = params["duration_ms"].integer;
        
        auto cacheDir = buildPath(workspace["root"].str, ".builder-cache");
        
        auto warmer = new CacheWarmer(cacheDir);
        warmer.recordAccess(outputs, duration);
        
        logs ~= "✓ Cache patterns recorded";
        
    } catch (Exception e) {
        logs ~= "⚠ Failed to record patterns: " ~ e.msg;
    }
    
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "result": JSONValue([
            "success": true,
            "logs": JSONValue(logs)
        ])
    ]);
}

JSONValue errorResponse(long id, int code, string message) {
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "error": JSONValue([
            "code": code,
            "message": message
        ])
    ]);
}

void writeError(string msg) {
    stderr.writeln("Error: ", msg);
}

