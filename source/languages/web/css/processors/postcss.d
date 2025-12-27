module languages.web.css.processors.postcss;

import std.process : execute;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string : strip;
import languages.web.css.processors.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// PostCSS processor
class PostCSSProcessor : CSSProcessor
{
    CSSCompileResult compile(const(string[]) sources, CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        CSSCompileResult result;
        string outputPath = resolveOutputPath(config, target, workspace);
        mkdirRecurse(dirName(outputPath));
        
        string entry = config.entry.empty ? sources[0] : config.entry;
        string[] cmd = ["postcss", entry, "-o", outputPath];
        if (config.sourcemap) cmd ~= "--map";
        
        structuredLog.debug_("running_postcss").field("detail", cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "PostCSS failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        if (config.sourcemap && exists(outputPath ~ ".map"))
            result.outputs ~= outputPath ~ ".map";
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    bool isAvailable() { auto r = execute(["postcss", "--version"]); return r.status == 0; }
    string name() const => "postcss";
    string getVersion() { auto r = execute(["postcss", "--version"]); return r.status == 0 ? r.output : "unknown"; }
    
    private string resolveOutputPath(CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        if (!config.output.empty) return buildPath(workspace.options.outputDir, config.output);
        if (!target.outputPath.empty) return buildPath(workspace.options.outputDir, target.outputPath);
        return buildPath(workspace.options.outputDir, target.name.split(":")[$ - 1] ~ ".css");
    }
}

/// Less CSS processor
class LessProcessor : CSSProcessor
{
    CSSCompileResult compile(const(string[]) sources, CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        CSSCompileResult result;
        string outputPath = resolveOutputPath(config, target, workspace);
        mkdirRecurse(dirName(outputPath));
        
        string entry = config.entry.empty ? sources[0] : config.entry;
        string[] cmd = ["lessc", entry, outputPath, "--math=parens-division"];
        if (config.minify) cmd ~= "--clean-css";
        if (config.sourcemap) cmd ~= "--source-map";
        
        structuredLog.debug_("running_less").field("detail", cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Less failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        if (config.sourcemap && exists(outputPath ~ ".map"))
            result.outputs ~= outputPath ~ ".map";
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    bool isAvailable() { auto r = execute(["lessc", "--version"]); return r.status == 0; }
    string name() const => "less";
    string getVersion() { auto r = execute(["lessc", "--version"]); return r.status == 0 ? r.output.strip() : "unknown"; }
    
    private string resolveOutputPath(CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        if (!config.output.empty) return buildPath(workspace.options.outputDir, config.output);
        if (!target.outputPath.empty) return buildPath(workspace.options.outputDir, target.outputPath);
        return buildPath(workspace.options.outputDir, target.name.split(":")[$ - 1] ~ ".css");
    }
}

/// Stylus processor
class StylusProcessor : CSSProcessor
{
    CSSCompileResult compile(const(string[]) sources, CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        CSSCompileResult result;
        string outputPath = resolveOutputPath(config, target, workspace);
        mkdirRecurse(dirName(outputPath));
        
        string entry = config.entry.empty ? sources[0] : config.entry;
        string[] cmd = ["stylus", entry, "--out", outputPath, "--include-css"];
        if (config.minify) cmd ~= "--compress";
        if (config.sourcemap) cmd ~= "--sourcemap";
        
        structuredLog.debug_("running_stylus").field("detail", cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Stylus failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputPath];
        if (config.sourcemap && exists(outputPath ~ ".map"))
            result.outputs ~= outputPath ~ ".map";
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    bool isAvailable() { auto r = execute(["stylus", "--version"]); return r.status == 0; }
    string name() const => "stylus";
    string getVersion() { auto r = execute(["stylus", "--version"]); return r.status == 0 ? r.output.strip() : "unknown"; }
    
    private string resolveOutputPath(CSSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        if (!config.output.empty) return buildPath(workspace.options.outputDir, config.output);
        if (!target.outputPath.empty) return buildPath(workspace.options.outputDir, target.outputPath);
        return buildPath(workspace.options.outputDir, target.name.split(":")[$ - 1] ~ ".css");
    }
}
