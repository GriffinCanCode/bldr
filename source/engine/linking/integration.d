module engine.linking.integration;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.string;
import engine.linking.incremental;
import engine.caching.actions.action;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Common linking configuration shared across languages
struct LinkingConfig
{
    string[] objectFiles;
    string outputPath;
    string[] libraries;
    string[] libraryPaths;
    string[] systemLibs;
    string[] extraFlags;
    string linkerPath;
    bool useIncrementalLink = true;
    bool debugInfo;
    bool strip;
    bool lto;
}

/// Result from incremental link operation
struct LinkResult
{
    bool success;
    string error;
    string[] warnings;
    bool wasIncremental;
    float reductionPercent;
    string outputHash;
}

/// Cross-language incremental linking helper
/// Integrates with IncrementalLinker for any compiled language
final class IncrementalLinkHelper
{
    private IncrementalLinker linker;
    private ActionCache actionCache;
    private string languageName;
    
    this(string languageName, string cacheDir = null, ActionCache actionCache = null) @system
    {
        this.languageName = languageName;
        auto effectiveCacheDir = cacheDir !is null ? cacheDir : 
            ".builder-cache/linking/" ~ languageName;
        this.linker = new IncrementalLinker(effectiveCacheDir, actionCache);
        this.actionCache = actionCache;
    }
    
    /// Check if incremental linking is available for this platform
    bool isAvailable() const pure nothrow @safe => linker.isIncrementalAvailable();
    
    /// Get the detected linker type
    LinkerType getLinkerType() const pure nothrow @safe => linker.getLinkerConfig().type;
    
    /// Analyze linking needs and return optimal strategy
    LinkAnalysis analyze(in LinkingConfig config) @system
    {
        return linker.analyze(
            config.outputPath,
            config.objectFiles,
            config.libraries,
            config.extraFlags.join(" ")
        );
    }
    
    /// Execute link with incremental optimization
    LinkResult link(in LinkingConfig config, string targetName) @system
    {
        LinkResult result;
        
        if (config.objectFiles.empty)
        {
            result.error = "No object files to link";
            return result;
        }
        
        // Analyze for incremental opportunity
        auto analysis = linker.analyze(
            config.outputPath,
            config.objectFiles,
            config.libraries,
            config.extraFlags.join(" ")
        );
        
        // If fully cached and output exists, skip linking
        if (analysis.objectsToLink.empty && analysis.reductionPercent >= 100.0 && 
            exists(config.outputPath))
        {
            structuredLog.debug_("link_fully_cached")
                .field("output", baseName(config.outputPath))
                .field("language", languageName)
                .emit();
            
            result.success = true;
            result.wasIncremental = false;
            result.reductionPercent = 100.0;
            result.outputHash = FastHash.hashFile(config.outputPath);
            return result;
        }
        
        // Determine linker to use
        string linkerToUse = config.linkerPath;
        if (linkerToUse.empty)
            linkerToUse = linker.getLinkerConfig().path;
        
        if (linkerToUse.empty)
        {
            result.error = "No linker available";
            return result;
        }
        
        // Build link command
        string[] cmd = [linkerToUse];
        auto linkerConfig = linker.getLinkerConfig();
        
        // Add output flag (platform-specific)
        if (linkerConfig.type == LinkerType.MSVC)
            cmd ~= "/OUT:" ~ config.outputPath;
        else
            cmd ~= ["-o", config.outputPath];
        
        // Add incremental flags if beneficial
        bool useIncremental = config.useIncrementalLink && analysis.canIncrementalLink();
        if (useIncremental)
        {
            cmd ~= linker.getLinkerFlags(analysis);
            structuredLog.info("incremental_link_" ~ languageName)
                .field("output", baseName(config.outputPath))
                .field("changed", analysis.changedObjects.length)
                .field("total", config.objectFiles.length)
                .emit();
        }
        
        // Add debug info
        if (config.debugInfo)
        {
            if (linkerConfig.type == LinkerType.MSVC)
                cmd ~= "/DEBUG";
            else
                cmd ~= "-g";
        }
        
        // Add strip
        if (config.strip && !config.debugInfo)
        {
            if (linkerConfig.type != LinkerType.MSVC)
                cmd ~= "-s";
        }
        
        // Add object files
        cmd ~= config.objectFiles.dup;
        
        // Add library paths
        foreach (libPath; config.libraryPaths)
        {
            if (linkerConfig.type == LinkerType.MSVC)
                cmd ~= "/LIBPATH:" ~ libPath;
            else
                cmd ~= "-L" ~ libPath;
        }
        
        // Add libraries
        foreach (lib; config.libraries)
        {
            if (linkerConfig.type == LinkerType.MSVC)
                cmd ~= lib ~ ".lib";
            else
                cmd ~= "-l" ~ lib;
        }
        
        // Add system libraries
        foreach (sysLib; config.systemLibs)
        {
            if (linkerConfig.type != LinkerType.MSVC)
                cmd ~= "-l" ~ sysLib;
        }
        
        // Add extra flags
        cmd ~= config.extraFlags.dup;
        
        structuredLog.debug_("link_command")
            .field("cmd", cmd.join(" "))
            .emit();
        
        // Execute link
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Linking failed: " ~ res.output;
            linker.invalidate(config.outputPath);
            return result;
        }
        
        // Parse warnings
        if (!res.output.empty)
        {
            foreach (line; res.output.lineSplitter)
            {
                auto lowerLine = line.toLower;
                if (lowerLine.canFind("warning"))
                    result.warnings ~= line.strip;
            }
        }
        
        // Record successful link
        linker.recordLink(
            config.outputPath,
            config.objectFiles,
            config.libraries,
            config.extraFlags.join(" "),
            useIncremental
        );
        
        result.success = true;
        result.wasIncremental = useIncremental;
        result.reductionPercent = analysis.reductionPercent;
        
        if (exists(config.outputPath))
            result.outputHash = FastHash.hashFile(config.outputPath);
        
        return result;
    }
    
    /// Invalidate link state for an output
    void invalidate(string outputPath) @system => linker.invalidate(outputPath);
    
    /// Get statistics
    auto getStats() @system => linker.getStats();
}

/// Create standard incremental link helper for common languages
IncrementalLinkHelper createLinkHelper(string language, ActionCache cache = null) @system
{
    return new IncrementalLinkHelper(language, null, cache);
}

/// Helper to add incremental link flags to existing command
string[] addIncrementalFlags(string[] cmd, LinkerType type) pure @safe
{
    auto flags = cmd.dup;
    final switch (type)
    {
        case LinkerType.LLD:
            flags ~= "--incremental";
            break;
        case LinkerType.MSVC:
            flags ~= "/INCREMENTAL";
            break;
        case LinkerType.Gold:
            flags ~= "--incremental";
            break;
        case LinkerType.LD64, LinkerType.Mold, LinkerType.GNU_LD, LinkerType.Unknown:
            break;
    }
    return flags;
}

/// Detect if a command uses a linker with incremental support
bool hasIncrementalSupport(string linkerPath) @system
{
    auto type = IncrementalLinker.detectLinkerType(linkerPath);
    return type == LinkerType.LLD || type == LinkerType.MSVC || type == LinkerType.Gold;
}

