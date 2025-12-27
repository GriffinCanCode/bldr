module languages.compiled.swift.tooling.builders.spm;

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
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// Swift Package Manager builder with action-level caching
class SPMBuilder : SwiftBuilder
{
    private ActionCache actionCache;
    
    this(ActionCache cache = null)
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/swift-spm", cacheConfig);
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
        
        // Build command arguments
        string[] args;
        
        // Configuration
        final switch (config.buildConfig)
        {
            case SwiftBuildConfig.Debug:
                args ~= ["-c", "debug"];
                break;
            case SwiftBuildConfig.Release:
                args ~= ["-c", "release"];
                break;
            case SwiftBuildConfig.Custom:
                if (!config.customConfig.empty)
                    args ~= ["-c", config.customConfig];
                break;
        }
        
        // Product or target
        if (!config.product.empty)
            args ~= ["--product", config.product];
        else if (!config.target.empty)
            args ~= ["--target", config.target];
        
        // Build path
        if (!config.buildPath.empty)
            args ~= ["--build-path", config.buildPath];
        
        // Scratch path
        if (!config.scratchPath.empty)
            args ~= ["--scratch-path", config.scratchPath];
        
        // Package path
        if (!config.packagePath.empty)
            args ~= ["--package-path", config.packagePath];
        
        // Parallel jobs
        if (config.jobs > 0)
            args ~= ["--jobs", config.jobs.to!string];
        
        // Verbose
        if (config.verbose)
            args ~= ["--verbose"];
        if (config.veryVerbose)
            args ~= ["-v"];
        
        // Skip update
        if (config.skipUpdate)
            args ~= ["--skip-update"];
        
        // Disable sandbox
        if (config.disableSandbox)
            args ~= ["--disable-sandbox"];
        
        // Disable automatic resolution
        if (config.disableAutomaticResolution)
            args ~= ["--disable-automatic-resolution"];
        
        // Force resolved versions
        if (config.forceResolvedVersions)
            args ~= ["--force-resolved-versions"];
        
        // Static Swift stdlib
        if (config.staticSwiftStdlib)
            args ~= ["--static-swift-stdlib"];
        
        // Arch
        if (!config.arch.empty)
            args ~= ["--arch", config.arch];
        
        // Triple
        if (!config.triple.empty)
            args ~= ["--triple", config.triple];
        
        // SDK
        if (!config.sdk.empty)
            args ~= ["--sdk", config.sdk];
        
        // Add Xc flags (C compiler flags)
        foreach (flag; config.buildSettings.cFlags)
            args ~= ["-Xcc", flag];
        
        // Add Xswiftc flags (Swift compiler flags)
        foreach (flag; config.buildSettings.swiftFlags)
            args ~= ["-Xswiftc", flag];
        
        // Add Xlinker flags
        foreach (flag; config.buildSettings.linkerFlags)
            args ~= ["-Xlinker", flag];
        
        // Add linked libraries
        foreach (lib; config.buildSettings.linkedLibraries)
            args ~= ["-Xlinker", "-l" ~ lib];
        
        // Add linked frameworks
        version(OSX)
        {
            foreach (framework; config.buildSettings.linkedFrameworks)
            {
                args ~= ["-Xlinker", "-framework"];
                args ~= ["-Xlinker", framework];
            }
        }
        
        // Enable library evolution
        if (config.enableLibraryEvolution)
            args ~= ["-Xswiftc", "-enable-library-evolution"];
        
        // Emit module interface
        if (config.emitModuleInterface)
            args ~= ["-Xswiftc", "-emit-module-interface"];
        
        // Sanitizer
        final switch (config.sanitizer)
        {
            case SwiftSanitizer.None:
                break;
            case SwiftSanitizer.Address:
                args ~= ["--sanitize=address"];
                break;
            case SwiftSanitizer.Thread:
                args ~= ["--sanitize=thread"];
                break;
            case SwiftSanitizer.Undefined:
                args ~= ["--sanitize=undefined"];
                break;
        }
        
        // Code coverage
        if (config.coverage == SwiftCoverage.Generate)
            args ~= ["--enable-code-coverage"];
        
