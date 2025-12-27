module engine.caching.modules.bmi;

import std.algorithm : any, canFind, filter, map, sort;
import std.array : array, join;
import std.conv : to;
import std.datetime : Clock, SysTime;
import std.digest.sha : SHA256, toHexString;
import std.file : exists, isFile, mkdirRecurse, read, remove, rmdirRecurse, write;
import std.path : baseName, buildPath, dirName, extension;
import core.sync.mutex : Mutex;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.simd.hash : SIMDHash;
import engine.caching.index : CacheIndex;
import engine.caching.policies.eviction : EvictionPolicy;
import infrastructure.utils.security.integrity : IntegrityValidator, SignedData;
import infrastructure.errors;

/// Compiler types for BMI format differentiation
enum BMICompiler : ubyte
{
    Unknown,
    GCC,     // .gcm files
    Clang,   // .pcm files  
    MSVC,    // .ifc files
}

/// Module type classification
enum ModuleType : ubyte
{
    Interface,    // Module interface unit (.cppm, .ixx, export module)
    Partition,    // Module partition (module foo:bar)
    HeaderUnit,   // Header unit (import <header>; or import "header";)
    Implementation // Module implementation unit (non-exported)
}

/// BMI cache key - uniquely identifies a cached module interface
struct BMIKey
{
    string moduleName;          // Logical module name (e.g., "std.io", "mylib.core")
    BMICompiler compiler;       // Compiler that generated the BMI
    string compilerVersion;     // Full compiler version string
    string flagsHash;           // Hash of relevant compiler flags
    string contentHash;         // Hash of module interface source content
    ModuleType moduleType;      // Type of module
    
    string toString() const pure @safe
    {
        import std.format : format;
        return format("%s:%s:%s:%s:%s", moduleName, compiler, compilerVersion[0..min($, 8)], flagsHash[0..min($, 8)], contentHash[0..min($, 8)]);
    }
    
    /// Generate stable storage key
    string toStorageKey() const @trusted
    {
        SHA256 hash;
        hash.start();
        hash.put(cast(ubyte[])moduleName);
        hash.put(cast(ubyte)compiler);
        hash.put(cast(ubyte[])compilerVersion);
        hash.put(cast(ubyte[])flagsHash);
        hash.put(cast(ubyte[])contentHash);
        hash.put(cast(ubyte)moduleType);
        return toHexString(hash.finish()).to!string;
    }
    
    private static size_t min(size_t a, size_t b) pure @safe => a < b ? a : b;
}

/// BMI cache entry with dependency tracking
struct BMIEntry
{
    BMIKey key;
    string bmiPath;                  // Path to cached .pcm/.gcm/.ifc file
    string sourcePath;               // Original source file path
    string[] dependencies;           // Module dependencies (other BMI keys)
    string[string] dependencyHashes; // Hash of each dependency's BMI
    SysTime timestamp;               // When BMI was generated
    SysTime lastAccess;              // LRU tracking
    long bmiSize;                    // Size of BMI file in bytes
    bool isValid;                    // Whether entry passed validation
    
    // Compiler-specific metadata
    string[string] metadata;         // Additional compiler-specific data
}

/// Configuration for BMI cache
struct BMICacheConfig
{
    size_t maxSize = 2_147_483_648;   // 2 GB default (BMIs can be large)
    size_t maxEntries = 10_000;        // 10k modules default
    size_t maxAge = 60;                // 60 days default
    bool validateOnLoad = true;        // Verify BMI integrity on cache load
    bool trackDependencies = true;     // Enable transitive dependency tracking
    
    static BMICacheConfig fromEnvironment() @system
    {
        import std.process : environment;
        
        BMICacheConfig config;
        
        if (auto v = environment.get("BUILDER_BMI_CACHE_MAX_SIZE"))
            config.maxSize = v.to!size_t;
        if (auto v = environment.get("BUILDER_BMI_CACHE_MAX_ENTRIES"))
            config.maxEntries = v.to!size_t;
        if (auto v = environment.get("BUILDER_BMI_CACHE_MAX_AGE_DAYS"))
            config.maxAge = v.to!size_t;
        if (auto v = environment.get("BUILDER_BMI_CACHE_VALIDATE"))
            config.validateOnLoad = (v == "1" || toLowerCase(v) == "true");
            
        return config;
    }
    
