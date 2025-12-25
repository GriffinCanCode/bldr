module languages.web.typescript.tooling.bundlers.tsc;

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
import core.time : MonoTime;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging.logger;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;
import engine.workers.integration : TypeScriptWorkerIntegration, TSWorkerCompileOptions, shouldUsePersistentWorker;

/// Official TypeScript compiler (tsc) with per-file action caching
class TSCBundler : TSBundler
{
    private ActionCache actionCache;
    
    this(ActionCache cache = null)
    {
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/typescript/tsc", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
    }
    
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
            result.error = "TypeScript compiler (tsc) not found. Install: npm install -g typescript";
            return result;
        }
        
        // Determine output directory
        string outputDir = config.outDir.empty ? workspace.options.outputDir : config.outDir;
        mkdirRecurse(outputDir);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = "tsc";
        metadata["target"] = config.target.to!string;
        metadata["module"] = config.moduleFormat.to!string;
        metadata["outDir"] = outputDir;
        metadata["declaration"] = config.declaration.to!string;
        metadata["sourceMap"] = config.sourceMap.to!string;
        
        // Add tsconfig as input if it exists
        string[] inputFiles = sources.dup;
        if (!config.tsconfig.empty && exists(config.tsconfig))
            inputFiles ~= config.tsconfig;
        
        // Try persistent worker first (warm V8 instance, 10-40x faster)
        if (shouldUsePersistentWorker("ts-tsc"))
        {
            TSWorkerCompileOptions workerOpts;
            workerOpts.target = targetToString(config.target);
            workerOpts.module_ = moduleToString(config.moduleFormat);
            workerOpts.sourceMap = config.sourceMap;
            workerOpts.declaration = config.declaration;
            workerOpts.strict = config.strict;
            
            auto workerResult = TypeScriptWorkerIntegration.compile(
                sources.dup,
                outputDir,
                workerOpts,
                true
            );
            
            if (workerResult.isOk)
            {
                auto r = workerResult.unwrap();
                if (r.success)
                {
                    Logger.info("  [Warm worker] Compiled " ~ sources.length.to!string ~ 
                               " files in " ~ r.executionTimeMs.to!string ~ "ms" ~
                               " (speedup: " ~ r.estimatedSpeedup().to!string ~ "x)");
                    
                    result.success = true;
                    result.outputs = collectOutputs(sources, config, outputDir);
                    if (config.declaration)
                        result.declarations = collectDeclarations(sources, config, outputDir);
                    result.outputHash = FastHash.hashFiles(result.outputs);
                    return result;
                }
                // Worker compiled but had errors
                result.error = r.output;
                result.hadTypeErrors = r.hasErrors();
                return result;
            }
            Logger.debugLog("Persistent worker unavailable, using direct tsc");
        }
        
        // Fallback: Direct compilation with caching
        return compileDirectWithCache(sources, config, target, workspace, outputDir, inputFiles, metadata);
    }
    
    /// Direct tsc compilation with action caching (fallback path)
    private TSCompileResult compileDirectWithCache(
        const(string[]) sources,
        TSConfig config,
        in Target target,
        in WorkspaceConfig workspace,
        string outputDir,
        string[] inputFiles,
        string[string] metadata
    )
    {
        TSCompileResult result;
        
        // Step 1: Type checking action
        ActionId typeCheckId;
        typeCheckId.targetId = target.name;
        typeCheckId.type = ActionType.Custom;
        typeCheckId.subId = "typecheck";
        typeCheckId.inputHash = FastHash.hashStrings(inputFiles);
        
        bool typeCheckCached = actionCache.isCached(typeCheckId, inputFiles, metadata);
        
        if (!typeCheckCached)
        {
            Logger.debugLog("  [Type checking] " ~ target.name);
            
            string[] checkCmd = ["tsc", "--noEmit"];
            if (!config.tsconfig.empty && exists(config.tsconfig))
                checkCmd ~= ["--project", config.tsconfig];
            else
            {
                checkCmd ~= buildCompilerOptions(config, outputDir);
                checkCmd ~= sources;
            }
            
            auto checkRes = execute(checkCmd, null, Config.none, size_t.max, workspace.root);
            bool typeCheckSuccess = (checkRes.status == 0);
            
            if (!typeCheckSuccess)
            {
                TypeCheckResult checkResult;
                parseTypeScriptOutput(checkRes.output, checkResult);
                result.hadTypeErrors = true;
                result.typeErrors = checkResult.errors;
            }
            
            actionCache.update(typeCheckId, inputFiles, [], metadata, typeCheckSuccess);
        }
        else
            Logger.debugLog("  [Cached] Type checking: " ~ target.name);
        
        // Step 2: Compilation action
        ActionId compileId;
        compileId.targetId = target.name;
        compileId.type = ActionType.Compile;
        compileId.subId = "tsc_emit";
        compileId.inputHash = FastHash.hashStrings(inputFiles);
        
        string[] expectedOutputs = collectOutputs(sources, config, outputDir);
        if (config.declaration)
            expectedOutputs ~= collectDeclarations(sources, config, outputDir);
        
        if (actionCache.isCached(compileId, inputFiles, metadata))
        {
            bool allExist = expectedOutputs.all!(o => exists(o));
            if (allExist)
            {
                Logger.debugLog("  [Cached] TSC compilation: " ~ target.name);
                result.success = true;
                result.outputs = collectOutputs(sources, config, outputDir);
                if (config.declaration)
                    result.declarations = collectDeclarations(sources, config, outputDir);
                result.outputHash = FastHash.hashFiles(result.outputs);
                return result;
            }
        }
        
        // Build and execute tsc command
        string[] cmd = ["tsc"];
        if (!config.tsconfig.empty && exists(config.tsconfig))
        {
            cmd ~= ["--project", config.tsconfig];
            if (!config.outDir.empty)
                cmd ~= ["--outDir", config.outDir];
        }
        else
        {
            cmd ~= buildCompilerOptions(config, outputDir);
            cmd ~= sources;
        }
        
        Logger.debugLog("Compiling with tsc: " ~ cmd.join(" "));
        
        auto res = execute(cmd, null, Config.none, size_t.max, workspace.root);
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "TypeScript compilation failed:\n" ~ res.output;
            result.hadTypeErrors = true;
            
            TypeCheckResult checkResult;
            parseTypeScriptOutput(res.output, checkResult);
            result.typeErrors = checkResult.errors;
            
            actionCache.update(compileId, inputFiles, [], metadata, false);
            return result;
        }
        
        Logger.debugLog("TypeScript compilation successful");
        
        result.outputs = collectOutputs(sources, config, outputDir);
        if (config.declaration)
            result.declarations = collectDeclarations(sources, config, outputDir);
        
        result.success = true;
        result.outputHash = FastHash.hashFiles(result.outputs);
        
        actionCache.update(compileId, inputFiles, result.outputs ~ result.declarations, metadata, true);
        
        return result;
    }
    
    bool isAvailable()
    {
        return TypeChecker.isTSCAvailable();
    }
    
    string name() const
    {
        return "tsc";
    }
    
    string getVersion()
    {
        return TypeChecker.getTSCVersion();
    }
    
    bool supportsTypeCheck()
    {
        return true;
    }
    
    private string[] buildCompilerOptions(TSConfig config, string outputDir)
    {
        string[] args;
        
        // Output directory
        args ~= ["--outDir", outputDir];
        
        // Target
        args ~= ["--target", targetToString(config.target)];
        
        // Module
        args ~= ["--module", moduleToString(config.moduleFormat)];
        
        // Module resolution
        args ~= ["--moduleResolution", moduleResolutionToString(config.moduleResolution)];
        
        // Declaration files
        if (config.declaration)
        {
            args ~= "--declaration";
            if (config.declarationMap)
                args ~= "--declarationMap";
        }
        
        // Source maps
        if (config.sourceMap)
        {
            args ~= "--sourceMap";
            if (config.inlineSourceMap)
                args ~= "--inlineSourceMap";
            if (config.inlineSources)
                args ~= "--inlineSources";
        }
        
        // Strict options
        if (config.strict) args ~= "--strict";
        if (config.alwaysStrict) args ~= "--alwaysStrict";
        if (config.strictNullChecks) args ~= "--strictNullChecks";
        if (config.strictFunctionTypes) args ~= "--strictFunctionTypes";
        if (config.strictBindCallApply) args ~= "--strictBindCallApply";
        if (config.strictPropertyInitialization) args ~= "--strictPropertyInitialization";
        if (config.noImplicitAny) args ~= "--noImplicitAny";
        if (config.noImplicitThis) args ~= "--noImplicitThis";
        if (config.noImplicitReturns) args ~= "--noImplicitReturns";
        if (config.noFallthroughCasesInSwitch) args ~= "--noFallthroughCasesInSwitch";
        if (config.noUnusedLocals) args ~= "--noUnusedLocals";
        if (config.noUnusedParameters) args ~= "--noUnusedParameters";
        
        // Other options
        if (config.skipLibCheck) args ~= "--skipLibCheck";
        if (config.allowJs) args ~= "--allowJs";
        if (config.checkJs) args ~= "--checkJs";
        if (config.esModuleInterop) args ~= "--esModuleInterop";
        if (config.allowSyntheticDefaultImports) args ~= "--allowSyntheticDefaultImports";
        if (config.forceConsistentCasingInFileNames) args ~= "--forceConsistentCasingInFileNames";
        if (config.resolveJsonModule) args ~= "--resolveJsonModule";
        if (config.isolatedModules) args ~= "--isolatedModules";
        if (config.preserveConstEnums) args ~= "--preserveConstEnums";
        if (config.removeComments) args ~= "--removeComments";
        if (config.importHelpers) args ~= "--importHelpers";
        if (config.downlevelIteration) args ~= "--downlevelIteration";
        if (config.emitDecoratorMetadata) args ~= "--emitDecoratorMetadata";
        if (config.experimentalDecorators) args ~= "--experimentalDecorators";
        if (config.noEmit) args ~= "--noEmit";
        if (config.noEmitOnError) args ~= "--noEmitOnError";
        
        // JSX
        if (config.jsx != TSXMode.React || !config.jsxFactory.empty)
        {
            args ~= ["--jsx", jsxModeToString(config.jsx)];
            if (!config.jsxFactory.empty && config.jsx == TSXMode.React)
                args ~= ["--jsxFactory", config.jsxFactory];
            if (!config.jsxFragmentFactory.empty)
                args ~= ["--jsxFragmentFactory", config.jsxFragmentFactory];
            if (!config.jsxImportSource.empty && 
                (config.jsx == TSXMode.ReactJSX || config.jsx == TSXMode.ReactJSXDev))
                args ~= ["--jsxImportSource", config.jsxImportSource];
        }
        
        // Paths
        if (!config.baseUrl.empty)
            args ~= ["--baseUrl", config.baseUrl];
        
        if (!config.rootDir.empty)
            args ~= ["--rootDir", config.rootDir];
        
        return args;
    }
    
    private string[] collectOutputs(const(string[]) sources, TSConfig config, string outputDir)
    {
        string[] outputs;
        
        foreach (source; sources)
        {
            // Convert .ts/.tsx to .js/.jsx
            string baseName = source.baseName.stripExtension;
            string ext = source.extension;
            
            string outExt = ".js";
            if (ext == ".tsx" && config.jsx == TSXMode.Preserve)
                outExt = ".jsx";
            
            string outputFile = buildPath(outputDir, baseName ~ outExt);
            if (exists(outputFile))
                outputs ~= outputFile;
        }
        
        return outputs;
    }
    
    private string[] collectDeclarations(const(string[]) sources, TSConfig config, string outputDir)
    {
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
    
    private static void parseTypeScriptOutput(string output, ref TypeCheckResult result)
    {
        import std.string : split, strip, indexOf;
        
        auto lines = output.split("\n");
        
        foreach (line; lines)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;
            
            if (trimmed.indexOf("error TS") != -1)
            {
                result.errors ~= trimmed;
            }
            else if (trimmed.indexOf("warning TS") != -1)
            {
                result.warnings ~= trimmed;
            }
        }
    }
    
    private static string targetToString(TSTarget target)
    {
        final switch (target)
        {
            case TSTarget.ES3: return "ES3";
            case TSTarget.ES5: return "ES5";
            case TSTarget.ES6: case TSTarget.ES2015: return "ES2015";
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
    
    private static string moduleToString(TSModuleFormat moduleFormat)
    {
        final switch (moduleFormat)
        {
            case TSModuleFormat.CommonJS: return "CommonJS";
            case TSModuleFormat.ESM: case TSModuleFormat.ES2015: return "ES2015";
            case TSModuleFormat.UMD: return "UMD";
            case TSModuleFormat.AMD: return "AMD";
            case TSModuleFormat.System: return "System";
            case TSModuleFormat.ES2020: return "ES2020";
            case TSModuleFormat.ESNext: return "ESNext";
            case TSModuleFormat.Node16: return "Node16";
            case TSModuleFormat.NodeNext: return "NodeNext";
        }
    }
    
    private static string moduleResolutionToString(TSModuleResolution resolution)
    {
        final switch (resolution)
        {
            case TSModuleResolution.Classic: return "Classic";
            case TSModuleResolution.Node: return "Node";
            case TSModuleResolution.Node16: return "Node16";
            case TSModuleResolution.NodeNext: return "NodeNext";
            case TSModuleResolution.Bundler: return "Bundler";
        }
    }
    
    private static string jsxModeToString(TSXMode mode)
    {
        final switch (mode)
        {
            case TSXMode.Preserve: return "preserve";
            case TSXMode.React: return "react";
            case TSXMode.ReactJSX: return "react-jsx";
            case TSXMode.ReactJSXDev: return "react-jsxdev";
            case TSXMode.ReactNative: return "react-native";
        }
    }
}

