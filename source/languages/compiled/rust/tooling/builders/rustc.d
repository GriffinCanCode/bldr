module languages.compiled.rust.tooling.builders.rustc;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.rust.tooling.builders.base;
import languages.compiled.rust.core.config;
import languages.compiled.rust.managers.toolchain;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// Direct rustc builder - compiles without cargo with action-level caching
class RustcBuilder : RustBuilder
{
    private ActionCache actionCache;
    
    this(ActionCache cache = null)
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/rust", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
    }
    RustCompileResult build(
        in string[] sources,
        in RustConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        RustCompileResult result;
        
        if (sources.empty)
        {
            result.error = "No source files provided";
            return result;
        }
        
        structuredLog.debug_("building_rust_with_rustc_").field("detail", "Building Rust with rustc: " ~ sources.join(", ")).emit();
        
        // Build command based on mode
        final switch (config.mode)
        {
            case RustBuildMode.Compile:
                return compileTarget(sources, config, target, workspace);
            case RustBuildMode.Check:
                return checkTarget(sources, config, target, workspace);
            case RustBuildMode.Test:
                return testTarget(sources, config, target, workspace);
            case RustBuildMode.Doc:
                result.error = "Documentation generation requires cargo";
                return result;
            case RustBuildMode.Bench:
                result.error = "Benchmarks require cargo";
                return result;
            case RustBuildMode.Example:
                result.error = "Examples require cargo";
                return result;
            case RustBuildMode.Custom:
                return compileCustom(sources, config, target, workspace);
        }
    }
    
    bool isAvailable()
    {
        return Rustc.isAvailable();
    }
    
    string name() const
    {
        return "rustc";
    }
    
    string getVersion()
    {
        return Rustc.getVersion();
    }
    
    bool supportsFeature(string feature)
    {
        return feature == "compile" || feature == "check";
    }
    
    private RustCompileResult compileTarget(
        in string[] sources,
        in RustConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        RustCompileResult result;
        
        // Determine output path
        string outputPath;
        if (!target.outputPath.empty)
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name);
        }
        
        // Create output directory
        string outputDir = dirName(outputPath);
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // For multi-file projects, compile incrementally with caching
        if (sources.length > 1)
        {
            // Create .rlib directory for intermediate objects
            string rlibDir = buildPath(outputDir, ".rlib");
            if (!exists(rlibDir))
                mkdirRecurse(rlibDir);
            
            // Compile each module separately
            string[] compiledModules;
            foreach (source; sources)
            {
                auto moduleResult = compileModule(source, config, target, workspace, rlibDir);
                if (!moduleResult.success)
                {
                    result.error = moduleResult.error;
                    result.hadWarnings = result.hadWarnings || moduleResult.hadWarnings;
                    result.warnings ~= moduleResult.warnings;
                    return result;
                }
                
                compiledModules ~= moduleResult.outputs;
                result.warnings ~= moduleResult.warnings;
                result.hadWarnings = result.hadWarnings || moduleResult.hadWarnings;
            }
            
            // Link all modules
            auto linkResult = linkModules(compiledModules, outputPath, config, target);
            if (!linkResult.success)
            {
                result.error = linkResult.error;
                return result;
            }
            
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            
            return result;
        }
        
        // Single file compilation - direct compilation with caching
        string entryPoint = config.entry.empty ? sources[0] : config.entry;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["crateType"] = crateTypeToString(config.crateType);
        metadata["edition"] = editionToString(config.edition);
        metadata["release"] = config.release.to!string;
        metadata["optLevel"] = config.release ? optLevelToString(config.optLevel) : "0";
        metadata["debugInfo"] = config.debugInfo.to!string;
        metadata["lto"] = ltoModeToString(config.lto);
        metadata["target"] = config.target;
        metadata["rustcFlags"] = config.rustcFlags.join(" ");
        
        // Create action ID for compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = baseName(entryPoint);
        actionId.inputHash = FastHash.hashFile(entryPoint);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, [entryPoint], metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_rustc_compilation_").field("detail", "  [Cached] Rustc compilation: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Build rustc command
        string[] cmd = ["rustc"];
        
        // Entry point
        cmd ~= [entryPoint];
        
        // Output
        cmd ~= ["-o", outputPath];
        
        // Crate type
        cmd ~= ["--crate-type", crateTypeToString(config.crateType)];
        
        // Edition
        cmd ~= ["--edition", editionToString(config.edition)];
        
        // Optimization level
        if (config.release)
            cmd ~= ["-C", "opt-level=" ~ optLevelToString(config.optLevel)];
        else
            cmd ~= ["-C", "opt-level=0"];
        
        // Debug info
        if (config.debugInfo)
            cmd ~= ["-C", "debuginfo=2"];
        
        // LTO
        if (config.lto != LtoMode.Off)
            cmd ~= ["-C", "lto=" ~ ltoModeToString(config.lto)];
        
        // Codegen units
        if (config.codegen == Codegen.Single)
            cmd ~= ["-C", "codegen-units=1"];
        else if (config.codegen == Codegen.Custom)
            cmd ~= ["-C", "codegen-units=" ~ config.codegenUnits.to!string];
        
        // Target triple
        if (!config.target.empty)
            cmd ~= ["--target", config.target];
        
        // Add rustc flags
        cmd ~= config.rustcFlags;
        
        structuredLog.debug_("rustc_command_").field("detail", "Rustc command: " ~ cmd.join(" ")).emit();
        
        // Set environment variables
        string[string] env = null;
        if (!config.env.empty)
            env = cast(string[string])config.env.dup;
        
        // Execute compilation
        auto res = execute(cmd, env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Rustc compilation failed:\n" ~ res.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                [entryPoint],
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        // Parse warnings
        parseRustcOutput(res.output, result);
        
        // Update cache with success
        actionCache.update(
            actionId,
            [entryPoint],
            [outputPath],
            metadata,
            true
        );
        
        result.success = true;
        result.outputs = [outputPath];
        
        if (exists(outputPath))
            result.outputHash = FastHash.hashFile(outputPath);
        else
            result.outputHash = FastHash.hashString(res.output);
        
        return result;
    }
    
    /// Compile individual module with caching
    private RustCompileResult compileModule(
        string source,
        in RustConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        string rlibDir
    )
    {
        RustCompileResult result;
        
        // Generate output path for .rlib
        string moduleName = baseName(source, extension(source));
        string rlibPath = buildPath(rlibDir, moduleName ~ ".rlib");
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["edition"] = editionToString(config.edition);
        metadata["release"] = config.release.to!string;
        metadata["optLevel"] = config.release ? optLevelToString(config.optLevel) : "0";
        metadata["target"] = config.target;
        metadata["rustcFlags"] = config.rustcFlags.join(" ");
        
        // Create action ID for module compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = baseName(source);
        actionId.inputHash = FastHash.hashFile(source);
        
        // Check if module compilation is cached
        if (actionCache.isCached(actionId, [source], metadata) && exists(rlibPath))
        {
            structuredLog.debug_("__cached_").field("detail", "  [Cached] " ~ source).emit();
            result.success = true;
            result.outputs = [rlibPath];
            return result;
        }
        
        // Build rustc command for module compilation
        string[] cmd = ["rustc"];
        cmd ~= [source];
        cmd ~= ["-o", rlibPath];
        cmd ~= ["--crate-type", "rlib"];
        cmd ~= ["--edition", editionToString(config.edition)];
        
        if (config.release)
            cmd ~= ["-C", "opt-level=" ~ optLevelToString(config.optLevel)];
        else
            cmd ~= ["-C", "opt-level=0"];
        
        if (!config.target.empty)
            cmd ~= ["--target", config.target];
        
        cmd ~= config.rustcFlags;
        
        structuredLog.debug_("compiling_module_").field("detail", "Compiling module: " ~ source).emit();
        
        // Set environment variables
        string[string] env = null;
        if (!config.env.empty)
            env = cast(string[string])config.env.dup;
        
        auto res = execute(cmd, env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Module compilation failed for " ~ source ~ ": " ~ res.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                [source],
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        // Parse warnings
        parseRustcOutput(res.output, result);
        
        // Update cache with success
        actionCache.update(
            actionId,
            [source],
            [rlibPath],
            metadata,
            true
        );
        
        result.success = true;
        result.outputs = [rlibPath];
        
        return result;
    }
    
    /// Link compiled modules with caching
    private RustCompileResult linkModules(
        string[] modules,
        string outputPath,
        in RustConfig config,
        in Target target
    )
    {
        RustCompileResult result;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["crateType"] = crateTypeToString(config.crateType);
        metadata["release"] = config.release.to!string;
        metadata["lto"] = ltoModeToString(config.lto);
        metadata["target"] = config.target;
        metadata["rustcFlags"] = config.rustcFlags.join(" ");
        
        // Create action ID for linking
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Link;
        actionId.subId = baseName(outputPath);
        actionId.inputHash = FastHash.hashStrings(modules);
        
        // Check if linking is cached
        if (actionCache.isCached(actionId, modules, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_linking_").field("detail", "  [Cached] Linking: " ~ outputPath).emit();
            result.success = true;
            return result;
        }
        
        // Build link command
        string[] cmd = ["rustc"];
        cmd ~= ["--crate-type", crateTypeToString(config.crateType)];
        cmd ~= ["-o", outputPath];
        cmd ~= ["--edition", editionToString(config.edition)];
        
        // Add compiled modules as external crates
        foreach (mod_; modules)
        {
            string dir = dirName(mod_);
            cmd ~= ["-L", dir];
        }
        
        if (config.release)
            cmd ~= ["-C", "opt-level=" ~ optLevelToString(config.optLevel)];
        
        if (config.lto != LtoMode.Off)
            cmd ~= ["-C", "lto=" ~ ltoModeToString(config.lto)];
        
        if (!config.target.empty)
            cmd ~= ["--target", config.target];
        
        cmd ~= config.rustcFlags;
        
        structuredLog.debug_("linking_").field("detail", "Linking: " ~ outputPath).emit();
        
        // Set environment variables
        string[string] env = null;
        if (!config.env.empty)
            env = cast(string[string])config.env.dup;
        
        auto res = execute(cmd, env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Linking failed: " ~ res.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                modules,
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        // Update cache with success
        actionCache.update(
            actionId,
            modules,
            [outputPath],
            metadata,
            true
        );
        
        result.success = true;
        return result;
    }
    
    private RustCompileResult checkTarget(
        in string[] sources,
        in RustConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        RustCompileResult result;
        
        // Build rustc command for checking
        string[] cmd = ["rustc"];
        
        // Entry point
        if (!config.entry.empty)
            cmd ~= [config.entry];
        else
            cmd ~= [sources[0]];
        
        // Check only (no code generation)
        cmd ~= ["--emit", "metadata"];
        cmd ~= ["--crate-type", "lib"];
        cmd ~= ["--edition", editionToString(config.edition)];
        
        // Target triple
        if (!config.target.empty)
            cmd ~= ["--target", config.target];
        
        // Add library paths
        if (sources.length > 1)
        {
            foreach (source; sources[1 .. $])
            {
                string dir = dirName(source);
                cmd ~= ["-L", dir];
            }
        }
        
        cmd ~= config.rustcFlags;
        
        structuredLog.debug_("rustc_check_").field("detail", "Rustc check: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Rustc check failed:\n" ~ res.output;
            return result;
        }
        
        parseRustcOutput(res.output, result);
        
        result.success = true;
        result.outputHash = FastHash.hashString(res.output);
        
        return result;
    }
    
    private RustCompileResult testTarget(
        in string[] sources,
        in RustConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        RustCompileResult result;
        
        // Build test binary
        string testBinary = buildPath(workspace.options.outputDir, "test-" ~ baseName(sources[0], ".rs"));
        
        string[] cmd = ["rustc"];
        
        if (!config.entry.empty)
            cmd ~= [config.entry];
        else
            cmd ~= [sources[0]];
        
        cmd ~= ["-o", testBinary];
        cmd ~= ["--test"];
        cmd ~= ["--edition", editionToString(config.edition)];
        
        if (!config.target.empty)
            cmd ~= ["--target", config.target];
        
        cmd ~= config.rustcFlags;
        
        structuredLog.debug_("rustc_test_compile_").field("detail", "Rustc test compile: " ~ cmd.join(" ")).emit();
        
        auto compileRes = execute(cmd);
        
        if (compileRes.status != 0)
        {
            result.error = "Test compilation failed:\n" ~ compileRes.output;
            return result;
        }
        
        // Run test binary
        structuredLog.debug_("running_tests_").field("detail", "Running tests: " ~ testBinary).emit();
        
        string[] testCmd = [testBinary] ~ config.testFlags;
        auto testRes = execute(testCmd);
        
        if (testRes.status != 0)
        {
            result.error = "Tests failed:\n" ~ testRes.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashString(testRes.output);
        
        // Clean up test binary
        if (exists(testBinary))
            remove(testBinary);
        
        return result;
    }
    
    private RustCompileResult compileCustom(
        in string[] sources,
        in RustConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        RustCompileResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(sources);
        return result;
    }
    
    private void parseRustcOutput(string output, ref RustCompileResult result)
    {
        foreach (line; output.split("\n"))
        {
            if (line.canFind("warning:"))
            {
                result.hadWarnings = true;
                result.warnings ~= line;
            }
        }
    }
    
    private string crateTypeToString(CrateType type)
    {
        final switch (type)
        {
            case CrateType.Bin: return "bin";
            case CrateType.Lib: return "lib";
            case CrateType.Rlib: return "rlib";
            case CrateType.Dylib: return "dylib";
            case CrateType.Cdylib: return "cdylib";
            case CrateType.Staticlib: return "staticlib";
            case CrateType.ProcMacro: return "proc-macro";
        }
    }
    
    private string editionToString(RustEdition edition)
    {
        final switch (edition)
        {
            case RustEdition.Edition2015: return "2015";
            case RustEdition.Edition2018: return "2018";
            case RustEdition.Edition2021: return "2021";
            case RustEdition.Edition2024: return "2024";
        }
    }
    
    private string optLevelToString(OptLevel level)
    {
        final switch (level)
        {
            case OptLevel.O0: return "0";
            case OptLevel.O1: return "1";
            case OptLevel.O2: return "2";
            case OptLevel.O3: return "3";
            case OptLevel.Os: return "s";
            case OptLevel.Oz: return "z";
        }
    }
    
    private string ltoModeToString(LtoMode mode)
    {
        final switch (mode)
        {
            case LtoMode.Off: return "off";
            case LtoMode.Thin: return "thin";
            case LtoMode.Fat: return "fat";
        }
    }
}


