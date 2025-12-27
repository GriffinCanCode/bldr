module languages.web.elm.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import languages.base.base;
import languages.web.elm.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process.checker : isCommandAvailable;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Elm build handler with action-level caching
class ElmHandler : BaseLanguageHandler
{
    private ActionCache actionCache;
    
    this()
    {
        auto cacheConfig = ActionCacheConfig.fromEnvironment();
        actionCache = new ActionCache(".builder-cache/actions/elm", cacheConfig);
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
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_elm_target_").field("detail", "Building Elm target: " ~ target.name).emit();
        
        // Check if elm is available
        if (!isCommandAvailable("elm"))
        {
            result.error = "Elm compiler not found. Install from: https://elm-lang.org/";
            return result;
        }
        
        // Validate sources
        if (target.sources.empty)
        {
            result.error = "No source files provided for Elm target";
            return result;
        }
        
        // Parse Elm configuration
        ElmConfig elmConfig = parseElmConfig(target, config);
        
        // Detect entry point if not specified
        if (elmConfig.entry.empty)
        {
            elmConfig.entry = detectEntryPoint(target.sources);
            if (elmConfig.entry.empty)
            {
                result.error = "No Main.elm entry point found";
                return result;
            }
        }
        
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, elmConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, elmConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, elmConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, elmConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        ElmConfig elmConfig = parseElmConfig(target, config);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else if (!elmConfig.output.empty)
        {
            outputs ~= buildPath(config.options.outputDir, elmConfig.output);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            string ext = elmConfig.outputTarget == ElmOutputTarget.HTML ? ".html" : ".js";
            outputs ~= buildPath(config.options.outputDir, name ~ ext);
        }
        
        return outputs;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, ElmConfig elmConfig)
    {
        LanguageBuildResult result;
        
        // Install dependencies if requested
        if (elmConfig.installDeps && exists("elm.json"))
        {
            structuredLog.debug_("installing_elm_dependencies").emit();
            auto installResult = installDependencies();
            if (!installResult.success)
            {
                structuredLog.warning("failed_to_install_dependencies_").field("detail", "Failed to install dependencies: " ~ installResult.error).emit();
            }
        }
        
        // Run elm-format if requested
        if (elmConfig.format && isCommandAvailable("elm-format"))
        {
            structuredLog.debug_("running_elmformat").emit();
            formatCode(target.sources);
        }
        
        // Run elm-review if requested
        if (elmConfig.review && isCommandAvailable("elm-review"))
        {
            structuredLog.debug_("running_elmreview").emit();
            auto reviewResult = reviewCode();
            if (!reviewResult.success)
            {
                structuredLog.warning("code_review_issues_found_").field("detail", "Code review issues found: " ~ reviewResult.error).emit();
            }
        }
        
        // Compile Elm to JavaScript
        return compileElm(target, config, elmConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, ElmConfig elmConfig)
    {
        LanguageBuildResult result;
        
        // Generate documentation for libraries
        if (elmConfig.docs || config.options.verbose)
        {
            structuredLog.debug_("generating_elm_documentation").emit();
            generateDocs();
        }
        
        // Compile library
        return compileElm(target, config, elmConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, ElmConfig elmConfig)
    {
        LanguageBuildResult result;
        
        // Check for elm-test
        if (!isCommandAvailable("elm-test"))
        {
            result.error = "elm-test not found. Install with: npm install -g elm-test";
            return result;
        }
        
        structuredLog.info("running_elm_tests").emit();
        
        try
        {
            auto testResult = execute(["elm-test"]);
            
            if (testResult.status != 0)
            {
                result.error = "Tests failed:\n" ~ testResult.output;
                return result;
            }
            
            result.success = true;
            structuredLog.info("tests_passed").emit();
        }
        catch (Exception e)
        {
            result.error = "Failed to run tests: " ~ e.msg;
        }
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, ElmConfig elmConfig)
    {
        // Custom builds use same logic as executable
        return buildExecutable(target, config, elmConfig);
    }
    
    private LanguageBuildResult compileElm(in Target target, in WorkspaceConfig config, ElmConfig elmConfig)
    {
        LanguageBuildResult result;
        
        // Determine output path
        string[] outputs = getOutputs(target, config);
        string outputPath = outputs[0];
        
        // Ensure output directory exists
        string outputDir = dirName(outputPath);
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        // Prepare inputs: All Elm source files + elm.json
        string[] inputFiles = target.sources.dup;
        
        // Add elm.json as critical dependency
        if (exists("elm.json"))
        {
            inputFiles ~= "elm.json";
        }
        
        // Add entry point if not already in sources
        if (!elmConfig.entry.empty && !inputFiles.canFind(elmConfig.entry))
        {
            inputFiles ~= elmConfig.entry;
        }
        
        // Find and add all .elm files in source directories
        if (exists("elm.json"))
        {
            try
            {
                auto elmJson = parseJSON(readText("elm.json"));
                if ("source-directories" in elmJson)
                {
                    foreach (dir; elmJson["source-directories"].array)
                    {
                        string srcDir = dir.str;
                        if (exists(srcDir) && isDir(srcDir))
                        {
                            foreach (entry; dirEntries(srcDir, "*.elm", SpanMode.depth))
                            {
                                if (isFile(entry.name) && !inputFiles.canFind(entry.name))
                                {
                                    inputFiles ~= entry.name;
                                }
                            }
                        }
                    }
                }
            }
            catch (Exception e)
            {
                // If we can't parse elm.json, just use provided sources
                structuredLog.warning("could_not_parse_elmjson_for_source_disco").field("detail", "Could not parse elm.json for source discovery: " ~ e.msg).emit();
            }
        }
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["elmVersion"] = getElmVersion();
        metadata["optimize"] = elmConfig.optimize.to!string;
        metadata["debugMode"] = elmConfig.debugMode.to!string;
        metadata["outputTarget"] = elmConfig.outputTarget.to!string;
        metadata["mode"] = elmConfig.mode.to!string;
        
        if (!elmConfig.entry.empty)
            metadata["entry"] = elmConfig.entry;
        if (!elmConfig.compilerFlags.empty)
            metadata["compilerFlags"] = elmConfig.compilerFlags.join(" ");
        if (!elmConfig.sourceDirs.empty)
            metadata["sourceDirs"] = elmConfig.sourceDirs.join(",");
        
        // Create action ID for Elm compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "elm-compile";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, inputFiles, metadata))
        {
            if (exists(outputPath))
            {
                structuredLog.debug_("__cached_elm_compilation_").field("detail", "  [Cached] Elm compilation: " ~ target.name).emit();
                result.success = true;
                result.outputs = [outputPath];
                result.outputHash = FastHash.hashFile(outputPath);
                return result;
            }
        }
        
        // Build command
        string[] cmd = ["elm", "make", elmConfig.entry];
        
        // Add output flag
        cmd ~= ["--output", outputPath];
        
        // Add optimization flag for production
        if (elmConfig.optimize)
        {
            cmd ~= "--optimize";
        }
        
        // Add debug mode if enabled
        if (elmConfig.debugMode)
        {
            cmd ~= "--debug";
        }
        
        // Add any additional flags
        cmd ~= elmConfig.compilerFlags;
        
        structuredLog.info("compiling_elm_").field("detail", "Compiling Elm: " ~ elmConfig.entry).emit();
        if (config.options.verbose)
        {
            structuredLog.debug_("command_").field("detail", "Command: " ~ cmd.join(" ")).emit();
        }
        
        bool success = false;
        
        try
        {
            auto compileResult = execute(cmd);
            
            if (compileResult.status != 0)
            {
                result.error = "Elm compilation failed:\n" ~ compileResult.output;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    inputFiles,
                    [],
                    metadata,
                    false
                );
                
                return result;
            }
            
            // Check output was created
            if (!exists(outputPath))
            {
                result.error = "Expected output file not created: " ~ outputPath;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    inputFiles,
                    [],
                    metadata,
                    false
                );
                
                return result;
            }
            
            success = true;
            
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            
            structuredLog.info("compiled_").field("detail", "Compiled: " ~ baseName(outputPath)).emit();
            
            if (!compileResult.output.empty && config.options.verbose)
            {
                structuredLog.debug_("log_event").field("message", compileResult.output).emit();
            }
        }
        catch (Exception e)
        {
            result.error = "Failed to compile Elm: " ~ e.msg;
            success = false;
        }
        
        // Update cache with result
        actionCache.update(
            actionId,
            inputFiles,
            success ? [outputPath] : [],
            metadata,
            success
        );
        
        return result;
    }
    
