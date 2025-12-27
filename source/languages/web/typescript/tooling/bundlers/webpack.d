module languages.web.typescript.tooling.bundlers.webpack;

import languages.web.typescript.tooling.bundlers.base;
import languages.web.typescript.tooling.checker;
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

/// Webpack bundler for TypeScript - advanced features and plugin ecosystem
/// Best for: Complex projects with advanced webpack features, legacy projects, custom loaders
class TSWebpackBundler : TSBundler
{
    TSCompileResult compile(
        const(string[]) sources,
        TSConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        TSCompileResult result;
        
        // Check if webpack is available
        if (!isAvailable())
        {
            result.error = "webpack not found. Install: npm install -g webpack webpack-cli ts-loader";
            return result;
        }
        
        // Type check first if strict mode
        if (config.strict)
        {
            auto checkResult = TypeChecker.check(sources, config, workspace.root);
            if (!checkResult.success)
            {
                result.hadTypeErrors = true;
                result.typeErrors = checkResult.errors;
                structuredLog.warning("type_check_failed_but_continuing_with_we").emit();
            }
        }
        
        // If custom tsconfig specified, use it; otherwise check for webpack.config.js/ts
        if (!config.tsconfig.empty && exists(config.tsconfig))
        {
            // Webpack will automatically pick up tsconfig.json via ts-loader
            return bundleWithWebpack(sources, config, target, workspace, result);
        }
        
        // Check for existing webpack.config.js/ts
        string webpackConfig = detectWebpackConfig(sources);
        if (!webpackConfig.empty)
        {
            structuredLog.debug_("detected_webpack_config_").field("detail", "Detected webpack config: " ~ webpackConfig).emit();
            return bundleWithConfigFile(webpackConfig, workspace, result);
        }
        
        // Generate temporary config
        return bundleWithGeneratedConfig(sources, config, target, workspace, result);
    }
    
