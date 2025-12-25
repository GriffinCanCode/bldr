module engine.runtime.hermetic.platforms.windows;

version(Windows):

import std.file : exists, mkdirRecurse, tempDir;
import std.path : buildPath;
import std.conv : to;
import std.string : toStringz, fromStringz;
import std.array : appender;
import engine.runtime.hermetic.core.spec;
import engine.runtime.hermetic.monitoring;
import engine.runtime.hermetic.monitoring.windows;
import infrastructure.errors;

/// Windows job object-based sandboxing
/// Uses Windows Job Objects for resource limits and process isolation
/// 
/// Design: Job Objects provide:
/// - Process tree isolation (all child processes contained)
/// - Resource limits (memory, CPU time, process count, working set)
/// - Termination guarantees (kill all processes on job close)
/// - I/O accounting for resource monitoring
/// - UI restrictions (clipboard, desktop isolation)
/// - CPU rate limiting (Windows 8+)
/// 
/// Security: Explicitly disables BREAKAWAY_OK to prevent process escape
/// 
/// Note: Windows doesn't provide filesystem/network isolation at the same
/// level as Linux namespaces or macOS sandbox-exec. This provides partial
/// hermeticity through process and resource control.
struct WindowsSandbox
{
    private SandboxSpec spec;
    private string workDir;
    private HANDLE jobHandle;
    private HANDLE completionPort;
    
    /// Create sandbox from spec
    static Result!WindowsSandbox create(SandboxSpec spec, string workDir_) @system
    {
        WindowsSandbox sandbox;
        sandbox.spec = spec;
        sandbox.workDir = workDir_;
        sandbox.completionPort = null;
        
        // Create job object for this sandbox
        sandbox.jobHandle = CreateJobObjectW(null, null);
        if (sandbox.jobHandle is null)
            return Result!WindowsSandbox.err("Failed to create job object");
        
        // Configure extended resource limits (includes BREAKAWAY disabled)
        auto limitsResult = sandbox.configureJobLimits();
        if (limitsResult.isErr)
        {
            CloseHandle(sandbox.jobHandle);
            return Result!WindowsSandbox.err(limitsResult.unwrapErr());
        }
        
        // Configure UI restrictions for isolation
        auto uiResult = sandbox.configureUIRestrictions();
        if (uiResult.isErr)
        {
            CloseHandle(sandbox.jobHandle);
            return Result!WindowsSandbox.err(uiResult.unwrapErr());
        }
        
        // Configure CPU rate limiting (Windows 8+)
        sandbox.configureCpuRateLimit();
        
        // Setup completion port for job event notifications
        sandbox.setupCompletionPort();
        
        return Result!WindowsSandbox.ok(sandbox);
    }
    
    /// Execute command in sandbox
    Result!ExecutionOutput execute(string[] command, string workingDir) @system
    {
        if (command.length == 0)
            return Result!ExecutionOutput.err("Empty command");
        
        // Build command line (Windows requires a single string)
        auto cmdLine = buildCommandLine(command);
        
        // Build environment block
        auto envBlock = buildEnvironmentBlock();
        
        // Create pipes for stdout/stderr
        HANDLE stdoutRead, stdoutWrite;
        HANDLE stderrRead, stderrWrite;
        
        SECURITY_ATTRIBUTES sa;
        sa.nLength = SECURITY_ATTRIBUTES.sizeof;
        sa.bInheritHandle = TRUE;
        sa.lpSecurityDescriptor = null;
        
        if (!CreatePipe(&stdoutRead, &stdoutWrite, &sa, 0))
            return Result!ExecutionOutput.err("Failed to create stdout pipe");
        
        if (!CreatePipe(&stderrRead, &stderrWrite, &sa, 0))
        {
            CloseHandle(stdoutRead);
            CloseHandle(stdoutWrite);
            return Result!ExecutionOutput.err("Failed to create stderr pipe");
        }
        
        // Don't inherit read handles
        SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0);
        
        // Setup process creation
        STARTUPINFOW si;
        si.cb = STARTUPINFOW.sizeof;
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdOutput = stdoutWrite;
        si.hStdError = stderrWrite;
        si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
        
        PROCESS_INFORMATION pi;
        
