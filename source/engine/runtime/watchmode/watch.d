module engine.runtime.watchmode.watch;

import std.stdio;
import std.datetime;
import std.algorithm;
import std.array;
import std.conv;
import std.path;
import core.thread;
import core.time;
import engine.graph;
import engine.graph.caching.mapped : MappedGraphStorage;
import engine.runtime.core.engine;
import engine.runtime.services;
import engine.caching.targets.cache;
import infrastructure.config.schema.schema;
import infrastructure.config.parsing.parser;
import infrastructure.utils.files.watch;
import infrastructure.utils.logging.logger;
import frontend.cli.events.events;
import infrastructure.analysis.incremental.watcher;
import infrastructure.errors;

/// Watch mode configuration
struct WatchModeConfig
{
    Duration debounceDelay = 300.msecs;     /// Delay before triggering rebuild
    bool clearScreen = true;                 /// Clear screen between builds
    bool showGraph = false;                  /// Show dependency graph
    string renderMode = "auto";              /// CLI render mode
    bool failFast = false;                   /// Stop on first error
    bool verbose = false;                    /// Verbose output
    bool useMmapPersistence = true;          /// Use mmap for instant startup
    string cacheDir = ".builder-cache";      /// Cache directory
}

/// Watch mode service - orchestrates file watching and incremental builds
/// 
/// Leverages incremental topological ordering for improved responsiveness:
/// - Caches the build graph between builds when structure is unchanged
/// - Uses incremental topo sort to avoid O(V+E) recomputation on each change
/// - Only rebuilds affected targets in proper topological order
/// - Memory-mapped graph persistence for instant startup on watch restart
final class WatchModeService
{
    private string _workspaceRoot;
    private WorkspaceConfig _config;
    private BuildServices _services;
    private FileWatcher _watcher;
    private AnalysisWatcher _analysisWatcher;
    private WatchModeConfig _watchConfig;
    private bool _isRunning;
    private size_t _buildNumber;
    private SysTime _lastBuildTime;
    private bool _lastBuildSuccess;
    
    // Incremental build optimization state
    private BuildGraph _cachedGraph;              // Cached graph for incremental updates
    private ulong _lastTopoVersion;               // Last seen topo cache version
    private size_t _incrementalHits;              // Times incremental order was reused
    private size_t _fullRebuilds;                 // Times full rebuild was needed
    
    // Memory-mapped persistence for instant startup
    private MappedGraphStorage _mmapStorage;      // Mmap-backed graph persistence
    private ubyte[32] _lastConfigHash;            // Last computed config hash
    private bool _usedMmapStartup;                // Whether startup used mmap
    
    /// Create watch mode service
    this(string workspaceRoot, WatchModeConfig config) @system
    {
        _workspaceRoot = workspaceRoot;
        _watchConfig = config;
        _buildNumber = 0;
        _isRunning = false;
        _lastBuildSuccess = true;
        _incrementalHits = 0;
        _fullRebuilds = 0;
        _usedMmapStartup = false;
        
        // Initialize mmap storage for instant startup
        if (_watchConfig.useMmapPersistence)
        {
            auto cachePath = buildPath(workspaceRoot, _watchConfig.cacheDir);
            _mmapStorage = new MappedGraphStorage(cachePath);
        }
    }
    
