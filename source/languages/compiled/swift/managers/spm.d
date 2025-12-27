module languages.compiled.swift.managers.spm;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import std.conv;
import infrastructure.utils.logging;

/// Swift Package Manager information
struct SPMPackageInfo
{
    string name;
    string version_;
    string[] dependencies;
    string[] products;
    string[] targets;
    bool isValid;
}

/// Swift Package Manager runner
class SPMRunner
{
    private string packagePath;
    private string swiftCmd;
    
    this(string packagePath = ".", string swiftCmd = "swift")
    {
        this.packagePath = packagePath;
        this.swiftCmd = swiftCmd;
    }
    
    /// Check if SPM is available
    static bool isAvailable()
    {
        auto res = execute(["swift", "package", "--help"]);
        return res.status == 0;
    }
    
    /// Get SPM version
    static string getVersion()
    {
        auto res = execute(["swift", "package", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Run swift package command
    auto runCommand(string[] args, string[string] env = null)
    {
        string[] cmd = [swiftCmd, "package"] ~ args;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env, Config.none, size_t.max, packagePath);
    }
    
    /// Initialize a new package
    auto init_(string type = "executable", string name = "")
    {
        string[] args = ["init", "--type", type];
        if (!name.empty)
            args ~= ["--name", name];
        
        return runCommand(args);
    }
    
    /// Resolve dependencies
    auto resolve()
    {
        return runCommand(["resolve"]);
    }
    
    /// Update dependencies
    auto update(string[] packages = [])
    {
        string[] args = ["update"];
        args ~= packages;
        return runCommand(args);
    }
    
    /// Reset package state
    auto reset()
    {
        return runCommand(["reset"]);
    }
    
    /// Clean build artifacts
    auto clean()
    {
        return runCommand(["clean"]);
    }
    
    /// Purge all cached data
    auto purgeCache()
    {
        return runCommand(["purge-cache"]);
    }
    
    /// Show package dependencies
    auto showDependencies(string format = "text")
    {
        return runCommand(["show-dependencies", "--format", format]);
    }
    
    /// Describe package
    auto describe(string type = "json")
    {
        return runCommand(["describe", "--type", type]);
    }
    
    /// Dump package manifest
    auto dumpPackage()
    {
        return runCommand(["dump-package"]);
    }
    
    /// Generate Xcode project
    auto generateXcodeproj(string[] opts = [])
    {
        return runCommand(["generate-xcodeproj"] ~ opts);
    }
    
    /// Edit package dependencies
    auto edit(string packageName, string[] opts = [])
    {
        return runCommand(["edit", packageName] ~ opts);
    }
    
    /// Unedit package dependencies
    auto unedit(string packageName, bool force = false)
    {
        string[] args = ["unedit", packageName];
        if (force)
            args ~= ["--force"];
        return runCommand(args);
    }
    
    /// Compute checksum
    auto computeChecksum(string filePath)
    {
        return runCommand(["compute-checksum", filePath]);
    }
    
    /// Archive source
    auto archiveSource(string outputPath = "")
    {
        string[] args = ["archive-source"];
        if (!outputPath.empty)
            args ~= ["--output", outputPath];
        return runCommand(args);
    }
    
    /// Completion script
    auto completionTool(string shell)
    {
        return runCommand(["completion-tool", shell]);
    }
    
    /// Plugin command
    auto plugin(string pluginName, string[] args = [])
    {
        return runCommand(["plugin", pluginName] ~ args);
    }
    
    /// Default localization
    auto defaultLocalization(string locale)
    {
        return runCommand(["default-localization", locale]);
    }
    
    /// Learn
    auto learn()
    {
        return runCommand(["learn"]);
    }
}

/// Swift build runner
class SwiftBuildRunner
{
    private string packagePath;
    private string swiftCmd;
    
    this(string packagePath = ".", string swiftCmd = "swift")
    {
        this.packagePath = packagePath;
        this.swiftCmd = swiftCmd;
    }
    
    /// Run swift build command
    auto runBuild(string[] args, string[string] env = null)
    {
        string[] cmd = [swiftCmd, "build"] ~ args;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env, Config.none, size_t.max, packagePath);
    }
    
    /// Build project
    auto build(
        string configuration = "release",
        string product = "",
        string target = "",
        string[] additionalArgs = []
    )
    {
        string[] args = ["-c", configuration];
        
        if (!product.empty)
            args ~= ["--product", product];
        if (!target.empty)
            args ~= ["--target", target];
        
        args ~= additionalArgs;
        
        return runBuild(args);
    }
    
    /// Show build settings
    auto showBuildSettings()
    {
        return runBuild(["--show-bin-path"]);
    }
}

/// Swift run runner
class SwiftRunRunner
{
    private string packagePath;
    private string swiftCmd;
    