        // Create process suspended so we can assign to job first
        auto created = CreateProcessW(
            null,
            cast(wchar*) toUTF16z(cmdLine),
            null,
            null,
            TRUE,  // Inherit handles
            CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
            envBlock.ptr,
            toUTF16z(workingDir),
            &si,
            &pi
        );
        
        // Close write ends of pipes (parent doesn't need them)
        CloseHandle(stdoutWrite);
        CloseHandle(stderrWrite);
        
        if (!created)
        {
            CloseHandle(stdoutRead);
            CloseHandle(stderrRead);
            return Result!ExecutionOutput.err("Failed to create process");
        }
        
        // Assign process to job object
        if (!AssignProcessToJobObject(jobHandle, pi.hProcess))
        {
            TerminateProcess(pi.hProcess, 1);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            CloseHandle(stdoutRead);
            CloseHandle(stderrRead);
            return Result!ExecutionOutput.err("Failed to assign process to job");
        }
        
        // Resume process
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        
        // Read output
        string stdout = readFromPipe(stdoutRead);
        string stderr = readFromPipe(stderrRead);
        
        CloseHandle(stdoutRead);
        CloseHandle(stderrRead);
        
        // Wait for process completion
        WaitForSingleObject(pi.hProcess, INFINITE);
        
        // Get exit code
        DWORD exitCode;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        
        CloseHandle(pi.hProcess);
        
        ExecutionOutput output;
        output.stdout = stdout;
        output.stderr = stderr;
        output.exitCode = exitCode;
        
