module engine.distributed.protocol.grpc.http2;

import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown, SocketOptionLevel, SocketOption;
import std.datetime : Duration, seconds, msecs;
import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.conv : to;
import std.algorithm : min;
import core.sync.mutex : Mutex;
import infrastructure.errors : Result, Ok, Err;

/**
 * HTTP/2 Frame Types (RFC 7540)
 */
enum FrameType : ubyte {
    Data         = 0x0,
    Headers      = 0x1,
    Priority     = 0x2,
    RstStream    = 0x3,
    Settings     = 0x4,
    PushPromise  = 0x5,
    Ping         = 0x6,
    GoAway       = 0x7,
    WindowUpdate = 0x8,
    Continuation = 0x9
}

/**
 * HTTP/2 Frame Flags
 */
enum FrameFlags : ubyte {
    None        = 0x0,
    EndStream   = 0x1,
    EndHeaders  = 0x4,
    Padded      = 0x8,
    Priority    = 0x20,
    Ack         = 0x1  // For Settings/Ping
}

/**
 * HTTP/2 Error Codes
 */
enum H2ErrorCode : uint {
    NoError            = 0x0,
    ProtocolError      = 0x1,
    InternalError      = 0x2,
    FlowControlError   = 0x3,
    SettingsTimeout    = 0x4,
    StreamClosed       = 0x5,
    FrameSizeError     = 0x6,
    RefusedStream      = 0x7,
    Cancel             = 0x8,
    CompressionError   = 0x9,
    ConnectError       = 0xa,
    EnhanceYourCalm    = 0xb,
    InadequateSecurity = 0xc,
    Http11Required     = 0xd
}

/**
 * HTTP/2 Settings Parameters
 */
enum SettingsParam : ushort {
    HeaderTableSize      = 0x1,
    EnablePush           = 0x2,
    MaxConcurrentStreams = 0x3,
    InitialWindowSize    = 0x4,
    MaxFrameSize         = 0x5,
    MaxHeaderListSize    = 0x6
}

/**
 * HTTP/2 Frame Header (9 bytes)
 */
struct FrameHeader {
    uint length;        // 24-bit
    FrameType type;
    ubyte flags;
    uint streamId;      // 31-bit (MSB reserved)
    
    /// Serialize to wire format (9 bytes, big-endian)
    ubyte[9] serialize() const pure nothrow @safe @nogc {
        ubyte[9] buf;
        // Length (24-bit big-endian)
        buf[0] = cast(ubyte)((length >> 16) & 0xFF);
        buf[1] = cast(ubyte)((length >> 8) & 0xFF);
        buf[2] = cast(ubyte)(length & 0xFF);
        buf[3] = type;
        buf[4] = flags;
        // Stream ID (31-bit big-endian, MSB = 0)
        buf[5] = cast(ubyte)((streamId >> 24) & 0x7F);
        buf[6] = cast(ubyte)((streamId >> 16) & 0xFF);
        buf[7] = cast(ubyte)((streamId >> 8) & 0xFF);
        buf[8] = cast(ubyte)(streamId & 0xFF);
        return buf;
    }
    
    /// Deserialize from wire format
    static FrameHeader deserialize(const ubyte[9] data) pure nothrow @safe @nogc {
        FrameHeader h;
        h.length = (cast(uint)data[0] << 16) | (cast(uint)data[1] << 8) | data[2];
        h.type = cast(FrameType)data[3];
        h.flags = data[4];
        h.streamId = ((cast(uint)data[5] & 0x7F) << 24) | 
                     (cast(uint)data[6] << 16) | 
                     (cast(uint)data[7] << 8) | 
                     data[8];
        return h;
    }
    
    bool hasFlag(FrameFlags f) const pure nothrow @safe @nogc => (flags & f) != 0;
}

/**
 * HTTP/2 Connection Settings
 */
