module frontend.cli.commands.extensions.watch;

import std.stdio;
import std.conv;
import std.algorithm;
import std.string;
import core.time;
import engine.runtime.watchmode.watch;
import engine.runtime.shutdown.shutdown;
import infrastructure.utils.logging.logger;
import frontend.cli.control.terminal;
import frontend.cli.display.format;
import infrastructure.errors;

/// Watch command - continuously watches for file changes and rebuilds
struct WatchCommand
{
    private static Terminal terminal;
    private static Formatter formatter;
    private static bool initialized = false;
    
    /// Initialize terminal and formatter
    private static void init() @system
    {
        if (!initialized)
        {
            auto caps = Capabilities.detect();
            terminal = Terminal(caps);
            formatter = Formatter(caps);
            initialized = true;
        }
    }
    
    /// Execute watch command
    static void execute(
        string target = "",
        bool clearScreen = true,
        bool showGraph = false,
        string renderMode = "auto",
        bool verbose = false,
        long debounceMs = 300) @system
    {
        init();
        
        terminal.writeln();
        terminal.writeln(formatter.header("Builder Watch Mode"));
        terminal.writeln();
        
        // Validate debounce delay
        if (debounceMs < 10 || debounceMs > 10000)
        {
            Logger.error("Debounce delay must be between 10ms and 10000ms");
            return;
        }
        
        // Create watch config
        WatchModeConfig config;
        config.clearScreen = clearScreen;
        config.showGraph = showGraph;
        config.renderMode = renderMode;
        config.verbose = verbose;
        config.debounceDelay = debounceMs.msecs;
        
        // Create watch service
        auto watchService = new WatchModeService(".", config);
        
        // Install signal handler for graceful shutdown
        installWatchSignalHandler(watchService);
        
        // Start watching
        auto result = watchService.start(target);
        
        if (result.isErr)
        {
            Logger.error("Watch mode failed to start");
            import infrastructure.errors.formatting.format : format;
            Logger.error(format(result.unwrapErr()));
            
            import core.stdc.stdlib : exit;
            exit(1);
        }
        
        terminal.flush();
    }
    
    /// Show watch mode help
    static void showHelp() @system
    {
        init();
        
        terminal.writeln();
        terminal.writeln(formatter.header("Watch Mode Help"));
        terminal.writeln();
        
        terminal.writeln(formatter.section("Description"));
        terminal.writeln("  Continuously watches source files for changes and automatically rebuilds.");
        terminal.writeln("  This is perfect for development workflows where you want instant feedback.");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Usage"));
        terminal.writeln("  bldr build --watch [target] [options]");
        terminal.writeln("  bldr watch [target] [options]");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Options"));
        terminal.writeln("  --clear              Clear screen between builds (default: true)");
        terminal.writeln("  --no-clear           Don't clear screen between builds");
        terminal.writeln("  --graph              Show dependency graph on each build");
        terminal.writeln("  --debounce=<ms>      Debounce delay in milliseconds (default: 300)");
        terminal.writeln("  --mode=<mode>        Render mode: auto, interactive, plain, quiet");
        terminal.writeln("  --verbose            Enable verbose output");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Examples"));
        terminal.writeln("  # Watch all targets");
        terminal.writeln("  bldr build --watch");
        terminal.writeln();
        terminal.writeln("  # Watch specific target");
        terminal.writeln("  bldr build --watch //src:app");
        terminal.writeln();
        terminal.writeln("  # Watch with custom debounce");
        terminal.writeln("  bldr build --watch --debounce=500");
        terminal.writeln();
        terminal.writeln("  # Watch without clearing screen");
        terminal.writeln("  bldr build --watch --no-clear");
        terminal.writeln();
        
        terminal.writeln(formatter.section("How It Works"));
        terminal.writeln("  1. Performs an initial full build");
        terminal.writeln("  2. Watches all source files in the workspace");
        terminal.writeln("  3. On file changes, waits for debounce delay");
        terminal.writeln("  4. Rebuilds affected targets (incremental)");
        terminal.writeln("  5. Leverages cache for maximum speed");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Platform Support"));
        terminal.writeln("  • macOS: Uses FSEvents (native, highly efficient)");
        terminal.writeln("  • Linux: Uses inotify (native, low overhead)");
        terminal.writeln("  • Other: Falls back to polling (universal)");
        terminal.writeln();
        
        terminal.writeln(formatter.section("Tips"));
        terminal.writeln("  • Use --debounce to adjust sensitivity to rapid changes");
        terminal.writeln("  • Watch mode respects .builderignore patterns");
        terminal.writeln("  • Incremental builds use the cache system automatically");
        terminal.writeln("  • Press Ctrl+C to stop watch mode gracefully");
        terminal.writeln();
        
        terminal.flush();
    }
}

/// Install signal handler for watch mode
private void installWatchSignalHandler(WatchModeService service) @system
{
    import core.stdc.signal : signal, SIGINT, SIGTERM;
    import core.thread : thread_detachThis;
    
    // Store service reference globally for signal handler
    globalWatchService = service;
    
    // Install handlers
    signal(SIGINT, &handleWatchSignal);
    signal(SIGTERM, &handleWatchSignal);
}

/// Global watch service reference for signal handler
private __gshared WatchModeService globalWatchService;

/// Global flag for shutdown request
private __gshared bool watchShutdownRequested = false;

/// Signal handler for watch mode
extern(C) void handleWatchSignal(int sig) nothrow @nogc @system
{
    watchShutdownRequested = true;
}