    private static string toLowerCase(string s) pure @trusted
    {
        import std.ascii : toLower;
        auto result = new char[s.length];
        foreach (i, c; s) result[i] = toLower(c);
        return (() @trusted => cast(string)result)();
    }
}

/// High-performance BMI cache for C++20 modules and header units
///
/// Design:
/// - Caches Binary Module Interface files (.pcm/.gcm/.ifc) by compiler
/// - Invalidates on: compiler version change, flag changes, source changes
/// - Tracks transitive module dependencies for proper invalidation
/// - Supports header-unit caching for faster compilation
///
/// Thread Safety:
/// - All public methods synchronized via internal mutex
/// - Safe for concurrent module compilations
final class BMICache
{
    private string cacheDir;
    private immutable string indexPath;
    private BMIEntry[string] entries;  // Key: BMIKey.toStorageKey()
    private bool dirty;
    private BMICacheConfig config;
    private Mutex cacheMutex;
    private IntegrityValidator validator;
    private CacheIndex index;
    
    // Statistics
    private size_t hits, misses;
    private size_t totalBMISize;
    
    this(string cacheDir = ".builder-cache/bmi", BMICacheConfig config = BMICacheConfig.init, CacheIndex sharedIndex = null) @system
    {
        this.cacheDir = cacheDir;
        this.indexPath = buildPath(cacheDir, "bmi_index.bin");
        this.config = config;
        this.cacheMutex = new Mutex();
        
        import std.file : getcwd;
        this.validator = IntegrityValidator.fromEnvironment(getcwd());
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
            
        // Create subdirectories for each compiler type
        foreach (compiler; [BMICompiler.GCC, BMICompiler.Clang, BMICompiler.MSVC])
            mkdirRecurse(buildPath(cacheDir, compilerSubdir(compiler)));
        
        this.index = sharedIndex ? sharedIndex : new CacheIndex(dirName(cacheDir));
        
        loadIndex();
    }
    
    /// Check if a module's BMI is cached and valid
    bool isCached(ref const BMIKey key) @system
    {
        synchronized (cacheMutex)
        {
            auto storageKey = key.toStorageKey();
            auto entryPtr = storageKey in entries;
            
            if (entryPtr is null)
                return recordMiss();
            
            // Validate BMI file exists
            if (!exists(entryPtr.bmiPath))
                return recordMiss();
            
            // Validate dependencies haven't changed
            if (config.trackDependencies && !validateDependencies(*entryPtr))
            {
                invalidateEntry(storageKey);
                return recordMiss();
            }
            
            entryPtr.lastAccess = Clock.currTime();
            dirty = true;
            
            recordHit();
            return true;
        }
    }
    
    /// Get cached BMI path if valid
    BuildResult!string getBMIPath(ref const BMIKey key) @system
    {
        synchronized (cacheMutex)
        {
            auto storageKey = key.toStorageKey();
            auto entryPtr = storageKey in entries;
            
            if (entryPtr is null || !exists(entryPtr.bmiPath))
                return Err!(string, BuildError)(
                    Errors.cache("BMI not found: " ~ key.moduleName, Cache.NotFound).build());
            
            return Ok!(string, BuildError)(entryPtr.bmiPath);
        }
    }
    
    /// Store a compiled BMI in the cache
    void store(
        ref const BMIKey key,
        string bmiSourcePath,
        string sourcePath,
        scope const(string)[] dependencies = [],
        scope const(string[string]) metadata = null
    ) @system
    {
        synchronized (cacheMutex)
        {
            if (!exists(bmiSourcePath))
                return;
            
            auto storageKey = key.toStorageKey();
            immutable now = Clock.currTime();
            
            // Determine destination path
            string destPath = buildPath(
                cacheDir,
                compilerSubdir(key.compiler),
                storageKey ~ bmiExtension(key.compiler)
            );
            
            // Copy BMI to cache
            import std.file : copy, getSize;
            if (bmiSourcePath != destPath)
            {
                auto destDir = dirName(destPath);
                if (!exists(destDir))
                    mkdirRecurse(destDir);
                copy(bmiSourcePath, destPath);
            }
            
            // Create entry
            BMIEntry entry;
            entry.key = cast(BMIKey)key;
            entry.bmiPath = destPath;
            entry.sourcePath = sourcePath;
            entry.dependencies = dependencies.dup;
            entry.timestamp = now;
            entry.lastAccess = now;
            entry.bmiSize = getSize(destPath).to!long;
            entry.isValid = true;
            
            if (metadata !is null)
                entry.metadata = cast(string[string])metadata.dup;
            
            // Hash dependencies for change detection
            foreach (dep; dependencies)
            {
                if (auto depEntry = dep in entries)
                    entry.dependencyHashes[dep] = FastHash.hashFile(depEntry.bmiPath);
            }
            
            // Update tracking
            if (auto existing = storageKey in entries)
                totalBMISize -= existing.bmiSize;
            totalBMISize += entry.bmiSize;
            
            entries[storageKey] = entry;
            dirty = true;
        }
    }
    
