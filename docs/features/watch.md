# Watch Mode

## Overview

Watch mode monitors the filesystem for changes and automatically triggers incremental builds. Key features:

- **Platform-Native Watchers**: FSEvents (macOS), inotify (Linux), kqueue (BSD), polling fallback
- **Debouncing**: Configurable delay to batch rapid changes
- **Incremental Topological Ordering**: Reuses cached build order when graph structure unchanged
- **Memory-Mapped Persistence**: Instant startup from cached graph state

## Architecture

### Module Structure

```
source/
├── infrastructure/utils/files/watch.d     # File watcher abstraction
├── engine/runtime/watchmode/watch.d       # Watch mode service
└── frontend/cli/commands/extensions/watch.d  # CLI command
```

### Layers

1. **File Watcher Layer**: Platform-specific filesystem monitoring
2. **Orchestration Layer**: Build coordination and state management
3. **CLI Layer**: User interface and command handling

## Usage

```bash
# Start watch mode
bldr watch

# Watch specific target
bldr watch my-target

# Options
bldr watch --debounce 500       # 500ms debounce delay
bldr watch --no-clear           # Don't clear screen between builds
bldr watch --graph              # Show dependency graph
bldr watch -v                   # Verbose output
```

## Configuration

### WatchModeConfig

```d
// Implementation: source/engine/runtime/watchmode/watch.d
struct WatchModeConfig
{
    Duration debounceDelay = 300.msecs;  // Delay before rebuild
    bool clearScreen = true;              // Clear between builds
    bool showGraph = false;               // Show dependency graph
    string renderMode = "auto";           // CLI render mode
    bool failFast = false;                // Stop on first error
    bool verbose = false;                 // Verbose output
    bool useMmapPersistence = true;       // Memory-mapped graph cache
    string cacheDir = ".builder-cache";   // Cache directory
}
```

### WatchConfig (File Watcher)

```d
// Implementation: source/infrastructure/utils/files/watch.d
struct WatchConfig
{
    Duration debounceDelay = 100.msecs;   // Watcher-level debounce
    Duration pollInterval = 500.msecs;     // Fallback poll interval
    bool recursive = true;                 // Watch subdirectories
    bool useNativeWatcher = true;          // Prefer native over polling
    size_t maxBatchSize = 1000;            // Max events per batch
}
```

## File Watchers

### Platform Selection

```d
// Implementation: FileWatcherFactory.create()
static IFileWatcher create()
{
    version(OSX)
    {
        auto fsevents = new FSEventsWatcher();
        if (fsevents.isAvailable())
            return fsevents;
    }
    
    version(linux)
    {
        auto inotify = new INotifyWatcher();
        if (inotify.isAvailable())
            return inotify;
    }
    
    version(BSD)
    {
        auto kqueue = new KQueueWatcher();
        if (kqueue.isAvailable())
            return kqueue;
    }
    
    return new PollingWatcher();  // Fallback
}
```

### FSEventsWatcher (macOS)

Uses `fswatch` command-line tool:

```d
string[] args = [
    "fswatch",
    "-r",           // Recursive
    "-l", "0.3",    // 300ms latency
    watchPath
];
```

**Availability**: Requires `fswatch` to be installed

**Characteristics**:
- Low CPU overhead
- Fast notifications
- Recursive by default
- Handles renames

### INotifyWatcher (Linux)

Uses `inotifywait` command-line tool:

```d
string[] args = [
    "inotifywait",
    "-m",           // Monitor continuously
    "-r",           // Recursive
    "-e", "modify,create,delete,move",
    "--format", "%w%f|%e",
    path
];
```

**Characteristics**:
- Near-zero CPU overhead
- Granular event types
- Efficient for large directories
- Subject to inotify descriptor limits

### PollingWatcher (Fallback)

Periodically scans filesystem for changes:

**Characteristics**:
- No external dependencies
- Works on all platforms
- Higher CPU usage (filesystem scanning)
- Delayed notifications (poll interval)
- Not recommended for large projects

## Debouncing

Two-level debouncing prevents excessive rebuilds:

### FileWatcher Debounce

```d
// Implementation: FileWatcher.debounceLoop()
private void debounceLoop(void delegate() onChange)
{
    while (_active)
    {
        Thread.sleep(50.msecs);  // Check interval
        
        synchronized (_queueMutex)
        {
            if (_eventQueue.length > 0)
            {
                auto timeSinceLastEvent = Clock.currTime() - _lastEventTime;
                if (timeSinceLastEvent >= _config.debounceDelay)
                {
                    onChange();
                    _eventQueue.length = 0;
                }
            }
        }
    }
}
```

### Event Batching

Events are batched until either:
- Batch size reaches `maxBatchSize` (default: 1000)
- Time since last event exceeds `debounceDelay`

## Build Workflow

```
File Change
    ↓
Debounce (300ms default)
    ↓
Re-parse Configuration (picks up Builderfile changes)
    ↓
Recreate BuildServices
    ↓
Analyze Dependencies (build graph)
    ↓
Check Incremental Topo Order (reuse if structure unchanged)
    ↓
Execute Build (with caching)
    ↓
Persist Graph (for instant startup)
    ↓
Report Results
```

### Configuration Re-parsing

Each rebuild re-parses the workspace configuration:

```d
// Allows editing Builderfile without restarting watch mode
auto configResult = ConfigParser.parseWorkspace(_workspaceRoot);
_config = configResult.unwrap();
_services = new BuildServices(_config, _config.options);
```

