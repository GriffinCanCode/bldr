module engine.distributed.protocol.grpc.frame;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.array : Appender;
import infrastructure.errors : Result, Ok, Err;

/**
 * gRPC Wire Format (Length-Prefixed Message Framing)
 * 
 * Each gRPC message has a 5-byte header:
 * - 1 byte: Compressed flag (0 = uncompressed, 1 = compressed)
 * - 4 bytes: Message length (big-endian uint32)
 * 
 * Followed by the message payload (protobuf-encoded).
 */
struct GrpcFrame {
    bool compressed;
    ubyte[] message;
    
    /// Frame header size
    enum HeaderSize = 5;
    
    /// Maximum message size (4MB default)
    enum DefaultMaxSize = 4 * 1024 * 1024;
    
    /// Encode frame to wire format
    ubyte[] encode() const @trusted {
        ubyte[] buf;
        buf.reserve(HeaderSize + message.length);
        
        // Compressed flag
        buf ~= compressed ? 1 : 0;
        
        // Message length (big-endian)
        buf ~= nativeToBigEndian(cast(uint)message.length)[];
        
        // Message payload
        buf ~= message;
        
        return buf;
    }
    
    /// Decode frame from wire format
    static Result!(GrpcFrame, string) decode(const ubyte[] data, size_t maxSize = DefaultMaxSize) @trusted {
        if (data.length < HeaderSize)
            return Err!(GrpcFrame, string)("Insufficient data for gRPC frame header");
        
        GrpcFrame frame;
        frame.compressed = data[0] != 0;
        
        auto msgLen = bigEndianToNative!uint(data[1 .. 5][0 .. 4]);
        
        if (msgLen > maxSize)
            return Err!(GrpcFrame, string)("Message exceeds maximum size");
        
        if (data.length < HeaderSize + msgLen)
            return Err!(GrpcFrame, string)("Insufficient data for gRPC message");
        
        frame.message = data[HeaderSize .. HeaderSize + msgLen].dup;
        return Ok!(GrpcFrame, string)(frame);
    }
    
    /// Calculate total encoded size
    size_t encodedSize() const pure nothrow @safe @nogc => HeaderSize + message.length;
    
    /// Create uncompressed frame
    static GrpcFrame uncompressed(const ubyte[] msg) @trusted {
        GrpcFrame f;
        f.compressed = false;
        f.message = msg.dup;
        return f;
    }
}

/**
 * gRPC Stream Reader
 * 
 * Handles streaming message parsing from HTTP/2 DATA frames.
 */
struct GrpcStreamReader {
    private Appender!(ubyte[]) buffer;
    private size_t maxMessageSize;
    
    /// Constructor
    this(size_t maxSize) @safe {
        maxMessageSize = maxSize;
        buffer = Appender!(ubyte[])();
    }
    
    /// Add data to buffer
    void addData(const ubyte[] data) @trusted {
        buffer ~= data;
    }
    
    /// Try to read next complete message
    Result!(GrpcFrame, string) readMessage() @trusted {
        if (buffer.data.length < GrpcFrame.HeaderSize)
            return Err!(GrpcFrame, string)("Need more data");
        
        // Peek at message length
        auto msgLen = bigEndianToNative!uint(buffer.data[1 .. 5][0 .. 4]);
        
        if (msgLen > maxMessageSize)
            return Err!(GrpcFrame, string)("Message exceeds maximum size");
        
        auto totalLen = GrpcFrame.HeaderSize + msgLen;
        if (buffer.data.length < totalLen)
            return Err!(GrpcFrame, string)("Need more data");
        
        // Parse frame
        auto frameResult = GrpcFrame.decode(buffer.data[0 .. totalLen], maxMessageSize);
        if (frameResult.isErr)
            return frameResult;
        
        // Remove consumed data
        buffer = Appender!(ubyte[])();
        if (totalLen < buffer.data.length)
            buffer ~= buffer.data[totalLen .. $];
        
        return frameResult;
    }
    
    /// Check if more messages might be available
    bool hasData() const @safe => buffer.data.length >= GrpcFrame.HeaderSize;
    
    /// Clear buffer
    void clear() @safe {
        buffer = Appender!(ubyte[])();
    }
}

/**
 * gRPC Status Codes (from grpc/status.h)
 */
enum GrpcStatusCode : int {
    Ok                 = 0,
    Cancelled          = 1,
    Unknown            = 2,
    InvalidArgument    = 3,
    DeadlineExceeded   = 4,
    NotFound           = 5,
    AlreadyExists      = 6,
    PermissionDenied   = 7,
    ResourceExhausted  = 8,
    FailedPrecondition = 9,
    Aborted            = 10,
    OutOfRange         = 11,
    Unimplemented      = 12,
    Internal           = 13,
    Unavailable        = 14,
    DataLoss           = 15,
    Unauthenticated    = 16
}

/**
 * gRPC Method Descriptor
 */
struct GrpcMethod {
    string service;       // Full service name (e.g., "build.bazel.remote.execution.v2.Execution")
    string method;        // Method name (e.g., "Execute")
    bool clientStreaming; // Client sends stream of messages
    bool serverStreaming; // Server sends stream of messages
    
    /// Get full path for HTTP/2 :path pseudo-header
    string path() const @safe => "/" ~ service ~ "/" ~ method;
    
