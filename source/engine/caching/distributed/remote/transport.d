module engine.caching.distributed.remote.transport;

import std.socket;
import std.uri : encode, decode;
import std.conv : to, text;
import std.string : split, strip, startsWith, indexOf, format;
import std.algorithm : canFind;
import std.datetime : Duration, Clock, SysTime;
import std.array : Appender;
import engine.caching.distributed.remote.protocol;
import infrastructure.errors;

/// HTTP transport for remote cache
/// Implements minimal HTTP/1.1 client for cache operations
/// No external dependencies - uses std.socket
final class HttpTransport
{
    private RemoteCacheConfig config;
    private Socket[] connectionPool;
    private bool[] connectionAvailable;
    private size_t nextConnection;
    
    /// Constructor
    this(RemoteCacheConfig config) @trusted
    {
        this.config = config;
        this.connectionPool = new Socket[config.maxConnections];
        this.connectionAvailable = new bool[config.maxConnections];
        this.connectionAvailable[] = true;
    }
    
    /// Destructor: close all connections
    ~this() @trusted
    {
        foreach (socket; connectionPool)
        {
            if (socket !is null)
            {
                try
                {
                    socket.shutdown(SocketShutdown.BOTH);
                    socket.close();
                }
                catch (Exception) {}
            }
        }
    }
    
    /// Execute GET request
    BuildResult!(ubyte[]) get(string contentHash) @trusted
    {
        immutable path = "/artifacts/" ~ encode(contentHash);
        return executeRequest("GET", path, null);
    }
    
    /// Execute PUT request
    VoidBuildResult put(string contentHash, const(ubyte)[] data) @trusted
    {
        immutable path = "/artifacts/" ~ encode(contentHash);
        auto result = executeRequest("PUT", path, data);
        
        if (result.isErr)
        {
            return VoidBuildResult.err(result.unwrapErr());
        }
        
        return Ok!BuildError();
    }
    
    /// Execute HEAD request
    BuildResult!bool head(string contentHash) @trusted
    {
        immutable path = "/artifacts/" ~ encode(contentHash);
        auto result = executeRequest("HEAD", path, null);
        
        if (result.isErr)
        {
            auto error = result.unwrapErr();
            // Not found is not an error for HEAD
            if (auto cacheErr = cast(CacheError)error)
            {
                if (cacheErr.code == ErrorCode.CacheNotFound)
                    return Ok!(bool, BuildError)(false);
            }
            return Err!(bool, BuildError)(error);
        }
        
        return Ok!(bool, BuildError)(true);
    }
    
    /// Execute DELETE request
    VoidBuildResult remove(string contentHash) @trusted
    {
        immutable path = "/artifacts/" ~ encode(contentHash);
        auto result = executeRequest("DELETE", path, null);
        
        if (result.isErr)
            return VoidBuildResult.err(result.unwrapErr());
        
        return Ok!BuildError();
    }
    
    private BuildResult!(ubyte[]) executeRequest(
        string method,
        string path,
        const(ubyte)[] body_
    ) @trusted
    {
        // Parse URL
        auto urlResult = parseUrl(config.url);
        if (urlResult.isErr)
            return Err!(ubyte[], BuildError)(urlResult.unwrapErr());
        
        auto urlInfo = urlResult.unwrap();
        
        // Get or create connection
        auto socketResult = getConnection(urlInfo.host, urlInfo.port);
        if (socketResult.isErr)
            return Err!(ubyte[], BuildError)(socketResult.unwrapErr());
        
        auto socket = socketResult.unwrap();
        scope(exit) releaseConnection(socket);
        
        try
        {
            // Build HTTP request
            auto request = buildHttpRequest(method, path, body_, urlInfo.host);
            
            // Send request with timeout
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, config.timeout);
            immutable sent = socket.send(request);
            if (sent != request.length)
            {
                auto error = new NetworkError(
                    "Failed to send complete request",
                    ErrorCode.NetworkError
                );
                return Err!(ubyte[], BuildError)(error);
            }
            
            // Receive response with timeout
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, config.timeout);
            auto responseResult = receiveHttpResponse(socket);
            if (responseResult.isErr)
                return Err!(ubyte[], BuildError)(responseResult.unwrapErr());
            
            auto response = responseResult.unwrap();
            
