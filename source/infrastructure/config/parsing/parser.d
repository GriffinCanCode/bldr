module infrastructure.config.parsing.parser;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import std.datetime : Clock;
import infrastructure.config.analysis.semantic;
import infrastructure.config.workspace.workspace;
import infrastructure.config.schema.schema;
import infrastructure.config.caching.parse;
import infrastructure.config.caching.sqlite;
import infrastructure.analysis.detection.inference;
import infrastructure.utils.logging.logger;
import infrastructure.utils.files.hash;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// High-level configuration parser
/// Wraps the unified parser and provides workspace-level parsing

class ConfigParser
{
    private static ConfigIndex _configIndex;
    
    /// Get or create the shared config index (lazy initialization)
    private static ConfigIndex getConfigIndex(string cacheDir) @system
    {
        if (_configIndex is null)
            _configIndex = new ConfigIndex(cacheDir);
        return _configIndex;
    }
    
    /// Close the config index (call during cleanup)
    static void closeConfigIndex() @system
    {
        if (_configIndex !is null)
        {
            _configIndex.close();
            _configIndex = null;
        }
    }
    
    /// Parse entire workspace starting from root
    /// Uses SQLite-backed ConfigIndex for sub-millisecond cache lookups
    /// Returns Result with WorkspaceConfig
    static BuildResult!WorkspaceConfig parseWorkspace(
        in string root,
        in AggregationPolicy policy = AggregationPolicy.CollectAll) @system
    {
        immutable cacheDir = buildPath(root, ".builder-cache");
        immutable workspacePath = absolutePath(root);
        
        WorkspaceConfig config;
        config.root = workspacePath;
        
        // Find all Builderfile files
        auto buildFiles = findBuildFiles(root);
        
        // Try SQLite cache first for fast lookup
        if (!buildFiles.empty)
        {
            auto cachedConfig = tryLoadFromCache(workspacePath, buildFiles, cacheDir);
            if (cachedConfig !is null)
            {
                Logger.success("Loaded configuration from cache (<1ms)");
                return Ok!(WorkspaceConfig, BuildError)(*cachedConfig);
            }
        }
        
        // Zero-config mode: infer targets if no Builderfiles found
        if (buildFiles.empty)
        {
            Logger.info("═══════════════════════════════════════════");
            Logger.info("  MODE: Zero-Config (No Builderfile found)");
            Logger.info("═══════════════════════════════════════════");
            Logger.info("Attempting automatic target inference...");
            
            try
            {
                auto inference = new TargetInference(root);
                config.targets = inference.inferTargets();
                
                if (config.targets.empty)
                {
                    auto error = createParseError(
                        root,
                        "No Builderfile found and no build targets could be automatically inferred",
                        ErrorCode.InvalidConfiguration
                    );
                    error.addSuggestion(ErrorSuggestion.command("Create a Builderfile", "bldr init"));
                    error.addSuggestion(ErrorSuggestion.docs("See zero-config mode", "docs/user-guides/examples.md"));
                    return Err!(WorkspaceConfig, BuildError)(error);
                }
                
                Logger.success("Zero-config mode: inferred " ~ 
                    config.targets.length.to!string ~ " target(s)");
            }
            catch (Exception e)
            {
                auto error = createParseError(
                    root,
                    "Failed to automatically infer build targets: " ~ e.msg,
                    ErrorCode.AnalysisFailed
                );
                error.addSuggestion(ErrorSuggestion.command("Create a Builderfile manually", "bldr init"));
                error.addSuggestion(ErrorSuggestion.command("Run with verbose output", "bldr build --verbose"));
                error.addContext(ErrorContext("auto-inference", e.msg));
                return Err!(WorkspaceConfig, BuildError)(error);
            }
        }
        else
        {
            Logger.info("═══════════════════════════════════════════");
            Logger.info("  MODE: Builderfile (" ~ buildFiles.length.to!string ~ " file(s) found)");
            Logger.info("═══════════════════════════════════════════");
            
            // Create parse cache
            auto cache = new ParseCache(true, buildPath(root, ".builder-cache/parse"));
            
            // Parse each Builderfile with error aggregation
            auto aggregated = aggregateMap(
                buildFiles,
                (string buildFile) => parseBuildFile(buildFile, root, cache),
                policy
            );
            
            // Log results
            if (aggregated.hasErrors)
            {
                Logger.warning(
                    "Failed to parse " ~ aggregated.errors.length.to!string ~
                    " Builderfile file(s)"
                );
                
                import infrastructure.errors.formatting.format : format;
                foreach (error; aggregated.errors)
                {
                    Logger.error(format(error));
                }
            }
            
            if (aggregated.hasSuccesses)
            {
                foreach (result; aggregated.successes)
                {
                    config.targets ~= result.targets;
                    config.repositories ~= result.repositories;
                }
                
                Logger.success(
                    "Successfully parsed " ~ config.targets.length.to!string ~
                    " target(s) from " ~ buildFiles.length.to!string ~ " Builderfile file(s)"
                );
                
                if (config.repositories.length > 0)
                {
                    Logger.info("Found " ~ config.repositories.length.to!string ~ " repository rule(s)");
                }
            }
            
            // Flush parse cache
            if (cache !is null)
                cache.close();
            
            if (policy == AggregationPolicy.FailFast && aggregated.hasErrors)
                return Err!(WorkspaceConfig, BuildError)(aggregated.errors[0]);
            
            if (!aggregated.hasSuccesses && aggregated.hasErrors)
                return Err!(WorkspaceConfig, BuildError)(aggregated.errors[0]);
        }
        
        // Load workspace config if exists
        string workspaceFile = buildPath(root, "Builderspace");
        if (exists(workspaceFile))
        {
            auto wsResult = parseWorkspaceFile(workspaceFile, config);
            if (wsResult.isErr)
            {
                auto error = wsResult.unwrapErr();
                Logger.error("Failed to parse Builderspace file");
                import infrastructure.errors.formatting.format : format;
                Logger.error(format(error));
                
                if (policy == AggregationPolicy.FailFast)
                    return Err!(WorkspaceConfig, BuildError)(error);
            }
        }
        
        // Save to SQLite cache for future sub-millisecond lookups
        if (!buildFiles.empty)
            saveToCache(workspacePath, buildFiles, config, cacheDir);
        
        return Ok!(WorkspaceConfig, BuildError)(config);
    }
    
