module languages.dotnet.fsharp.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.base.base;
import languages.base.mixins;
import languages.dotnet.fsharp.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// F# build handler with action-level caching
class FSharpHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"fsharp";
    mixin ConfigParsingMixin!(FSharpConfig, "parseFSharpConfig", ["fsharp", "fsConfig"]);
    mixin SimpleBuildOrchestrationMixin!(FSharpConfig, "parseFSharpConfig");
    
    private void enhanceConfigFromProject(
        ref FSharpConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        // Auto-detect build tool if needed
        if (config.buildTool == FSharpBuildTool.Auto)
        {
            config.buildTool = detectBuildTool();
        }
        
        // Auto-detect package manager if needed
        if (config.packageManager == FSharpPackageManager.Auto)
        {
            config.packageManager = detectPackageManager();
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        string[] outputs;
        FSharpConfig fsConfig = parseFSharpConfig(target);
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Determine output based on mode and platform
            final switch (fsConfig.mode)
            {
                case FSharpBuildMode.Library:
                    outputs ~= buildPath(config.options.outputDir, name ~ ".dll");
                    break;
                case FSharpBuildMode.Executable:
                    version(Windows)
                        outputs ~= buildPath(config.options.outputDir, name ~ ".exe");
                    else
                        outputs ~= buildPath(config.options.outputDir, name);
                    break;
                case FSharpBuildMode.Script:
                    // Scripts don't produce output files
                    break;
                case FSharpBuildMode.Fable:
                    if (fsConfig.fable.typescript)
                        outputs ~= buildPath(config.options.outputDir, fsConfig.fable.outDir, name ~ ".ts");
                    else
                        outputs ~= buildPath(config.options.outputDir, fsConfig.fable.outDir, name ~ ".js");
                    break;
                case FSharpBuildMode.Wasm:
                    outputs ~= buildPath(config.options.outputDir, name ~ ".wasm");
                    break;
                case FSharpBuildMode.Native:
                    version(Windows)
                        outputs ~= buildPath(config.options.outputDir, name ~ ".exe");
                    else
                        outputs ~= buildPath(config.options.outputDir, name);
                    break;
                case FSharpBuildMode.Compile:
                    outputs ~= buildPath(config.options.outputDir, name ~ ".dll");
                    break;
            }
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.FSharp);
        if (spec is null)
            return [];
        
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = spec.scanImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source).emit();
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, FSharpConfig fsConfig)
    {
        // Ensure mode is set to executable
        fsConfig.mode = FSharpBuildMode.Executable;
        
        // Delegate to appropriate builder based on build tool
        return buildWithTool(target, config, fsConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, FSharpConfig fsConfig)
    {
        // Ensure mode is set to library
        fsConfig.mode = FSharpBuildMode.Library;
        
        return buildWithTool(target, config, fsConfig);
    }
    
    private LanguageBuildResult buildWithTool(in Target target, in WorkspaceConfig config, FSharpConfig fsConfig)
    {
        LanguageBuildResult result;
        
        final switch (fsConfig.buildTool)
        {
            case FSharpBuildTool.Auto:
                // Shouldn't reach here - auto should be resolved
                fsConfig.buildTool = FSharpBuildTool.Dotnet;
                goto case FSharpBuildTool.Dotnet;
                
            case FSharpBuildTool.Dotnet:
                result = buildWithDotnet(target, config, fsConfig);
                break;
                
            case FSharpBuildTool.FAKE:
                result = buildWithFAKE(target, config, fsConfig);
                break;
                
            case FSharpBuildTool.Direct:
                result = buildWithFSC(target, config, fsConfig);
                break;
                
            case FSharpBuildTool.None:
                result.error = "Build tool set to None - cannot build";
                break;
        }
        
        return result;
    }
    
    private LanguageBuildResult buildWithDotnet(const Target target, const WorkspaceConfig config, FSharpConfig fsConfig)
    {
        LanguageBuildResult result;
        
        auto outputs = getOutputs(target, config);
        if (outputs.empty)
        {
            result.error = "No output path specified";
            return result;
        }
        
        auto outputPath = outputs[0];
        auto outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build metadata for cache validation
        import engine.caching.actions.action : ActionId, ActionType;
        
        string[string] metadata;
        metadata["buildTool"] = "dotnet";
        metadata["configuration"] = fsConfig.dotnet.configuration;
        metadata["framework"] = fsConfig.dotnet.framework.identifier;
        metadata["runtime"] = fsConfig.dotnet.runtime;
        
        // Collect input files
        string[] inputFiles = target.sources.dup;
        
        // Add project file if exists
        string projectFile;
        foreach (source; target.sources)
        {
            if (source.endsWith(".fsproj"))
            {
                projectFile = source;
                break;
            }
        }
        
        if (projectFile.empty)
        {
            auto fsprojFiles = dirEntries(".", "*.fsproj", SpanMode.shallow, false).array;
            if (!fsprojFiles.empty)
            {
                projectFile = fsprojFiles[0].name;
                inputFiles ~= projectFile;
            }
        }
        
        // Create action ID for dotnet build
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Package;
        actionId.subId = "dotnet-fsharp-build";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if build is cached
        if (getCache().isCached(actionId, inputFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_dotnet_f_build_").field("detail", "  [Cached] dotnet F# build: " ~ outputPath).emit();
            result.success = true;
            result.outputs = outputs;
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Build command
        string[] cmd = ["dotnet", "build"];
        
        // Add configuration
        cmd ~= ["--configuration", fsConfig.dotnet.configuration];
        
        // Add framework
        if (!fsConfig.dotnet.framework.identifier.empty)
            cmd ~= ["--framework", fsConfig.dotnet.framework.identifier];
        
        // Add runtime
        if (!fsConfig.dotnet.runtime.empty)
            cmd ~= ["--runtime", fsConfig.dotnet.runtime];
        
        // Add output directory
        if (!fsConfig.dotnet.outputDir.empty)
            cmd ~= ["--output", fsConfig.dotnet.outputDir];
        else
            cmd ~= ["--output", outputDir];
        
        // Add verbosity
        cmd ~= ["--verbosity", fsConfig.dotnet.verbosity];
        
        // Restoration options
        if (fsConfig.dotnet.noRestore)
            cmd ~= ["--no-restore"];
        
        if (fsConfig.dotnet.noDependencies)
            cmd ~= ["--no-dependencies"];
        
        if (fsConfig.dotnet.force)
            cmd ~= ["--force"];
        
        // Self-contained
        if (fsConfig.dotnet.selfContained)
        {
            cmd ~= ["--self-contained"];
            
            if (fsConfig.dotnet.singleFile)
                cmd ~= ["-p:PublishSingleFile=true"];
            
            if (fsConfig.dotnet.readyToRun)
                cmd ~= ["-p:PublishReadyToRun=true"];
            
            if (fsConfig.dotnet.trimmed)
                cmd ~= ["-p:PublishTrimmed=true"];
        }
        
        // Add custom flags
        cmd ~= target.flags;
        cmd ~= fsConfig.compilerFlags.map!(f => "-p:OtherFlags=\"" ~ f ~ "\"").array;
        
        if (!projectFile.empty)
            cmd ~= [projectFile];
        
        // Execute build
        auto res = execute(cmd);
        
        bool success = (res.status == 0);
        
        import engine.caching.actions.action : ActionId, ActionType;
        ActionId actionId2;
        actionId2.targetId = target.name;
        actionId2.type = ActionType.Package;
        actionId2.subId = "dotnet-fsharp-build";
        actionId2.inputHash = FastHash.hashStrings(inputFiles);
        
        string[string] metadata2;
        metadata2["buildTool"] = "dotnet";
        metadata2["configuration"] = fsConfig.dotnet.configuration;
        
        if (!success)
        {
            result.error = "dotnet build failed: " ~ res.output;
            
            // Update cache with failure
            getCache().update(
                actionId2,
                inputFiles,
                [],
                metadata2,
                false
            );
            
            return result;
        }
        
        result.success = true;
        result.outputs = outputs;
        
        if (exists(outputPath))
            result.outputHash = FastHash.hashFile(outputPath);
        else
            result.outputHash = FastHash.hashStrings(target.sources.dup);
        
        // Update cache with success
        getCache().update(
            actionId2,
            inputFiles,
            outputs,
            metadata2,
            true
        );
        
        return result;
    }
    
    private LanguageBuildResult buildWithFAKE(const Target target, const WorkspaceConfig config, FSharpConfig fsConfig)
    {
        LanguageBuildResult result;
        
        // Check if FAKE script exists
        if (!exists(fsConfig.fake.scriptFile))
        {
            result.error = "FAKE script not found: " ~ fsConfig.fake.scriptFile;
            return result;
        }
        
        // Build command
        string[] cmd = ["dotnet", "fake", "run", fsConfig.fake.scriptFile];
        
        // Add target
        if (!fsConfig.fake.target.empty)
            cmd ~= ["--target", fsConfig.fake.target];
        
        // Add arguments
        cmd ~= fsConfig.fake.arguments;
        
        // Add flags
        if (fsConfig.fake.verbose)
            cmd ~= ["--verbose"];
        
        if (fsConfig.fake.singleTarget)
            cmd ~= ["--single-target"];
        
        if (fsConfig.fake.parallel)
            cmd ~= ["--parallel", "true"];
        
        // Execute FAKE
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "FAKE build failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = getOutputs(target, config);
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildWithFSC(const Target target, const WorkspaceConfig config, FSharpConfig fsConfig)
    {
        LanguageBuildResult result;
        
        auto outputs = getOutputs(target, config);
        if (outputs.empty)
        {
            result.error = "No output path specified";
            return result;
        }
        
        auto outputPath = outputs[0];
        auto outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build metadata for cache validation
        import engine.caching.actions.action : ActionId, ActionType;
        
        string[string] metadata;
        metadata["compiler"] = "fsc";
        metadata["mode"] = fsConfig.mode.to!string;
        metadata["optimize"] = fsConfig.optimize.to!string;
        metadata["debug"] = fsConfig.debug_.to!string;
        metadata["tailcalls"] = fsConfig.tailcalls.to!string;
        metadata["flags"] = (target.flags ~ fsConfig.compilerFlags).join(" ");
        
        // Create action ID for fsc build (build-level since F# requires ordered compilation)
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "fsc-build";
        actionId.inputHash = FastHash.hashStrings(target.sources);
        
        // Check if build is cached
        if (getCache().isCached(actionId, target.sources, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_fsc_build_").field("detail", "  [Cached] fsc build: " ~ outputPath).emit();
            result.success = true;
            result.outputs = outputs;
            result.outputHash = FastHash.hashFile(outputPath);
            return result;
        }
        
        // Build command
        string[] cmd = ["fsc"];
        
        // Add output
        cmd ~= ["--out:" ~ outputPath];
        
        // Add target type
        if (fsConfig.mode == FSharpBuildMode.Executable)
            cmd ~= ["--target:exe"];
        else
            cmd ~= ["--target:library"];
        
        // Add optimization flags
        if (fsConfig.optimize)
            cmd ~= ["--optimize+"];
        else
            cmd ~= ["--optimize-"];
        
        // Add debug symbols
        if (fsConfig.debug_)
            cmd ~= ["--debug+", "--debug:full"];
        else if (target.name.indexOf("release") >= 0 || target.name.indexOf("Release") >= 0)
            cmd ~= ["--debug-"];
        
        // Tail calls
        if (fsConfig.tailcalls)
            cmd ~= ["--tailcalls+"];
        else
            cmd ~= ["--tailcalls-"];
        
        // Checked arithmetic
        if (fsConfig.checked)
            cmd ~= ["--checked+"];
        else
            cmd ~= ["--checked-"];
        
        // Deterministic
        if (fsConfig.deterministic)
            cmd ~= ["--deterministic+"];
        
        // Cross-optimize
        if (fsConfig.crossoptimize)
            cmd ~= ["--crossoptimize+"];
        
        // Defines
        foreach (define; fsConfig.defines)
            cmd ~= ["--define:" ~ define];
        
        // Warnings
        cmd ~= ["--warn:" ~ fsConfig.analysis.warningLevel.to!string];
        
        if (fsConfig.analysis.warningsAsErrors)
            cmd ~= ["--warnaserror+"];
        
        foreach (warn; fsConfig.analysis.warningsAsErrorsList)
            cmd ~= ["--warnaserror:" ~ warn.to!string];
        
        foreach (warn; fsConfig.analysis.disableWarnings)
            cmd ~= ["--nowarn:" ~ warn.to!string];
        
        // XML documentation
        if (!fsConfig.xmlDoc.empty)
            cmd ~= ["--doc:" ~ fsConfig.xmlDoc];
        
        // Add references for dependencies
        foreach (dep; target.deps)
        {
            auto depTarget = config.findTarget(dep);
            if (depTarget !is null)
            {
                auto depOutputs = getOutputs(*depTarget, config);
                foreach (depOut; depOutputs)
                    cmd ~= ["--reference:" ~ depOut];
            }
        }
        
        // Add compiler flags
        cmd ~= target.flags;
        cmd ~= fsConfig.compilerFlags;
        
        // Add source files
        cmd ~= target.sources.filter!(s => s.endsWith(".fs") || s.endsWith(".fsx") || s.endsWith(".fsi")).array;
        
        // Execute compilation
        auto res = execute(cmd);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "fsc failed: " ~ res.output;
            
            // Update cache with failure
            getCache().update(
                actionId,
                target.sources,
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashFile(outputPath);
        
        // Update cache with success
        getCache().update(
            actionId,
            target.sources,
            outputs,
            metadata,
            true
        );
        
        return result;
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, FSharpConfig fsConfig)
    {
        LanguageBuildResult result;
        
        // Use dotnet test if available
        if (fsConfig.buildTool == FSharpBuildTool.Dotnet || fsConfig.buildTool == FSharpBuildTool.Auto)
        {
            string[] cmd = ["dotnet", "test"];
            
            // Add configuration
            cmd ~= ["--configuration", fsConfig.dotnet.configuration];
            
            // Add framework
            if (!fsConfig.dotnet.framework.identifier.empty)
                cmd ~= ["--framework", fsConfig.dotnet.framework.identifier];
            
            // Add verbosity
            cmd ~= ["--verbosity", fsConfig.dotnet.verbosity];
            
            // Test options
            if (!fsConfig.test.filter.empty)
                cmd ~= ["--filter", fsConfig.test.filter];
            
            // Coverage
            if (fsConfig.test.coverage)
            {
                cmd ~= ["--collect:\"XPlat Code Coverage\""];
            }
            
            // Find .fsproj test file
            string testProject;
            foreach (source; target.sources)
            {
                if (source.endsWith(".fsproj"))
                {
                    testProject = source;
                    break;
                }
            }
            
            if (!testProject.empty)
                cmd ~= [testProject];
            
            // Add test flags
            cmd ~= fsConfig.test.testFlags;
            
            auto res = execute(cmd);
            
            if (res.status != 0)
            {
                result.error = "Tests failed: " ~ res.output;
                return result;
            }
            
            result.success = true;
            result.outputHash = FastHash.hashStrings(target.sources.dup);
        }
        else
        {
            // Build and run tests manually
            auto buildResult = buildExecutable(target, config, fsConfig);
            if (!buildResult.success)
            {
                result.error = buildResult.error;
                return result;
            }
            
            // Run the test executable
            if (!buildResult.outputs.empty)
            {
                auto res = execute([buildResult.outputs[0]]);
                
                if (res.status != 0)
                {
                    result.error = "Test execution failed: " ~ res.output;
                    return result;
                }
            }
            
            result.success = true;
            result.outputHash = buildResult.outputHash;
        }
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, FSharpConfig fsConfig)
    {
        LanguageBuildResult result;
        
        // Custom build commands via langConfig
        // For custom builds, users can specify commands in langConfig["fsharp"] as JSON
        // Example: { "customCommands": ["dotnet tool run paket", "dotnet fsi build.fsx"] }
        if ("fsharp" in target.langConfig)
        {
            import std.json : parseJSON, JSONType;
            import std.process : executeShell;
            
            try
            {
                auto json = parseJSON(target.langConfig["fsharp"]);
                if ("customCommands" in json)
                {
                    auto commandsJson = json["customCommands"];
                    if (commandsJson.type == JSONType.array)
                    {
                        foreach (cmd; commandsJson.array)
                        {
                            string command = cmd.str;
                            structuredLog.info("executing_custom_command_").field("detail", "Executing custom command: " ~ command).emit();
                            
                            auto res = executeShell(command);
                            if (res.status != 0)
                            {
                                result.error = "Custom command failed: " ~ command ~ "\n" ~ res.output;
                                return result;
                            }
                        }
                    }
                }
            }
            catch (Exception e)
            {
                result.error = "Failed to parse custom commands: " ~ e.msg;
                return result;
            }
        }
        
        result.success = true;
        result.outputs = getOutputs(target, config);
        result.outputHash = FastHash.hashStrings(target.sources.dup);
        
        return result;
    }
    
    /// Detect build tool from project structure
    private FSharpBuildTool detectBuildTool()
    {
        // Check for .fsproj (dotnet)
        auto fsprojFiles = dirEntries(".", "*.fsproj", SpanMode.shallow, false);
        if (!fsprojFiles.empty)
            return FSharpBuildTool.Dotnet;
        
        // Check for FAKE script
        if (exists("build.fsx") || exists("Build.fsx"))
            return FSharpBuildTool.FAKE;
        
        // Default to dotnet CLI
        return FSharpBuildTool.Dotnet;
    }
    
    /// Detect package manager from project structure
    private FSharpPackageManager detectPackageManager()
    {
        // Check for Paket
        if (exists("paket.dependencies") || exists("paket.lock"))
            return FSharpPackageManager.Paket;
        
        // Check for NuGet
        if (exists("packages.config") || exists("nuget.config"))
            return FSharpPackageManager.NuGet;
        
        // Default to NuGet (most common)
        return FSharpPackageManager.NuGet;
    }
}

