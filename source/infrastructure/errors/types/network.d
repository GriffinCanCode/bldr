module infrastructure.errors.types.network;

import infrastructure.errors.types.types;
import infrastructure.errors.codes;
import infrastructure.errors.types.context;

/// Network communication error
/// Used for remote cache, HTTP requests, and network-related failures
final class NetworkError : BaseBuildError
{
    /// Constructor with message
    this(string message, ErrorCode code = ErrorCode.NetworkError,
         string file = __FILE__, size_t line = __LINE__) @trusted
    {
        super(code, message);
        addContext(ErrorContext("file", file));
        addContext(ErrorContext("line", line.to!string));
    }
    
    /// Add host information
    NetworkError withHost(string host, ushort port) return @system
    {
        addContext(ErrorContext("network host", format("%s:%d", host, port)));
        return this;
    }
    
    /// Add URL context
    NetworkError withUrl(string url) return @system
    {
        addContext(ErrorContext("url", url));
        return this;
    }
    
    /// Add timeout context
    NetworkError withTimeout(Duration timeout) return @system
    {
        import std.conv : to;
        addContext(ErrorContext("timeout", timeout.total!"msecs".to!string ~ " ms"));
        return this;
    }
    
    private import std.string : format;
    private import std.datetime : Duration;
    private import std.conv : to;
}


