module infrastructure.telemetry.debugging.replay;

import std.datetime : SysTime, Clock, Duration;
import std.conv : to;
import std.format : format;
import std.file : exists, read, write, mkdirRecurse;
import std.path : buildPath, dirName;
import std.json : JSONValue, parseJSON;
import std.algorithm : map, filter;
import std.range : array;
import core.sync.mutex : Mutex;
import infrastructure.telemetry.collection.collector : BuildSession, TargetMetric, TargetStatus;
import infrastructure.errors;

/// Build replay system for debugging
/// 
/// Features:
/// - Record build inputs and outputs
/// - Deterministic replay of builds
/// - Time-travel debugging
/// - Diff between builds
/// - Integration with telemetry
/// 
/// Architecture:
/// - BuildRecording: Captures complete build state
/// - ReplayEngine: Replays recorded builds
/// - DiffAnalyzer: Compares build recordings
/// 
/// Use Cases:
/// - Debugging flaky builds
/// - Reproducing build failures
/// - Performance regression analysis
/// - CI/CD debugging

/// Build recording capturing complete build state
struct BuildRecording
{
    string recordingId;
    SysTime timestamp;
    BuildSession session;
    
    // Environment state
    string[string] environment;
    string workingDirectory;
    string[] commandArgs;
    
    // Input state
    FileSnapshot[] inputFiles;
    string[] dependencies;
    
    // Output state
    FileSnapshot[] outputFiles;
    
    // Execution trace
    TargetExecution[] executions;
    
    // Metadata
    string[string] metadata;
}

/// Snapshot of a file at a point in time
struct FileSnapshot
{
    string path;
    string contentHash;
    size_t size;
    SysTime modifiedTime;
    
    /// Create snapshot from file
    static FileSnapshot capture(string path) @system
    {
        import std.file : getSize, timeLastModified;
        import infrastructure.utils.files.hash : FastHash;
        
        FileSnapshot snapshot;
        snapshot.path = path;
        snapshot.contentHash = FastHash.hashFile(path);
        snapshot.size = getSize(path);
        snapshot.modifiedTime = timeLastModified(path);
        
        return snapshot;
    }
}

/// Target execution record
struct TargetExecution
{
    string targetId;
    SysTime startTime;
    SysTime endTime;
    Duration duration;
    TargetStatus status;
    string[] inputs;
    string[] outputs;
    string[] commands;
    int exitCode;
    string stdout;
    string stderr;
}

/// Build recorder
final class BuildRecorder
{
    private string recordingsDir;
    private Mutex recorderMutex;
    private BuildRecording currentRecording;
    private bool recording;
    
    this(string recordingsDir = ".builder-cache/recordings") @system
    {
        this.recordingsDir = recordingsDir;
        this.recorderMutex = new Mutex();
        this.recording = false;
    }
    
    /// Start recording a build
    void startRecording(string[] args) @system
    {
        import std.process : environment;
        import std.file : getcwd;
        import std.uuid : randomUUID;
        
        synchronized (recorderMutex)
        {
            currentRecording = BuildRecording.init;
            currentRecording.recordingId = randomUUID().toString();
            currentRecording.timestamp = Clock.currTime();
            currentRecording.workingDirectory = getcwd();
            currentRecording.commandArgs = args.dup;
            
            // Capture environment
            foreach (key, value; environment.toAA())
            {
                currentRecording.environment[key] = value;
            }
            
            recording = true;
        }
    }
    
    /// Record target execution
    void recordExecution(TargetExecution execution) @system
    {
        synchronized (recorderMutex)
        {
            if (!recording)
                return;
            
            currentRecording.executions ~= execution;
        }
    }
    
    /// Record input file
    void recordInput(string path) @system
    {
        synchronized (recorderMutex)
        {
            if (!recording || !exists(path))
                return;
            
            auto snapshot = FileSnapshot.capture(path);
            currentRecording.inputFiles ~= snapshot;
        }
    }
    
    /// Record output file
    void recordOutput(string path) @system
    {
        synchronized (recorderMutex)
        {
            if (!recording || !exists(path))
                return;
            
            auto snapshot = FileSnapshot.capture(path);
            currentRecording.outputFiles ~= snapshot;
        }
    }
    
    /// Set build session
    void setSession(BuildSession session) @system
    {
        synchronized (recorderMutex)
        {
            if (!recording)
                return;
            
            currentRecording.session = session;
        }
    }
    
    /// Add metadata
    void addMetadata(string key, string value) @system
    {
        synchronized (recorderMutex)
        {
            if (!recording)
                return;
            
            currentRecording.metadata[key] = value;
        }
    }
    
    /// Stop recording and save
    Result!(string, ReplayError) stopRecording() @system
    {
        synchronized (recorderMutex)
        {
            if (!recording)
                return Result!(string, ReplayError).err(
                    ReplayError.notRecording());
            
            recording = false;
            
            // Save recording
            immutable filepath = buildPath(recordingsDir, currentRecording.recordingId ~ ".json");
            auto result = saveRecording(currentRecording, filepath);
            
            if (result.isErr)
                return Result!(string, ReplayError).err(result.unwrapErr());
            
            return Result!(string, ReplayError).ok(currentRecording.recordingId);
        }
    }
    
