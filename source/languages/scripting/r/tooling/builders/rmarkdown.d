module languages.scripting.r.tooling.builders.rmarkdown;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import infrastructure.config.schema.schema;
import languages.scripting.r.core.config;
import languages.scripting.r.tooling.builders.base;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// RMarkdown builder - renders RMarkdown documents
class RMarkdownBuilder : RBuilder
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
            result.error = "No RMarkdown files specified";
            return result;
        }
        
        string rmdFile = target.sources[0];
        
        // Get output format
        string outputFormat = getOutputFormat(rConfig.rmarkdown.format, rConfig.rmarkdown.customFormat);
        
        // Build R command to render RMarkdown
        string[] rArgs = ["-e"];
        
        // Build render command
        string renderCmd = "rmarkdown::render('" ~ rmdFile ~ "'";
        renderCmd ~= ", output_format='" ~ outputFormat ~ "'";
        
        if (!rConfig.rmarkdown.outputFile.empty)
        {
            renderCmd ~= ", output_file='" ~ rConfig.rmarkdown.outputFile ~ "'";
        }
        
        if (rConfig.rmarkdown.selfContained)
        {
            renderCmd ~= ", self_contained=TRUE";
        }
        
        if (rConfig.rmarkdown.keepIntermediates)
        {
            renderCmd ~= ", clean=FALSE";
        }
        
        // Add parameters if specified
        if (!rConfig.rmarkdown.params.empty)
        {
            string[] paramList;
            foreach (key, value; rConfig.rmarkdown.params)
            {
                paramList ~= key ~ "='" ~ value ~ "'";
            }
            renderCmd ~= ", params=list(" ~ paramList.join(", ") ~ ")";
        }
        
        renderCmd ~= ")";
        rArgs ~= renderCmd;
        
        string[] cmd = [rCmd] ~ rArgs;
        
        structuredLog.info("rendering_rmarkdown_").field("detail", "Rendering RMarkdown: " ~ rmdFile).emit();
        structuredLog.debug_("command_").field("detail", "Command: " ~ cmd.join(" ")).emit();
        
        auto env = prepareEnvironment(rConfig);
        auto res = execute(cmd, env, Config.none, size_t.max, config.root);
        
        if (res.status != 0)
        {
            result.error = "RMarkdown rendering failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = getOutputs(target, config, rConfig);
        result.outputHash = FastHash.hashStrings(target.sources);
        
        structuredLog.info("rmarkdown_rendered_successfully").emit();
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config, in RConfig rConfig)
    {
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else if (!rConfig.rmarkdown.outputFile.empty)
        {
            outputs ~= buildPath(config.options.outputDir, rConfig.rmarkdown.outputFile);
        }
        else
        {
            // Determine extension from format
            string ext = getOutputExtension(rConfig.rmarkdown.format);
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(config.options.outputDir, name ~ ext);
        }
        
        return outputs;
    }
    
    override bool validate(in Target target, in RConfig rConfig)
    {
        if (target.sources.empty)
        {
            structuredLog.error("no_rmarkdown_file_specified").emit();
            return false;
        }
        
        string rmdFile = target.sources[0];
        if (!exists(rmdFile))
        {
            structuredLog.error("rmarkdown_file_not_found_").field("detail", "RMarkdown file not found: " ~ rmdFile).emit();
            return false;
        }
        
        // Check file extension
        if (!rmdFile.endsWith(".Rmd") && !rmdFile.endsWith(".rmd"))
        {
            structuredLog.warning("file_does_not_have_rmd_extension_").field("detail", "File does not have .Rmd extension: " ~ rmdFile).emit();
        }
        
        return true;
    }
    
    /// Get output format string for rmarkdown::render
    private string getOutputFormat(RMarkdownFormat format, string customFormat)
    {
        if (format == RMarkdownFormat.Custom && !customFormat.empty)
        {
            return customFormat;
        }
        
        final switch (format)
        {
            case RMarkdownFormat.HTML:
                return "html_document";
            case RMarkdownFormat.PDF:
                return "pdf_document";
            case RMarkdownFormat.Word:
                return "word_document";
            case RMarkdownFormat.Markdown:
                return "md_document";
            case RMarkdownFormat.RevealJS:
                return "revealjs::revealjs_presentation";
            case RMarkdownFormat.Beamer:
                return "beamer_presentation";
            case RMarkdownFormat.Custom:
                return "html_document"; // fallback
        }
    }
    
    /// Get output file extension for format
    private string getOutputExtension(RMarkdownFormat format)
    {
        final switch (format)
        {
            case RMarkdownFormat.HTML:
            case RMarkdownFormat.RevealJS:
                return ".html";
            case RMarkdownFormat.PDF:
            case RMarkdownFormat.Beamer:
                return ".pdf";
            case RMarkdownFormat.Word:
                return ".docx";
            case RMarkdownFormat.Markdown:
                return ".md";
            case RMarkdownFormat.Custom:
                return ".html"; // fallback
        }
    }
    
    /// Prepare environment variables
    private string[string] prepareEnvironment(const ref RConfig config)
    {
        import std.process : environment;
        
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        foreach (key, value; config.rEnv)
            env[key] = value;
        
        if (!config.libPaths.empty)
        {
            env["R_LIBS_USER"] = config.libPaths.join(":");
        }
        
        return env;
    }
}