        return Result!ExecutionOutput.ok(output);
    }
    
    /// Cleanup sandbox resources - terminates all processes and releases handles
    void cleanup() @system
    {
        // Close completion port first
        if (completionPort !is null)
        {
            CloseHandle(completionPort);
            completionPort = null;
        }
        
        if (jobHandle !is null)
        {
            // Terminate all processes in job (graceful shutdown)
            TerminateJobObject(jobHandle, 1);
            CloseHandle(jobHandle);
            jobHandle = null;
        }
    }
    
    /// Query current job statistics for debugging/monitoring
    JobStatistics queryStatistics() @system
    {
        JobStatistics stats;
        
        if (jobHandle is null)
            return stats;
        
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accountInfo;
        if (QueryInformationJobObject(
            jobHandle,
            JobObjectBasicAccountingInformation,
            &accountInfo,
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION.sizeof,
            null))
        {
            stats.totalUserTime = accountInfo.TotalUserTime.QuadPart / 10_000; // to ms
            stats.totalKernelTime = accountInfo.TotalKernelTime.QuadPart / 10_000;
            stats.totalProcesses = accountInfo.TotalProcesses;
            stats.activeProcesses = accountInfo.ActiveProcesses;
            stats.terminatedProcesses = accountInfo.TotalTerminatedProcesses;
        }
        
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION extInfo;
        if (QueryInformationJobObject(
            jobHandle,
            JobObjectExtendedLimitInformation,
            &extInfo,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION.sizeof,
            null))
        {
            stats.peakProcessMemory = extInfo.PeakProcessMemoryUsed;
            stats.peakJobMemory = extInfo.PeakJobMemoryUsed;
        }
        
        return stats;
    }
    
    /// Configure job object resource limits using JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    /// 
    /// Security: Explicitly ensures BREAKAWAY_OK is NOT set to prevent process escape
    /// from the job object. This is critical for sandbox containment.
    private Result!void configureJobLimits() @system
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION extInfo;
        extInfo.BasicLimitInformation.LimitFlags = 0;
        
        // === CRITICAL: Kill all processes when job handle is closed ===
        // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE ensures all processes in the job
        // are terminated when the last handle to the job is closed
        extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        
        // === CRITICAL: Do NOT set BREAKAWAY_OK ===
        // By not setting JOB_OBJECT_LIMIT_BREAKAWAY_OK (0x00000800) or
        // JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK (0x00001000), child processes
        // CANNOT escape the job object. This is essential for sandbox containment.
        // Explicit: extInfo.BasicLimitInformation.LimitFlags &= ~JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        
        // Set job-wide memory limit
        if (spec.resources.maxMemoryBytes > 0)
        {
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
            extInfo.JobMemoryLimit = spec.resources.maxMemoryBytes;
            
            // Also set per-process memory limit (more granular control)
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_PROCESS_MEMORY;
            extInfo.ProcessMemoryLimit = spec.resources.maxMemoryBytes;
        }
        
        // Set working set limits (committed memory bounds)
        if (spec.resources.maxMemoryBytes > 0)
        {
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_WORKINGSET;
            // Minimum working set: 1MB or 1% of max, whichever is larger
            extInfo.BasicLimitInformation.MinimumWorkingSetSize = 
                spec.resources.maxMemoryBytes > 100 * 1024 * 1024 
                    ? spec.resources.maxMemoryBytes / 100 
                    : 1024 * 1024;
            extInfo.BasicLimitInformation.MaximumWorkingSetSize = spec.resources.maxMemoryBytes;
        }
        
        // Set process count limit
        if (spec.resources.maxProcesses > 0)
        {
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
            extInfo.BasicLimitInformation.ActiveProcessLimit = spec.resources.maxProcesses;
        }
        
        // Set CPU time limit (job-wide aggregate)
        if (spec.resources.maxCpuTimeMs > 0)
        {
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_JOB_TIME;
            LARGE_INTEGER cpuTime;
            cpuTime.QuadPart = spec.resources.maxCpuTimeMs * 10_000; // Convert ms to 100ns units
            extInfo.BasicLimitInformation.PerJobUserTimeLimit = cpuTime;
        }
        
        // Terminate on unhandled exceptions (debugging/security)
        extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
        
        // Apply extended limits
        if (!SetInformationJobObject(
            jobHandle,
            JobObjectExtendedLimitInformation,
            &extInfo,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION.sizeof))
        {
            return Result!void.err("Failed to set job extended limits");
        }
        
        return Result!void.ok();
    }
    
    /// Configure UI restrictions for desktop/clipboard isolation
    /// Provides additional layer of isolation beyond process containment
    private Result!void configureUIRestrictions() @system
    {
        JOBOBJECT_BASIC_UI_RESTRICTIONS uiRestrictions;
        
        // Disable clipboard access
        uiRestrictions.UIRestrictionsClass = JOB_OBJECT_UILIMIT_CLIPBOARD;
        
        // Disable desktop switching
        uiRestrictions.UIRestrictionsClass |= JOB_OBJECT_UILIMIT_DESKTOP;
        
        // Disable display settings changes
        uiRestrictions.UIRestrictionsClass |= JOB_OBJECT_UILIMIT_DISPLAYSETTINGS;
        
        // Disable exit windows (shutdown/restart)
        uiRestrictions.UIRestrictionsClass |= JOB_OBJECT_UILIMIT_EXITWINDOWS;
        
        // Disable global atoms (inter-process communication)
        uiRestrictions.UIRestrictionsClass |= JOB_OBJECT_UILIMIT_GLOBALATOMS;
        
        // Disable user handles outside job
        uiRestrictions.UIRestrictionsClass |= JOB_OBJECT_UILIMIT_HANDLES;
        
        // Disable system parameter changes
        uiRestrictions.UIRestrictionsClass |= JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS;
        
        if (!SetInformationJobObject(
            jobHandle,
            JobObjectBasicUIRestrictions,
            &uiRestrictions,
            JOBOBJECT_BASIC_UI_RESTRICTIONS.sizeof))
        {
            return Result!void.err("Failed to set UI restrictions");
        }
        
        return Result!void.ok();
    }
    
    /// Configure CPU rate limiting (Windows 8+)
    /// Uses JOBOBJECT_CPU_RATE_CONTROL_INFORMATION for throttling
    private void configureCpuRateLimit() @system
    {
        // Only apply if CPU shares are configured
        if (spec.resources.cpuShares == 0 || spec.resources.cpuShares >= 10000)
            return;
        
        JOBOBJECT_CPU_RATE_CONTROL_INFORMATION cpuRateInfo;
        cpuRateInfo.ControlFlags = JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | 
                                   JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP;
        
        // Convert cpuShares (1-10000) to CPU rate (1-10000 = 0.01% - 100%)
        // Default 1024 shares ~= 10% CPU cap
        cpuRateInfo.CpuRate = cast(DWORD)(spec.resources.cpuShares);
        
        // This may fail on Windows 7, which is acceptable
        SetInformationJobObject(
            jobHandle,
            JobObjectCpuRateControlInformation,
            &cpuRateInfo,
            JOBOBJECT_CPU_RATE_CONTROL_INFORMATION.sizeof
        );
    }
    
    /// Setup I/O completion port for async job event notifications
    /// Allows monitoring of process creation/termination within job
    private void setupCompletionPort() @system
    {
        // Create completion port
        completionPort = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 1);
        if (completionPort is null)
            return;
        
        // Associate job with completion port
        JOBOBJECT_ASSOCIATE_COMPLETION_PORT portInfo;
        portInfo.CompletionKey = cast(void*)jobHandle;
        portInfo.CompletionPort = completionPort;
        
        SetInformationJobObject(
            jobHandle,
            JobObjectAssociateCompletionPortInformation,
            &portInfo,
            JOBOBJECT_ASSOCIATE_COMPLETION_PORT.sizeof
        );
    }
    
    /// Build Windows command line from array
    private static string buildCommandLine(string[] command) @safe
    {
        auto result = appender!string;
        
        foreach (i, arg; command)
        {
            if (i > 0)
                result ~= " ";
            
            // Quote arguments with spaces
            if (arg.canFind(' '))
            {
                result ~= "\"";
                result ~= arg;
                result ~= "\"";
            }
            else
            {
                result ~= arg;
            }
        }
        
        return result.data;
    }
    
    /// Build environment block for CreateProcess
    private string buildEnvironmentBlock() @trusted
    {
        import std.algorithm : joiner;
        import std.range : chain;
        
        auto result = appender!(wchar[]);
        
        foreach (key, value; spec.environment.toMap())
        {
            foreach (wchar c; toUTF16(key))
                result ~= c;
            result ~= '=';
            foreach (wchar c; toUTF16(value))
                result ~= c;
            result ~= '\0';
        }
        
        // Double null terminator
        result ~= '\0';
        
        return cast(string) result.data;
    }
    
    /// Read all data from a pipe
    private static string readFromPipe(HANDLE pipe) @trusted
    {
        auto result = appender!string;
        char[4096] buffer;
        DWORD bytesRead;
        
        while (ReadFile(pipe, buffer.ptr, buffer.length, &bytesRead, null) && bytesRead > 0)
        {
            result ~= buffer[0 .. bytesRead];
        }
        
        return result.data;
    }
}

