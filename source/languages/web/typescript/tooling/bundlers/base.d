module languages.web.typescript.tooling.bundlers.base;

import std.array;
import infrastructure.config.schema.schema;
import engine.caching.actions.action : ActionCache;

// ============================================================================
// TypeScript Types (moved from legacy config.d)
// ============================================================================

/// TypeScript build modes
enum TSBuildMode { Check, Compile, Bundle, Library }

/// TypeScript compiler selection
enum TSCompiler { Auto, TSC, SWC, ESBuild, Webpack, Rollup, Vite, None }

/// Module format for output
enum TSModuleFormat { CommonJS, ESM, UMD, AMD, System, ES2015, ES2020, ESNext, Node16, NodeNext }

/// Module resolution strategy
enum TSModuleResolution { Classic, Node, Node16, NodeNext, Bundler }

/// JSX compilation mode
enum TSXMode { Preserve, React, ReactJSX, ReactJSXDev, ReactNative }

/// Target ECMAScript version
enum TSTarget { ES3, ES5, ES6, ES2015, ES2016, ES2017, ES2018, ES2019, ES2020, ES2021, ES2022, ES2023, ESNext }

/// TypeScript configuration
struct TSConfig
{
    TSBuildMode mode = TSBuildMode.Compile;
    TSCompiler compiler = TSCompiler.Auto;
    string entry;
    string outDir;
    string rootDir;
    TSTarget target = TSTarget.ES2020;
    TSModuleFormat moduleFormat = TSModuleFormat.CommonJS;
    TSModuleResolution moduleResolution = TSModuleResolution.Node;
    bool declaration = false;
    bool declarationMap = false;
    bool sourceMap = false;
    bool strict = true;
    bool allowJs = false;
    bool esModuleInterop = true;
    bool skipLibCheck = true;
    bool isolatedModules = false;
    bool experimentalDecorators = false;
    bool emitDecoratorMetadata = false;
    TSXMode jsx = TSXMode.React;
    string jsxFactory = "React.createElement";
    string jsxFragmentFactory = "React.Fragment";
    bool minify = false;
    string[] external;
    string tsconfig;
    string packageManager = "npm";
    bool installDeps = false;
}

/// TypeScript compilation result
struct TSCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string[] declarations;
    string outputHash;
    bool hadTypeErrors;
    string[] typeErrors;
}

// ============================================================================
// Bundler Interface
// ============================================================================

/// Base interface for TypeScript compilers/bundlers
interface TSBundler
{
    TSCompileResult compile(const(string[]) sources, TSConfig config, in Target target, in WorkspaceConfig workspace);
    bool isAvailable();
    string name() const;
    string getVersion();
    bool supportsTypeCheck();
}

/// Factory for creating TypeScript bundlers
class TSBundlerFactory
{
    static TSBundler create(TSCompiler type, TSConfig config, ActionCache cache = null)
    {
        import languages.web.typescript.tooling.bundlers.tsc;
        import languages.web.typescript.tooling.bundlers.swc;
        import languages.web.typescript.tooling.bundlers.esbuild;
        import languages.web.typescript.tooling.bundlers.webpack;
        import languages.web.typescript.tooling.bundlers.rollup;
        import languages.web.typescript.tooling.bundlers.vite;
        
        final switch (type)
        {
            case TSCompiler.Auto: return createAuto(config, cache);
            case TSCompiler.TSC: return new TSCBundler(cache);
            case TSCompiler.SWC: return new SWCBundler();
            case TSCompiler.ESBuild: return new TSESBuildBundler();
            case TSCompiler.Webpack: return new TSWebpackBundler();
            case TSCompiler.Rollup: return new TSRollupBundler();
            case TSCompiler.Vite: return new TSViteBundler();
            case TSCompiler.None: return new NullTSBundler();
        }
    }
    
    private static TSBundler createAuto(TSConfig config, ActionCache cache)
    {
        import languages.web.typescript.tooling.bundlers.tsc;
        import languages.web.typescript.tooling.bundlers.swc;
        import languages.web.typescript.tooling.bundlers.esbuild;
        import languages.web.typescript.tooling.bundlers.webpack;
        import languages.web.typescript.tooling.bundlers.rollup;
        import languages.web.typescript.tooling.bundlers.vite;
        
        if (config.mode == TSBuildMode.Library)
        {
            if (config.declaration)
            {
                auto rollup = new TSRollupBundler();
                if (rollup.isAvailable()) return rollup;
                auto tsc = new TSCBundler(cache);
                if (tsc.isAvailable()) return tsc;
            }
            else
            {
                auto rollup = new TSRollupBundler();
                if (rollup.isAvailable()) return rollup;
            }
        }
        
        if (config.mode == TSBuildMode.Bundle)
        {
            auto vite = new TSViteBundler();
            if (vite.isAvailable()) return vite;
            auto webpack = new TSWebpackBundler();
            if (webpack.isAvailable()) return webpack;
        }
        
        auto swc = new SWCBundler();
        if (swc.isAvailable()) return swc;
        auto esbuild = new TSESBuildBundler();
        if (esbuild.isAvailable()) return esbuild;
        auto tsc = new TSCBundler(cache);
        if (tsc.isAvailable()) return tsc;
        
        return new NullTSBundler();
    }
}

/// Null bundler - type checks but doesn't compile
class NullTSBundler : TSBundler
{
    TSCompileResult compile(const(string[]) sources, TSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        import languages.web.typescript.tooling.checker;
        import infrastructure.utils.files.hash : FastHash;
        
        TSCompileResult result;
        auto checkResult = TypeChecker.check(sources, config, workspace.root);
        
        if (!checkResult.success)
        {
            result.error = "Type check failed:\n" ~ checkResult.errors.join("\n");
            result.hadTypeErrors = true;
            result.typeErrors = checkResult.errors;
            return result;
        }
        
        result.success = true;
        result.outputs = sources.dup;
        result.outputHash = FastHash.hashStrings(sources);
        return result;
    }
    
    bool isAvailable()
    {
        import languages.web.typescript.tooling.checker;
        return TypeChecker.isTSCAvailable();
    }
    
    string name() const => "none";
    
    string getVersion()
    {
        import languages.web.typescript.tooling.checker;
        return TypeChecker.getTSCVersion();
    }
    
    bool supportsTypeCheck() => true;
}
