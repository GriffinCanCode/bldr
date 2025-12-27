module engine.linking.incremental;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.file;
import std.path;
import std.process;
import std.string;
import core.sync.mutex;
import infrastructure.toolchain.core.platform;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.errors;
import engine.caching.actions.action;

/// Linker types with incremental linking support
enum LinkerType
{
    Unknown,
    LLD,        // LLVM linker (ld.lld) - supports --incremental
    GNU_LD,     // GNU ld - limited incremental support
    MSVC,       // Microsoft link.exe - supports /INCREMENTAL
    LD64,       // Apple ld64 - limited support
    Mold,       // Modern fast linker
    Gold        // GNU gold linker
}

/// Incremental linking strategy
enum LinkStrategy
{
    Full,           // Full re-link (all objects)
    Incremental,    // Incremental link (changed objects only)
    Delta           // Delta linking (only changed sections)
}

/// Object file state for tracking changes
struct ObjectState
{
    string path;
    string hash;
    SysTime mtime;
    ulong size;
    string[] symbols;  // Exported symbols (for dependency tracking)
}

/// Link session state - persisted between builds
struct LinkState
{
    string outputPath;
    string outputHash;
    ObjectState[] objects;
    string[] libraries;
    string linkerFlags;
    SysTime timestamp;
    LinkerType linkerType;
    bool incrementalEnabled;
    
    /// Check if object set has changed
    bool hasChanges(scope const(string)[] currentObjects) const @system
    {
        if (currentObjects.length != objects.length) return true;
        
        auto currentSet = currentObjects.map!(o => buildNormalizedPath(o)).array.sort.array;
        auto storedSet = objects.map!(o => buildNormalizedPath(o.path)).array.sort.array;
        
        return currentSet != storedSet;
    }
    
    /// Get changed objects (for incremental re-link)
    string[] getChangedObjects(scope const(string)[] currentObjects) const @system
    {
        string[] changed;
        
        // Build lookup map from stored objects
        string[string] storedHashes;
        foreach (ref obj; objects)
            storedHashes[buildNormalizedPath(obj.path)] = obj.hash;
        
        foreach (objPath; currentObjects)
        {
            auto normalized = buildNormalizedPath(objPath);
            if (!exists(objPath)) continue;
            
            auto storedHash = normalized in storedHashes;
            if (storedHash is null)
            {
                changed ~= objPath;  // New object
                continue;
            }
            
            // Check if content changed
            auto currentHash = FastHash.hashFile(objPath);
            if (currentHash != *storedHash)
                changed ~= objPath;
        }
        
        return changed;
    }
}

/// Result of incremental link analysis
struct LinkAnalysis
{
    LinkStrategy strategy;
    string[] objectsToLink;       // Objects that need linking
    string[] cachedObjects;       // Objects that can use cached state
    string[] changedObjects;      // Objects that changed since last link
    string[] removedObjects;      // Objects removed since last link
    string[] addedObjects;        // New objects since last link
    float reductionPercent;       // Percentage of objects skipped
    string reason;                // Reason for chosen strategy
    
    bool canIncrementalLink() const pure nothrow => 
        strategy == LinkStrategy.Incremental || strategy == LinkStrategy.Delta;
}

/// Platform-specific linker configuration
struct LinkerConfig
{
    LinkerType type = LinkerType.Unknown;
    string path;
    string version_;
    bool supportsIncremental;
    bool supportsThinLTO;
    bool supportsLTO;
    string[] defaultFlags;
    
    /// Get incremental linking flags for this linker
    string[] getIncrementalFlags() const pure nothrow @safe
    {
        final switch (type)
        {
            case LinkerType.LLD:
                // LLD supports --incremental (experimental)
                return ["--incremental"];
            case LinkerType.MSVC:
                // MSVC supports /INCREMENTAL
                return ["/INCREMENTAL"];
            case LinkerType.LD64:
                // macOS ld64 - incremental via -no_deduplicate
                return ["-no_deduplicate", "-no_compact_unwind"];
            case LinkerType.Mold:
                // Mold is so fast it doesn't need incremental
                return [];
            case LinkerType.Gold:
                // Gold has --incremental-base and --incremental
                return ["--incremental"];
            case LinkerType.GNU_LD, LinkerType.Unknown:
                return [];
        }
    }
    
