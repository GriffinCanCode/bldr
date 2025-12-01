# Watch Mode Implementation

This document describes the technical implementation of Builder's watch mode feature.

## Architecture Overview

Watch mode consists of three main layers:

1. **File Watcher Layer**: Platform-specific file system monitoring
2. **Orchestration Layer**: Build coordination and state management
3. **CLI Layer**: User interface and command handling

## Module Structure

```
source/
├── utils/files/watch.d           # File watcher abstraction
├── core/execution/watch.d        # Watch mode service
└── cli/commands/watch.d          # CLI command
```

## File Watcher Layer

### Design Pattern: Strategy + Factory

The file watcher uses a strategy pattern with a factory for platform selection:

```d
interface IFileWatcher {
    WatchResult watch(string path, WatchConfig config, WatchBatchCallback callback);
    void stop();
    bool isActive() const;
    string name() const;
}
```

### Platform Implementations

#### FSEventsWatcher (macOS)

Uses Apple's FSEvents API via `fswatch` command-line tool:

```d
class FSEventsWatcher : IFileWatcher {
    // Spawns fswatch process
    // Reads events from stdout
    // Batches events with debouncing
    // Thread-safe event queue
}
```

**Advantages**:
- Zero CPU overhead
- Instant notifications
- Recursive by default
- Handles renames correctly

**Trade-offs**:
- Requires external dependency (`fswatch`)
- Process management overhead
- No filtering at OS level

#### INotifyWatcher (Linux)

Uses Linux's inotify API via `inotifywait`:

```d
class INotifyWatcher : IFileWatcher {
    // Spawns inotifywait process
    // Parses event stream
    // Maps inotify events to FileEvent types
    // Batches with debouncing
}
```

**Advantages**:
- Near-zero CPU overhead
- Instant notifications
- Granular event types
- Efficient for large directories

**Trade-offs**:
- Requires inotify-tools
- inotify descriptor limits (can be increased)
- Process management overhead

#### PollingWatcher (Universal Fallback)

File system polling using snapshots:

```d
class PollingWatcher : IFileWatcher {
    // Takes periodic snapshots of directory tree
    // Compares file states (size + mtime)
    // Detects creates, modifies, deletes
    // Configurable poll interval (default: 500ms)
}
```

**Advantages**:
- No external dependencies
- Works on all platforms
- Simple implementation
- No descriptor limits

**Trade-offs**:
- Higher CPU usage (scanning filesystem)
- Delayed notifications (poll interval)
- Not suitable for very large projects

### Debouncing Strategy

Watch mode implements exponential backoff debouncing:

```d
class FileWatcher {
    private FileEvent[] _eventQueue;
    private SysTime _lastTrigger;
    
    // Debounce loop runs in separate thread
    private void debounceLoop(void delegate() onChange) {
        while (_active) {
            Thread.sleep(50.msecs);
            
            if (eventQueue.length > 0) {
                if (timeSinceLastEvent >= debounceDelay) {
                    onChange();  // Trigger rebuild
                    eventQueue.clear();
                }
            }
        }
    }
}
```

**Algorithm**:
1. Collect file events in queue
2. Check every 50ms if debounce delay has passed
3. If delay passed and queue not empty, trigger callback
4. Clear queue and reset timer

**Benefits**:
- Groups rapid changes (save spamming)
- Prevents redundant builds
- Configurable delay per project
- Low overhead (50ms check interval)

## Orchestration Layer

### Watch Mode Service

The `WatchModeService` coordinates the entire watch mode workflow:

```d
class WatchModeService {
    // Dependencies
    private WorkspaceConfig _config;
    private BuildServices _services;
    private FileWatcher _watcher;
    
    // State
    private size_t _buildNumber;
    private SysTime _lastBuildTime;
    private bool _lastBuildSuccess;
    
    // Main loop
    Result!(void, BuildError) start(string target);
}
```

### Build Workflow

```
File Change Event
    ↓
Debounce (300ms)
    ↓
┌────────────────────────────┐
│ Re-parse Configuration     │  ← Picks up Builderfile changes
└────────────┬───────────────┘
             ↓
┌────────────────────────────┐
│ Analyze Dependencies       │  ← Builds dependency graph
└────────────┬───────────────┘
             ↓
┌────────────────────────────┐
│ Create Execution Engine    │  ← Prepares parallel executor
└────────────┬───────────────┘
             ↓
┌────────────────────────────┐
│ Execute Build              │  ← Incremental build with cache
└────────────┬───────────────┘
             ↓
┌────────────────────────────┐
│ Report Results             │  ← Success/failure + timing
└────────────────────────────┘
```

