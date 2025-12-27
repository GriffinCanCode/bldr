module engine.runtime.hermetic.sandbox.profiles;

version(OSX):

import std.algorithm : map, canFind, joiner;
import std.array : array, join;
import std.string : replace;
import std.conv : to;

import engine.runtime.hermetic.core.spec;

/// SBPL (Sandbox Profile Language) generator for macOS sandbox-exec
/// 
/// Design: Declarative security using scheme-like DSL
/// - Deny-by-default model
/// - Hierarchical rules with regex path matching
/// - Mach-O service filtering
/// - Network socket control
/// - IPC restrictions
struct SBPLGenerator
{
    private SandboxSpec spec;
    private string[] rules;
    
    /// Generate complete SBPL profile from spec
    static string generate(const ref SandboxSpec spec) @trusted
    {
        SBPLGenerator gen;
        gen.spec = cast(SandboxSpec) spec;
        
        gen.header();
        gen.defaultDeny();
        gen.processRules();
        gen.filesystemRules();
        gen.networkRules();
        gen.ipcRules();
        gen.machRules();
        gen.signalRules();
        gen.systemRules();
        
        return gen.rules.join("\n");
    }
    
    private void header() @safe
    {
        rules ~= "(version 1)";
        rules ~= "";
        rules ~= "; Auto-generated sandbox profile";
        rules ~= "; Hermetic build isolation for Builder";
        rules ~= "";
    }
    
    private void defaultDeny() @safe
    {
        rules ~= "; Default deny all operations";
        rules ~= "(deny default)";
        rules ~= "";
    }
    
    private void processRules() @safe
    {
        rules ~= "; Process operations";
        
        if (spec.process.allowFork)
            rules ~= "(allow process-fork)";
        
        if (spec.process.allowExec)
        {
            rules ~= "(allow process-exec";
            rules ~= "  (subpath \"/usr/bin\")";
            rules ~= "  (subpath \"/bin\")";
            rules ~= "  (subpath \"/usr/local/bin\")";
            rules ~= "  (subpath \"/opt/homebrew/bin\")";
            
            // Allow exec from input paths (compilers, tools)
            foreach (path; spec.inputs.paths)
                rules ~= "  (subpath \"" ~ escapeSBPL(path) ~ "\")";
            
            rules ~= ")";
        }
        
        rules ~= "";
    }
    
    private void filesystemRules() @safe
    {
        rules ~= "; Filesystem operations";
        
        // Essential system paths (read-only)
        rules ~= "(allow file-read*";
        rules ~= "  (subpath \"/usr/lib\")";
        rules ~= "  (subpath \"/usr/share\")";
        rules ~= "  (subpath \"/System/Library\")";
        rules ~= "  (subpath \"/Library/Frameworks\")";
        rules ~= "  (subpath \"/usr/local/lib\")";
        rules ~= "  (subpath \"/opt/homebrew/lib\")";
        rules ~= "  (subpath \"/opt/homebrew/Cellar\")";
        rules ~= "  (literal \"/dev/null\")";
        rules ~= "  (literal \"/dev/random\")";
        rules ~= "  (literal \"/dev/urandom\")";
        rules ~= "  (literal \"/dev/zero\")";
        rules ~= "  (subpath \"/private/var/db/timezone\")";
        rules ~= "  (literal \"/etc/localtime\")";
        rules ~= "  (literal \"/etc/passwd\")";
        rules ~= "  (literal \"/etc/group\")";
        rules ~= ")";
        
        // Input paths (read-only with metadata)
        if (spec.inputs.paths.length > 0)
        {
            rules ~= "(allow file-read* file-read-metadata";
            foreach (path; spec.inputs.paths)
                rules ~= "  (subpath \"" ~ escapeSBPL(path) ~ "\")";
            rules ~= ")";
        }
        
        // Output paths (read-write)
        if (spec.outputs.paths.length > 0)
        {
            rules ~= "(allow file-read* file-write* file-write-create";
            foreach (path; spec.outputs.paths)
                rules ~= "  (subpath \"" ~ escapeSBPL(path) ~ "\")";
            rules ~= ")";
        }
        
        // Temp paths (full access)
        if (spec.temps.paths.length > 0)
        {
            rules ~= "(allow file-read* file-write* file-write-create file-write-unlink";
            foreach (path; spec.temps.paths)
                rules ~= "  (subpath \"" ~ escapeSBPL(path) ~ "\")";
            rules ~= ")";
        }
        
        // Deny writes to system paths
        rules ~= "(deny file-write*";
        rules ~= "  (subpath \"/etc\")";
        rules ~= "  (subpath \"/var\")";
        rules ~= "  (subpath \"/System\")";
        rules ~= "  (subpath \"/Library\")";
        rules ~= "  (subpath \"/usr\")";
        rules ~= ")";
        
        rules ~= "";
    }
    
