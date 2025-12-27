module languages.web.elm.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import std.process : execute;
import languages.base;
import languages.web.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process.checker : isCommandAvailable;
import engine.caching.actions.action;

// ============================================================================
// Elm-specific enums
// ============================================================================

/// Elm output target
enum ElmOutputTarget { JavaScript, HTML }

// ============================================================================
// Elm Handler
// ============================================================================

/// Elm build handler - leverages BaseWebHandler for common functionality
class ElmHandler : BaseWebHandler
{
    private ElmOutputTarget outputTarget = ElmOutputTarget.JavaScript;
    private bool optimize = false;
    private bool debugMode = true;
    private bool docs = false;
    private bool format = false;
    private bool review = false;
    private string[] compilerFlags;
    private string[] sourceDirs;
    
    override protected string languageId() const pure nothrow => "elm";
    override protected TargetLanguage languageEnum() const pure nothrow => TargetLanguage.Elm;
    override protected string[] configKeys() const pure nothrow => ["elm", "elmConfig"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "Elm compiler not found. Install from: https://elm-lang.org/";
    
    /// Validate Elm sources
    override protected string validateSources(const(string[]) sources, WebConfig config) const
    {
        return "";  // Elm accepts all .elm files
    }
    
    /// Detect elm compiler
    override protected string detectToolkit(WebConfig config)
    {
        if (isCommandAvailable("elm")) return "elm";
        return "";
    }
    
    /// Build executable Elm target
    override protected LanguageBuildResult buildExecutable(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    )
    {
        // Install dependencies if requested
        if (webConfig.installDeps && exists("elm.json"))
        {
            structuredLog.debug_("installing_elm_dependencies").emit();
            auto installResult = installElmDependencies();
            if (!installResult.success)
                structuredLog.warning("failed_to_install_deps_").field("detail", installResult.error).emit();
        }
        
        // Run elm-format if requested
        if (format && isCommandAvailable("elm-format"))
        {
            structuredLog.debug_("running_elmformat").emit();
            formatCode(target.sources);
        }
        
        // Run elm-review if requested
        if (review && isCommandAvailable("elm-review"))
        {
            structuredLog.debug_("running_elmreview").emit();
            auto reviewResult = reviewCode();
            if (!reviewResult.success)
                structuredLog.warning("review_issues_").field("detail", reviewResult.error).emit();
        }
        
        return compileElm(target, config, webConfig);
    }
    
    /// Build Elm library
    override protected LanguageBuildResult buildLibrary(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    )
    {
        // Generate documentation for libraries
        if (docs || config.options.verbose)
        {
            structuredLog.debug_("generating_elm_documentation").emit();
            generateDocs();
        }
        
        return compileElm(target, config, webConfig);
    }
    
    /// Run Elm tests
    override protected LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
        if (!isCommandAvailable("elm-test"))
        {
            result.error = "elm-test not found. Install with: npm install -g elm-test";
            return result;
        }
        
        structuredLog.info("running_elm_tests").emit();
        
        auto testResult = execute(["elm-test"]);
        if (testResult.status != 0)
        {
            result.error = "Tests failed:\n" ~ testResult.output;
            return result;
        }
        
        result.success = true;
        structuredLog.info("tests_passed").emit();
        return result;
    }
    
    /// Get output filename
    override protected string getOutputName(string name, WebConfig config) const pure nothrow
    {
        return outputTarget == ElmOutputTarget.HTML ? name ~ ".html" : name ~ ".js";
    }
    
    /// Parse Elm-specific config
    override protected void parseLanguageSpecificConfig(ref WebConfig config, JSONValue json)
    {
        // Output target
        if (auto v = "outputTarget" in json)
        {
            string s = (*v).str.toLower;
            outputTarget = (s == "html") ? ElmOutputTarget.HTML : ElmOutputTarget.JavaScript;
        }
        
        // Mode (maps to optimize/debug)
        if (auto v = "mode" in json)
        {
            string s = (*v).str.toLower;
            if (s == "optimize" || s == "production")
            {
                optimize = true;
                debugMode = false;
            }
        }
        
        // Booleans
        if (auto v = "optimize" in json) optimize = (*v).type == JSONType.true_;
        if (auto v = "debug" in json) debugMode = (*v).type == JSONType.true_;
        if (auto v = "docs" in json) docs = (*v).type == JSONType.true_;
        if (auto v = "format" in json) format = (*v).type == JSONType.true_;
        if (auto v = "review" in json) review = (*v).type == JSONType.true_;
        
        // Arrays
        if (auto v = "compilerFlags" in json)
            compilerFlags = (*v).array.map!(e => e.str).array;
        if (auto v = "sourceDirs" in json)
            sourceDirs = (*v).array.map!(e => e.str).array;
        
        // Load source directories from elm.json
        if (exists("elm.json"))
        {
            try
            {
                auto elmJson = parseJSON(readText("elm.json"));
                if ("source-directories" in elmJson)
                    sourceDirs = elmJson["source-directories"].array.map!(e => e.str).array;
            }
            catch (Exception) {}
        }
    }
    
    // ========== Private helpers ==========
    