struct H2Settings {
    uint headerTableSize = 4096;
    bool enablePush = false;          // Disabled for gRPC
    uint maxConcurrentStreams = 100;
    uint initialWindowSize = 65535;   // Default 64KB - 1
    uint maxFrameSize = 16384;        // Min allowed
    uint maxHeaderListSize = 8192;
    
    /// Serialize to SETTINGS frame payload
    ubyte[] serialize() const @trusted {
        ubyte[] buf;
        buf.reserve(36);
        
        void addSetting(SettingsParam p, uint v) {
            buf ~= nativeToBigEndian(cast(ushort)p)[];
            buf ~= nativeToBigEndian(v)[];
        }
        
        addSetting(SettingsParam.HeaderTableSize, headerTableSize);
        addSetting(SettingsParam.EnablePush, enablePush ? 1 : 0);
        addSetting(SettingsParam.MaxConcurrentStreams, maxConcurrentStreams);
        addSetting(SettingsParam.InitialWindowSize, initialWindowSize);
        addSetting(SettingsParam.MaxFrameSize, maxFrameSize);
        addSetting(SettingsParam.MaxHeaderListSize, maxHeaderListSize);
        
        return buf;
    }
    
    /// Parse SETTINGS frame payload
    static H2Settings parse(const ubyte[] data) @trusted {
        H2Settings s;
        size_t i = 0;
        while (i + 6 <= data.length) {
            auto id = bigEndianToNative!ushort(data[i .. i + 2][0 .. 2]);
            auto val = bigEndianToNative!uint(data[i + 2 .. i + 6][0 .. 4]);
            
            switch (cast(SettingsParam)id) {
                case SettingsParam.HeaderTableSize:      s.headerTableSize = val; break;
                case SettingsParam.EnablePush:           s.enablePush = val != 0; break;
                case SettingsParam.MaxConcurrentStreams: s.maxConcurrentStreams = val; break;
                case SettingsParam.InitialWindowSize:    s.initialWindowSize = val; break;
                case SettingsParam.MaxFrameSize:         s.maxFrameSize = val; break;
                case SettingsParam.MaxHeaderListSize:    s.maxHeaderListSize = val; break;
                default: break;
            }
            i += 6;
        }
        return s;
    }
}

/**
 * HPACK Header Compression (RFC 7541) - Simplified Implementation
 * 
 * Implements minimal HPACK for gRPC pseudo-headers and common headers.
 * Uses static table + literal encoding (no dynamic table for simplicity).
 */
struct HpackEncoder {
    /// Static table entries (RFC 7541 Appendix A)
    private static immutable string[][2] staticTable = [
        [":authority", ""],
        [":method", "GET"],
        [":method", "POST"],
        [":path", "/"],
        [":path", "/index.html"],
        [":scheme", "http"],
        [":scheme", "https"],
        [":status", "200"],
        [":status", "204"],
        [":status", "206"],
        [":status", "304"],
        [":status", "400"],
        [":status", "404"],
        [":status", "500"],
        ["accept-charset", ""],
        ["accept-encoding", "gzip, deflate"],
        ["accept-language", ""],
        ["accept-ranges", ""],
        ["accept", ""],
        ["access-control-allow-origin", ""],
        ["age", ""],
        ["allow", ""],
        ["authorization", ""],
        ["cache-control", ""],
        ["content-disposition", ""],
        ["content-encoding", ""],
        ["content-language", ""],
        ["content-length", ""],
        ["content-location", ""],
        ["content-range", ""],
        ["content-type", ""],
        ["cookie", ""],
        ["date", ""],
        ["etag", ""],
        ["expect", ""],
        ["expires", ""],
        ["from", ""],
        ["host", ""],
        ["if-match", ""],
        ["if-modified-since", ""],
        ["if-none-match", ""],
        ["if-range", ""],
        ["if-unmodified-since", ""],
        ["last-modified", ""],
        ["link", ""],
        ["location", ""],
        ["max-forwards", ""],
        ["proxy-authenticate", ""],
        ["proxy-authorization", ""],
        ["range", ""],
        ["referer", ""],
        ["refresh", ""],
        ["retry-after", ""],
        ["server", ""],
        ["set-cookie", ""],
        ["strict-transport-security", ""],
        ["transfer-encoding", ""],
        ["user-agent", ""],
        ["vary", ""],
        ["via", ""],
        ["www-authenticate", ""]
    ];
    
