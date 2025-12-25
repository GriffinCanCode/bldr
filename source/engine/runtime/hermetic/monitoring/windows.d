module engine.runtime.hermetic.monitoring.windows;

version(Windows):

import engine.runtime.hermetic.monitoring;
import engine.runtime.hermetic.core.spec : ResourceLimits;
import engine.distributed.protocol.protocol : ResourceUsage;
import std.datetime : Duration, msecs;
import std.conv : to;

/// Windows resource monitor using Performance Counters and Job Objects
/// 
/// Design: Uses Windows Job Objects for process tree accounting
/// - Job accounting information for CPU time
/// - Working set information for memory usage
/// - I/O counters for disk operations
/// 
/// Provides accurate resource tracking for process trees on Windows
final class WindowsMonitor : BaseMonitor
{
    private HANDLE jobHandle;
    private ulong initialUserTime;
    private ulong initialKernelTime;
    private ulong initialReadBytes;
    private ulong initialWriteBytes;
    
    this(ResourceLimits limits) @safe
    {
        super(limits);
        jobHandle = null;
    }
    
    override void start() @trusted
    {
        super.start();
        
        // Create job object for resource tracking
        jobHandle = CreateJobObjectW(null, null);
        if (jobHandle is null)
            return;
        
        // Assign current process to job
        import core.sys.windows.windows : GetCurrentProcess;
        AssignProcessToJobObject(jobHandle, GetCurrentProcess());
        
        // Set resource limits if specified
        if (limits.maxMemoryBytes > 0 || limits.maxProcesses > 0 || limits.maxCpuTimeMs > 0)
        {
            setJobLimits();
        }
        
        // Record initial counters
        recordInitialCounters();
    }
    
    override void stop() @trusted
    {
        super.stop();
        
        // Check for violations
        checkLimits();
        
        // Cleanup job object
        if (jobHandle !is null)
        {
            CloseHandle(jobHandle);
            jobHandle = null;
        }
    }
    
    override ResourceUsage snapshot() @trusted
    {
        ResourceUsage usage;
        
        if (!started || jobHandle is null)
            return usage;
        
        // Query job accounting information
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accountInfo;
        if (QueryInformationJobObject(
            jobHandle,
            JobObjectBasicAccountingInformation,
            &accountInfo,
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION.sizeof,
            null))
        {
            // Calculate CPU time (user + kernel)
            immutable userTime = fileTimeToMs(accountInfo.TotalUserTime);
            immutable kernelTime = fileTimeToMs(accountInfo.TotalKernelTime);
            usage.cpuTime = msecs((userTime + kernelTime) - (initialUserTime + initialKernelTime));
        }
        
        // Query memory usage
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION extInfo;
        if (QueryInformationJobObject(
            jobHandle,
            JobObjectExtendedLimitInformation,
            &extInfo,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION.sizeof,
            null))
        {
            usage.peakMemory = extInfo.PeakJobMemoryUsed;
        }
        
        // Query I/O counters
        JOBOBJECT_IO_COUNTERS ioCounters;
        if (QueryInformationJobObject(
            jobHandle,
            JobObjectIoCounters,
            &ioCounters,
            JOBOBJECT_IO_COUNTERS.sizeof,
            null))
        {
            usage.diskRead = ioCounters.ReadTransferCount - initialReadBytes;
            usage.diskWrite = ioCounters.WriteTransferCount - initialWriteBytes;
        }
        
        return usage;
    }
    