            // Parse status code
            if (response.statusCode == 404)
            {
                auto error = new CacheError(
                    "Artifact not found",
                    ErrorCode.CacheNotFound
                );
                return Err!(ubyte[], BuildError)(error);
            }
            else if (response.statusCode == 401 || response.statusCode == 403)
            {
                auto error = new CacheError(
                    "Authentication failed",
                    ErrorCode.CacheUnauthorized
                );
                return Err!(ubyte[], BuildError)(error);
            }
            else if (response.statusCode >= 400)
            {
                auto error = new NetworkError(
                    "HTTP error: " ~ response.statusCode.to!string,
                    ErrorCode.NetworkError
                );
                return Err!(ubyte[], BuildError)(error);
            }
            
            return Ok!(ubyte[], BuildError)(response.body_);
        }
        catch (Exception e)
        {
            auto error = new NetworkError(
                "Request failed: " ~ e.msg,
                ErrorCode.NetworkError
            );
            return Err!(ubyte[], BuildError)(error);
        }
    }
    
    private struct UrlInfo
    {
        string host;
        ushort port;
        string path;
    }
    
    private BuildResult!UrlInfo parseUrl(string url) pure @trusted
    {
        UrlInfo info;
        
        // Strip protocol
        string remaining = url;
        if (remaining.startsWith("http://"))
            remaining = remaining[7 .. $];
        else if (remaining.startsWith("https://"))
            remaining = remaining[8 .. $];
        
        // Split host:port and path
        immutable slashIdx = remaining.indexOf('/');
        string hostPort;
        if (slashIdx >= 0)
        {
            hostPort = remaining[0 .. slashIdx];
            info.path = remaining[slashIdx .. $];
        }
        else
        {
            hostPort = remaining;
            info.path = "/";
        }
        
        // Parse host and port
        immutable colonIdx = hostPort.indexOf(':');
        if (colonIdx >= 0)
        {
            info.host = hostPort[0 .. colonIdx];
            try
            {
                info.port = hostPort[colonIdx + 1 .. $].to!ushort;
            }
            catch (Exception)
            {
                info.port = 80;
            }
        }
        else
        {
            info.host = hostPort;
            info.port = 80;
        }
        
        return Ok!(UrlInfo, BuildError)(info);
    }
    
    private ubyte[] buildHttpRequest(
        string method,
        string path,
        const(ubyte)[] body_,
        string host
    ) pure @trusted
    {
        Appender!(ubyte[]) buffer;
        
        // Request line
        buffer ~= cast(ubyte[])(method ~ " " ~ path ~ " HTTP/1.1\r\n");
        
        // Headers
        buffer ~= cast(ubyte[])("Host: " ~ host ~ "\r\n");
        
        if (config.authToken.length > 0)
            buffer ~= cast(ubyte[])("Authorization: Bearer " ~ config.authToken ~ "\r\n");
        
        buffer ~= cast(ubyte[])"User-Agent: Builder/1.0\r\n";
        buffer ~= cast(ubyte[])"Connection: keep-alive\r\n";
        
        if (body_.length > 0)
        {
            buffer ~= cast(ubyte[])("Content-Length: " ~ body_.length.to!string ~ "\r\n");
            buffer ~= cast(ubyte[])"Content-Type: application/octet-stream\r\n";
        }
        
        buffer ~= cast(ubyte[])"\r\n";
        
        // Body
        if (body_.length > 0)
            buffer ~= body_;
        
        return buffer.data;
    }
    
    private struct HttpResponse
    {
        int statusCode;
        string[string] headers;
        ubyte[] body_;
    }
    
    private BuildResult!HttpResponse receiveHttpResponse(Socket socket) @trusted
    {
        HttpResponse response;
        ubyte[] buffer = new ubyte[8192];
        Appender!(ubyte[]) received;
        
        try
        {
            // Read until we have headers
            bool headersComplete = false;
            ptrdiff_t headerEnd = -1;
            
            while (!headersComplete)
            {
                immutable bytesRead = socket.receive(buffer);
                if (bytesRead <= 0)
                    break;
                
                received ~= buffer[0 .. bytesRead];
                
                // Check for header end marker
                foreach (i; 0 .. received.data.length - 3)
                {
                    if (received.data[i .. i + 4] == cast(ubyte[])"\r\n\r\n")
                    {
                        headersComplete = true;
                        headerEnd = i + 4;
                        break;
                    }
                }
            }
            
            if (headerEnd < 0)
            {
                auto error = new NetworkError(
                    "Failed to receive HTTP headers",
                    ErrorCode.NetworkError
                );
                return Err!(HttpResponse, BuildError)(error);
            }
            
            // Parse headers
            immutable headerSection = cast(string)received.data[0 .. headerEnd];
            auto lines = headerSection.split("\r\n");
            
            // Parse status line
            if (lines.length == 0)
            {
                auto error = new NetworkError(
                    "Invalid HTTP response: no status line",
                    ErrorCode.NetworkError
                );
                return Err!(HttpResponse, BuildError)(error);
            }
            
            auto statusParts = lines[0].split(" ");
            if (statusParts.length < 2)
            {
                auto error = new NetworkError(
                    "Invalid HTTP status line",
                    ErrorCode.NetworkError
                );
                return Err!(HttpResponse, BuildError)(error);
            }
            
            try
            {
                response.statusCode = statusParts[1].to!int;
            }
            catch (Exception)
            {
                auto error = new NetworkError(
                    "Invalid HTTP status code",
                    ErrorCode.NetworkError
                );
                return Err!(HttpResponse, BuildError)(error);
            }
            
            // Parse headers
            foreach (line; lines[1 .. $])
            {
                immutable colonIdx = line.indexOf(':');
                if (colonIdx > 0)
                {
                    immutable key = line[0 .. colonIdx].strip();
                    immutable value = line[colonIdx + 1 .. $].strip();
                    response.headers[key] = value;
                }
            }
            
            // Read body if Content-Length specified
            immutable contentLengthStr = response.headers.get("Content-Length", "0");
            size_t contentLength;
            try
            {
                contentLength = contentLengthStr.to!size_t;
            }
            catch (Exception)
            {
                contentLength = 0;
            }
            
            // Extract body from received data
            if (headerEnd < received.data.length)
                response.body_ ~= received.data[headerEnd .. $];
            
            // Read remaining body if needed
            while (response.body_.length < contentLength)
            {
                immutable remaining = contentLength - response.body_.length;
                immutable toRead = remaining < buffer.length ? remaining : buffer.length;
                immutable bytesRead = socket.receive(buffer[0 .. toRead]);
                
                if (bytesRead <= 0)
                    break;
                
                response.body_ ~= buffer[0 .. bytesRead];
            }
            
            return Ok!(HttpResponse, BuildError)(response);
        }
        catch (Exception e)
        {
            auto error = new NetworkError(
                "Failed to receive HTTP response: " ~ e.msg,
                ErrorCode.NetworkError
            );
            return Err!(HttpResponse, BuildError)(error);
        }
    }
    
    private BuildResult!Socket getConnection(string host, ushort port) @trusted
    {
        // Try to find available connection
        foreach (i, available; connectionAvailable)
        {
            if (available && connectionPool[i] !is null)
            {
                connectionAvailable[i] = false;
                return Ok!(Socket, BuildError)(connectionPool[i]);
            }
        }
        
        // Create new connection
        try
        {
            auto socket = new TcpSocket();
            socket.connect(new InternetAddress(host, port));
            
            // Find slot for connection
            foreach (i; 0 .. connectionPool.length)
            {
                if (connectionPool[i] is null)
                {
                    connectionPool[i] = socket;
                    connectionAvailable[i] = false;
                    return Ok!(Socket, BuildError)(socket);
                }
            }
            
            // No slots available, use temporary connection
            return Ok!(Socket, BuildError)(socket);
        }
        catch (Exception e)
        {
            auto error = new NetworkError(
                "Failed to connect to " ~ host ~ ":" ~ port.to!string ~ ": " ~ e.msg,
                ErrorCode.NetworkError
            );
            return Err!(Socket, BuildError)(error);
        }
    }
    
    private void releaseConnection(Socket socket) @trusted nothrow
    {
        if (socket is null)
            return;
        
        // Find connection in pool
        foreach (i, poolSocket; connectionPool)
        {
            if (poolSocket is socket)
            {
                connectionAvailable[i] = true;
                return;
            }
        }
        
        // Not in pool, close it
        try
        {
            socket.shutdown(SocketShutdown.BOTH);
            socket.close();
        }
        catch (Exception) {}
    }
}


