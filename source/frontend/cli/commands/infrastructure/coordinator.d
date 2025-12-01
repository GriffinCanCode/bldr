module frontend.cli.commands.infrastructure.coordinator;

import std.stdio;
import std.conv : to;
import std.string : strip;
import engine.graph : BuildGraph;
import engine.distributed.coordinator : Coordinator, CoordinatorConfig;
import infrastructure.utils.logging.logger;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;

/// Start distributed build coordinator
int coordinatorCommand(string[] args)
{
    CoordinatorConfig config;
    
    // Parse arguments
    for (size_t i = 0; i < args.length; i++)
    {
        immutable arg = args[i];
        
        if (arg == "--host" && i + 1 < args.length)
        {
            config.host = args[++i];
        }
        else if (arg == "--port" && i + 1 < args.length)
        {
            config.port = args[++i].to!ushort;
        }
        else if (arg == "--max-workers" && i + 1 < args.length)
        {
            config.maxWorkers = args[++i].to!size_t;
        }
        else if (arg == "--help" || arg == "-h")
        {
            printCoordinatorHelp();
            return 0;
        }
    }
    
    // Create empty build graph (will be populated by clients)
    auto graph = new BuildGraph();
    
    // Create coordinator
    auto coordinator = new Coordinator(graph, config);
    
    // Start coordinator
    auto startResult = coordinator.start();
    if (startResult.isErr)
    {
        Logger.error("Failed to start coordinator");
        Logger.error(formatError(startResult.unwrapErr()));
        return 1;
    }
    
    writeln("Builder Coordinator started");
    writeln("  Host: ", config.host);
    writeln("  Port: ", config.port);
    writeln("  Max workers: ", config.maxWorkers);
    writeln();
    writeln("Press Ctrl+C to stop...");
    
    // Wait for interrupt
    import core.stdc.signal;
    import core.thread : Thread;
    import core.time : seconds;
    
    __gshared bool running = true;
    
    extern (C) void signalHandler(int sig) nothrow @nogc @system
    {
        running = false;
    }
    
    signal(SIGINT, &signalHandler);
    signal(SIGTERM, &signalHandler);
    
    while (running)
    {
        Thread.sleep(1.seconds);
    }
    
    writeln("\nShutting down coordinator...");
    coordinator.stop();
    
    return 0;
}

/// Print coordinator help
void printCoordinatorHelp()
{
    writeln("Builder Coordinator - Distributed build coordinator");
    writeln();
    writeln("USAGE:");
    writeln("  bldr coordinator [OPTIONS]");
    writeln();
    writeln("OPTIONS:");
    writeln("  --host <HOST>          Bind address (default: 0.0.0.0)");
    writeln("  --port <PORT>          Listen port (default: 9000)");
    writeln("  --max-workers <N>      Maximum workers (default: 1000)");
    writeln("  -h, --help             Show this help message");
    writeln();
    writeln("EXAMPLES:");
    writeln("  # Start coordinator on default port");
    writeln("  bldr coordinator");
    writeln();
    writeln("  # Custom host and port");
    writeln("  bldr coordinator --host 127.0.0.1 --port 8080");
    writeln();
    writeln("  # Limit workers");
    writeln("  bldr coordinator --max-workers 50");
}



