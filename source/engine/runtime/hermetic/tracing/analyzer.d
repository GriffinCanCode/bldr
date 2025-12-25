module engine.runtime.hermetic.tracing.analyzer;

import std.algorithm : filter, map, sort, uniq, canFind, any;
import std.array : array, Appender;
import std.range : walkLength;
import std.string : indexOf, startsWith;
import std.conv : to;
import engine.runtime.hermetic.tracing.tracer;

/// Severity of hermeticity violation
enum ViolationSeverity
{
    Critical,   // Definite hermeticity breach (network, external writes)
    High,       // Likely non-hermetic (user dirs, system config)
    Medium,     // Potentially problematic (tmp without cleanup)
    Low,        // Minor concern (readable system paths)
    Info        // Informational only
}

/// Category of violation
enum ViolationCategory
{
    Network,           // Network access
    ExternalRead,      // Reading from non-hermetic paths
    ExternalWrite,     // Writing to non-hermetic paths
    UserData,          // Accessing user-specific data
    SystemConfig,      // Reading system configuration
    TimeAccess,        // Accessing time (non-determinism)
    RandomAccess,      // Accessing random sources
    EnvironmentLeak,   // Environment variable leakage
    ProcessLeak,       // Process information leakage
    Unknown            // Unclassified violation
}

/// A detected hermeticity violation
struct HermeticityViolation
{
    ViolationSeverity severity;
    ViolationCategory category;
    string description;
    string path;                   // Affected path (if file-related)
    string syscallName;            // Syscall that caused this violation
    string[] suggestions;          // How to fix this violation
    
    /// Format violation for display
    string toString() const @safe
    {
        import std.format : format;
        return format!"[%s] %s: %s"(severity, category, description);
    }
}

/// Hermeticity analysis result
struct HermeticityAnalysis
{
    bool hermetic;                       // Overall hermeticity status
    HermeticityViolation[] violations;   // All detected violations
    HermeticityViolation[] critical;     // Critical violations only
    string[] networkAccesses;            // Network endpoints accessed
    string[] externalPaths;              // Non-hermetic paths accessed
    SyscallStatistics stats;             // Syscall statistics
    
    /// Get violations by severity (lazy range)
    auto bySeverity(ViolationSeverity sev) const @safe
    {
        return violations.filter!(v => v.severity == sev);
    }
    
    /// Get violations by category (lazy range)
    auto byCategory(ViolationCategory cat) const @safe
    {
        return violations.filter!(v => v.category == cat);
    }
    
    /// Generate human-readable report
    string report() const @safe
    {
        Appender!string sb;
        
        sb ~= "═══════════════════════════════════════════════════════════════\n";
        sb ~= "                    HERMETICITY ANALYSIS REPORT                 \n";
        sb ~= "═══════════════════════════════════════════════════════════════\n\n";
        
        sb ~= hermetic ? "✓ BUILD IS HERMETIC\n\n" : "✗ BUILD IS NOT HERMETIC\n\n";
        
        // Summary
        sb ~= "Summary:\n";
        sb ~= "────────────────────────────────────────\n";
        sb ~= "  Total syscalls traced: " ~ stats.totalSyscalls.to!string ~ "\n";
        sb ~= "  File operations:       " ~ stats.fileOps.to!string ~ "\n";
        sb ~= "  Network operations:    " ~ stats.networkOps.to!string ~ "\n";
        sb ~= "  Process operations:    " ~ stats.processOps.to!string ~ "\n";
        sb ~= "  Unique files accessed: " ~ stats.uniqueFiles.to!string ~ "\n";
        sb ~= "\n";
        
        // Violations by severity
        if (violations.length > 0)
        {
            sb ~= "Violations:\n";
            sb ~= "────────────────────────────────────────\n";
            
            foreach (sev; [ViolationSeverity.Critical, ViolationSeverity.High,
                          ViolationSeverity.Medium, ViolationSeverity.Low])
            {
                auto sevViolations = bySeverity(sev).array;  // materialize once for count + iteration
                if (sevViolations.length > 0)
                {
                    sb ~= "\n  " ~ sev.to!string ~ " (" ~ sevViolations.length.to!string ~ "):\n";
                    foreach (v; sevViolations)
                    {
                        sb ~= "    • " ~ v.description ~ "\n";
                        if (v.path.length > 0)
                            sb ~= "      Path: " ~ v.path ~ "\n";
                        foreach (suggestion; v.suggestions)
                            sb ~= "      → " ~ suggestion ~ "\n";
                    }
                }
            }
            sb ~= "\n";
        }
        
        // External paths accessed
        if (externalPaths.length > 0)
        {
            sb ~= "External Paths Accessed:\n";
            sb ~= "────────────────────────────────────────\n";
            foreach (p; externalPaths)
                sb ~= "  " ~ p ~ "\n";
            sb ~= "\n";
        }
        
        // Network accesses
        if (networkAccesses.length > 0)
        {
            sb ~= "Network Accesses:\n";
            sb ~= "────────────────────────────────────────\n";
            foreach (n; networkAccesses)
                sb ~= "  " ~ n ~ "\n";
            sb ~= "\n";
        }
        
        sb ~= "═══════════════════════════════════════════════════════════════\n";
        
        return sb.data;
    }
}

