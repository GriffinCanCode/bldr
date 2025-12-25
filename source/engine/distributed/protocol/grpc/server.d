module engine.distributed.protocol.grpc.server;

import std.socket : Socket, TcpSocket, InternetAddress, SocketShutdown, SocketOptionLevel, SocketOption;
import std.datetime : Duration, seconds;
import std.conv : to;
import std.algorithm : startsWith;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.grpc.http2;
import engine.distributed.protocol.grpc.frame;
import engine.distributed.protocol.grpc.codec;
import engine.distributed.protocol.grpc.types;
import infrastructure.errors;

/// gRPC server configuration
struct GrpcServerConfig {
    string address;                          // Bind address (host:port)
    bool useTls = false;                     // Use TLS?
    string serverCert;                       // Server certificate (PEM)
    string serverKey;                        // Server private key (PEM)
    string rootCerts;                        // Root CA for client auth (PEM)
    bool requireClientAuth = false;          // Require client certificates?
    uint maxConcurrentStreams = 100;         // Max concurrent streams per connection
    Duration keepaliveTime = 30.seconds;     // Keepalive ping interval
    Duration keepaliveTimeout = 10.seconds;  // Keepalive timeout
    size_t maxMessageSize = 4 * 1024 * 1024; // 4MB default
    uint workerThreads = 4;                  // Number of worker threads
    
    static GrpcServerConfig insecure(string address) {
        GrpcServerConfig c;
        c.address = address;
        return c;
    }
    
    /// Parse host and port from address
    auto parseAddress() const @trusted {
        struct Result { string host; ushort port; }
        
        import std.string : indexOf;
        auto colonIdx = address.indexOf(':');
        if (colonIdx > 0) {
            try {
                return Result(address[0 .. colonIdx], address[colonIdx + 1 .. $].to!ushort);
            } catch (Exception) {}
        }
        return Result("0.0.0.0", 50051);  // Default gRPC port
    }
}

/// Service handler interface for gRPC services
interface GrpcServiceHandler {
    /// Get the service name
    string serviceName() const @safe;
    
    /// Handle a unary RPC call
    Result!(ubyte[], string) handleUnary(string method, const ubyte[] request) @trusted;
    
    /// Handle a server streaming RPC call (returns array of responses)
    Result!(ubyte[][], string) handleServerStreaming(string method, const ubyte[] request) @trusted;
}

/// Service registration entry
private struct ServiceEntry {
    GrpcServiceHandler handler;
    string serviceName;
}

/**
 * gRPC Server Implementation
 * 
 * HTTP/2-based server supporting REAPI and Builder's native protocol.
 */
final class GrpcServer {
    private GrpcServerConfig config;
    private Socket listener;
    private bool running;
    private Mutex mutex;
    private ServiceEntry[] services;
    private Thread[] workerThreads;
    private Thread acceptThread;
    
    /// HTTP/2 connection preface
    private static immutable ubyte[] connectionPreface = 
        cast(immutable(ubyte)[])"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    
    this(GrpcServerConfig config) @trusted {
        this.config = config;
        this.mutex = new Mutex();
    }
    
    /// Register a service handler
    void registerService(GrpcServiceHandler handler) @trusted {
        synchronized (mutex) {
            services ~= ServiceEntry(handler, handler.serviceName());
        }
    }
    
    /// Start the server
    Result!DistributedError start() @trusted {
        auto addr = config.parseAddress();
        
        try {
            listener = new TcpSocket();
            listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
            listener.bind(new InternetAddress(addr.host, addr.port));
            listener.listen(128);
            
            running = true;
            
            // Start accept thread
            acceptThread = new Thread(&acceptLoop);
            acceptThread.start();
            
            return Ok!DistributedError();
        } catch (Exception e) {
            return Result!DistributedError.err(
                new DistributedError("Failed to start server: " ~ e.msg));
        }
    }
    
    /// Stop the server
    void stop() @trusted {
        running = false;
        
        if (listener !is null) {
            try {
                listener.shutdown(SocketShutdown.BOTH);
                listener.close();
            } catch (Exception) {}
        }
        
        // Wait for accept thread
        if (acceptThread !is null) {
            try { acceptThread.join(); }
            catch (Exception) {}
        }
    }
    
    /// Check if server is running
    bool isRunning() const @safe => running;
    
    /// Get bound address
    string boundAddress() const @safe => config.address;
    
    private void acceptLoop() @trusted {
        while (running) {
            try {
                auto client = listener.accept();
                if (client is null) continue;
                
                // Handle client in new thread
                auto handler = new Thread(() => handleConnection(client));
                handler.start();
            } catch (Exception) {
                if (!running) break;
            }
        }
    }
    
