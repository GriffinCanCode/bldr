module engine.distributed.protocol.protocol;

import std.datetime : Duration, SysTime, Clock, seconds, dur, msecs;
import std.conv : to;
import std.digest : toHexString;
import std.bitmanip : write, read;
import std.string : toLower;
import infrastructure.errors;

// Re-export NetworkError from infrastructure.errors for backward compatibility
public import infrastructure.errors.types.network : NetworkError;

/// Protocol version for compatibility checking
enum ProtocolVersion : ubyte
{
    V1 = 1
}

/// Unique identifier for messages (for correlation and deduplication)
struct MessageId
{
    ulong value;
    
    static MessageId generate() @trusted
    {
        import std.random : uniform;
        return MessageId(uniform!ulong());
    }
    
    string toString() const pure @safe => value.to!string;
}

/// Worker identifier (unique per worker instance)
struct WorkerId
{
    ulong value;
    
    static WorkerId broadcast() pure nothrow @safe @nogc => WorkerId(0);  // Broadcast sentinel
    bool isBroadcast() const pure nothrow @safe @nogc => value == 0;
    string toString() const pure @safe => value.to!string;
}

/// Action identifier (content-addressed via BLAKE3)
struct ActionId
{
    ubyte[32] hash;  // BLAKE3 output
    
    this(const ubyte[32] hash) pure nothrow @safe @nogc { this.hash = hash; }
    this(const ubyte[] hash) pure @safe
    {
        assert(hash.length == 32, "ActionId requires 32-byte hash");
        this.hash[] = hash[0 .. 32];
    }
    
    string toString() const @trusted => toHexString(hash[]).toLower();
    bool opEquals(const ActionId other) const pure nothrow @safe @nogc => hash == other.hash;
    size_t toHash() const pure nothrow @trusted @nogc => *cast(size_t*)hash.ptr;
}

/// Artifact identifier (content-addressed via BLAKE3)
alias ArtifactId = ActionId;

/// Worker state enum (finite state machine)
enum WorkerState : ubyte
{
    Idle,       // Waiting for work
    Executing,  // Running build action
    Stealing,   // Attempting work theft
    Uploading,  // Uploading artifacts
    Failed,     // Permanent failure
    Draining    // Graceful shutdown
}

/// Action execution status
enum ResultStatus : ubyte
{
    Success,    // Completed successfully
    Failure,    // Command returned non-zero
    Timeout,    // Exceeded time limit
    Cancelled,  // Explicitly cancelled
    Error       // Internal error (sandbox, network, etc.)
}

/// Scheduling priority (higher = more urgent)
enum Priority : ubyte
{
    Low = 0,
    Normal = 50,
    High = 100,
    Critical = 200
}

/// Message compression algorithm
enum Compression : ubyte
{
    None = 0,
    Zstd = 1,
    Lz4 = 2
}

/// Security capabilities for hermetic execution
struct Capabilities
{
    bool network = false;           // Network access allowed?
    bool writeHome = false;         // Write to $HOME allowed?
    bool writeTmp = true;           // Write to /tmp allowed?
    string[] readPaths;             // Readable paths
    string[] writePaths;            // Writable paths
    size_t maxCpu = 0;              // Max CPU cores (0 = unlimited)
    size_t maxMemory = 0;           // Max memory bytes (0 = unlimited)
    Duration timeout = 1.seconds;   // Execution timeout
    
    /// Serialize to binary
    ubyte[] serialize() const pure @trusted
    {
        ubyte[] buffer;
        buffer.reserve(256);
        
        // Flags (compact bit manipulation)
        immutable flags = cast(ubyte)((network ? 0x01 : 0) | (writeHome ? 0x02 : 0) | (writeTmp ? 0x04 : 0));
        buffer.write!ubyte(flags, buffer.length);
        
        // Paths (length-prefixed arrays)
        buffer.write!uint(cast(uint)readPaths.length, buffer.length);
        foreach (path; readPaths)
        {
            buffer.write!uint(cast(uint)path.length, buffer.length);
            buffer ~= cast(ubyte[])path;
        }
        
        buffer.write!uint(cast(uint)writePaths.length, buffer.length);
        foreach (path; writePaths)
        {
            buffer.write!uint(cast(uint)path.length, buffer.length);
            buffer ~= cast(ubyte[])path;
        }
        
        // Resource limits
        buffer.write!ulong(maxCpu, buffer.length);
        buffer.write!ulong(maxMemory, buffer.length);
        buffer.write!long(timeout.total!"msecs", buffer.length);
        
        return buffer;
    }
    
