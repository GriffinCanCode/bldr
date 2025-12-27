module languages.web.javascript.bundlers.base;

import infrastructure.config.schema.schema;

// ============================================================================
// JavaScript Types (moved from legacy config.d)
// ============================================================================

/// JavaScript build modes
enum JSBuildMode { Node, Bundle, Library }

/// Bundler type selection
enum BundlerType { Auto, ESBuild, Webpack, Rollup, Vite, None }

/// Output format for bundles
enum OutputFormat { ESM, CommonJS, IIFE, UMD }

/// Target platform
enum Platform { Browser, Node, Neutral }

/// JavaScript configuration
struct JSConfig
{
    JSBuildMode mode = JSBuildMode.Node;
    BundlerType bundler = BundlerType.Auto;
    string entry;
    Platform platform = Platform.Node;
    OutputFormat format = OutputFormat.CommonJS;
    bool minify = false;
    bool sourcemap = false;
    string[] external;
    string configFile;
    string packageManager = "npm";
    bool installDeps = false;
    string target = "es2018";
    bool jsx = false;
    string jsxFactory = "React.createElement";
    string[string] loaders;
}

/// Bundler result
struct BundleResult
{
    bool success;
    string error;
    string[] outputs;
    string outputHash;
}

// ============================================================================
// Bundler Interface
// ============================================================================

/// Base interface for JavaScript bundlers
interface Bundler
{
    BundleResult bundle(const(string[]) sources, JSConfig config, in Target target, in WorkspaceConfig workspace);
    bool isAvailable();
    string name() const;
    string getVersion();
}

/// Factory for creating bundlers
class BundlerFactory
{
    static Bundler create(BundlerType type, JSConfig config)
    {
        import languages.web.javascript.bundlers.esbuild;
        import languages.web.javascript.bundlers.webpack;
        import languages.web.javascript.bundlers.rollup;
        import languages.web.javascript.bundlers.vite;
        
        final switch (type)
        {
            case BundlerType.Auto: return createAuto(config);
            case BundlerType.ESBuild: return new ESBuildBundler();
            case BundlerType.Webpack: return new WebpackBundler();
            case BundlerType.Rollup: return new RollupBundler();
            case BundlerType.Vite: return new ViteBundler();
            case BundlerType.None: return new NullBundler();
        }
    }
    
    private static Bundler createAuto(JSConfig config)
    {
        import languages.web.javascript.bundlers.esbuild;
        import languages.web.javascript.bundlers.webpack;
        import languages.web.javascript.bundlers.rollup;
        import languages.web.javascript.bundlers.vite;
        
        if (config.mode == JSBuildMode.Library)
        {
            auto vite = new ViteBundler();
            if (vite.isAvailable()) return vite;
            auto rollup = new RollupBundler();
            if (rollup.isAvailable()) return rollup;
        }
        
        auto esbuild = new ESBuildBundler();
        if (esbuild.isAvailable()) return esbuild;
        auto vite = new ViteBundler();
        if (vite.isAvailable()) return vite;
        auto webpack = new WebpackBundler();
        if (webpack.isAvailable()) return webpack;
        auto rollup = new RollupBundler();
        if (rollup.isAvailable()) return rollup;
        
        return new NullBundler();
    }
}

/// Null bundler - validates but doesn't bundle
class NullBundler : Bundler
{
    BundleResult bundle(const(string[]) sources, JSConfig config, in Target target, in WorkspaceConfig workspace)
    {
        import std.process : execute;
        import infrastructure.utils.files.hash : FastHash;
        
        BundleResult result;
        foreach (source; sources)
        {
            auto res = execute(["node", "--check", source]);
            if (res.status != 0)
            {
                result.error = "Syntax error in " ~ source ~ ": " ~ res.output;
                return result;
            }
        }
        result.success = true;
        result.outputs = sources.dup;
        result.outputHash = FastHash.hashStrings(sources);
        return result;
    }
    
    bool isAvailable()
    {
        import std.process : execute;
        return execute(["node", "--version"]).status == 0;
    }
    
    string name() const => "none";
    
    string getVersion()
    {
        import std.process : execute;
        auto r = execute(["node", "--version"]);
        return r.status == 0 ? r.output : "unknown";
    }
}