    /// Try to load config from SQLite cache with validation
    private static WorkspaceConfig* tryLoadFromCache(
        string workspacePath,
        string[] buildFiles,
        string cacheDir) @system
    {
        try
        {
            auto configIndex = getConfigIndex(cacheDir);
            
            // Check if we have a cached entry
            auto cacheResult = configIndex.getConfig(workspacePath);
            if (cacheResult.isErr)
                return null;
            
            auto entry = cacheResult.unwrap();
            
            // Validate content hash (files haven't changed)
            immutable currentHash = computeConfigHash(buildFiles);
            if (entry.contentHash != currentHash)
            {
                Logger.debugLog("Config cache invalidated: content hash mismatch");
                configIndex.deleteConfig(workspacePath);
                return null;
            }
            
            // Deserialize cached config
            auto config = deserializeConfig(entry.configData);
            if (config is null)
                return null;
            
            return config;
        }
        catch (Exception e)
        {
            Logger.debugLog("Config cache lookup failed: " ~ e.msg);
            return null;
        }
    }
    
    /// Save config to SQLite cache
    private static void saveToCache(
        string workspacePath,
        string[] buildFiles,
        ref WorkspaceConfig config,
        string cacheDir) @system
    {
        try
        {
            auto configIndex = getConfigIndex(cacheDir);
            
            ConfigEntry entry;
            entry.workspacePath = workspacePath;
            entry.contentHash = computeConfigHash(buildFiles);
            entry.metadataHash = computeMetadataHash(buildFiles);
            entry.targetCount = cast(int)config.targets.length;
            entry.configData = serializeConfig(config);
            entry.createdAt = Clock.currTime();
            
            configIndex.putConfig(entry);
            
            // Also cache individual targets for fast lookup
            TargetEntry[] targetEntries;
            foreach (ref target; config.targets)
            {
                TargetEntry te;
                te.targetId = target.name;
                te.workspacePath = workspacePath;
                te.name = target.name;
                te.targetType = target.type;
                te.language = target.language;
                te.outputPath = target.outputPath;
                te.depCount = cast(int)target.deps.length;
                te.targetData = serializeTarget(target);
                targetEntries ~= te;
            }
            
            if (targetEntries.length > 0)
                configIndex.putTargetsBatch(targetEntries);
            
            Logger.debugLog("Saved " ~ config.targets.length.to!string ~ " targets to config cache");
        }
        catch (Exception e)
        {
            Logger.debugLog("Config cache save failed: " ~ e.msg);
        }
    }
    