        // Testability
        if (config.enableTestability)
            args ~= ["--enable-testability"];
        
        // Collect all source files for caching
        string[] inputFiles;
        string packagePath = config.packagePath.empty ? "." : config.packagePath;
        string manifestPath = buildPath(packagePath, "Package.swift");
        
        if (exists(manifestPath))
            inputFiles ~= manifestPath;
        
        // Add all Swift source files in Sources/
        string sourcesDir = buildPath(packagePath, "Sources");
        if (exists(sourcesDir) && isDir(sourcesDir))
        {
            foreach (entry; dirEntries(sourcesDir, "*.swift", SpanMode.depth))
            {
                inputFiles ~= entry.name;
            }
        }
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["mode"] = config.mode.to!string;
        metadata["buildConfig"] = config.buildConfig.to!string;
        metadata["product"] = config.product;
        metadata["target"] = config.target;
        metadata["arch"] = config.arch;
        metadata["triple"] = config.triple;
        metadata["sdk"] = config.sdk;
        metadata["swiftFlags"] = config.buildSettings.swiftFlags.join(" ");
        metadata["linkerFlags"] = config.buildSettings.linkerFlags.join(" ");
        metadata["sanitizer"] = config.sanitizer.to!string;
        metadata["args"] = args.join(" ");
        
        // Create action ID for SPM build
        ActionId actionId;
        actionId.targetId = baseName(packagePath);
        actionId.type = config.mode == SPMBuildMode.Test ? ActionType.Test : ActionType.Package;
        actionId.subId = "spm_" ~ config.mode.to!string;
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Get output directory
        auto outputs = getBuildOutputs(config, workspace);
        
        // Check if build is cached (only for Build mode, not Test/Run)
        if (config.mode == SPMBuildMode.Build && 
            actionCache.isCached(actionId, inputFiles, metadata) && 
            !outputs.empty && exists(outputs[0]))
        {
            structuredLog.debug_("__cached_spm_build_").field("detail", "  [Cached] SPM build: " ~ packagePath).emit();
            result.success = true;
            result.outputs = outputs;
            result.outputHash = FastHash.hashFile(outputs[0]);
            return result;
        }
        
        // Run appropriate command based on mode
        auto runner = new SwiftBuildRunner(config.packagePath);
        
        import std.typecons : Tuple;
        Tuple!(int, "status", string, "output") res;
        final switch (config.mode)
        {
            case SPMBuildMode.Build:
                res = runner.runBuild(args, cast(string[string])config.env);
                break;
            case SPMBuildMode.Run:
                // Build first, then run
                res = runner.runBuild(args, cast(string[string])config.env);
                if (res.status == 0)
                {
                    auto runRunner = new SwiftRunRunner(config.packagePath);
                    auto runRes = runRunner.run(
                        config.product,
                        [],
                        config.buildConfig == SwiftBuildConfig.Debug ? "debug" : "release",
                        cast(string[string])config.env
                    );
                    result.success = runRes.status == 0;
                    if (runRes.status != 0)
                        result.error = "Run failed: " ~ runRes.output;
                }
                break;
            case SPMBuildMode.Test:
                auto testRunner = new SwiftTestRunner(config.packagePath);
                res = testRunner.test(
                    cast(string[])config.testing.filter.dup,
                    cast(string[])config.testing.skip.dup,
                    config.testing.parallel,
                    config.testing.enableCodeCoverage,
                    config.testing.numWorkers,
                    cast(string[string])config.env
                );
                
                // Parse test results
                parseTestResults(res.output, result);
                break;
            case SPMBuildMode.Check:
                // Type check only
                args ~= ["--build-tests"];
                res = runner.runBuild(args, cast(string[string])config.env);
                break;
            case SPMBuildMode.Clean:
                auto spmRunner = new SPMRunner(config.packagePath);
                res = spmRunner.clean();
                result.success = res.status == 0;
                if (res.status != 0)
                    result.error = "Clean failed: " ~ res.output;
                return result;
            case SPMBuildMode.GenerateXcodeproj:
                version(OSX)
                {
                    auto spmRunner = new SPMRunner(config.packagePath);
                    res = spmRunner.generateXcodeproj();
                    result.success = res.status == 0;
                    if (res.status != 0)
                        result.error = "Xcode project generation failed: " ~ res.output;
                    return result;
                }
                else
                {
                    result.error = "Xcode project generation only supported on macOS";
                    return result;
                }
            case SPMBuildMode.Custom:
                res = runner.runBuild(args, cast(string[string])config.env);
                break;
        }
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Swift build failed: " ~ res.output;
            parseWarnings(res.output, result);
            
