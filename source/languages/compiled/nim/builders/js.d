module languages.compiled.nim.builders.js;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.nim.builders.base;
import languages.compiled.nim.core.config;
import languages.compiled.nim.tooling.tools;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// JavaScript backend builder - compiles Nim to JavaScript
class JsBuilder : NimBuilder
{
    void setActionCache(ActionCache cache)
    {
        // JS builder inherits from CompileBuilder pattern - could add caching in future
    }
    
    NimCompileResult build(
        in string[] sources,
        in NimConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        NimCompileResult result;
        
        if (sources.empty && config.entry.empty)
        {
            result.error = "No source files specified";
            return result;
        }
        
        string entryPoint = config.entry.empty ? sources[0] : config.entry;
        
        // Ensure backend is set to JS
        import std.conv : to;
        NimConfig jsConfig = cast(NimConfig)config;
        jsConfig.backend = NimBackend.Js;
        
        // Determine output path
        string outputPath = determineJsOutputPath(entryPoint, jsConfig, target, workspace);
        string outputDir = dirName(outputPath);
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Build JavaScript compilation command
        string[] cmd = buildJsCommand(entryPoint, outputPath, jsConfig);
        
        if (jsConfig.verbose || jsConfig.listCmd)
        {
            structuredLog.info("nim_js_compile_command_").field("detail", "Nim JS compile command: " ~ cmd.join(" ")).emit();
        }
        
        // Set environment variables
        string[string] env = environment.toAA();
        foreach (key, value; jsConfig.env)
        {
            env[key] = value;
        }
        
        // Execute compilation
        auto res = execute(cmd, env);
        
        if (res.status != 0)
        {
            result.error = "Nim JavaScript compilation failed: " ~ res.output;
            return result;
        }
        
        // Parse warnings and hints
        parseCompilerOutput(res.output, result);
        
        // Verify output exists
        if (!exists(outputPath))
        {
            result.error = "Compilation succeeded but output file not found: " ~ outputPath;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFile(outputPath);
        
        return result;
    }
    
    bool isAvailable()
    {
        return NimTools.isNimAvailable();
    }
    
    string name() const
    {
        return "nim-js";
    }
    
    string getVersion()
    {
        return NimTools.getNimVersion();
    }
    
    bool supportsFeature(string feature)
    {
        return feature == "js" || feature == "javascript" || feature == "js-backend";
    }
    
    private string determineJsOutputPath(
        string entryPoint,
        in NimConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        // Use explicit output if specified
        if (!config.output.empty)
        {
            string output = config.output;
            // Ensure .js extension
            if (!output.endsWith(".js"))
                output ~= ".js";
            
            if (config.outputDir.empty)
                return buildPath(workspace.options.outputDir, output);
            else
                return buildPath(config.outputDir, output);
        }
        
        // Use target output path
        if (!target.outputPath.empty)
        {
            string output = target.outputPath;
            if (!output.endsWith(".js"))
                output ~= ".js";
            return buildPath(workspace.options.outputDir, output);
        }
        
        // Generate from entry point
        string baseName = stripExtension(baseName(entryPoint));
        string outputDir = config.outputDir.empty ? workspace.options.outputDir : config.outputDir;
        
        return buildPath(outputDir, baseName ~ ".js");
    }
    
    private string[] buildJsCommand(string entryPoint, string outputPath, in NimConfig config)
    {
        string[] cmd = ["nim", "js"];
        
        // Output specification
        cmd ~= "--out:" ~ outputPath;
        
        // Nimcache directory
        if (!config.nimCache.empty)
            cmd ~= "--nimcache:" ~ config.nimCache;
        
        // Optimization
        if (config.release)
        {
            cmd ~= "-d:release";
        }
        else
        {
            final switch (config.optimize)
            {
                case OptLevel.None:
                    cmd ~= "--opt:none";
                    break;
                case OptLevel.Speed:
                    cmd ~= "--opt:speed";
                    break;
                case OptLevel.Size:
                    cmd ~= "--opt:size";
                    break;
            }
        }
        
        // Danger mode
        if (config.danger)
            cmd ~= "-d:danger";
        
        // Debug options
        if (config.debugInfo)
            cmd ~= "--debugger:native";
        
        if (!config.checks)
            cmd ~= "--checks:off";
        
        if (!config.assertions)
            cmd ~= "--assertions:off";
        
        // Defines
        foreach (define; config.defines)
            cmd ~= "-d:" ~ define;
        
        // Paths
        if (config.path.clearPaths)
            cmd ~= "--clearNimblePath";
        
        foreach (path; config.path.paths)
            cmd ~= "--path:" ~ path;
        
        foreach (nimblePath; config.path.nimblePaths)
            cmd ~= "--nimblePath:" ~ nimblePath;
        
        // Hints and warnings
        foreach (hint; config.hints.enable)
            cmd ~= "--hint:" ~ hint ~ ":on";
        
        foreach (hint; config.hints.disable)
            cmd ~= "--hint:" ~ hint ~ ":off";
        
        foreach (warn; config.hints.enableWarnings)
            cmd ~= "--warning:" ~ warn ~ ":on";
        
        foreach (warn; config.hints.disableWarnings)
            cmd ~= "--warning:" ~ warn ~ ":off";
        
        if (config.hints.warningsAsErrors)
            cmd ~= "--warningAsError";
        
        // Additional compiler flags
        cmd ~= config.compilerFlags;
        
        // Verbose output
        if (config.verbose)
            cmd ~= "--verbose";
        
        // Force rebuild
        if (config.forceBuild)
            cmd ~= "--forceBuild";
        
        // Colors
        if (!config.colors)
            cmd ~= "--colors:off";
        
        // Entry point
        cmd ~= entryPoint;
        
        return cmd;
    }
    
    private void parseCompilerOutput(string output, ref NimCompileResult result)
    {
        import std.regex;
        
        // Parse warnings
        auto warningRegex = regex(`Warning:.*$", "m`);
        foreach (match; matchAll(output, warningRegex))
        {
            result.warnings ~= match.hit;
            result.hadWarnings = true;
        }
        
        // Parse hints
        auto hintRegex = regex(`Hint:.*$", "m`);
        foreach (match; matchAll(output, hintRegex))
        {
            result.hints ~= match.hit;
        }
    }
}