    /// Get Elm compiler version for cache validation
    private string getElmVersion()
    {
        try
        {
            auto res = execute(["elm", "--version"]);
            if (res.status == 0)
                return res.output.strip;
        }
        catch (Exception) {}
        return "unknown";
    }
    
    /// Parse Elm configuration from target
    private ElmConfig parseElmConfig(in Target target, in WorkspaceConfig config)
    {
        ElmConfig elmConfig;
        
        // Try language-specific keys
        string configKey = "";
        if ("elm" in target.langConfig)
            configKey = "elm";
        else if ("elmConfig" in target.langConfig)
            configKey = "elmConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                elmConfig = ElmConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_elm_config_using_default").field("detail", "Failed to parse Elm config, using defaults: " ~ e.msg).emit();
            }
        }
        
        // Load source directories from elm.json if present
        if (exists("elm.json"))
        {
            try
            {
                auto elmJson = parseJSON(readText("elm.json"));
                if ("source-directories" in elmJson)
                {
                    import std.algorithm : map;
                    import std.array : array;
                    elmConfig.sourceDirs = elmJson["source-directories"].array.map!(e => e.str).array;
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_elmjson_").field("detail", "Failed to parse elm.json: " ~ e.msg).emit();
            }
        }
        
        return elmConfig;
    }
    
    /// Detect entry point from source files
    private string detectEntryPoint(const(string[]) sources)
    {
        // Look for Main.elm
        foreach (source; sources)
        {
            if (baseName(source) == "Main.elm")
                return source;
        }
        
        // Look for src/Main.elm
        foreach (source; sources)
        {
            if (source.endsWith("src/Main.elm"))
                return source;
        }
        
        // Fallback: first .elm file
        foreach (source; sources)
        {
            if (extension(source) == ".elm")
                return source;
        }
        
        return "";
    }
    
    /// Install Elm dependencies
    private ElmCompileResult installDependencies()
    {
        ElmCompileResult result;
        
        try
        {
            // elm install will read elm.json and install packages
            // Note: elm install is interactive by default, but dependencies are auto-installed on first compile
            // We'll just skip explicit installation and let elm make handle it
            result.success = true;
        }
        catch (Exception e)
        {
            result.error = "Failed to check dependencies: " ~ e.msg;
        }
        
        return result;
    }
    
    /// Format Elm code
    private void formatCode(const(string[]) sources)
    {
        try
        {
            foreach (source; sources)
            {
                if (extension(source) == ".elm")
                {
                    execute(["elm-format", "--yes", source]);
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_format_code_").field("detail", "Failed to format code: " ~ e.msg).emit();
        }
    }
    
    /// Review Elm code for quality
    private ElmCompileResult reviewCode()
    {
        ElmCompileResult result;
        
        try
        {
            auto reviewResult = execute(["elm-review"]);
            
            // elm-review returns non-zero if issues found
            if (reviewResult.status != 0)
            {
                result.error = reviewResult.output;
                result.warnings = reviewResult.output.split("\n");
            }
            
            result.success = true; // We don't fail build on review issues
        }
        catch (Exception e)
        {
            result.error = "Failed to run elm-review: " ~ e.msg;
        }
        
        return result;
    }
    
    /// Generate documentation
    private void generateDocs()
    {
        try
        {
            auto docsResult = execute(["elm", "make", "--docs=docs.json"]);
            if (docsResult.status == 0)
            {
                structuredLog.info("documentation_generated_docsjson").emit();
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_generate_documentation_").field("detail", "Failed to generate documentation: " ~ e.msg).emit();
        }
    }
}