    /// Compute BLAKE3 hash of all config files
    private static string computeConfigHash(string[] buildFiles) @system
    {
        import std.digest : toHexString;
        
        // Hash all file contents together
        ubyte[][string] fileHashes;
        foreach (file; buildFiles)
        {
            if (exists(file))
                fileHashes[file] = cast(ubyte[])FastHash.hashFile(file);
        }
        
        // Sort by filename for deterministic ordering
        auto sortedKeys = fileHashes.keys.dup.sort();
        string combined;
        foreach (key; sortedKeys)
            combined ~= cast(string)fileHashes[key];
        
        return FastHash.hashString(combined);
    }
    
    /// Compute fast metadata hash (sizes + mtimes)
    private static string computeMetadataHash(string[] buildFiles) @system
    {
        string metadata;
        foreach (file; buildFiles)
        {
            if (exists(file))
                metadata ~= FastHash.hashMetadata(file);
        }
        return FastHash.hashString(metadata);
    }
    
    /// Serialize WorkspaceConfig to bytes
    private static ubyte[] serializeConfig(ref WorkspaceConfig config) @system
    {
        import std.bitmanip : nativeToBigEndian;
        import std.array : appender;
        
        auto buffer = appender!(ubyte[]);
        buffer.reserve(4096);
        
        // Version byte
        buffer.put(cast(ubyte)1);
        
        // Root path
        buffer.put(nativeToBigEndian(cast(uint)config.root.length)[]);
        buffer.put(cast(const(ubyte)[])config.root);
        
        // Target count
        buffer.put(nativeToBigEndian(cast(uint)config.targets.length)[]);
        
        // Serialize each target
        foreach (ref target; config.targets)
            buffer.put(serializeTarget(target));
        
        return buffer.data;
    }
    
    /// Serialize single Target to bytes
    private static ubyte[] serializeTarget(ref Target target) @system
    {
        import std.bitmanip : nativeToBigEndian;
        import std.array : appender;
        
        auto buffer = appender!(ubyte[]);
        
        // Name
        buffer.put(nativeToBigEndian(cast(uint)target.name.length)[]);
        buffer.put(cast(const(ubyte)[])target.name);
        
        // Type and language
        buffer.put(cast(ubyte)target.type);
        buffer.put(cast(ubyte)target.language);
        
        // Sources
        buffer.put(nativeToBigEndian(cast(uint)target.sources.length)[]);
        foreach (src; target.sources)
        {
            buffer.put(nativeToBigEndian(cast(uint)src.length)[]);
            buffer.put(cast(const(ubyte)[])src);
        }
        
        // Deps
        buffer.put(nativeToBigEndian(cast(uint)target.deps.length)[]);
        foreach (dep; target.deps)
        {
            buffer.put(nativeToBigEndian(cast(uint)dep.length)[]);
            buffer.put(cast(const(ubyte)[])dep);
        }
        
        // Output path
        buffer.put(nativeToBigEndian(cast(uint)target.outputPath.length)[]);
        buffer.put(cast(const(ubyte)[])target.outputPath);
        
        return buffer.data;
    }
    
    /// Deserialize WorkspaceConfig from bytes
    private static WorkspaceConfig* deserializeConfig(ubyte[] data) @system
    {
        import std.bitmanip : bigEndianToNative;
        
        if (data.length < 5)
            return null;
        
        try
        {
            size_t offset = 0;
            
            // Version check
            ubyte ver = data[offset++];
            if (ver != 1)
                return null;
            
            auto config = new WorkspaceConfig;
            
            // Root path
            ubyte[4] rootLenBytes = data[offset .. offset + 4];
            offset += 4;
            uint rootLen = bigEndianToNative!uint(rootLenBytes);
            config.root = cast(string)data[offset .. offset + rootLen].idup;
            offset += rootLen;
            
            // Target count
            ubyte[4] countBytes = data[offset .. offset + 4];
            offset += 4;
            uint targetCount = bigEndianToNative!uint(countBytes);
            
            // Deserialize targets
            foreach (_; 0 .. targetCount)
            {
                Target target;
                offset = deserializeTarget(data, offset, target);
                config.targets ~= target;
            }
            
            return config;
        }
        catch (Exception)
        {
            return null;
        }
    }
    
