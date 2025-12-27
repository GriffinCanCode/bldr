module languages.scripting.r.tooling.builders.shiny;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import infrastructure.config.schema.schema;
import languages.scripting.r.core.config;
import languages.scripting.r.tooling.builders.base;
import languages.scripting.r.tooling.checkers;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Shiny app builder - validates and prepares Shiny applications
class RShinyBuilder : RBuilder
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
            result.error = "No source files specified for Shiny app";
            return result;
        }
        
        string appDir = dirName(target.sources[0]);
        
        // Check for app.R or server.R/ui.R
        bool hasAppR = exists(buildPath(appDir, "app.R"));
        bool hasServerUI = exists(buildPath(appDir, "server.R")) && 
                          exists(buildPath(appDir, "ui.R"));
        
        if (!hasAppR && !hasServerUI)
        {
            result.error = "Shiny app must have either app.R or server.R/ui.R";
            return result;
        }
        
        // Validate Shiny app syntax
        if (rConfig.validateSyntax)
        {
            if (!validateSyntax(target.sources, rCmd, config.root))
            {
                result.error = "Syntax validation failed";
                return result;
            }
        }
        
        // Create launcher script
        auto outputs = getOutputs(target, config, rConfig);
        if (!outputs.empty)
        {
            if (!createShinyLauncher(appDir, outputs[0], rConfig))
            {
                result.error = "Failed to create Shiny launcher";
                return result;
            }
        }
        
        structuredLog.info("shiny_app_validated_successfully_at_").field("detail", "Shiny app validated successfully at: " ~ appDir).emit();
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config, in RConfig rConfig)
    {
        string[] outputs;
        auto name = target.name.split(":")[$ - 1];
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            // Shiny apps produce a launcher script
            outputs ~= buildPath(config.options.outputDir, name);
        }
        
        return outputs;
    }
    
    override bool validate(in Target target, in RConfig rConfig)
    {
        if (target.sources.empty)
        {
            structuredLog.error("no_source_files_specified_for_shiny_app").emit();
            return false;
        }
        
        string appDir = dirName(target.sources[0]);
        
        // Check for valid Shiny structure
        bool hasAppR = exists(buildPath(appDir, "app.R"));
        bool hasServerUI = exists(buildPath(appDir, "server.R")) && 
                          exists(buildPath(appDir, "ui.R"));
        
        if (!hasAppR && !hasServerUI)
        {
            structuredLog.error("shiny_app_must_have_either_appr_or_serve").emit();
            return false;
        }
        
        return true;
    }
    
    /// Create Shiny launcher script
    private bool createShinyLauncher(string appDir, string outputPath, const ref RConfig config)
    {
        try
        {
            // Ensure output directory exists
            string outDir = dirName(outputPath);
            if (!exists(outDir))
                mkdirRecurse(outDir);
            
            // Create launcher script
            string launcher = "#!/usr/bin/env " ~ config.rExecutable ~ "\n\n";
            
            // Add library paths if specified
            if (!config.libPaths.empty)
            {
                launcher ~= ".libPaths(c(" ~ config.libPaths.map!(p => `"` ~ p ~ `"`).join(",") ~ ", .libPaths()))\n\n";
            }
            
            // Check if Shiny is installed
            launcher ~= "if (!requireNamespace('shiny', quietly = TRUE)) {\n";
            launcher ~= "  stop('Shiny package is required. Install with: install.packages(\"shiny\")')\n";
            launcher ~= "}\n\n";
            
            // Run the Shiny app
            launcher ~= "shiny::runApp(\n";
            launcher ~= "  appDir = '" ~ appDir ~ "',\n";
            launcher ~= "  host = '" ~ config.shiny.host ~ "',\n";
            launcher ~= "  port = " ~ config.shiny.port.to!string ~ ",\n";
            launcher ~= "  launch.browser = " ~ (config.shiny.launchBrowser ? "TRUE" : "FALSE") ~ ",\n";
            launcher ~= "  display.mode = '" ~ config.shiny.displayMode ~ "'\n";
            launcher ~= ")\n";
            
            std.file.write(outputPath, launcher);
            
            // Make executable on POSIX systems
            version(Posix)
            {
                import core.sys.posix.sys.stat;
                auto attrs = getAttributes(outputPath);
                setAttributes(outputPath, attrs | S_IXUSR | S_IXGRP | S_IXOTH);
            }
            
            structuredLog.info("created_shiny_launcher_").field("detail", "Created Shiny launcher: " ~ outputPath).emit();
            return true;
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_create_shiny_launcher_").field("detail", "Failed to create Shiny launcher: " ~ e.msg).emit();
            return false;
        }
    }
}

