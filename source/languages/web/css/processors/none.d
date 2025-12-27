module languages.web.css.processors.none;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.web.css.core.config;
import languages.web.css.processors.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// No processing - pure CSS passthrough with optional minification
class NoneProcessor : CSSProcessor
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
        
        // Concatenate all source files
        string combinedCSS;
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
            {
                result.error = "CSS file not found: " ~ source;
                return result;
            }
            
            try
            {
                combinedCSS ~= readText(source) ~ "\n";
            }
            catch (Exception e)
            {
                result.error = "Failed to read CSS file " ~ source ~ ": " ~ e.msg;
                return result;
            }
        }
        
        // Optionally minify (basic minification)
        if (config.minify)
        {
            combinedCSS = minifyCSS(combinedCSS);
        }
        
        // Write output
        try
        {
            mkdirRecurse(dirName(outputPath));
            std.file.write(outputPath, combinedCSS);
        }
        catch (Exception e)
        {
            result.error = "Failed to write output: " ~ e.msg;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    bool isAvailable()
    {
        return true; // Always available
    }
    
    string name() const
    {
        return "none";
    }
    
    string getVersion()
    {
        return "1.0";
    }
    
    private string minifyCSS(string css)
    {
        import std.regex;
        import std.string;
        
        // Basic minification - remove comments, extra whitespace
        auto result = css;
        
        // Remove /* */ comments
        result = replaceAll(result, regex(r"/\*[\s\S]*?\*/"), "");
        
        // Remove whitespace around { } : ; ,
        result = replaceAll(result, regex(r"\s*\{\s*"), "{");
        result = replaceAll(result, regex(r"\s*\}\s*"), "}");
        result = replaceAll(result, regex(r"\s*:\s*"), ":");
        result = replaceAll(result, regex(r"\s*;\s*"), ";");
        result = replaceAll(result, regex(r"\s*,\s*"), ",");
        
        // Remove extra line breaks and spaces
        result = replaceAll(result, regex(r"\n+"), "");
        result = replaceAll(result, regex(r"\s+"), " ");
        
        return strip(result);
    }
}

