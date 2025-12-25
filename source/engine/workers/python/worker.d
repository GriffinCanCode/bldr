module engine.workers.python.worker;

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

/// Python Persistent Worker Factory
/// 
/// Creates persistent workers for Python tooling.
/// Python itself doesn't compile, but these tools benefit from warmth:
/// - mypy: Type checker with significant startup cost
/// - ruff: Ultra-fast linter (Rust-based)
/// - pylint: Traditional linter
/// - black: Code formatter
/// 
/// Startup costs avoided:
/// - Python interpreter initialization (~100-200ms)
/// - Type stub loading (mypy: ~500ms-2s)
/// - Configuration parsing
/// - Import resolution
/// 
/// Speedup: 3-20x depending on tool

/// Python tool type
enum PythonTool
{
    Mypy,      /// mypy - type checker (biggest benefit from persistence)
    Ruff,      /// ruff - ultra-fast linter/formatter
    Pylint,    /// pylint - traditional linter
    Black,     /// black - code formatter
    Pytest     /// pytest - test runner
}

/// Python worker configuration
struct PythonWorkerConfig
{
    PythonTool tool = PythonTool.Mypy;
    string pythonPath;              /// Path to python interpreter
    string virtualEnv;              /// Virtual environment path
    string configPath;              /// Config file path (pyproject.toml, etc.)
    string[] toolArgs;              /// Default tool arguments
    Duration startupTimeout = seconds(30);
    Duration requestTimeout = minutes(5);
    bool daemon = true;             /// Use daemon mode if available (mypy)
    bool incremental = true;        /// Incremental analysis
    string cacheDir;                /// Cache directory
}

/// Python Persistent Worker Factory - extends base with Python-specific logic
final class PythonWorkerFactory : BasePersistentWorkerFactory
{
    private PythonWorkerConfig config;
    private string workerScriptPath;
    
    this(PythonWorkerConfig config = PythonWorkerConfig.init) @trusted
    {
        BaseWorkerConfig baseCfg;
        baseCfg.startupTimeout = config.startupTimeout;
        baseCfg.requestTimeout = config.requestTimeout;
        baseCfg.idleTimeout = minutes(10);  // Type checker state valuable
        baseCfg.maxRequests = 5000;
        baseCfg.coldStartMs = coldStartFor(config.tool);
        
        super(baseCfg);
        this.config = config;
        this.workerScriptPath = findOrCreateWorkerScript();
    }
    
    override string workerType() const pure nothrow @safe
    {
        final switch (config.tool)
        {
            case PythonTool.Mypy: return "python-mypy";
            case PythonTool.Ruff: return "python-ruff";
            case PythonTool.Pylint: return "python-pylint";
            case PythonTool.Black: return "python-black";
            case PythonTool.Pytest: return "python-pytest";
        }
    }
    
    override PersistentWorkerConfig defaultConfig() const @safe
    {
        auto cfg = super.defaultConfig();
        cfg.executable = getPythonPath();
        cfg.baseArgs = buildWorkerArgs();
        cfg.idleTimeout = minutes(10);
        cfg.maxRequests = 5000;
        return cfg;
    }
    
    protected override string[] buildWorkerArgs() const @trusted
    {
        string[] args = [workerScriptPath];
        
        // Tool selection
        final switch (config.tool)
        {
            case PythonTool.Mypy: args ~= "--tool=mypy"; break;
            case PythonTool.Ruff: args ~= "--tool=ruff"; break;
            case PythonTool.Pylint: args ~= "--tool=pylint"; break;
            case PythonTool.Black: args ~= "--tool=black"; break;
            case PythonTool.Pytest: args ~= "--tool=pytest"; break;
        }
        
        args ~= "--persistent";
        
        if (!config.configPath.empty)
            args ~= ["--config", config.configPath];
        
        if (config.daemon && config.tool == PythonTool.Mypy)
            args ~= "--daemon";
        
        if (config.incremental)
            args ~= "--incremental";
        
        if (!config.cacheDir.empty)
            args ~= ["--cache-dir", config.cacheDir];
        
        args ~= config.toolArgs;
        
        return args;
    }
    