/// Execution output
struct ExecutionOutput
{
    string stdout;
    string stderr;
    int exitCode;
}

/// Job statistics for debugging/monitoring
struct JobStatistics
{
    ulong totalUserTime;       // Total user-mode CPU time (ms)
    ulong totalKernelTime;     // Total kernel-mode CPU time (ms)
    uint totalProcesses;       // Total processes ever created
    uint activeProcesses;      // Currently active processes
    uint terminatedProcesses;  // Processes terminated due to limits
    size_t peakProcessMemory;  // Peak per-process memory
    size_t peakJobMemory;      // Peak job-wide memory
}

/// Result type
private struct Result(T)
{
    private bool _isOk;
    private T _value;
    private string _error;
    
    static Result ok(T val) @safe
    {
        Result r;
        r._isOk = true;
        r._value = val;
        return r;
    }
    
    static Result ok() @safe
    {
        Result r;
        r._isOk = true;
        return r;
    }
    
    static Result err(string error) @safe
    {
        Result r;
        r._isOk = false;
        r._error = error;
        return r;
    }
    
    bool isOk() @safe const pure nothrow { return _isOk; }
    bool isErr() @safe const pure nothrow { return !_isOk; }
    
    T unwrap() @safe
    {
        if (!_isOk)
            assert(false, "Result unwrap failed: " ~ _error);
        return _value;
    }
    
    string unwrapErr() @safe const
    {
        if (_isOk)
            assert(false, "Result is ok, not an error");
        return _error;
    }
}

// Windows API bindings
import core.sys.windows.windows;
import std.utf : toUTF16, toUTF16z;
import std.algorithm : canFind;

// Additional Windows API structures and functions
extern(Windows) nothrow @nogc:

struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
{
    LARGE_INTEGER TotalUserTime;
    LARGE_INTEGER TotalKernelTime;
    LARGE_INTEGER ThisPeriodTotalUserTime;
    LARGE_INTEGER ThisPeriodTotalKernelTime;
    DWORD TotalPageFaultCount;
    DWORD TotalProcesses;
    DWORD ActiveProcesses;
    DWORD TotalTerminatedProcesses;
}

struct JOBOBJECT_BASIC_LIMIT_INFORMATION
{
    LARGE_INTEGER PerProcessUserTimeLimit;
    LARGE_INTEGER PerJobUserTimeLimit;
    DWORD LimitFlags;
    SIZE_T MinimumWorkingSetSize;
    SIZE_T MaximumWorkingSetSize;
    DWORD ActiveProcessLimit;
    ULONG_PTR Affinity;
    DWORD PriorityClass;
    DWORD SchedulingClass;
}

struct IO_COUNTERS
{
    ULONGLONG ReadOperationCount;
    ULONGLONG WriteOperationCount;
    ULONGLONG OtherOperationCount;
    ULONGLONG ReadTransferCount;
    ULONGLONG WriteTransferCount;
    ULONGLONG OtherTransferCount;
}

struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
{
    JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    IO_COUNTERS IoInfo;
    SIZE_T ProcessMemoryLimit;
    SIZE_T JobMemoryLimit;
    SIZE_T PeakProcessMemoryUsed;
    SIZE_T PeakJobMemoryUsed;
}

/// UI restrictions structure for desktop/clipboard isolation
struct JOBOBJECT_BASIC_UI_RESTRICTIONS
{
    DWORD UIRestrictionsClass;
}

/// CPU rate control structure (Windows 8+)
struct JOBOBJECT_CPU_RATE_CONTROL_INFORMATION
{
    DWORD ControlFlags;
    union
    {
        DWORD CpuRate;       // Used when HARD_CAP is set (1-10000 = 0.01%-100%)
        DWORD Weight;        // Used when WEIGHT_BASED is set (1-9)
        struct
        {
            WORD MinRate;
            WORD MaxRate;
        }
    }
}

/// Completion port association structure
struct JOBOBJECT_ASSOCIATE_COMPLETION_PORT
{
    void* CompletionKey;
    HANDLE CompletionPort;
}

enum JOBOBJECTINFOCLASS
{
    JobObjectBasicAccountingInformation = 1,
    JobObjectBasicLimitInformation = 2,
    JobObjectBasicProcessIdList = 3,
    JobObjectBasicUIRestrictions = 4,
    JobObjectSecurityLimitInformation = 5,
    JobObjectEndOfJobTimeInformation = 6,
    JobObjectAssociateCompletionPortInformation = 7,
    JobObjectBasicAndIoAccountingInformation = 8,
    JobObjectExtendedLimitInformation = 9,
    JobObjectJobSetInformation = 10,
    JobObjectGroupInformation = 11,
    JobObjectNotificationLimitInformation = 12,
    JobObjectLimitViolationInformation = 13,
    JobObjectGroupInformationEx = 14,
    JobObjectCpuRateControlInformation = 15,
}

// Limit flags for JOBOBJECT_BASIC_LIMIT_INFORMATION
enum : DWORD
{
    JOB_OBJECT_LIMIT_WORKINGSET = 0x00000001,
    JOB_OBJECT_LIMIT_PROCESS_TIME = 0x00000002,
    JOB_OBJECT_LIMIT_JOB_TIME = 0x00000004,
    JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x00000008,
    JOB_OBJECT_LIMIT_AFFINITY = 0x00000010,
    JOB_OBJECT_LIMIT_PRIORITY_CLASS = 0x00000020,
    JOB_OBJECT_LIMIT_PRESERVE_JOB_TIME = 0x00000040,
    JOB_OBJECT_LIMIT_SCHEDULING_CLASS = 0x00000080,
    JOB_OBJECT_LIMIT_PROCESS_MEMORY = 0x00000100,
    JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200,
    JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = 0x00000400,
    JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800,              // SECURITY: Never set this
    JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000,      // SECURITY: Never set this
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000,        // Always set for containment
    JOB_OBJECT_LIMIT_SUBSET_AFFINITY = 0x00004000,
}