    /// Deserialize from binary
    static BuildResult!Capabilities deserialize(const ubyte[] data) @system
    {
        if (data.length < 1)
            return Err!(Capabilities, BuildError)(DistributedErrors.protocol("Invalid capabilities: empty data").build());
        
        Capabilities caps;
        size_t offset = 0;
        ubyte[] mutableData = cast(ubyte[])data.dup;
        
        try
        {
            // Flags
            auto flagSlice = mutableData[offset .. offset + 1];
            immutable flags = flagSlice.read!ubyte();
            offset += 1;
            caps.network = (flags & 0x01) != 0;
            caps.writeHome = (flags & 0x02) != 0;
            caps.writeTmp = (flags & 0x04) != 0;
            
            // Read paths
            auto readCountSlice = mutableData[offset .. offset + 4];
            immutable readCount = readCountSlice.read!uint();
            offset += 4;
            caps.readPaths.reserve(readCount);
            foreach (_; 0 .. readCount)
            {
                auto lenSlice = mutableData[offset .. offset + 4];
                immutable len = lenSlice.read!uint();
                offset += 4;
                caps.readPaths ~= cast(string)data[offset .. offset + len];
                offset += len;
            }
            
            // Write paths
            auto writeCountSlice = mutableData[offset .. offset + 4];
            immutable writeCount = writeCountSlice.read!uint();
            offset += 4;
            caps.writePaths.reserve(writeCount);
            foreach (_; 0 .. writeCount)
            {
                auto lenSlice2 = mutableData[offset .. offset + 4];
                immutable len = lenSlice2.read!uint();
                offset += 4;
                caps.writePaths ~= cast(string)data[offset .. offset + len];
                offset += len;
            }
            
            // Resource limits
            auto cpuSlice = mutableData[offset .. offset + 8];
            caps.maxCpu = cpuSlice.read!ulong();
            offset += 8;
            auto memSlice = mutableData[offset .. offset + 8];
            caps.maxMemory = memSlice.read!ulong();
            offset += 8;
            auto timeSlice = mutableData[offset .. offset + 8];
            immutable timeoutMs = timeSlice.read!long();
            caps.timeout = dur!"msecs"(timeoutMs);
            
            return Ok!(Capabilities, BuildError)(caps);
        }
        catch (Exception e)
        {
            return Err!(Capabilities, BuildError)(DistributedErrors.deserialize("capabilities: " ~ e.msg).build());
        }
    }
}

/// Input artifact specification
struct InputSpec
{
    ArtifactId id;      // Artifact identifier
    string path;        // Mounted path in sandbox
    bool executable;    // Executable bit?
}

/// Output artifact specification
struct OutputSpec
{
    string path;        // Path in sandbox
    bool optional;      // Failure if missing?
}

/// Resource usage metrics
struct ResourceUsage
{
    Duration cpuTime;       // Total CPU time
    size_t peakMemory;      // Peak memory usage (bytes)
    size_t diskRead;        // Disk bytes read
    size_t diskWrite;       // Disk bytes written
    size_t networkTx;       // Network bytes sent
    size_t networkRx;       // Network bytes received
}

/// System metrics (for health monitoring)
struct SystemMetrics
{
    float cpuUsage;         // CPU utilization [0.0, 1.0]
    float memoryUsage;      // Memory utilization [0.0, 1.0]
    float diskUsage;        // Disk utilization [0.0, 1.0]
    size_t queueDepth;      // Local queue size
    size_t activeActions;   // Currently executing
}

/// Build action request (coordinator → worker)
final class ActionRequest
{
    ActionId id;                    // Unique action identifier
    string command;                 // Shell command to execute
    string[string] env;             // Environment variables
    InputSpec[] inputs;             // Input artifacts
    OutputSpec[] outputs;           // Expected outputs
    Capabilities capabilities;      // Security sandbox
    Priority priority;              // Scheduling priority
    Duration timeout;               // Max execution time
    
    this(ActionId id, string command, string[string] env, 
         InputSpec[] inputs, OutputSpec[] outputs,
         Capabilities capabilities, Priority priority, Duration timeout) @safe
    {
        this.id = id;
        this.command = command;
        this.env = env;
        this.inputs = inputs;
        this.outputs = outputs;
        this.capabilities = capabilities;
        this.priority = priority;
        this.timeout = timeout;
    }
    