    protected override string getExecutable() const @trusted
    {
        return getPythonPath();
    }
    
    protected override string[string] buildEnvironment() const @trusted
    {
        auto env = super.buildEnvironment();
        
        // Virtual environment
        if (!config.virtualEnv.empty)
        {
            env["VIRTUAL_ENV"] = config.virtualEnv;
            env["PATH"] = buildPath(config.virtualEnv, "bin") ~ ":" ~ environment.get("PATH", "");
        }
        
        // Cache directories
        auto cacheBase = config.cacheDir.empty 
            ? buildPath(tempDir(), "bldr-python-cache")
            : config.cacheDir;
        
        env["MYPY_CACHE_DIR"] = buildPath(cacheBase, "mypy");
        env["RUFF_CACHE_DIR"] = buildPath(cacheBase, "ruff");
        env["PYTEST_CACHE_DIR"] = buildPath(cacheBase, "pytest");
        
        // Disable bytecode for cleaner builds
        env["PYTHONDONTWRITEBYTECODE"] = "1";
        
        return env;
    }
    
    protected override string[] getHealthCheckArgs() const @safe
    {
        return ["--version"];
    }
    
    private static long coldStartFor(PythonTool tool) pure nothrow @safe @nogc
    {
        final switch (tool)
        {
            case PythonTool.Mypy: return 1500;    // Heaviest - type stub loading
            case PythonTool.Ruff: return 50;      // Rust-based, fast
            case PythonTool.Pylint: return 800;
            case PythonTool.Black: return 200;
            case PythonTool.Pytest: return 400;
        }
    }
    
    private string getPythonPath() const @trusted
    {
        if (!config.pythonPath.empty && exists(config.pythonPath))
            return config.pythonPath;
        
        // Check virtual environment first
        if (!config.virtualEnv.empty)
        {
            auto venvPython = buildPath(config.virtualEnv, "bin", "python3");
            if (exists(venvPython)) return venvPython;
        }
        
        foreach (p; ["python3", "/usr/bin/python3", "/usr/local/bin/python3"])
        {
            try
            {
                auto result = execute(["which", p]);
                if (result.status == 0) return result.output.strip();
            }
            catch (Exception) { continue; }
        }
        
        return "python3";
    }
    
    private string findOrCreateWorkerScript() @trusted
    {
        auto possiblePaths = [
            buildPath(thisExePath().dirName, "python-worker.py"),
            buildPath(thisExePath().dirName, "..", "lib", "python-worker.py"),
            "/usr/local/lib/bldr/python-worker.py"
        ];
        
        foreach (path; possiblePaths)
            if (exists(path))
                return path;
        
        return createInlineWorkerScript();
    }
    
    private string createInlineWorkerScript() @trusted
    {
        auto scriptPath = buildPath(tempDir(), "bldr-python-worker.py");
        
        if (!exists(scriptPath))
        {
            std.file.write(scriptPath, generateWorkerScript());
            execute(["chmod", "+x", scriptPath]);
            Logger.debugLog("Created Python worker script: " ~ scriptPath);
        }
        
        return scriptPath;
    }
    