    private void handleConnection(Socket client) @trusted {
        scope(exit) {
            try {
                client.shutdown(SocketShutdown.BOTH);
                client.close();
            } catch (Exception) {}
        }
        
        // Set timeouts
        client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 30.seconds);
        client.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 30.seconds);
        
        // Read and validate connection preface
        ubyte[24] prefaceBuf;
        auto received = client.receive(prefaceBuf);
        if (received != 24 || prefaceBuf != connectionPreface)
            return;
        
        // Send initial SETTINGS
        auto settings = H2Settings.init;
        settings.maxConcurrentStreams = config.maxConcurrentStreams;
        settings.maxFrameSize = cast(uint)config.maxMessageSize;
        
        auto settingsPayload = settings.serialize();
        auto settingsHeader = FrameHeader(
            cast(uint)settingsPayload.length, 
            FrameType.Settings, 
            0, 
            0
        );
        client.send(settingsHeader.serialize());
        client.send(settingsPayload);
        
        // Read client SETTINGS
        ubyte[9] headerBuf;
        received = client.receive(headerBuf);
        if (received != 9) return;
        
        auto header = FrameHeader.deserialize(headerBuf);
        if (header.type == FrameType.Settings && header.length > 0) {
            ubyte[] payload = new ubyte[header.length];
            client.receive(payload);
        }
        
        // Send SETTINGS ACK
        auto ackHeader = FrameHeader(0, FrameType.Settings, FrameFlags.Ack, 0);
        client.send(ackHeader.serialize());
        
        // Main frame processing loop
        processFrames(client);
    }
    
    private void processFrames(Socket client) @trusted {
        H2Stream[uint] streams;
        
        while (running) {
            ubyte[9] headerBuf;
            auto received = client.receive(headerBuf);
            if (received != 9) break;
            
            auto header = FrameHeader.deserialize(headerBuf);
            
            ubyte[] payload;
            if (header.length > 0) {
                payload = new ubyte[header.length];
                size_t totalRead = 0;
                while (totalRead < header.length) {
                    auto chunk = client.receive(payload[totalRead .. $]);
                    if (chunk <= 0) break;
                    totalRead += chunk;
                }
            }
            
            // Handle frame
            switch (header.type) {
                case FrameType.Headers:
                    handleHeaders(client, header, payload, streams);
                    break;
                    
                case FrameType.Data:
                    handleData(client, header, payload, streams);
                    break;
                    
                case FrameType.Settings:
                    if (!header.hasFlag(FrameFlags.Ack)) {
                        auto ackHeader = FrameHeader(0, FrameType.Settings, FrameFlags.Ack, 0);
                        client.send(ackHeader.serialize());
                    }
                    break;
                    
                case FrameType.Ping:
                    if (!header.hasFlag(FrameFlags.Ack)) {
                        auto pongHeader = FrameHeader(
                            cast(uint)payload.length, 
                            FrameType.Ping, 
                            FrameFlags.Ack, 
                            0
                        );
                        client.send(pongHeader.serialize());
                        client.send(payload);
                    }
                    break;
                    
                case FrameType.WindowUpdate:
                    // Acknowledge window update
                    break;
                    
                case FrameType.GoAway:
                    return;  // Connection closing
                    
                case FrameType.RstStream:
                    if (header.streamId in streams)
                        streams[header.streamId].state = StreamState.Closed;
                    break;
                    
                default:
                    break;
            }
        }
    }
    
    private void handleHeaders(
        Socket client, 
        FrameHeader header, 
        ubyte[] payload,
        ref H2Stream[uint] streams
    ) @trusted {
        auto headers = HpackDecoder.decode(payload);
        
        // Get or create stream
        if (header.streamId !in streams) {
            H2Stream stream;
            stream.id = header.streamId;
            stream.state = StreamState.Open;
            streams[header.streamId] = stream;
        }
        
        streams[header.streamId].headers = headers;
        
        // If end stream, process the request
        if (header.hasFlag(FrameFlags.EndStream)) {
            processRequest(client, header.streamId, headers, []);
        }
    }
    
    private void handleData(
        Socket client, 
        FrameHeader header, 
        ubyte[] payload,
        ref H2Stream[uint] streams
    ) @trusted {
        if (header.streamId !in streams) return;
        
        auto stream = &streams[header.streamId];
        stream.pendingData ~= payload;
        
        // Send WINDOW_UPDATE for received data
        if (payload.length > 0) {
            ubyte[4] windowPayload = [0, 0, 0, 0];
            auto increment = cast(uint)payload.length;
            windowPayload[0] = cast(ubyte)((increment >> 24) & 0xFF);
            windowPayload[1] = cast(ubyte)((increment >> 16) & 0xFF);
            windowPayload[2] = cast(ubyte)((increment >> 8) & 0xFF);
            windowPayload[3] = cast(ubyte)(increment & 0xFF);
            
            // Connection-level window update
            auto connWindowHeader = FrameHeader(4, FrameType.WindowUpdate, 0, 0);
            client.send(connWindowHeader.serialize());
            client.send(windowPayload);
            
            // Stream-level window update
            auto streamWindowHeader = FrameHeader(4, FrameType.WindowUpdate, 0, header.streamId);
            client.send(streamWindowHeader.serialize());
            client.send(windowPayload);
        }
        
        // If end stream, process the request
        if (header.hasFlag(FrameFlags.EndStream)) {
            processRequest(client, header.streamId, stream.headers, stream.pendingData);
            stream.pendingData = [];
        }
    }
    
    private void processRequest(
        Socket client,
        uint streamId,
        string[string] headers,
        ubyte[] data
    ) @trusted {
        // Extract method from :path
        auto path = headers.get(":path", "");
        auto method = GrpcMethod.fromPath(path);
        
        // Find service handler
        GrpcServiceHandler handler;
        synchronized (mutex) {
            foreach (entry; services) {
                if (entry.serviceName == method.service) {
                    handler = entry.handler;
                    break;
                }
            }
        }
        
        // Parse gRPC frame from request data
        ubyte[] requestPayload;
        if (data.length >= GrpcFrame.HeaderSize) {
            auto frameResult = GrpcFrame.decode(data, config.maxMessageSize);
            if (frameResult.isOk)
                requestPayload = frameResult.unwrap().message;
        }
        
        // Call handler
        ubyte[] responsePayload;
        GrpcStatusCode status = GrpcStatusCode.Ok;
        string statusMessage;
        
        if (handler is null) {
            status = GrpcStatusCode.Unimplemented;
            statusMessage = "Service not found: " ~ method.service;
        } else {
            auto result = handler.handleUnary(method.method, requestPayload);
            if (result.isOk) {
                responsePayload = result.unwrap();
            } else {
                status = GrpcStatusCode.Internal;
                statusMessage = result.unwrapErr();
            }
        }
        
        // Send response headers
        auto responseHeaders = GrpcHeaders.responseHeaders(status, statusMessage);
        auto headerBlock = HpackEncoder.encode(responseHeaders);
        
        auto responseHeaderFrame = FrameHeader(
            cast(uint)headerBlock.length,
            FrameType.Headers,
            FrameFlags.EndHeaders,
            streamId
        );
        client.send(responseHeaderFrame.serialize());
        client.send(headerBlock);
        
        // Send response data
        if (responsePayload.length > 0) {
            auto frame = GrpcFrame.uncompressed(responsePayload);
            auto encoded = frame.encode();
            
            auto dataHeader = FrameHeader(
                cast(uint)encoded.length,
                FrameType.Data,
                0,
                streamId
            );
            client.send(dataHeader.serialize());
            client.send(encoded);
        }
        
        // Send trailers (required for gRPC)
        string[string] trailers;
        trailers["grpc-status"] = status.to!string;
        if (statusMessage.length > 0)
            trailers["grpc-message"] = statusMessage;
        
        auto trailerBlock = HpackEncoder.encode(trailers);
        auto trailerHeader = FrameHeader(
            cast(uint)trailerBlock.length,
            FrameType.Headers,
            FrameFlags.EndHeaders | FrameFlags.EndStream,
            streamId
        );
        client.send(trailerHeader.serialize());
        client.send(trailerBlock);
    }
}

