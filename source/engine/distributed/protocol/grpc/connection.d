module engine.distributed.protocol.grpc.connection;

import std.datetime : Duration, seconds, msecs;
import std.conv : to;
import std.string : indexOf;
import std.algorithm : min;
import core.sync.mutex : Mutex;
import engine.distributed.protocol.grpc.http2;
import engine.distributed.protocol.grpc.frame;
import infrastructure.errors : Result, Ok, Err;
import infrastructure.utils.simd.strings : SIMDStrings;

/**
 * gRPC Connection Pool
 * 
 * Manages persistent HTTP/2 connections for gRPC calls.
 * Provides thread-safe connection reuse and automatic reconnection.
 */
final class GrpcConnectionPool {
    private GrpcConnection[string] connections;
    private Mutex mutex;
    private H2Settings defaultSettings;
    
    this() @trusted {
        mutex = new Mutex();
        defaultSettings = H2Settings.init;
        defaultSettings.enablePush = false;  // gRPC doesn't use push
        defaultSettings.maxConcurrentStreams = 100;
    }
    
    /// Get or create connection for endpoint
    Result!(GrpcConnection, string) getConnection(string endpoint) @trusted {
        synchronized (mutex) {
            if (auto conn = endpoint in connections) {
                if (conn.isConnected)
                    return Ok!(GrpcConnection, string)(*conn);
                connections.remove(endpoint);
            }
            
            auto conn = new GrpcConnection(endpoint, defaultSettings);
            auto result = conn.connect();
            if (result.isErr)
                return Err!(GrpcConnection, string)(result.unwrapErr());
            
            connections[endpoint] = conn;
            return Ok!(GrpcConnection, string)(conn);
        }
    }
    
    /// Close all connections
    void closeAll() @trusted {
        synchronized (mutex) {
            foreach (ref conn; connections)
                conn.close();
            connections.clear();
        }
    }
    
    /// Singleton instance
    private static __gshared GrpcConnectionPool _instance;
    
    static GrpcConnectionPool instance() @trusted {
        if (_instance is null)
            _instance = new GrpcConnectionPool();
        return _instance;
    }
}

/**
 * gRPC Connection
 * 
 * Single HTTP/2 connection for gRPC calls with proper framing.
 */
final class GrpcConnection {
    private string endpoint;
    private string host;
    private ushort port;
    private bool useTls;
    private H2Connection h2conn;
    private H2Settings settings;
    private Duration timeout;
    
    this(string endpoint, H2Settings settings = H2Settings.init, Duration timeout = 30.seconds) @trusted {
        this.endpoint = endpoint;
        this.settings = settings;
        this.timeout = timeout;
        this.h2conn = new H2Connection();
        parseEndpoint();
    }
    
    /// SIMD-accelerated URL scheme parsing for high-throughput connection setup
    private void parseEndpoint() @trusted {
        string remaining = endpoint;
        port = 443;
        useTls = true;
        
        // SIMD-accelerated scheme prefix matching
        if (SIMDStrings.startsWith(remaining, "http://")) {
            remaining = remaining[7 .. $];
            port = 80;
            useTls = false;
        } else if (SIMDStrings.startsWith(remaining, "https://")) {
            remaining = remaining[8 .. $];
            useTls = true;
        } else if (SIMDStrings.startsWith(remaining, "grpcs://")) {
            remaining = remaining[8 .. $];
            useTls = true;
        } else if (SIMDStrings.startsWith(remaining, "grpc://")) {
            remaining = remaining[7 .. $];
            port = 443;
            useTls = false;
        }
        
        auto colonIdx = remaining.indexOf(':');
        if (colonIdx >= 0) {
            host = remaining[0 .. colonIdx];
            auto portPart = remaining[colonIdx + 1 .. $];
            auto slashIdx = portPart.indexOf('/');
            if (slashIdx >= 0)
                portPart = portPart[0 .. slashIdx];
            try { port = portPart.to!ushort; } catch (Exception) {}
        } else {
            auto slashIdx = remaining.indexOf('/');
            host = slashIdx >= 0 ? remaining[0 .. slashIdx] : remaining;
        }
    }
    
    /// Connect to server
    Result!string connect() @trusted {
        return h2conn.connect(host, port, timeout);
    }
    
    /// Check if connected
    bool isConnected() @trusted => h2conn.isConnected();
    
    /// Close connection
    void close() @trusted {
        h2conn.close();
    }
    
