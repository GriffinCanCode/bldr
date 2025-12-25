module engine.runtime.hermetic.security.seccomp;

version(linux):

/// Seccomp-BPF syscall filtering for Linux sandbox
/// 
/// Design: Uses BPF (Berkeley Packet Filter) to block dangerous syscalls
/// that could be used to escape the sandbox:
/// - ptrace: Debug/trace processes (escape via process manipulation)
/// - personality: Change execution domain (bypass ASLR, etc.)
/// - mount/umount: Modify filesystem namespace (escape via mount manipulation)
/// - pivot_root: Change root filesystem
/// - reboot/kexec: System control
/// - module_*: Kernel module operations
/// - acct: Process accounting
/// - syslog: Kernel logging access
/// - setns/unshare: Namespace manipulation (escape via namespace juggling)
/// 
/// Filter operates in KILL mode for blocked syscalls - immediate SIGKILL

import core.sys.posix.unistd : syscall;
import core.stdc.errno : errno, EINVAL, ENOSYS;

/// Seccomp modes
private enum SECCOMP_SET_MODE_STRICT = 0;
private enum SECCOMP_SET_MODE_FILTER = 1;

/// Seccomp operations for prctl
private enum PR_SET_SECCOMP = 22;
private enum PR_SET_NO_NEW_PRIVS = 38;

/// BPF instruction structure (sock_filter)
private struct BpfInstruction
{
    ushort code;    // Operation code
    ubyte jt;       // Jump true offset
    ubyte jf;       // Jump false offset
    uint k;         // Generic value (syscall number, constant, etc.)
}

/// BPF program structure (sock_fprog)
private struct BpfProgram
{
    ushort len;             // Number of filter instructions
    BpfInstruction* filter; // Pointer to filter array
}

/// BPF instruction codes
private enum : ushort
{
    // Instruction classes
    BPF_LD   = 0x00,
    BPF_JMP  = 0x05,
    BPF_RET  = 0x06,
    
    // Load sizes
    BPF_W    = 0x00,  // Word (4 bytes)
    
    // Addressing modes
    BPF_ABS  = 0x20,
    BPF_K    = 0x00,
    
    // Jump operations
    BPF_JEQ  = 0x10,
    BPF_JGE  = 0x30,
    BPF_JGT  = 0x20,
}

/// Seccomp return values
private enum : uint
{
    SECCOMP_RET_KILL_PROCESS = 0x80000000, // Kill the process
    SECCOMP_RET_KILL_THREAD  = 0x00000000, // Kill the thread (same as KILL)
    SECCOMP_RET_TRAP         = 0x00030000, // Send SIGSYS
    SECCOMP_RET_ERRNO        = 0x00050000, // Return errno
    SECCOMP_RET_LOG          = 0x7ffc0000, // Log and allow
    SECCOMP_RET_ALLOW        = 0x7fff0000, // Allow syscall
}

/// Seccomp data offsets (for x86_64)
private enum : uint
{
    SECCOMP_DATA_NR          = 0,   // Syscall number offset
    SECCOMP_DATA_ARCH        = 4,   // Architecture offset
    SECCOMP_DATA_ARGS        = 16,  // Arguments offset (6 x 8 bytes)
}

/// Architecture audit values
private enum : uint
{
    AUDIT_ARCH_X86_64        = 0xc000003e,
    AUDIT_ARCH_AARCH64       = 0xc00000b7,
}

/// x86_64 syscall numbers for dangerous operations
private enum Syscalls : uint
{
    // Process manipulation (sandbox escape vectors)
    ptrace          = 101,  // Debug/trace processes
    process_vm_readv  = 310,  // Read from another process's memory
    process_vm_writev = 311,  // Write to another process's memory
    
    // Execution domain manipulation
    personality     = 135,  // Change execution domain
    
    // Filesystem namespace manipulation
    mount           = 165,  // Mount filesystem
    umount2         = 166,  // Unmount filesystem
    pivot_root      = 155,  // Change root filesystem
    
    // System control (privilege escalation)
    reboot          = 169,  // Reboot system
    kexec_load      = 246,  // Load new kernel
    kexec_file_load = 320,  // Load new kernel from file
    