    private TSCompileResult bundleWithConfigFile(
        string configFile,
        in WorkspaceConfig workspace,
        ref TSCompileResult result
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
                {
                    result.outputs ~= entry.name;
                    if (entry.name.endsWith(".d.ts"))
                        result.declarations ~= entry.name;
                }
            }
        }
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    private TSCompileResult bundleWithWebpack(
        const(string[]) sources,
        TSConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        ref TSCompileResult result
    )
    {
        return bundleWithGeneratedConfig(sources, config, target, workspace, result);
    }
    
    private TSCompileResult bundleWithGeneratedConfig(
        const(string[]) sources,
        TSConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        ref TSCompileResult result
    )
    {
        // Generate temporary webpack config
        string entry = config.entry.empty ? sources[0] : config.entry;
        string outputDir = config.outDir.empty ? workspace.options.outputDir : config.outDir;
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
        
        // Check for source maps
        if (config.sourceMap && exists(buildPath(outputDir, outputFile ~ ".map")))
        {
            result.outputs ~= buildPath(outputDir, outputFile ~ ".map");
        }
        
        // Check for declaration files if enabled
        if (config.declaration)
        {
            string declFile = buildPath(outputDir, baseName(outputFile, ".js") ~ ".d.ts");
            if (exists(declFile))
            {
                result.declarations ~= declFile;
                result.outputs ~= declFile;
            }
        }
        
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        return result;
    }
    
    private string generateWebpackConfig(
        string entry,
        string outputDir,
        string outputFile,
        TSConfig config
    )
    {
        string mode = config.minify ? "production" : "development";
        string libraryTarget = moduleFormatToLibraryTarget(config.moduleFormat);
        string tsTarget = targetToString(config.target);
        string moduleFormat = moduleFormatToString(config.moduleFormat);
        
        // Generate ts-loader options
        string tsLoaderOptions = `{
          transpileOnly: false,
          compilerOptions: {
            target: '` ~ tsTarget ~ `',
            module: '` ~ moduleFormat ~ `',
            declaration: ` ~ (config.declaration ? "true" : "false") ~ `,
            declarationMap: ` ~ (config.declarationMap ? "true" : "false") ~ `,
            sourceMap: ` ~ (config.sourceMap ? "true" : "false") ~ `,
            esModuleInterop: ` ~ (config.esModuleInterop ? "true" : "false") ~ `,
            strict: ` ~ (config.strict ? "true" : "false") ~ `
          }
        }`;
        
        string externalsSection = "";
        if (!config.external.empty)
        {
            externalsSection = `
  externals: [` ~ config.external.map!(e => "'" ~ e ~ "'").join(", ") ~ `],`;
        }
        
        return `
const path = require('path');

module.exports = {
  mode: '` ~ mode ~ `',
  entry: '` ~ absolutePath(entry) ~ `',
  output: {
    path: '` ~ absolutePath(outputDir) ~ `',
    filename: '` ~ outputFile ~ `',
    libraryTarget: '` ~ libraryTarget ~ `'
  },` ~ externalsSection ~ `
  devtool: ` ~ (config.sourceMap ? "'source-map'" : "false") ~ `,
  resolve: {
    extensions: ['.ts', '.tsx', '.js', '.jsx', '.json']
  },
  module: {
    rules: [
      {
        test: /\.tsx?$/,
        use: {
          loader: 'ts-loader',
          options: ` ~ tsLoaderOptions ~ `
        },
        exclude: /node_modules/
      }
    ]
  }
};
`;
    }
    
    private string moduleFormatToLibraryTarget(TSModuleFormat format)
    {
        final switch (format)
        {
            case TSModuleFormat.CommonJS: return "commonjs2";
            case TSModuleFormat.ESM: return "module";
            case TSModuleFormat.ES2015: return "module";
            case TSModuleFormat.ES2020: return "module";
            case TSModuleFormat.ESNext: return "module";
            case TSModuleFormat.UMD: return "umd";
            case TSModuleFormat.AMD: return "amd";
            case TSModuleFormat.System: return "system";
            case TSModuleFormat.Node16: return "commonjs2";
            case TSModuleFormat.NodeNext: return "commonjs2";
        }
    }
    
    private string targetToString(TSTarget target)
    {
        final switch (target)
        {
            case TSTarget.ES3: return "ES3";
            case TSTarget.ES5: return "ES5";
            case TSTarget.ES6: return "ES6";
            case TSTarget.ES2015: return "ES2015";
            case TSTarget.ES2016: return "ES2016";
            case TSTarget.ES2017: return "ES2017";
            case TSTarget.ES2018: return "ES2018";
            case TSTarget.ES2019: return "ES2019";
            case TSTarget.ES2020: return "ES2020";
            case TSTarget.ES2021: return "ES2021";
            case TSTarget.ES2022: return "ES2022";
            case TSTarget.ES2023: return "ES2023";
            case TSTarget.ESNext: return "ESNext";
        }
    }
    
    private string moduleFormatToString(TSModuleFormat format)
    {
        final switch (format)
        {
            case TSModuleFormat.CommonJS: return "CommonJS";
            case TSModuleFormat.ESM: return "ESNext";
            case TSModuleFormat.ES2015: return "ES2015";
            case TSModuleFormat.ES2020: return "ES2020";
            case TSModuleFormat.ESNext: return "ESNext";
            case TSModuleFormat.UMD: return "UMD";
            case TSModuleFormat.AMD: return "AMD";
            case TSModuleFormat.System: return "System";
            case TSModuleFormat.Node16: return "Node16";
            case TSModuleFormat.NodeNext: return "NodeNext";
        }
    }
    
    private string detectWebpackConfig(const(string[]) sources)
    {
        if (sources.empty)
            return "";
        
        string projectDir = dirName(sources[0]);
        
        // Check for webpack.config.ts (preferred for TypeScript projects)
        string tsConfig = buildPath(projectDir, "webpack.config.ts");
        if (exists(tsConfig))
            return tsConfig;
        
        // Check for webpack.config.js
        string jsConfig = buildPath(projectDir, "webpack.config.js");
        if (exists(jsConfig))
            return jsConfig;
        
        return "";
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
    
    bool supportsTypeCheck()
    {
        // webpack with ts-loader can do type checking
        return true;
    }
}