    this(string packagePath = ".", string swiftCmd = "swift")
    {
        this.packagePath = packagePath;
        this.swiftCmd = swiftCmd;
    }
    
    /// Run swift run command
    auto run(
        string product = "",
        string[] productArgs = [],
        string configuration = "debug",
        string[string] env = null
    )
    {
        string[] cmd = [swiftCmd, "run"];
        
        cmd ~= ["-c", configuration];
        
        if (!product.empty)
            cmd ~= [product];
        
        if (!productArgs.empty)
        {
            cmd ~= ["--"];
            cmd ~= productArgs;
        }
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env, Config.none, size_t.max, packagePath);
    }
    
    /// Run in REPL mode
    auto repl(string[] args = [], string[string] env = null)
    {
        string[] cmd = [swiftCmd, "repl"] ~ args;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env, Config.none, size_t.max, packagePath);
    }
}

/// Swift test runner
class SwiftTestRunner
{
    private string packagePath;
    private string swiftCmd;
    
    this(string packagePath = ".", string swiftCmd = "swift")
    {
        this.packagePath = packagePath;
        this.swiftCmd = swiftCmd;
    }
    
    /// Run tests
    auto test(
        string[] filter = [],
        string[] skip = [],
        bool parallel = true,
        bool enableCodeCoverage = false,
        int numWorkers = 0,
        string[string] env = null
    )
    {
        string[] cmd = [swiftCmd, "test"];
        
        // Add filters
        foreach (f; filter)
            cmd ~= ["--filter", f];
        
        // Add skips
        foreach (s; skip)
            cmd ~= ["--skip", s];
        
        // Parallel testing
        if (!parallel)
            cmd ~= ["--parallel"];
        
        // Code coverage
        if (enableCodeCoverage)
            cmd ~= ["--enable-code-coverage"];
        
        // Number of workers
        if (numWorkers > 0)
            cmd ~= ["--num-workers", numWorkers.to!string];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env, Config.none, size_t.max, packagePath);
    }
    
    /// List tests
    auto list(string[string] env = null)
    {
        string[] cmd = [swiftCmd, "test", "list"];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env, Config.none, size_t.max, packagePath);
    }
}

/// Swift compiler runner
class SwiftCompilerRunner
{
    private string swiftcCmd;
    
    this(string swiftcCmd = "swiftc")
    {
        this.swiftcCmd = swiftcCmd;
    }
    
    /// Check if swiftc is available
    static bool isAvailable()
    {
        auto res = execute(["swiftc", "--version"]);
        return res.status == 0;
    }
    
    /// Get swiftc version
    static string getVersion()
    {
        auto res = execute(["swiftc", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Compile Swift files
    auto compile(
        string[] sources,
        string output,
        string[] additionalFlags = [],
        string[string] env = null
    )
    {
        string[] cmd = [swiftcCmd, "-o", output];
        cmd ~= additionalFlags;
        cmd ~= sources;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd, env);
    }
    
    /// Emit IR
    auto emitIR(string source, string output)
    {
        string[] cmd = [swiftcCmd, "-emit-ir", source, "-o", output];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
    
    /// Emit assembly
    auto emitAssembly(string source, string output)
    {
        string[] cmd = [swiftcCmd, "-emit-assembly", source, "-o", output];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
    
    /// Emit SIL
    auto emitSIL(string source, string output)
    {
        string[] cmd = [swiftcCmd, "-emit-sil", source, "-o", output];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
    
    /// Dump AST
    auto dumpAST(string source)
    {
        string[] cmd = [swiftcCmd, "-dump-ast", source];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
    
    /// Type check only
    auto typecheck(string[] sources)
    {
        string[] cmd = [swiftcCmd, "-typecheck"];
        cmd ~= sources;
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        return execute(cmd);
    }
}

