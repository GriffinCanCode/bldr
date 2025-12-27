module languages.scripting.r.tooling.builders.script;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import infrastructure.config.schema.schema;
import languages.scripting.r.core.config;
import languages.scripting.r.tooling.builders.base;
import languages.scripting.r.tooling.checkers;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Script builder - creates executable wrappers for R scripts
class RScriptBuilder : RBuilder
{
    override BuildResult build(
        in Target target,
        in WorkspaceConfig config,
        in RConfig rConfig,
        in string rCmd
    )
    {
        BuildResult result;
        
        if (target.sources.empty)
        {
            result.error = "No source files specified";
            return result;
        }
        
        // Validate syntax if requested
        if (rConfig.validateSyntax)
        {
            if (!validateSyntax(target.sources, rCmd, config.root))
            {
                result.error = "Syntax validation failed";
                return result;
            }
        }
        
        // Create executable wrapper
        auto outputs = getOutputs(target, config, rConfig);
        if (!outputs.empty)
        {
            auto outputPath = outputs[0];
            auto mainFile = target.sources[0];
            
            if (!createScriptWrapper(mainFile, outputPath, rConfig))
            {
                result.error = "Failed to create script wrapper";
                return result;
            }
            
            structuredLog.info("created_r_script_wrapper_").field("detail", "Created R script wrapper: " ~ outputPath).emit();
        }
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config, in RConfig rConfig)
    {
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(config.options.outputDir, name);
        }
        
        return outputs;
    }
    
    override bool validate(in Target target, in RConfig rConfig)
    {
        if (target.sources.empty)
        {
            structuredLog.error("no_source_files_specified_for_r_script").emit();
            return false;
        }
        
        // Check if main file exists
        if (!exists(target.sources[0]))
        {
            structuredLog.error("main_r_script_not_found_").field("detail", "Main R script not found: " ~ target.sources[0]).emit();
            return false;
        }
        
        return true;
    }
    
    /// Create R script wrapper
    private bool createScriptWrapper(string scriptPath, string outputPath, const ref RConfig config)
    {
        try
        {
            // Ensure output directory exists
            string outDir = dirName(outputPath);
            if (!exists(outDir))
                mkdirRecurse(outDir);
            
            // Create wrapper script
            string wrapper = "#!/usr/bin/env " ~ config.rExecutable ~ "\n\n";
            
            // Add library paths if specified
            if (!config.libPaths.empty)
            {
                wrapper ~= ".libPaths(c(" ~ config.libPaths.map!(p => `"` ~ p ~ `"`).join(",") ~ ", .libPaths()))\n";
            }
            
            // Source the main script
            wrapper ~= "source('" ~ scriptPath ~ "')\n";
            
            std.file.write(outputPath, wrapper);
            
            // Make executable on POSIX systems
            version(Posix)
            {
                import core.sys.posix.sys.stat;
                auto attrs = getAttributes(outputPath);
                setAttributes(outputPath, attrs | S_IXUSR | S_IXGRP | S_IXOTH);
            }
            
            return true;
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_create_script_wrapper_").field("detail", "Failed to create script wrapper: " ~ e.msg).emit();
            return false;
        }
    }
}