    /// Invalidate a specific module's cache entry
    void invalidate(ref const BMIKey key) @system
    {
        synchronized (cacheMutex)
        {
            invalidateEntry(key.toStorageKey());
        }
    }
    
    /// Invalidate all entries for a specific compiler version
    void invalidateCompilerVersion(BMICompiler compiler, string version_) @system
    {
        synchronized (cacheMutex)
        {
            string[] toRemove;
            foreach (storageKey, ref entry; entries)
            {
                if (entry.key.compiler == compiler && entry.key.compilerVersion != version_)
                    toRemove ~= storageKey;
            }
            
            foreach (key; toRemove)
                invalidateEntry(key);
        }
    }
    
    /// Clear entire BMI cache
    void clear() @system
    {
        synchronized (cacheMutex)
        {
            entries.clear();
            totalBMISize = 0;
            dirty = false;
        }
        
        if (exists(cacheDir))
            rmdirRecurse(cacheDir);
        mkdirRecurse(cacheDir);
        
        // Recreate compiler subdirectories
        foreach (compiler; [BMICompiler.GCC, BMICompiler.Clang, BMICompiler.MSVC])
            mkdirRecurse(buildPath(cacheDir, compilerSubdir(compiler)));
    }
    
    /// Flush index to disk and run eviction
    void flush() @system
    {
        synchronized (cacheMutex)
        {
            if (!dirty) return;
            
            runEviction();
            saveIndex();
            dirty = false;
        }
    }
    
    /// Get cache statistics
    struct BMICacheStats
    {
        size_t totalEntries;
        size_t totalSize;
        size_t hits, misses;
        float hitRate;
        size_t headerUnits;
        size_t moduleInterfaces;
        size_t[BMICompiler] byCompiler;
    }
    
    BMICacheStats getStats() const @system
    {
        synchronized (cast(Mutex)cacheMutex)
        {
            BMICacheStats stats;
            stats.totalEntries = entries.length;
            stats.totalSize = totalBMISize;
            stats.hits = hits;
            stats.misses = misses;
            
            auto total = hits + misses;
            stats.hitRate = total > 0 ? (hits * 100.0f) / total : 0;
            
            foreach (ref entry; entries)
            {
                stats.byCompiler[entry.key.compiler]++;
                if (entry.key.moduleType == ModuleType.HeaderUnit)
                    stats.headerUnits++;
                else
                    stats.moduleInterfaces++;
            }
            
            return stats;
        }
    }
    
    /// Get all cached modules for a given compiler
    string[] getModulesForCompiler(BMICompiler compiler) const @system
    {
        synchronized (cast(Mutex)cacheMutex)
        {
            return entries.byValue
                .filter!(e => e.key.compiler == compiler)
                .map!(e => cast(string)e.key.moduleName)
                .array;
        }
    }
    
private:
    bool recordMiss() @system nothrow
    {
        misses++;
        return false;
    }
    
    void recordHit() @system nothrow
    {
        hits++;
    }
    
    void invalidateEntry(string storageKey) @system
    {
        if (auto entry = storageKey in entries)
        {
            if (exists(entry.bmiPath))
            {
                try remove(entry.bmiPath);
                catch (Exception) {}
            }
            totalBMISize -= entry.bmiSize;
            entries.remove(storageKey);
            dirty = true;
        }
    }
    
    bool validateDependencies(ref const BMIEntry entry) @system
    {
        foreach (dep; entry.dependencies)
        {
            auto depEntry = dep in entries;
            if (depEntry is null)
                return false;
            
            // Check if dependency's BMI has changed
            auto currentHash = entry.dependencyHashes.get(dep, "");
            if (currentHash.length == 0)
                continue;
            
            if (!exists(depEntry.bmiPath))
                return false;
            
            auto actualHash = FastHash.hashFile(depEntry.bmiPath);
            if (!SIMDHash.equals(currentHash, actualHash))
                return false;
        }
        return true;
    }
    
