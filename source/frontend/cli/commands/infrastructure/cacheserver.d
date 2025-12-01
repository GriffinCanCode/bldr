module frontend.cli.commands.infrastructure.cacheserver;

import std.stdio : writeln, writefln;
import std.conv : to;
import std.getopt;
import engine.caching.distributed.remote.server : CacheServer;
import infrastructure.utils.logging.logger : Logger;

/// Cache server command
/// Starts a remote cache server for distributed builds
struct CacheServerCommand
{
    /// Execute cache server command
    static void execute(string[] args) @system
    {
        string host = "0.0.0.0";
        ushort port = 8080;
        string storageDir = ".cache-storage";
        string authToken = "";
        size_t maxSize = 10_000_000_000;  // 10 GB default
        bool help = false;
        
        auto helpInfo = getopt(
            args,
            "host|h", "Host to bind to (default: 0.0.0.0)", &host,
            "port|p", "Port to listen on (default: 8080)", &port,
            "storage|s", "Storage directory (default: .cache-storage)", &storageDir,
            "auth|a", "Authentication token (optional)", &authToken,
            "max-size|m", "Maximum storage size in bytes (default: 10GB)", &maxSize,
            "help", "Show this help message", &help
        );
        
        if (help || helpInfo.helpWanted)
        {
            printHelp();
            return;
        }
        
        Logger.info("Starting Builder cache server...");
        Logger.info("Host: " ~ host);
        Logger.info("Port: " ~ port.to!string);
        Logger.info("Storage: " ~ storageDir);
        Logger.info("Max size: " ~ formatBytes(maxSize));
        
        if (authToken.length > 0)
            Logger.info("Authentication: enabled");
        else
            Logger.info("Authentication: disabled (WARNING: Insecure for production)");
        
        try
        {
            auto server = new CacheServer(host, port, storageDir, authToken, maxSize);
            
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
            
            Logger.info("Shutdown signal received, stopping server...");
            server.stop();
        }
        catch (Exception e)
        {
            Logger.error("Failed to start cache server: " ~ e.msg);
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


