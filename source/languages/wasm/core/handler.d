module languages.wasm.core.handler;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import languages.base.base;
import languages.base.mixins;
import languages.wasm.core.config;
import languages.wasm.tooling.tools;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types : Import, ImportKind, SourceLocation;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// WebAssembly/WASI build handler
/// Supports compilation from multiple source languages and WASI execution
class WebAssemblyHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"wasm";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_wasm_target_").field("detail", "Building WebAssembly target: " ~ target.name).emit();
        
        // Parse WASM configuration
        WasmConfig wasmConfig = parseWasmConfig(target);
        
        // Auto-detect source language from files
        if (wasmConfig.sourceLang == WasmSourceLang.Auto)
            wasmConfig.sourceLang = detectSourceLanguage(target.sources);
        
        // Auto-detect toolchain
        if (wasmConfig.toolchain == WasmToolchain.Auto)
        
            wasmConfig.toolchain = WasmTools.detectToolchain(wasmConfig.sourceLang);
        
        // Create output directory
        string outDir = wasmConfig.outputDir.empty ? config.options.outputDir : wasmConfig.outputDir;
        if (!exists(outDir))
            mkdirRecurse(outDir);
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, wasmConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, wasmConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, wasmConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, wasmConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        WasmConfig wasmConfig = parseWasmConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            string outDir = wasmConfig.outputDir.empty ? config.options.outputDir : wasmConfig.outputDir;
            
            // Primary WASM output
            outputs ~= buildPath(outDir, name ~ ".wasm");
            
            // JS glue if enabled
            if (wasmConfig.jsGlue)
                outputs ~= buildPath(outDir, name ~ ".js");
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                
                // Parse WAT imports
                if (source.endsWith(".wat") || source.endsWith(".wast"))
                {
                    auto imports = parseWatImports(content);
                    allImports ~= imports;
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_").field("detail", "Failed to analyze imports in " ~ source).emit();
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, WasmConfig wasmConfig) @system
    {
        LanguageBuildResult result;
        
        // Set default entry point for WASI
        if (wasmConfig.entryPoint.empty && wasmConfig.wasi.enabled)
            wasmConfig.entryPoint = "_start";
        
        return compileTarget(target, config, wasmConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, WasmConfig wasmConfig) @system
    {
        LanguageBuildResult result;
        
        // Libraries typically export all functions
        wasmConfig.exportAll = true;
        
        return compileTarget(target, config, wasmConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, WasmConfig wasmConfig) @system
    {
        LanguageBuildResult result;
        
        // Build first
        auto buildResult = compileTarget(target, config, wasmConfig);
        if (!buildResult.success)
            return buildResult;
        
        // Run with WASI
        if (!buildResult.outputs.empty)
        {
            auto runResult = runWasm(buildResult.outputs[0], wasmConfig);
            if (runResult.status != 0)
            {
                result.error = "Test execution failed: " ~ runResult.error;
                return result;
            }
            
            structuredLog.info("test_output_").field("detail", runResult.output).emit();
        }
        
        result.success = true;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        return result;
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, WasmConfig wasmConfig) @system
    {
        return compileTarget(target, config, wasmConfig);
    }
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config, WasmConfig wasmConfig) @system
    {
        LanguageBuildResult result;
        
        // Set output name
        if (wasmConfig.outputName.empty)
            wasmConfig.outputName = target.name.split(":")[$ - 1];
        
        // Compile based on toolchain
        WasmCompileResult compileResult;
        
        final switch (wasmConfig.toolchain)
        {
            case WasmToolchain.Auto:
                // Fallback to wat2wasm for .wat files, otherwise error
                if (target.sources.any!(s => s.endsWith(".wat") || s.endsWith(".wast")))
                    compileResult = WasmBuilder.buildWithWat2Wasm(target.sources.dup, wasmConfig);
                else
                {
                    result.error = "No suitable WASM toolchain detected. Install wasm-pack, emscripten, zig, or tinygo.";
                    return result;
                }
                break;
                
            case WasmToolchain.WasmPack:
                string projectDir = target.sources.empty ? "." : dirName(target.sources[0]);
                compileResult = WasmBuilder.buildWithWasmPack(target.sources.dup, wasmConfig, projectDir);
                break;
                
            case WasmToolchain.Emscripten:
                compileResult = WasmBuilder.buildWithEmscripten(target.sources.dup, wasmConfig);
                break;
                
            case WasmToolchain.Clang:
                // Use Emscripten path with STANDALONE_WASM
                wasmConfig.wasi.enabled = true;
                compileResult = WasmBuilder.buildWithEmscripten(target.sources.dup, wasmConfig);
                break;
                
            case WasmToolchain.TinyGo:
                compileResult = WasmBuilder.buildWithTinyGo(target.sources.dup, wasmConfig);
                break;
                
            case WasmToolchain.Zig:
                compileResult = WasmBuilder.buildWithZig(target.sources.dup, wasmConfig);
                break;
                
            case WasmToolchain.AssemblyScript:
                result.error = "AssemblyScript toolchain not yet implemented";
                return result;
                
            case WasmToolchain.Wat2Wasm:
                compileResult = WasmBuilder.buildWithWat2Wasm(target.sources.dup, wasmConfig);
                break;
        }
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Optimize if requested and not debug
        if (wasmConfig.optimize != WasmOptLevel.None && !compileResult.outputs.empty)
        {
            auto optResult = WasmBuilder.optimizeWasm(compileResult.outputs[0], wasmConfig);
            if (!optResult.success)
                structuredLog.warning("wasm_opt_failed_").field("detail", optResult.error).emit();
        }
        
        // Report warnings
        if (compileResult.hadWarnings)
        {
            foreach (warn; compileResult.warnings)
                structuredLog.warning("wasm_warning_").field("detail", warn).emit();
        }
        
        result.success = true;
        result.outputs = compileResult.outputs ~ compileResult.artifacts;
        
        // Calculate output hash
        if (!compileResult.outputs.empty && exists(compileResult.outputs[0]))
            result.outputHash = FastHash.hashFile(compileResult.outputs[0]);
        
        return result;
    }
    
    private RuntimeResult runWasm(string wasmPath, WasmConfig config) @system
    {
        // Auto-detect runtime if not specified
        WasmRuntime runtime = config.runtime;
        if (runtime == WasmRuntime.Auto)
            runtime = WasmTools.detectRuntime();
        
        final switch (runtime)
        {
            case WasmRuntime.Auto:
            case WasmRuntime.Native:
            case WasmRuntime.Wasmtime:
                return WasmRuntime_.runWasmtime(wasmPath, config.wasi);
                
            case WasmRuntime.Wasmer:
                return WasmRuntime_.runWasmer(wasmPath, config.wasi);
                
            case WasmRuntime.Wasm3:
                return WasmRuntime_.runWasm3(wasmPath, config.wasi);
                
            case WasmRuntime.Node:
                return WasmRuntime_.runNode(wasmPath, config.jsGluePath);
                
            case WasmRuntime.Browser:
                structuredLog.info("browser_target_use_serve_to_test").emit();
                return RuntimeResult(0, "Browser target - use serve to test", "");
        }
    }
    
    private WasmConfig parseWasmConfig(in Target target) @system
    {
        WasmConfig config;
        
        // Try language-specific keys
        string configKey;
        if ("wasm" in target.langConfig)
            configKey = "wasm";
        else if ("wasmConfig" in target.langConfig)
            configKey = "wasmConfig";
        else if ("webassembly" in target.langConfig)
            configKey = "webassembly";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = WasmConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_wasm_config_").field("detail", "Using defaults: " ~ e.msg).emit();
            }
        }
        
        // Apply target flags
        if (!target.flags.empty)
            config.compilerFlags ~= target.flags;
        
        return config;
    }
    
    private WasmSourceLang detectSourceLanguage(in string[] sources) @system
    {
        foreach (source; sources)
        {
            string ext = extension(source);
            switch (ext)
            {
                case ".rs": return WasmSourceLang.Rust;
                case ".c": return WasmSourceLang.C;
                case ".cpp", ".cc", ".cxx": return WasmSourceLang.Cpp;
                case ".go": return WasmSourceLang.Go;
                case ".zig": return WasmSourceLang.Zig;
                case ".ts": return WasmSourceLang.AssemblyScript;
                case ".wat", ".wast": return WasmSourceLang.Wat;
                case ".wasm": return WasmSourceLang.Wasm;
                default: continue;
            }
        }
        
        // Check for Cargo.toml (Rust project)
        if (sources.any!(s => baseName(s) == "Cargo.toml" || exists(buildPath(dirName(s), "Cargo.toml"))))
            return WasmSourceLang.Rust;
        
        return WasmSourceLang.Auto;
    }
    
    private Import[] parseWatImports(string content)
    {
        Import[] imports;
        
        import std.regex;
        
        // Match (import "module" "name" ...)
        auto importRegex = regex(`\(import\s+"([^"]+)"\s+"([^"]+)"`);
        
        foreach (match; matchAll(content, importRegex))
        {
            imports ~= Import(
                match[1] ~ "." ~ match[2],
                ImportKind.External,
                SourceLocation("", 0, 0)
            );
        }
        
        return imports;
    }
}