    /// Compile Elm to JavaScript/HTML
    private LanguageBuildResult compileElm(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
        // Detect entry point
        string entry = webConfig.entry;
        if (entry.empty)
        {
            entry = detectEntryPoint(target.sources);
            if (entry.empty)
            {
                result.error = "No Main.elm entry point found";
                return result;
            }
        }
        
        // Determine output path
        string[] outputs = getOutputs(target, config);
        string outputPath = outputs[0];
        
        // Ensure output directory exists
        string outputDir = dirName(outputPath);
        if (!exists(outputDir)) mkdirRecurse(outputDir);
        
        // Collect inputs
        string[] inputFiles = collectElmInputFiles(target.sources, entry);
        
        // Build metadata
        string[string] metadata = buildCacheMetadata(webConfig, "elm");
        metadata["elmVersion"] = getElmVersion();
        metadata["optimize"] = optimize.to!string;
        metadata["debugMode"] = debugMode.to!string;
        metadata["outputTarget"] = outputTarget.to!string;
        if (!entry.empty) metadata["entry"] = entry;
        if (!compilerFlags.empty) metadata["compilerFlags"] = compilerFlags.join(" ");
        if (!sourceDirs.empty) metadata["sourceDirs"] = sourceDirs.join(",");
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "elm-compile";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        // Check cache
        if (getCache().isCached(actionId, inputFiles, metadata))
        {
            if (exists(outputPath))
            {
                structuredLog.debug_("__cached_elm_compilation_").field("detail", 
                    "  [Cached] Elm: " ~ target.name).emit();
                result.success = true;
                result.outputs = [outputPath];
                result.outputHash = FastHash.hashFile(outputPath);
                return result;
            }
        }
        
        // Build command
        string[] cmd = ["elm", "make", entry, "--output", outputPath];
        
        if (optimize) cmd ~= "--optimize";
        if (debugMode) cmd ~= "--debug";
        cmd ~= compilerFlags;
        
        structuredLog.info("compiling_elm_").field("detail", "Compiling: " ~ entry).emit();
        if (config.options.verbose)
            structuredLog.debug_("command_").field("detail", "Command: " ~ cmd.join(" ")).emit();
        
        bool success = false;
        try
        {
            auto compileResult = execute(cmd);
            
            if (compileResult.status != 0)
            {
                result.error = "Elm compilation failed:\n" ~ compileResult.output;
                getCache().update(actionId, inputFiles, [], metadata, false);
                return result;
            }
            
            if (!exists(outputPath))
            {
                result.error = "Expected output not created: " ~ outputPath;
                getCache().update(actionId, inputFiles, [], metadata, false);
                return result;
            }
            
            success = true;
            result.success = true;
            result.outputs = [outputPath];
            result.outputHash = FastHash.hashFile(outputPath);
            
            structuredLog.info("compiled_").field("detail", "Compiled: " ~ baseName(outputPath)).emit();
        }
        catch (Exception e)
        {
            result.error = "Failed to compile Elm: " ~ e.msg;
        }
        
        getCache().update(actionId, inputFiles, success ? [outputPath] : [], metadata, success);
        return result;
    }
    
    /// Collect Elm input files
    private string[] collectElmInputFiles(const(string[]) sources, string entry)
    {
        string[] inputs = sources.dup;
        
        if (exists("elm.json"))
            inputs ~= "elm.json";
        
        if (!entry.empty && !inputs.canFind(entry))
            inputs ~= entry;
        
        // Add all .elm files from source directories
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
                            foreach (f; dirEntries(srcDir, "*.elm", SpanMode.depth))
                            {
                                if (isFile(f.name) && !inputs.canFind(f.name))
                                    inputs ~= f.name;
                            }
                        }
                    }
                }
            }
            catch (Exception) {}
        }
        
        return inputs;
    }
    
    /// Detect entry point (Main.elm)
    private string detectEntryPoint(const(string[]) sources)
    {
        // Look for Main.elm
        foreach (source; sources)
            if (baseName(source) == "Main.elm") return source;
        
        // Look for src/Main.elm
        foreach (source; sources)
            if (source.endsWith("src/Main.elm")) return source;
        
        // Fallback: first .elm file
        foreach (source; sources)
            if (extension(source) == ".elm") return source;
        
        return "";
    }
    
    /// Get Elm compiler version
    private string getElmVersion()
    {
        try
        {
            auto res = execute(["elm", "--version"]);
            if (res.status == 0) return res.output.strip;
        }
        catch (Exception) {}
        return "unknown";
    }
    
    /// Format Elm code
    private void formatCode(const(string[]) sources)
    {
        try
        {
            foreach (source; sources)
                if (extension(source) == ".elm")
                    execute(["elm-format", "--yes", source]);
        }
        catch (Exception e)
        {
            structuredLog.warning("format_failed_").field("detail", e.msg).emit();
        }
    }
    
    /// Review Elm code
    private ElmReviewResult reviewCode()
    {
        ElmReviewResult result;
        try
        {
            auto reviewResult = execute(["elm-review"]);
            if (reviewResult.status != 0)
            {
                result.error = reviewResult.output;
                result.warnings = reviewResult.output.split("\n");
            }
            result.success = true;  // Don't fail build on review issues
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
            auto res = execute(["elm", "make", "--docs=docs.json"]);
            if (res.status == 0)
                structuredLog.info("documentation_generated_docsjson").emit();
        }
        catch (Exception e)
        {
            structuredLog.warning("docs_failed_").field("detail", e.msg).emit();
        }
    }
    
    /// Install Elm dependencies
    private ElmReviewResult installElmDependencies()
    {
        ElmReviewResult result;
        try
        {
            // elm install doesn't have a non-interactive mode, so we just verify elm.json exists
            // Dependencies are automatically fetched on first build
            if (exists("elm.json"))
            {
                result.success = true;
            }
            else
            {
                // Initialize if needed
                auto initResult = execute(["elm", "init"]);
                result.success = initResult.status == 0;
                if (!result.success)
                    result.error = initResult.output;
            }
        }
        catch (Exception e)
        {
            result.error = "Failed to install dependencies: " ~ e.msg;
        }
        return result;
    }
}

/// Elm review result
private struct ElmReviewResult
{
    bool success;
    string error;
    string[] warnings;
}

/// Elm compilation result (for interface compatibility)
struct ElmCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string outputHash;
    string[] warnings;
}