    // Kernel module operations
    init_module     = 175,  // Load kernel module
    finit_module    = 313,  // Load kernel module from fd
    delete_module   = 176,  // Unload kernel module
    
    // System accounting/logging
    acct            = 163,  // Process accounting
    syslog          = 103,  // Kernel log access
    
    // Namespace manipulation (sandbox escape)
    setns           = 308,  // Join existing namespace
    unshare         = 272,  // Create new namespace (uncontrolled)
    
    // I/O permissions (privilege escalation)
    ioperm          = 173,  // Set I/O port permissions
    iopl            = 172,  // Set I/O privilege level
    
    // Quota/resource manipulation
    quotactl        = 179,  // Manipulate disk quotas
    
    // Key management
    keyctl          = 250,  // Key management
    add_key         = 248,  // Add key to keyring
    request_key     = 249,  // Request key
    
    // BPF manipulation (could modify our filter)
    bpf             = 321,  // BPF operations
    
    // Performance monitoring (information leak)
    perf_event_open = 298,  // Performance monitoring
    
    // User namespace manipulation
    userfaultfd     = 323,  // Userfaultfd (potential escape)
    
    // Miscellaneous dangerous
    lookup_dcookie  = 212,  // Retrieve cookie for directory entry
    vhangup         = 153,  // Virtual hangup
    sysfs           = 139,  // Get filesystem info (deprecated)
    _sysctl         = 156,  // Read/write kernel parameters
    
    // Clock manipulation (non-determinism)
    clock_settime   = 227,  // Set system clock
    settimeofday    = 164,  // Set time of day
    adjtimex        = 159,  // Tune kernel clock
    clock_adjtime   = 305,  // Adjust clock
    
    // Swap (resource exhaustion)
    swapon          = 167,  // Enable swap
    swapoff         = 168,  // Disable swap
    
    // Move pages between NUMA nodes
    move_pages      = 279,  // Move pages between nodes
    migrate_pages   = 256,  // Migrate pages
    
    // Obsolete/dangerous
    create_module   = 174,  // Create loadable module entry (obsolete)
    get_kernel_syms = 177,  // Get kernel symbol table (obsolete)
    query_module    = 178,  // Query loaded modules (obsolete)
    nfsservctl      = 180,  // NFS server control (obsolete)
}

/// aarch64 syscall numbers for dangerous operations
private enum SyscallsAArch64 : uint
{
    ptrace          = 117,
    personality     = 92,
    mount           = 40,
    umount2         = 39,
    pivot_root      = 41,
    reboot          = 142,
    kexec_load      = 104,
    kexec_file_load = 294,
    init_module     = 105,
    finit_module    = 273,
    delete_module   = 106,
    acct            = 89,
    syslog          = 116,
    setns           = 268,
    unshare         = 97,
    quotactl        = 60,
    bpf             = 280,
    perf_event_open = 241,
    userfaultfd     = 282,
    clock_settime   = 112,
    settimeofday    = 170,
    adjtimex        = 171,
    clock_adjtime   = 266,
    swapon          = 224,
    swapoff         = 225,
    add_key         = 217,
    request_key     = 218,
    keyctl          = 219,
    process_vm_readv  = 270,
    process_vm_writev = 271,
    move_pages      = 239,
    migrate_pages   = 238,
}

/// Seccomp policy configuration
struct SeccompPolicy
{
    bool blockPtrace = true;          // Block ptrace and process manipulation
    bool blockMount = true;           // Block mount/umount operations
    bool blockNamespaces = true;      // Block setns/unshare (except controlled)
    bool blockModules = true;         // Block kernel module operations
    bool blockSystemControl = true;   // Block reboot, kexec, etc.
    bool blockClockManipulation = true; // Block time manipulation (determinism)
    bool blockBpf = true;             // Block BPF manipulation
    bool blockKeyManagement = true;   // Block kernel key management
    bool logBlocked = false;          // Log blocked syscalls (instead of kill)
    
    /// Default strict policy for hermetic builds
    static SeccompPolicy strict() @safe pure nothrow
    {
        return SeccompPolicy();
    }
    
    /// Relaxed policy (for debugging only)
    static SeccompPolicy relaxed() @safe pure nothrow
    {
        SeccompPolicy p;
        p.logBlocked = true;
        p.blockClockManipulation = false;
        return p;
    }
}