    private string generateWorkerScript() const pure @safe
    {
        return `#!/usr/bin/env python3
"""
Python Persistent Worker - Bazel-compatible protocol
Keeps Python tools warm for 3-20x speedup.
"""
import sys
import json
import subprocess
import time
import os
from typing import Dict, Any, List, Optional

# Parse arguments
tool = "mypy"
daemon = False
incremental = False
config_path = None
cache_dir = None

args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--tool":
        tool = args[i + 1]
        i += 2
    elif args[i].startswith("--tool="):
        tool = args[i].split("=")[1]
        i += 1
    elif args[i] == "--persistent":
        i += 1
    elif args[i] == "--config":
        config_path = args[i + 1]
        i += 2
    elif args[i] == "--daemon":
        daemon = True
        i += 1
    elif args[i] == "--incremental":
        incremental = True
        i += 1
    elif args[i] == "--cache-dir":
        cache_dir = args[i + 1]
        i += 2
    elif args[i] == "--version":
        if tool == "mypy":
            subprocess.run(["python3", "-m", "mypy", "--version"])
        elif tool == "ruff":
            subprocess.run(["ruff", "--version"])
        elif tool == "black":
            subprocess.run(["black", "--version"])
        elif tool == "pylint":
            subprocess.run(["pylint", "--version"])
        elif tool == "pytest":
            subprocess.run(["pytest", "--version"])
        sys.exit(0)
    else:
        i += 1

# Initialize mypy daemon if requested
mypy_dmypy = None
if tool == "mypy" and daemon:
    try:
        subprocess.run(["dmypy", "start"], capture_output=True, timeout=30)
        mypy_dmypy = True
        sys.stderr.write("mypy daemon started\\n")
    except Exception as e:
        sys.stderr.write(f"Failed to start mypy daemon: {e}\\n")
        mypy_dmypy = False

def execute_tool(request: Dict[str, Any]) -> Dict[str, Any]:
    start_time = time.time()
    request_id = request.get("request_id", 0)
    arguments = request.get("arguments", [])
    sandbox_dir = request.get("sandbox_dir")
    
    if request.get("cancel"):
        return {
            "request_id": request_id,
            "exit_code": 0,
            "output": "Cancelled",
            "was_cached": False,
            "execution_time_ms": 0,
            "outputs": []
        }
    
    # Build command based on tool
    cmd: List[str] = []
    
    if tool == "mypy":
        if mypy_dmypy:
            cmd = ["dmypy", "check", "--"] + arguments
        else:
            cmd = ["python3", "-m", "mypy"]
            if incremental:
                cmd.append("--incremental")
            if config_path:
                cmd.extend(["--config-file", config_path])
            cmd.extend(arguments)
            
    elif tool == "ruff":
        cmd = ["ruff", "check"] + arguments
        
    elif tool == "pylint":
        cmd = ["pylint"] + arguments
        if config_path:
            cmd.extend(["--rcfile", config_path])
            
    elif tool == "black":
        cmd = ["black", "--check"] + arguments
        
    elif tool == "pytest":
        cmd = ["pytest"] + arguments
        if cache_dir:
            cmd.extend(["--cache-dir", cache_dir])
    
    # Execute
    try:
        cwd = sandbox_dir if sandbox_dir else None
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=300
        )
        output = result.stdout + result.stderr
        exit_code = result.returncode
    except subprocess.TimeoutExpired:
        output = "Command timed out"
        exit_code = 124
    except Exception as e:
        output = f"Execution failed: {e}"
        exit_code = 1
    
    exec_time_ms = int((time.time() - start_time) * 1000)
    
    return {
        "request_id": request_id,
        "exit_code": exit_code,
        "output": output,
        "was_cached": False,
        "execution_time_ms": exec_time_ms,
        "outputs": []
    }

# Main protocol loop
sys.stderr.write(f"Python {tool} persistent worker ready\\n")

for line in sys.stdin:
    try:
        request = json.loads(line.strip())
        response = execute_tool(request)
        print(json.dumps(response), flush=True)
    except json.JSONDecodeError as e:
        print(json.dumps({
            "request_id": 0,
            "exit_code": 1,
            "output": f"Protocol error: {e}",
            "was_cached": False,
            "execution_time_ms": 0,
            "outputs": []
        }), flush=True)
    except Exception as e:
        print(json.dumps({
            "request_id": 0,
            "exit_code": 1,
            "output": f"Internal error: {e}",
            "was_cached": False,
            "execution_time_ms": 0,
            "outputs": []
        }), flush=True)

# Cleanup
if mypy_dmypy:
    try:
        subprocess.run(["dmypy", "stop"], capture_output=True, timeout=5)
    except:
        pass
`;
    }
}