    void runEviction() @system
    {
        // Simple LRU eviction when over size/entry limits
        if (totalBMISize <= config.maxSize && entries.length <= config.maxEntries)
            return;
        
        // Sort by last access time
        auto sorted = entries.byKeyValue
            .map!(kv => tuple(kv.key, kv.value.lastAccess, kv.value.bmiSize))
            .array
            .sort!((a, b) => a[1] < b[1]);
        
        foreach (item; sorted)
        {
            if (totalBMISize <= config.maxSize * 0.9 && entries.length <= config.maxEntries * 0.9)
                break;
            invalidateEntry(item[0]);
        }
    }
    
    static string compilerSubdir(BMICompiler compiler) pure @safe
    {
        final switch (compiler)
        {
            case BMICompiler.Unknown: return "unknown";
            case BMICompiler.GCC: return "gcc";
            case BMICompiler.Clang: return "clang";
            case BMICompiler.MSVC: return "msvc";
        }
    }
    
    static string bmiExtension(BMICompiler compiler) pure @safe
    {
        final switch (compiler)
        {
            case BMICompiler.Unknown: return ".bmi";
            case BMICompiler.GCC: return ".gcm";
            case BMICompiler.Clang: return ".pcm";
            case BMICompiler.MSVC: return ".ifc";
        }
    }
    
    void loadIndex() @system
    {
        if (!exists(indexPath)) return;
        
        try
        {
            auto fileData = cast(ubyte[])read(indexPath);
            auto signed = SignedData.deserialize(fileData);
            
            if (!validator.verifyWithMetadata(signed))
            {
                entries.clear();
                return;
            }
            
            import core.time : days;
            if (IntegrityValidator.isExpired(signed, config.maxAge.days))
            {
                entries.clear();
                return;
            }
            
            // Deserialize entries
            entries = deserializeBMIEntries(signed.data);
            
            // Recalculate total size and validate
            totalBMISize = 0;
            string[] invalid;
            foreach (key, ref entry; entries)
            {
                if (config.validateOnLoad && !exists(entry.bmiPath))
                    invalid ~= key;
                else
                    totalBMISize += entry.bmiSize;
            }
            foreach (key; invalid)
                entries.remove(key);
        }
        catch (Exception)
        {
            entries.clear();
        }
    }
    
    void saveIndex() nothrow
    {
        try
        {
            auto data = serializeBMIEntries(entries);
            auto signed = validator.signWithMetadata(data);
            write(indexPath, signed.serialize());
        }
        catch (Exception) {}
    }
    
    // Simple binary serialization
    static ubyte[] serializeBMIEntries(BMIEntry[string] entries) @system
    {
        import std.bitmanip : nativeToLittleEndian;
        
        ubyte[] result;
        
        // Write entry count
        result ~= nativeToLittleEndian(cast(uint)entries.length);
        
        foreach (ref entry; entries)
        {
            // Write each field with length prefix
            void writeString(string s)
            {
                result ~= nativeToLittleEndian(cast(uint)s.length);
                result ~= cast(ubyte[])s;
            }
            
            void writeStringArray(string[] arr)
            {
                result ~= nativeToLittleEndian(cast(uint)arr.length);
                foreach (s; arr) writeString(s);
            }
            
            writeString(entry.key.moduleName);
            result ~= cast(ubyte)entry.key.compiler;
            writeString(entry.key.compilerVersion);
            writeString(entry.key.flagsHash);
            writeString(entry.key.contentHash);
            result ~= cast(ubyte)entry.key.moduleType;
            writeString(entry.bmiPath);
            writeString(entry.sourcePath);
            writeStringArray(entry.dependencies);
            result ~= nativeToLittleEndian(entry.timestamp.stdTime);
            result ~= nativeToLittleEndian(entry.lastAccess.stdTime);
            result ~= nativeToLittleEndian(entry.bmiSize);
            result ~= cast(ubyte)(entry.isValid ? 1 : 0);
            
            // Write dependency hashes
            result ~= nativeToLittleEndian(cast(uint)entry.dependencyHashes.length);
            foreach (k, v; entry.dependencyHashes)
            {
                writeString(k);
                writeString(v);
            }
            
            // Write metadata
            result ~= nativeToLittleEndian(cast(uint)entry.metadata.length);
            foreach (k, v; entry.metadata)
            {
                writeString(k);
                writeString(v);
            }
        }
        
        return result;
    }
    
