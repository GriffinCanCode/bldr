module languages.web.javascript.bundlers.webpack;

import languages.web.javascript.bundlers.base;
import languages.web.javascript.core.config;
import infrastructure.config.schema.schema;
import std.process;
import std.path;
import std.file;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.string;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Webpack bundler - for complex projects with advanced features
class WebpackBundler : Bundler
{
    BundleResult bundle(
        const(string[]) sources,
        JSConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        BundleResult result;
        
        // Check if webpack is available
        if (!isAvailable())
        {
            result.error = "webpack not found. Install: npm install -g webpack webpack-cli";
            return result;
        }
        
        // If custom config file specified, use it
        if (!config.configFile.empty && exists(config.configFile))
        {
            return bundleWithConfigFile(config.configFile, workspace, result);
        }
        
        // Otherwise, generate temporary config
        return bundleWithGeneratedConfig(sources, config, target, workspace, result);
    }
    
    private BundleResult bundleWithConfigFile(
        string configFile,
        in WorkspaceConfig workspace,
        BundleResult result
    )
    {
        structuredLog.debug_("using_webpack_config_").field("detail", "Using webpack config: " ~ configFile).emit();
        
        string[] cmd = ["webpack", "--config", configFile];
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "webpack failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        
        // Parse webpack output to find generated files
        string outputDir = workspace.options.outputDir;
        if (exists(outputDir) && isDir(outputDir))
        {
            foreach (entry; dirEntries(outputDir, SpanMode.shallow))
            {
                if (entry.isFile)
                    result.outputs ~= entry.name;
            }
        }
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    private BundleResult bundleWithGeneratedConfig(
        const(string[]) sources,
        JSConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        BundleResult result
    )
    {
        // Generate temporary webpack config
        string entry = config.entry.empty ? sources[0] : config.entry;
        string outputDir = workspace.options.outputDir;
        mkdirRecurse(outputDir);
        
        string outputFile = target.name.split(":")[$ - 1] ~ ".js";
        
        // Build webpack config as JavaScript
        string webpackConfig = generateWebpackConfig(
            entry,
            outputDir,
            outputFile,
            config
        );
        
        // Write temporary config
        string tempConfig = buildPath(outputDir, ".webpack.config.temp.js");
        std.file.write(tempConfig, webpackConfig);
        
        scope(exit)
        {
            if (exists(tempConfig))
                remove(tempConfig);
        }
        
        structuredLog.debug_("generated_webpack_config_").field("detail", "Generated webpack config: " ~ tempConfig).emit();
        
        // Run webpack
        string[] cmd = ["webpack", "--config", tempConfig];
        auto res = execute(cmd);
        
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
    
    private string generateWebpackConfig(
        string entry,
        string outputDir,
        string outputFile,
        JSConfig config
    )
    {
        string mode = config.minify ? "production" : "development";
        string libraryTarget = outputFormatToLibraryTarget(config.format);
        string target = platformToWebpackTarget(config.platform);
        
        return `
const path = require('path');

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
  externals: ` ~ externalToJSON(config.external) ~ `,
  resolve: {
    extensions: ['.js', '.json', '.jsx']
  }
};
`;
    }
    
    private string outputFormatToLibraryTarget(OutputFormat format)
    {
        final switch (format)
        {
            case OutputFormat.ESM: return "module";
            case OutputFormat.CommonJS: return "commonjs2";
            case OutputFormat.IIFE: return "var";
            case OutputFormat.UMD: return "umd";
        }
    }
    
    private string platformToWebpackTarget(Platform platform)
    {
        final switch (platform)
        {
            case Platform.Browser: return "web";
            case Platform.Node: return "node";
            case Platform.Neutral: return "web";
        }
    }
    
    private string externalToJSON(string[] external)
    {
        if (external.empty)
            return "[]";
        
        return "[" ~ external.map!(e => "'" ~ e ~ "'").join(", ") ~ "]";
    }
    
    bool isAvailable()
    {
        auto res = execute(["webpack", "--version"]);
        return res.status == 0;
    }
    
    string name() const
    {
        return "webpack";
    }
    
    string getVersion()
    {
        auto res = execute(["webpack", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
}