    /// Get flags for delta/partial linking
    string[] getDeltaLinkFlags() const pure nothrow @safe
    {
        final switch (type)
        {
            case LinkerType.LLD:
                return ["-r", "--incremental"];  // Relocatable + incremental
            case LinkerType.MSVC:
                return ["/INCREMENTAL", "/LTCG:incremental"];
            case LinkerType.LD64:
                return ["-r"];  // Relocatable only
            case LinkerType.Mold, LinkerType.Gold:
                return ["-r"];
            case LinkerType.GNU_LD, LinkerType.Unknown:
                return ["-r"];
        }
    }
    
    /// Check if this linker supports incremental linking well
    bool hasGoodIncrementalSupport() const pure nothrow @safe =>
        type == LinkerType.LLD || type == LinkerType.MSVC || type == LinkerType.Gold;
}

/// Incremental linking engine
/// Tracks object file changes and enables partial re-linking
final class IncrementalLinker
{
    private string cacheDir;
    private Mutex mutex;
    private ActionCache actionCache;
    private LinkState[string] linkStates;  // Key: output path
    private LinkerConfig detectedLinker;
    private bool initialized;
    
    // Statistics
    private size_t fullLinks;
    private size_t incrementalLinks;
    private size_t savedLinkTime;  // Estimated ms saved
    
    this(string cacheDir = ".builder-cache/linking", ActionCache actionCache = null) @system
    {
        this.cacheDir = cacheDir;
        this.mutex = new Mutex();
        this.actionCache = actionCache;
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
        
        loadStates();
        detectLinker();
        initialized = true;
    }
    
    /// Analyze objects to determine optimal linking strategy
    LinkAnalysis analyze(
        string outputPath,
        scope const(string)[] objects,
        scope const(string)[] libraries = null,
        string linkerFlags = ""
    ) @system
    {
        synchronized (mutex)
        {
            LinkAnalysis analysis;
            auto normalized = buildNormalizedPath(outputPath);
            
            // Check if we have previous link state
            auto statePtr = normalized in linkStates;
            if (statePtr is null || !exists(outputPath))
            {
                analysis.strategy = LinkStrategy.Full;
                analysis.objectsToLink = objects.dup;
                analysis.reason = "no previous link state";
                return analysis;
            }
            
            auto state = *statePtr;
            
            // Check if linker flags changed
            if (state.linkerFlags != linkerFlags)
            {
                analysis.strategy = LinkStrategy.Full;
                analysis.objectsToLink = objects.dup;
                analysis.reason = "linker flags changed";
                return analysis;
            }
            
            // Get changed objects
            analysis.changedObjects = state.getChangedObjects(objects);
            
            // Detect added/removed objects
            auto currentSet = objects.map!(o => buildNormalizedPath(o)).array.sort.array;
            auto storedSet = state.objects.map!(o => buildNormalizedPath(o.path)).array.sort.array;
            
            analysis.addedObjects = currentSet.filter!(o => !storedSet.canFind(o))
                .map!(o => cast(string)o).array;
            analysis.removedObjects = storedSet.filter!(o => !currentSet.canFind(o))
                .map!(o => cast(string)o).array;
            
            // Determine strategy based on changes
            size_t totalChanged = analysis.changedObjects.length + 
                                  analysis.addedObjects.length + 
                                  analysis.removedObjects.length;
            
            if (totalChanged == 0)
            {
                // No changes - check if output still valid
                if (exists(outputPath) && FastHash.hashFile(outputPath) == state.outputHash)
                {
                    analysis.strategy = LinkStrategy.Full;  // Actually cached
                    analysis.objectsToLink = [];
                    analysis.cachedObjects = objects.dup;
                    analysis.reductionPercent = 100.0;
                    analysis.reason = "no changes, output cached";
                    return analysis;
                }
            }
            
            // Determine if incremental is beneficial
            float changeRatio = cast(float)totalChanged / objects.length;
            
            if (changeRatio < 0.3 && detectedLinker.supportsIncremental && 
                analysis.removedObjects.empty)  // Can't remove objects incrementally
            {
                analysis.strategy = LinkStrategy.Incremental;
                analysis.objectsToLink = objects.dup;  // Link all but with incremental flag
                analysis.cachedObjects = [];
                analysis.reductionPercent = (1.0 - changeRatio) * 100.0;
                analysis.reason = "incremental link: " ~ totalChanged.to!string ~ 
                    " of " ~ objects.length.to!string ~ " changed";
            }
            else
            {
                analysis.strategy = LinkStrategy.Full;
                analysis.objectsToLink = objects.dup;
                analysis.reason = changeRatio >= 0.3 ? "too many changes for incremental" :
                    (!analysis.removedObjects.empty ? "objects removed" : "full relink needed");
            }
            
            return analysis;
        }
    }
    