    static BMIEntry[string] deserializeBMIEntries(ubyte[] data) @system
    {
        import std.bitmanip : littleEndianToNative;
        
        BMIEntry[string] result;
        size_t pos = 0;
        
        T read(T)()
        {
            auto bytes = data[pos .. pos + T.sizeof];
            pos += T.sizeof;
            return littleEndianToNative!T(bytes[0..T.sizeof]);
        }
        
        string readString()
        {
            auto len = read!uint();
            auto s = cast(string)data[pos .. pos + len].dup;
            pos += len;
            return s;
        }
        
        string[] readStringArray()
        {
            auto count = read!uint();
            string[] arr;
            arr.reserve(count);
            foreach (_; 0 .. count)
                arr ~= readString();
            return arr;
        }
        
        auto entryCount = read!uint();
        
        foreach (_; 0 .. entryCount)
        {
            BMIEntry entry;
            
            entry.key.moduleName = readString();
            entry.key.compiler = cast(BMICompiler)data[pos++];
            entry.key.compilerVersion = readString();
            entry.key.flagsHash = readString();
            entry.key.contentHash = readString();
            entry.key.moduleType = cast(ModuleType)data[pos++];
            entry.bmiPath = readString();
            entry.sourcePath = readString();
            entry.dependencies = readStringArray();
            entry.timestamp = SysTime(read!long());
            entry.lastAccess = SysTime(read!long());
            entry.bmiSize = read!long();
            entry.isValid = data[pos++] != 0;
            
            // Read dependency hashes
            auto depHashCount = read!uint();
            foreach (__; 0 .. depHashCount)
            {
                auto k = readString();
                auto v = readString();
                entry.dependencyHashes[k] = v;
            }
            
            // Read metadata
            auto metaCount = read!uint();
            foreach (__; 0 .. metaCount)
            {
                auto k = readString();
                auto v = readString();
                entry.metadata[k] = v;
            }
            
            result[entry.key.toStorageKey()] = entry;
        }
        
        return result;
    }
    
    static auto tuple(T...)(T args) => Tuple!T(args);
    
    import std.typecons : Tuple;
}

/// Helper to create BMI key from compilation context
BMIKey createBMIKey(
    string moduleName,
    string sourcePath,
    string compilerPath,
    string compilerVersion,
    scope const(string)[] flags,
    ModuleType moduleType = ModuleType.Interface
) @system
{
    BMIKey key;
    key.moduleName = moduleName;
    key.moduleType = moduleType;
    key.compilerVersion = compilerVersion;
    
    // Detect compiler type from path
    if (compilerPath.canFind("clang"))
        key.compiler = BMICompiler.Clang;
    else if (compilerPath.canFind("g++") || compilerPath.canFind("gcc"))
        key.compiler = BMICompiler.GCC;
    else if (compilerPath.canFind("cl.exe") || compilerPath.canFind("msvc"))
        key.compiler = BMICompiler.MSVC;
    else
        key.compiler = BMICompiler.Unknown;
    
    // Hash relevant flags (exclude non-semantic flags like -o, paths)
    auto relevantFlags = flags.filter!(f => 
        f.startsWith("-std") || f.startsWith("-O") || f.startsWith("-f") ||
        f.startsWith("-D") || f.startsWith("-m") || f.startsWith("/std") ||
        f.startsWith("/O") || f.startsWith("/D")
    ).array;
    key.flagsHash = FastHash.hashStrings(relevantFlags);
    
    // Hash source content
    key.contentHash = exists(sourcePath) ? FastHash.hashFile(sourcePath) : "";
    
    return key;
}

/// Create BMI key for header unit
BMIKey createHeaderUnitKey(
    string headerPath,
    string compilerPath,
    string compilerVersion,
    scope const(string)[] flags
) @system
{
    return createBMIKey(
        "header:" ~ baseName(headerPath),
        headerPath,
        compilerPath,
        compilerVersion,
        flags,
        ModuleType.HeaderUnit
    );
}

private bool startsWith(string s, string prefix) pure @safe
{
    return s.length >= prefix.length && s[0..prefix.length] == prefix;
}