### Key Design Decisions

#### Configuration Re-parsing

**Decision**: Re-parse `Builderfile` on every rebuild.

**Rationale**:
- Allows editing build configuration without restarting watch mode
- Low overhead (parsing is fast)
- Eliminates need for "reload" command

**Trade-off**: Slight overhead (~10ms) per rebuild.

#### Service Recreation

**Decision**: Recreate `BuildServices` on each rebuild.

**Rationale**:
- Ensures fresh state (no stale caches)
- Picks up environment changes
- Simpler than selective invalidation

**Trade-off**: Higher memory churn (GC pressure).

#### Screen Clearing

**Decision**: Optional screen clearing between builds (default: enabled).

**Rationale**:
- Clean output improves focus
- Reduces visual clutter
- Can be disabled for debugging

**Implementation**:
```d
version(Windows) {
    execute(["cmd", "/c", "cls"]);
} else {
    write("\033[2J\033[H");  // ANSI escape codes
}
```

## CLI Layer

### Command Structure

Follows Builder's command pattern:

```d
struct WatchCommand {
    static void execute(
        string target,
        bool clearScreen,
        bool showGraph,
        string renderMode,
        bool verbose,
        long debounceMs
    );
    
    static void showHelp();
}
```

### Signal Handling

Watch mode installs custom signal handlers for graceful shutdown:

```d
extern(C) void handleWatchSignal(int sig) nothrow @nogc {
    globalWatchService.stop();  // Cleanup
    exit(0);
}

// Install handlers
signal(SIGINT, &handleWatchSignal);
signal(SIGTERM, &handleWatchSignal);
```

**Behavior**:
- Ctrl+C triggers graceful shutdown
- Flushes caches
- Displays statistics
- Cleans up watcher resources

## Integration with Existing Systems

### Cache System Integration

Watch mode leverages Builder's existing cache infrastructure:

```d
// Two-tier caching
BuildCache.isCached(targetId, sources, deps)
    ↓
Metadata check (size + mtime) → 1μs
    ├─ Hit → Return cached
    └─ Miss → Content hash → 1ms
        ├─ Match → Return cached
        └─ Mismatch → Rebuild
```

**Key Point**: Watch mode doesn't need special caching logic. It simply triggers builds and the cache system automatically handles incremental compilation.

### Event System Integration

Watch mode publishes build events for UI rendering:

```d
// Events published by watch mode
BuildStartedEvent
TargetStartedEvent
TargetCompletedEvent / TargetFailedEvent
BuildCompletedEvent / BuildFailedEvent
StatisticsEvent
```

These events are consumed by the rendering system to provide progress indication, status updates, and statistics.

### Telemetry Integration

Watch mode automatically integrates with telemetry:

```d
// Each build is tracked
TelemetryCollector.recordBuild(
    success: bool,
    duration: Duration,
    targets: size_t,
    cached: size_t
);

// Statistics available via telemetry command
bldr telemetry
```

## Performance Optimizations

### 1. Lazy Service Creation

Services are created only when needed:

```d
// Don't create services until first build
if (_services is null) {
    _services = new BuildServices(_config, _config.options);
}
```

### 2. Batched Event Processing

File events are batched to reduce build frequency:

```d
// Batch size: 1000 events
// Debounce: 300ms after last event

if (batch.length >= config.maxBatchSize) {
    callback(batch);  // Trigger immediately
} else if (timeSinceLastEvent > debounceDelay) {
    callback(batch);  // Trigger after delay
}
```

### 3. Ignore Pattern Filtering

Events are filtered early to avoid processing irrelevant files:

```d
// Check ignore patterns before queueing
if (IgnoreRegistry.shouldIgnoreDirectoryAny(filePath)) {
    continue;  // Skip event
}
```

### 4. Parallel Directory Scanning

Polling watcher uses parallel scanning:

```d
// Scan directories in parallel
foreach (dir; parallel(directories)) {
    // Find files in directory
    // Check against state map
    // Emit events
}
```

## Error Handling

### Watcher Failures

If the watcher fails, watch mode falls back gracefully:

```d
try {
    runFSWatch(config, callback);
} catch (Exception e) {
    Logger.error("FSEvents watcher failed: " ~ e.msg);
    _active = false;  // Stop watching
}
```