/// Syscall statistics
struct SyscallStatistics
{
    size_t totalSyscalls;
    size_t fileOps;
    size_t networkOps;
    size_t processOps;
    size_t memoryOps;
    size_t uniqueFiles;
    size_t[string] syscallCounts;
}

/// Configuration for hermeticity analysis
struct AnalyzerConfig
{
    string[] allowedPaths;       // Paths that are allowed to be accessed
    string[] workspacePaths;     // Workspace paths (allowed read/write)
    string[] toolchainPaths;     // Toolchain paths (allowed read)
    bool strictNetwork = true;   // Fail on any network access
    bool allowReadonly = true;   // Allow readonly access to system paths
    bool checkTimeSources = true;// Check for time-related syscalls
    bool checkRandomness = true; // Check for random sources
    
    /// Create strict hermetic config
    static AnalyzerConfig strict() @safe pure nothrow
    {
        AnalyzerConfig cfg;
        cfg.toolchainPaths = [
            "/usr/", "/lib/", "/lib64/", "/bin/", "/sbin/",
            "/System/", "/Library/", "/Applications/Xcode.app/"
        ];
        return cfg;
    }
    
    /// Create permissive config (more lenient)
    static AnalyzerConfig permissive() @safe pure nothrow
    {
        AnalyzerConfig cfg = strict();
        cfg.strictNetwork = false;
        cfg.checkTimeSources = false;
        cfg.checkRandomness = false;
        return cfg;
    }
    
    /// Add workspace path
    ref AnalyzerConfig workspace(string path) return @safe pure nothrow
    {
        workspacePaths ~= path;
        allowedPaths ~= path;
        return this;
    }
}

/// Syscall trace analyzer for hermeticity verification
struct SyscallAnalyzer
{
    private AnalyzerConfig config;
    
    /// Create analyzer with config
    static SyscallAnalyzer create(AnalyzerConfig config = AnalyzerConfig.strict()) @safe pure nothrow
    {
        SyscallAnalyzer analyzer;
        analyzer.config = config;
        return analyzer;
    }
    
    /// Analyze trace result for hermeticity violations
    HermeticityAnalysis analyze(const TraceResult trace) const @safe
    {
        HermeticityAnalysis result;
        
        // Compute statistics
        result.stats = computeStats(trace);
        
        // Analyze each event
        foreach (ref event; trace.events)
        {
            auto violations = analyzeEvent(event);
            result.violations ~= violations;
        }
        
        // Extract critical violations
        result.critical = result.violations
            .filter!(v => v.severity == ViolationSeverity.Critical)
            .array;
        
        // Collect external paths
        result.externalPaths = trace.events
            .filter!(e => e.isExternalAccess())
            .map!(e => e.filePath())
            .filter!(p => p.length > 0)
            .array
            .sort
            .uniq
            .array;
        
        // Collect network accesses
        result.networkAccesses = trace.events
            .filter!(e => e.isNetworkOp())
            .map!(e => e.args.length > 0 ? e.args[0] : "unknown")
            .array
            .sort
            .uniq
            .array;
        
        // Determine overall hermeticity
        result.hermetic = result.critical.length == 0 && 
                         (config.strictNetwork ? result.networkAccesses.length == 0 : true);
        
        return result;
    }
    
    /// Analyze a single syscall event
    HermeticityViolation[] analyzeEvent(const ref SyscallEvent event) const @safe
    {
        HermeticityViolation[] violations;
        
        // Check network operations
        if (event.isNetworkOp())
        {
            violations ~= createViolation(
                ViolationSeverity.Critical,
                ViolationCategory.Network,
                "Network access detected: " ~ event.syscallName,
                event.args.length > 0 ? event.args[0] : "",
                event.syscallName,
                ["Use --network=none to disable network", 
                 "Pre-fetch dependencies before build"]
            );
        }
        
        // Check file operations
        immutable path = event.filePath();
        if (path.length > 0)
            violations ~= analyzeFilePath(path, event);
        
        // Check time-related syscalls
        if (config.checkTimeSources && isTimeRelated(event.syscallName))
        {
            violations ~= createViolation(
                ViolationSeverity.Medium,
                ViolationCategory.TimeAccess,
                "Time source accessed: " ~ event.syscallName,
                "",
                event.syscallName,
                ["Use SOURCE_DATE_EPOCH for reproducible timestamps",
                 "Use determinism shim library"]
            );
        }
        
        // Check random sources
        if (config.checkRandomness && isRandomSource(path))
        {
            violations ~= createViolation(
                ViolationSeverity.Medium,
                ViolationCategory.RandomAccess,
                "Random source accessed: " ~ path,
                path,
                event.syscallName,
                ["Use RANDOM_SEED environment variable",
                 "Use determinism shim library"]
            );
        }
        
        return violations;
    }
    
