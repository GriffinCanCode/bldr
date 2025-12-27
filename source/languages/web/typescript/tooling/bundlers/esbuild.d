module languages.web.typescript.tooling.bundlers.esbuild;

import languages.web.typescript.tooling.bundlers.base;
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

/// esbuild bundler - TypeScript optimized
class TSESBuildBundler : TSBundler
{
    TSCompileResult compile(
        const(string[]) sources,
        TSConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        TSCompileResult result;
        
        if (!isAvailable())
        {
            result.error = "esbuild not found. Install: npm install -g esbuild";
            return result;
        }
        
        // Type check first if needed (esbuild doesn't type check)
        if (config.mode != TSBuildMode.Check && TypeChecker.isTSCAvailable())
        {
            auto checkResult = TypeChecker.check(sources, config, workspace.root);
            if (!checkResult.success)
            {
                if (config.noEmitOnError)
                {
                    result.error = "Type checking failed:\n" ~ checkResult.errors.join("\n");
                    result.hadTypeErrors = true;
                    result.typeErrors = checkResult.errors;
                    return result;
                }
                else
                {
                    structuredLog.warning("type_checking_failed_but_continuing_with").emit();
                    result.hadTypeErrors = true;
                    result.typeErrors = checkResult.errors;
                }
            }
        }
        
        // Determine entry point
        string entry = config.entry.empty ? sources[0] : config.entry;
        
        // Determine output directory
        string outputDir = config.outDir.empty ? workspace.options.outputDir : config.outDir;
        mkdirRecurse(outputDir);
        
        string outputFile;
        
        if (config.mode == TSBuildMode.Bundle)
        {
            // Bundle mode - single output
            string baseName = target.name.split(":")[$ - 1];
            outputFile = buildPath(outputDir, baseName ~ ".js");
            
            auto bundleResult = bundle(entry, outputFile, config, workspace);
            if (!bundleResult)
            {
                result.error = "esbuild bundling failed";
                return result;
            }
            
            result.outputs = [outputFile];
            if (config.sourceMap && exists(outputFile ~ ".map"))
                result.outputs ~= outputFile ~ ".map";
        }
        else
        {
            // Compile mode - one output per source
            result.outputs = compileMultiple(sources, config, outputDir, workspace.root);
            if (result.outputs.empty)
            {
                result.error = "esbuild compilation failed";
                return result;
            }
        }
        
        result.success = true;
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        // Generate declarations if needed
        if (config.declaration && config.mode == TSBuildMode.Library)
        {
            result.declarations = generateDeclarationsWithTSC(sources, config, outputDir, workspace.root);
        }
        
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
    
    bool supportsTypeCheck()
    {
        return false; // esbuild is transpile-only
    }
    
    private bool bundle(string entry, string output, TSConfig config, in WorkspaceConfig workspace)
    {
        string[] cmd = ["esbuild", entry, "--bundle"];
        
        cmd ~= ["--outfile=" ~ output];
        
        // Format
        cmd ~= ["--format=" ~ formatToString(config.moduleFormat)];
        
        // Target
        cmd ~= ["--target=" ~ targetToString(config.target)];
        
        // Platform (default to neutral for TypeScript)
        cmd ~= "--platform=neutral";
        
        // Minify
        if (config.minify)
            cmd ~= "--minify";
        
        // Source maps
        if (config.sourceMap)
        {
            if (config.inlineSourceMap)
                cmd ~= "--sourcemap=inline";
            else
                cmd ~= "--sourcemap";
        }
        
        // External packages
        foreach (ext; config.external)
        {
            cmd ~= "--external:" ~ ext;
        }
        
        // JSX support
        if (config.jsx != TSXMode.Preserve)
        {
            cmd ~= "--jsx=" ~ jsxModeToESBuild(config.jsx);
            if (config.jsx == TSXMode.React && config.jsxFactory != "React.createElement")
                cmd ~= "--jsx-factory=" ~ config.jsxFactory;
            if (config.jsx == TSXMode.React && config.jsxFragmentFactory != "React.Fragment")
                cmd ~= "--jsx-fragment=" ~ config.jsxFragmentFactory;
            if ((config.jsx == TSXMode.ReactJSX || config.jsx == TSXMode.ReactJSXDev) && !config.jsxImportSource.empty)
                cmd ~= "--jsx-import-source=" ~ config.jsxImportSource;
        }
        
        // TypeScript-specific
        cmd ~= "--loader:.ts=ts";
        cmd ~= "--loader:.tsx=tsx";
        
        // Resolve extensions
        cmd ~= "--resolve-extensions=.ts,.tsx,.js,.jsx,.json";
        
        structuredLog.debug_("bundling_with_esbuild_").field("detail", "Bundling with esbuild: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, workspace.root);
        
        if (res.status != 0)
        {
            structuredLog.error("esbuild_bundling_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    private string[] compileMultiple(const(string[]) sources, TSConfig config, string outputDir, string workspaceRoot)
    {
        string[] outputs;
        
        foreach (source; sources)
        {
            string baseName = source.baseName.stripExtension;
            string outputFile = buildPath(outputDir, baseName ~ ".js");
            
            string[] cmd = ["esbuild", source];
            
            cmd ~= ["--outfile=" ~ outputFile];
            cmd ~= ["--format=" ~ formatToString(config.moduleFormat)];
            cmd ~= ["--target=" ~ targetToString(config.target)];
            cmd ~= "--platform=neutral";
            
            if (config.minify)
                cmd ~= "--minify";
            
            if (config.sourceMap)
            {
                if (config.inlineSourceMap)
                    cmd ~= "--sourcemap=inline";
                else
                    cmd ~= "--sourcemap";
            }
            
            // JSX support
            if (config.jsx != TSXMode.Preserve)
            {
                cmd ~= "--jsx=" ~ jsxModeToESBuild(config.jsx);
            }
            
            cmd ~= "--loader:.ts=ts";
            cmd ~= "--loader:.tsx=tsx";
            
            structuredLog.debug_("compiling_with_esbuild_").field("detail", "Compiling with esbuild: " ~ cmd.join(" ")).emit();
            
            auto res = execute(cmd, null, Config.none, size_t.max, workspaceRoot);
            
            if (res.status != 0)
            {
                structuredLog.error("esbuild_compilation_failed_for_").field("detail", "esbuild compilation failed for " ~ source).emit();
                structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
                return [];
            }
            
            outputs ~= outputFile;
            if (config.sourceMap && exists(outputFile ~ ".map"))
                outputs ~= outputFile ~ ".map";
        }
        
        return outputs;
    }
    
    private string[] generateDeclarationsWithTSC(const(string[]) sources, TSConfig config, string outputDir, string workspaceRoot)
    {
        if (!TypeChecker.isTSCAvailable())
        {
            structuredLog.warning("tsc_not_available_cannot_generate_declar").emit();
            return [];
        }
        
        string[] cmd = [
            "tsc",
            "--emitDeclarationOnly",
            "--outDir", outputDir,
            "--declaration"
        ];
        
        if (config.declarationMap)
            cmd ~= "--declarationMap";
        
        cmd ~= sources;
        
        structuredLog.debug_("generating_declarations_with_tsc_").field("detail", "Generating declarations with tsc: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, workspaceRoot);
        
        if (res.status != 0)
        {
            structuredLog.warning("failed_to_generate_declaration_files_").field("detail", "Failed to generate declaration files: " ~ res.output).emit();
            return [];
        }
        
        string[] declarations;
        foreach (source; sources)
        {
            string baseName = source.baseName.stripExtension;
            string declFile = buildPath(outputDir, baseName ~ ".d.ts");
            if (exists(declFile))
                declarations ~= declFile;
        }
        
        return declarations;
    }
    
    private static string formatToString(TSModuleFormat moduleFormat)
    {
        final switch (moduleFormat)
        {
            case TSModuleFormat.CommonJS: return "cjs";
            case TSModuleFormat.ESM:
            case TSModuleFormat.ES2015:
            case TSModuleFormat.ES2020:
            case TSModuleFormat.ESNext:
            case TSModuleFormat.Node16:
            case TSModuleFormat.NodeNext:
                return "esm";
            case TSModuleFormat.UMD:
            case TSModuleFormat.AMD:
            case TSModuleFormat.System:
                return "iife"; // esbuild doesn't support these, fall back to IIFE
        }
    }
    
    private static string targetToString(TSTarget target)
    {
        final switch (target)
        {
            case TSTarget.ES3: return "es3";
            case TSTarget.ES5: return "es5";
            case TSTarget.ES6: case TSTarget.ES2015: return "es2015";
            case TSTarget.ES2016: return "es2016";
            case TSTarget.ES2017: return "es2017";
            case TSTarget.ES2018: return "es2018";
            case TSTarget.ES2019: return "es2019";
            case TSTarget.ES2020: return "es2020";
            case TSTarget.ES2021: return "es2021";
            case TSTarget.ES2022: return "es2022";
            case TSTarget.ES2023: return "es2023";
            case TSTarget.ESNext: return "esnext";
        }
    }
    
    private static string jsxModeToESBuild(TSXMode mode)
    {
        final switch (mode)
        {
            case TSXMode.Preserve: return "preserve";
            case TSXMode.React: return "transform";
            case TSXMode.ReactJSX: return "automatic";
            case TSXMode.ReactJSXDev: return "automatic";
            case TSXMode.ReactNative: return "preserve";
        }
    }
}