    /// Authority for gRPC headers
    string authority() const @safe => host ~ ":" ~ port.to!string;
    
    // =========================================================================
    // gRPC Call Types
    // =========================================================================
    
    /// Unary RPC: single request, single response
    Result!(ubyte[], string) unaryCall(
        string servicePath,
        const ubyte[] request,
        Duration callTimeout = Duration.zero
    ) @trusted {
        auto streamResult = h2conn.createStream();
        if (streamResult.isErr)
            return Err!(ubyte[], string)(streamResult.unwrapErr());
        
        auto streamId = streamResult.unwrap();
        auto effectiveTimeout = callTimeout > Duration.zero ? callTimeout : timeout;
        
        // Send headers
        auto headers = GrpcHeaders.requestHeaders(
            authority,
            servicePath,
            GrpcHeaders.GrpcEncodingIdentity,
            GrpcHeaders.formatTimeout(effectiveTimeout.total!"nsecs")
        );
        auto headerBlock = HpackEncoder.encode(headers);
        
        auto sendHeadersResult = h2conn.sendHeaders(streamId, headerBlock, false);
        if (sendHeadersResult.isErr)
            return Err!(ubyte[], string)(sendHeadersResult.unwrapErr());
        
        // Send request with gRPC framing
        auto frame = GrpcFrame.uncompressed(request);
        auto sendDataResult = h2conn.sendData(streamId, frame.encode(), true);
        if (sendDataResult.isErr)
            return Err!(ubyte[], string)(sendDataResult.unwrapErr());
        
        // Receive response
        auto responseResult = h2conn.receiveResponse(streamId);
        if (responseResult.isErr)
            return Err!(ubyte[], string)(responseResult.unwrapErr());
        
        auto response = responseResult.unwrap();
        
        // Check gRPC status
        auto status = response.grpcStatus;
        if (status != 0 && status != -1)
            return Err!(ubyte[], string)("gRPC error " ~ status.to!string ~ ": " ~ response.grpcMessage);
        
        // Decode gRPC frame
        if (response.data.length < GrpcFrame.HeaderSize)
            return Ok!(ubyte[], string)(cast(ubyte[])[]);
        
        auto frameResult = GrpcFrame.decode(response.data, 16 * 1024 * 1024);
        if (frameResult.isErr)
            return Err!(ubyte[], string)(frameResult.unwrapErr());
        
        return Ok!(ubyte[], string)(frameResult.unwrap().message);
    }
    
    /// Server streaming RPC: single request, stream of responses
    Result!(ubyte[][], string) serverStreamingCall(
        string servicePath,
        const ubyte[] request,
        Duration callTimeout = Duration.zero
    ) @trusted {
        auto streamResult = h2conn.createStream();
        if (streamResult.isErr)
            return Err!(ubyte[][], string)(streamResult.unwrapErr());
        
        auto streamId = streamResult.unwrap();
        auto effectiveTimeout = callTimeout > Duration.zero ? callTimeout : timeout;
        
        // Send headers
        auto headers = GrpcHeaders.requestHeaders(
            authority,
            servicePath,
            GrpcHeaders.GrpcEncodingIdentity,
            GrpcHeaders.formatTimeout(effectiveTimeout.total!"nsecs")
        );
        auto headerBlock = HpackEncoder.encode(headers);
        
        auto sendHeadersResult = h2conn.sendHeaders(streamId, headerBlock, false);
        if (sendHeadersResult.isErr)
            return Err!(ubyte[][], string)(sendHeadersResult.unwrapErr());
        
        // Send request
        auto frame = GrpcFrame.uncompressed(request);
        auto sendDataResult = h2conn.sendData(streamId, frame.encode(), true);
        if (sendDataResult.isErr)
            return Err!(ubyte[][], string)(sendDataResult.unwrapErr());
        
        // Receive stream of responses
        ubyte[][] responses;
        auto reader = GrpcStreamReader(16 * 1024 * 1024);
        
        while (true) {
            auto responseResult = h2conn.receiveResponse(streamId);
            if (responseResult.isErr)
                break;
            
            auto response = responseResult.unwrap();
            reader.addData(response.data);
            
            while (reader.hasData) {
                auto msgResult = reader.readMessage();
                if (msgResult.isOk)
                    responses ~= msgResult.unwrap().message;
                else
                    break;
            }
            
            if (response.grpcStatus != -1)
                break;
        }
        
        return Ok!(ubyte[][], string)(responses);
    }
    