/// Run Python tool using persistent worker
Result!(PythonToolResult, WorkerError) runPythonTool(
    WorkerPool pool,
    PythonTool tool,
    string[] paths,
    string[] options = []
) @trusted
{
    string workerType;
    final switch (tool)
    {
        case PythonTool.Mypy: workerType = "python-mypy"; break;
        case PythonTool.Ruff: workerType = "python-ruff"; break;
        case PythonTool.Pylint: workerType = "python-pylint"; break;
        case PythonTool.Black: workerType = "python-black"; break;
        case PythonTool.Pytest: workerType = "python-pytest"; break;
    }
    
    string[] args = options ~ paths;
    
    auto inputs = paths
        .filter!(p => exists(p))
        .map!(p => InputFile(p, ""))
        .array;
    
    auto result = pool.execute(workerType, args, inputs);
    
    if (result.isErr)
        return Err!(PythonToolResult, WorkerError)(result.unwrapErr());
    
    auto response = result.unwrap();
    
    return Ok!(PythonToolResult, WorkerError)(PythonToolResult(
        response.success,
        response.output,
        response.executionTimeMs,
        response.wasCached,
        parsePythonDiagnostics(tool, response.output)
    ));
}

/// Python tool result
struct PythonToolResult
{
    bool success;
    string output;
    long executionTimeMs;
    bool wasCached;
    PythonDiagnostic[] diagnostics;
}

/// Python diagnostic message
struct PythonDiagnostic
{
    string file;
    int line;
    int column;
    string message;
    string code;    // Error code (e.g., "E501", "error: ...")
    string level;
}

/// Parse Python tool output for diagnostics
private PythonDiagnostic[] parsePythonDiagnostics(PythonTool tool, string output) @trusted
{
    PythonDiagnostic[] diagnostics;
    
    // Different tools have different output formats
    final switch (tool)
    {
        case PythonTool.Mypy:
            // mypy format: file.py:line: error: message
            auto pattern = regex(r"^(.+\.py):(\d+):\s*(error|warning|note):\s*(.+)$", "m");
            foreach (m; matchAll(output, pattern))
                diagnostics ~= PythonDiagnostic(m[1], m[2].to!int, 0, m[4], "", m[3]);
            break;
            
        case PythonTool.Ruff:
            // ruff format: file.py:line:col: E501 message
            auto pattern = regex(r"^(.+\.py):(\d+):(\d+):\s*(\w+)\s+(.+)$", "m");
            foreach (m; matchAll(output, pattern))
            {
                auto level = m[4].startsWith("E") ? "error" : "warning";
                diagnostics ~= PythonDiagnostic(m[1], m[2].to!int, m[3].to!int, m[5], m[4], level);
            }
            break;
            
        case PythonTool.Pylint:
            // pylint format: file.py:line:col: CODE: message (category)
            auto pattern = regex(r"^(.+\.py):(\d+):(\d+):\s*(\w\d+):\s*(.+)$", "m");
            foreach (m; matchAll(output, pattern))
            {
                auto level = m[4].startsWith("E") ? "error" : "warning";
                diagnostics ~= PythonDiagnostic(m[1], m[2].to!int, m[3].to!int, m[5], m[4], level);
            }
            break;
            
        case PythonTool.Black:
            // black just reports reformatted files
            break;
            
        case PythonTool.Pytest:
            // pytest output is complex, just capture failures
            auto pattern = regex(r"^FAILED\s+(.+)::(.+)\s+-\s+(.+)$", "m");
            foreach (m; matchAll(output, pattern))
                diagnostics ~= PythonDiagnostic(m[1], 0, 0, m[3], "", "error");
            break;
    }
    
    return diagnostics;
}