    private void networkRules() @safe
    {
        rules ~= "; Network operations";
        
        if (spec.network.isHermetic)
        {
            rules ~= "; Hermetic: deny all network";
            rules ~= "(deny network*)";
        }
        else
        {
            // DNS resolution
            if (spec.network.allowDns)
            {
                rules ~= "(allow network-outbound";
                rules ~= "  (remote udp \"*:53\")";
                rules ~= "  (remote tcp \"*:53\")";
                rules ~= ")";
            }
            
            // HTTP/HTTPS
            if (spec.network.allowHttp || spec.network.allowHttps)
            {
                if (spec.network.allowedHosts.length > 0)
                {
                    rules ~= "(allow network-outbound";
                    foreach (host; spec.network.allowedHosts)
                    {
                        if (spec.network.allowHttp)
                            rules ~= "  (remote tcp \"" ~ host ~ ":80\")";
                        if (spec.network.allowHttps)
                            rules ~= "  (remote tcp \"" ~ host ~ ":443\")";
                    }
                    rules ~= ")";
                }
                else
                {
                    rules ~= "(allow network-outbound";
                    if (spec.network.allowHttp)
                        rules ~= "  (remote tcp \"*:80\")";
                    if (spec.network.allowHttps)
                        rules ~= "  (remote tcp \"*:443\")";
                    rules ~= ")";
                }
            }
            
            // Always allow localhost connections
            rules ~= "(allow network-outbound";
            rules ~= "  (remote tcp \"localhost:*\")";
            rules ~= "  (remote tcp \"127.0.0.1:*\")";
            rules ~= "  (remote tcp \"::1:*\")";
            rules ~= ")";
            
            // Allow local sockets for tools
            rules ~= "(allow network-outbound (local unix-socket))";
        }
        
        // Deny inbound by default
        rules ~= "(deny network-inbound)";
        
        rules ~= "";
    }
    
    private void ipcRules() @safe
    {
        rules ~= "; IPC operations";
        
        // POSIX shared memory
        rules ~= "(allow ipc-posix-shm-read-data)";
        rules ~= "(allow ipc-posix-shm-write-data)";
        
        // POSIX semaphores (needed by many compilers)
        rules ~= "(allow ipc-posix-sem)";
        
        // Deny System V IPC
        rules ~= "(deny ipc-sysv*)";
        
        rules ~= "";
    }
    
    private void machRules() @safe
    {
        rules ~= "; Mach IPC operations";
        
        // Allow essential mach lookups
        rules ~= "(allow mach-lookup";
        rules ~= "  (global-name \"com.apple.system.logger\")";
        rules ~= "  (global-name \"com.apple.system.notification_center\")";
        rules ~= "  (global-name \"com.apple.CoreServices.coreservicesd\")";
        rules ~= "  (global-name \"com.apple.SecurityServer\")";
        rules ~= "  (global-name \"com.apple.distributed_notifications@Uv3\")";
        rules ~= ")";
        
        // Allow task_for_pid for same process only
        rules ~= "(allow mach-task-name)";
        
        // Deny dangerous mach operations
        rules ~= "(deny mach-register)";
        rules ~= "(deny mach-host-special-port-set)";
        
        rules ~= "";
    }
    
    private void signalRules() @safe
    {
        rules ~= "; Signal operations";
        rules ~= "(allow signal (target self))";
        rules ~= "(allow signal (target children))";
        rules ~= "";
    }
    
    private void systemRules() @safe
    {
        rules ~= "; System operations";
        
        // Allow sysctl read (needed for system info)
        rules ~= "(allow sysctl-read)";
        rules ~= "(deny sysctl-write)";
        
        // Allow process-info for self
        rules ~= "(allow process-info-pidinfo)";
        rules ~= "(allow process-info-setcontrol (target self))";
        
        // Deny dangerous operations
        rules ~= "(deny nvram*)";
        rules ~= "(deny iokit*)";
        rules ~= "(deny system-fsctl)";
        rules ~= "(deny system-socket)";
        
        // Deny code injection
        rules ~= "(deny file-map-executable (subpath \"/tmp\"))";
        rules ~= "(deny file-map-executable (subpath \"/var/tmp\"))";
        
        rules ~= "";
    }
    
    /// Escape string for SBPL
    private static string escapeSBPL(string path) @safe pure
    {
        return path.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}

/// Validate generated profile syntax
bool validateProfile(string profile) @system
{
    import std.process : execute;
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;
    
    // Write profile to temp file
    auto tempFile = buildPath(tempDir(), "validate-" ~ randomUUID().toString() ~ ".sb");
    
    try
    {
        write(tempFile, profile);
        
        // Dry-run sandbox-exec to validate syntax
        auto result = execute(["sandbox-exec", "-f", tempFile, "-n", "true"]);
        
        remove(tempFile);
        return result.status == 0;
    }
    catch (Exception)
    {
        try { remove(tempFile); } catch (Exception) {}
        return false;
    }
}

@system unittest
{
    // Test profile generation
    auto spec = SandboxSpecBuilder.create()
        .input("/usr/local")
        .output("/tmp/out")
        .temp("/tmp/work")
        .build();
    
    if (spec.isOk)
    {
        auto unwrapped = spec.unwrap();
        auto profile = SBPLGenerator.generate(unwrapped);
        
        assert(profile.canFind("(version 1)"));
        assert(profile.canFind("(deny default)"));
        assert(profile.canFind("/usr/local"));
        assert(profile.canFind("/tmp/out"));
    }
}


