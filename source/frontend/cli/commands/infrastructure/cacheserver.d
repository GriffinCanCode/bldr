module frontend.cli.commands.infrastructure.cacheserver;

import std.stdio : writeln, writefln;
import std.conv : to;
import std.getopt;
import engine.caching.distributed.remote.server : CacheServer;
import engine.caching.distributed.remote.tls : TlsConfig;
import engine.caching.distributed.remote.cdn : CdnConfig;
import infrastructure.utils.logging : Logger, structuredLog;

/// Cache server command
/// Starts a remote cache server for distributed builds
struct CacheServerCommand
{
    /// Execute cache server command
    static void execute(string[] args) @system
    {
        import std.parallelism : totalCPUs;
        
        string host = "0.0.0.0";
        ushort port = 8080;
        string storageDir = ".cache-storage";
        string authToken = "";
        size_t maxSize = 10_000_000_000;  // 10 GB default
        size_t workers = 0;               // 0 = 2 * CPU cores
        size_t queueSize = 1024;          // Connection backlog
        bool help = false;
        
        auto helpInfo = getopt(
            args,
            "host|h", "Host to bind to (default: 0.0.0.0)", &host,
            "port|p", "Port to listen on (default: 8080)", &port,
            "storage|s", "Storage directory (default: .cache-storage)", &storageDir,
            "auth|a", "Authentication token (optional)", &authToken,
            "max-size|m", "Maximum storage size in bytes (default: 10GB)", &maxSize,
            "workers|w", "Worker threads (default: 2 * CPU cores)", &workers,
            "queue-size|q", "Connection queue capacity (default: 1024)", &queueSize,
            "help", "Show this help message", &help
        );
        
        if (help || helpInfo.helpWanted)
        {
            printHelp();
            return;
        }
        
        immutable actualWorkers = workers == 0 ? totalCPUs * 2 : workers;
        
        structuredLog.info("starting_builder_cache_server").emit();
        structuredLog.info("host_").field("detail", "Host: " ~ host).emit();
        structuredLog.info("port_").field("detail", "Port: " ~ port.to!string).emit();
        structuredLog.info("workers_").field("detail", "Workers: " ~ actualWorkers.to!string).emit();
        structuredLog.info("queue_size_").field("detail", "Queue size: " ~ queueSize.to!string).emit();
        structuredLog.info("storage_").field("detail", "Storage: " ~ storageDir).emit();
        structuredLog.info("max_size_").field("detail", "Max size: " ~ formatBytes(maxSize)).emit();
        
        if (authToken.length > 0)
            structuredLog.info("authentication_enabled").emit();
        else
            structuredLog.info("authentication_disabled_warning_insecure").emit();
        
        try
        {
            auto server = new CacheServer(
                host, port, storageDir, authToken, maxSize,
                true, true, true,  // compression, rate limiting, metrics
                TlsConfig.init, CdnConfig.init,
                workers, queueSize
            );
            
            // Handle Ctrl+C gracefully
            import core.sys.posix.signal : signal, SIGINT, SIGTERM;
            import core.thread : Thread;
            import core.time : msecs;
            
            __gshared bool shutdownRequested = false;
            
            extern(C) void signalHandler(int sig) nothrow @nogc @system
            {
                shutdownRequested = true;
            }
            
            signal(SIGINT, &signalHandler);
            signal(SIGTERM, &signalHandler);
            
            server.start();
            
            // Check for shutdown signal periodically
            while (!shutdownRequested)
            {
                Thread.sleep(100.msecs);
            }
            
            structuredLog.info("shutdown_signal_received_stopping_server").emit();
            server.stop();
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_start_cache_server_").field("detail", "Failed to start cache server: " ~ e.msg).emit();
            import core.stdc.stdlib : exit;
            exit(1);
        }
    }
    
    private static void printHelp() @system
    {
        writeln("Builder Cache Server");
        writeln();
        writeln("Usage: bldr cache-server [options]");
        writeln();
        writeln("Options:");
        writeln("  -h, --host <host>         Host to bind to (default: 0.0.0.0)");
        writeln("  -p, --port <port>         Port to listen on (default: 8080)");
        writeln("  -s, --storage <dir>       Storage directory (default: .cache-storage)");
        writeln("  -a, --auth <token>        Authentication token (optional)");
        writeln("  -m, --max-size <bytes>    Maximum storage size (default: 10GB)");
        writeln("  -w, --workers <count>     Worker threads (default: 2 * CPU cores)");
        writeln("  -q, --queue-size <count>  Connection queue capacity (default: 1024)");
        writeln("      --help                Show this help message");
        writeln();
        writeln("Examples:");
        writeln("  # Start server on default port");
        writeln("  bldr cache-server");
        writeln();
        writeln("  # Start server with authentication");
        writeln("  bldr cache-server --auth my-secret-token --port 8080");
        writeln();
        writeln("  # Start server with custom storage");
        writeln("  bldr cache-server --storage /var/cache/bldr --max-size 50000000000");
        writeln();
        writeln("  # High-concurrency server (custom thread pool)");
        writeln("  bldr cache-server --workers 32 --queue-size 4096");
        writeln();
        writeln("Client Configuration:");
        writeln("  Set environment variables to use remote cache:");
        writeln("    export BUILDER_REMOTE_CACHE_URL=http://localhost:8080");
        writeln("    export BUILDER_REMOTE_CACHE_TOKEN=my-secret-token");
        writeln();
    }
    
    private static string formatBytes(size_t bytes) pure @safe
    {
        if (bytes < 1024)
            return bytes.to!string ~ " B";
        if (bytes < 1024 * 1024)
            return (bytes / 1024.0).to!string[0 .. 5] ~ " KB";
        if (bytes < 1024 * 1024 * 1024)
            return (bytes / (1024.0 * 1024.0)).to!string[0 .. 5] ~ " MB";
        return (bytes / (1024.0 * 1024.0 * 1024.0)).to!string[0 .. 5] ~ " GB";
    }
}


