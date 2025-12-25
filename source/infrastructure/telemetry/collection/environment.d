module infrastructure.telemetry.collection.environment;

import std.datetime : SysTime, Clock;
import std.process : environment;
import std.algorithm : canFind, startsWith;
import std.array : array, split;
import std.string : strip;
import std.conv : to;
import std.file : exists;
import std.path : buildPath;

/// Build environment snapshot for reproducibility checking
/// Tracks tool versions, environment variables, and system info
struct BuildEnvironment
{
    /// Tool versions detected at build time
    string[string] toolVersions;
    
    /// Relevant environment variables (filtered for reproducibility)
    string[string] envVars;
    
    /// System information
    SystemInfo system;
    
    /// Time when build was performed
    SysTime buildTime;
    
    /// Create snapshot of current build environment
    /// 
    /// Safety: This function is @system because:
    /// 1. Calls to detectToolVersions() are validated I/O operations
    /// 2. Environment variable access is read-only
    /// 3. Clock.currTime() is safe time query
    /// 4. All string operations are bounds-checked
    /// 
    /// Invariants:
    /// - toolVersions contains only successfully detected tools
    /// - envVars contains only relevant build-affecting variables
    /// - buildTime is always valid
    /// 
    /// What could go wrong:
    /// - Tool detection subprocess fails: handled gracefully (empty version)
    /// - Environment variable access: handled by D runtime
    /// - System info detection fails: returns default values
    static BuildEnvironment snapshot() @system
    {
        BuildEnvironment env;
        env.toolVersions = detectToolVersions();
        env.envVars = captureRelevantEnvVars();
        env.system = SystemInfo.detect();
        env.buildTime = Clock.currTime();
        return env;
    }
    
    /// Compare two build environments for reproducibility
    /// Returns true if environments are equivalent for build purposes
    bool isCompatible(const BuildEnvironment other) const pure nothrow @system
    {
        // Check tool versions match
        foreach (pair; toolVersions.byKeyValue)
        {
            if (auto otherVersion = pair.key in other.toolVersions)
            {
                if (*otherVersion != pair.value)
                    return false; // Version mismatch
            }
            else
            {
                return false; // Tool missing in other environment
            }
        }
        
        // Check critical environment variables match (both directions)
        foreach (pair; envVars.byKeyValue)
        {
            if (isCriticalEnvVar(pair.key))
            {
                if (auto otherValue = pair.key in other.envVars)
                {
                    if (*otherValue != pair.value)
                        return false; // Critical env var mismatch
                }
                else
                {
                    return false; // Critical env var missing in other
                }
            }
        }
        
        // Check for critical env vars added in other but not in this
        foreach (pair; other.envVars.byKeyValue)
        {
            if (isCriticalEnvVar(pair.key))
            {
                if (pair.key !in envVars)
                    return false; // Critical env var added
            }
        }
        
        // Check system compatibility
        if (system.os != other.system.os)
            return false;
        if (system.arch != other.system.arch)
            return false;
        
        return true;
    }
    
    /// Get human-readable diff between environments
    string[] diff(const BuildEnvironment other) const pure @system
    {
        string[] differences;
        
        // Tool version differences
        foreach (pair; toolVersions.byKeyValue)
        {
            if (auto otherVersion = pair.key in other.toolVersions)
            {
                if (*otherVersion != pair.value)
                    differences ~= "Tool " ~ pair.key ~ ": " ~ pair.value ~ " → " ~ *otherVersion;
            }
            else
            {
                differences ~= "Tool " ~ pair.key ~ ": present → missing";
            }
        }
        
        // Check for new tools in other
        foreach (pair; other.toolVersions.byKeyValue)
        {
            if (pair.key !in toolVersions)
                differences ~= "Tool " ~ pair.key ~ ": missing → " ~ pair.value;
        }
        
        // Environment variable differences
        foreach (pair; envVars.byKeyValue)
        {
            if (isCriticalEnvVar(pair.key))
            {
                if (auto otherValue = pair.key in other.envVars)
                {
                    if (*otherValue != pair.value)
                        differences ~= "EnvVar " ~ pair.key ~ ": " ~ pair.value ~ " → " ~ *otherValue;
                }
                else
                {
                    differences ~= "EnvVar " ~ pair.key ~ ": present → missing";
                }
            }
        }
        
        // System differences
        if (system.os != other.system.os)
            differences ~= "OS: " ~ system.os ~ " → " ~ other.system.os;
        if (system.arch != other.system.arch)
            differences ~= "Arch: " ~ system.arch ~ " → " ~ other.system.arch;
        
        return differences;
    }
    
