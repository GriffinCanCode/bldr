module languages.web.css.processors.base;

import infrastructure.config.schema.schema;

// ============================================================================
// CSS Types
// ============================================================================

/// CSS processor type
enum CSSProcessorType { None, PostCSS, SCSS, Less, Stylus, Auto }

/// CSS framework integration
enum CSSFramework { None, Tailwind, Bootstrap, Bulma }

/// CSS build mode
enum CSSBuildMode { Compile, Production, Watch }

/// CSS configuration
struct CSSConfig
{
    CSSProcessorType processor = CSSProcessorType.Auto;
    CSSFramework framework = CSSFramework.None;
    CSSBuildMode mode = CSSBuildMode.Compile;
    string entry;
    string output;
    bool minify = false;
    bool sourcemap = false;
    bool autoprefix = true;
    string[] targets;
    string[] postcssPlugins;
    string[] includePaths;
    string tailwindConfig;
    bool purge = false;
    string[] contentPaths;
}

/// CSS compilation result
struct CSSCompileResult
{
    bool success;
    string error;
    string[] outputs;
    string outputHash;
}

// ============================================================================
// Processor Interface
// ============================================================================

/// Base interface for CSS processors
interface CSSProcessor
{
    /// Compile CSS files
    CSSCompileResult compile(const(string[]) sources, CSSConfig config, in Target target, in WorkspaceConfig workspace);
    
    /// Check if processor is available
    bool isAvailable();
    
    /// Get processor name
    string name() const;
    
    /// Get processor version
    string getVersion();
}

/// Factory for creating CSS processors
class CSSProcessorFactory
{
    static CSSProcessor create(CSSProcessorType processorType)
    {
        import languages.web.css.processors.none;
        import languages.web.css.processors.postcss;
        import languages.web.css.processors.scss;
        
        final switch (processorType)
        {
            case CSSProcessorType.None:  return new NoneProcessor();
            case CSSProcessorType.PostCSS: return new PostCSSProcessor();
            case CSSProcessorType.SCSS: return new SCSSProcessor();
            case CSSProcessorType.Less: return new LessProcessor();
            case CSSProcessorType.Stylus: return new StylusProcessor();
            case CSSProcessorType.Auto: return new NoneProcessor();
        }
    }
}
