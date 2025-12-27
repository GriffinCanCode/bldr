module languages.scripting.ruby.tooling.builders.script;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.tooling.builders.base;
import languages.scripting.ruby.tooling.info;
import languages.base.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security.validation;

/// Script builder for Ruby scripts and simple applications
class ScriptBuilder : Builder
{
    override BuildResult build(
        in string[] sources,
        in RubyConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        BuildResult result;
        
        if (sources.empty)
        {
            result.error = "No source files specified";
            return result;
        }
        
        // Validate syntax
        string[] errors;
        if (!SyntaxChecker.check(sources, errors))
        {
            result.error = "Syntax errors:\n" ~ errors.join("\n");
            return result;
        }
        
        // Create executable wrapper
        auto outputPath = getOutputPath(target, workspace);
        auto mainFile = sources[0];
        
        if (!createWrapper(mainFile, outputPath, config, workspace.root))
        {
            result.error = "Failed to create executable wrapper";
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashStrings(sources);
        
        return result;
    }
    
    override bool isAvailable()
    {
        return RubyTools.isRubyAvailable();
    }
    
    override string name() const
    {
        return "Ruby Script Builder";
    }
    
    private string getOutputPath(in Target target, in WorkspaceConfig workspace)
    {
        if (!target.outputPath.empty)
        {
            return buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            return buildPath(workspace.options.outputDir, name);
        }
    }
    
    private bool createWrapper(
        string mainFile,
        string outputPath,
        const RubyConfig config,
        string projectRoot
    )
    {
        auto outputDir = dirName(outputPath);
        
        // Ensure output directory exists
        if (!exists(outputDir))
        {
            try
            {
                mkdirRecurse(outputDir);
            }
            catch (Exception e)
            {
                structuredLog.error("failed_to_create_output_directory_").field("detail", "Failed to create output directory: " ~ e.msg).emit();
                return false;
            }
        }
        
        // Build wrapper script
        string wrapper = "#!/usr/bin/env ruby\n";
        wrapper ~= "# frozen_string_literal: true\n\n";
        
        // Add load paths
        if (!config.loadPath.empty)
        {
            foreach (path; config.loadPath)
            {
                wrapper ~= "$LOAD_PATH.unshift('" ~ path ~ "')\n";
            }
            wrapper ~= "\n";
        }
        
        // Add Bundler setup if configured
        if (config.requireBundler && config.bundler.enabled)
        {
            wrapper ~= "require 'bundler/setup'\n";
            wrapper ~= "Bundler.require(:default)\n\n";
        }
        
        // Load main file
        auto relPath = relativePath(mainFile, outputDir);
        wrapper ~= "load File.join(File.dirname(__FILE__), '..', '" ~ relPath ~ "')\n";
        
        // Write wrapper
        try
        {
            std.file.write(outputPath, wrapper);
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_write_wrapper_").field("detail", "Failed to write wrapper: " ~ e.msg).emit();
            return false;
        }
        
        // Make executable on POSIX systems
        version(Posix)
        {
            // Validate path before using it with external command
            if (!SecurityValidator.isPathSafe(outputPath))
            {
                structuredLog.error("unsafe_output_path_detected_").field("detail", "Unsafe output path detected: " ~ outputPath).emit();
                return false;
            }
            
            // Use safe array form instead of executeShell
            auto res = execute(["chmod", "+x", outputPath]);
            if (res.status != 0)
            {
                structuredLog.warning("failed_to_make_wrapper_executable_").field("detail", "Failed to make wrapper executable: " ~ res.output).emit();
            }
        }
        
        structuredLog.info("created_executable_wrapper_").field("detail", "Created executable wrapper: " ~ outputPath).emit();
        return true;
    }
}


