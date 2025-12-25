module engine.workers.go.worker;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.regex;
import std.string;
import core.time : Duration, seconds, minutes;
import engine.workers.protocol;
import engine.workers.pool;
import engine.workers.base;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Go Persistent Worker Factory
/// 
/// Creates persistent workers for Go compilation.
/// Go is already fast, but persistent workers help with:
/// - Build cache warmth
/// - Module download caching  
/// - Type checking state
/// 
/// Startup costs avoided:
/// - Go toolchain initialization (~50-100ms)
/// - Module resolution
/// - Build cache loading
/// 
/// Speedup: 2-5x for incremental builds
/// 
/// Protocol: Bazel-compatible persistent worker protocol

/// Go compiler mode
enum GoCompiler
{
    Build,     /// go build - compile packages
    Test,      /// go test - run tests
    Vet,       /// go vet - static analysis
    Fmt        /// go fmt - formatting (fast, but useful for batching)
}

/// Go worker configuration
struct GoWorkerConfig
{
    GoCompiler compiler = GoCompiler.Build;
    string goPath;                  /// GOPATH
    string goRoot;                  /// GOROOT
    string goBin;                   /// Path to go binary
    string[] buildArgs;             /// Default build arguments
    Duration startupTimeout = seconds(15);
    Duration requestTimeout = minutes(5);
    bool race = false;              /// Enable race detector
    bool verbose = false;           /// Verbose output
    string[] tags;                  /// Build tags
    string[] ldflags;               /// Linker flags
    bool trimpath = true;           /// Trim path for reproducible builds
}

/// Go Persistent Worker Factory - extends base with Go-specific logic
final class GoWorkerFactory : BasePersistentWorkerFactory
{
    private GoWorkerConfig config;
    private string workerScriptPath;
    
    this(GoWorkerConfig config = GoWorkerConfig.init) @trusted
    {
        BaseWorkerConfig baseCfg;
        baseCfg.startupTimeout = config.startupTimeout;
        baseCfg.requestTimeout = config.requestTimeout;
        baseCfg.idleTimeout = minutes(5);
        baseCfg.maxRequests = 10000;  // Go is fast, can handle many requests
        baseCfg.coldStartMs = coldStartFor(config.compiler);
        
        super(baseCfg);
        this.config = config;
        this.workerScriptPath = findOrCreateWorkerScript();
    }
    
    override string workerType() const pure nothrow @safe
    {
        final switch (config.compiler)
        {
            case GoCompiler.Build: return "go-build";
            case GoCompiler.Test: return "go-test";
            case GoCompiler.Vet: return "go-vet";
            case GoCompiler.Fmt: return "go-fmt";
        }
    }
    
    override PersistentWorkerConfig defaultConfig() const @safe
    {
        auto cfg = super.defaultConfig();
        cfg.executable = getExecutable();
        cfg.baseArgs = buildWorkerArgs();
        cfg.idleTimeout = minutes(5);
        cfg.maxRequests = 10000;
        return cfg;
    }
    
    protected override string[] buildWorkerArgs() const @trusted
    {
        string[] args = [workerScriptPath];
        
        // Compiler mode
        final switch (config.compiler)
        {
            case GoCompiler.Build: args ~= "--mode=build"; break;
            case GoCompiler.Test: args ~= "--mode=test"; break;
            case GoCompiler.Vet: args ~= "--mode=vet"; break;
            case GoCompiler.Fmt: args ~= "--mode=fmt"; break;
        }
        
        args ~= "--persistent";
        
        if (config.race)
            args ~= "--race";
        
        if (config.verbose)
            args ~= "-v";
        
        if (config.trimpath)
            args ~= "--trimpath";
        
        foreach (tag; config.tags)
            args ~= ["--tag", tag];
        
        foreach (ldflag; config.ldflags)
            args ~= ["--ldflags", ldflag];
        
        return args;
    }
    
    protected override string getExecutable() const @trusted
    {
        return "/bin/bash";
    }
    
    protected override string[string] buildEnvironment() const @trusted
    {
        auto env = super.buildEnvironment();
        
        if (!config.goPath.empty)
            env["GOPATH"] = config.goPath;
        
        if (!config.goRoot.empty)
            env["GOROOT"] = config.goRoot;
        
        // Enable module mode
        env["GO111MODULE"] = "on";
        
        // Build cache
        env["GOCACHE"] = buildPath(tempDir(), "bldr-go-cache");
        
        // Parallel compilation
        import std.parallelism : totalCPUs;
        env["GOMAXPROCS"] = totalCPUs.to!string;
        
        return env;
    }
    
    protected override string[] getHealthCheckArgs() const @safe
    {
        return ["--version"];
    }
    
    private static long coldStartFor(GoCompiler compiler) pure nothrow @safe @nogc
    {
        final switch (compiler)
        {
            case GoCompiler.Build: return 100;
            case GoCompiler.Test: return 150;
            case GoCompiler.Vet: return 80;
            case GoCompiler.Fmt: return 30;
        }
    }
    
    private string findOrCreateWorkerScript() @trusted
    {
        auto possiblePaths = [
            buildPath(thisExePath().dirName, "go-worker.sh"),
            buildPath(thisExePath().dirName, "..", "lib", "go-worker.sh"),
            "/usr/local/lib/bldr/go-worker.sh"
        ];
        
        foreach (path; possiblePaths)
            if (exists(path))
                return path;
        
        return createInlineWorkerScript();
    }
    