/// Install seccomp-bpf filter
/// Must be called from the sandboxed process after fork/clone
/// Returns 0 on success, -1 on failure with errno set
int installSeccompFilter(SeccompPolicy policy = SeccompPolicy.strict()) @system nothrow
{
    // Build blocklist based on policy
    uint[] blockedSyscalls;
    
    // Always block the most dangerous syscalls
    static immutable alwaysBlocked = [
        Syscalls.init_module,
        Syscalls.finit_module,
        Syscalls.delete_module,
        Syscalls.create_module,
        Syscalls.get_kernel_syms,
        Syscalls.query_module,
        Syscalls.nfsservctl,
        Syscalls.reboot,
        Syscalls.kexec_load,
        Syscalls.kexec_file_load,
        Syscalls.ioperm,
        Syscalls.iopl,
        Syscalls.acct,
        Syscalls.syslog,
        Syscalls.vhangup,
        Syscalls.sysfs,
        Syscalls._sysctl,
        Syscalls.lookup_dcookie,
    ];
    
    foreach (s; alwaysBlocked)
        blockedSyscalls ~= s;
    
    if (policy.blockPtrace)
    {
        blockedSyscalls ~= Syscalls.ptrace;
        blockedSyscalls ~= Syscalls.process_vm_readv;
        blockedSyscalls ~= Syscalls.process_vm_writev;
        blockedSyscalls ~= Syscalls.perf_event_open;
    }
    
    if (policy.blockMount)
    {
        blockedSyscalls ~= Syscalls.mount;
        blockedSyscalls ~= Syscalls.umount2;
        blockedSyscalls ~= Syscalls.pivot_root;
        blockedSyscalls ~= Syscalls.swapon;
        blockedSyscalls ~= Syscalls.swapoff;
    }
    
    if (policy.blockNamespaces)
    {
        blockedSyscalls ~= Syscalls.setns;
        blockedSyscalls ~= Syscalls.unshare;
        blockedSyscalls ~= Syscalls.userfaultfd;
    }
    
    if (policy.blockSystemControl)
    {
        blockedSyscalls ~= Syscalls.personality;
        blockedSyscalls ~= Syscalls.quotactl;
        blockedSyscalls ~= Syscalls.move_pages;
        blockedSyscalls ~= Syscalls.migrate_pages;
    }
    
    if (policy.blockClockManipulation)
    {
        blockedSyscalls ~= Syscalls.clock_settime;
        blockedSyscalls ~= Syscalls.settimeofday;
        blockedSyscalls ~= Syscalls.adjtimex;
        blockedSyscalls ~= Syscalls.clock_adjtime;
    }
    
    if (policy.blockBpf)
        blockedSyscalls ~= Syscalls.bpf;
    
    if (policy.blockKeyManagement)
    {
        blockedSyscalls ~= Syscalls.keyctl;
        blockedSyscalls ~= Syscalls.add_key;
        blockedSyscalls ~= Syscalls.request_key;
    }
    
    return installFilter(blockedSyscalls, policy.logBlocked);
}

/// Install BPF filter with given blocked syscalls
private int installFilter(const(uint)[] blockedSyscalls, bool logOnly) @system nothrow
{
    // Must set no_new_privs before installing seccomp filter
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
        return -1;
    
    // Build BPF program
    auto filter = buildBpfFilter(blockedSyscalls, logOnly);
    if (filter.length == 0)
        return -1;
    
    // Create program structure
    BpfProgram prog;
    prog.len = cast(ushort)filter.length;
    prog.filter = filter.ptr;
    
    // Install filter via prctl
    if (prctl(PR_SET_SECCOMP, SECCOMP_SET_MODE_FILTER, cast(size_t)&prog, 0, 0) != 0)
        return -1;
    
    return 0;
}