            // Update cache with failure (only for Build mode)
            if (config.mode == SPMBuildMode.Build)
            {
                actionCache.update(
                    actionId,
                    inputFiles,
                    [],
                    metadata,
                    false
                );
            }
            
            return result;
        }
        
        // Parse warnings
        parseWarnings(res.output, result);
        
        // Get build outputs
        result.outputs = outputs;
        
        // Calculate hash
        if (!outputs.empty && exists(outputs[0]))
        {
            result.outputHash = FastHash.hashFile(outputs[0]);
        }
        else
        {
            result.outputHash = FastHash.hashStrings(sources);
        }
        
        // Update cache with success (only for Build mode)
        if (config.mode == SPMBuildMode.Build)
        {
            actionCache.update(
                actionId,
                inputFiles,
                outputs,
                metadata,
                true
            );
        }
        
        result.success = true;
        return result;
    }
    
    bool isAvailable()
    {
        return SPMRunner.isAvailable();
    }
    
    string name() const
    {
        return "swift-package-manager";
    }
    
    string getVersion()
    {
        return SPMRunner.getVersion();
    }
    
    bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "packages":
            case "dependencies":
            case "cross-compile":
            case "library-evolution":
            case "testing":
                return true;
            default:
                return false;
        }
    }
    
    private string[] getBuildOutputs(in SwiftConfig config, in WorkspaceConfig workspace)
    {
        string[] outputs;
        
        // Get build path
        string buildPathDir = config.buildPath;
        if (buildPathDir.empty)
            buildPathDir = ".build";
        
        // Determine configuration directory
        string configDir;
        final switch (config.buildConfig)
        {
            case SwiftBuildConfig.Debug:
                configDir = "debug";
                break;
            case SwiftBuildConfig.Release:
                configDir = "release";
                break;
            case SwiftBuildConfig.Custom:
                configDir = config.customConfig.empty ? "debug" : config.customConfig;
                break;
        }
        
        string outputDir = buildPath(buildPathDir, configDir);
        
        // Find built products
        if (exists(outputDir) && isDir(outputDir))
        {
            // Look for executable or library
            if (config.projectType == SwiftProjectType.Executable)
            {
                string productName = config.product;
                if (productName.empty && !config.target.empty)
                    productName = config.target;
                
                if (!productName.empty)
                {
                    string exePath = buildPath(outputDir, productName);
                    if (exists(exePath))
                        outputs ~= exePath;
                }
            }
            else if (config.projectType == SwiftProjectType.Library)
            {
                // Look for .a, .dylib, .so, or .dll files
                foreach (entry; dirEntries(outputDir, SpanMode.shallow))
                {
                    if (entry.isFile)
                    {
                        string ext = extension(entry.name);
                        if (ext == ".a" || ext == ".dylib" || ext == ".so" || ext == ".dll")
                        {
                            outputs ~= entry.name;
                        }
                    }
                }
            }
        }
        
        return outputs;
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
    
    private void parseTestResults(string output, ref SwiftBuildResult result)
    {
        result.testsRan = true;
        
        // Parse test output for pass/fail counts
        foreach (line; output.split("\n"))
        {
            // Look for test summary lines
            if (line.canFind("Test Suite") && line.canFind("passed"))
            {
                // Parse counts
                import std.regex;
                auto match = line.matchFirst(regex(`(\d+) tests?.*?(\d+) failures?`));
                if (!match.empty)
                {
                    result.testsPassed = match[1].to!int - match[2].to!int;
                    result.testsFailed = match[2].to!int;
                }
            }
        }
    }
}

