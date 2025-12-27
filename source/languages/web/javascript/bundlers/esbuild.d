module languages.web.javascript.bundlers.esbuild;

import languages.web.javascript.bundlers.base;
import languages.web.javascript.core.config;
import infrastructure.config.schema.schema;
import std.process;
import std.path;
import std.file;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// esbuild bundler - fastest option for most use cases
class ESBuildBundler : Bundler
{
    BundleResult bundle(
        const(string[]) sources,
        JSConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        BundleResult result;
        
        // Check if esbuild is available
        if (!isAvailable())
        {
            result.error = "esbuild not found. Install: npm install -g esbuild";
            return result;
        }
        
        // Determine entry point
        string entry = config.entry.empty ? sources[0] : config.entry;
        
        // Build output path
        string outputDir = workspace.options.outputDir;
        mkdirRecurse(outputDir);
        
        string outputFile = buildPath(
            outputDir,
            target.name.split(":")[$ - 1] ~ ".js"
        );
        
        // Build esbuild command
        string[] cmd = ["esbuild", entry];
        
        // Bundle mode
        if (config.mode == JSBuildMode.Bundle)
        {
            cmd ~= "--bundle";
        }
        
        // Output file
        cmd ~= "--outfile=" ~ outputFile;
        
        // Platform
        final switch (config.platform)
        {
            case Platform.Browser:
                cmd ~= "--platform=browser";
                break;
            case Platform.Node:
                cmd ~= "--platform=node";
                break;
            case Platform.Neutral:
                cmd ~= "--platform=neutral";
                break;
        }
        
        // Format
        final switch (config.format)
        {
            case OutputFormat.ESM:
                cmd ~= "--format=esm";
                break;
            case OutputFormat.CommonJS:
                cmd ~= "--format=cjs";
                break;
            case OutputFormat.IIFE:
                cmd ~= "--format=iife";
                break;
            case OutputFormat.UMD:
                // esbuild doesn't support UMD, fall back to IIFE
                cmd ~= "--format=iife";
                structuredLog.warning("esbuild_doesnt_support_umd_using_iife_in").emit();
                break;
        }
        
        // Minification
        if (config.minify)
        {
            cmd ~= "--minify";
        }
        
        // Source maps
        if (config.sourcemap)
        {
            cmd ~= "--sourcemap";
        }
        
        // Target ES version
        cmd ~= "--target=" ~ config.target;
        
        // External packages
        foreach (ext; config.external)
        {
            cmd ~= "--external:" ~ ext;
        }
        
        // JSX support
        if (config.jsx)
        {
            cmd ~= "--jsx=transform";
            cmd ~= "--jsx-factory=" ~ config.jsxFactory;
        }
        
        // Custom loaders
        foreach (extension, loader; config.loaders)
        {
            cmd ~= "--loader:" ~ extension ~ "=" ~ loader;
        }
        
        // Additional flags from target
        cmd ~= target.flags;
        
        structuredLog.debug_("running_esbuild_").field("detail", "Running esbuild: " ~ cmd.join(" ")).emit();
        
        // Execute esbuild
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "esbuild failed: " ~ res.output;
            return result;
        }
        
        structuredLog.debug_("esbuild_completed_successfully").emit();
        
        // Success
        result.success = true;
        result.outputs = [outputFile];
        
        if (config.sourcemap && exists(outputFile ~ ".map"))
        {
            result.outputs ~= outputFile ~ ".map";
        }
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    bool isAvailable()
    {
        auto res = execute(["esbuild", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "esbuild";
    }
    
    string getVersion()
    {
        auto res = execute(["esbuild", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
}