    /// Analyze file path access
    HermeticityViolation[] analyzeFilePath(string path, const ref SyscallEvent event) const @safe
    {
        HermeticityViolation[] violations;
        
        // Check if path is in allowed list
        if (isPathAllowed(path))
            return violations;
        
        // Check for user data access
        if (isUserPath(path))
        {
            violations ~= createViolation(
                ViolationSeverity.Critical,
                ViolationCategory.UserData,
                "User directory accessed",
                path,
                event.syscallName,
                ["Remove dependency on user-specific paths",
                 "Use workspace-relative paths only"]
            );
        }
        // Check for system config access
        else if (isSystemConfigPath(path))
        {
            violations ~= createViolation(
                ViolationSeverity.High,
                ViolationCategory.SystemConfig,
                "System configuration accessed",
                path,
                event.syscallName,
                ["Avoid reading system configuration",
                 "Use explicit configuration instead"]
            );
        }
        // Check for tmp without workspace
        else if (isTempPath(path) && !isInWorkspace(path))
        {
            violations ~= createViolation(
                ViolationSeverity.Medium,
                ViolationCategory.ExternalWrite,
                "Temporary file outside workspace",
                path,
                event.syscallName,
                ["Use workspace temp directory",
                 "Set TMPDIR to workspace location"]
            );
        }
        // External path access
        else if (!isToolchainPath(path))
        {
            violations ~= createViolation(
                config.allowReadonly && event.syscallName.indexOf("read") >= 0 
                    ? ViolationSeverity.Low 
                    : ViolationSeverity.High,
                ViolationCategory.ExternalRead,
                "External path accessed",
                path,
                event.syscallName,
                ["Add path to allowed list if necessary",
                 "Use hermetic toolchain"]
            );
        }
        
        return violations;
    }
    
    /// Create violation with all fields
    static HermeticityViolation createViolation(
        ViolationSeverity severity,
        ViolationCategory category,
        string description,
        string path,
        string syscallName,
        string[] suggestions
    ) @safe pure nothrow
    {
        HermeticityViolation v;
        v.severity = severity;
        v.category = category;
        v.description = description;
        v.path = path;
        v.syscallName = syscallName;
        v.suggestions = suggestions;
        return v;
    }
    
    /// Compute statistics from trace
    static SyscallStatistics computeStats(const TraceResult trace) @safe
    {
        SyscallStatistics stats;
        stats.totalSyscalls = trace.events.length;
        
        string[] files;
        
        foreach (ref event; trace.events)
        {
            // Count by category
            if (event.isNetworkOp())
                stats.networkOps++;
            else if (isFileOp(event.syscallName))
                stats.fileOps++;
            else if (isProcessOp(event.syscallName))
                stats.processOps++;
            else if (isMemoryOp(event.syscallName))
                stats.memoryOps++;
            
            // Count by syscall name
            if (event.syscallName in stats.syscallCounts)
                stats.syscallCounts[event.syscallName]++;
            else
                stats.syscallCounts[event.syscallName] = 1;
            
            // Track unique files
            immutable path = event.filePath();
            if (path.length > 0 && !files.canFind(path))
                files ~= path;
        }
        
        stats.uniqueFiles = files.length;
        return stats;
    }
    
    private:
    
    /// Check if path is allowed
    bool isPathAllowed(string path) const @safe pure nothrow
    {
        foreach (allowed; config.allowedPaths)
            if (path.length >= allowed.length && path[0 .. allowed.length] == allowed)
                return true;
        return false;
    }
    
    /// Check if path is in workspace
    bool isInWorkspace(string path) const @safe pure nothrow
    {
        foreach (ws; config.workspacePaths)
            if (path.length >= ws.length && path[0 .. ws.length] == ws)
                return true;
        return false;
    }
    
