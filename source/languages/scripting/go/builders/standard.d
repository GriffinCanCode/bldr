module languages.scripting.go.builders.standard;

import std.process : Config, environment;
import infrastructure.utils.security : execute;  // SECURITY: Auto-migrated
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.scripting.go.builders.base;
import languages.scripting.go.core.config;
import languages.scripting.go.managers.modules;
import languages.scripting.go.tooling.tools;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionId, ActionType;

// Async I/O threshold for batch hashing optimization  
private enum size_t ASYNC_HASH_THRESHOLD = 8;

/// Standard Go builder - uses go build command with action-level caching
class StandardBuilder : GoBuilder
{
    protected ActionCache actionCache;
    
    this(ActionCache actionCache = null)
    {
        this.actionCache = actionCache;
    }
    
    override GoBuildResult build(
        in string[] sources,
        in GoConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        GoBuildResult result;
        
        if (!isAvailable())
        {
            result.error = "Go compiler not available. Install Go from https://golang.org/dl/";
            return result;
        }
        
        // Determine working directory (module root)
        string workDir = workspace.root;
        if (!sources.empty)
            workDir = dirName(sources[0]);
        
        // Check if in a module
        auto goModPath = ModuleAnalyzer.findGoMod(workDir);
        bool inModule = !goModPath.empty;
        
        if (!inModule && config.modMode != GoModMode.Off)
        {
            structuredLog.warning("no_gomod_found_consider_running_go_mod_i").emit();
        }
        
        // Run go generate if requested
        if (config.generate)
        {
            auto genResult = GoTools.generate([], workDir);
            if (!genResult.success)
            {
                result.error = "go generate failed: " ~ genResult.errors.join("\n");
                return result;
            }
        }
        
        // Run go mod tidy if requested
        if (config.modTidy && inModule)
        {
            auto tidyResult = GoTools.modTidy(workDir);
            if (!tidyResult.success)
            {
                result.error = "go mod tidy failed: " ~ tidyResult.errors.join("\n");
                return result;
            }
        }
        
        // Install dependencies if requested
        if (config.installDeps && inModule)
        {
            auto downloadResult = GoTools.modDownload(workDir);
            if (!downloadResult.success)
            {
                structuredLog.warning("failed_to_download_dependencies_").field("detail", "Failed to download dependencies: " ~ downloadResult.errors.join("\n")).emit();
            }
        }
        
        // Vendor dependencies if requested
        if (config.vendor && inModule)
        {
            auto vendorResult = GoTools.modVendor(workDir);
            if (!vendorResult.success)
            {
                structuredLog.warning("failed_to_vendor_dependencies_").field("detail", "Failed to vendor dependencies: " ~ vendorResult.errors.join("\n")).emit();
            }
        }
        
        // Run formatting if requested
        if (config.runFmt)
        {
            auto fmtResult = GoTools.format(sources, true);
            if (!fmtResult.success)
            {
                structuredLog.warning("formatting_issues_").field("detail", "Formatting issues: " ~ fmtResult.errors.join("\n")).emit();
            }
            result.toolWarnings ~= fmtResult.warnings;
        }
        
        // Run go vet if requested
        if (config.runVet)
        {
            auto vetResult = GoTools.vet([], workDir);
            if (!vetResult.success)
            {
                result.hadToolErrors = true;
                result.toolWarnings ~= vetResult.errors;
                structuredLog.warning("go_vet_found_issuesn").field("detail", "go vet found issues:\n" ~ vetResult.errors.join("\n")).emit();
            }
        }
        
        // Run linter if requested
        if (config.runLint)
        {
            ToolResult lintResult;
            
            if (config.linter == "golangci-lint")
                lintResult = GoTools.lintGolangCI(workDir);
            else if (config.linter == "staticcheck")
                lintResult = GoTools.lintStaticCheck(workDir);
            else if (config.linter == "golint")
                lintResult = GoTools.lintGoLint([], workDir);
            else
                lintResult = GoTools.lintGolangCI(workDir); // Default
            
            if (lintResult.hasIssues())
            {
                result.toolWarnings ~= lintResult.warnings;
                structuredLog.info("linter_found_issuesn").field("detail", "Linter found issues:\n" ~ lintResult.warnings.join("\n")).emit();
            }
        }
        
        // Build the actual binary
        auto buildResult = executeBuild(sources, config, target, workspace, workDir);
        
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        return result;
    }
    