    /// Start watch mode
    VoidBuildResult start(string target = "") @system
    {
        // Parse workspace configuration
        auto configResult = ConfigParser.parseWorkspace(_workspaceRoot);
        if (configResult.isErr)
            return VoidBuildResult.err(configResult.unwrapErr());
        
        _config = configResult.unwrap();
        
        // Initialize build services
        _services = new BuildServices(_config, _config.options);
        
        // Initialize analysis watcher for proactive cache invalidation
        if (_services.analyzer.hasIncremental())
        {
            _analysisWatcher = new AnalysisWatcher(
                _services.analyzer.getIncrementalAnalyzer(),
                _config
            );
            
            auto watcherResult = _analysisWatcher.start(_workspaceRoot);
            if (watcherResult.isOk)
                Logger.debugLog("Analysis watcher started for proactive cache invalidation");
            else
                Logger.debugLog("Analysis watcher not available");
        }
        
        // Create file watcher with config
        WatchConfig watchConfig;
        watchConfig.debounceDelay = _watchConfig.debounceDelay;
        watchConfig.recursive = true;
        watchConfig.useNativeWatcher = true;
        
        _watcher = new FileWatcher(watchConfig);
        
        // Perform initial build (try mmap instant startup first)
        printWatchHeader();
        
        if (tryMmapStartup(target))
        {
            Logger.success("Instant startup from memory-mapped graph cache");
            _usedMmapStartup = true;
        }
        else
        {
            Logger.info("Performing initial build...");
            writeln();
            performBuild(target);
        }
        
        // Start watching
        Logger.info("Watching for changes... (Press Ctrl+C to stop)");
        Logger.info("Using watcher: " ~ _watcher.implName());
        if (_watchConfig.useMmapPersistence)
            Logger.debugLog("Memory-mapped graph persistence enabled");
        writeln();
        
        _isRunning = true;
        
        auto watchResult = _watcher.watch(_workspaceRoot, () {
            handleFileChanges(target);
        });
        
        if (watchResult.isErr)
            return VoidBuildResult.err(watchResult.unwrapErr());
        
        // Keep running until interrupted
        while (_isRunning)
            Thread.sleep(100.msecs);
        
        return VoidBuildResult.ok();
    }
    
    /// Try instant startup from memory-mapped graph
    /// Returns true if successful, false if needs full rebuild
    private bool tryMmapStartup(string target) @system
    {
        if (_mmapStorage is null || !_mmapStorage.graphExists())
            return false;
        
        import std.datetime.stopwatch : StopWatch, AutoStart;
        auto sw = StopWatch(AutoStart.yes);
        
        // Compute current config hash
        auto configFiles = collectConfigFiles();
        _lastConfigHash = MappedGraphStorage.computeConfigHash(configFiles);
        
        // Try to load graph with config validation
        auto graphResult = _mmapStorage.tryLoadForWatchMode(_lastConfigHash);
        if (graphResult.isErr)
        {
            Logger.debugLog("Mmap startup failed: config changed or cache invalid");
            return false;
        }
        
        _cachedGraph = graphResult.unwrap();
        _lastTopoVersion = _cachedGraph.topoCacheVersion;
        _lastBuildSuccess = true;
        _lastBuildTime = Clock.currTime();
        
        sw.stop();
        auto elapsed = sw.peek();
        Logger.debugLog("Graph loaded from mmap in " ~ elapsed.total!"usecs".to!string ~ "µs");
        
        return true;
    }
    
    /// Collect all config files for hash computation
    private string[] collectConfigFiles() const @trusted
    {
        import std.file : dirEntries, SpanMode, exists, isFile;
        
        string[] files;
        
        // Builderfile in root
        auto builderfile = buildPath(_workspaceRoot, "Builderfile");
        if (exists(builderfile) && isFile(builderfile))
            files ~= builderfile;
        
        // Builderspace in root
        auto builderspace = buildPath(_workspaceRoot, "Builderspace");
        if (exists(builderspace) && isFile(builderspace))
            files ~= builderspace;
        
        // Scan for nested Builderfiles
        try
        {
            foreach (entry; dirEntries(_workspaceRoot, "Builderfile", SpanMode.depth))
                if (entry.isFile)
                    files ~= entry.name;
        }
        catch (Exception) {}
        
        return files;
    }
    
