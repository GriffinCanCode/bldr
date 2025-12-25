module infrastructure.utils.files.watch;

import std.stdio;
import std.file;
import std.path;
import std.datetime;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.process : execute;
import core.thread;
import core.time;
import core.sync.mutex;
import infrastructure.utils.files.ignore;
import infrastructure.utils.security.validation;
import infrastructure.errors;

/// File system event type
enum FileEventKind
{
    Created,
    Modified,
    Deleted,
    Renamed,
    Unknown
}

/// File system event
struct FileEvent
{
    string path;           /// Absolute path to the file
    FileEventKind kind;    /// Type of event
    SysTime timestamp;     /// When the event occurred
}

/// File watcher configuration
struct WatchConfig
{
    Duration debounceDelay = 100.msecs;  /// Delay before triggering rebuild
    Duration pollInterval = 500.msecs;   /// Fallback poll interval
    bool recursive = true;               /// Watch subdirectories
    bool useNativeWatcher = true;        /// Try native OS watcher first
    size_t maxBatchSize = 1000;          /// Max events to batch
}

/// File watcher callback
alias WatchCallback = void delegate(const ref FileEvent event);
alias WatchBatchCallback = void delegate(const FileEvent[] events);

/// Result of a watch operation
alias WatchResult = Result!BuildError;

/// Cross-platform file watcher interface
interface IFileWatcher
{
    /// Start watching a directory
    WatchResult watch(string path, WatchConfig config, WatchBatchCallback callback) @system;
    
    /// Stop watching
    void stop() @system;
    
    /// Check if watcher is active
    bool isActive() const pure nothrow @nogc;
    
    /// Get implementation name
    string name() const pure nothrow;
}

/// Factory for creating platform-appropriate file watcher
final class FileWatcherFactory
{
    /// Create best available watcher for current platform
    static IFileWatcher create() @system
    {
        version(OSX)
        {
            // Try FSEvents first (most efficient on macOS)
            auto fsevents = new FSEventsWatcher();
            if (fsevents.isAvailable())
                return fsevents;
        }
        
        version(linux)
        {
            // Try inotify on Linux
            auto inotify = new INotifyWatcher();
            if (inotify.isAvailable())
                return inotify;
        }
        
        version(BSD)
        {
            // kqueue on BSD systems
            auto kqueue = new KQueueWatcher();
            if (kqueue.isAvailable())
                return kqueue;
        }
        
        // Fallback to polling watcher (works everywhere)
        return new PollingWatcher();
    }
}

/// FSEvents-based watcher for macOS
final class FSEventsWatcher : IFileWatcher
{
    private bool _active;
    private string _watchPath;
    
    bool isAvailable() const nothrow @system
    {
        version(OSX)
        {
            // Check if fswatch is available
            try
            {
                auto result = execute(["which", "fswatch"]);
                return result.status == 0;
            }
            catch (Exception)
            {
                return false;
            }
        }
        else
        {
            return false;
        }
    }
    
    WatchResult watch(string path, WatchConfig config, WatchBatchCallback callback) @system
    {
        if (!exists(path) || !isDir(path))
        {
            auto error = new IOError(path, "Directory not found", ErrorCode.FileNotFound);
            return WatchResult.err(error);
        }
        
        _watchPath = absolutePath(path);
        _active = true;
        
        // Start fswatch in a separate thread
        new Thread(() => runFSWatch(config, callback)).start();
        
        return WatchResult.ok();
    }
    
    void stop() @system
    {
        _active = false;
    }
    
    bool isActive() const pure nothrow @nogc
    {
        return _active;
    }
    
    string name() const pure nothrow
    {
        return "FSEvents";
    }
    