    /// Get linker flags based on analysis
    string[] getLinkerFlags(
        in LinkAnalysis analysis,
        scope const(string)[] baseFlags = null
    ) const pure @safe
    {
        string[] flags = baseFlags.dup;
        
        if (analysis.strategy == LinkStrategy.Incremental)
            flags ~= detectedLinker.getIncrementalFlags();
        else if (analysis.strategy == LinkStrategy.Delta)
            flags ~= detectedLinker.getDeltaLinkFlags();
        
        return flags;
    }
    
    /// Build linker command with optimal flags
    string[] buildLinkCommand(
        string linkerPath,
        string outputPath,
        scope const(string)[] objects,
        scope const(string)[] libraries,
        in LinkAnalysis analysis,
        scope const(string)[] extraFlags = null
    ) const @system
    {
        string[] cmd = [linkerPath];
        
        // Output flag (platform-specific)
        if (detectedLinker.type == LinkerType.MSVC)
            cmd ~= "/OUT:" ~ outputPath;
        else
            cmd ~= ["-o", outputPath];
        
        // Add incremental flags if appropriate
        if (analysis.canIncrementalLink())
            cmd ~= detectedLinker.getIncrementalFlags();
        
        // Add objects
        cmd ~= objects.dup;
        
        // Add libraries
        foreach (lib; libraries)
        {
            if (detectedLinker.type == LinkerType.MSVC)
                cmd ~= lib;
            else
                cmd ~= "-l" ~ lib;
        }
        
        // Add extra flags
        cmd ~= extraFlags.dup;
        
        return cmd;
    }
    
    /// Record successful link for future incremental builds
    void recordLink(
        string outputPath,
        scope const(string)[] objects,
        scope const(string)[] libraries,
        string linkerFlags,
        bool wasIncremental
    ) @system
    {
        synchronized (mutex)
        {
            auto normalized = buildNormalizedPath(outputPath);
            
            LinkState state;
            state.outputPath = normalized;
            state.outputHash = exists(outputPath) ? FastHash.hashFile(outputPath) : "";
            state.timestamp = Clock.currTime();
            state.linkerType = detectedLinker.type;
            state.linkerFlags = linkerFlags;
            state.incrementalEnabled = wasIncremental;
            
            // Capture object states
            foreach (obj; objects)
            {
                if (!exists(obj)) continue;
                
                ObjectState objState;
                objState.path = obj;
                objState.hash = FastHash.hashFile(obj);
                objState.size = getSize(obj);
                objState.mtime = timeLastModified(obj);
                state.objects ~= objState;
            }
            
            state.libraries = libraries.dup;
            linkStates[normalized] = state;
            
            // Update stats
            if (wasIncremental)
                incrementalLinks++;
            else
                fullLinks++;
            
            saveStates();
            
            structuredLog.debug_("link_recorded")
                .field("output", baseName(outputPath))
                .field("objects", objects.length)
                .field("incremental", wasIncremental)
                .emit();
        }
    }
    
