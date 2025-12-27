module infrastructure.errors.codes.network;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Network communication error codes (18000-18999)
/// Covers HTTP, gRPC, sockets, and general networking
enum Network : int
{
    /// Generic network error
    Error = 18000,
    /// Connection refused
    ConnectionRefused = 18001,
    /// Connection timeout
    ConnectionTimeout = 18002,
    /// Connection reset
    ConnectionReset = 18003,
    /// Host not found (DNS)
    HostNotFound = 18004,
    /// Network unreachable
    NetworkUnreachable = 18005,
    /// Socket error
    SocketError = 18006,
    /// SSL/TLS error
    TLSError = 18007,
    /// Certificate verification failed
    CertificateError = 18008,
    /// HTTP error (4xx/5xx)
    HTTPError = 18009,
    /// Request timeout
    RequestTimeout = 18010,
    /// Response timeout
    ResponseTimeout = 18011,
    /// Invalid response
    InvalidResponse = 18012,
    /// Rate limited (429)
    RateLimited = 18013,
    /// Service unavailable (503)
    ServiceUnavailable = 18014,
    /// Gateway timeout (504)
    GatewayTimeout = 18015,
    /// Proxy error
    ProxyError = 18016,
    /// DNS resolution failed
    DNSError = 18017,
    /// Redirect loop
    RedirectLoop = 18018,
    /// Max redirects exceeded
    TooManyRedirects = 18019,
    /// gRPC error
    GRPCError = 18020,
    /// Protocol error
    ProtocolError = 18021,
    /// Keep-alive timeout
    KeepAliveTimeout = 18022,
    /// Connection pool exhausted
    PoolExhausted = 18023,
    /// Bandwidth limit exceeded
    BandwidthExceeded = 18024,
    /// Chunked encoding error
    ChunkedEncodingError = 18025,
    /// Content too large
    ContentTooLarge = 18026,
    /// Compression error
    CompressionError = 18027,
}

/// Namespace for network error utilities
struct NetworkErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Network; }
    
    static Recoverability recoverabilityOf(Network code) pure nothrow @nogc
    {
        switch (code)
        {
            case Network.ConnectionTimeout:
            case Network.ConnectionReset:
            case Network.RequestTimeout:
            case Network.ResponseTimeout:
            case Network.RateLimited:
            case Network.ServiceUnavailable:
            case Network.GatewayTimeout:
            case Network.KeepAliveTimeout:
            case Network.PoolExhausted:
                return Recoverability.Transient;
            case Network.HostNotFound:
            case Network.CertificateError:
            case Network.ProxyError:
            case Network.DNSError:
            case Network.RedirectLoop:
            case Network.TooManyRedirects:
            case Network.ContentTooLarge:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Network code) pure nothrow @safe
    {
        final switch (code)
        {
            case Network.Error:               return "Network error";
            case Network.ConnectionRefused:   return "Connection refused";
            case Network.ConnectionTimeout:   return "Connection timeout";
            case Network.ConnectionReset:     return "Connection reset";
            case Network.HostNotFound:        return "Host not found";
            case Network.NetworkUnreachable:  return "Network unreachable";
            case Network.SocketError:         return "Socket error";
            case Network.TLSError:            return "TLS error";
            case Network.CertificateError:    return "Certificate verification failed";
            case Network.HTTPError:           return "HTTP error";
            case Network.RequestTimeout:      return "Request timeout";
            case Network.ResponseTimeout:     return "Response timeout";
            case Network.InvalidResponse:     return "Invalid response";
            case Network.RateLimited:         return "Rate limited";
            case Network.ServiceUnavailable:  return "Service unavailable";
            case Network.GatewayTimeout:      return "Gateway timeout";
            case Network.ProxyError:          return "Proxy error";
            case Network.DNSError:            return "DNS resolution failed";
            case Network.RedirectLoop:        return "Redirect loop detected";
            case Network.TooManyRedirects:    return "Too many redirects";
            case Network.GRPCError:           return "gRPC error";
            case Network.ProtocolError:       return "Protocol error";
            case Network.KeepAliveTimeout:    return "Keep-alive timeout";
            case Network.PoolExhausted:       return "Connection pool exhausted";
            case Network.BandwidthExceeded:   return "Bandwidth limit exceeded";
            case Network.ChunkedEncodingError: return "Chunked encoding error";
            case Network.ContentTooLarge:     return "Content too large";
            case Network.CompressionError:    return "Compression error";
        }
    }
}

