module languages.compiled.zig.builders.compile;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.range;
import std.string;
import languages.compiled.zig.core.config;
import languages.compiled.zig.tooling.tools;
import languages.compiled.zig.builders.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;
import engine.linking.incremental;

/// Builder using direct zig compile commands with action-level caching and incremental linking
class CompileBuilder : ZigBuilder
{
    private ActionCache actionCache;
    private IncrementalLinker incLinker;
    private bool useIncrementalLink;
    
    this(ActionCache cache = null, bool enableIncrementalLink = true) @system
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/zig", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
        
        // Initialize incremental linker for Zig's linking phase
        incLinker = new IncrementalLinker(".builder-cache/linking/zig", actionCache);
        useIncrementalLink = enableIncrementalLink && incLinker.isIncrementalAvailable();
        
        if (useIncrementalLink)
            structuredLog.debug_("zig_incremental_link_enabled")
                .field("linker", incLinker.getLinkerConfig().type.to!string)
                .emit();
    }
    ZigCompileResult build(
        const string[] sources,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace
    )
    {
        ZigCompileResult result;
        
        if (sources.empty)
        {
            result.error = "No source files specified";
            return result;
        }
        
        // Determine entry point
        string entryPoint = config.entry.empty ? sources[0] : config.entry;
        
        if (!exists(entryPoint))
        {
            result.error = "Entry point not found: " ~ entryPoint;
            return result;
        }
        
        // Build based on mode
        final switch (config.mode)
        {
            case ZigBuildMode.Compile:
                result = compileTarget(sources, config, target, workspace);
                break;
            case ZigBuildMode.Test:
                result = runTests(sources, config, target, workspace);
                break;
            case ZigBuildMode.Run:
                result = buildAndRun(sources, config, target, workspace);
                break;
            case ZigBuildMode.Check:
                result = checkOnly(sources, config);
                break;
            case ZigBuildMode.TranslateC:
                result.error = "translate-c not yet implemented in compile builder";
                return result;
            case ZigBuildMode.BuildScript:
                result.error = "Use BuildZigBuilder for build.zig projects";
                return result;
            case ZigBuildMode.Custom:
                result = compileTarget(sources, config, target, workspace);
                break;
        }
        
        return result;
    }
    
    bool isAvailable()
    {
        return ZigTools.isZigAvailable();
    }
    
    string name() const
    {
        return "compile";
    }
    
    string getVersion()
    {
        return ZigTools.getZigVersion();
    }
    
    bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "compile":
            case "test":
            case "run":
            case "check":
            case "cross-compile":
                return true;
            default:
                return false;
        }
    }
    
    /// Compile target directly
    private ZigCompileResult compileTarget(
        const string[] sources,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace
    )
    {
        ZigCompileResult result;
        
        // Determine output path
        string outputPath = getOutputPath(config, target, workspace);
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // For multi-file projects, compile incrementally with caching
        if (sources.length > 1)
        {
            return compileIncremental(sources, config, target, workspace, outputPath, outputDir);
        }
        
        // Single file compilation with caching
        return compileDirect(sources, config, target, workspace, outputPath, outputDir);
    }
    
    /// Direct compilation with action-level caching
    private ZigCompileResult compileDirect(
        const string[] sources,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string outputPath,
        string outputDir
    )
    {
        ZigCompileResult result;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["outputType"] = config.outputType.to!string;
        metadata["optimize"] = config.optimize.to!string;
        metadata["linkMode"] = config.linkMode.to!string;
        metadata["strip"] = config.strip.to!string;
        metadata["target"] = config.target.toTargetFlag();
        metadata["cpuFeatures"] = config.target.cpuFeatures.to!string;
        metadata["lto"] = config.lto.to!string;
        metadata["pic"] = config.pic.to!string;
        metadata["cflags"] = config.cflags.join(" ");
        
        // Create action ID for compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = baseName(outputPath);
        actionId.inputHash = FastHash.hashStrings(sources);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, sources, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_zig_compilation_").field("detail", "  [Cached] Zig compilation: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Build command based on output type
        string[] cmd;
        
        final switch (config.outputType)
        {
            case OutputType.Exe:
                cmd = ["zig", "build-exe"];
                break;
            case OutputType.Lib:
                cmd = ["zig", "build-lib"];
                break;
            case OutputType.Dylib:
                cmd = ["zig", "build-lib", "-dynamic"];
                break;
            case OutputType.Obj:
                cmd = ["zig", "build-obj"];
                break;
        }
        
        // Add entry point
        cmd ~= config.entry.empty ? sources[0] : config.entry;
        
        // Add other sources as packages
        foreach (i, source; sources[1 .. $])
        {
            string modName = baseName(source, extension(source));
            cmd ~= ["--mod", modName ~ ":" ~ source];
        }
        
        // Add packages/dependencies
        foreach (pkg; config.packages)
        {
            if (!pkg.path.empty && exists(pkg.path))
            {
                cmd ~= ["--mod", pkg.name ~ ":" ~ pkg.path];
            }
        }
        
        // Add optimization mode
        final switch (config.optimize)
        {
            case OptMode.Debug:
                cmd ~= "-ODebug";
                break;
            case OptMode.ReleaseSafe:
                cmd ~= "-OReleaseSafe";
                break;
            case OptMode.ReleaseFast:
                cmd ~= "-OReleaseFast";
                break;
            case OptMode.ReleaseSmall:
                cmd ~= "-OReleaseSmall";
                break;
        }
        
        // Add target for cross-compilation
        if (config.target.isCross())
        {
            cmd ~= "-target";
            cmd ~= config.target.toTargetFlag();
        }
        
        // Add CPU features
        if (config.target.cpuFeatures == CpuFeature.Native)
        {
            cmd ~= "-mcpu=native";
        }
        else if (config.target.cpuFeatures == CpuFeature.Custom && !config.target.customFeatures.empty)
        {
            cmd ~= "-mcpu=" ~ config.target.customFeatures;
        }
        
        // Add C include directories
        foreach (inc; config.cIncludeDirs)
        {
            cmd ~= "-I" ~ inc;
        }
        
        // Add C library directories
        foreach (lib; config.cLibDirs)
        {
            cmd ~= "-L" ~ lib;
        }
        
        // Add C libraries
        foreach (lib; config.cLibs)
        {
            cmd ~= "-l" ~ lib;
        }
        
        // Add system libraries
        foreach (lib; config.sysLibs)
        {
            cmd ~= "-l" ~ lib;
        }
        
        // Add C flags
        cmd ~= config.cflags.map!(f => "-cflags " ~ f).array;
        
        // Add link mode
        // Note: -static is not supported on macOS/Darwin when libc is used
        if (config.linkMode == LinkMode.Static)
        {
            version(OSX)
            {
                // Skip -static on macOS as it's not supported with system libc
                structuredLog.debug_("skipping_static_flag_on_macos_not_suppor").emit();
            }
            else
            {
                cmd ~= "-static";
            }
        }
        
        // Add strip mode
        final switch (config.strip)
        {
            case StripMode.None:
                break;
            case StripMode.Debug:
                cmd ~= "-fstrip";
                break;
            case StripMode.All:
                cmd ~= "-fstrip";
                break;
        }
        
        // Add PIC/PIE
        if (config.pic)
            cmd ~= "-fPIC";
        if (config.pie)
            cmd ~= "-fPIE";
        
        // Add LTO
        if (config.lto)
            cmd ~= "-flto";
        
        // Add single-threaded
        if (config.singleThreaded)
            cmd ~= "-fsingle-threaded";
        
        // Add stack check
        if (!config.stackCheck)
            cmd ~= "-fno-stack-check";
        
        // Add red zone
        if (!config.redZone)
            cmd ~= "-mred-zone";
        
        // Add code model
        if (config.codeModel != CodeModel.Default)
        {
            final switch (config.codeModel)
            {
                case CodeModel.Default: break;
                case CodeModel.Tiny: cmd ~= "-mcmodel=tiny"; break;
                case CodeModel.Small: cmd ~= "-mcmodel=small"; break;
                case CodeModel.Kernel: cmd ~= "-mcmodel=kernel"; break;
                case CodeModel.Medium: cmd ~= "-mcmodel=medium"; break;
                case CodeModel.Large: cmd ~= "-mcmodel=large"; break;
            }
        }
        
        // Add output path
        cmd ~= ["-femit-bin=" ~ outputPath];
        
        // Add cache directory
        if (!config.cache.cacheDir.empty)
        {
            cmd ~= "--cache-dir";
            cmd ~= config.cache.cacheDir;
        }
        
        // Add global cache option
        if (!config.cache.globalCache)
        {
            cmd ~= "--global-cache-dir";
            cmd ~= buildPath(workspace.root, ".zig-cache");
        }
        
        // Add verbose
        if (config.verbose)
            cmd ~= "--verbose";
        
        // Add time report
        if (config.timeReport)
            cmd ~= "--verbose-link";
        
        // Add color
        if (!config.color)
            cmd ~= "-fno-color";
        
        // Add LLVM options
        if (!config.llvmVerifyModule)
            cmd ~= "-fno-llvm-module-verification";
        if (!config.llvmIrVerify)
            cmd ~= "-fno-llvm-ir-verification";
        
        // Add target flags
        cmd ~= target.flags;
        
        structuredLog.info("compiling_with_zig_").field("detail", "Compiling with zig: " ~ cmd.join(" ")).emit();
        
        // Prepare environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        // Add custom environment variables
        foreach (key, value; config.env)
            env[key] = value;
        
        // Execute compilation
        auto res = execute(cmd, env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Compilation failed: " ~ res.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                sources,
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        // Parse warnings
        foreach (line; res.output.lineSplitter)
        {
            if (line.canFind("warning:"))
            {
                result.warnings ~= line.strip;
                result.hadWarnings = true;
            }
        }
        
        // Update cache with success
        actionCache.update(
            actionId,
            sources,
            [outputPath],
            metadata,
            true
        );
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    /// Incremental compilation with per-file caching
    private ZigCompileResult compileIncremental(
        const string[] sources,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string outputPath,
        string outputDir
    )
    {
        ZigCompileResult result;
        
        // Create object directory for intermediate files
        string objDir = buildPath(outputDir, ".zig-obj");
        if (!exists(objDir))
            mkdirRecurse(objDir);
        
        // Compile each source file separately
        string[] objectFiles;
        foreach (source; sources)
        {
            auto objResult = compileObject(source, config, target, workspace, objDir);
            if (!objResult.success)
            {
                result.error = objResult.error;
                result.warnings ~= objResult.warnings;
                result.hadWarnings = result.hadWarnings || objResult.hadWarnings;
                return result;
            }
            
            objectFiles ~= objResult.outputs;
            result.warnings ~= objResult.warnings;
            result.hadWarnings = result.hadWarnings || objResult.hadWarnings;
        }
        
        // Link all object files
        auto linkResult = linkObjects(objectFiles, outputPath, config, target, workspace);
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
    
    /// Compile individual source file to object with caching
    private ZigCompileResult compileObject(
        string source,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string objDir
    )
    {
        ZigCompileResult result;
        
        // Generate object file path
        string objName = baseName(source, extension(source)) ~ ".o";
        string objPath = buildPath(objDir, objName);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["optimize"] = config.optimize.to!string;
        metadata["target"] = config.target.toTargetFlag();
        metadata["cpuFeatures"] = config.target.cpuFeatures.to!string;
        metadata["cflags"] = config.cflags.join(" ");
        
        // Create action ID for object compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = baseName(source);
        actionId.inputHash = FastHash.hashFile(source);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, [source], metadata) && exists(objPath))
        {
            structuredLog.debug_("__cached_").field("detail", "  [Cached] " ~ source).emit();
            result.success = true;
            result.outputs = [objPath];
            return result;
        }
        
        // Build zig command for object compilation
        string[] cmd = ["zig", "build-obj"];
        cmd ~= source;
        cmd ~= ["-femit-bin=" ~ objPath];
        
        // Add optimization mode
        final switch (config.optimize)
        {
            case OptMode.Debug: cmd ~= "-ODebug"; break;
            case OptMode.ReleaseSafe: cmd ~= "-OReleaseSafe"; break;
            case OptMode.ReleaseFast: cmd ~= "-OReleaseFast"; break;
            case OptMode.ReleaseSmall: cmd ~= "-OReleaseSmall"; break;
        }
        
        // Add target for cross-compilation
        if (config.target.isCross())
        {
            cmd ~= "-target";
            cmd ~= config.target.toTargetFlag();
        }
        
        // Add CPU features
        if (config.target.cpuFeatures == CpuFeature.Native)
        {
            cmd ~= "-mcpu=native";
        }
        else if (config.target.cpuFeatures == CpuFeature.Custom && !config.target.customFeatures.empty)
        {
            cmd ~= "-mcpu=" ~ config.target.customFeatures;
        }
        
        // Add C flags
        cmd ~= config.cflags.map!(f => "-cflags " ~ f).array;
        
        structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ source).emit();
        
        // Prepare environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        // Add custom environment variables
        foreach (key, value; config.env)
            env[key] = value;
        
        auto res = execute(cmd, env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Object compilation failed for " ~ source ~ ": " ~ res.output;
            
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
        foreach (line; res.output.lineSplitter)
        {
            if (line.canFind("warning:"))
            {
                result.warnings ~= line.strip;
                result.hadWarnings = true;
            }
        }
        
        // Update cache with success
        actionCache.update(
            actionId,
            [source],
            [objPath],
            metadata,
            true
        );
        
        result.success = true;
        result.outputs = [objPath];
        
        return result;
    }
    
    /// Link object files with caching and incremental linking support
    private ZigCompileResult linkObjects(
        string[] objectFiles,
        string outputPath,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace
    )
    {
        ZigCompileResult result;
        
        string[string] metadata;
        metadata["outputType"] = config.outputType.to!string;
        metadata["linkMode"] = config.linkMode.to!string;
        metadata["strip"] = config.strip.to!string;
        metadata["target"] = config.target.toTargetFlag();
        metadata["lto"] = config.lto.to!string;
        metadata["sysLibs"] = config.sysLibs.join(" ");
        
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Link;
        actionId.subId = baseName(outputPath);
        actionId.inputHash = FastHash.hashStrings(objectFiles);
        
        // Check action cache first
        if (actionCache.isCached(actionId, objectFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_linking_").field("detail", "  [Cached] Linking: " ~ outputPath).emit();
            result.success = true;
            return result;
        }
        
        // Analyze for incremental linking
        auto linkAnalysis = incLinker.analyze(outputPath, objectFiles, config.sysLibs, "");
        bool doIncremental = useIncrementalLink && linkAnalysis.canIncrementalLink();
        
        if (doIncremental)
            structuredLog.info("zig_incremental_link")
                .field("output", baseName(outputPath))
                .field("changed", linkAnalysis.changedObjects.length)
                .field("total", objectFiles.length)
                .emit();
        
        // Determine zig command based on output type
        string[] cmd;
        final switch (config.outputType)
        {
            case OutputType.Exe: cmd = ["zig", "build-exe"]; break;
            case OutputType.Lib: cmd = ["zig", "build-lib"]; break;
            case OutputType.Dylib: cmd = ["zig", "build-lib", "-dynamic"]; break;
            case OutputType.Obj: cmd = ["zig", "build-obj"]; break;
        }
        
        cmd ~= objectFiles;
        cmd ~= ["-femit-bin=" ~ outputPath];
        
        if (config.target.isCross())
        {
            cmd ~= "-target";
            cmd ~= config.target.toTargetFlag();
        }
        
        if (config.linkMode == LinkMode.Static)
        {
            version(OSX) {}
            else { cmd ~= "-static"; }
        }
        
        final switch (config.strip)
        {
            case StripMode.None: break;
            case StripMode.Debug, StripMode.All: cmd ~= "-fstrip"; break;
        }
        
        if (config.lto)
            cmd ~= "-flto";
        
        // Add incremental linker flags via passthrough to system linker
        if (doIncremental)
        {
            auto incFlags = incLinker.getLinkerFlags(linkAnalysis);
            foreach (flag; incFlags)
                cmd ~= "-Wl," ~ flag;  // Pass to system linker
        }
        
        foreach (lib; config.sysLibs)
            cmd ~= "-l" ~ lib;
        
        structuredLog.debug_("linking_").field("detail", "Linking: " ~ outputPath).emit();
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        foreach (key, value; config.env)
            env[key] = value;
        
        auto res = execute(cmd, env);
        
        if (res.status != 0)
        {
            result.error = "Linking failed: " ~ res.output;
            actionCache.update(actionId, objectFiles, [], metadata, false);
            incLinker.invalidate(outputPath);
            return result;
        }
        
        // Record successful link
        actionCache.update(actionId, objectFiles, [outputPath], metadata, true);
        incLinker.recordLink(outputPath, objectFiles, config.sysLibs, "", doIncremental);
        
        result.success = true;
        return result;
    }
    
    /// Run tests
    private ZigCompileResult runTests(
        const string[] sources,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace
    )
    {
        ZigCompileResult result;
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string[] cmd = ["zig", "test"];
            
            // Add optimization
            final switch (config.optimize)
            {
                case OptMode.Debug: cmd ~= "-ODebug"; break;
                case OptMode.ReleaseSafe: cmd ~= "-OReleaseSafe"; break;
                case OptMode.ReleaseFast: cmd ~= "-OReleaseFast"; break;
                case OptMode.ReleaseSmall: cmd ~= "-OReleaseSmall"; break;
            }
            
            // Add target
            if (config.target.isCross())
            {
                cmd ~= "-target";
                cmd ~= config.target.toTargetFlag();
            }
            
            // Add test filter
            if (!config.test.filter.empty)
            {
                cmd ~= "--test-filter";
                cmd ~= config.test.filter;
            }
            
            // Add test skip filter
            if (!config.test.skipFilter.empty)
            {
                cmd ~= "--test-name-prefix";
                cmd ~= config.test.skipFilter;
            }
            
            // Add target flags
            cmd ~= target.flags;
            
            // Add source
            cmd ~= source;
            
            structuredLog.info("running_tests_").field("detail", "Running tests: " ~ cmd.join(" ")).emit();
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.error = "Tests failed in " ~ source ~ ": " ~ res.output;
                return result;
            }
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(sources);
        
        return result;
    }
    
    /// Build and run
    private ZigCompileResult buildAndRun(
        const string[] sources,
        ZigConfig config,
        const Target target,
        const WorkspaceConfig workspace
    )
    {
        // First compile
        auto compileResult = compileTarget(sources, config, target, workspace);
        if (!compileResult.success)
            return compileResult;
        
        // Then run
        if (!compileResult.outputs.empty)
        {
            string exe = compileResult.outputs[0];
            structuredLog.info("running_").field("detail", "Running: " ~ exe).emit();
            
            auto res = execute([exe]);
            if (res.status != 0)
            {
                compileResult.error = "Execution failed: " ~ res.output;
                compileResult.success = false;
            }
        }
        
        return compileResult;
    }
    
    /// Check only (no code generation)
    private ZigCompileResult checkOnly(const string[] sources, ZigConfig config)
    {
        ZigCompileResult result;
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string[] cmd = ["zig", "ast-check", source];
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.error = "Check failed in " ~ source ~ ": " ~ res.output;
                return result;
            }
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(sources);
        
        return result;
    }
    
    /// Get output path
    private string getOutputPath(ZigConfig config, const Target target, const WorkspaceConfig workspace)
    {
        if (!config.outputName.empty)
        {
            return buildPath(config.outputDir, config.outputName);
        }
        
        if (!target.outputPath.empty)
        {
            return buildPath(workspace.options.outputDir, target.outputPath);
        }
        
        auto name = target.name.split(":")[$ - 1];
        
        // Add extension based on platform
        version(Windows)
        {
            if (config.outputType == OutputType.Exe)
                name ~= ".exe";
        }
        
        return buildPath(config.outputDir, name);
    }
}