    /// Set job object limits based on ResourceLimits
    /// 
    /// Security: BREAKAWAY_OK is intentionally NOT set to prevent process escape.
    /// KILL_ON_JOB_CLOSE ensures all processes are terminated on cleanup.
    private void setJobLimits() @trusted
    {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION extInfo;
        extInfo.BasicLimitInformation.LimitFlags = 0;
        
        // === CRITICAL: Kill all processes when job handle is closed ===
        extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        
        // === SECURITY: Do NOT set BREAKAWAY_OK or SILENT_BREAKAWAY_OK ===
        // This prevents child processes from escaping the job object
        
        // Set memory limit
        if (limits.maxMemoryBytes > 0)
        {
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_JOB_MEMORY;
            extInfo.JobMemoryLimit = limits.maxMemoryBytes;
        }
        
        // Set process count limit
        if (limits.maxProcesses > 0)
        {
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
            extInfo.BasicLimitInformation.ActiveProcessLimit = limits.maxProcesses;
        }
        
        // Set CPU time limit (per-process, not job-wide)
        if (limits.maxCpuTimeMs > 0)
        {
            extInfo.BasicLimitInformation.LimitFlags |= JOB_OBJECT_LIMIT_PROCESS_TIME;
            extInfo.BasicLimitInformation.PerProcessUserTimeLimit = msToFileTime(limits.maxCpuTimeMs);
        }
        
        // Apply limits
        SetInformationJobObject(
            jobHandle,
            JobObjectExtendedLimitInformation,
            &extInfo,
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION.sizeof
        );
    }
    
    /// Record initial counters for delta calculation (override base method)
    protected override void recordInitialCounters() @trusted
    {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accountInfo;
        if (QueryInformationJobObject(
            jobHandle,
            JobObjectBasicAccountingInformation,
            &accountInfo,
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION.sizeof,
            null))
        {
            initialUserTime = fileTimeToMs(accountInfo.TotalUserTime);
            initialKernelTime = fileTimeToMs(accountInfo.TotalKernelTime);
        }
        
        JOBOBJECT_IO_COUNTERS ioCounters;
        if (QueryInformationJobObject(
            jobHandle,
            JobObjectIoCounters,
            &ioCounters,
            JOBOBJECT_IO_COUNTERS.sizeof,
            null))
        {
            initialReadBytes = ioCounters.ReadTransferCount;
            initialWriteBytes = ioCounters.WriteTransferCount;
            initialDiskRead = initialReadBytes;
            initialDiskWrite = initialWriteBytes;
        }
    }
    
    /// Convert FILETIME to milliseconds
    private static ulong fileTimeToMs(LARGE_INTEGER ft) @safe pure nothrow
    {
        // FILETIME is in 100-nanosecond intervals
        return ft.QuadPart / 10_000;
    }
    
    /// Convert milliseconds to FILETIME
    private static LARGE_INTEGER msToFileTime(ulong ms) @safe pure nothrow
    {
        LARGE_INTEGER ft;
        ft.QuadPart = ms * 10_000;
        return ft;
    }
}

// Windows API bindings for Job Objects
import core.sys.windows.windows;

// Additional structures not in core.sys.windows.windows
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

struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
{
    JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    IO_COUNTERS IoInfo;
    SIZE_T ProcessMemoryLimit;
    SIZE_T JobMemoryLimit;
    SIZE_T PeakProcessMemoryUsed;
    SIZE_T PeakJobMemoryUsed;
}

struct JOBOBJECT_IO_COUNTERS
{
    ULONGLONG ReadOperationCount;
    ULONGLONG WriteOperationCount;
    ULONGLONG OtherOperationCount;
    ULONGLONG ReadTransferCount;
    ULONGLONG WriteTransferCount;
    ULONGLONG OtherTransferCount;
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
    JobObjectIoCounters = 11,
}

// Limit flags
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
    JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800,
    JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000,
}

// Job Object APIs
extern(Windows) HANDLE CreateJobObjectW(SECURITY_ATTRIBUTES* lpJobAttributes, LPCWSTR lpName);
extern(Windows) BOOL AssignProcessToJobObject(HANDLE hJob, HANDLE hProcess);
extern(Windows) BOOL TerminateJobObject(HANDLE hJob, UINT uExitCode);
extern(Windows) BOOL QueryInformationJobObject(
    HANDLE hJob,
    JOBOBJECTINFOCLASS JobObjectInformationClass,
    LPVOID lpJobObjectInformation,
    DWORD cbJobObjectInformationLength,
    LPDWORD lpReturnLength
);
extern(Windows) BOOL SetInformationJobObject(
    HANDLE hJob,
    JOBOBJECTINFOCLASS JobObjectInformationClass,
    LPVOID lpJobObjectInformation,
    DWORD cbJobObjectInformationLength
);