    /// Serialize to binary format
    ubyte[] serialize() const pure @trusted
    {
        ubyte[] buffer;
        buffer.reserve(4096);
        
        // Action ID
        buffer ~= id.hash;
        
        // Command (length-prefixed string)
        buffer.write!uint(cast(uint)command.length, buffer.length);
        buffer ~= cast(ubyte[])command;
        
        // Environment (count + key-value pairs)
        buffer.write!uint(cast(uint)env.length, buffer.length);
        foreach (key, value; env)
        {
            buffer.write!uint(cast(uint)key.length, buffer.length);
            buffer ~= cast(ubyte[])key;
            buffer.write!uint(cast(uint)value.length, buffer.length);
            buffer ~= cast(ubyte[])value;
        }
        
        // Inputs
        buffer.write!uint(cast(uint)inputs.length, buffer.length);
        foreach (input; inputs)
        {
            buffer ~= input.id.hash;
            buffer.write!uint(cast(uint)input.path.length, buffer.length);
            buffer ~= cast(ubyte[])input.path;
            buffer.write!ubyte(input.executable ? 1 : 0, buffer.length);
        }
        
        // Outputs
        buffer.write!uint(cast(uint)outputs.length, buffer.length);
        foreach (output; outputs)
        {
            buffer.write!uint(cast(uint)output.path.length, buffer.length);
            buffer ~= cast(ubyte[])output.path;
            buffer.write!ubyte(output.optional ? 1 : 0, buffer.length);
        }
        
        // Capabilities
        auto capsData = capabilities.serialize();
        buffer.write!uint(cast(uint)capsData.length, buffer.length);
        buffer ~= capsData;
        
        // Priority and timeout
        buffer.write!ubyte(priority, buffer.length);
        buffer.write!long(timeout.total!"msecs", buffer.length);
        
        return buffer;
    }
    
