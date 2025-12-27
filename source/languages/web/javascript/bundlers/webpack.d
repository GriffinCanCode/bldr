module languages.web.javascript.bundlers.webpack;

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

/// Webpack bundler - for complex projects with advanced features
class WebpackBundler : Bundler
{
    BundleResult bundle(const(string[]) sources, JSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        BundleResult result;
        
        if (!isAvailable())
        {
            result.error = "webpack not found. Install: npm install -g webpack webpack-cli";
            return result;
        }
        
        if (!config.configFile.empty && exists(config.configFile))
            return bundleWithConfigFile(config.configFile, workspace, result);
        
        return bundleWithGeneratedConfig(sources, config, target, workspace, result);
    }
    
    private BundleResult bundleWithConfigFile(string configFile, in WorkspaceConfig workspace, BundleResult result)
    {
        structuredLog.debug_("using_webpack_config").field("detail", configFile).emit();
        
        auto res = execute(["webpack", "--config", configFile]);
        if (res.status != 0)
        {
            result.error = "webpack failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        string outputDir = workspace.options.outputDir;
        if (exists(outputDir) && isDir(outputDir))
            foreach (entry; dirEntries(outputDir, SpanMode.shallow))
                if (entry.isFile) result.outputs ~= entry.name;
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    private BundleResult bundleWithGeneratedConfig(const(string[]) sources, JSConfig config, in Target target, in WorkspaceConfig workspace, BundleResult result)
    {
        string entry = config.entry.empty ? sources[0] : config.entry;
        string outputDir = workspace.options.outputDir;
        mkdirRecurse(outputDir);
        string outputFile = target.name.split(":")[$ - 1] ~ ".js";
        
        string webpackConfig = generateConfig(entry, outputDir, outputFile, config);
        string tempConfig = buildPath(outputDir, ".webpack.config.temp.js");
        std.file.write(tempConfig, webpackConfig);
        scope(exit) if (exists(tempConfig)) remove(tempConfig);
        
        structuredLog.debug_("generated_webpack_config").field("detail", tempConfig).emit();
        
        auto res = execute(["webpack", "--config", tempConfig]);
        if (res.status != 0)
        {
            result.error = "webpack failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.outputs = [buildPath(outputDir, outputFile)];
        result.outputHash = FastHash.hashFiles(result.outputs);
        return result;
    }
    
    private string generateConfig(string entry, string outputDir, string outputFile, JSConfig config)
    {
        string mode = config.minify ? "production" : "development";
        string libraryTarget = formatToLibrary(config.format);
        string target = platformToTarget(config.platform);
        
        return `const path = require('path');
module.exports = {
  mode: '` ~ mode ~ `',
  entry: '` ~ absolutePath(entry) ~ `',
  output: {
    path: '` ~ absolutePath(outputDir) ~ `',
    filename: '` ~ outputFile ~ `',
    libraryTarget: '` ~ libraryTarget ~ `'
  },
  target: '` ~ target ~ `',
  devtool: ` ~ (config.sourcemap ? "'source-map'" : "false") ~ `,
  externals: [` ~ config.external.map!(e => "'" ~ e ~ "'").join(", ") ~ `],
  resolve: { extensions: ['.js', '.json', '.jsx'] }
};`;
    }
    
    private string formatToLibrary(OutputFormat f)
    {
        final switch (f)
        {
            case OutputFormat.ESM: return "module";
            case OutputFormat.CommonJS: return "commonjs2";
            case OutputFormat.IIFE: return "var";
            case OutputFormat.UMD: return "umd";
        }
    }
    
    private string platformToTarget(Platform p)
    {
        final switch (p)
        {
            case Platform.Browser: return "web";
            case Platform.Node: return "node";
            case Platform.Neutral: return "web";
        }
    }
    
    bool isAvailable() { return execute(["webpack", "--version"]).status == 0; }
    string name() const => "webpack";
    string getVersion()
    {
        auto r = execute(["webpack", "--version"]);
        return r.status == 0 ? r.output.strip : "unknown";
    }
}