## Incremental Optimization

### Topological Order Caching

When graph structure is unchanged, the cached topological order is reused:

```d
if (_cachedGraph !is null && graph.hasValidTopoCache)
{
    if (currentVersion == _lastTopoVersion && 
        graph.nodes.length == _cachedGraph.nodes.length)
    {
        usedIncrementalOrder = true;
        _incrementalHits++;
    }
}
```

### Memory-Mapped Persistence

For instant startup on watch restart:

```d
// Try instant startup from mmap
if (tryMmapStartup(target))
{
    Logger.success("Instant startup from memory-mapped graph cache");
    _usedMmapStartup = true;
}
else
{
    performBuild(target);
}
```

### MappedGraphStorage

```d
// Validates config hash before loading
auto graphResult = _mmapStorage.tryLoadForWatchMode(_lastConfigHash);
if (graphResult.isOk)
{
    _cachedGraph = graphResult.unwrap();
    // Instant startup: ~microseconds vs milliseconds
}
```

## Change Detection

### ChangeDetector

Maps file changes to affected targets:

```d
final class ChangeDetector
{
    string[] getAffectedTargets(const string[] changedFiles)
    {
        // Find directly affected targets
        foreach (changedFile; changedFiles)
        {
            foreach (target; _config.targets)
            {
                foreach (source; target.sources)
                {
                    if (matches(changedFile, source))
                        directlyAffected[target.name] = true;
                }
            }
        }
        
        // Get transitive closure in topological order
        foreach (targetName; directlyAffected.keys)
        {
            auto affectedNodes = _graph.getAffectedNodes(TargetId(targetName));
            // Returns nodes in build order (leaves first)
        }
        
        return allAffected;
    }
}
```

## Ignore Patterns

Paths are filtered early to avoid processing:

```d
if (IgnoreRegistry.shouldIgnorePathAny(filePath))
    continue;  // Skip event
```

Common ignored patterns:
- `.builder-cache/`
- `.git/`
- `node_modules/`
- Build output directories

## Error Handling

### Watcher Failures

```d
catch (Exception e)
{
    Logger.error("FSEvents watcher failed: " ~ e.msg);
    _active = false;  // Stop watching
}
```

### Build Failures

Build failures don't stop watch mode:

```d
catch (Exception e)
{
    Logger.error("Build failed with exception: " ~ e.msg);
    _lastBuildSuccess = false;
    // Continue watching
}
```

### Configuration Errors

```d
auto configResult = ConfigParser.parseWorkspace(_workspaceRoot);
if (configResult.isErr)
{
    Logger.error("Failed to parse workspace configuration");
    return;  // Skip this build, wait for next change
}
```

## Statistics

### WatchStats

```d
struct WatchStats
{
    size_t totalBuilds;
    size_t successfulBuilds;
    size_t failedBuilds;
    Duration totalBuildTime;
    Duration averageBuildTime;
    SysTime startTime;
    
    // Incremental optimization
    size_t incrementalHits;
    size_t fullRecomputations;
    
    // Memory-mapped graph
    bool usedMmapStartup;
    size_t mmapPersists;
    
    float incrementalEffectiveness()
    {
        auto total = incrementalHits + fullRecomputations;
        return total == 0 ? 1.0 : incrementalHits / total;
    }
}
```

## Screen Clearing

```d
private void clearScreen()
{
    version(Windows)
    {
        execute(["cmd", "/c", "cls"]);
    }
    else
    {
        write("\033[2J\033[H");  // ANSI escape codes
        stdout.flush();
    }
}
```

## Signal Handling

Watch mode handles interrupts gracefully:

```bash
# Ctrl+C triggers:
1. Stop file watcher
2. Stop analysis watcher  
3. Persist graph for instant startup
4. Shutdown services
5. Print statistics
```

## API Reference

### WatchModeService

```d
final class WatchModeService
{
    this(string workspaceRoot, WatchModeConfig config);
    VoidBuildResult start(string target = "");
    void stop();
}
```

### FileWatcher

```d
final class FileWatcher
{
    this(WatchConfig config = WatchConfig.init);
    WatchResult watch(string path, void delegate() onChange);
    void stop();
    bool isActive() const;
    string implName() const;  // "FSEvents", "inotify", "polling"
}
```

### IFileWatcher Interface

```d
interface IFileWatcher
{
    WatchResult watch(string path, WatchConfig config, WatchBatchCallback callback);
    void stop();
    bool isActive() const;
    string name() const;
}
```

## Performance Tuning

### Debounce Delay

| Project Size | Recommended Delay |
|-------------|-------------------|
| Small (<100 files) | 100-200ms |
| Medium | 200-300ms |
| Large (>1000 files) | 300-500ms |

### Native vs Polling

Always prefer native watchers when available:

```d
WatchConfig config;
config.useNativeWatcher = true;  // Default
```

Polling should only be used as fallback when native watchers are unavailable.

### Graph Persistence

Enable mmap persistence for instant restarts:

```d
WatchModeConfig config;
config.useMmapPersistence = true;  // Default
```

## Limitations

- **Polling**: Higher CPU usage, delayed notifications
- **inotify**: Subject to system descriptor limits
- **FSEvents**: Requires external `fswatch` tool
- **Configuration changes**: Some changes require watch restart

## See Also

- [Incremental Compilation](incremental-compilation.md)
- [Performance](performance.md)
- [CLI Reference](../user-guides/CLI.md)