    private void runFSWatch(WatchConfig config, WatchBatchCallback callback) @system
    {
        try
        {
            import std.process : pipeProcess, Redirect, wait;
            
            string[] args = [
                "fswatch",
                "-r",           // Recursive
                "-l", "0.3",    // Latency 300ms - let fswatch handle debouncing
                _watchPath
            ];
            
            auto pipes = pipeProcess(args, Redirect.stdout);
            scope(exit) wait(pipes.pid);
            
            // Pass events directly - fswatch handles debouncing via -l flag
            // FileWatcher's debounceLoop handles additional debouncing
            foreach (line; pipes.stdout.byLine)
            {
                if (!_active)
                    break;
                
                string filePath = line.idup;
                
                // Skip if path contains ignored directories (e.g. .builder-cache)
                if (IgnoreRegistry.shouldIgnorePathAny(filePath))
                    continue;
                
                FileEvent event;
                event.path = filePath;
                event.kind = inferEventKind(filePath);
                event.timestamp = Clock.currTime();
                
                // Pass event immediately - let FileWatcher handle debouncing
                callback([event]);
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging.logger;
            Logger.error("FSEvents watcher failed: " ~ e.msg);
            _active = false;
        }
    }
    
    private static FileEventKind inferEventKind(string path) nothrow @system
    {
        try
        {
            if (exists(path))
                return FileEventKind.Modified;
            else
                return FileEventKind.Deleted;
        }
        catch (Exception)
        {
            return FileEventKind.Unknown;
        }
    }
}

/// inotify-based watcher for Linux
final class INotifyWatcher : IFileWatcher
{
    private bool _active;
    
    bool isAvailable() const pure nothrow
    {
        version(linux)
            return true;
        else
            return false;
    }
    
    WatchResult watch(string path, WatchConfig config, WatchBatchCallback callback) @system
    {
        if (!exists(path) || !isDir(path))
        {
            auto error = new IOError(path, "Directory not found", ErrorCode.FileNotFound);
            return WatchResult.err(error);
        }
        
        _active = true;
        
        // Use inotify-tools for simplicity
        new Thread(() => runINotify(path, config, callback)).start();
        
        return WatchResult.ok();
    }
    
    void stop() @system
    {
        _active = false;
    }
    
    bool isActive() const pure nothrow @nogc
    {
        return _active;
    }
    
    string name() const pure nothrow
    {
        return "inotify";
    }
    
    private void runINotify(string path, WatchConfig config, WatchBatchCallback callback) @system
    {
        try
        {
            import std.process : pipeProcess, Redirect, wait;
            
            string[] args = [
                "inotifywait",
                "-m",           // Monitor continuously
                "-r",           // Recursive
                "-e", "modify,create,delete,move",
                "--format", "%w%f|%e",
                path
            ];
            
            auto pipes = pipeProcess(args, Redirect.stdout);
            scope(exit) wait(pipes.pid);
            
            FileEvent[] batch;
            SysTime lastEvent = Clock.currTime();
            
            foreach (line; pipes.stdout.byLine)
            {
                if (!_active)
                    break;
                
                auto parts = line.split("|");
                if (parts.length < 2)
                    continue;
                
                string filePath = parts[0].idup;
                string eventType = parts[1].idup;
                
                if (IgnoreRegistry.shouldIgnorePathAny(filePath))
                    continue;
                
                FileEvent event;
                event.path = filePath;
                event.kind = parseINotifyEvent(eventType);
                event.timestamp = Clock.currTime();
                
                batch ~= event;
                lastEvent = event.timestamp;
                
                if (batch.length >= config.maxBatchSize || 
                    (Clock.currTime() - lastEvent) > config.debounceDelay)
                {
                    if (batch.length > 0)
                    {
                        callback(batch);
                        batch.length = 0;
                    }
                }
            }
            
            if (batch.length > 0)
            {
                callback(batch);
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging.logger;
            Logger.error("inotify watcher failed: " ~ e.msg);
            _active = false;
        }
    }
    
    private static FileEventKind parseINotifyEvent(string eventType) pure nothrow
    {
        if (eventType.canFind("CREATE"))
            return FileEventKind.Created;
        else if (eventType.canFind("MODIFY"))
            return FileEventKind.Modified;
        else if (eventType.canFind("DELETE"))
            return FileEventKind.Deleted;
        else if (eventType.canFind("MOVE"))
            return FileEventKind.Renamed;
        else
            return FileEventKind.Unknown;
    }
}

/// kqueue-based watcher for BSD systems
final class KQueueWatcher : IFileWatcher
{
    private bool _active;
    private string _watchPath;
    