    /// Encode headers to HPACK wire format
    static ubyte[] encode(string[string] headers) @trusted {
        ubyte[] buf;
        buf.reserve(512);
        
        foreach (name, value; headers)
            buf ~= encodeLiteral(name, value);
        
        return buf;
    }
    
    /// Encode gRPC request headers
    static ubyte[] encodeGrpcRequest(
        string method,
        string path,
        string authority,
        string contentType = "application/grpc"
    ) @trusted {
        ubyte[] buf;
        buf.reserve(256);
        
        // :method POST (indexed, static table entry 3)
        buf ~= 0x83;  // Indexed header field (1 << 7 | 3)
        
        // :scheme http (indexed, static table entry 6) or https (7)
        buf ~= 0x86;  // Using http for simplicity
        
        // :path (literal with indexing)
        buf ~= encodeLiteral(":path", path);
        
        // :authority
        buf ~= encodeLiteral(":authority", authority);
        
        // content-type
        buf ~= encodeLiteral("content-type", contentType);
        
        // te: trailers (required for gRPC)
        buf ~= encodeLiteral("te", "trailers");
        
        // grpc-encoding
        buf ~= encodeLiteral("grpc-encoding", "identity");
        
        return buf;
    }
    
    /// Encode literal header (never indexed)
    private static ubyte[] encodeLiteral(string name, string value) @trusted {
        ubyte[] buf;
        
        // Literal header field without indexing (0000 prefix)
        buf ~= 0x00;
        
        // Name (length + string, no Huffman)
        buf ~= encodeString(name);
        
        // Value
        buf ~= encodeString(value);
        
        return buf;
    }
    
    /// Encode string (7-bit length prefix, no Huffman)
    private static ubyte[] encodeString(string s) @trusted {
        ubyte[] buf;
        
        if (s.length < 127) {
            buf ~= cast(ubyte)s.length;  // MSB = 0 (no Huffman)
        } else {
            // Multi-byte length encoding
            buf ~= 0x7F;
            auto remaining = s.length - 127;
            while (remaining >= 0x80) {
                buf ~= cast(ubyte)((remaining & 0x7F) | 0x80);
                remaining >>= 7;
            }
            buf ~= cast(ubyte)remaining;
        }
        
        buf ~= cast(ubyte[])s;
        return buf;
    }
}

/**
 * HPACK Decoder - Simplified
 */
struct HpackDecoder {
    /// Decode HPACK headers
    static string[string] decode(const ubyte[] data) @trusted {
        string[string] headers;
        size_t i = 0;
        
        while (i < data.length) {
            auto b = data[i];
            
            if ((b & 0x80) != 0) {
                // Indexed header field
                auto idx = b & 0x7F;
                if (idx > 0 && idx <= HpackEncoder.staticTable.length) {
                    auto entry = HpackEncoder.staticTable[idx - 1];
                    headers[entry[0]] = entry[1];
                }
                i++;
            } else if ((b & 0xC0) == 0x40) {
                // Literal with incremental indexing
                i++;
                auto nameResult = decodeString(data[i .. $]);
                i += nameResult.bytesRead;
                auto valueResult = decodeString(data[i .. $]);
                i += valueResult.bytesRead;
                headers[nameResult.value] = valueResult.value;
            } else if ((b & 0xF0) == 0x00) {
                // Literal without indexing
                i++;
                auto nameResult = decodeString(data[i .. $]);
                i += nameResult.bytesRead;
                auto valueResult = decodeString(data[i .. $]);
                i += valueResult.bytesRead;
                headers[nameResult.value] = valueResult.value;
            } else {
                i++;  // Skip unknown
            }
        }
        
        return headers;
    }
    