    /// Display formatted environment info
    string toString() const pure @system
    {
        import std.format : format;
        import std.algorithm : sort;
        
        string result;
        result ~= "=== Build Environment ===\n\n";
        
        // System info
        result ~= "[System]\n";
        result ~= format("  OS:          %s\n", system.os);
        result ~= format("  Arch:        %s\n", system.arch);
        result ~= format("  CPU Cores:   %d\n", system.cpuCores);
        result ~= format("  Hostname:    %s\n", system.hostname);
        result ~= "\n";
        
        // Tool versions
        result ~= "[Tools]\n";
        auto sortedTools = toolVersions.keys.dup.sort;
        foreach (tool; sortedTools)
        {
            result ~= format("  %-12s %s\n", tool ~ ":", toolVersions[tool]);
        }
        result ~= "\n";
        
        // Environment variables
        result ~= "[Environment]\n";
        auto sortedEnv = envVars.keys.dup.sort;
        foreach (key; sortedEnv)
        {
            result ~= format("  %-20s %s\n", key ~ ":", envVars[key]);
        }
        
        return result;
    }
    
    /// Detect versions of common build tools
    private static string[string] detectToolVersions() @system
    {
        string[string] versions;
        
        // Define tools to detect with their version commands
        static immutable toolCommands = [
            "gcc": ["gcc", "--version"],
            "g++": ["g++", "--version"],
            "clang": ["clang", "--version"],
            "clang++": ["clang++", "--version"],
            "dmd": ["dmd", "--version"],
            "ldc2": ["ldc2", "--version"],
            "gdc": ["gdc", "--version"],
            "python": ["python3", "--version"],
            "node": ["node", "--version"],
            "npm": ["npm", "--version"],
            "go": ["go", "version"],
            "rustc": ["rustc", "--version"],
            "cargo": ["cargo", "--version"],
            "javac": ["javac", "-version"],
            "make": ["make", "--version"],
            "cmake": ["cmake", "--version"],
            "ninja": ["ninja", "--version"],
            "git": ["git", "--version"],
        ];
        
        foreach (tool, command; toolCommands)
        {
            try
            {
                import std.process : execute;
                auto result = execute(command);
                if (result.status == 0)
                {
                    // Extract version from output (first line usually)
                    auto lines = result.output.split("\n");
                    if (lines.length > 0)
                        versions[tool] = parseVersion(lines[0]);
                }
            }
            catch (Exception)
            {
                // Tool not available, skip it
            }
        }
        
        return versions;
    }
    
    /// Parse version string from tool output
    private static string parseVersion(string output) pure nothrow @system
    {
        // Simple version extraction - take first line and strip
        auto stripped = output.strip();
        if (stripped.length > 200)
            stripped = stripped[0..200]; // Limit length
        return stripped;
    }
    
    /// Capture environment variables relevant for build reproducibility
    private static string[string] captureRelevantEnvVars() @system
    {
        string[string] relevant;
        
        // List of environment variables that affect builds
        static immutable relevantKeys = [
            "PATH",
            "CC", "CXX", "FC",                    // Compiler selection
            "CFLAGS", "CXXFLAGS", "LDFLAGS",      // Compiler flags
            "MAKEFLAGS",                          // Make flags
            "CMAKE_PREFIX_PATH",                  // CMake paths
            "PKG_CONFIG_PATH",                    // Pkg-config
            "PYTHON", "PYTHON_PATH",              // Python
            "GOPATH", "GOROOT",                   // Go
            "RUSTFLAGS",                          // Rust
            "JAVA_HOME",                          // Java
            "NODE_ENV",                           // Node.js
            "BUILDER_CACHE_DIR",                  // Builder-specific
            "BUILDER_PARALLEL",
        ];
        
        foreach (key; relevantKeys)
        {
            auto value = environment.get(key, null);
            if (value !is null && value.length > 0)
                relevant[key] = value;
        }
        
        return relevant;
    }
    
