module languages.web.javascript.bundlers.rollup;

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

/// Rollup bundler - optimized for library bundles with tree-shaking
class RollupBundler : Bundler
{
    BundleResult bundle(const(string[]) sources, JSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        BundleResult result;
        
        if (!isAvailable())
        {
            result.error = "rollup not found. Install: npm install -g rollup";
            return result;
        }
        
        if (!config.configFile.empty && exists(config.configFile))
            return bundleWithConfigFile(config.configFile, workspace, result);
        
        return bundleWithCLI(sources, config, target, workspace, result);
    }
    
    private BundleResult bundleWithConfigFile(string configFile, in WorkspaceConfig workspace, BundleResult result)
    {
        structuredLog.debug_("using_rollup_config").field("detail", configFile).emit();
        
        auto res = execute(["rollup", "-c", configFile]);
        if (res.status != 0)
        {
            result.error = "rollup failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        string outputDir = workspace.options.outputDir;
        if (exists(outputDir) && isDir(outputDir))
            foreach (entry; dirEntries(outputDir, SpanMode.shallow))
                if (entry.isFile && entry.name.endsWith(".js")) result.outputs ~= entry.name;
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    private BundleResult bundleWithCLI(const(string[]) sources, JSConfig config, in Target target, in WorkspaceConfig workspace, BundleResult result)
    {
        string entry = config.entry.empty ? sources[0] : config.entry;
        string outputDir = workspace.options.outputDir;
        mkdirRecurse(outputDir);
        string outputFile = buildPath(outputDir, target.name.split(":")[$ - 1] ~ ".js");
        
        string[] cmd = ["rollup", entry, "--file", outputFile, "--format", formatToRollup(config.format)];
        if (config.sourcemap) cmd ~= "--sourcemap";
        foreach (ext; config.external) cmd ~= ["--external", ext];
        
        structuredLog.debug_("running_rollup").field("detail", cmd.join(" ")).emit();
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "rollup failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        if (config.sourcemap && exists(outputFile ~ ".map"))
            result.outputs ~= outputFile ~ ".map";
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    private string formatToRollup(OutputFormat f)
    {
        final switch (f)
        {
            case OutputFormat.ESM: return "es";
            case OutputFormat.CommonJS: return "cjs";
            case OutputFormat.IIFE: return "iife";
            case OutputFormat.UMD: return "umd";
        }
    }
    
    bool isAvailable() { return execute(["rollup", "--version"]).status == 0; }
    string name() const => "rollup";
    string getVersion()
    {
        auto r = execute(["rollup", "--version"]);
        return r.status == 0 ? r.output.strip : "unknown";
    }
}
