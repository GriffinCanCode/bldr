module engine.distributed.protocol.reapi_v2.types;

import std.datetime : Duration, SysTime;
import std.conv : to;
import std.digest : toHexString;
import std.string : toLower;

/// Digest function variants supported by REAPI
enum DigestFunction : ubyte {
    Unknown = 0,
    SHA256 = 1,
    SHA1 = 2,
    MD5 = 3,
    VSO = 4,
    SHA384 = 5,
    SHA512 = 6,
    MURMUR3 = 7,
    SHA256TREE = 8,
    BLAKE3 = 9  // Builder's native
}

/// Compression algorithms
enum Compressor : ubyte {
    Identity = 0,
    Zstd = 1,
    Deflate = 2
}

/// Symlink path strategy
enum SymlinkAbsolutePathStrategy : ubyte {
    Unknown = 0,
    Disallowed = 1,
    Allowed = 2
}

/// REAPI content-addressed digest
struct ReapiDigest {
    ubyte[] hash;        // Hash bytes (length depends on function)
    long sizeBytes;      // Size in bytes
    DigestFunction func = DigestFunction.SHA256;
    
    this(const ubyte[] hash, long sizeBytes, DigestFunction func = DigestFunction.SHA256) pure @safe {
        this.hash = hash.dup;
        this.sizeBytes = sizeBytes;
        this.func = func;
    }
    
    /// Hash as hex string
    string hashString() const @trusted =>
        hash.length > 0 ? toHexString(hash).toLower() : "";
    
    /// Create from hex string
    static ReapiDigest fromHex(string hexStr, long sizeBytes, DigestFunction func = DigestFunction.SHA256) @trusted {
        if (hexStr.length == 0 || hexStr.length % 2 != 0)
            return ReapiDigest([], sizeBytes, func);
        
        auto hashLen = hexStr.length / 2;
        auto hash = new ubyte[hashLen];
        
        foreach (i; 0 .. hashLen) {
            auto hexPair = hexStr[i * 2 .. i * 2 + 2];
            hash[i] = cast(ubyte)hexPair.to!ubyte(16);
        }
        
        return ReapiDigest(hash, sizeBytes, func);
    }
    
    bool opEquals(const ReapiDigest other) const pure nothrow @safe @nogc =>
        hash == other.hash && sizeBytes == other.sizeBytes;
    
    size_t toHash() const pure nothrow @trusted @nogc =>
        hash.length >= size_t.sizeof ? *cast(size_t*)hash.ptr : 0;
}

/// Platform property
struct ReapiProperty {
    string name;
    string value;
}

/// Execution platform requirements
struct ReapiPlatform {
    ReapiProperty[] properties;
    
    /// Get property value by name
    string get(string name) const pure @safe {
        foreach (prop; properties)
            if (prop.name == name) return prop.value;
        return null;
    }
    
    /// Set or add property
    void set(string name, string value) @safe {
        foreach (ref prop; properties) {
            if (prop.name == name) {
                prop.value = value;
                return;
            }
        }
        properties ~= ReapiProperty(name, value);
    }
}

/// Environment variable
struct ReapiEnvVar {
    string name;
    string value;
}

/// REAPI command definition
struct ReapiCommand {
    string[] arguments;
    ReapiEnvVar[] environmentVariables;
    string[] outputFiles;
    string[] outputDirectories;
    string[] outputPaths;
    ReapiPlatform platform;
    string workingDirectory;
    string[] outputNodeProperties;
}

/// REAPI action definition
struct ReapiAction {
    ReapiDigest commandDigest;
    ReapiDigest inputRootDigest;
    Duration timeout;
    bool doNotCache;
    string salt;
    ReapiPlatform platform;
}

/// File node in directory tree
struct ReapiFileNode {
    string name;
    ReapiDigest digest;
    bool isExecutable;
    ReapiNodeProperty[] nodeProperties;
}

/// Directory node in tree
struct ReapiDirectoryNode {
    string name;
    ReapiDigest digest;
}

/// Symlink node
struct ReapiSymlinkNode {
    string name;
    string target;
    ReapiNodeProperty[] nodeProperties;
}

/// Node property
struct ReapiNodeProperty {
    string name;
    string value;
}

/// Directory structure (Merkle tree node)
struct ReapiDirectory {
    ReapiFileNode[] files;
    ReapiDirectoryNode[] directories;
    ReapiSymlinkNode[] symlinks;
    ReapiNodeProperty[] nodeProperties;
}

/// Directory tree
struct ReapiTree {
    ReapiDirectory root;
    ReapiDirectory[] children;
}

/// Output file in action result
struct ReapiOutputFile {
    string path;
    ReapiDigest digest;
    bool isExecutable;
    ubyte[] contents;  // Inline for small files
    ReapiNodeProperty[] nodeProperties;
}

/// Output directory in action result
struct ReapiOutputDirectory {
    string path;
    ReapiDigest treeDigest;
    bool isTopologicallySorted;
    ReapiDigest rootDirectoryDigest;
}

