module languages.dynamic.handler;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import std.regex;
import std.process : environment;
import languages.base.base;
import languages.dynamic.spec : DynamicLanguageSpec = LanguageSpec;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import infrastructure.utils.security : execute;
import infrastructure.errors;
import engine.caching.actions.action;

/// Generic language handler driven by declarative specification
/// Eliminates need to write D code for simple language integrations
class SpecBasedHandler : BaseLanguageHandler
{
    private DynamicLanguageSpec spec;
    private ActionCache cache;
    
    this(DynamicLanguageSpec spec)
    {
        this.spec = spec;
    }
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        // Check compiler availability
        if (!spec.isAvailable())
        {
            result.error = "Compiler '" ~ spec.build.compiler ~ "' not found for " ~ spec.metadata.display;
            return result;
        }
        
        // Route based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config);
                break;
            case TargetType.Test:
                result = runTests(target, config);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.root, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(config.root, name);
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        if (spec.deps.pattern.empty)
            return [];
        
        Import[] allImports;
        auto regex = regex(spec.deps.pattern);
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                foreach (match; matchAll(content, regex))
                {
                    Import imp;
                    imp.moduleName = match[1].to!string;
                    imp.kind = ImportKind.External;  // Default to external
                    imp.location = SourceLocation(source, 0, 0);
                    allImports ~= imp;
                }
            }
            catch (Exception e)
            {
                Logger.warning("Failed to analyze imports in " ~ source);
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        // Install dependencies if configured
        if (!spec.deps.installCmd.empty)
        {
            if (!installDependencies(target, config))
            {
                result.error = "Failed to install dependencies";
                return result;
            }
        }
        
        // Run formatter if configured
        if (!spec.build.formatCmd.empty)
        {
            runFormatter(target, config);
        }
        
        // Run linter if configured
        if (!spec.build.lintCmd.empty)
        {
            runLinter(target, config);
        }
        
        // Build executable
        if (spec.build.compileCmd.empty)
        {
            result.error = "No compile command specified in language spec";
            return result;
        }
        
        auto outputs = getOutputs(target, config);
        string[string] vars;
        vars["sources"] = target.sources.join(" ");
        vars["output"] = outputs.empty ? "a.out" : outputs[0];
        vars["flags"] = target.flags.join(" ");
        vars["workspace"] = config.root;
        
        auto cmd = spec.expandTemplate(spec.build.compileCmd, vars);
        Logger.info("Building: " ~ cmd);
        
        auto res = executeWithEnv(cmd, spec.build.env, config.root);
        
        if (res.status != 0)
        {
            result.error = "Build failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        // For libraries, often just validation/syntax check is needed
        if (!spec.build.checkCmd.empty)
        {
            string[string] vars;
            vars["sources"] = target.sources.join(" ");
            vars["workspace"] = config.root;
            
            auto cmd = spec.expandTemplate(spec.build.checkCmd, vars);
            auto res = executeWithEnv(cmd, spec.build.env, config.root);
            
            if (res.status != 0)
            {
                result.error = "Check failed: " ~ res.output;
                return result;
            }
        }
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        if (spec.build.testCmd.empty)
        {
            result.error = "No test command specified in language spec";
            return result;
        }
        
        string[string] vars;
        vars["sources"] = target.sources.join(" ");
        vars["workspace"] = config.root;
        vars["flags"] = target.flags.join(" ");
        
        auto cmd = spec.expandTemplate(spec.build.testCmd, vars);
        Logger.info("Testing: " ~ cmd);
        
        auto res = executeWithEnv(cmd, spec.build.env, config.root);
        
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "Tests failed: " ~ res.output;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private bool installDependencies(in Target target, in WorkspaceConfig config) @system
    {
        string[string] vars;
        vars["workspace"] = config.root;
        
        if (!spec.deps.manifest.empty)
        {
            auto manifestPath = buildPath(config.root, spec.deps.manifest);
            if (!exists(manifestPath))
            {
                Logger.debugLog("No manifest found at " ~ manifestPath);
                return true; // Not an error if optional
            }
            vars["manifest"] = manifestPath;
        }
        
        auto cmd = spec.expandTemplate(spec.deps.installCmd, vars);
        Logger.info("Installing dependencies: " ~ cmd);
        
        auto res = executeWithEnv(cmd, spec.build.env, config.root);
        return res.status == 0;
    }
    
    private void runFormatter(in Target target, in WorkspaceConfig config) @system
    {
        string[string] vars;
        vars["sources"] = target.sources.join(" ");
        vars["workspace"] = config.root;
        
        auto cmd = spec.expandTemplate(spec.build.formatCmd, vars);
        Logger.debugLog("Formatting: " ~ cmd);
        
        auto res = executeWithEnv(cmd, spec.build.env, config.root);
        if (res.status != 0)
            Logger.warning("Formatting had issues: " ~ res.output);
    }
    
    private void runLinter(in Target target, in WorkspaceConfig config) @system
    {
        string[string] vars;
        vars["sources"] = target.sources.join(" ");
        vars["workspace"] = config.root;
        
        auto cmd = spec.expandTemplate(spec.build.lintCmd, vars);
        Logger.debugLog("Linting: " ~ cmd);
        
        auto res = executeWithEnv(cmd, spec.build.env, config.root);
        if (res.status != 0)
            Logger.warning("Linting found issues: " ~ res.output);
    }
    
    /// Execute command with environment variables
    private auto executeWithEnv(string cmd, string[string] env, string workDir) @system
    {
        import std.process : executeShell, Config;
        
        // Merge spec env with system env
        string[string] fullEnv = environment.toAA();
        foreach (key, value; env)
        {
            auto expanded = value.replace("{{workspace}}", workDir);
            fullEnv[key] = expanded;
        }
        
        return executeShell(cmd, fullEnv, Config.none, size_t.max, workDir);
    }
}