    /// Invalidate link state for an output
    void invalidate(string outputPath) @system
    {
        synchronized (mutex)
        {
            linkStates.remove(buildNormalizedPath(outputPath));
            saveStates();
        }
    }
    
    /// Get detected linker configuration
    const(LinkerConfig) getLinkerConfig() const pure nothrow @safe => detectedLinker;
    
    /// Check if incremental linking is available
    bool isIncrementalAvailable() const pure nothrow @safe => 
        detectedLinker.supportsIncremental;
    
    /// Get linker type for a given path
    static LinkerType detectLinkerType(string linkerPath) @system
    {
        if (linkerPath.empty) return LinkerType.Unknown;
        
        auto base = baseName(linkerPath).toLower;
        
        if (base.canFind("lld") || base.canFind("ld.lld"))
            return LinkerType.LLD;
        if (base.canFind("link.exe") || base == "link")
            return LinkerType.MSVC;
        if (base.canFind("mold"))
            return LinkerType.Mold;
        if (base.canFind("gold") || base.canFind("ld.gold"))
            return LinkerType.Gold;
        if (base.canFind("ld64"))
            return LinkerType.LD64;
        
        // Try to detect via version output
        try
        {
            auto res = execute([linkerPath, "--version"]);
            if (res.status == 0)
            {
                auto output = res.output.toLower;
                if (output.canFind("lld"))
                    return LinkerType.LLD;
                if (output.canFind("mold"))
                    return LinkerType.Mold;
                if (output.canFind("gold"))
                    return LinkerType.Gold;
                if (output.canFind("gnu ld"))
                    return LinkerType.GNU_LD;
            }
        }
        catch (Exception) {}
        
        version (OSX)
            return LinkerType.LD64;  // Default on macOS
        else
            return LinkerType.GNU_LD;  // Default elsewhere
    }
    
    /// Get statistics
    struct Stats
    {
        size_t fullLinks;
        size_t incrementalLinks;
        size_t trackedOutputs;
        size_t totalObjects;
        float incrementalRate;
        LinkerType linkerType;
        bool incrementalSupported;
    }
    
    Stats getStats() const @system
    {
        synchronized (cast(Mutex)mutex)
        {
            Stats s;
            s.fullLinks = fullLinks;
            s.incrementalLinks = incrementalLinks;
            s.trackedOutputs = linkStates.length;
            s.linkerType = detectedLinker.type;
            s.incrementalSupported = detectedLinker.supportsIncremental;
            
            foreach (state; linkStates.byValue)
                s.totalObjects += state.objects.length;
            
            auto total = fullLinks + incrementalLinks;
            s.incrementalRate = total > 0 ? 
                (cast(float)incrementalLinks / total) * 100.0 : 0.0;
            
            return s;
        }
    }
    
    private void detectLinker() @system
    {
        auto platform = Platform.host();
        
        // Try to find best available linker
        string[] candidates;
        
        version (Windows)
        {
            candidates = ["lld-link", "link.exe"];
            detectedLinker.type = LinkerType.MSVC;
        }
        else version (OSX)
        {
            candidates = ["ld.lld", "ld", "ld64.lld"];
            detectedLinker.type = LinkerType.LD64;
        }
        else  // Linux/Unix
        {
            candidates = ["ld.lld", "mold", "ld.gold", "ld"];
            detectedLinker.type = LinkerType.GNU_LD;
        }
        
        foreach (linker; candidates)
        {
            auto result = findLinker(linker);
            if (!result.empty)
            {
                detectedLinker.path = result;
                detectedLinker.type = detectLinkerType(result);
                break;
            }
        }
        
        // Set capabilities based on type
        final switch (detectedLinker.type)
        {
            case LinkerType.LLD:
                detectedLinker.supportsIncremental = true;
                detectedLinker.supportsThinLTO = true;
                detectedLinker.supportsLTO = true;
                break;
            case LinkerType.MSVC:
                detectedLinker.supportsIncremental = true;
                detectedLinker.supportsThinLTO = false;
                detectedLinker.supportsLTO = true;
                break;
            case LinkerType.Mold:
                detectedLinker.supportsIncremental = false;  // Fast enough without
                detectedLinker.supportsThinLTO = true;
                detectedLinker.supportsLTO = true;
                break;
            case LinkerType.Gold:
                detectedLinker.supportsIncremental = true;
                detectedLinker.supportsThinLTO = false;
                detectedLinker.supportsLTO = true;
                break;
            case LinkerType.LD64:
                detectedLinker.supportsIncremental = false;  // Limited
                detectedLinker.supportsThinLTO = true;
                detectedLinker.supportsLTO = true;
                break;
            case LinkerType.GNU_LD, LinkerType.Unknown:
                detectedLinker.supportsIncremental = false;
                detectedLinker.supportsThinLTO = false;
                detectedLinker.supportsLTO = true;
                break;
        }
        
        structuredLog.debug_("linker_detected")
            .field("type", detectedLinker.type.to!string)
            .field("path", detectedLinker.path)
            .field("incremental", detectedLinker.supportsIncremental)
            .emit();
    }
    
