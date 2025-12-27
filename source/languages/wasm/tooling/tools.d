module languages.wasm.tooling.tools;

import std.process;
import std.string;
import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.conv;
import languages.wasm.core.config;
import infrastructure.utils.logging;

/// Tool availability result
struct ToolCheck
{
    bool available;
    string version_;
    string path;
}

/// Runtime execution result
struct RuntimeResult
{
    int status;
    string output;
    string error;
}

/// WebAssembly toolchain detection and execution
struct WasmTools
{
    /// Check if wasmtime is available
    static ToolCheck checkWasmtime()
    {
        return checkTool("wasmtime", ["--version"]);
    }
    
    /// Check if wasmer is available
    static ToolCheck checkWasmer()
    {
        return checkTool("wasmer", ["--version"]);
    }
    
    /// Check if wasm3 is available
    static ToolCheck checkWasm3()
    {
        return checkTool("wasm3", ["--version"]);
    }
    
    /// Check if wasm-pack is available
    static ToolCheck checkWasmPack()
    {
        return checkTool("wasm-pack", ["--version"]);
    }
    
    /// Check if emcc (Emscripten) is available
    static ToolCheck checkEmscripten()
    {
        return checkTool("emcc", ["--version"]);
    }
    
    /// Check if clang with WASM target is available
    static ToolCheck checkClangWasm()
    {
        auto clang = checkTool("clang", ["--version"]);
        if (!clang.available) return clang;
        
        // Verify WASM target support
        auto res = execute(["clang", "--print-targets"]);
        if (res.status == 0 && res.output.canFind("wasm"))
        {
            return clang;
        }
        return ToolCheck(false, "", "");
    }
    
    /// Check if TinyGo is available
    static ToolCheck checkTinyGo()
    {
        return checkTool("tinygo", ["version"]);
    }
    
    /// Check if Zig is available
    static ToolCheck checkZig()
    {
        return checkTool("zig", ["version"]);
    }
    
    /// Check if AssemblyScript compiler is available
    static ToolCheck checkAssemblyScript()
    {
        return checkTool("asc", ["--version"]);
    }
    
    /// Check if wabt (wat2wasm) is available
    static ToolCheck checkWabt()
    {
        return checkTool("wat2wasm", ["--version"]);
    }
    
    /// Check if wasm-opt (binaryen) is available
    static ToolCheck checkWasmOpt()
    {
        return checkTool("wasm-opt", ["--version"]);
    }
    
    /// Auto-detect best available runtime
    static WasmRuntime detectRuntime()
    {
        if (checkWasmtime().available) return WasmRuntime.Wasmtime;
        if (checkWasmer().available) return WasmRuntime.Wasmer;
        if (checkWasm3().available) return WasmRuntime.Wasm3;
        
        // Check for Node.js
        auto node = checkTool("node", ["--version"]);
        if (node.available) return WasmRuntime.Node;
        
        return WasmRuntime.Auto;
    }
    
    /// Auto-detect best toolchain for source language
    static WasmToolchain detectToolchain(WasmSourceLang source)
    {
        final switch (source)
        {
            case WasmSourceLang.Auto:
                // Check available toolchains in priority order
                if (checkWasmPack().available) return WasmToolchain.WasmPack;
                if (checkEmscripten().available) return WasmToolchain.Emscripten;
                if (checkClangWasm().available) return WasmToolchain.Clang;
                if (checkZig().available) return WasmToolchain.Zig;
                return WasmToolchain.Auto;
                
            case WasmSourceLang.Rust:
                if (checkWasmPack().available) return WasmToolchain.WasmPack;
                return WasmToolchain.Auto;
                
            case WasmSourceLang.C:
            case WasmSourceLang.Cpp:
                if (checkEmscripten().available) return WasmToolchain.Emscripten;
                if (checkClangWasm().available) return WasmToolchain.Clang;
                return WasmToolchain.Auto;
                
            case WasmSourceLang.Go:
                if (checkTinyGo().available) return WasmToolchain.TinyGo;
                return WasmToolchain.Auto;
                
            case WasmSourceLang.Zig:
                if (checkZig().available) return WasmToolchain.Zig;
                return WasmToolchain.Auto;
                
            case WasmSourceLang.AssemblyScript:
                if (checkAssemblyScript().available) return WasmToolchain.AssemblyScript;
                return WasmToolchain.Auto;
                
            case WasmSourceLang.Wat:
            case WasmSourceLang.Wasm:
                if (checkWabt().available) return WasmToolchain.Wat2Wasm;
                return WasmToolchain.Auto;
        }
    }
    
