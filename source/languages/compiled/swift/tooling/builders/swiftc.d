module languages.compiled.swift.tooling.builders.swiftc;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.swift.config;
import languages.compiled.swift.tooling.builders.base;
import languages.compiled.swift.managers.spm;
import languages.compiled.swift.managers.toolchain;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// Direct swiftc compiler builder with action-level caching
class SwiftcBuilder : SwiftBuilder
{
    private ActionCache actionCache;
    
    this(ActionCache cache = null)
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/swift", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
    }
    SwiftBuildResult build(
        in string[] sources,
        in SwiftConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        SwiftBuildResult result;
        
        // Get output path
        auto outputs = getOutputPath(config, target, workspace);
        auto outputPath = outputs[0];
        auto outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // For multi-file projects, compile incrementally with caching
        if (sources.length > 1 && config.incrementalCompilation)
        {
            return compileIncremental(sources, config, target, workspace, outputPath, outputDir);
        }
        
        // Single pass compilation with caching
        return compileDirect(sources, config, target, workspace, outputPath, outputDir);
    }
    
    /// Direct compilation with action-level caching
    private SwiftBuildResult compileDirect(
        in string[] sources,
        in SwiftConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        string outputPath,
        string outputDir
    )
    {
        SwiftBuildResult result;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["buildConfig"] = config.buildConfig.to!string;
        metadata["optimization"] = config.optimization.to!string;
        metadata["projectType"] = config.projectType.to!string;
        metadata["libraryType"] = config.libraryType.to!string;
        metadata["languageVersion"] = getLanguageVersionString(config.languageVersion);
        metadata["triple"] = config.triple;
        metadata["sdk"] = config.sdk;
        metadata["swiftFlags"] = config.buildSettings.swiftFlags.join(" ");
        metadata["linkerFlags"] = config.buildSettings.linkerFlags.join(" ");
        metadata["wholeModule"] = config.wholeModuleOptimization.to!string;
        
        // Create action ID for compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = baseName(outputPath);
        actionId.inputHash = FastHash.hashStrings(sources);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, sources, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_swift_compilation_").field("detail", "  [Cached] Swift compilation: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Build command
        string[] cmd = [config.swiftcPath.empty ? "swiftc" : config.swiftcPath];
        
        // Output
        cmd ~= ["-o", outputPath];
        
        // Configuration-specific flags
        final switch (config.buildConfig)
        {
            case SwiftBuildConfig.Debug:
                cmd ~= ["-g"];
                break;
            case SwiftBuildConfig.Release:
                // Add optimization
                final switch (config.optimization)
                {
                    case SwiftOptimization.None:
                        cmd ~= ["-Onone"];
                        break;
                    case SwiftOptimization.Speed:
                        cmd ~= ["-O"];
                        break;
                    case SwiftOptimization.Size:
                        cmd ~= ["-Osize"];
                        break;
                    case SwiftOptimization.Unchecked:
                        cmd ~= ["-Ounchecked"];
                        break;
                }
                break;
            case SwiftBuildConfig.Custom:
                // Custom flags from config
                break;
        }
        
        // Project type specific flags
        final switch (config.projectType)
        {
            case SwiftProjectType.Executable:
                // Default behavior
                break;
            case SwiftProjectType.Library:
                // Emit library
                if (config.libraryType == SwiftLibraryType.Static)
                    cmd ~= ["-emit-library", "-static"];
                else if (config.libraryType == SwiftLibraryType.Dynamic)
                    cmd ~= ["-emit-library"];
                else
                    cmd ~= ["-emit-library"]; // Auto
                break;
            case SwiftProjectType.SystemModule:
                cmd ~= ["-emit-module"];
                break;
            case SwiftProjectType.Test:
                cmd ~= ["-enable-testing"];
                break;
            case SwiftProjectType.Macro:
                version(none) // Requires Swift 5.9+
                {
                    cmd ~= ["-load-plugin-library"];
                }
                break;
            case SwiftProjectType.Plugin:
                cmd ~= ["-emit-module"];
                break;
        }
        
        // Swift language version
        string langVersion = getLanguageVersionString(config.languageVersion);
        if (!langVersion.empty)
            cmd ~= ["-swift-version", langVersion];
        
        // Target triple
        if (!config.triple.empty)
            cmd ~= ["-target", config.triple];
        
        // SDK
        if (!config.sdk.empty)
            cmd ~= ["-sdk", config.sdk];
        
        // Module name
        if (!config.product.empty)
            cmd ~= ["-module-name", config.product];
        
        // Enable library evolution
        if (config.enableLibraryEvolution)
            cmd ~= ["-enable-library-evolution"];
        
        // Emit module interface
        if (config.emitModuleInterface)
            cmd ~= ["-emit-module-interface"];
        
        // Whole module optimization
        if (config.wholeModuleOptimization)
            cmd ~= ["-whole-module-optimization"];
        
        // Incremental compilation
        if (config.incrementalCompilation)
            cmd ~= ["-incremental"];
        
        // Enable batch mode
        if (config.batchMode)
            cmd ~= ["-enable-batch-mode"];
        
        // Number of threads
        if (config.jobs > 0)
            cmd ~= ["-num-threads", config.jobs.to!string];
        
        // Index while building
        if (config.indexWhileBuilding)
            cmd ~= ["-index-store-path", buildPath(outputDir, "index")];
        
        // Debug info
        if (config.debugInfo)
            cmd ~= ["-g"];
        
        // Testability
        if (config.enableTestability)
            cmd ~= ["-enable-testing"];
        
        // Sanitizers
        final switch (config.sanitizer)
        {
            case SwiftSanitizer.None:
                break;
            case SwiftSanitizer.Address:
                cmd ~= ["-sanitize=address"];
                break;
            case SwiftSanitizer.Thread:
                cmd ~= ["-sanitize=thread"];
                break;
            case SwiftSanitizer.Undefined:
                cmd ~= ["-sanitize=undefined"];
                break;
        }
        
        // Framework paths
        version(OSX)
        {
            foreach (framework; config.buildSettings.linkedFrameworks)
            {
                cmd ~= ["-framework", framework];
            }
        }
        
        // Linked libraries
        foreach (lib; config.buildSettings.linkedLibraries)
        {
            cmd ~= ["-l" ~ lib];
        }
        
        // Linker flags
        foreach (flag; config.buildSettings.linkerFlags)
        {
            cmd ~= ["-Xlinker", flag];
        }
        
        // Custom Swift flags
        cmd ~= config.buildSettings.swiftFlags;
        
        // Defines
        foreach (define; config.buildSettings.defines)
        {
            cmd ~= ["-D", define];
        }
        
        // Import paths
        foreach (path; config.buildSettings.headerSearchPaths)
        {
            cmd ~= ["-I", path];
        }
        
        // Add sources
        cmd ~= sources;
        
        // Run compiler
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, config.env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "swiftc failed: " ~ res.output;
            parseWarnings(res.output, result);
            
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
        parseWarnings(res.output, result);
        
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
    private SwiftBuildResult compileIncremental(
        in string[] sources,
        in SwiftConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        string outputPath,
        string outputDir
    )
    {
        SwiftBuildResult result;
        
        // Create object directory for intermediate files
        string objDir = buildPath(outputDir, ".swift-obj");
        if (!exists(objDir))
            mkdirRecurse(objDir);
        
        // Compile each source file separately
        string[] objectFiles;
        foreach (source; sources)
        {
            auto objResult = compileSource(source, config, target, workspace, objDir);
            if (!objResult.success)
            {
                result.error = objResult.error;
                result.warnings ~= objResult.warnings;
                return result;
            }
            
            objectFiles ~= objResult.outputs;
            result.warnings ~= objResult.warnings;
        }
        
        // Link all object files
        auto linkResult = linkObjects(objectFiles, outputPath, config, target);
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
    
    /// Compile individual source file with caching
    private SwiftBuildResult compileSource(
        string source,
        in SwiftConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        string objDir
    )
    {
        SwiftBuildResult result;
        
        // Generate object file path
        string objName = baseName(source, extension(source)) ~ ".o";
        string objPath = buildPath(objDir, objName);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["buildConfig"] = config.buildConfig.to!string;
        metadata["optimization"] = config.optimization.to!string;
        metadata["languageVersion"] = getLanguageVersionString(config.languageVersion);
        metadata["triple"] = config.triple;
        metadata["sdk"] = config.sdk;
        metadata["swiftFlags"] = config.buildSettings.swiftFlags.join(" ");
        
        // Create action ID for source compilation
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
        
        // Build swiftc command for source compilation
        string[] cmd = [config.swiftcPath.empty ? "swiftc" : config.swiftcPath];
        
        // Emit object file
        cmd ~= ["-c", source];
        cmd ~= ["-o", objPath];
        
        // Configuration flags
        final switch (config.buildConfig)
        {
            case SwiftBuildConfig.Debug:
                cmd ~= ["-g"];
                break;
            case SwiftBuildConfig.Release:
                final switch (config.optimization)
                {
                    case SwiftOptimization.None: cmd ~= ["-Onone"]; break;
                    case SwiftOptimization.Speed: cmd ~= ["-O"]; break;
                    case SwiftOptimization.Size: cmd ~= ["-Osize"]; break;
                    case SwiftOptimization.Unchecked: cmd ~= ["-Ounchecked"]; break;
                }
                break;
            case SwiftBuildConfig.Custom:
                break;
        }
        
        // Swift language version
        string langVersion = getLanguageVersionString(config.languageVersion);
        if (!langVersion.empty)
            cmd ~= ["-swift-version", langVersion];
        
        // Target triple
        if (!config.triple.empty)
            cmd ~= ["-target", config.triple];
        
        // SDK
        if (!config.sdk.empty)
            cmd ~= ["-sdk", config.sdk];
        
        // Module name
        if (!config.product.empty)
            cmd ~= ["-module-name", config.product];
        
        // Custom Swift flags
        cmd ~= config.buildSettings.swiftFlags;
        
        structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ source).emit();
        
        auto res = execute(cmd, config.env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Compilation failed for " ~ source ~ ": " ~ res.output;
            
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
        parseWarnings(res.output, result);
        
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
    
    /// Link object files with caching
    private SwiftBuildResult linkObjects(
        string[] objectFiles,
        string outputPath,
        in SwiftConfig config,
        in Target target
    )
    {
        SwiftBuildResult result;
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["projectType"] = config.projectType.to!string;
        metadata["libraryType"] = config.libraryType.to!string;
        metadata["triple"] = config.triple;
        metadata["linkerFlags"] = config.buildSettings.linkerFlags.join(" ");
        metadata["linkedLibraries"] = config.buildSettings.linkedLibraries.join(" ");
        
        // Create action ID for linking
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Link;
        actionId.subId = baseName(outputPath);
        actionId.inputHash = FastHash.hashStrings(objectFiles);
        
        // Check if linking is cached
        if (actionCache.isCached(actionId, objectFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_linking_").field("detail", "  [Cached] Linking: " ~ outputPath).emit();
            result.success = true;
            return result;
        }
        
        // Build swiftc link command
        string[] cmd = [config.swiftcPath.empty ? "swiftc" : config.swiftcPath];
        
        // Output
        cmd ~= ["-o", outputPath];
        
        // Object files
        cmd ~= objectFiles;
        
        // Target triple
        if (!config.triple.empty)
            cmd ~= ["-target", config.triple];
        
        // Framework paths
        version(OSX)
        {
            foreach (framework; config.buildSettings.linkedFrameworks)
            {
                cmd ~= ["-framework", framework];
            }
        }
        
        // Linked libraries
        foreach (lib; config.buildSettings.linkedLibraries)
        {
            cmd ~= ["-l" ~ lib];
        }
        
        // Linker flags
        foreach (flag; config.buildSettings.linkerFlags)
        {
            cmd ~= ["-Xlinker", flag];
        }
        
        structuredLog.debug_("linking_").field("detail", "Linking: " ~ outputPath).emit();
        
        auto res = execute(cmd, config.env);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Linking failed: " ~ res.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                objectFiles,
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        // Update cache with success
        actionCache.update(
            actionId,
            objectFiles,
            [outputPath],
            metadata,
            true
        );
        
        result.success = true;
        return result;
    }
    
    bool isAvailable()
    {
        return SwiftCompilerRunner.isAvailable();
    }
    
    string name() const
    {
        return "swiftc";
    }
    
    string getVersion()
    {
        return SwiftCompilerRunner.getVersion();
    }
    
    bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "compile":
            case "simple-projects":
                return true;
            default:
                return false;
        }
    }
    
    private string[] getOutputPath(in SwiftConfig config, in Target target, in WorkspaceConfig workspace)
    {
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Adjust extension based on platform and library type
            version(OSX)
            {
                if (config.projectType == SwiftProjectType.Library)
                {
                    if (config.libraryType == SwiftLibraryType.Static)
                        outputs ~= buildPath(workspace.options.outputDir, "lib" ~ name ~ ".a");
                    else
                        outputs ~= buildPath(workspace.options.outputDir, "lib" ~ name ~ ".dylib");
                }
                else
                {
                    outputs ~= buildPath(workspace.options.outputDir, name);
                }
            }
            else version(linux)
            {
                if (config.projectType == SwiftProjectType.Library)
                {
                    if (config.libraryType == SwiftLibraryType.Static)
                        outputs ~= buildPath(workspace.options.outputDir, "lib" ~ name ~ ".a");
                    else
                        outputs ~= buildPath(workspace.options.outputDir, "lib" ~ name ~ ".so");
                }
                else
                {
                    outputs ~= buildPath(workspace.options.outputDir, name);
                }
            }
            else version(Windows)
            {
                if (config.projectType == SwiftProjectType.Library)
                {
                    if (config.libraryType == SwiftLibraryType.Static)
                        outputs ~= buildPath(workspace.options.outputDir, name ~ ".lib");
                    else
                        outputs ~= buildPath(workspace.options.outputDir, name ~ ".dll");
                }
                else
                {
                    outputs ~= buildPath(workspace.options.outputDir, name ~ ".exe");
                }
            }
            else
            {
                outputs ~= buildPath(workspace.options.outputDir, name);
            }
        }
        
        return outputs;
    }
    
    private string getLanguageVersionString(SwiftLanguageVersion version_)
    {
        final switch (version_)
        {
            case SwiftLanguageVersion.Swift4: return "4";
            case SwiftLanguageVersion.Swift4_2: return "4.2";
            case SwiftLanguageVersion.Swift5: return "5";
            case SwiftLanguageVersion.Swift5_1: return "5.1";
            case SwiftLanguageVersion.Swift5_2: return "5.2";
            case SwiftLanguageVersion.Swift5_3: return "5.3";
            case SwiftLanguageVersion.Swift5_4: return "5.4";
            case SwiftLanguageVersion.Swift5_5: return "5.5";
            case SwiftLanguageVersion.Swift5_6: return "5.6";
            case SwiftLanguageVersion.Swift5_7: return "5.7";
            case SwiftLanguageVersion.Swift5_8: return "5.8";
            case SwiftLanguageVersion.Swift5_9: return "5.9";
            case SwiftLanguageVersion.Swift5_10: return "5.10";
            case SwiftLanguageVersion.Swift6: return "6";
        }
    }
    
    private void parseWarnings(string output, ref SwiftBuildResult result)
    {
        foreach (line; output.split("\n"))
        {
            if (line.canFind("warning:"))
            {
                result.warnings ~= line.strip;
            }
        }
    }
}