    private static string findLinker(string name) @system
    {
        import std.process : environment;
        
        // Check PATH
        auto pathEnv = environment.get("PATH", "");
        version (Windows)
            auto paths = pathEnv.split(";");
        else
            auto paths = pathEnv.split(":");
        
        foreach (dir; paths)
        {
            version (Windows)
                auto candidate = buildPath(dir, name ~ ".exe");
            else
                auto candidate = buildPath(dir, name);
            
            if (exists(candidate))
                return candidate;
        }
        
        // Common locations
        string[] commonPaths;
        version (OSX)
        {
            commonPaths = [
                "/usr/bin",
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "/Library/Developer/CommandLineTools/usr/bin"
            ];
        }
        else version (Windows)
        {
            commonPaths = [
                "C:\\Program Files\\LLVM\\bin",
                "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC\\14.38.33130\\bin\\Hostx64\\x64"
            ];
        }
        else
        {
            commonPaths = [
                "/usr/bin",
                "/usr/local/bin",
                "/usr/lib/llvm-17/bin",
                "/usr/lib/llvm-16/bin",
                "/usr/lib/llvm-15/bin"
            ];
        }
        
        foreach (dir; commonPaths)
        {
            version (Windows)
                auto candidate = buildPath(dir, name ~ ".exe");
            else
                auto candidate = buildPath(dir, name);
            
            if (exists(candidate))
                return candidate;
        }
        
        return "";
    }
    
    private void loadStates() @system
    {
        auto statePath = buildPath(cacheDir, "link_states.bin");
        if (!exists(statePath)) return;
        
        try
        {
            auto data = cast(ubyte[])std.file.read(statePath);
            if (data.length < 4) return;
            
            // Simple binary deserialization with manual reading
            size_t offset = 0;
            
            uint count = (cast(uint[])data[0..4])[0];
            offset = 4;
            
            for (size_t i = 0; i < count && offset + 2 < data.length; i++)
            {
                ushort pathLen = (cast(ushort[])data[offset..offset+2])[0];
                offset += 2;
                if (offset + pathLen > data.length) break;
                
                auto path = cast(string)data[offset .. offset + pathLen].idup;
                offset += pathLen;
                
                LinkState state;
                state.outputPath = path;
                
                // Read output hash
                if (offset + 2 > data.length) break;
                ushort hashLen = (cast(ushort[])data[offset..offset+2])[0];
                offset += 2;
                if (offset + hashLen > data.length) break;
                state.outputHash = cast(string)data[offset .. offset + hashLen].idup;
                offset += hashLen;
                
                // Read object count
                if (offset + 4 > data.length) break;
                uint objCount = (cast(uint[])data[offset..offset+4])[0];
                offset += 4;
                
                for (size_t j = 0; j < objCount && offset + 2 < data.length; j++)
                {
                    ObjectState obj;
                    ushort objPathLen = (cast(ushort[])data[offset..offset+2])[0];
                    offset += 2;
                    if (offset + objPathLen > data.length) break;
                    obj.path = cast(string)data[offset .. offset + objPathLen].idup;
                    offset += objPathLen;
                    
                    if (offset + 2 > data.length) break;
                    ushort objHashLen = (cast(ushort[])data[offset..offset+2])[0];
                    offset += 2;
                    if (offset + objHashLen > data.length) break;
                    obj.hash = cast(string)data[offset .. offset + objHashLen].idup;
                    offset += objHashLen;
                    
                    state.objects ~= obj;
                }
                
                linkStates[buildNormalizedPath(path)] = state;
            }
            
            structuredLog.debug_("link_states_loaded").field("count", linkStates.length).emit();
        }
        catch (Exception e)
        {
            structuredLog.debug_("link_states_load_failed").field("error", e.msg).emit();
        }
    }
    