    /// Generic tool check
    private static ToolCheck checkTool(string name, string[] versionArgs)
    {
        try
        {
            auto res = execute([name] ~ versionArgs);
            if (res.status == 0)
            {
                // Extract version from first line
                string version_ = res.output.lineSplitter.front.strip;
                
                // Try to find the tool path
                string path;
                auto which = execute(["which", name]);
                if (which.status == 0)
                    path = which.output.strip;
                
                return ToolCheck(true, version_, path);
            }
        }
        catch (Exception e) {}
        
        return ToolCheck(false, "", "");
    }
}

/// WASM runtime executor
class WasmRuntime_
{
    /// Run WASM module with wasmtime
    static RuntimeResult runWasmtime(string wasmPath, WasiConfig wasi, string[] args = [])
    {
        string[] cmd = ["wasmtime"];
        
        // Add WASI directory mappings
        foreach (mapping; wasi.dirMappings)
        {
            if (mapping.readonly)
                cmd ~= ["--dir", mapping.guest ~ "::" ~ mapping.host ~ "::readonly"];
            else
                cmd ~= ["--dir", mapping.guest ~ "::" ~ mapping.host];
        }
        
        // Add environment variables
        foreach (key, value; wasi.envVars)
            cmd ~= ["--env", key ~ "=" ~ value];
        
        cmd ~= wasmPath;
        cmd ~= wasi.args;
        cmd ~= args;
        
        return executeRuntime(cmd);
    }
    
    /// Run WASM module with wasmer
    static RuntimeResult runWasmer(string wasmPath, WasiConfig wasi, string[] args = [])
    {
        string[] cmd = ["wasmer", "run"];
        
        // Add WASI directory mappings
        foreach (mapping; wasi.dirMappings)
            cmd ~= ["--dir", mapping.host];
        
        // Add environment variables
        foreach (key, value; wasi.envVars)
            cmd ~= ["--env", key ~ "=" ~ value];
        
        cmd ~= wasmPath;
        
        if (!wasi.args.empty || !args.empty)
        {
            cmd ~= "--";
            cmd ~= wasi.args;
            cmd ~= args;
        }
        
        return executeRuntime(cmd);
    }
    
    /// Run WASM module with wasm3
    static RuntimeResult runWasm3(string wasmPath, WasiConfig wasi, string[] args = [])
    {
        string[] cmd = ["wasm3"];
        cmd ~= wasmPath;
        cmd ~= wasi.args;
        cmd ~= args;
        
        return executeRuntime(cmd);
    }
    
    /// Run WASM in Node.js
    static RuntimeResult runNode(string wasmPath, string jsGluePath, string[] args = [])
    {
        // Use JS glue if available, otherwise run directly
        string[] cmd = ["node"];
        
        if (!jsGluePath.empty && exists(jsGluePath))
            cmd ~= jsGluePath;
        else
            cmd ~= ["-e", generateNodeRunner(wasmPath)];
        
        cmd ~= args;
        
        return executeRuntime(cmd);
    }
    
    /// Generate inline Node.js WASM runner
    private static string generateNodeRunner(string wasmPath)
    {
        return `
            const fs = require('fs');
            const path = require('path');
            const wasmBuffer = fs.readFileSync('` ~ wasmPath ~ `');
            WebAssembly.instantiate(wasmBuffer).then(result => {
                if (result.instance.exports._start) {
                    result.instance.exports._start();
                } else if (result.instance.exports.main) {
                    result.instance.exports.main();
                }
            });
        `;
    }
    
    /// Execute runtime command
    private static RuntimeResult executeRuntime(string[] cmd)
    {
        RuntimeResult result;
        
        try
        {
            auto res = execute(cmd);
            result.status = res.status;
            result.output = res.output;
        }
        catch (Exception e)
        {
            result.status = -1;
            result.error = e.msg;
        }
        
        return result;
    }
}

