module languages.compiled.nim.builders.check;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.compiled.nim.builders.base;
import languages.compiled.nim.core.config;
import languages.compiled.nim.tooling.tools;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Check builder - syntax and semantic checking without code generation
class CheckBuilder : NimBuilder
{
    void setActionCache(ActionCache cache)
    {
        // Check builder doesn't use caching - checks are fast
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
        
        // Check each source file
        string[] filesToCheck = config.entry.empty ? sources.dup : cast(string[])[config.entry];
        
        foreach (source; filesToCheck)
        {
            if (!exists(source))
            {
                result.error = "Source file not found: " ~ source;
                return result;
            }
            
            auto checkResult = checkFile(source, config);
            
            if (!checkResult.success)
            {
                result.error = checkResult.error;
                return result;
            }
            
            result.warnings ~= checkResult.warnings;
            result.hints ~= checkResult.hints;
            
            if (!checkResult.warnings.empty)
                result.hadWarnings = true;
        }
        
        result.success = true;
        result.outputs = filesToCheck;
        result.outputHash = FastHash.hashStrings(filesToCheck);
        
        return result;
    }
    
    bool isAvailable()
    {
        return NimTools.isNimAvailable();
    }
    
    string name() const
    {
        return "nim-check";
    }
    
    string getVersion()
    {
        return NimTools.getNimVersion();
    }
    
    bool supportsFeature(string feature)
    {
        return feature == "check" || feature == "syntax-check";
    }
    
    private NimCompileResult checkFile(string source, in NimConfig config)
    {
        NimCompileResult result;
        
        // Build check command
        string[] cmd = ["nim", "check"];
        
        // Add hints and warnings config
        foreach (hint; config.hints.disable)
            cmd ~= "--hint:" ~ hint ~ ":off";
        
        foreach (warn; config.hints.disableWarnings)
            cmd ~= "--warning:" ~ warn ~ ":off";
        
        if (config.hints.warningsAsErrors)
            cmd ~= "--warningAsError";
        
        if (config.hints.hintsAsErrors)
            cmd ~= "--hintAsError";
        
        // Add paths
        foreach (path; config.path.paths)
            cmd ~= "--path:" ~ path;
        
        // Add defines
        foreach (define; config.defines)
            cmd ~= "-d:" ~ define;
        
        // Backend (affects type checking)
        final switch (config.backend)
        {
            case NimBackend.C:
                cmd ~= "--backend:c";
                break;
            case NimBackend.Cpp:
                cmd ~= "--backend:cpp";
                break;
            case NimBackend.Js:
                cmd ~= "--backend:js";
                break;
            case NimBackend.ObjC:
                cmd ~= "--backend:objc";
                break;
        }
        
        // Add source file
        cmd ~= source;
        
        if (config.verbose)
        {
            structuredLog.debug_("check_command_").field("detail", "Check command: " ~ cmd.join(" ")).emit();
        }
        
        // Execute check
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Check failed for " ~ source ~ ": " ~ res.output;
            return result;
        }
        
        // Parse output for warnings and hints
        parseOutput(res.output, result);
        
        result.success = true;
        return result;
    }
    
    private void parseOutput(string output, ref NimCompileResult result)
    {
        import std.regex;
        
        // Parse warnings
        auto warningRegex = regex(`Warning:.*$", "m`);
        foreach (match; matchAll(output, warningRegex))
        {
            result.warnings ~= match.hit;
        }
        
        // Parse hints
        auto hintRegex = regex(`Hint:.*$", "m`);
        foreach (match; matchAll(output, hintRegex))
        {
            result.hints ~= match.hit;
        }
    }
}