    /// Deserialize from binary format
    static Result!(ActionRequest, DistributedError) deserialize(const ubyte[] data) @system
    {
        if (data.length < 32)
            return Err!(ActionRequest, DistributedError)(DistributedErrors.protocol("ActionRequest data too short").build());
        
        size_t offset = 0;
        ubyte[] mutableData = cast(ubyte[])data.dup;
        
        try
        {
            // Action ID (32 bytes)
            auto actionId = ActionId(data[offset .. offset + 32]);
            offset += 32;
            
            // Command string
            if (offset + 4 > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Command length").build());
            auto cmdLenSlice = mutableData[offset .. offset + 4];
            immutable cmdLen = cmdLenSlice.read!uint();
            offset += 4;
            
            if (offset + cmdLen > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Command data").build());
            auto command = cast(string)data[offset .. offset + cmdLen];
            offset += cmdLen;
            
            // Environment variables
            if (offset + 4 > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Env count").build());
            auto envCountSlice = mutableData[offset .. offset + 4];
            immutable envCount = envCountSlice.read!uint();
            offset += 4;
            
            string[string] env;
            foreach (_; 0 .. envCount)
            {
                if (offset + 4 > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Env key length").build());
                auto keyLenSlice = mutableData[offset .. offset + 4];
                immutable keyLen = keyLenSlice.read!uint();
                offset += 4;
                
                if (offset + keyLen > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Env key").build());
                auto key = cast(string)data[offset .. offset + keyLen];
                offset += keyLen;
                
                if (offset + 4 > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Env value length").build());
                auto valLenSlice = mutableData[offset .. offset + 4];
                immutable valLen = valLenSlice.read!uint();
                offset += 4;
                
                if (offset + valLen > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Env value").build());
                auto value = cast(string)data[offset .. offset + valLen];
                offset += valLen;
                
                env[key] = value;
            }
            
            // Input specs
            if (offset + 4 > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Input count").build());
            auto inputCountSlice = mutableData[offset .. offset + 4];
            immutable inputCount = inputCountSlice.read!uint();
            offset += 4;
            
            InputSpec[] inputs;
            inputs.reserve(inputCount);
            foreach (_; 0 .. inputCount)
            {
                if (offset + 32 > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Input ID").build());
                auto inputId = ArtifactId(data[offset .. offset + 32]);
                offset += 32;
                
                if (offset + 4 > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Input path length").build());
                auto pathLenSlice = mutableData[offset .. offset + 4];
                immutable pathLen = pathLenSlice.read!uint();
                offset += 4;
                
                if (offset + pathLen > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Input path").build());
                auto path = cast(string)data[offset .. offset + pathLen];
                offset += pathLen;
                
                if (offset + 1 > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Input executable flag").build());
                auto execSlice = mutableData[offset .. offset + 1];
                immutable executable = execSlice.read!ubyte() != 0;
                offset += 1;
                
                inputs ~= InputSpec(inputId, path, executable);
            }
            
            // Output specs
            if (offset + 4 > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Output count").build());
            auto outputCountSlice = mutableData[offset .. offset + 4];
            immutable outputCount = outputCountSlice.read!uint();
            offset += 4;
            
            OutputSpec[] outputs;
            outputs.reserve(outputCount);
            foreach (_; 0 .. outputCount)
            {
                if (offset + 4 > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Output path length").build());
                auto pathLenSlice2 = mutableData[offset .. offset + 4];
                immutable pathLen = pathLenSlice2.read!uint();
                offset += 4;
                
                if (offset + pathLen > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Output path").build());
                auto path = cast(string)data[offset .. offset + pathLen];
                offset += pathLen;
                
                if (offset + 1 > data.length)
                    return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Output optional flag").build());
                auto optSlice = mutableData[offset .. offset + 1];
                immutable optional = optSlice.read!ubyte() != 0;
                offset += 1;
                
                outputs ~= OutputSpec(path, optional);
            }
            
            // Capabilities
            if (offset + 4 > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Capabilities length").build());
            auto capsLenSlice = mutableData[offset .. offset + 4];
            immutable capsLen = capsLenSlice.read!uint();
            offset += 4;
            
            if (offset + capsLen > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Capabilities data").build());
            auto capsResult = Capabilities.deserialize(data[offset .. offset + capsLen]);
            if (capsResult.isErr)
                return Err!(ActionRequest, DistributedError)(cast(DistributedError)capsResult.unwrapErr());
            auto capabilities = capsResult.unwrap();
            offset += capsLen;
            
            // Priority
            if (offset + 1 > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Priority").build());
            auto priSlice = mutableData[offset .. offset + 1];
            immutable priority = cast(Priority)priSlice.read!ubyte();
            offset += 1;
            
            // Timeout
            if (offset + 8 > data.length)
                return Err!(ActionRequest, DistributedError)(DistributedErrors.truncated("Timeout").build());
            auto timeSlice = mutableData[offset .. offset + 8];
            immutable timeout = timeSlice.read!long().msecs;
            
            auto request = new ActionRequest(actionId, command, env, inputs, outputs, capabilities, priority, timeout);
            return Ok!(ActionRequest, DistributedError)(request);
        }
        catch (Exception e)
        {
            return Err!(ActionRequest, DistributedError)(DistributedErrors.deserialize(e.msg).build());
        }
    }
}

/// Build action result (worker → coordinator)
struct ActionResult
{
    ActionId id;                // Which action
    ResultStatus status;        // Outcome
    Duration duration;          // Execution time
    ArtifactId[] outputs;       // Generated artifacts
    string stdout;              // Captured stdout
    string stderr;              // Captured stderr
    int exitCode;               // Process exit code
    ResourceUsage resources;    // Resource consumption
}

/// Work steal request (worker → worker)
struct StealRequest
{
    WorkerId thief;     // Who wants work
    WorkerId victim;    // Who has work
    Priority minPriority = Priority.Low;  // Only steal if >= this
}

/// Work steal response (worker → worker)
struct StealResponse
{
    WorkerId victim;        // Who responded
    WorkerId thief;         // Who asked
    bool hasWork;           // Work available?
    ActionRequest action;   // Stolen action (if hasWork)
}

/// Heartbeat message (worker → coordinator)
struct HeartBeat
{
    WorkerId worker;        // Worker identifier
    WorkerState state;      // Current state
    SystemMetrics metrics;  // System metrics
    SysTime timestamp;      // When sent
}

/// Shutdown command (coordinator → worker)
struct Shutdown
{
    bool graceful;          // Finish current work?
    Duration timeout;       // Max wait time
}

/// Message envelope (wraps all messages)
struct Envelope(T)
{
    ProtocolVersion version_ = ProtocolVersion.V1;
    MessageId id;
    WorkerId sender;
    WorkerId recipient;
    SysTime timestamp;
    Compression compression = Compression.None;
    T payload;
    
    this(WorkerId sender, WorkerId recipient, T payload) @safe
    {
        this.id = MessageId.generate();
        this.sender = sender;
        this.recipient = recipient;
        this.timestamp = Clock.currTime;
        this.payload = payload;
    }
}

/// Distributed build error - base class for distributed system errors
class DistributedError : BaseBuildError
{
    this(string message, string file = __FILE__, size_t line = __LINE__) @trusted
    {
        super(ErrorCode.DistributedError, message);
        addContext(ErrorContext("file", file));
        addContext(ErrorContext("line", line.to!string));
    }
    
    this(ErrorCode code, string message, string file = __FILE__, size_t line = __LINE__) @trusted
    {
        super(code, message);
        addContext(ErrorContext("file", file));
        addContext(ErrorContext("line", line.to!string));
    }
}

/// Execution errors (sandbox, timeout, etc.)
class ExecutionError : DistributedError
{
    this(string message, string file = __FILE__, size_t line = __LINE__) @safe =>
        super(ErrorCode.SandboxError, "Execution failed: " ~ message, file, line);
}

/// Worker errors (unavailable, failed, etc.)
class WorkerError : DistributedError
{
    this(string message, string file = __FILE__, size_t line = __LINE__) @safe =>
        super(ErrorCode.WorkerFailed, "Worker error: " ~ message, file, line);
}

/// Unified distributed error factory
/// 
/// Usage:
///   DistributedErrors.protocol("Invalid message format")
///       .withContext("parsing", "message header")
///       .withSuggestion("Check protocol version compatibility")
struct DistributedErrors
{
    @disable this();
    
    /// Generic distributed protocol error
    static ErrorBuilder!DistributedError protocol(string message, string file = __FILE__, size_t line = __LINE__)
    {
        auto err = new DistributedError(message, file, line);
        return ErrorBuilder!DistributedError(err);
    }
    
    /// Distributed error with specific code
    static ErrorBuilder!DistributedError withCode(ErrorCode code, string message, string file = __FILE__, size_t line = __LINE__)
    {
        auto err = new DistributedError(code, message, file, line);
        return ErrorBuilder!DistributedError(err);
    }
    
    /// Deserialization error
    static ErrorBuilder!DistributedError deserialize(string context, string file = __FILE__, size_t line = __LINE__)
    {
        auto err = new DistributedError("Deserialization failed: " ~ context, file, line);
        return ErrorBuilder!DistributedError(err);
    }
    
    /// Data truncation error
    static ErrorBuilder!DistributedError truncated(string field, string file = __FILE__, size_t line = __LINE__)
    {
        auto err = new DistributedError(field ~ " truncated", file, line);
        return ErrorBuilder!DistributedError(err);
    }
    
    /// Execution error
    static ErrorBuilder!ExecutionError execution(string message, string file = __FILE__, size_t line = __LINE__)
    {
        auto err = new ExecutionError(message, file, line);
        return ErrorBuilder!ExecutionError(err);
    }
    
    /// Worker error
    static ErrorBuilder!WorkerError worker(string message, string file = __FILE__, size_t line = __LINE__)
    {
        auto err = new WorkerError(message, file, line);
        return ErrorBuilder!WorkerError(err);
    }
}

/// ErrorBuilder support for DistributedError (allows wrapping existing instances)
struct ErrorBuilder(T : DistributedError)
{
    private T error;
    
    this(T error) { this.error = error; }
    
    static ErrorBuilder create(Args...)(Args args)
    {
        ErrorBuilder builder;
        builder.error = new T(args);
        return builder;
    }
    
    ref ErrorBuilder withContext(string operation, string details = "") return
    {
        error.addContext(ErrorContext(operation, details));
        return this;
    }
    
    ref ErrorBuilder withSuggestion(ErrorSuggestion suggestion) return
    {
        error.addSuggestion(suggestion);
        return this;
    }
    
    ref ErrorBuilder withSuggestion(string suggestion) return
    {
        error.addSuggestion(suggestion);
        return this;
    }
    
    ref ErrorBuilder withCommand(string description, string cmd) return
    {
        error.addSuggestion(ErrorSuggestion.command(description, cmd));
        return this;
    }
    
    ref ErrorBuilder withDocs(string description, string url = "") return
    {
        error.addSuggestion(ErrorSuggestion.docs(description, url));
        return this;
    }
    
    T build() { return error; }
    alias build this;
}