// UI restriction flags for JOBOBJECT_BASIC_UI_RESTRICTIONS
enum : DWORD
{
    JOB_OBJECT_UILIMIT_HANDLES = 0x00000001,
    JOB_OBJECT_UILIMIT_READCLIPBOARD = 0x00000002,
    JOB_OBJECT_UILIMIT_WRITECLIPBOARD = 0x00000004,
    JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS = 0x00000008,
    JOB_OBJECT_UILIMIT_DISPLAYSETTINGS = 0x00000010,
    JOB_OBJECT_UILIMIT_GLOBALATOMS = 0x00000020,
    JOB_OBJECT_UILIMIT_DESKTOP = 0x00000040,
    JOB_OBJECT_UILIMIT_EXITWINDOWS = 0x00000080,
    JOB_OBJECT_UILIMIT_CLIPBOARD = JOB_OBJECT_UILIMIT_READCLIPBOARD | JOB_OBJECT_UILIMIT_WRITECLIPBOARD,
}

// CPU rate control flags (Windows 8+)
enum : DWORD
{
    JOB_OBJECT_CPU_RATE_CONTROL_ENABLE = 0x00000001,
    JOB_OBJECT_CPU_RATE_CONTROL_WEIGHT_BASED = 0x00000002,
    JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP = 0x00000004,
    JOB_OBJECT_CPU_RATE_CONTROL_NOTIFY = 0x00000008,
    JOB_OBJECT_CPU_RATE_CONTROL_MIN_MAX_RATE = 0x00000010,
}

// Job Object APIs
extern(Windows) HANDLE CreateJobObjectW(SECURITY_ATTRIBUTES* lpJobAttributes, LPCWSTR lpName);
extern(Windows) BOOL AssignProcessToJobObject(HANDLE hJob, HANDLE hProcess);
extern(Windows) BOOL TerminateJobObject(HANDLE hJob, UINT uExitCode);
extern(Windows) BOOL SetInformationJobObject(
    HANDLE hJob,
    JOBOBJECTINFOCLASS JobObjectInformationClass,
    LPVOID lpJobObjectInformation,
    DWORD cbJobObjectInformationLength
);
extern(Windows) BOOL QueryInformationJobObject(
    HANDLE hJob,
    JOBOBJECTINFOCLASS JobObjectInformationClass,
    LPVOID lpJobObjectInformation,
    DWORD cbJobObjectInformationLength,
    LPDWORD lpReturnLength
);
extern(Windows) BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
extern(Windows) DWORD ResumeThread(HANDLE hThread);

// I/O Completion Port APIs
extern(Windows) HANDLE CreateIoCompletionPort(
    HANDLE FileHandle,
    HANDLE ExistingCompletionPort,
    ULONG_PTR CompletionKey,
    DWORD NumberOfConcurrentThreads
);
extern(Windows) BOOL GetQueuedCompletionStatus(
    HANDLE CompletionPort,
    LPDWORD lpNumberOfBytesTransferred,
    PULONG_PTR lpCompletionKey,
    LPOVERLAPPED* lpOverlapped,
    DWORD dwMilliseconds
);

// Invalid handle constant
enum HANDLE INVALID_HANDLE_VALUE = cast(HANDLE)-1;

// Additional type aliases
alias PULONG_PTR = ULONG_PTR*;

struct OVERLAPPED
{
    ULONG_PTR Internal;
    ULONG_PTR InternalHigh;
    union
    {
        struct
        {
            DWORD Offset;
            DWORD OffsetHigh;
        }
        PVOID Pointer;
    }
    HANDLE hEvent;
}
alias LPOVERLAPPED = OVERLAPPED*;
alias PVOID = void*;

enum : DWORD
{
    CREATE_SUSPENDED = 0x00000004,
    CREATE_UNICODE_ENVIRONMENT = 0x00000400,
    STARTF_USESTDHANDLES = 0x00000100,
    HANDLE_FLAG_INHERIT = 0x00000001,
    STD_INPUT_HANDLE = cast(DWORD) -10,
    STD_OUTPUT_HANDLE = cast(DWORD) -11,
    STD_ERROR_HANDLE = cast(DWORD) -12,
}