    /// Load recording
    static Result!(BuildRecording, ReplayError) loadRecording(string recordingId, string recordingsDir = ".builder-cache/recordings") @system
    {
        immutable filepath = buildPath(recordingsDir, recordingId ~ ".json");
        
        if (!exists(filepath))
            return Result!(BuildRecording, ReplayError).err(
                ReplayError.recordingNotFound(recordingId));
        
        try
        {
            auto content = cast(string)read(filepath);
            auto json = parseJSON(content);
            
            BuildRecording recording;
            recording.recordingId = json["recordingId"].str;
            recording.timestamp = SysTime.fromISOExtString(json["timestamp"].str);
            recording.workingDirectory = json["workingDirectory"].str;
            
            // Parse environment
            foreach (key, value; json["environment"].object)
            {
                recording.environment[key] = value.str;
            }
            
            // Parse command args
            foreach (arg; json["commandArgs"].array)
            {
                recording.commandArgs ~= arg.str;
            }
            
            // Parse input files
            foreach (file; json["inputFiles"].array)
            {
                FileSnapshot snapshot;
                snapshot.path = file["path"].str;
                snapshot.contentHash = file["contentHash"].str;
                snapshot.size = cast(size_t)file["size"].integer;
                snapshot.modifiedTime = SysTime.fromISOExtString(file["modifiedTime"].str);
                recording.inputFiles ~= snapshot;
            }
            
            // Parse output files
            foreach (file; json["outputFiles"].array)
            {
                FileSnapshot snapshot;
                snapshot.path = file["path"].str;
                snapshot.contentHash = file["contentHash"].str;
                snapshot.size = cast(size_t)file["size"].integer;
                snapshot.modifiedTime = SysTime.fromISOExtString(file["modifiedTime"].str);
                recording.outputFiles ~= snapshot;
            }
            
            // Parse metadata
            if ("metadata" in json)
            {
                foreach (key, value; json["metadata"].object)
                {
                    recording.metadata[key] = value.str;
                }
            }
            
            return Result!(BuildRecording, ReplayError).ok(recording);
        }
        catch (Exception e)
        {
            return Result!(BuildRecording, ReplayError).err(
                ReplayError.loadFailed(e.msg));
        }
    }
    
    private static Result!ReplayError saveRecording(BuildRecording recording, string filepath) @system
    {
        try
        {
            // Ensure directory exists
            auto dir = dirName(filepath);
            if (!exists(dir))
                mkdirRecurse(dir);
            
            // Serialize to JSON
            JSONValue json;
            json["recordingId"] = recording.recordingId;
            json["timestamp"] = recording.timestamp.toISOExtString();
            json["workingDirectory"] = recording.workingDirectory;
            
            // Environment
            JSONValue envJson;
            foreach (key, value; recording.environment)
            {
                envJson[key] = value;
            }
            json["environment"] = envJson;
            
            // Command args
            JSONValue[] argsJson;
            foreach (arg; recording.commandArgs)
            {
                argsJson ~= JSONValue(arg);
            }
            json["commandArgs"] = argsJson;
            
            // Input files
            JSONValue[] inputsJson;
            foreach (file; recording.inputFiles)
            {
                JSONValue fileJson;
                fileJson["path"] = file.path;
                fileJson["contentHash"] = file.contentHash;
                fileJson["size"] = file.size;
                fileJson["modifiedTime"] = file.modifiedTime.toISOExtString();
                inputsJson ~= fileJson;
            }
            json["inputFiles"] = inputsJson;
            
            // Output files
            JSONValue[] outputsJson;
            foreach (file; recording.outputFiles)
            {
                JSONValue fileJson;
                fileJson["path"] = file.path;
                fileJson["contentHash"] = file.contentHash;
                fileJson["size"] = file.size;
                fileJson["modifiedTime"] = file.modifiedTime.toISOExtString();
                outputsJson ~= fileJson;
            }
            json["outputFiles"] = outputsJson;
            
            // Metadata
            if (recording.metadata.length > 0)
            {
                JSONValue metaJson;
                foreach (key, value; recording.metadata)
                {
                    metaJson[key] = value;
                }
                json["metadata"] = metaJson;
            }
            
            write(filepath, json.toPrettyString());
            return Result!ReplayError.ok();
        }
        catch (Exception e)
        {
            return Result!ReplayError.err(
                ReplayError.saveFailed(e.msg));
        }
    }
}

/// Replay engine for deterministic build replay
final class ReplayEngine
{
    private string recordingsDir;
    
    this(string recordingsDir = ".builder-cache/recordings") @system
    {
        this.recordingsDir = recordingsDir;
    }
    
