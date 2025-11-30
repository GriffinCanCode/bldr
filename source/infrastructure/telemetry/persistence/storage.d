module infrastructure.telemetry.persistence.storage;

import std.file : exists, mkdirRecurse, read, write;
import std.path : buildPath;
import std.datetime : SysTime, Duration, Clock, dur;
import std.algorithm : sort, filter;
import std.range : array;
import core.sync.mutex : Mutex;
import infrastructure.telemetry.collection.collector;
import infrastructure.telemetry.collection.environment : BuildEnvironment;
import infrastructure.telemetry.persistence.schema;
import infrastructure.utils.serialization;
import infrastructure.utils.files.directories : ensureDirectoryWithGitignore;
import infrastructure.errors;

/// High-performance binary storage for telemetry data
/// Uses SIMD-accelerated serialization framework
/// Thread-safe with mutex protection
final class TelemetryStorage
{
    private string storageDir;
    private immutable string storageFile;
    private BuildSession[] sessions;
    private Mutex storageMutex;
    private TelemetryConfig config;
    
    this(string storageDir = ".builder-cache/telemetry", TelemetryConfig config = TelemetryConfig.init) @system
    {
        this.storageDir = storageDir;
        this.storageFile = buildPath(storageDir, "telemetry.bin");
        this.storageMutex = new Mutex();
        this.config = config;
        
        ensureDirectoryWithGitignore(storageDir);
        
        loadSessions();
    }
    
    /// Add a new session - thread-safe
    Result!TelemetryError append(BuildSession session) @system
    {
        synchronized (storageMutex)
        {
            sessions ~= session;
            
            // Apply retention policy
            applyRetention();
            
            return persist();
        }
    }
    
    /// Get all sessions - thread-safe
    Result!(BuildSession[], TelemetryError) getSessions() @system
    {
        synchronized (storageMutex)
        {
            return Result!(BuildSession[], TelemetryError).ok(sessions.dup);
        }
    }
    
    /// Get recent sessions - thread-safe
    Result!(BuildSession[], TelemetryError) getRecent(size_t count) @system
    {
        synchronized (storageMutex)
        {
            immutable limit = count < sessions.length ? count : sessions.length;
            if (limit == 0)
                return Result!(BuildSession[], TelemetryError).ok([]);
            
            return Result!(BuildSession[], TelemetryError).ok(
                sessions[$ - limit .. $].dup
            );
        }
    }
    
    /// Clear all telemetry data - thread-safe
    Result!TelemetryError clear() @system
    {
        synchronized (storageMutex)
        {
            sessions = [];
            return persist();
        }
    }
    
    /// Load sessions from binary file using high-performance Codec
    private void loadSessions() @system
    {
        if (!exists(storageFile))
        {
            sessions = [];
            return;
        }
        
        try
        {
            // Read entire file
            auto data = cast(ubyte[])read(storageFile);
            
            // Deserialize with codec
            auto result = Codec.deserialize!SerializableTelemetryContainer(data);
            
            if (result.isErr)
            {
                // Corrupted file - start fresh
                sessions = [];
                return;
            }
            
            auto container = result.unwrap();
            
            // Convert to runtime format
            sessions = [];
            sessions.reserve(container.sessions.length);
            
            foreach (ref serialSession; container.sessions)
            {
                sessions ~= fromSerializable!(BuildSession, BuildEnvironment, TargetMetric, TargetStatus)(serialSession);
            }
        }
        catch (Exception e)
        {
            // Failed to load - start fresh
            sessions = [];
        }
    }
    
    /// Persist sessions to disk using high-performance Codec
    private Result!TelemetryError persist() @system
    {
        try
        {
            // Convert to serializable format
            SerializableBuildSession[] serializable;
            serializable.reserve(sessions.length);
            
            foreach (ref session; sessions)
            {
                serializable ~= toSerializable(session);
            }
            
            // Create container
            SerializableTelemetryContainer container;
            container.sessions = serializable;
            
            // Serialize with high-performance codec
            auto data = Codec.serialize(container);
            
            // Write to temporary file first (atomic write)
            auto tempFile = storageFile ~ ".tmp";
            scope(exit)
            {
                if (exists(tempFile))
                    remove(tempFile);
            }
            
            write(tempFile, data);
            
            // Atomic rename
            if (exists(storageFile))
                remove(storageFile);
            rename(tempFile, storageFile);
            
            return Result!TelemetryError.ok();
        }
        catch (Exception e)
        {
            return Result!TelemetryError.err(
                TelemetryError.storageError("Failed to persist: " ~ e.msg)
            );
        }
    }
    
    /// Apply retention policy
    private void applyRetention() @system
    {
        // Remove old sessions beyond max count
        if (config.maxSessions > 0 && sessions.length > config.maxSessions)
        {
            sessions = sessions[$ - config.maxSessions .. $];
        }
        
        // Remove sessions older than max age
        if (config.maxAge.total!"seconds" > 0)
        {
            auto cutoff = Clock.currTime() - config.maxAge;
            sessions = sessions.filter!(s => s.startTime > cutoff).array;
        }
    }
    
    private void remove(string path) @system
    {
        import std.file : remove;
        remove(path);
    }
    
    private void rename(string from, string to) @system
    {
        import std.file : rename;
        rename(from, to);
    }
}

/// Telemetry configuration
struct TelemetryConfig
{
    bool enabled = true;                // Enable telemetry collection
    size_t maxSessions = 100;           // Maximum sessions to keep
    Duration maxAge = dur!"days"(30);   // Maximum age of sessions
    bool autoCleanup = true;            // Automatically clean old sessions
    
    /// Load configuration from environment
    static TelemetryConfig fromEnvironment() @system
    {
        import std.process : environment;
        import std.conv : to;
        
        TelemetryConfig config;
        
        // Optional: Enable/disable telemetry
        immutable enabledStr = environment.get("BUILDER_TELEMETRY_ENABLED", "1");
        config.enabled = enabledStr != "false" && enabledStr != "0";
        
        // Optional: Max sessions
        immutable maxSessionsStr = environment.get("BUILDER_TELEMETRY_MAX_SESSIONS");
        if (maxSessionsStr.length > 0)
            config.maxSessions = maxSessionsStr.to!size_t;
        
        // Optional: Max age (days)
        immutable maxAgeDaysStr = environment.get("BUILDER_TELEMETRY_MAX_AGE_DAYS");
        if (maxAgeDaysStr.length > 0)
            config.maxAge = dur!"days"(maxAgeDaysStr.to!long);
        
        // Optional: Auto cleanup
        immutable autoCleanupStr = environment.get("BUILDER_TELEMETRY_AUTO_CLEANUP");
        if (autoCleanupStr.length > 0)
            config.autoCleanup = autoCleanupStr != "false" && autoCleanupStr != "0";
        
        return config;
    }
}