/**
 * Builder for creating configured GrpcServer instances
 */
struct GrpcServerBuilder {
    private GrpcServerConfig config;
    private GrpcServiceHandler[] handlers;
    
    static GrpcServerBuilder create() @safe {
        GrpcServerBuilder b;
        b.config = GrpcServerConfig.init;
        return b;
    }
    
    ref GrpcServerBuilder listenOn(string address) return @safe {
        config.address = address;
        return this;
    }
    
    ref GrpcServerBuilder withTls(string cert, string key, string rootCerts = "") return @safe {
        config.useTls = true;
        config.serverCert = cert;
        config.serverKey = key;
        config.rootCerts = rootCerts;
        return this;
    }
    
    ref GrpcServerBuilder withMaxConcurrentStreams(uint n) return @safe {
        config.maxConcurrentStreams = n;
        return this;
    }
    
    ref GrpcServerBuilder withMaxMessageSize(size_t size) return @safe {
        config.maxMessageSize = size;
        return this;
    }
    
    ref GrpcServerBuilder withService(GrpcServiceHandler handler) return @safe {
        handlers ~= handler;
        return this;
    }
    
    GrpcServer build() @trusted {
        auto server = new GrpcServer(config);
        foreach (h; handlers)
            server.registerService(h);
        return server;
    }
}

/**
 * REAPI Service Handler - Wraps Builder coordinator for REAPI compatibility
 */
final class ReapiServiceHandler : GrpcServiceHandler {
    private string service;
    private Result!(ubyte[], string) delegate(string, const ubyte[]) @trusted handler;
    
    this(
        string serviceName, 
        Result!(ubyte[], string) delegate(string, const ubyte[]) @trusted handler
    ) @safe {
        this.service = serviceName;
        this.handler = handler;
    }
    
    string serviceName() const @safe => service;
    
    Result!(ubyte[], string) handleUnary(string method, const ubyte[] request) @trusted {
        if (handler is null)
            return Err!(ubyte[], string)("No handler registered");
        return handler(method, request);
    }
    
    Result!(ubyte[][], string) handleServerStreaming(string method, const ubyte[] request) @trusted {
        auto result = handleUnary(method, request);
        if (result.isErr)
            return Err!(ubyte[][], string)(result.unwrapErr());
        return Ok!(ubyte[][], string)([result.unwrap()]);
    }
}
