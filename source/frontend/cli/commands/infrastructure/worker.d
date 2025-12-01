module frontend.cli.commands.infrastructure.worker;

import std.stdio;
import std.conv : to;
import std.string : strip;
import engine.distributed.worker : Worker, WorkerConfig;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Start distributed build worker
int workerCommand(string[] args)
{
    WorkerConfig config;
    
    // Parse arguments
    for (size_t i = 0; i < args.length; i++)
    {
        immutable arg = args[i];
        
        if (arg == "--coordinator" && i + 1 < args.length)
        {
            config.coordinatorUrl = args[++i];
        }
        else if (arg == "--parallelism" && i + 1 < args.length)
        {
            config.maxConcurrentActions = args[++i].to!size_t;
        }
        else if (arg == "--sandbox")
        {
            config.enableSandboxing = true;
        }
        else if (arg == "--no-sandbox")
        {
            config.enableSandboxing = false;
        }
        else if (arg == "--help" || arg == "-h")
        {
            printWorkerHelp();
            return 0;
        }
    }
    
    // Validate coordinator URL
    if (config.coordinatorUrl.length == 0)
    {
        Logger.error("Coordinator URL is required (use --coordinator)");
        return 1;
    }
    
    // Create worker
    auto worker = new Worker(config);
    
    // Start worker
    auto startResult = worker.start();
    if (startResult.isErr)
    {
        Logger.error("Failed to start worker: " ~ format(startResult.unwrapErr()));
        return 1;
    }
    
    writeln("Builder Worker started");
    writeln("  Coordinator: ", config.coordinatorUrl);
    writeln("  Parallelism: ", config.maxConcurrentActions);
    writeln("  Sandboxing: ", config.enableSandboxing ? "enabled" : "disabled");
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
    
    writeln("\nShutting down worker...");
    worker.stop();
    
    return 0;
}

/// Print worker help
void printWorkerHelp()
{
    writeln("Builder Worker - Distributed build worker");
    writeln();
    writeln("USAGE:");
    writeln("  bldr worker [OPTIONS]");
    writeln();
    writeln("OPTIONS:");
    writeln("  --coordinator <URL>    Coordinator URL (required)");
    writeln("  --parallelism <N>      Max concurrent actions (default: 8)");
    writeln("  --sandbox              Enable hermetic sandboxing (default)");
    writeln("  --no-sandbox           Disable sandboxing");
    writeln("  -h, --help             Show this help message");
    writeln();
    writeln("EXAMPLES:");
    writeln("  # Connect to local coordinator");
    writeln("  bldr worker --coordinator http://localhost:9000");
    writeln();
    writeln("  # Custom parallelism");
    writeln("  bldr worker --coordinator http://coordinator:9000 --parallelism 16");
    writeln();
    writeln("  # Disable sandboxing (for development)");
    writeln("  bldr worker --coordinator http://localhost:9000 --no-sandbox");
}