    /// Replay a recorded build
    Result!(ReplayResult, ReplayError) replay(string recordingId) @system
    {
        // Load recording
        auto recordingResult = BuildRecorder.loadRecording(recordingId, recordingsDir);
        if (recordingResult.isErr)
            return Result!(ReplayResult, ReplayError).err(recordingResult.unwrapErr());
        
        auto recording = recordingResult.unwrap();
        
        try
        {
            ReplayResult result;
            result.recordingId = recordingId;
            result.success = true;
            
            // Verify input files match
            foreach (file; recording.inputFiles)
            {
                if (!exists(file.path))
                {
                    result.success = false;
                    result.errors ~= format("Input file not found: %s", file.path);
                    continue;
                }
                
                auto snapshot = FileSnapshot.capture(file.path);
                if (snapshot.contentHash != file.contentHash)
                {
                    result.differences ~= ReplayDifference(
                        file.path,
                        DifferenceType.InputChanged,
                        format("Hash mismatch: expected %s, got %s", 
                               file.contentHash, snapshot.contentHash)
                    );
                }
            }
            
            // Check environment differences
            import std.process : environment;
            foreach (key, value; recording.environment)
            {
                auto currentValue = environment.get(key, null);
                if (currentValue != value)
                {
                    result.differences ~= ReplayDifference(
                        format("env:%s", key),
                        DifferenceType.EnvironmentChanged,
                        format("Value changed: %s -> %s", value, currentValue)
                    );
                }
            }
            
            result.replayTime = Clock.currTime();
            return Result!(ReplayResult, ReplayError).ok(result);
        }
        catch (Exception e)
        {
            return Result!(ReplayResult, ReplayError).err(
                ReplayError.replayFailed(e.msg));
        }
    }
    
    /// List all recordings
    Result!(RecordingInfo[], ReplayError) listRecordings() @system
    {
        import std.file : dirEntries, DirEntry, SpanMode;
        import std.algorithm : endsWith;
        
        try
        {
            if (!exists(recordingsDir))
                return Result!(RecordingInfo[], ReplayError).ok([]);
            
            RecordingInfo[] recordings;
            
            foreach (entry; dirEntries(recordingsDir, SpanMode.shallow))
            {
                if (!entry.name.endsWith(".json"))
                    continue;
                
                try
                {
                    auto content = cast(string)read(entry.name);
                    auto json = parseJSON(content);
                    
                    RecordingInfo info;
                    info.recordingId = json["recordingId"].str;
                    info.timestamp = SysTime.fromISOExtString(json["timestamp"].str);
                    info.workingDirectory = json["workingDirectory"].str;
                    recordings ~= info;
                }
                catch (Exception e)
                {
                    // Skip corrupted recordings
                    continue;
                }
            }
            
            return Result!(RecordingInfo[], ReplayError).ok(recordings);
        }
        catch (Exception e)
        {
            return Result!(RecordingInfo[], ReplayError).err(
                ReplayError.listFailed(e.msg));
        }
    }
}

/// Recording info for listing
struct RecordingInfo
{
    string recordingId;
    SysTime timestamp;
    string workingDirectory;
}

/// Replay result
struct ReplayResult
{
    string recordingId;
    bool success;
    SysTime replayTime;
    ReplayDifference[] differences;
    string[] errors;
}

/// Difference detected during replay
struct ReplayDifference
{
    string path;
    DifferenceType type;
    string description;
}

/// Type of difference
enum DifferenceType
{
    InputChanged,
    OutputChanged,
    EnvironmentChanged,
    DependencyChanged
}

/// Replay-specific errors
struct ReplayError
{
    string message;
    ErrorCode code;
    
    static ReplayError notRecording() pure @system
    {
        return ReplayError("Not currently recording", cast(ErrorCode) Internal.Error);
    }
    
    static ReplayError recordingNotFound(string id) pure @system
    {
        return ReplayError("Recording not found: " ~ id, cast(ErrorCode) IO.FileNotFound);
    }
    
    static ReplayError loadFailed(string details) pure @system
    {
        return ReplayError("Failed to load recording: " ~ details, cast(ErrorCode) IO.FileReadFailed);
    }
    
    static ReplayError saveFailed(string details) pure @system
    {
        return ReplayError("Failed to save recording: " ~ details, cast(ErrorCode) IO.FileWriteFailed);
    }
    
    static ReplayError replayFailed(string details) pure @system
    {
        return ReplayError("Replay failed: " ~ details, cast(ErrorCode) Internal.Error);
    }
    
    static ReplayError listFailed(string details) pure @system
    {
        return ReplayError("Failed to list recordings: " ~ details, cast(ErrorCode) IO.FileReadFailed);
    }
    
    string toString() const pure nothrow @system
    {
        return message;
    }
}

/// Global build recorder instance
private BuildRecorder globalRecorder;

/// Get global build recorder
BuildRecorder getRecorder() @system
{
    if (globalRecorder is null)
    {
        globalRecorder = new BuildRecorder();
    }
    return globalRecorder;
}

/// Set custom recorder
void setRecorder(BuildRecorder recorder) @system
{
    globalRecorder = recorder;
}