    bool isAvailable() const pure nothrow
    {
        version(BSD)
            return true;
        version(OSX)
            return true;  // macOS also supports kqueue
        else
            return false;
    }
    
    WatchResult watch(string path, WatchConfig config, WatchBatchCallback callback) @system
    {
        if (!exists(path) || !isDir(path))
        {
            auto error = new IOError(path, "Directory not found", ErrorCode.FileNotFound);
            return WatchResult.err(error);
        }
        
        _watchPath = absolutePath(path);
        _active = true;
        
        version(BSD)
        {
            // Try using kqueue directly
            new Thread(() => runKQueue(config, callback)).start();
            return WatchResult.ok();
        }
        else version(OSX)
        {
            // macOS has kqueue but FSEvents is preferred
            // Still provide kqueue as fallback
            new Thread(() => runKQueue(config, callback)).start();
            return WatchResult.ok();
        }
        else
        {
            auto error = new BuildError("kqueue not supported on this platform");
            return WatchResult.err(error);
        }
    }
    
    void stop() @system
    {
        _active = false;
    }
    
    bool isActive() const pure nothrow @nogc
    {
        return _active;
    }
    
    string name() const pure nothrow
    {
        return "kqueue";
    }
    
    private void runKQueue(WatchConfig config, WatchBatchCallback callback) @system
    {
        version(Posix)
        {
            try
            {
                // Use kevent command-line tool for simplicity
                // Native kqueue implementation would require C bindings
                // Fallback to polling if kevent tool not available
                auto pollingWatcher = new PollingWatcher();
                pollingWatcher.watch(_watchPath, config, callback);
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging.logger;
                Logger.error("kqueue watcher failed: " ~ e.msg);
                _active = false;
            }
        }
        else
        {
            _active = false;
        }
    }
}

/// Polling-based watcher (universal fallback)
final class PollingWatcher : IFileWatcher
{
    private bool _active;
    private string[string] _fileStates;  // path -> hash
    private Mutex _mutex;
    
    this() @system
    {
        _mutex = new Mutex();
    }
    
    bool isAvailable() const pure nothrow
    {
        return true;
    }
    
    WatchResult watch(string path, WatchConfig config, WatchBatchCallback callback) @system
    {
        if (!exists(path) || !isDir(path))
        {
            auto error = new IOError(path, "Directory not found", ErrorCode.FileNotFound);
            return WatchResult.err(error);
        }
        
        _active = true;
        
        // Initialize file states
        scanDirectory(path);
        
        // Start polling thread
        new Thread(() => pollLoop(path, config, callback)).start();
        
        return WatchResult.ok();
    }
    
    void stop() @system
    {
        _active = false;
    }
    
    bool isActive() const pure nothrow @nogc
    {
        return _active;
    }
    
    string name() const pure nothrow
    {
        return "Polling";
    }
    
    private void scanDirectory(string path) @system
    {
        synchronized (_mutex)
        {
            try
            {
                foreach (entry; dirEntries(path, SpanMode.depth))
                {
                    if (entry.isFile && !IgnoreRegistry.shouldIgnorePathAny(entry.name))
                    {
                        _fileStates[entry.name] = getFileState(entry.name);
                    }
                }
            }
            catch (Exception) {}
        }
    }
    
    private void pollLoop(string path, WatchConfig config, WatchBatchCallback callback) @system
    {
        while (_active)
        {
            Thread.sleep(config.pollInterval);
            
            if (!_active)
                break;
            
            FileEvent[] events = detectChanges(path);
            
            if (events.length > 0)
            {
                callback(events);
            }
        }
    }
    