/// WASM toolchain builders
class WasmBuilder
{
    /// Build with wasm-pack (Rust)
    static WasmCompileResult buildWithWasmPack(
        string[] sources,
        WasmConfig config,
        string projectDir
    )
    {
        WasmCompileResult result;
        
        string[] cmd = ["wasm-pack", "build"];
        
        // Target
        if (config.wasi.enabled)
            cmd ~= ["--target", "nodejs"];
        else if (config.jsGlue)
            cmd ~= ["--target", "web"];
        else
            cmd ~= ["--target", "bundler"];
        
        // Output directory
        cmd ~= ["--out-dir", config.outputDir];
        
        // Optimization
        final switch (config.optimize)
        {
            case WasmOptLevel.None: cmd ~= "--dev"; break;
            case WasmOptLevel.O1:
            case WasmOptLevel.O2:
            case WasmOptLevel.O3: break;  // release is default
            case WasmOptLevel.Os:
            case WasmOptLevel.Oz: cmd ~= "--release"; break;
        }
        
        // Working directory
        auto res = execute(cmd, null, Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        result.success = true;
        
        // Find outputs
        string outDir = buildPath(projectDir, config.outputDir);
        if (exists(outDir))
        {
            foreach (entry; dirEntries(outDir, SpanMode.shallow))
            {
                if (entry.name.endsWith(".wasm"))
                    result.outputs ~= entry.name;
                else
                    result.artifacts ~= entry.name;
            }
        }
        
        return result;
    }
    
    /// Build with Emscripten
    static WasmCompileResult buildWithEmscripten(
        string[] sources,
        WasmConfig config
    )
    {
        WasmCompileResult result;
        
        string[] cmd = ["emcc"];
        cmd ~= sources;
        
        // Output
        string outName = config.outputName.empty ? "output" : config.outputName;
        string outPath = buildPath(config.outputDir, outName ~ ".wasm");
        cmd ~= ["-o", outPath];
        
        // Optimization
        final switch (config.optimize)
        {
            case WasmOptLevel.None: cmd ~= "-O0"; break;
            case WasmOptLevel.O1: cmd ~= "-O1"; break;
            case WasmOptLevel.O2: cmd ~= "-O2"; break;
            case WasmOptLevel.O3: cmd ~= "-O3"; break;
            case WasmOptLevel.Os: cmd ~= "-Os"; break;
            case WasmOptLevel.Oz: cmd ~= "-Oz"; break;
        }
        
        // WASM-specific flags
        cmd ~= "-s WASM=1";
        
        if (config.wasi.enabled)
            cmd ~= "-s STANDALONE_WASM=1";
        
        if (config.esModule)
            cmd ~= "-s EXPORT_ES6=1";
        
        if (config.exportAll)
            cmd ~= "-s EXPORTED_FUNCTIONS='[\"_main\"]'";
        
        // Memory
        cmd ~= "-s INITIAL_MEMORY=" ~ (config.memory.initialPages * 65536).to!string;
        if (config.memory.maxPages > 0)
            cmd ~= "-s MAXIMUM_MEMORY=" ~ (config.memory.maxPages * 65536).to!string;
        
        // Features
        if (config.features.simd)
            cmd ~= "-msimd128";
        if (config.features.threads)
        {
            cmd ~= "-pthread";
            cmd ~= "-s SHARED_MEMORY=1";
        }
        
        // Additional flags
        cmd ~= config.compilerFlags;
        cmd ~= config.linkerFlags;
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        result.success = true;
        result.outputs ~= outPath;
        
        // Check for generated JS glue
        string jsPath = outPath.replace(".wasm", ".js");
        if (exists(jsPath))
            result.artifacts ~= jsPath;
        
        return result;
    }
    
    /// Build with Zig
    static WasmCompileResult buildWithZig(
        string[] sources,
        WasmConfig config
    )
    {
        WasmCompileResult result;
        
        string[] cmd = ["zig", "build-exe"];
        
        // Target
        if (config.wasi.enabled)
            cmd ~= ["-target", "wasm32-wasi"];
        else
            cmd ~= ["-target", "wasm32-freestanding"];
        
        // Sources
        cmd ~= sources;
        
        // Output
        string outName = config.outputName.empty ? "output" : config.outputName;
        string outPath = buildPath(config.outputDir, outName ~ ".wasm");
        cmd ~= ["-femit-bin=" ~ outPath];
        
        // Optimization
        final switch (config.optimize)
        {
            case WasmOptLevel.None: cmd ~= "-ODebug"; break;
            case WasmOptLevel.O1:
            case WasmOptLevel.O2: cmd ~= "-OReleaseSafe"; break;
            case WasmOptLevel.O3: cmd ~= "-OReleaseFast"; break;
            case WasmOptLevel.Os:
            case WasmOptLevel.Oz: cmd ~= "-OReleaseSmall"; break;
        }
        
        // Strip
        if (config.strip)
            cmd ~= "--strip";
        
        // Features
        if (config.features.simd)
            cmd ~= "-mcpu=generic+simd128";
        
        // Export all
        if (config.exportAll)
            cmd ~= "--export-dynamic";
        
        cmd ~= config.compilerFlags;
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        result.success = true;
        result.outputs ~= outPath;
        
        return result;
    }
    
    /// Build with TinyGo
    static WasmCompileResult buildWithTinyGo(
        string[] sources,
        WasmConfig config
    )
    {
        WasmCompileResult result;
        
        string[] cmd = ["tinygo", "build"];
        
        // Target
        if (config.wasi.enabled)
            cmd ~= ["-target", "wasi"];
        else
            cmd ~= ["-target", "wasm"];
        
        // Output
        string outName = config.outputName.empty ? "output" : config.outputName;
        string outPath = buildPath(config.outputDir, outName ~ ".wasm");
        cmd ~= ["-o", outPath];
        
        // Optimization
        final switch (config.optimize)
        {
            case WasmOptLevel.None: cmd ~= "-opt=0"; break;
            case WasmOptLevel.O1: cmd ~= "-opt=1"; break;
            case WasmOptLevel.O2: cmd ~= "-opt=2"; break;
            case WasmOptLevel.O3:
            case WasmOptLevel.Os:
            case WasmOptLevel.Oz: cmd ~= "-opt=z"; break;
        }
        
        // Source (TinyGo takes package path or single file)
        if (!sources.empty)
            cmd ~= sources[0];
        
        cmd ~= config.compilerFlags;
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        result.success = true;
        result.outputs ~= outPath;
        
        return result;
    }
    
    /// Build WAT to WASM
    static WasmCompileResult buildWithWat2Wasm(
        string[] sources,
        WasmConfig config
    )
    {
        WasmCompileResult result;
        
        foreach (source; sources)
        {
            if (!source.endsWith(".wat") && !source.endsWith(".wast"))
                continue;
            
            string[] cmd = ["wat2wasm"];
            cmd ~= source;
            
            string outName = config.outputName.empty ? 
                            baseName(source).replace(".wat", "").replace(".wast", "") : 
                            config.outputName;
            string outPath = buildPath(config.outputDir, outName ~ ".wasm");
            cmd ~= ["-o", outPath];
            
            // Validation
            cmd ~= "--enable-all";  // Enable all proposals
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.error = res.output;
                return result;
            }
            
            result.outputs ~= outPath;
        }
        
        result.success = true;
        return result;
    }
    
    /// Optimize WASM with wasm-opt (binaryen)
    static WasmCompileResult optimizeWasm(string wasmPath, WasmConfig config)
    {
        WasmCompileResult result;
        
        if (!WasmTools.checkWasmOpt().available)
        {
            result.success = true;  // Skip optimization if not available
            result.outputs ~= wasmPath;
            return result;
        }
        
        string[] cmd = ["wasm-opt"];
        
        // Optimization level
        final switch (config.optimize)
        {
            case WasmOptLevel.None: break;
            case WasmOptLevel.O1: cmd ~= "-O1"; break;
            case WasmOptLevel.O2: cmd ~= "-O2"; break;
            case WasmOptLevel.O3: cmd ~= "-O3"; break;
            case WasmOptLevel.Os: cmd ~= "-Os"; break;
            case WasmOptLevel.Oz: cmd ~= "-Oz"; break;
        }
        
        cmd ~= wasmPath;
        cmd ~= ["-o", wasmPath];
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = res.output;
            return result;
        }
        
        result.success = true;
        result.outputs ~= wasmPath;
        
        return result;
    }
}


