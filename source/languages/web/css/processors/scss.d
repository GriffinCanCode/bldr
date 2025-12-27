module languages.web.css.processors.scss;

import std.process : execute;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import languages.web.css.processors.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// SCSS/Sass processor using sass CLI
class SCSSProcessor : CSSProcessor
{
    CSSCompileResult compile(const(string[]) sources, CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        CSSCompileResult result;
        string outputPath = resolveOutputPath(config, target, workspace);
        mkdirRecurse(dirName(outputPath));
        
        string[] cmd = ["sass"];
        
        // Include paths
        foreach (inc; config.includePaths)
            cmd ~= "--load-path=" ~ inc;
        
        // Output style
        cmd ~= (config.minify || config.mode == CSSBuildMode.Production) 
            ? "--style=compressed" : "--style=expanded";
        
        // Source maps
        cmd ~= config.sourcemap ? "--source-map" : "--no-source-map";
        
        // Input and output
        string entry = config.entry.empty ? sources[0] : config.entry;
        cmd ~= [entry, outputPath];
        
        structuredLog.debug_("running_sass").field("detail", cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "SCSS failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        if (config.sourcemap && exists(outputPath ~ ".map"))
            result.outputs ~= outputPath ~ ".map";
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    bool isAvailable() { auto r = execute(["sass", "--version"]); return r.status == 0; }
    string name() const => "sass";
    string getVersion() { auto r = execute(["sass", "--version"]); return r.status == 0 ? r.output : "unknown"; }
    
    private string resolveOutputPath(CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        if (!config.output.empty) return buildPath(workspace.options.outputDir, config.output);
        if (!target.outputPath.empty) return buildPath(workspace.options.outputDir, target.outputPath);
        return buildPath(workspace.options.outputDir, target.name.split(":")[$ - 1] ~ ".css");
    }
}
