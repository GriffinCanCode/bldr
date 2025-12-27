module languages.web.typescript.tooling.bundlers.rollup;

import languages.web.typescript.tooling.bundlers.base;
import languages.web.typescript.core.config;
import languages.web.typescript.tooling.checker;
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

/// Rollup bundler for TypeScript - optimized for library bundles with tree-shaking
/// Best for: Library development, tree-shaking optimization, minimal bundle sizes
class TSRollupBundler : TSBundler
{
    TSCompileResult compile(
        const(string[]) sources,
        TSConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        TSCompileResult result;
        
        // Check if rollup is available
        if (!isAvailable())
        {
            result.error = "rollup not found. Install: npm install -g rollup @rollup/plugin-typescript";
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
                structuredLog.warning("type_check_failed_but_continuing_with_ro").emit();
            }
        }
        
        // Check for existing rollup.config.js/ts
        string rollupConfig = detectRollupConfig(sources);
        if (!rollupConfig.empty)
        {
            structuredLog.debug_("detected_rollup_config_").field("detail", "Detected rollup config: " ~ rollupConfig).emit();
            return bundleWithConfigFile(rollupConfig, workspace, result);
        }
        
        // Generate temporary config for precise control
        return bundleWithGeneratedConfig(sources, config, target, workspace, result);
    }
    
    private TSCompileResult bundleWithConfigFile(
        string configFile,
        in WorkspaceConfig workspace,
        ref TSCompileResult result
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
    
    private TSCompileResult bundleWithGeneratedConfig(
        const(string[]) sources,
        TSConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        ref TSCompileResult result
    )
    {
        string entry = config.entry.empty ? sources[0] : config.entry;
        string outputDir = config.outDir.empty ? workspace.options.outputDir : config.outDir;
        mkdirRecurse(outputDir);
        
        string outputFile = buildPath(
            outputDir,
            target.name.split(":")[$ - 1] ~ ".js"
        );
        
        // Generate temporary rollup config
        string rollupConfig = generateRollupConfig(
            entry,
            outputDir,
            outputFile,
            config
        );
        
        // Write temporary config in project root
        string projectDir = dirName(absolutePath(entry));
        string tempConfig = buildPath(projectDir, "rollup.config.temp.mjs");
        std.file.write(tempConfig, rollupConfig);
        
        scope(exit)
        {
            if (exists(tempConfig))
                remove(tempConfig);
        }
        
        structuredLog.debug_("generated_rollup_config_").field("detail", "Generated rollup config: " ~ tempConfig).emit();
        
        // Run rollup
        string[] cmd = ["rollup", "-c", tempConfig];
        auto res = execute(cmd, null, Config.none, size_t.max, projectDir);
        
        if (res.status != 0)
        {
            result.error = "rollup failed: " ~ res.output;
            return result;
        }
        
        structuredLog.debug_("rollup_completed_successfully").emit();
        
        result.success = true;
        result.outputs = [outputFile];
        
        // Check for source maps
        if (config.sourceMap && exists(outputFile ~ ".map"))
        {
            result.outputs ~= outputFile ~ ".map";
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
    
    private string generateRollupConfig(
        string entry,
        string outputDir,
        string outputFile,
        TSConfig config
    )
    {
        string format = moduleFormatToRollup(config.moduleFormat);
        string tsTarget = targetToCompilerOption(config.target);
        
        // Build external packages array
        string externalsArray = "[]";
        if (!config.external.empty)
        {
            externalsArray = "[" ~ config.external.map!(e => "'" ~ e ~ "'").join(", ") ~ "]";
        }
        
        // TypeScript plugin options
        string tsPluginOptions = `{
    tsconfig: false,
    compilerOptions: {
      target: '` ~ tsTarget ~ `',
      module: 'ESNext',
      declaration: ` ~ (config.declaration ? "true" : "false") ~ `,
      declarationMap: ` ~ (config.declarationMap ? "true" : "false") ~ `,
      declarationDir: '` ~ absolutePath(outputDir) ~ `',
      sourceMap: ` ~ (config.sourceMap ? "true" : "false") ~ `,
      esModuleInterop: ` ~ (config.esModuleInterop ? "true" : "false") ~ `,
      strict: ` ~ (config.strict ? "true" : "false") ~ `,
      skipLibCheck: ` ~ (config.skipLibCheck ? "true" : "false") ~ `
    }
  }`;
        
        // Conditionally add terser plugin for minification
        string plugins = `typescript(` ~ tsPluginOptions ~ `)`;
        if (config.minify)
        {
            plugins = `typescript(` ~ tsPluginOptions ~ `), terser()`;
        }
        
        return `import typescript from '@rollup/plugin-typescript';` ~ 
               (config.minify ? "\nimport { terser } from 'rollup-plugin-terser';" : "") ~ `

export default {
  input: '` ~ absolutePath(entry) ~ `',
  output: {
    file: '` ~ absolutePath(outputFile) ~ `',
    format: '` ~ format ~ `',
    sourcemap: ` ~ (config.sourceMap ? "true" : "false") ~ `,
    exports: 'auto'
  },
  external: ` ~ externalsArray ~ `,
  plugins: [` ~ plugins ~ `]
};
`;
    }
    
    private string moduleFormatToRollup(TSModuleFormat format)
    {
        final switch (format)
        {
            case TSModuleFormat.CommonJS: return "cjs";
            case TSModuleFormat.ESM: return "es";
            case TSModuleFormat.ES2015: return "es";
            case TSModuleFormat.ES2020: return "es";
            case TSModuleFormat.ESNext: return "es";
            case TSModuleFormat.UMD: return "umd";
            case TSModuleFormat.AMD: return "amd";
            case TSModuleFormat.System: return "system";
            case TSModuleFormat.Node16: return "cjs";
            case TSModuleFormat.NodeNext: return "cjs";
        }
    }
    
    private string targetToCompilerOption(TSTarget target)
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
    
    private string detectRollupConfig(const(string[]) sources)
    {
        if (sources.empty)
            return "";
        
        string projectDir = dirName(sources[0]);
        
        // Check for rollup.config.ts (preferred for TypeScript projects)
        string tsConfig = buildPath(projectDir, "rollup.config.ts");
        if (exists(tsConfig))
            return tsConfig;
        
        // Check for rollup.config.mjs (ESM)
        string mjsConfig = buildPath(projectDir, "rollup.config.mjs");
        if (exists(mjsConfig))
            return mjsConfig;
        
        // Check for rollup.config.js
        string jsConfig = buildPath(projectDir, "rollup.config.js");
        if (exists(jsConfig))
            return jsConfig;
        
        return "";
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
    
    bool supportsTypeCheck()
    {
        // rollup with @rollup/plugin-typescript can do type checking
        return false; // Note: plugin transpiles, but doesn't type-check by default
    }
}

