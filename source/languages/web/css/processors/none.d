module languages.web.css.processors.none;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.regex;
import std.string;
import languages.web.css.processors.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;

/// No processing - pure CSS passthrough with optional minification
class NoneProcessor : CSSProcessor
{
    CSSCompileResult compile(const(string[]) sources, CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        CSSCompileResult result;
        
        string outputPath = resolveOutputPath(config, target, workspace);
        
        // Concatenate all source files
        string combinedCSS;
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
            {
                result.error = "CSS file not found: " ~ source;
                return result;
            }
            
            try { combinedCSS ~= readText(source) ~ "\n"; }
            catch (Exception e)
            {
                result.error = "Failed to read " ~ source ~ ": " ~ e.msg;
                return result;
            }
        }
        
        // Optionally minify
        if (config.minify)
            combinedCSS = minifyCSS(combinedCSS);
        
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
    
    bool isAvailable() => true;
    string name() const => "none";
    string getVersion() => "1.0";
    
    private string resolveOutputPath(CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        if (!config.output.empty)
            return buildPath(workspace.options.outputDir, config.output);
        if (!target.outputPath.empty)
            return buildPath(workspace.options.outputDir, target.outputPath);
        return buildPath(workspace.options.outputDir, target.name.split(":")[$ - 1] ~ ".css");
    }
    
    private string minifyCSS(string css)
    {
        auto result = css;
        result = replaceAll(result, regex(r"/\*[\s\S]*?\*/"), "");
        result = replaceAll(result, regex(r"\s*\{\s*"), "{");
        result = replaceAll(result, regex(r"\s*\}\s*"), "}");
        result = replaceAll(result, regex(r"\s*:\s*"), ":");
        result = replaceAll(result, regex(r"\s*;\s*"), ";");
        result = replaceAll(result, regex(r"\s*,\s*"), ",");
        result = replaceAll(result, regex(r"\n+"), "");
        result = replaceAll(result, regex(r"\s+"), " ");
        return strip(result);
    }
}
