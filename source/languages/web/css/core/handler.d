module languages.web.css.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.uni : toLower;
import languages.base;
import languages.web.base;
import languages.web.css.processors;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// CSS build handler - leverages BaseWebHandler for common functionality
class CSSHandler : BaseWebHandler
{
    private CSSProcessorType processor = CSSProcessorType.Auto;
    private CSSFramework framework = CSSFramework.None;
    private bool autoprefix = true;
    private bool purge = false;
    private string[] targets;
    private string[] postcssPlugins;
    private string[] includePaths;
    private string[] contentPaths;
    private string tailwindConfig;
    
    override protected string languageId() const pure nothrow => "css";
    override protected TargetLanguage languageEnum() const pure nothrow => TargetLanguage.CSS;
    override protected string[] configKeys() const pure nothrow => ["css", "cssConfig"];
    
    override protected string toolkitNotFoundError() const pure nothrow =>
        "CSS processor not found. Install PostCSS, Sass, or use pure CSS.";
    
    override protected string validateSources(const(string[]) sources, WebConfig config) const => "";
    
    override protected string detectToolkit(WebConfig config) => "css";
    
    override protected LanguageBuildResult buildExecutable(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    ) => compileCSS(target, config, webConfig);
    
    override protected LanguageBuildResult buildLibrary(
        in Target target, in WorkspaceConfig config, WebConfig webConfig, string toolPath
    ) => compileCSS(target, config, webConfig);
    