/// Output symlink
struct ReapiOutputSymlink {
    string path;
    string target;
    ReapiNodeProperty[] nodeProperties;
}

/// Execution timing metadata
struct ReapiExecutionMetadata {
    string worker;
    SysTime queuedTimestamp;
    SysTime workerStartTimestamp;
    SysTime workerCompletedTimestamp;
    SysTime inputFetchStartTimestamp;
    SysTime inputFetchCompletedTimestamp;
    SysTime executionStartTimestamp;
    SysTime executionCompletedTimestamp;
    SysTime outputUploadStartTimestamp;
    SysTime outputUploadCompletedTimestamp;
    Duration virtualExecutionDuration;
}

/// REAPI action result
struct ReapiActionResult {
    ReapiOutputFile[] outputFiles;
    ReapiOutputSymlink[] outputFileSymlinks;
    ReapiOutputSymlink[] outputSymlinks;
    ReapiOutputDirectory[] outputDirectories;
    int exitCode;
    ubyte[] stdoutRaw;
    ReapiDigest stdoutDigest;
    ubyte[] stderrRaw;
    ReapiDigest stderrDigest;
    ReapiExecutionMetadata executionMetadata;
}

/// gRPC-style status
struct ReapiStatus {
    int code;           // 0 = OK
    string message;
    
    static ReapiStatus ok() pure nothrow @safe @nogc => ReapiStatus(0, "");
    static ReapiStatus cancelled() pure @safe => ReapiStatus(1, "Cancelled");
    static ReapiStatus unknown(string msg) pure @safe => ReapiStatus(2, msg);
    static ReapiStatus invalidArgument(string msg) pure @safe => ReapiStatus(3, msg);
    static ReapiStatus deadlineExceeded() pure @safe => ReapiStatus(4, "Deadline exceeded");
    static ReapiStatus notFound(string msg) pure @safe => ReapiStatus(5, msg);
    static ReapiStatus alreadyExists(string msg) pure @safe => ReapiStatus(6, msg);
    static ReapiStatus permissionDenied(string msg) pure @safe => ReapiStatus(7, msg);
    static ReapiStatus resourceExhausted(string msg) pure @safe => ReapiStatus(8, msg);
    static ReapiStatus failedPrecondition(string msg) pure @safe => ReapiStatus(9, msg);
    static ReapiStatus aborted(string msg) pure @safe => ReapiStatus(10, msg);
    static ReapiStatus outOfRange(string msg) pure @safe => ReapiStatus(11, msg);
    static ReapiStatus unimplemented(string msg) pure @safe => ReapiStatus(12, msg);
    static ReapiStatus internal(string msg) pure @safe => ReapiStatus(13, msg);
    static ReapiStatus unavailable(string msg) pure @safe => ReapiStatus(14, msg);
    static ReapiStatus dataLoss(string msg) pure @safe => ReapiStatus(15, msg);
    static ReapiStatus unauthenticated(string msg) pure @safe => ReapiStatus(16, msg);
    
    bool isOk() const pure nothrow @safe @nogc => code == 0;
}

/// Execute request
struct ReapiExecuteRequest {
    string instanceName;
    bool skipCacheLookup;
    ReapiDigest actionDigest;
    ReapiExecutionPolicy executionPolicy;
    ReapiResultsCachePolicy resultsCachePolicy;
}

/// Execution policy
struct ReapiExecutionPolicy {
    int priority;
}

/// Results cache policy
struct ReapiResultsCachePolicy {
    int priority;
}

/// Execute response
struct ReapiExecuteResponse {
    ReapiActionResult result;
    bool cachedResult;
    ReapiStatus status;
    string serverLogs;
    string message;
}

/// Long-running operation
struct ReapiOperation {
    string name;
    bool done;
    ReapiStatus error;
    ReapiExecuteResponse response;  // Set when done
    ReapiExecutionMetadata metadata;
}

/// Capabilities response
struct ReapiServerCapabilities {
    ReapiCacheCapabilities cacheCapabilities;
    ReapiExecutionCapabilities executionCapabilities;
    string lowApiVersion;
    string highApiVersion;
}

/// Cache capabilities
struct ReapiCacheCapabilities {
    DigestFunction[] digestFunctions;
    bool actionCacheUpdateEnabled;
    long maxBatchTotalSizeBytes;
    SymlinkAbsolutePathStrategy symlinkAbsolutePathStrategy;
    Compressor[] supportedCompressors;
}

/// Execution capabilities
struct ReapiExecutionCapabilities {
    DigestFunction digestFunction;
    bool execEnabled;
    string[] supportedNodeProperties;
}

/// Batch blob request
struct ReapiBlobRequest {
    ReapiDigest digest;
    ubyte[] data;
    Compressor compressor;
}

/// Batch blob response
struct ReapiBlobResponse {
    ReapiDigest digest;
    ubyte[] data;
    Compressor compressor;
    ReapiStatus status;
}

