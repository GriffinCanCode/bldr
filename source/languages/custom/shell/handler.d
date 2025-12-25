module languages.custom.shell.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import languages.base.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;

/// Shell/genrule handler - executes arbitrary shell commands
/// Useful for integrating languages not natively supported (Gleam, etc.) via CLI
class ShellHandler : BaseLanguageHandler
{
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context) @system
    {
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        Logger.debugLog("Building shell target: " ~ target.name);
        
        // Shell targets must have a command
        if (target.command.empty)
        {
            result.error = "Shell target '" ~ target.name ~ "' requires a 'command' field";
            return result;
        }
        
        // Determine working directory
        string workDir = target.workdir.empty ? config.root : target.workdir;
        if (!workDir.isAbsolute)
            workDir = buildPath(config.root, workDir);
        
        // Set up environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        foreach (key, value; config.globalEnv)
            env[key] = value;
        foreach (key, value; target.env)
            env[key] = value;
        
        // Add sources as environment variable
        if (!target.sources.empty)
            env["SOURCES"] = target.sources.join(" ");
        
        // Add output path as environment variable
        if (!target.outputPath.empty)
            env["OUTPUT"] = target.outputPath;
        
        Logger.info("Executing: " ~ target.command);
        Logger.debugLog("  workdir: " ~ workDir);
        
        // Execute the command via shell
        auto res = executeShell(target.command, env, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            result.error = "Shell command failed (exit code " ~ res.status.to!string ~ "):\n" ~ res.output;
            return result;
        }
        
        // Log output if any
        if (!res.output.strip.empty)
            Logger.info(res.output.strip);
        
        result.success = true;
        result.outputs = getOutputs(target, config);
        result.outputHash = FastHash.hashStrings(target.sources.empty ? [target.command] : target.sources);
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        if (!target.outputPath.empty)
            return [buildPath(config.options.outputDir, target.outputPath)];
        return [];
    }
    
    override bool needsRebuild(in Target target, in WorkspaceConfig config) @system
    {
        // Shell targets always rebuild by default (no caching of arbitrary commands)
        // unless outputs exist and are newer than sources
        if (target.sources.empty)
            return true;
        
        auto outputs = getOutputs(target, config);
        if (outputs.empty)
            return true;
        
        foreach (output; outputs)
        {
            if (!exists(output))
                return true;
            
            auto outputTime = timeLastModified(output);
            foreach (source; target.sources)
            {
                if (exists(source) && timeLastModified(source) > outputTime)
                    return true;
            }
        }
        
        return false;
    }
    
    override void clean(in Target target, in WorkspaceConfig config) @system
    {
        foreach (output; getOutputs(target, config))
        {
            if (exists(output))
            {
                Logger.info("Removing: " ~ output);
                if (isDir(output))
                    rmdirRecurse(output);
                else
                    remove(output);
            }
        }
    }
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        // Shell targets don't have analyzable imports
        return [];
    }
}

