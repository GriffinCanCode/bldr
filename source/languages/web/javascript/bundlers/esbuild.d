module languages.web.javascript.bundlers.esbuild;

import std.process : execute;
import std.path;
import std.file;
import std.algorithm;
import std.array;
import std.string : strip;
import languages.web.javascript.bundlers.base;
import infrastructure.config.schema.schema;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// esbuild bundler - fastest option for most use cases
class ESBuildBundler : Bundler
{
    BundleResult bundle(const(string[]) sources, JSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        BundleResult result;
        
        if (!isAvailable())
        {
            result.error = "esbuild not found. Install: npm install -g esbuild";
            return result;
        }
        
        string entry = config.entry.empty ? sources[0] : config.entry;
        string outputDir = workspace.options.outputDir;
        mkdirRecurse(outputDir);
        string outputFile = buildPath(outputDir, target.name.split(":")[$ - 1] ~ ".js");
        
        string[] cmd = ["esbuild", entry];
        
        if (config.mode == JSBuildMode.Bundle) cmd ~= "--bundle";
        cmd ~= "--outfile=" ~ outputFile;
        
        final switch (config.platform)
        {
            case Platform.Browser: cmd ~= "--platform=browser"; break;
            case Platform.Node: cmd ~= "--platform=node"; break;
            case Platform.Neutral: cmd ~= "--platform=neutral"; break;
        }
        
        final switch (config.format)
        {
            case OutputFormat.ESM: cmd ~= "--format=esm"; break;
            case OutputFormat.CommonJS: cmd ~= "--format=cjs"; break;
            case OutputFormat.IIFE: cmd ~= "--format=iife"; break;
            case OutputFormat.UMD: cmd ~= "--format=iife"; break;  // esbuild doesn't support UMD
        }
        
        if (config.minify) cmd ~= "--minify";
        if (config.sourcemap) cmd ~= "--sourcemap";
        cmd ~= "--target=" ~ config.target;
        
        foreach (ext; config.external) cmd ~= "--external:" ~ ext;
        
        if (config.jsx)
        {
            cmd ~= "--jsx=transform";
            cmd ~= "--jsx-factory=" ~ config.jsxFactory;
        }
        
        foreach (extension, loader; config.loaders)
            cmd ~= "--loader:" ~ extension ~ "=" ~ loader;
        
        cmd ~= target.flags;
        
        structuredLog.debug_("running_esbuild").field("detail", cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "esbuild failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        if (config.sourcemap && exists(outputFile ~ ".map"))
            result.outputs ~= outputFile ~ ".map";
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    bool isAvailable() { return execute(["esbuild", "--version"]).status == 0; }
    string name() const => "esbuild";
    string getVersion()
    {
        auto r = execute(["esbuild", "--version"]);
        return r.status == 0 ? r.output.strip : "unknown";
    }
}
