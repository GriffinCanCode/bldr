module languages.web.css.processors.postcss;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string : strip;
import languages.web.css.core.config;
import languages.web.css.processors.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// PostCSS processor
class PostCSSProcessor : CSSProcessor
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
        
        // Build postcss command
        string[] cmd = ["postcss"];
        
        // Entry
        string entry = config.entry.empty ? sources[0] : config.entry;
        cmd ~= [entry];
        
        // Output
        cmd ~= ["-o", outputPath];
        
        // Source maps
        if (config.sourcemap)
        {
            cmd ~= ["--map"];
        }
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "PostCSS compilation failed: " ~ res.output;
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
        auto res = execute(["postcss", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "postcss";
    }
    
    string getVersion()
    {
        auto res = execute(["postcss", "--version"]);
        if (res.status == 0)
            return res.output;
        return "unknown";
    }
}

/// Less CSS processor
class LessProcessor : CSSProcessor
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
        
        // Build lessc command
        string[] cmd = ["lessc"];
        
        // Entry point
        string entry = config.entry.empty ? sources[0] : config.entry;
        cmd ~= [entry];
        
        // Output
        cmd ~= [outputPath];
        
        // Compression/minification
        if (config.minify)
            cmd ~= ["--clean-css"];
        
        // Source maps
        if (config.sourcemap)
            cmd ~= ["--source-map"];
        
        // Strict math (recommended)
        cmd ~= ["--math=parens-division"];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Less compilation failed: " ~ res.output;
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
        auto res = execute(["lessc", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "less";
    }
    
    string getVersion()
    {
        auto res = execute(["lessc", "--version"]);
        if (res.status == 0)
            return res.output.strip();
        return "unknown";
    }
}

/// Stylus processor
class StylusProcessor : CSSProcessor
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
        
        // Build stylus command
        string[] cmd = ["stylus"];
        
        // Entry point
        string entry = config.entry.empty ? sources[0] : config.entry;
        cmd ~= [entry];
        
        // Output
        cmd ~= ["--out", outputPath];
        
        // Compression
        if (config.minify)
            cmd ~= ["--compress"];
        
        // Source maps
        if (config.sourcemap)
            cmd ~= ["--sourcemap"];
        
        // Include CSS (allow importing .css files)
        cmd ~= ["--include-css"];
        
        structuredLog.debug_("running_").field("detail", "Running: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Stylus compilation failed: " ~ res.output;
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
        auto res = execute(["stylus", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "stylus";
    }
    
    string getVersion()
    {
        auto res = execute(["stylus", "--version"]);
        if (res.status == 0)
            return res.output.strip();
        return "unknown";
    }
}