    private void saveStates() @system nothrow
    {
        try
        {
            ubyte[] data;
            
            // Write count (little-endian)
            uint count = cast(uint)linkStates.length;
            data ~= (cast(ubyte*)&count)[0..4];
            
            foreach (state; linkStates.byValue)
            {
                // Write path length and path
                ushort pathLen = cast(ushort)state.outputPath.length;
                data ~= (cast(ubyte*)&pathLen)[0..2];
                data ~= cast(ubyte[])state.outputPath;
                
                // Write hash length and hash
                ushort hashLen = cast(ushort)state.outputHash.length;
                data ~= (cast(ubyte*)&hashLen)[0..2];
                data ~= cast(ubyte[])state.outputHash;
                
                // Write object count
                uint objCount = cast(uint)state.objects.length;
                data ~= (cast(ubyte*)&objCount)[0..4];
                
                foreach (ref obj; state.objects)
                {
                    ushort objPathLen = cast(ushort)obj.path.length;
                    data ~= (cast(ubyte*)&objPathLen)[0..2];
                    data ~= cast(ubyte[])obj.path;
                    
                    ushort objHashLen = cast(ushort)obj.hash.length;
                    data ~= (cast(ubyte*)&objHashLen)[0..2];
                    data ~= cast(ubyte[])obj.hash;
                }
            }
            
            std.file.write(buildPath(cacheDir, "link_states.bin"), data);
        }
        catch (Exception) {}
    }
    
    ~this() nothrow
    {
        // Note: Don't destroy mutex in destructor - may cause issues during GC
        // Users should ensure proper cleanup if needed
    }
}

/// Helper to create linker arguments for different platforms
struct LinkerArgs
{
    string[] args;
    LinkerType type;
    
    /// Add output path
    ref LinkerArgs output(string path) return @safe
    {
        if (type == LinkerType.MSVC)
            args ~= "/OUT:" ~ path;
        else
            args ~= ["-o", path];
        return this;
    }
    
    /// Add library search path
    ref LinkerArgs libPath(string path) return @safe
    {
        if (type == LinkerType.MSVC)
            args ~= "/LIBPATH:" ~ path;
        else
            args ~= ["-L", path];
        return this;
    }
    
    /// Add library
    ref LinkerArgs lib(string name) return @safe
    {
        if (type == LinkerType.MSVC)
            args ~= name ~ ".lib";
        else
            args ~= "-l" ~ name;
        return this;
    }
    
    /// Add incremental flag
    ref LinkerArgs incremental() return @safe
    {
        final switch (type)
        {
            case LinkerType.LLD:
                args ~= "--incremental";
                break;
            case LinkerType.MSVC:
                args ~= "/INCREMENTAL";
                break;
            case LinkerType.Gold:
                args ~= "--incremental";
                break;
            case LinkerType.LD64, LinkerType.Mold, LinkerType.GNU_LD, LinkerType.Unknown:
                // No incremental support
                break;
        }
        return this;
    }
    
    /// Add debug info
    ref LinkerArgs debug_() return @safe
    {
        if (type == LinkerType.MSVC)
            args ~= "/DEBUG";
        else
            args ~= "-g";
        return this;
    }
    
    /// Static initializer
    static LinkerArgs create(LinkerType type) @safe
    {
        LinkerArgs la;
        la.type = type;
        return la;
    }
}