    override protected LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, WebConfig webConfig)
        => validateCSS(target, config);
    
    override protected string getOutputName(string name, WebConfig config) const pure nothrow => name ~ ".css";
    
    override protected void parseLanguageSpecificConfig(ref WebConfig config, JSONValue json)
    {
        if (auto v = "processor" in json)
        {
            string s = (*v).str.toLower;
            processor = s == "postcss" ? CSSProcessorType.PostCSS :
                       s == "scss" || s == "sass" ? CSSProcessorType.SCSS :
                       s == "less" ? CSSProcessorType.Less :
                       s == "stylus" ? CSSProcessorType.Stylus :
                       s == "none" ? CSSProcessorType.None : CSSProcessorType.Auto;
        }
        
        if (auto v = "framework" in json)
        {
            string s = (*v).str.toLower;
            framework = s == "tailwind" ? CSSFramework.Tailwind :
                       s == "bootstrap" ? CSSFramework.Bootstrap :
                       s == "bulma" ? CSSFramework.Bulma : CSSFramework.None;
        }
        
        if (auto v = "autoprefix" in json) autoprefix = (*v).type == JSONType.true_;
        if (auto v = "purge" in json) purge = (*v).type == JSONType.true_;
        if (auto v = "tailwindConfig" in json) tailwindConfig = (*v).str;
        if (auto v = "targets" in json) targets = (*v).array.map!(e => e.str).array;
        if (auto v = "postcssPlugins" in json) postcssPlugins = (*v).array.map!(e => e.str).array;
        if (auto v = "includePaths" in json) includePaths = (*v).array.map!(e => e.str).array;
        if (auto v = "contentPaths" in json) contentPaths = (*v).array.map!(e => e.str).array;
    }
    
    private LanguageBuildResult compileCSS(in Target target, in WorkspaceConfig config, WebConfig webConfig)
    {
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            result.error = "No source files specified";
            return result;
        }
        
        if (webConfig.mode == WebBuildMode.Production) webConfig.minify = true;
        if (processor == CSSProcessorType.Auto) processor = detectProcessor(target.sources);
        
        auto cssProcessor = CSSProcessorFactory.create(processor);
        
        if (!cssProcessor.isAvailable() && processor != CSSProcessorType.None)
        {
            structuredLog.warning("processor_not_available_using_pure_css").emit();
            cssProcessor = CSSProcessorFactory.create(CSSProcessorType.None);
        }
        
        structuredLog.debug_("using_css_processor_").field("detail", cssProcessor.name()).emit();
        
        string[] inputFiles = collectCSSInputFiles(target.sources, webConfig);
        string[] expectedOutputs = getOutputs(target, config);
        
        string[string] metadata = buildCacheMetadata(webConfig, cssProcessor.name());
        metadata["processor"] = cssProcessor.name();
        metadata["processorVersion"] = cssProcessor.getVersion();
        metadata["autoprefix"] = autoprefix.to!string;
        metadata["purge"] = purge.to!string;
        metadata["framework"] = framework.to!string;
        
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Transform;
        actionId.subId = "css-compile";
        actionId.inputHash = FastHash.hashStrings(inputFiles);
        
        if (getCache().isCached(actionId, inputFiles, metadata) && expectedOutputs.all!(o => exists(o)))
        {
            structuredLog.debug_("__cached_css_").field("detail", "[Cached] CSS: " ~ target.name).emit();
            result.success = true;
            result.outputs = expectedOutputs;
            result.outputHash = FastHash.hashStrings(expectedOutputs);
            return result;
        }
        
        auto compileResult = cssProcessor.compile(target.sources, toCSSConfig(webConfig), target, config);
        getCache().update(actionId, inputFiles, compileResult.outputs, metadata, compileResult.success);
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        result.success = true;
        result.outputs = compileResult.outputs;
        result.outputHash = compileResult.outputHash;
        return result;
    }
    
    private LanguageBuildResult validateCSS(in Target target, in WorkspaceConfig config)
    {
        LanguageBuildResult result;
        foreach (source; target.sources)
        {
            if (!exists(source) || !isFile(source))
            {
                result.error = "CSS file not found: " ~ source;
                return result;
            }
            try { readText(source); }
            catch (Exception e) { result.error = "Failed to read " ~ source; return result; }
        }
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    private CSSProcessorType detectProcessor(const(string[]) sources)
    {
        foreach (source; sources)
        {
            string ext = extension(source);
            if (ext == ".scss" || ext == ".sass") return CSSProcessorType.SCSS;
            if (ext == ".less") return CSSProcessorType.Less;
            if (ext == ".styl" || ext == ".stylus") return CSSProcessorType.Stylus;
        }
        if (!sources.empty)
        {
            string dir = dirName(sources[0]);
            if (exists(buildPath(dir, "postcss.config.js")) ||
                exists(buildPath(dir, "postcss.config.json")) ||
                exists(buildPath(dir, ".postcssrc")))
                return CSSProcessorType.PostCSS;
        }
        return CSSProcessorType.None;
    }
    
    private string[] collectCSSInputFiles(const(string[]) sources, WebConfig config)
    {
        string[] inputs = sources.dup;
        if (!sources.empty)
        {
            string baseDir = dirName(sources[0]);
            foreach (cf; ["postcss.config.js", "postcss.config.json", ".postcssrc", 
                         "tailwind.config.js", ".browserslistrc"])
                if (exists(buildPath(baseDir, cf))) inputs ~= buildPath(baseDir, cf);
            if (processor == CSSProcessorType.SCSS && exists(buildPath(baseDir, "sass-options.json")))
                inputs ~= buildPath(baseDir, "sass-options.json");
        }
        if (!tailwindConfig.empty && exists(tailwindConfig)) inputs ~= tailwindConfig;
        return inputs;
    }
    
    private CSSConfig toCSSConfig(WebConfig config)
    {
        CSSConfig c;
        c.entry = config.entry;
        c.output = config.output;
        c.minify = config.minify;
        c.sourcemap = config.sourcemap;
        c.processor = processor;
        c.framework = framework;
        c.autoprefix = autoprefix;
        c.purge = purge;
        c.targets = targets;
        c.postcssPlugins = postcssPlugins;
        c.includePaths = includePaths;
        c.contentPaths = contentPaths;
        c.tailwindConfig = tailwindConfig;
        return c;
    }
}