    /// Check if an environment variable is critical for reproducibility
    private static bool isCriticalEnvVar(string key) pure nothrow @system
    {
        // Critical variables that must match exactly
        return key == "CC" || key == "CXX" || key == "FC" ||
               key.startsWith("CFLAGS") || key.startsWith("CXXFLAGS") ||
               key == "MAKEFLAGS" || key == "RUSTFLAGS";
    }
}

/// System information for build environment
struct SystemInfo
{
    string os;          // Operating system
    string arch;        // Architecture (x86_64, arm64, etc.)
    size_t cpuCores;    // Number of CPU cores
    string hostname;    // Machine hostname (for tracking)
    
    /// Detect current system information
    /// 
    /// Safety: This function is @system because:
    /// 1. version() checks are compile-time constants
    /// 2. Environment access is read-only
    /// 3. String operations are bounds-checked
    /// 
    /// Invariants:
    /// - os and arch are never null (set to defaults if detection fails)
    /// - cpuCores is always >= 1
    /// 
    /// What could go wrong:
    /// - Environment variables missing: handled with defaults
    /// - Subprocess execution fails: handled with defaults
    static SystemInfo detect() @system
    {
        SystemInfo info;
        
        // Detect OS
        version(Windows)
            info.os = "Windows";
        else version(linux)
            info.os = "Linux";
        else version(OSX)
            info.os = "macOS";
        else version(FreeBSD)
            info.os = "FreeBSD";
        else version(OpenBSD)
            info.os = "OpenBSD";
        else version(NetBSD)
            info.os = "NetBSD";
        else version(Solaris)
            info.os = "Solaris";
        else
            info.os = "Unknown";
        
        // Detect architecture
        version(X86_64)
            info.arch = "x86_64";
        else version(X86)
            info.arch = "x86";
        else version(AArch64)
            info.arch = "arm64";
        else version(ARM)
            info.arch = "arm";
        else version(PPC64)
            info.arch = "ppc64";
        else version(PPC)
            info.arch = "ppc";
        else version(MIPS64)
            info.arch = "mips64";
        else version(MIPS)
            info.arch = "mips";
        else
            info.arch = "unknown";
        
        // Detect CPU cores
        import std.parallelism : totalCPUs;
        info.cpuCores = totalCPUs;
        
        // Get hostname
        info.hostname = environment.get("HOSTNAME", environment.get("COMPUTERNAME", "unknown"));
        
        return info;
    }
}

unittest
{
    import std.stdio : writeln;
    
    // Test BuildEnvironment snapshot
    {
        auto env = BuildEnvironment.snapshot();
        
        // Should have detected some tools
        assert(env.toolVersions.length > 0, "Should detect at least one tool");
        
        // Should have system info
        assert(env.system.os.length > 0);
        assert(env.system.arch.length > 0);
        assert(env.system.cpuCores > 0);
        
        // Should have captured PATH at minimum
        assert("PATH" in env.envVars);
    }
    
    // Test compatibility checking
    {
        auto env1 = BuildEnvironment.snapshot();
        auto env2 = BuildEnvironment.snapshot();
        
        // Same environment should be compatible
        assert(env1.isCompatible(env2));
        
        // Modified environment should not be compatible
        env2.toolVersions["gcc"] = "999.0.0";
        assert(!env1.isCompatible(env2));
    }
    
    // Test diff generation
    {
        auto env1 = BuildEnvironment.snapshot();
        auto env2 = BuildEnvironment.snapshot();
        
        env2.toolVersions["test-tool"] = "1.0.0";
        auto differences = env1.diff(env2);
        
        assert(differences.length > 0);
        assert(differences[0].canFind("test-tool"));
    }
    
    // Test SystemInfo
    {
        auto sys = SystemInfo.detect();
        assert(sys.os.length > 0);
        assert(sys.arch.length > 0);
        assert(sys.cpuCores > 0);
    }
}