    /// Stop watch mode
    void stop() @system
    {
        _isRunning = false;
        
        // Persist graph for instant startup on next run
        if (_mmapStorage !is null && _cachedGraph !is null)
        {
            auto persistResult = _mmapStorage.persist(_cachedGraph, _lastConfigHash);
            if (persistResult.isOk)
                Logger.debugLog("Graph persisted for instant startup");
        }
        
        if (_watcher !is null)
            _watcher.stop();
        
        if (_analysisWatcher !is null)
            _analysisWatcher.stop();
        
        if (_services !is null)
            _services.shutdown();
        
        Logger.info("Watch mode stopped");
    }
    
    /// Handle file changes and trigger rebuild
    private void handleFileChanges(string target) @system
    {
        _buildNumber++;
        
        if (_watchConfig.clearScreen)
        {
            clearScreen();
        }
        
        printBuildHeader();
        
        performBuild(target);
        
        writeln();
        auto buildMsg = "Build #" ~ _buildNumber.to!string;
        if (_lastBuildSuccess)
            Logger.success(buildMsg ~ " completed successfully");
        else
            Logger.error(buildMsg ~ " failed");
        Logger.info("Watching for changes...");
        writeln();
    }
    
    /// Perform a build with incremental topological order optimization
    private void performBuild(string target) @system
    {
        import std.datetime.stopwatch : StopWatch, AutoStart;
        
        auto sw = StopWatch(AutoStart.yes);
        _lastBuildSuccess = false;
        
        try
        {
            // Re-parse configuration to pick up any changes
            auto configResult = ConfigParser.parseWorkspace(_workspaceRoot);
            if (configResult.isErr)
            {
                Logger.error("Failed to parse workspace configuration");
                import infrastructure.errors.formatting.format : format;
                Logger.error(format(configResult.unwrapErr()));
                return;
            }
            
            _config = configResult.unwrap();
            
            // Recreate services to pick up config changes
            if (_services !is null)
            {
                _services.shutdown();
            }
            _services = new BuildServices(_config, _config.options);
            
            // Set render mode
            import frontend.cli.display.render : parseRenderMode;
            auto renderMode = parseRenderMode(_watchConfig.renderMode);
            _services.setRenderMode(renderMode);
            
            // Analyze dependencies
            auto graphResult = _services.analyzer.analyze(target);
            if (graphResult.isErr)
            {
                Logger.error("Failed to analyze dependencies");
                import infrastructure.errors.formatting.format : format;
                Logger.error(format(graphResult.unwrapErr()));
                return;
            }
            auto graph = graphResult.unwrap();
            
            // Track incremental optimization effectiveness
            bool usedIncrementalOrder = false;
            if (_cachedGraph !is null && graph.hasValidTopoCache)
            {
                auto currentVersion = graph.topoCacheVersion;
                if (currentVersion == _lastTopoVersion && graph.nodes.length == _cachedGraph.nodes.length)
                {
                    usedIncrementalOrder = true;
                    _incrementalHits++;
                    Logger.debugLog("Using incremental topological order (version " ~ currentVersion.to!string ~ ")");
                }
                else
                {
                    _fullRebuilds++;
                    Logger.debugLog("Full topological recomputation needed");
                }
                _lastTopoVersion = currentVersion;
            }
            else
            {
                _fullRebuilds++;
                _lastTopoVersion = graph.topoCacheVersion;
            }
            
            _cachedGraph = graph;
            
            // Update config hash for persistence
            auto configFiles = collectConfigFiles();
            _lastConfigHash = MappedGraphStorage.computeConfigHash(configFiles);
            
            if (_watchConfig.showGraph)
            {
                Logger.info("\nDependency Graph:");
                graph.print();
                
                // Show incremental stats in verbose mode
                if (_watchConfig.verbose)
                {
                    auto stats = graph.incrementalStats;
                    Logger.debugLog("Incremental topo stats: cache_hits=" ~ stats.cacheHits.to!string ~
                        ", incremental=" ~ stats.incrementalUpdates.to!string ~
                        ", full=" ~ stats.fullRecomputations.to!string ~
                        ", effectiveness=" ~ (stats.effectiveness * 100).to!string ~ "%");
                }
            }
            
            // Execute build
            auto engine = _services.createEngine(graph);
            _lastBuildSuccess = engine.execute();
            engine.shutdown();
            
            sw.stop();
            _lastBuildTime = Clock.currTime();
            
            // Persist graph after successful build for instant startup
            if (_lastBuildSuccess && _mmapStorage !is null)
            {
                auto persistResult = _mmapStorage.persist(graph, _lastConfigHash);
                if (persistResult.isErr && _watchConfig.verbose)
                    Logger.debugLog("Graph persistence failed: " ~ persistResult.unwrapErr().message);
            }
            
            // Print timing with incremental info
            auto elapsed = sw.peek();
            auto timingMsg = "Build time: " ~ elapsed.total!"msecs".to!string ~ "ms";
            if (usedIncrementalOrder)
                timingMsg ~= " (incremental order)";
            Logger.info(timingMsg);
        }
        catch (Exception e)
        {
            Logger.error("Build failed with exception: " ~ e.msg);
            _lastBuildSuccess = false;
        }
    }
    