    /// Parse from path
    static GrpcMethod fromPath(string path) @trusted {
        GrpcMethod m;
        if (path.length > 1 && path[0] == '/') {
            import std.string : lastIndexOf;
            auto lastSlash = path.lastIndexOf('/');
            if (lastSlash > 0) {
                m.service = path[1 .. lastSlash];
                m.method = path[lastSlash + 1 .. $];
            }
        }
        return m;
    }
}

/**
 * Common gRPC Headers
 */
struct GrpcHeaders {
    static immutable string ContentType = "application/grpc";
    static immutable string ContentTypeProto = "application/grpc+proto";
    static immutable string TeTrailers = "trailers";
    static immutable string GrpcEncodingIdentity = "identity";
    static immutable string GrpcEncodingGzip = "gzip";
    static immutable string GrpcEncodingDeflate = "deflate";
    
    /// Build request headers
    static string[string] requestHeaders(
        string authority,
        string path,
        string encoding = GrpcEncodingIdentity,
        string timeout = null
    ) @safe {
        string[string] h;
        h[":method"] = "POST";
        h[":scheme"] = "http";
        h[":path"] = path;
        h[":authority"] = authority;
        h["content-type"] = ContentTypeProto;
        h["te"] = TeTrailers;
        h["grpc-encoding"] = encoding;
        h["grpc-accept-encoding"] = "identity,gzip,deflate";
        
        if (timeout !is null)
            h["grpc-timeout"] = timeout;
        
        return h;
    }
    
    /// Build response headers
    static string[string] responseHeaders(
        GrpcStatusCode status = GrpcStatusCode.Ok,
        string message = null
    ) @safe {
        import std.conv : to;
        
        string[string] h;
        h[":status"] = "200";
        h["content-type"] = ContentTypeProto;
        h["grpc-status"] = status.to!string;
        
        if (message !is null)
            h["grpc-message"] = message;
        
        return h;
    }
    
    /// Parse gRPC timeout header value
    /// Format: <value><unit> where unit is H(ours), M(inutes), S(econds), m(illis), u(micros), n(anos)
    static long parseTimeout(string timeout) @trusted {
        if (timeout.length < 2)
            return 0;
        
        import std.conv : to;
        
        auto unit = timeout[$ - 1];
        auto value = timeout[0 .. $ - 1].to!long;
        
        switch (unit) {
            case 'H': return value * 3600_000_000_000L;
            case 'M': return value * 60_000_000_000L;
            case 'S': return value * 1_000_000_000L;
            case 'm': return value * 1_000_000L;
            case 'u': return value * 1_000L;
            case 'n': return value;
            default: return 0;
        }
    }
    
    /// Format timeout value for header
    static string formatTimeout(long nanoseconds) @trusted {
        import std.conv : to;
        
        if (nanoseconds >= 3600_000_000_000L)
            return (nanoseconds / 3600_000_000_000L).to!string ~ "H";
        if (nanoseconds >= 60_000_000_000L)
            return (nanoseconds / 60_000_000_000L).to!string ~ "M";
        if (nanoseconds >= 1_000_000_000L)
            return (nanoseconds / 1_000_000_000L).to!string ~ "S";
        if (nanoseconds >= 1_000_000L)
            return (nanoseconds / 1_000_000L).to!string ~ "m";
        if (nanoseconds >= 1_000L)
            return (nanoseconds / 1_000L).to!string ~ "u";
        return nanoseconds.to!string ~ "n";
    }
}

/**
 * REAPI Service Definitions
 */
struct ReapiServices {
    // Service names
    static immutable string Execution = "build.bazel.remote.execution.v2.Execution";
    static immutable string ActionCache = "build.bazel.remote.execution.v2.ActionCache";
    static immutable string CAS = "build.bazel.remote.execution.v2.ContentAddressableStorage";
    static immutable string Capabilities = "build.bazel.remote.execution.v2.Capabilities";
    static immutable string ByteStream = "google.bytestream.ByteStream";
    
    /// Execution service methods
    static GrpcMethod execute() @safe => GrpcMethod(Execution, "Execute", false, true);
    static GrpcMethod waitExecution() @safe => GrpcMethod(Execution, "WaitExecution", false, true);
    
    /// ActionCache service methods
    static GrpcMethod getActionResult() @safe => GrpcMethod(ActionCache, "GetActionResult", false, false);
    static GrpcMethod updateActionResult() @safe => GrpcMethod(ActionCache, "UpdateActionResult", false, false);
    
    /// CAS service methods
    static GrpcMethod findMissingBlobs() @safe => GrpcMethod(CAS, "FindMissingBlobs", false, false);
    static GrpcMethod batchUpdateBlobs() @safe => GrpcMethod(CAS, "BatchUpdateBlobs", false, false);
    static GrpcMethod batchReadBlobs() @safe => GrpcMethod(CAS, "BatchReadBlobs", false, false);
    static GrpcMethod getTree() @safe => GrpcMethod(CAS, "GetTree", false, true);
    
    /// Capabilities service methods
    static GrpcMethod getCapabilities() @safe => GrpcMethod(Capabilities, "GetCapabilities", false, false);
    
    /// ByteStream service methods
    static GrpcMethod read() @safe => GrpcMethod(ByteStream, "Read", false, true);
    static GrpcMethod write() @safe => GrpcMethod(ByteStream, "Write", true, false);
}

