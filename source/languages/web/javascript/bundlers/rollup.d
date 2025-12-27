module languages.web.javascript.bundlers.rollup;

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

/// Rollup bundler - optimized for library bundles with tree-shaking
class RollupBundler : Bundler
{
    BundleResult bundle(
        const(string[]) sources,
        JSConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        BundleResult result;
        
        // Check if rollup is available
        if (!isAvailable())
        {
            result.error = "rollup not found. Install: npm install -g rollup";
            return result;
        }
        
        // If custom config file specified, use it
        if (!config.configFile.empty && exists(config.configFile))
        {
            return bundleWithConfigFile(config.configFile, workspace, result);
        }
        
        // Otherwise, use CLI mode
        return bundleWithCLI(sources, config, target, workspace, result);
    }
    
    private BundleResult bundleWithConfigFile(
        string configFile,
        in WorkspaceConfig workspace,
        BundleResult result
    )
    {
        structuredLog.debug_("using_rollup_config_").field("detail", "Using rollup config: " ~ configFile).emit();
        
        string[] cmd = ["rollup", "-c", configFile];
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "rollup failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        
        // Parse rollup output to find generated files
        string outputDir = workspace.options.outputDir;
        if (exists(outputDir) && isDir(outputDir))
        {
            foreach (entry; dirEntries(outputDir, SpanMode.shallow))
            {
                if (entry.isFile && entry.name.endsWith(".js"))
                    result.outputs ~= entry.name;
            }
        }
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    private BundleResult bundleWithCLI(
        const(string[]) sources,
        JSConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        BundleResult result
    )
    {
        string entry = config.entry.empty ? sources[0] : config.entry;
        string outputDir = workspace.options.outputDir;
        mkdirRecurse(outputDir);
        
        string outputFile = buildPath(
            outputDir,
            target.name.split(":")[$ - 1] ~ ".js"
        );
        
        // Build rollup command
        string[] cmd = ["rollup", entry];
        
        // Output file
        cmd ~= "--file";
        cmd ~= outputFile;
        
        // Format
        cmd ~= "--format";
        cmd ~= outputFormatToRollup(config.format);
        
        // Source maps
        if (config.sourcemap)
        {
            cmd ~= "--sourcemap";
        }
        
        // External packages
        foreach (ext; config.external)
        {
            cmd ~= "--external";
            cmd ~= ext;
        }
        
        // Plugins for minification (requires @rollup/plugin-terser)
        if (config.minify)
        {
            structuredLog.warning("rollup_minification_requires_rollupplugi").emit();
        }
        
        structuredLog.debug_("running_rollup_").field("detail", "Running rollup: " ~ cmd.join(" ")).emit();
        
        // Execute rollup
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "rollup failed: " ~ res.output;
            return result;
        }
        
        structuredLog.debug_("rollup_completed_successfully").emit();
        
        result.success = true;
        result.outputs = [outputFile];
        
        if (config.sourcemap && exists(outputFile ~ ".map"))
        {
            result.outputs ~= outputFile ~ ".map";
        }
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    private string outputFormatToRollup(OutputFormat format)
    {
        final switch (format)
        {
            case OutputFormat.ESM: return "es";
            case OutputFormat.CommonJS: return "cjs";
            case OutputFormat.IIFE: return "iife";
            case OutputFormat.UMD: return "umd";
        }
    }
    
    bool isAvailable()
    {
        auto res = execute(["rollup", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "rollup";
    }
    
    string getVersion()
    {
        auto res = execute(["rollup", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
}