    private FileEvent[] detectChanges(string path) @system
    {
        FileEvent[] events;
        string[string] newStates;
        
        // Scan current files
        try
        {
            foreach (entry; dirEntries(path, SpanMode.depth))
            {
                if (entry.isFile && !IgnoreRegistry.shouldIgnorePathAny(entry.name))
                {
                    string state = getFileState(entry.name);
                    newStates[entry.name] = state;
                    
                    synchronized (_mutex)
                    {
                        auto oldState = entry.name in _fileStates;
                        
                        if (oldState is null)
                        {
                            // New file
                            FileEvent event;
                            event.path = entry.name;
                            event.kind = FileEventKind.Created;
                            event.timestamp = Clock.currTime();
                            events ~= event;
                        }
                        else if (*oldState != state)
                        {
                            // Modified file
                            FileEvent event;
                            event.path = entry.name;
                            event.kind = FileEventKind.Modified;
                            event.timestamp = Clock.currTime();
                            events ~= event;
                        }
                    }
                }
            }
        }
        catch (Exception) {}
        
        // Detect deleted files
        synchronized (_mutex)
        {
            foreach (oldPath; _fileStates.keys)
            {
                if (oldPath !in newStates)
                {
                    FileEvent event;
                    event.path = oldPath;
                    event.kind = FileEventKind.Deleted;
                    event.timestamp = Clock.currTime();
                    events ~= event;
                }
            }
            
            _fileStates = newStates;
        }
        
        return events;
    }
    
    private static string getFileState(string path) @system
    {
        try
        {
            auto info = DirEntry(path);
            return info.size.to!string ~ "|" ~ info.timeLastModified.toUnixTime().to!string;
        }
        catch (Exception)
        {
            return "";
        }
    }
}

/// High-level file watcher with debouncing and batching
final class FileWatcher
{
    private IFileWatcher _impl;
    private WatchConfig _config;
    private bool _active;
    private FileEvent[] _eventQueue;
    private Mutex _queueMutex;
    private SysTime _lastEventTime;  // When last event was received
    private Thread _debounceThread;
    
    this(WatchConfig config = WatchConfig.init) @system
    {
        _config = config;
        _queueMutex = new Mutex();
        _impl = FileWatcherFactory.create();
    }
    
    /// Start watching with callback
    WatchResult watch(string path, void delegate() onChange) @system
    {
        _active = true;
        _lastEventTime = SysTime.min;  // No events yet
        
        // Start debounce thread
        _debounceThread = new Thread(() => debounceLoop(onChange));
        _debounceThread.start();
        
        // Start actual file watcher
        return _impl.watch(path, _config, (const FileEvent[] events) {
            handleEvents(events);
        });
    }
    
    /// Stop watching
    void stop() @system
    {
        _active = false;
        _impl.stop();
        
        if (_debounceThread !is null)
        {
            _debounceThread.join();
        }
    }
    
    /// Check if active
    bool isActive() const pure nothrow @nogc
    {
        return _active;
    }
    
    /// Get implementation name
    string implName() const pure nothrow
    {
        return _impl.name();
    }
    
    private void handleEvents(const FileEvent[] events) @system
    {
        synchronized (_queueMutex)
        {
            foreach (event; events)
            {
                _eventQueue ~= event;
            }
            _lastEventTime = Clock.currTime();  // Update on new events
        }
    }
    
    private void debounceLoop(void delegate() onChange) @system
    {
        while (_active)
        {
            Thread.sleep(50.msecs);
            
            bool shouldTrigger = false;
            synchronized (_queueMutex)
            {
                if (_eventQueue.length > 0)
                {
                    auto timeSinceLastEvent = Clock.currTime() - _lastEventTime;
                    
                    // Trigger only after debounce delay has passed since last event
                    if (timeSinceLastEvent >= _config.debounceDelay)
                    {
                        _eventQueue.length = 0;
                        shouldTrigger = true;
                    }
                }
            }
            
            // Call outside synchronized block to avoid deadlocks
            if (shouldTrigger)
            {
                try { onChange(); }
                catch (Exception e)
                {
                    import infrastructure.utils.logging.logger;
                    Logger.error("Watch callback failed: " ~ e.msg);
                }
            }
        }
    }
}