    /// Deserialize single Target from bytes
    private static size_t deserializeTarget(ubyte[] data, size_t offset, ref Target target) @system
    {
        import std.bitmanip : bigEndianToNative;
        
        // Name
        ubyte[4] nameLenBytes = data[offset .. offset + 4];
        offset += 4;
        uint nameLen = bigEndianToNative!uint(nameLenBytes);
        target.name = cast(string)data[offset .. offset + nameLen].idup;
        offset += nameLen;
        
        // Type and language
        target.type = cast(TargetType)data[offset++];
        target.language = cast(TargetLanguage)data[offset++];
        
        // Sources
        ubyte[4] srcCountBytes = data[offset .. offset + 4];
        offset += 4;
        uint srcCount = bigEndianToNative!uint(srcCountBytes);
        foreach (_; 0 .. srcCount)
        {
            ubyte[4] srcLenBytes = data[offset .. offset + 4];
            offset += 4;
            uint srcLen = bigEndianToNative!uint(srcLenBytes);
            target.sources ~= cast(string)data[offset .. offset + srcLen].idup;
            offset += srcLen;
        }
        
        // Deps
        ubyte[4] depCountBytes = data[offset .. offset + 4];
        offset += 4;
        uint depCount = bigEndianToNative!uint(depCountBytes);
        foreach (_; 0 .. depCount)
        {
            ubyte[4] depLenBytes = data[offset .. offset + 4];
            offset += 4;
            uint depLen = bigEndianToNative!uint(depLenBytes);
            target.deps ~= cast(string)data[offset .. offset + depLen].idup;
            offset += depLen;
        }
        
        // Output path
        ubyte[4] outLenBytes = data[offset .. offset + 4];
        offset += 4;
        uint outLen = bigEndianToNative!uint(outLenBytes);
        target.outputPath = cast(string)data[offset .. offset + outLen].idup;
        offset += outLen;
        
        return offset;
    }
    
    /// Find all Builderfile files in directory tree
    private static string[] findBuildFiles(string root)
    {
        string[] buildFiles;
        
        if (!exists(root) || !isDir(root))
            return buildFiles;
        
        foreach (entry; dirEntries(root, SpanMode.depth))
        {
            import infrastructure.utils.security.validation;
            if (!SecurityValidator.isPathWithinBase(entry.name, root))
                continue;
            
            if (entry.isFile && entry.name.baseName == "Builderfile")
                buildFiles ~= entry.name;
        }
        
        return buildFiles;
    }
    
    /// Parse a single Builderfile file
    private static BuildResult!ParseResult parseBuildFile(
        string path, 
        string root,
        ParseCache cache) @system
    {
        try
        {
            auto content = readText(path);
            return parseDSL(content, path, root);
        }
        catch (FileException e)
        {
            auto error = fileReadError(path, e.msg, "reading Builderfile");
            return Err!(ParseResult, BuildError)(error);
        }
        catch (Exception e)
        {
            auto error = parseErrorWithContext(path, 
                "Failed to parse Builderfile: " ~ e.msg, 0, 0, "parsing Builderfile file");
            return Err!(ParseResult, BuildError)(error);
        }
    }
    
    /// Parse workspace-level configuration
    private static VoidBuildResult parseWorkspaceFile(string path, ref WorkspaceConfig config) @system
    {
        try
        {
            auto content = readText(path);
            // Future: Migrate to unified parser for workspace files
            // For now, just succeed
            return VoidBuildResult.ok();
        }
        catch (FileException e)
        {
            auto error = fileReadError(path, e.msg, "reading Builderspace file");
            return VoidBuildResult.err(error);
        }
        catch (Exception e)
        {
            auto error = parseErrorWithContext(path, 
                "Failed to parse Builderspace file: " ~ e.msg, 0, 0, "parsing Builderspace file");
            return VoidBuildResult.err(error);
        }
    }
}