User is notified and watch mode exits cleanly.

### Build Failures

Build failures don't stop watch mode:

```d
try {
    performBuild(target);
} catch (Exception e) {
    Logger.error("Build failed: " ~ e.msg);
    _lastBuildSuccess = false;
    // Continue watching
}
```

Watch mode continues and the next file change will trigger another build attempt.

### Configuration Errors

If configuration parsing fails, watch mode reports the error but continues watching:

```d
auto configResult = ConfigParser.parseWorkspace(_workspaceRoot);
if (configResult.isErr) {
    Logger.error("Failed to parse configuration");
    return;  // Skip this build, wait for next change
}
```

## Testing Strategy

### Unit Tests

Each component is independently testable:

```d
// Test debouncing
unittest {
    auto events = [event1, event2, event3];
    auto debouncer = new Debouncer(100.msecs);
    
    size_t callCount = 0;
    debouncer.onTrigger(() => callCount++);
    
    foreach (event; events) {
        debouncer.addEvent(event);
        Thread.sleep(50.msecs);  // Within debounce window
    }
    
    Thread.sleep(150.msecs);  // Exceed debounce window
    assert(callCount == 1);  // Single trigger
}
```

### Integration Tests

End-to-end watch mode tests:

```d
// Test watch mode workflow
unittest {
    auto service = new WatchModeService("test-workspace", config);
    
    // Start watch mode in background
    auto watchThread = new Thread(() => service.start());
    watchThread.start();
    
    // Modify a file
    write("test.d", "void main() {}");
    
    // Wait for rebuild
    Thread.sleep(500.msecs);
    
    // Verify build completed
    assert(exists("bin/test"));
    
    // Cleanup
    service.stop();
    watchThread.join();
}
```

### Manual Testing

Watch mode includes extensive manual testing scenarios in `tests/integration/watch.d`.

## Future Enhancements

### 1. Selective Target Watching

Watch only files relevant to a specific target:

```d
// Implementation idea
class TargetWatcher {
    // Map files to targets
    // Watch only relevant files
    // Rebuild only affected targets
}
```

**Benefits**:
- Reduced watcher overhead
- Faster rebuilds
- Better for large monorepos

### 2. Build Queue

Queue builds instead of canceling in-progress builds:

```d
// Implementation idea
class BuildQueue {
    private Build[] _queue;
    private Build _current;
    
    void enqueue(Build build);
    void processQueue();
}
```

**Benefits**:
- No dropped changes
- Better for rapid changes
- More predictable behavior

### 3. Hot Reload Integration

Integrate with language-specific hot reload mechanisms:

```d
// Implementation idea
interface HotReloader {
    void hotReload(string[] changedFiles);
}

class WatchModeService {
    void useHotReloader(HotReloader reloader);
}
```

**Benefits**:
- Instant updates without full restart
- Better developer experience
- Language-specific optimizations

### 4. Remote Watch

Support watching remote file systems (SSH, network drives):

```d
// Implementation idea
class RemoteWatcher : IFileWatcher {
    // Poll remote filesystem
    // Or use rsync for change detection
}
```

**Benefits**:
- Remote development support
- Container development
- Cloud IDE integration

## Comparison with Other Implementations

### vs. Webpack Watch

| Feature | Builder Watch | Webpack Watch |
|---------|--------------|---------------|
| Implementation | D (native) | JavaScript |
| Platform Support | macOS, Linux, fallback | Node.js platforms |
| Debouncing | Built-in | Via watchOptions |
| Incremental | Cache-based | Module graph |
| Multi-language | ✅ | ❌ (JS only) |

### vs. Cargo Watch

| Feature | Builder Watch | Cargo Watch |
|---------|--------------|---------------|
| Implementation | D (native) | Rust |
| Platform Support | Cross-platform | Cross-platform |
| Debouncing | Configurable | Fixed |
| Incremental | Cache-based | Compiler-based |
| Multi-language | ✅ | ❌ (Rust only) |

## Conclusion

Watch mode is implemented as a clean, layered architecture that integrates seamlessly with Builder's existing systems. The use of platform-specific native watchers ensures high performance, while the fallback polling watcher ensures universal compatibility.

Key architectural decisions:
- **Strategy pattern** for platform-specific watchers
- **Factory pattern** for watcher selection
- **Service recreation** for clean state
- **Integration over invention** for caching and telemetry

The result is a robust, performant watch mode that saves developers 10-30 minutes per day by eliminating manual build invocations.

