module languages.scripting.elixir.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import languages.base.base;
import languages.scripting.elixir.config;
import languages.scripting.elixir.managers;
import languages.scripting.elixir.tooling;
import languages.scripting.elixir.analysis;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Elixir build handler with action-level caching - comprehensive and modular
class ElixirHandler : BaseLanguageHandler
{
    private ActionCache actionCache;
    
    this()
    {
        auto cacheConfig = ActionCacheConfig.fromEnvironment();
        actionCache = new ActionCache(".builder-cache/actions/elixir", cacheConfig);
    }
    
    ~this()
    {
        import core.memory : GC;
        if (actionCache && !GC.inFinalizer())
        {
            try
            {
                actionCache.close();
            }
            catch (Exception) {}
        }
    }
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_elixir_target_").field("detail", "Building Elixir target: " ~ target.name).emit();
        
        // Parse Elixir configuration
        ElixirConfig elixirConfig = parseElixirConfig(target);
        
        // Auto-detect and enhance configuration from project structure
        enhanceConfigFromProject(elixirConfig, target, config);
        
        // Setup Elixir environment
        string elixirCmd = setupElixirEnvironment(elixirConfig, config.root);
        string mixCmd = setupMixCommand(elixirConfig, config.root);
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, elixirConfig, elixirCmd, mixCmd);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, elixirConfig, elixirCmd, mixCmd);
                break;
            case TargetType.Test:
                result = runTests(target, config, elixirConfig, elixirCmd, mixCmd);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, elixirConfig, elixirCmd, mixCmd);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        string[] outputs;
        
        ElixirConfig elixirConfig = parseElixirConfig(target);
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Different output based on project type
            final switch (elixirConfig.projectType)
            {
                case ElixirProjectType.Script:
                    outputs ~= target.sources; // Scripts are their own output
                    break;
                case ElixirProjectType.Escript:
                    outputs ~= buildPath(config.options.outputDir, name);
                    break;
                case ElixirProjectType.MixProject:
                case ElixirProjectType.Phoenix:
                case ElixirProjectType.PhoenixLiveView:
                case ElixirProjectType.Library:
                    // BEAM files in _build directory
                    string buildDir = elixirConfig.project.buildPath;
                    string envDir = envToString(elixirConfig.env);
                    outputs ~= buildPath(buildDir, envDir, "lib");
                    break;
                case ElixirProjectType.Umbrella:
                    // Each app in umbrella
                    string buildDir = elixirConfig.project.buildPath;
                    string envDir = envToString(elixirConfig.env);
                    foreach (app; elixirConfig.umbrella.apps)
                    {
                        outputs ~= buildPath(buildDir, envDir, "lib", app);
                    }
                    break;
                case ElixirProjectType.Nerves:
                    // Firmware file
                    outputs ~= buildPath(config.options.outputDir, name ~ ".fw");
                    break;
            }
            
            // Add release output if configured
            if (elixirConfig.release.type != ReleaseType.None)
            {
                outputs ~= buildPath(elixirConfig.release.path, elixirConfig.release.name);
            }
        }
        
        return outputs;
    }
    
    private LanguageBuildResult buildExecutable(
        const Target target,
        const WorkspaceConfig config,
        ElixirConfig elixirConfig,
        string elixirCmd,
        string mixCmd
    ) @system
    {
        LanguageBuildResult result;
        
        // Pre-build steps
        if (!preBuildSteps(elixirConfig, config.root, mixCmd))
        {
            result.error = "Pre-build steps failed";
            return result;
        }
        
        // Auto-format if configured
        if (elixirConfig.format.enabled)
        {
            structuredLog.info("autoformatting_code").emit();
            auto formatResult = Formatter.format(
                elixirConfig.format,
                target.sources,
                mixCmd,
                elixirConfig.format.checkFormatted
            );
            
            if (!formatResult.success && elixirConfig.format.checkFormatted)
            {
                result.error = "Code is not properly formatted";
                return result;
            }
            
            if (formatResult.hasIssues())
            {
                foreach (issue; formatResult.issues)
                {
                    structuredLog.warning("__").field("detail", "  " ~ issue).emit();
                }
            }
        }
        
        // Run Credo if configured
        if (elixirConfig.credo.enabled)
        {
            structuredLog.info("running_credo_static_analysis").emit();
            auto credoResult = CredoChecker.check(elixirConfig.credo, mixCmd);
            
            if (credoResult.hasErrors())
            {
                result.error = "Credo found critical issues:\n" ~ credoResult.errors.join("\n");
                return result;
            }
            
            if (credoResult.hasWarnings())
            {
                structuredLog.warning("credo_warnings").emit();
                foreach (warning; credoResult.warnings)
                {
                    structuredLog.warning("__").field("detail", "  " ~ warning).emit();
                }
            }
        }
        
        // Build using appropriate builder with action cache
        auto builder = BuilderFactory.create(elixirConfig.projectType, elixirConfig, actionCache);
        
        if (!builder.isAvailable())
        {
            result.error = "Required tools not available for " ~ elixirConfig.projectType.to!string;
            return result;
        }
        
        structuredLog.debug_("using_builder_").field("detail", "Using builder: " ~ builder.name()).emit();
        
        auto buildResult = builder.build(target.sources, elixirConfig, target, config);
        
        result.success = buildResult.success;
        if (!buildResult.errors.empty)
            result.error = buildResult.errors[0];
        result.outputs = buildResult.outputs;
        
        // Post-build steps
        if (result.success)
        {
            postBuildSteps(elixirConfig, config.root, mixCmd, buildResult);
        }
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(
        const Target target,
        const WorkspaceConfig config,
        ElixirConfig elixirConfig,
        string elixirCmd,
        string mixCmd
    ) @system
    {
        LanguageBuildResult result;
        
        // Libraries should use Library mode
        if (elixirConfig.projectType == ElixirProjectType.MixProject)
        {
            elixirConfig.projectType = ElixirProjectType.Library;
        }
        
        // Pre-build steps
        if (!preBuildSteps(elixirConfig, config.root, mixCmd))
        {
            result.error = "Pre-build steps failed";
            return result;
        }
        
        // Format check
        if (elixirConfig.format.enabled)
        {
            auto formatResult = Formatter.format(
                elixirConfig.format,
                target.sources,
                mixCmd,
                elixirConfig.format.checkFormatted
            );
            
            if (!formatResult.success && elixirConfig.format.checkFormatted)
            {
                result.error = "Code is not properly formatted";
                return result;
            }
        }
        
        // Run Dialyzer if configured
        if (elixirConfig.dialyzer.enabled)
        {
            structuredLog.info("running_dialyzer_type_analysis").emit();
            auto dialyzerResult = DialyzerChecker.check(elixirConfig.dialyzer, mixCmd);
            
            if (dialyzerResult.hasErrors())
            {
                result.error = "Dialyzer found type errors:\n" ~ dialyzerResult.errors.join("\n");
                return result;
            }
            
            if (dialyzerResult.hasWarnings())
            {
                structuredLog.warning("dialyzer_warnings").emit();
                foreach (warning; dialyzerResult.warnings)
                {
                    structuredLog.warning("__").field("detail", "  " ~ warning).emit();
                }
            }
        }
        
        // Build with action cache
        auto builder = BuilderFactory.create(elixirConfig.projectType, elixirConfig, actionCache);
        auto buildResult = builder.build(target.sources, elixirConfig, target, config);
        
        result.success = buildResult.success;
        if (!buildResult.errors.empty)
            result.error = buildResult.errors[0];
        result.outputs = buildResult.outputs;
        
        // Generate documentation if configured
        if (result.success && elixirConfig.documentation().enabled)
        {
            structuredLog.info("generating_documentation").emit();
            DocGenerator.generate(elixirConfig.documentation(), mixCmd);
        }
        
        // Build Hex package if configured
        if (result.success && elixirConfig.hex.publish)
        {
            structuredLog.info("building_hex_package").emit();
            HexManager.buildPackage(elixirConfig.hex, mixCmd);
        }
        
        return result;
    }
    
    private LanguageBuildResult runTests(
        const Target target,
        const WorkspaceConfig config,
        ElixirConfig elixirConfig,
        string elixirCmd,
        string mixCmd
    ) @system
    {
        LanguageBuildResult result;
        
        // Pre-build steps (compile dependencies)
        if (!preBuildSteps(elixirConfig, config.root, mixCmd))
        {
            result.error = "Pre-build steps failed";
            return result;
        }
        
        // Build test command
        string[] cmd = [mixCmd, "test"];
        
        // Set MIX_ENV to test
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        env["MIX_ENV"] = "test";
        
        // Merge custom environment variables
        // (ElixirConfig doesn't have env_ property, skipping)
        
        // Add ExUnit options
        if (elixirConfig.exunit().trace)
            cmd ~= "--trace";
        
        if (elixirConfig.exunit().maxCases > 0)
            cmd ~= ["--max-cases", elixirConfig.exunit().maxCases.to!string];
        
        foreach (tag; elixirConfig.exunit().exclude)
            cmd ~= ["--exclude", tag];
        
        foreach (tag; elixirConfig.exunit().include)
            cmd ~= ["--include", tag];
        
        foreach (tag; elixirConfig.exunit().only)
            cmd ~= ["--only", tag];
        
        if (elixirConfig.exunit().seed > 0)
            cmd ~= ["--seed", elixirConfig.exunit().seed.to!string];
        
        if (elixirConfig.exunit().timeout > 0)
            cmd ~= ["--timeout", elixirConfig.exunit().timeout.to!string];
        
        if (!elixirConfig.exunit().colors)
            cmd ~= "--no-color";
        
        // Add test paths
        if (!elixirConfig.exunit().testPaths.empty)
            cmd ~= elixirConfig.exunit().testPaths;
        
        structuredLog.info("running_exunit_tests_").field("detail", "Running ExUnit tests: " ~ cmd.join(" ")).emit();
        
        // Run tests
        auto res = execute(cmd, env, Config.none, size_t.max, config.root);
        
        if (res.status != 0)
        {
            result.error = "Tests failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        // Run coverage if configured
        if (elixirConfig.coveralls().enabled)
        {
            structuredLog.info("generating_test_coverage").emit();
            
            string[] covCmd = [mixCmd, "coveralls"];
            
            if (!elixirConfig.coveralls().post)
                covCmd ~= ["--local"];
            
            auto covRes = execute(covCmd, env, Config.none, size_t.max, config.root);
            
            if (covRes.status != 0)
            {
                structuredLog.warning("coverage_generation_failed").emit();
            }
        }
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(
        const Target target,
        const WorkspaceConfig config,
        ElixirConfig elixirConfig,
        string elixirCmd,
        string mixCmd
    ) @system
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    /// Parse Elixir configuration from target
    private ElixirConfig parseElixirConfig(const Target target) @system
    {
        ElixirConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("elixir" in target.langConfig)
            configKey = "elixir";
        else if ("elixirConfig" in target.langConfig)
            configKey = "elixirConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = ElixirConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_elixir_config_using_defa").field("detail", "Failed to parse Elixir config, using defaults: " ~ e.msg).emit();
            }
        }
        
        return config;
    }
    
    /// Enhance configuration based on project structure
    private void enhanceConfigFromProject(
        ref ElixirConfig config,
        const Target target,
        const WorkspaceConfig workspace
    ) @system
    {
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        // Auto-detect project type
        if (config.projectType == ElixirProjectType.MixProject)
        {
            auto detectedType = ProjectDetector.detectProjectType(sourceDir);
            if (detectedType != ElixirProjectType.MixProject)
            {
                config.projectType = detectedType;
                structuredLog.debug_("detected_project_type_").field("detail", "Detected project type: " ~ detectedType.to!string).emit();
            }
        }
        
        // Parse mix.exs if exists
        string mixExsPath = buildPath(sourceDir, config.project.mixExsPath);
        if (exists(mixExsPath))
        {
            auto mixInfo = MixProjectParser.parse(mixExsPath);
            
            if (config.project.name.empty && !mixInfo.name.empty)
                config.project.name = mixInfo.name;
            
            if (config.project.app.empty && !mixInfo.app.empty)
                config.project.app = mixInfo.app;
            
            if (config.project.version_.empty && !mixInfo.version_.empty)
                config.project.version_ = mixInfo.version_;
            
            structuredLog.debug_("parsed_mix_project_").field("detail", "Parsed Mix project: " ~ mixInfo.app).emit();
        }
        
        // Check for Phoenix
        if (ProjectDetector.isPhoenixProject(sourceDir))
        {
            config.phoenix.enabled = true;
            structuredLog.debug_("detected_phoenix_application").emit();
            
            if (ProjectDetector.hasLiveView(sourceDir))
            {
                config.phoenix.liveView = true;
                structuredLog.debug_("detected_phoenix_liveview").emit();
            }
        }
        
        // Check for umbrella
        if (ProjectDetector.isUmbrellaProject(sourceDir))
        {
            config.projectType = ElixirProjectType.Umbrella;
            auto apps = ProjectDetector.getUmbrellaApps(sourceDir, config.umbrella.appsDir);
            if (!apps.empty)
            {
                config.umbrella.apps = apps;
                structuredLog.debug_("detected_umbrella_apps_").field("detail", "Detected umbrella apps: " ~ apps.join(", ")).emit();
            }
        }
        
        // Check for Nerves
        if (ProjectDetector.isNervesProject(sourceDir))
        {
            // config.nerves.enabled = true;
            structuredLog.debug_("detected_nerves_project").emit();
        }
        
        // Check for .tool-versions (asdf)
        string toolVersionsPath = buildPath(sourceDir, ".tool-versions");
        if (exists(toolVersionsPath))
        {
            auto versions = VersionManager.parseToolVersions(toolVersionsPath);
            if ("elixir" in versions)
            {
                structuredLog.debug_("found_elixir_version_in_toolversions_").field("detail", "Found Elixir version in .tool-versions: " ~ versions["elixir"]).emit();
            }
        }
    }
    
    /// Setup Elixir environment and return Elixir command to use
    private string setupElixirEnvironment(ElixirConfig config, string projectRoot) @system
    {
        string elixirCmd = "elixir";
        
        // Use specific path if configured
        if (!config.elixirVersion.elixirPath.empty)
        {
            elixirCmd = config.elixirVersion.elixirPath;
        }
        else if (config.elixirVersion.useAsdf)
        {
            // Use asdf version manager
            auto vm = new AsdfVersionManager(projectRoot);
            if (vm.isAvailable())
            {
                elixirCmd = vm.getElixirPath();
                structuredLog.info("using_elixir_from_asdf_").field("detail", "Using Elixir from asdf: " ~ vm.getCurrentVersion()).emit();
            }
        }
        
        // Verify Elixir is available
        if (!ElixirTools.isElixirAvailable(elixirCmd))
        {
            structuredLog.warning("elixir_not_available_at_").field("detail", "Elixir not available at: " ~ elixirCmd ~ ", falling back to 'elixir'").emit();
            elixirCmd = "elixir";
        }
        
        auto version_ = ElixirTools.getElixirVersion(elixirCmd);
        structuredLog.debug_("using_elixir_").field("detail", "Using Elixir: " ~ elixirCmd ~ " (" ~ version_ ~ ")").emit();
        
        return elixirCmd;
    }
    
    /// Setup Mix command
    private string setupMixCommand(ElixirConfig config, string projectRoot) @system
    {
        string mixCmd = "mix";
        
        // Use local mix if available
        string localMix = buildPath(projectRoot, "mix");
        if (exists(localMix))
        {
            mixCmd = localMix;
        }
        
        if (!ElixirTools.isMixAvailable(mixCmd))
        {
            structuredLog.warning("mix_not_available").emit();
        }
        
        return mixCmd;
    }
    
    /// Pre-build steps (dependencies, compilation)
    private bool preBuildSteps(ElixirConfig config, string projectRoot, string mixCmd) @system
    {
        // Clean if requested
        if (false) // config.clean
        {
            structuredLog.info("cleaning_build_artifacts").emit();
            auto cleanRes = execute([mixCmd, "clean"], null, Config.none, size_t.max, projectRoot);
            if (cleanRes.status != 0)
            {
                structuredLog.warning("clean_failed").emit();
            }
        }
        
        // Install/update dependencies
        if (false) // config.installDeps || config.depsGet
        {
            structuredLog.info("fetching_dependencies").emit();
            auto depsRes = execute([mixCmd, "deps.get"], null, Config.none, size_t.max, projectRoot);
            if (depsRes.status != 0)
            {
                structuredLog.error("failed_to_fetch_dependencies").emit();
                structuredLog.error("__output_").field("detail", "  Output: " ~ depsRes.output).emit();
                return false;
            }
        }
        
        // Clean dependencies if requested
        if (false) // config.depsClean
        {
            structuredLog.info("cleaning_dependencies").emit();
            auto cleanRes = execute([mixCmd, "deps.clean", "--all"], null, Config.none, size_t.max, projectRoot);
            if (cleanRes.status != 0)
            {
                structuredLog.warning("deps_clean_failed").emit();
            }
        }
        
        // Compile dependencies
        if (false) // config.depsCompile
        {
            structuredLog.info("compiling_dependencies").emit();
            auto compRes = execute([mixCmd, "deps.compile"], null, Config.none, size_t.max, projectRoot);
            if (compRes.status != 0)
            {
                structuredLog.error("failed_to_compile_dependencies").emit();
                structuredLog.error("__output_").field("detail", "  Output: " ~ compRes.output).emit();
                return false;
            }
        }
        
        return true;
    }
    
    /// Post-build steps (Dialyzer, releases, etc.)
    private void postBuildSteps(
        ElixirConfig config,
        string projectRoot,
        string mixCmd,
        ElixirBuildResult buildResult
    ) @system
    {
        // Run Dialyzer with PLT caching (post-build for type checking)
        if (config.dialyzer.enabled)
        {
            structuredLog.info("running_dialyzer").emit();
            
            // Cache Dialyzer PLT builds
            string pltPath = buildPath(projectRoot, config.dialyzer.pltFile);
            string[] dialyzerInputs;
            
            // Gather BEAM files for PLT
            string beamDir = buildPath(projectRoot, "_build", envToString(config.env), "lib");
            if (exists(beamDir))
            {
                foreach (entry; dirEntries(beamDir, "*.beam", SpanMode.depth))
                {
                    dialyzerInputs ~= entry.name;
                }
            }
            
            // Build metadata for PLT cache
            string[string] pltMetadata;
            pltMetadata["apps"] = config.dialyzer.pltApps.join(",");
            pltMetadata["warnings"] = config.dialyzer.warnings.join(",");
            pltMetadata["flags"] = config.dialyzer.flags.join(",");
            
            // Create action ID for PLT build
            ActionId pltActionId;
            pltActionId.targetId = baseName(projectRoot);
            pltActionId.type = ActionType.Custom;
            pltActionId.subId = "dialyzer_plt";
            pltActionId.inputHash = FastHash.hashStrings(dialyzerInputs);
            
            // Check if PLT is cached
            bool pltCached = false;
            if (actionCache.isCached(pltActionId, dialyzerInputs, pltMetadata) && exists(pltPath))
            {
                structuredLog.info("__cached_dialyzer_plt").emit();
                pltCached = true;
            }
            
            auto dialyzerResult = DialyzerChecker.check(config.dialyzer, mixCmd);
            
            // Update PLT cache if not cached
            if (!pltCached && actionCache)
            {
                string[] pltOutputs;
                if (exists(pltPath))
                    pltOutputs ~= pltPath;
                
                actionCache.update(
                    pltActionId,
                    dialyzerInputs,
                    pltOutputs,
                    pltMetadata,
                    dialyzerResult.success
                );
            }
            
            if (dialyzerResult.hasWarnings())
            {
                structuredLog.warning("dialyzer_warnings").emit();
                foreach (warning; dialyzerResult.warnings)
                {
                    structuredLog.warning("__").field("detail", "  " ~ warning).emit();
                }
            }
        }
        
        // Build release if configured
        if (config.release.type != ReleaseType.None)
        {
            structuredLog.info("building_release").emit();
            auto releaseBuilder = ReleaseManager.createBuilder(config.release.type);
            if (releaseBuilder.isAvailable())
            {
                releaseBuilder.buildRelease(config.release, mixCmd);
            }
        }
        
        // Generate documentation with caching
        if (config.documentation().enabled)
        {
            structuredLog.info("generating_documentation").emit();
            
            // Gather source files for ExDoc cache
            string[] docInputs;
            string libDir = buildPath(projectRoot, "lib");
            if (exists(libDir))
            {
                foreach (entry; dirEntries(libDir, "*.ex", SpanMode.depth))
                {
                    docInputs ~= entry.name;
                }
            }
            
            string mixExsPath = buildPath(projectRoot, config.project().mixExsPath);
            if (exists(mixExsPath))
                docInputs ~= mixExsPath;
            
            // Build metadata for ExDoc cache
            string[string] docMetadata;
            docMetadata["format"] = config.documentation().formatters.join(",");
            docMetadata["outputPath"] = config.documentation().output;
            docMetadata["mainModule"] = config.documentation().main;
            
            // Create action ID for ExDoc generation
            ActionId docActionId;
            docActionId.targetId = baseName(projectRoot);
            docActionId.type = ActionType.Custom;
            docActionId.subId = "exdoc";
            docActionId.inputHash = FastHash.hashStrings(docInputs);
            
            string docOutputDir = buildPath(projectRoot, config.documentation().output);
            
            // Check if ExDoc is cached
            if (actionCache.isCached(docActionId, docInputs, docMetadata) && exists(docOutputDir))
            {
                structuredLog.info("__cached_exdoc_generation").emit();
            }
            else
            {
                auto docResult = DocGenerator.generate(config.documentation(), mixCmd);
                
                string[] docOutputs;
                if (exists(docOutputDir))
                    docOutputs ~= docOutputDir;
                
                actionCache.update(
                    docActionId,
                    docInputs,
                    docOutputs,
                    docMetadata,
                    docResult
                );
            }
        }
    }
    
    /// Convert MixEnv to string
    private string envToString(MixEnv env) @system pure nothrow
    {
        final switch (env)
        {
            case MixEnv.Dev: return "dev";
            case MixEnv.Test: return "test";
            case MixEnv.Prod: return "prod";
            case MixEnv.Custom: return "custom";
        }
    }
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        auto spec = getLanguageSpec(TargetLanguage.Elixir);
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
}