    /// Check if path is toolchain path
    bool isToolchainPath(string path) const @safe pure nothrow
    {
        foreach (tc; config.toolchainPaths)
            if (path.length >= tc.length && path[0 .. tc.length] == tc)
                return true;
        return false;
    }
    
    /// Check if path is user directory
    static bool isUserPath(string path) @safe pure nothrow
    {
        return path.startsWith("/home/") || 
               path.startsWith("/Users/") ||
               path.startsWith("~");
    }
    
    /// Check if path is system config
    static bool isSystemConfigPath(string path) @safe pure nothrow
    {
        return path.startsWith("/etc/") ||
               path.startsWith("/var/") ||
               path.indexOf(".config") >= 0 ||
               path.indexOf(".local") >= 0;
    }
    
    /// Check if path is temp directory
    static bool isTempPath(string path) @safe pure nothrow
    {
        return path.startsWith("/tmp/") ||
               path.startsWith("/private/tmp/") ||
               path.startsWith("/var/tmp/");
    }
    
    /// Check if path is random source
    static bool isRandomSource(string path) @safe pure nothrow
    {
        return path == "/dev/random" || 
               path == "/dev/urandom" ||
               path == "/dev/arandom";
    }
    
    /// Check if syscall is time-related
    static bool isTimeRelated(string syscall) @safe pure nothrow
    {
        static immutable timeSyscalls = [
            "time", "gettimeofday", "clock_gettime", "clock_getres"
        ];
        return timeSyscalls.canFind(syscall);
    }
    
    /// Check if syscall is file operation
    static bool isFileOp(string syscall) @safe pure nothrow
    {
        static immutable fileOps = [
            "open", "openat", "close", "read", "write", "stat", "fstat",
            "lstat", "access", "faccessat", "readlink", "unlink", "rename",
            "mkdir", "rmdir", "chmod", "chown", "creat", "truncate"
        ];
        return fileOps.canFind(syscall);
    }
    
    /// Check if syscall is process operation
    static bool isProcessOp(string syscall) @safe pure nothrow
    {
        static immutable procOps = [
            "fork", "vfork", "clone", "clone3", "execve", "execveat",
            "exit", "exit_group", "wait4", "waitid"
        ];
        return procOps.canFind(syscall);
    }
    
    /// Check if syscall is memory operation
    static bool isMemoryOp(string syscall) @safe pure nothrow
    {
        static immutable memOps = [
            "mmap", "munmap", "mprotect", "brk", "mremap"
        ];
        return memOps.canFind(syscall);
    }
}

/// Convenience function to analyze trace for hermeticity
HermeticityAnalysis analyzeHermeticity(
    const TraceResult trace,
    AnalyzerConfig config = AnalyzerConfig.strict()
) @safe
{
    return SyscallAnalyzer.create(config).analyze(trace);
}

@safe unittest
{
    import std.stdio : writeln;
    
    writeln("Testing syscall analyzer...");
    
    // Test analyzer creation
    auto analyzer = SyscallAnalyzer.create(AnalyzerConfig.strict());
    
    // Test event analysis
    SyscallEvent networkEvent;
    networkEvent.syscallName = "connect";
    networkEvent.args = ["192.168.1.1:80"];
    
    auto violations = analyzer.analyzeEvent(networkEvent);
    assert(violations.length > 0);
    assert(violations[0].severity == ViolationSeverity.Critical);
    assert(violations[0].category == ViolationCategory.Network);
    
    // Test file path analysis
    SyscallEvent fileEvent;
    fileEvent.syscallName = "open";
    fileEvent.args = ["/home/user/.bashrc"];
    
    violations = analyzer.analyzeEvent(fileEvent);
    assert(violations.length > 0);
    assert(violations[0].category == ViolationCategory.UserData);
    
    // Test allowed path
    SyscallEvent allowedEvent;
    allowedEvent.syscallName = "open";
    allowedEvent.args = ["/usr/lib/libc.so"];
    
    auto analyzer2 = SyscallAnalyzer.create(AnalyzerConfig.strict());
    violations = analyzer2.analyzeEvent(allowedEvent);
    // Should be allowed (toolchain path)
    
    // Test trace analysis
    TraceResult trace;
    trace.events = [networkEvent, fileEvent, allowedEvent];
    trace.traceSuccessful = true;
    
    auto analysis = analyzer.analyze(trace);
    assert(!analysis.hermetic);  // Network access makes it non-hermetic
    assert(analysis.critical.length > 0);
    assert(analysis.networkAccesses.length > 0);
    
    // Test report generation
    auto report = analysis.report();
    assert(report.indexOf("HERMETICITY") >= 0);
    assert(report.indexOf("NOT HERMETIC") >= 0);
    
    writeln("✓ Syscall analyzer tests passed");
}

