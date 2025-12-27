module languages.web.css.processors.scss;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import languages.web.css.core.config;
import languages.web.css.processors.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// SCSS/Sass processor using sass CLI
class SCSSProcessor : CSSProcessor
{
    CSSCompileResult compile(
        const(string[]) sources,
        CSSConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        CSSCompileResult result;
        
        // Determine output path
        string outputPath;
        if (!config.output.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, config.output);
        }
        else if (!target.outputPath.empty)
        {
            outputPath = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputPath = buildPath(workspace.options.outputDir, name ~ ".css");
        }
        
        mkdirRecurse(dirName(outputPath));
        
        // Build sass command
        string[] cmd = ["sass"];
        
        // Add include paths
        foreach (includePath; config.includePaths)
        {
            cmd ~= ["--load-path=" ~ includePath];
        }
        
        // Output style
        if (config.minify || config.mode == CSSBuildMode.Production)
        {
            cmd ~= ["--style=compressed"];
        }
        else
        {
            cmd ~= ["--style=expanded"];
        }
        
        // Source maps
        if (config.sourcemap)
        {
            cmd ~= ["--source-map"];
        }
        else
        {
            cmd ~= ["--no-source-map"];
        }
        
        // Input and output
        string entry = config.entry.empty ? sources[0] : config.entry;
        cmd ~= [entry, outputPath];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "SCSS compilation failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        if (config.sourcemap && exists(outputPath ~ ".map"))
        {
            result.outputs ~= outputPath ~ ".map";
        }
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    bool isAvailable()
    {
        auto res = execute(["sass", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "sass";
    }
    
    string getVersion()
    {
        auto res = execute(["sass", "--version"]);
        if (res.status == 0)
            return res.output;
        return "unknown";
    }
}