    /// Print watch mode header
    private void printWatchHeader() @system
    {
        writeln("\n═══════════════════════════════════════════════════════════\n",
                "  Builder Watch Mode\n",
                "═══════════════════════════════════════════════════════════\n");
    }
    
    /// Print build header
    private void printBuildHeader() @system
    {
        writeln("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n",
                "  Build #", _buildNumber, " - ", Clock.currTime().toSimpleString(), "\n",
                "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    }
    
    /// Clear the terminal screen
    private void clearScreen() @system
    {
        version(Windows)
        {
            import std.process : execute;
            execute(["cmd", "/c", "cls"]);
        }
        else
        {
            write("\033[2J\033[H");
            stdout.flush();
        }
    }
}

/// Intelligent change detector that maps file changes to affected targets
/// 
/// Uses incremental topological ordering to efficiently determine rebuild scope
/// and return affected targets in proper build order (leaves first).
final class ChangeDetector
{
    private WorkspaceConfig _config;
    private BuildGraph _graph;
    private BuildCache _cache;
    
    this(WorkspaceConfig config, BuildGraph graph, BuildCache cache) @system
    {
        _config = config;
        _graph = graph;
        _cache = cache;
    }
    
    /// Determine which targets are affected by file changes
    /// Returns targets in topological order (leaves first for proper rebuild)
    string[] getAffectedTargets(const string[] changedFiles) @system
    {
        bool[string] directlyAffected;
        
        // For each changed file, find targets that reference it
        foreach (changedFile; changedFiles)
        {
            auto normalizedPath = buildNormalizedPath(absolutePath(changedFile));
            
            // Check each target
            foreach (target; _config.targets)
            {
                // Check if file is in target's sources
                foreach (source; target.sources)
                {
                    auto sourcePath = buildNormalizedPath(absolutePath(source));
                    
                    if (sourcePath == normalizedPath || 
                        normalizedPath.startsWith(dirName(sourcePath)))
                    {
                        directlyAffected[target.name] = true;
                        break;
                    }
                }
            }
        }
        
        // Use incremental topological ordering to get all affected nodes in order
        // This leverages the cached topo order for O(affected) vs O(V+E)
        string[] allAffected;
        bool[string] seen;
        
        foreach (targetName; directlyAffected.keys)
        {
            auto targetId = TargetId(targetName);
            auto affectedNodes = _graph.getAffectedNodes(targetId);
            
            foreach (node; affectedNodes)
            {
                auto nodeId = node.id.toString();
                if (nodeId !in seen)
                {
                    seen[nodeId] = true;
                    allAffected ~= nodeId;
                }
            }
        }
        
        return allAffected;
    }
    
    /// Get affected nodes as BuildNode references (for direct execution)
    /// Returns nodes in topological order (leaves first)
    BuildNode[] getAffectedNodes(const string[] changedFiles) @system
    {
        bool[string] directlyAffected;
        
        foreach (changedFile; changedFiles)
        {
            auto normalizedPath = buildNormalizedPath(absolutePath(changedFile));
            
            foreach (target; _config.targets)
            {
                foreach (source; target.sources)
                {
                    auto sourcePath = buildNormalizedPath(absolutePath(source));
                    if (sourcePath == normalizedPath || normalizedPath.startsWith(dirName(sourcePath)))
                    {
                        directlyAffected[target.name] = true;
                        break;
                    }
                }
            }
        }
        
        // Collect all affected nodes using incremental topo order
        BuildNode[] allAffected;
        bool[string] seen;
        
        foreach (targetName; directlyAffected.keys)
        {
            auto targetId = TargetId(targetName);
            auto affectedNodes = _graph.getAffectedNodes(targetId);
            
            foreach (node; affectedNodes)
            {
                auto nodeId = node.id.toString();
                if (nodeId !in seen)
                {
                    seen[nodeId] = true;
                    allAffected ~= node;
                }
            }
        }
        
        return allAffected;
    }
    
    /// Check if target A must be built before target B
    bool mustPrecede(string a, string b) @system
    {
        return _graph.mustPrecede(TargetId(a), TargetId(b));
    }
}

/// Watch statistics tracker with incremental optimization metrics
struct WatchStats
{
    size_t totalBuilds;
    size_t successfulBuilds;
    size_t failedBuilds;
    Duration totalBuildTime;
    Duration averageBuildTime;
    SysTime startTime;
    
    // Incremental topological ordering stats
    size_t incrementalHits;       // Times cached topo order was reused
    size_t fullRecomputations;    // Times full topo sort was needed
    
    // Memory-mapped graph stats
    bool usedMmapStartup;         // Whether instant startup was used
    size_t mmapPersists;          // Times graph was persisted
    
    /// Record a build
    void recordBuild(bool success, Duration buildTime, bool usedIncrementalOrder = false) @system
    {
        totalBuilds++;
        if (success) successfulBuilds++; else failedBuilds++;
        totalBuildTime += buildTime;
        if (totalBuilds > 0) averageBuildTime = totalBuildTime / totalBuilds;
        if (usedIncrementalOrder) incrementalHits++; else fullRecomputations++;
    }
    
    /// Get incremental ordering effectiveness (0.0 - 1.0)
    @property float incrementalEffectiveness() const pure @safe nothrow @nogc
    {
        auto total = incrementalHits + fullRecomputations;
        return total == 0 ? 1.0f : cast(float)incrementalHits / cast(float)total;
    }
    
    /// Print statistics
    void print() const @system
    {
        writeln("\nWatch Mode Statistics:");
        writeln("  Total builds: " ~ totalBuilds.to!string);
        writeln("  Successful: " ~ successfulBuilds.to!string);
        writeln("  Failed: " ~ failedBuilds.to!string);
        writeln("  Average build time: " ~ averageBuildTime.total!"msecs".to!string ~ "ms");
        
        // Memory-mapped persistence stats
        if (usedMmapStartup)
            writeln("  Startup: instant (mmap)");
        
        // Incremental optimization stats
        if (incrementalHits + fullRecomputations > 0)
        {
            writeln("  Incremental topo hits: " ~ incrementalHits.to!string);
            writeln("  Full recomputations: " ~ fullRecomputations.to!string);
            auto pct = cast(int)(incrementalEffectiveness * 100);
            writeln("  Incremental effectiveness: " ~ pct.to!string ~ "%");
        }
        
        auto uptime = Clock.currTime() - startTime;
        writeln("  Uptime: " ~ uptime.total!"seconds".to!string ~ "s");
    }
}