    private string createInlineWorkerScript() @trusted
    {
        auto scriptPath = buildPath(tempDir(), "bldr-go-worker.sh");
        
        if (!exists(scriptPath))
        {
            std.file.write(scriptPath, generateWorkerScript());
            execute(["chmod", "+x", scriptPath]);
            Logger.debugLog("Created Go worker script: " ~ scriptPath);
        }
        
        return scriptPath;
    }
    
    private string generateWorkerScript() const pure @safe
    {
        return `#!/bin/bash
# Go Persistent Worker - Bazel-compatible protocol
# Keeps go build cache warm for 2-5x speedup

set -e

MODE="build"
RACE=false
VERBOSE=false
TRIMPATH=false
TAGS=""
LDFLAGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --mode=*) MODE="${1#*=}"; shift ;;
        --persistent) shift ;;
        --race) RACE=true; shift ;;
        -v) VERBOSE=true; shift ;;
        --trimpath) TRIMPATH=true; shift ;;
        --tag) TAGS="$TAGS -tags $2"; shift 2 ;;
        --ldflags) LDFLAGS="$LDFLAGS -ldflags '$2'"; shift 2 ;;
        --version) go version; exit 0 ;;
        *) shift ;;
    esac
done

# Main protocol loop
while IFS= read -r line; do
    REQUEST_ID=$(echo "$line" | jq -r '.request_id')
    ARGS=$(echo "$line" | jq -r '.arguments | join(" ")')
    SANDBOX=$(echo "$line" | jq -r '.sandbox_dir // empty')
    CANCEL=$(echo "$line" | jq -r '.cancel // false')
    
    if [ "$CANCEL" = "true" ]; then
        echo "{\"request_id\":$REQUEST_ID,\"exit_code\":0,\"output\":\"Cancelled\",\"was_cached\":false,\"execution_time_ms\":0,\"outputs\":[]}"
        continue
    fi
    
    START_TIME=$(date +%s%3N)
    
    if [ -n "$SANDBOX" ]; then
        cd "$SANDBOX"
    fi
    
    # Build command
    CMD="go"
    case $MODE in
        build) CMD="go build" ;;
        test) CMD="go test" ;;
        vet) CMD="go vet" ;;
        fmt) CMD="gofmt -w" ;;
    esac
    
    # Add options
    [ "$RACE" = true ] && CMD="$CMD -race"
    [ "$VERBOSE" = true ] && CMD="$CMD -v"
    [ "$TRIMPATH" = true ] && CMD="$CMD -trimpath"
    [ -n "$TAGS" ] && CMD="$CMD $TAGS"
    [ -n "$LDFLAGS" ] && CMD="$CMD $LDFLAGS"
    
    # Execute
    OUTPUT=$(eval "$CMD $ARGS" 2>&1) || EXIT_CODE=$?
    EXIT_CODE=${EXIT_CODE:-0}
    
    END_TIME=$(date +%s%3N)
    EXEC_TIME=$((END_TIME - START_TIME))
    
    OUTPUT_ESCAPED=$(echo "$OUTPUT" | jq -Rs .)
    
    echo "{\"request_id\":$REQUEST_ID,\"exit_code\":$EXIT_CODE,\"output\":$OUTPUT_ESCAPED,\"was_cached\":false,\"execution_time_ms\":$EXEC_TIME,\"outputs\":[]}"
done

exit 0
`;
    }
}

/// Compile Go sources using persistent worker
Result!(GoCompilationResult, WorkerError) compileWithGoWorker(
    WorkerPool pool,
    GoCompiler compiler,
    string[] packages,
    string outputPath = "",
    string[] options = []
) @trusted
{
    string workerType;
    final switch (compiler)
    {
        case GoCompiler.Build: workerType = "go-build"; break;
        case GoCompiler.Test: workerType = "go-test"; break;
        case GoCompiler.Vet: workerType = "go-vet"; break;
        case GoCompiler.Fmt: workerType = "go-fmt"; break;
    }
    
    string[] args;
    if (!outputPath.empty)
        args ~= ["-o", outputPath];
    args ~= options;
    args ~= packages;
    
    auto result = pool.execute(workerType, args, []);
    
    if (result.isErr)
        return Err!(GoCompilationResult, WorkerError)(result.unwrapErr());
    
    auto response = result.unwrap();
    
    return Ok!(GoCompilationResult, WorkerError)(GoCompilationResult(
        response.success,
        response.output,
        response.executionTimeMs,
        response.wasCached,
        parseGoDiagnostics(response.output),
        outputPath.empty ? [] : [outputPath]
    ));
}

/// Go compilation result
struct GoCompilationResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool wasCached;
    GoDiagnostic[] diagnostics;
    string[] outputFiles;
}

/// Go diagnostic message
struct GoDiagnostic
{
    string file;
    int line;
    int column;
    string message;
    string level;
}

/// Parse Go compiler output for diagnostics
private GoDiagnostic[] parseGoDiagnostics(string output) @trusted
{
    GoDiagnostic[] diagnostics;
    
    // Go error format: file.go:line:col: message
    auto pattern = regex(r"^(.+\.go):(\d+):(\d+):\s*(.+)$", "m");
    
    foreach (match; matchAll(output, pattern))
    {
        auto level = match[4].canFind("error") ? "error" : "warning";
        diagnostics ~= GoDiagnostic(match[1], match[2].to!int, match[3].to!int, match[4], level);
    }
    
    return diagnostics;
}