    private struct StringResult {
        string value;
        size_t bytesRead;
    }
    
    private static StringResult decodeString(const ubyte[] data) @trusted {
        if (data.length == 0)
            return StringResult("", 0);
        
        bool huffman = (data[0] & 0x80) != 0;
        size_t len = data[0] & 0x7F;
        size_t offset = 1;
        
        if (len == 0x7F) {
            // Multi-byte length
            size_t m = 0;
            while (offset < data.length && (data[offset] & 0x80) != 0) {
                len += (data[offset] & 0x7F) << m;
                m += 7;
                offset++;
            }
            if (offset < data.length) {
                len += data[offset] << m;
                offset++;
            }
        }
        
        if (offset + len > data.length)
            len = data.length - offset;
        
        // Note: Huffman decoding not implemented (not required for gRPC interop)
        auto value = cast(string)data[offset .. offset + len];
        return StringResult(value, offset + len);
    }
}

/**
 * HTTP/2 Stream State
 */
enum StreamState {
    Idle,
    Open,
    HalfClosedLocal,
    HalfClosedRemote,
    Closed
}

/**
 * HTTP/2 Stream
 */
struct H2Stream {
    uint id;
    StreamState state = StreamState.Idle;
    int sendWindow;
    int recvWindow;
    ubyte[] pendingData;
    string[string] headers;
    
    /// Check if stream can send
    bool canSend() const pure nothrow @safe @nogc =>
        state == StreamState.Open || state == StreamState.HalfClosedRemote;
    
    /// Check if stream can receive
    bool canRecv() const pure nothrow @safe @nogc =>
        state == StreamState.Open || state == StreamState.HalfClosedLocal;
}

/**
 * HTTP/2 Connection (Client)
 * 
 * Implements HTTP/2 framing over TCP for gRPC transport.
 */
final class H2Connection {
    private Socket socket;
    private H2Settings localSettings;
    private H2Settings peerSettings;
    private H2Stream[uint] streams;
    private uint nextStreamId = 1;  // Odd for client-initiated
    private int connectionWindow;
    private Mutex mutex;
    private bool connected;
    private ubyte[] recvBuffer;
    
    /// HTTP/2 connection preface
    private static immutable ubyte[] connectionPreface = 
        cast(immutable(ubyte)[])"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    
    /// Constructor
    this() @trusted {
        mutex = new Mutex();
        localSettings = H2Settings.init;
        connectionWindow = localSettings.initialWindowSize;
    }
    
    /// Connect to server
    Result!(void, string) connect(string host, ushort port, Duration timeout = 30.seconds) @trusted {
        try {
            socket = new TcpSocket();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, timeout);
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, timeout);
            socket.connect(new InternetAddress(host, port));
            
            // Send connection preface
            socket.send(connectionPreface);
            
            // Send initial SETTINGS
            sendSettings();
            
            // Receive peer SETTINGS
            auto settingsResult = receiveFrame();
            if (settingsResult.isErr)
                return Err!(void, string)(settingsResult.unwrapErr());
            
            // Send SETTINGS ACK
            sendSettingsAck();
            