    bool isAvailable()
    {
        return GoTools.isGoAvailable();
    }
    
    string name() const
    {
        return "standard";
    }
    
    string getVersion()
    {
        return GoTools.getGoVersion();
    }
    
    bool supportsMode(GoBuildMode mode)
    {
        return mode == GoBuildMode.Executable ||
               mode == GoBuildMode.Library ||
               mode == GoBuildMode.PIE ||
               mode == GoBuildMode.Shared;
    }
    
    private GoBuildResult executeBuild(
        const string[] sources,
        const GoConfig config,
        const Target target,
        const WorkspaceConfig workspace,
        string workDir
    )
    {
        GoBuildResult result;
        
        // Determine output path
        string outputPath;
        if (!target.outputPath.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name);
        }
        
        // Create output directory
        auto outputDir = dirName(outputPath);
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["goVersion"] = GoTools.getGoVersion();
        metadata["mode"] = config.mode.to!string;
        metadata["trimpath"] = config.trimpath.to!string;
        metadata["buildTags"] = (config.buildTags ~ config.constraints.tags).join(",");
        metadata["gcflags"] = config.gcflags.join(" ");
        metadata["ldflags"] = config.ldflags.join(" ");
        metadata["asmflags"] = config.asmflags.join(" ");
        if (config.vendor || config.modMode == GoModMode.Vendor)
            metadata["mod"] = "vendor";
        else if (config.modMode != GoModMode.Auto)
            metadata["mod"] = modModeToString(config.modMode);
        metadata["targetFlags"] = target.flags.join(" ");
        
        // Create action ID for Go build - use async hashing for many sources
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "go_build";
        // Use async hashing for better I/O throughput on cold cache
        if (sources.length > ASYNC_HASH_THRESHOLD)
        {
            auto hashes = FastHash.hashFilesAsync(sources.dup);
            actionId.inputHash = FastHash.hashStrings(hashes);
        }
        else
        {
            actionId.inputHash = FastHash.hashFiles(sources.dup);
        }
        
        // Check if build is cached
        bool hasActionCache = actionCache !is null;
        if (hasActionCache && actionCache.isCached(actionId, sources, metadata))
        {
            // Verify output exists
            if (exists(outputPath))
            {
                structuredLog.debug_("__cached_go_build_").field("detail", "  [Cached] Go build: " ~ target.name).emit();
                result.success = true;
                result.outputs = [outputPath];
                result.outputHash = FastHash.hashFile(outputPath);
                return result;
            }
        }
        
        // Build go build command
        string[] cmd;
        
        // For library mode, just compile the package without output
        bool isLibrary = config.mode == GoBuildMode.Library;
        
        string tempOutput;
        if (isLibrary)
        {
            // For library mode, build to a temp location to validate compilation
            import std.file : tempDir;
            import std.random : uniform;
            import std.format : format;
            tempOutput = buildPath(tempDir(), format("go-lib-temp-%d", uniform(0, 1000000)));
            cmd = ["go", "build", "-o", tempOutput];
        }
        else
        {
            cmd = ["go", "build"];
            
            // Build mode
            if (config.mode != GoBuildMode.Executable)
            {
                cmd ~= "-buildmode";
                cmd ~= buildModeToString(config.mode);
            }
            
            // Output path
            cmd ~= ["-o", outputPath];
        }
        
        // Trimpath
        if (config.trimpath)
            cmd ~= "-trimpath";
        
        // Build tags
        auto allTags = config.buildTags ~ config.constraints.tags;
        if (!allTags.empty)
        {
            cmd ~= "-tags";
            cmd ~= allTags.join(",");
        }
        
        // Compiler flags
        if (!config.gcflags.empty)
        {
            cmd ~= "-gcflags";
            cmd ~= config.gcflags.join(" ");
        }
        
        // Linker flags
        if (!config.ldflags.empty)
        {
            cmd ~= "-ldflags";
            cmd ~= config.ldflags.join(" ");
        }
        
        // Assembly flags
        if (!config.asmflags.empty)
        {
            cmd ~= "-asmflags";
            cmd ~= config.asmflags.join(" ");
        }
        