    /// Client streaming RPC: stream of requests, single response
    Result!(ClientStream, string) clientStreamingCall(string servicePath) @trusted {
        auto streamResult = h2conn.createStream();
        if (streamResult.isErr)
            return Err!(ClientStream, string)(streamResult.unwrapErr());
        
        auto streamId = streamResult.unwrap();
        
        auto headers = GrpcHeaders.requestHeaders(
            authority,
            servicePath,
            GrpcHeaders.GrpcEncodingIdentity,
            GrpcHeaders.formatTimeout(timeout.total!"nsecs")
        );
        auto headerBlock = HpackEncoder.encode(headers);
        
        auto sendHeadersResult = h2conn.sendHeaders(streamId, headerBlock, false);
        if (sendHeadersResult.isErr)
            return Err!(ClientStream, string)(sendHeadersResult.unwrapErr());
        
        return Ok!(ClientStream, string)(ClientStream(h2conn, streamId));
    }
    
    /// Bidirectional streaming RPC
    Result!(BidiStream, string) bidiStreamingCall(string servicePath) @trusted {
        auto streamResult = h2conn.createStream();
        if (streamResult.isErr)
            return Err!(BidiStream, string)(streamResult.unwrapErr());
        
        auto streamId = streamResult.unwrap();
        
        auto headers = GrpcHeaders.requestHeaders(
            authority,
            servicePath,
            GrpcHeaders.GrpcEncodingIdentity,
            null
        );
        auto headerBlock = HpackEncoder.encode(headers);
        
        auto sendHeadersResult = h2conn.sendHeaders(streamId, headerBlock, false);
        if (sendHeadersResult.isErr)
            return Err!(BidiStream, string)(sendHeadersResult.unwrapErr());
        
        return Ok!(BidiStream, string)(BidiStream(h2conn, streamId));
    }
}

/// Client streaming handle
struct ClientStream {
    private H2Connection conn;
    private uint streamId;
    
    /// Send message (call multiple times)
    Result!string send(const ubyte[] data, bool endStream = false) @trusted {
        auto frame = GrpcFrame.uncompressed(data);
        return conn.sendData(streamId, frame.encode(), endStream);
    }
    
    /// Close send side and get response
    Result!(ubyte[], string) closeAndRecv() @trusted {
        auto result = conn.sendData(streamId, [], true);
        if (result.isErr)
            return Err!(ubyte[], string)(result.unwrapErr());
        
        auto responseResult = conn.receiveResponse(streamId);
        if (responseResult.isErr)
            return Err!(ubyte[], string)(responseResult.unwrapErr());
        
        auto response = responseResult.unwrap();
        if (response.data.length < GrpcFrame.HeaderSize)
            return Ok!(ubyte[], string)(cast(ubyte[])[]);
        
        auto frameResult = GrpcFrame.decode(response.data, 16 * 1024 * 1024);
        if (frameResult.isErr)
            return Err!(ubyte[], string)(frameResult.unwrapErr());
        
        return Ok!(ubyte[], string)(frameResult.unwrap().message);
    }
}

/// Bidirectional streaming handle
struct BidiStream {
    private H2Connection conn;
    private uint streamId;
    private GrpcStreamReader reader;
    
    this(H2Connection conn, uint streamId) @safe {
        this.conn = conn;
        this.streamId = streamId;
        this.reader = GrpcStreamReader(16 * 1024 * 1024);
    }
    
    /// Send message
    Result!string send(const ubyte[] data) @trusted {
        auto frame = GrpcFrame.uncompressed(data);
        return conn.sendData(streamId, frame.encode(), false);
    }
    
    /// Close send side
    Result!string closeSend() @trusted {
        return conn.sendData(streamId, [], true);
    }
    
    /// Receive next message (blocks until available or stream ends)
    Result!(ubyte[], string) recv() @trusted {
        while (!reader.hasData) {
            auto responseResult = conn.receiveResponse(streamId);
            if (responseResult.isErr)
                return Err!(ubyte[], string)(responseResult.unwrapErr());
            
            auto response = responseResult.unwrap();
            reader.addData(response.data);
            
            if (response.grpcStatus != -1)
                break;
        }
        
        if (!reader.hasData)
            return Err!(ubyte[], string)("Stream ended");
        
        auto msgResult = reader.readMessage();
        if (msgResult.isErr)
            return Err!(ubyte[], string)(msgResult.unwrapErr());
        
        return Ok!(ubyte[], string)(msgResult.unwrap().message);
    }
}