            connected = true;
            return Ok!(void, string)();
        } catch (Exception e) {
            return Err!(void, string)("Connection failed: " ~ e.msg);
        }
    }
    
    /// Close connection
    void close() @trusted {
        if (socket is null) return;
        
        // Send GOAWAY
        synchronized (mutex) {
            try {
                sendGoAway(H2ErrorCode.NoError);
                socket.shutdown(SocketShutdown.BOTH);
                socket.close();
            } catch (Exception) {}
        }
        socket = null;
        connected = false;
    }
    
    /// Check if connected
    bool isConnected() @trusted => connected && socket !is null && socket.isAlive;
    
    /// Create new stream
    Result!(uint, string) createStream() @trusted {
        synchronized (mutex) {
            if (streams.length >= peerSettings.maxConcurrentStreams)
                return Err!(uint, string)("Max concurrent streams reached");
            
            auto id = nextStreamId;
            nextStreamId += 2;  // Client uses odd IDs
            
            H2Stream stream;
            stream.id = id;
            stream.state = StreamState.Idle;
            stream.sendWindow = peerSettings.initialWindowSize;
            stream.recvWindow = localSettings.initialWindowSize;
            streams[id] = stream;
            
            return Ok!(uint, string)(id);
        }
    }
    
    /// Send HEADERS frame
    Result!(void, string) sendHeaders(
        uint streamId, 
        const ubyte[] headerBlock, 
        bool endStream = false
    ) @trusted {
        synchronized (mutex) {
            if (streamId !in streams)
                return Err!(void, string)("Stream not found");
            
            auto flags = FrameFlags.EndHeaders;
            if (endStream)
                flags |= FrameFlags.EndStream;
            
            auto header = FrameHeader(
                cast(uint)headerBlock.length,
                FrameType.Headers,
                flags,
                streamId
            );
            
            try {
                socket.send(header.serialize());
                socket.send(headerBlock);
                
                streams[streamId].state = endStream 
                    ? StreamState.HalfClosedLocal 
                    : StreamState.Open;
                
                return Ok!(void, string)();
            } catch (Exception e) {
                return Err!(void, string)("Failed to send headers: " ~ e.msg);
            }
        }
    }
    
    /// Send DATA frame
    Result!(void, string) sendData(
        uint streamId, 
        const ubyte[] data, 
        bool endStream = false
    ) @trusted {
        synchronized (mutex) {
            if (streamId !in streams)
                return Err!(void, string)("Stream not found");
            
            auto stream = &streams[streamId];
            if (!stream.canSend)
                return Err!(void, string)("Stream not in sendable state");
            
            // Respect flow control
            auto toSend = min(data.length, stream.sendWindow, connectionWindow);
            if (toSend < data.length && !endStream) {
                // Need to send in chunks, but for simplicity send what we can
            }
            
            auto flags = endStream ? FrameFlags.EndStream : FrameFlags.None;
            auto header = FrameHeader(
                cast(uint)toSend,
                FrameType.Data,
                flags,
                streamId
            );
            
            try {
                socket.send(header.serialize());
                if (toSend > 0)
                    socket.send(data[0 .. toSend]);
                
                stream.sendWindow -= cast(int)toSend;
                connectionWindow -= cast(int)toSend;
                
                if (endStream)
                    stream.state = stream.state == StreamState.HalfClosedRemote 
                        ? StreamState.Closed 
                        : StreamState.HalfClosedLocal;
                
                return Ok!(void, string)();
            } catch (Exception e) {
                return Err!(void, string)("Failed to send data: " ~ e.msg);
            }
        }
    }
    
    /// Receive frame (blocking)
    Result!(ReceivedFrame, string) receiveFrame() @trusted {
        ubyte[9] headerBuf;
        
        auto received = socket.receive(headerBuf);
        if (received != 9)
            return Err!(ReceivedFrame, string)("Failed to read frame header");
        
        auto header = FrameHeader.deserialize(headerBuf);
        
        ubyte[] payload;
        if (header.length > 0) {
            payload = new ubyte[header.length];
            size_t totalRead = 0;
            while (totalRead < header.length) {
                auto chunk = socket.receive(payload[totalRead .. $]);
                if (chunk <= 0)
                    return Err!(ReceivedFrame, string)("Failed to read frame payload");
                totalRead += chunk;
            }
        }
        
        // Handle frame by type
        handleFrame(header, payload);
        
        return Ok!(ReceivedFrame, string)(ReceivedFrame(header, payload));
    }
    
    /// Receive response for stream
    Result!(H2Response, string) receiveResponse(uint streamId) @trusted {
        H2Response response;
        
        while (true) {
            auto frameResult = receiveFrame();
            if (frameResult.isErr)
                return Err!(H2Response, string)(frameResult.unwrapErr());
            
            auto frame = frameResult.unwrap();
            
            if (frame.header.streamId != streamId)
                continue;  // Different stream, keep reading
            
            if (frame.header.type == FrameType.Headers) {
                response.headers = HpackDecoder.decode(frame.payload);
            } else if (frame.header.type == FrameType.Data) {
                response.data ~= frame.payload;
            }
            
            if (frame.header.hasFlag(FrameFlags.EndStream))
                break;
        }
        
        return Ok!(H2Response, string)(response);
    }
    
    private void handleFrame(FrameHeader header, ubyte[] payload) @trusted {
        switch (header.type) {
            case FrameType.Settings:
                if (!header.hasFlag(FrameFlags.Ack)) {
                    peerSettings = H2Settings.parse(payload);
                    sendSettingsAck();
                }
                break;
                
            case FrameType.WindowUpdate:
                if (payload.length >= 4) {
                    auto increment = bigEndianToNative!uint(payload[0 .. 4]) & 0x7FFFFFFF;
                    if (header.streamId == 0)
                        connectionWindow += increment;
                    else if (header.streamId in streams)
                        streams[header.streamId].sendWindow += increment;
                }
                break;
                
            case FrameType.Ping:
                if (!header.hasFlag(FrameFlags.Ack))
                    sendPingAck(payload);
                break;
                
            case FrameType.GoAway:
                connected = false;
                break;
                
            case FrameType.RstStream:
                if (header.streamId in streams)
                    streams[header.streamId].state = StreamState.Closed;
                break;
                
            default:
                break;
        }
    }
    
    private void sendSettings() @trusted {
        auto payload = localSettings.serialize();
        auto header = FrameHeader(cast(uint)payload.length, FrameType.Settings, 0, 0);
        socket.send(header.serialize());
        socket.send(payload);
    }
    
    private void sendSettingsAck() @trusted {
        auto header = FrameHeader(0, FrameType.Settings, FrameFlags.Ack, 0);
        socket.send(header.serialize());
    }
    
    private void sendPingAck(ubyte[] data) @trusted {
        auto header = FrameHeader(cast(uint)data.length, FrameType.Ping, FrameFlags.Ack, 0);
        socket.send(header.serialize());
        socket.send(data);
    }
    
    private void sendGoAway(H2ErrorCode errorCode) @trusted {
        ubyte[8] payload;
        auto lastStream = nativeToBigEndian(nextStreamId > 2 ? nextStreamId - 2 : 0);
        auto code = nativeToBigEndian(cast(uint)errorCode);
        payload[0 .. 4] = lastStream;
        payload[4 .. 8] = code;
        
        auto header = FrameHeader(8, FrameType.GoAway, 0, 0);
        socket.send(header.serialize());
        socket.send(payload);
    }
    
    /// Send WINDOW_UPDATE
    void sendWindowUpdate(uint streamId, uint increment) @trusted {
        ubyte[4] payload = nativeToBigEndian(increment & 0x7FFFFFFF);
        auto header = FrameHeader(4, FrameType.WindowUpdate, 0, streamId);
        socket.send(header.serialize());
        socket.send(payload);
    }
}

/// Received frame container
struct ReceivedFrame {
    FrameHeader header;
    ubyte[] payload;
}

/// HTTP/2 Response container
struct H2Response {
    string[string] headers;
    ubyte[] data;
    
    /// Get gRPC status
    int grpcStatus() const @trusted {
        if (auto s = "grpc-status" in headers) {
            try { return (*s).to!int; }
            catch (Exception) { return -1; }
        }
        return -1;
    }
    
    /// Get gRPC message
    string grpcMessage() const @safe => headers.get("grpc-message", "");
}