/// Build BPF filter program
private BpfInstruction[] buildBpfFilter(const(uint)[] blockedSyscalls, bool logOnly) @system nothrow
{
    if (blockedSyscalls.length == 0)
        return [];
    
    // Calculate program size:
    // 2 instructions for arch check
    // 1 instruction to load syscall number
    // 2 instructions per blocked syscall (compare + conditional jump)
    // 1 instruction for default allow
    auto programSize = 3 + blockedSyscalls.length * 2 + 1;
    
    auto filter = new BpfInstruction[programSize];
    size_t idx = 0;
    
    // Load architecture (for validation)
    filter[idx++] = bpfStmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_ARCH);
    
    // Check architecture (x86_64)
    // If arch doesn't match, kill (prevents architecture confusion attacks)
    filter[idx++] = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0);
    filter[idx++] = bpfStmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
    
    // Load syscall number
    filter[idx++] = bpfStmt(BPF_LD | BPF_W | BPF_ABS, SECCOMP_DATA_NR);
    
    // For each blocked syscall, add a check
    immutable retAction = logOnly ? SECCOMP_RET_LOG : SECCOMP_RET_KILL_PROCESS;
    
    foreach (syscallNum; blockedSyscalls)
    {
        // Jump over the return if not matching
        filter[idx++] = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, syscallNum, 0, 1);
        filter[idx++] = bpfStmt(BPF_RET | BPF_K, retAction);
    }
    
    // Default: allow syscall
    filter[idx++] = bpfStmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);
    
    return filter[0..idx];
}

/// Create BPF statement instruction
private BpfInstruction bpfStmt(ushort code, uint k) @safe pure nothrow
{
    BpfInstruction inst;
    inst.code = code;
    inst.jt = 0;
    inst.jf = 0;
    inst.k = k;
    return inst;
}

/// Create BPF jump instruction
private BpfInstruction bpfJump(ushort code, uint k, ubyte jt, ubyte jf) @safe pure nothrow
{
    BpfInstruction inst;
    inst.code = code;
    inst.jt = jt;
    inst.jf = jf;
    inst.k = k;
    return inst;
}

/// prctl syscall wrapper
private extern(C) int prctl(int option, size_t arg2, size_t arg3, size_t arg4, size_t arg5) @system nothrow
{
    enum SYS_prctl = 157;  // x86_64
    return cast(int)syscall(SYS_prctl, option, arg2, arg3, arg4, arg5);
}

/// Check if seccomp is available on this system
bool isSeccompAvailable() @system nothrow
{
    // Try to read seccomp mode from /proc/self/status
    // or check prctl availability
    return prctl(PR_SET_NO_NEW_PRIVS, 0, 0, 0, 0) == 0 || errno != EINVAL;
}

/// Error information for seccomp failures
struct SeccompError
{
    int errorCode;
    string description;
    
    static SeccompError noNewPrivs() @safe pure nothrow
    {
        return SeccompError(1, "Failed to set NO_NEW_PRIVS");
    }
    
    static SeccompError filterInstall() @safe pure nothrow
    {
        return SeccompError(2, "Failed to install seccomp filter");
    }
    
    static SeccompError unsupported() @safe pure nothrow
    {
        return SeccompError(3, "Seccomp not supported on this kernel");
    }
}

version(unittest)
{
    // Unit tests run in the main process, cannot actually test seccomp
    // as it would affect the test runner. These are structural tests only.
    
    @safe unittest
    {
        // Test policy creation
        auto strict = SeccompPolicy.strict();
        assert(strict.blockPtrace);
        assert(strict.blockMount);
        assert(strict.blockNamespaces);
        assert(!strict.logBlocked);
        
        auto relaxed = SeccompPolicy.relaxed();
        assert(relaxed.logBlocked);
        assert(!relaxed.blockClockManipulation);
    }
    
    @safe unittest
    {
        // Test BPF instruction creation
        auto stmt = bpfStmt(BPF_LD | BPF_W | BPF_ABS, 0);
        assert(stmt.code == (BPF_LD | BPF_W | BPF_ABS));
        assert(stmt.k == 0);
        
        auto jmp = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, 100, 1, 0);
        assert(jmp.jt == 1);
        assert(jmp.jf == 0);
        assert(jmp.k == 100);
    }
    
    @system unittest
    {
        // Test filter building (structural only)
        uint[] blocked = [Syscalls.ptrace, Syscalls.mount];
        auto filter = buildBpfFilter(blocked, false);
        
        // Should have: arch load + arch check + kill + syscall load + 2*blocked + allow
        assert(filter.length == 3 + 1 + 4 + 1);
        
        // Empty list should return empty filter
        auto emptyFilter = buildBpfFilter([], false);
        assert(emptyFilter.length == 0);
    }
}