        // GCC flags (for gccgo)
        if (!config.gccgoflags.empty)
        {
            cmd ~= "-gccgoflags";
            cmd ~= config.gccgoflags.join(" ");
        }
        
        // Work directory
        if (!config.workDir.empty)
        {
            cmd ~= "-work";
            cmd ~= "-workdir";
            cmd ~= config.workDir;
        }
        
        // Vendor mode
        if (config.vendor || config.modMode == GoModMode.Vendor)
        {
            cmd ~= "-mod";
            cmd ~= "vendor";
        }
        else if (config.modMode != GoModMode.Auto)
        {
            cmd ~= "-mod";
            cmd ~= modModeToString(config.modMode);
        }
        
        // Add target flags
        cmd ~= target.flags;
        
        // Add sources or packages
        if (isLibrary)
        {
            // For libraries, compile the package directory instead of individual files
            // This is necessary because Go requires all files in a package to be built together
            cmd ~= ".";
        }
        else
        {
            // For executables, use the source files or package
            if (sources.empty)
                cmd ~= ".";
            else
                cmd ~= sources;
        }
        
        structuredLog.debug_("building_go_").field("detail", "Building Go: " ~ cmd.join(" ")).emit();
        
        // Prepare environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        // Add CGO environment
        if (config.cgo.enabled)
        {
            foreach (key, value; config.cgo.toEnv())
                env[key] = value;
        }
        
        // Add module mode environment
        if (config.modMode != GoModMode.Auto)
        {
            env["GO111MODULE"] = modModeToEnvString(config.modMode);
        }
        
        // Add module cache directory
        if (!config.modCacheDir.empty)
        {
            env["GOMODCACHE"] = config.modCacheDir;
        }
        
        // Execute build
        auto res = execute(cmd, env, Config.none, size_t.max, workDir);
        
        bool success = res.status == 0;
        
        if (!success)
        {
            result.error = "Go build failed: " ~ res.output;
            
            // Record failure in cache
            if (hasActionCache)
            {
                actionCache.update(actionId, sources, [], metadata, false);
            }
            
            return result;
        }
        
        result.success = true;
        
        // For library mode, there's no output binary, just verify compilation
        if (isLibrary)
        {
            // Clean up temp file
            if (!tempOutput.empty && exists(tempOutput))
            {
                try {
                    remove(tempOutput);
                } catch (Exception e) {
                    structuredLog.warning("failed_to_remove_temp_file_").field("detail", "Failed to remove temp file: " ~ tempOutput).emit();
                }
            }
            
            result.outputs = [];
            result.outputHash = FastHash.hashStrings(sources);
            structuredLog.info("go_librarypackage_compiled_successfully_").emit();
        }
        else
        {
            result.outputs = [outputPath];
            
            // Calculate hash
            if (exists(outputPath))
                result.outputHash = FastHash.hashFile(outputPath);
            else
                result.outputHash = FastHash.hashStrings(sources);
            
            // Update cache with success
            if (hasActionCache)
            {
                actionCache.update(actionId, sources, result.outputs, metadata, true);
            }
        }
        
        return result;
    }
    
    private string buildModeToString(GoBuildMode mode)
    {
        final switch (mode)
        {
            case GoBuildMode.Executable: return "exe";
            case GoBuildMode.CArchive: return "c-archive";
            case GoBuildMode.CShared: return "c-shared";
            case GoBuildMode.Plugin: return "plugin";
            case GoBuildMode.PIE: return "pie";
            case GoBuildMode.Shared: return "shared";
            case GoBuildMode.Library: return "default";
        }
    }
    
    private string modModeToString(GoModMode mode)
    {
        final switch (mode)
        {
            case GoModMode.Auto: return "";
            case GoModMode.On: return "mod";
            case GoModMode.Off: return ""; // Handled by GO111MODULE
            case GoModMode.Readonly: return "readonly";
            case GoModMode.Vendor: return "vendor";
        }
    }
    
    private string modModeToEnvString(GoModMode mode)
    {
        final switch (mode)
        {
            case GoModMode.Auto: return "auto";
            case GoModMode.On: return "on";
            case GoModMode.Off: return "off";
            case GoModMode.Readonly: return "on";
            case GoModMode.Vendor: return "on";
        }
    }
}

