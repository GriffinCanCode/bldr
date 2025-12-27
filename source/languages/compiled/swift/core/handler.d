module languages.compiled.swift.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import languages.compiled.base;
import languages.compiled.swift.config;
import languages.compiled.swift.analysis.manifest;
import languages.compiled.swift.managers.spm;
import languages.compiled.swift.managers.toolchain;
import languages.compiled.swift.tooling;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Advanced Swift build handler with SPM, Xcode, and cross-compilation support
class SwiftHandler : BaseCompiledLanguageHandler
{
    private SwiftConfig _config;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override protected string languageId() const pure nothrow => "swift";
    
    override protected TargetLanguage languageType() const pure nothrow => TargetLanguage.Swift;
    
    override protected string[] configKeys() const pure nothrow => ["swift", "swiftConfig"];
    
    override protected string toolchainNotFoundError() const pure nothrow =>
        "Swift toolchain not available. Install from https://swift.org or Xcode from the Apple App Store.";
    
    override protected string detectToolchain(in Target target, in WorkspaceConfig config) @system
    {
        _config = parseSwiftConfig(target);
        
        if (!SwiftToolchainManager.isSwiftAvailable())
            return "";
        
        // Auto-detect Package.swift
        if (_config.manifest.manifestPath.empty || !exists(_config.manifest.manifestPath))
        {
            auto manifestPath = PackageManifestParser.findManifest(target.sources.dup);
            if (!manifestPath.empty)
            {
                structuredLog.debug_("found_packageswift_").field("detail", "Found Package.swift: " ~ manifestPath).emit();
                _config.manifest.manifestPath = manifestPath;
                _config.packagePath = dirName(manifestPath);
                
                auto manifest = PackageManifestParser.parse(manifestPath);
                if (manifest.isValid)
                    _config.manifest = manifest.manifest;
            }
        }
        
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        return ExecutableDetector.findInPath("swift");
    }
    
    // ===== Build Methods =====
    
    override protected LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        if (_config.projectType != SwiftProjectType.Executable)
            _config.projectType = SwiftProjectType.Executable;
        
        if (_config.product.empty && !target.sources.empty)
        {
            // Look for main.swift
            foreach (source; target.sources)
            {
                if (baseName(source) == "main.swift")
                {
                    _config.product = stripExtension(baseName(source));
                    break;
                }
            }
            if (_config.product.empty)
                _config.product = target.name.split(":")[$ - 1];
        }
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        if (_config.projectType != SwiftProjectType.Library)
            _config.projectType = SwiftProjectType.Library;
        
        if (_config.product.empty)
            _config.product = target.name.split(":")[$ - 1];
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildAndRunTests(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.mode = SPMBuildMode.Test;
        
        if (_config.buildConfig == SwiftBuildConfig.Release)
            _config.buildConfig = SwiftBuildConfig.Debug;
        
        _config.enableTestability = true;
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.mode = SPMBuildMode.Custom;
        return compileTarget(target, config);
    }
    
    // ===== Tooling =====
    
    override protected bool shouldFormat(in Target target) const @system => _config.swiftformat.enabled;
    override protected bool shouldLint(in Target target) const @system => _config.swiftlint.enabled;
    
    override protected CompiledLanguageResult runFormatter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!SwiftFormatRunner.isAvailable())
        {
            structuredLog.warning("swiftformat_not_available_skipping").emit();
            return result;
        }
        
        structuredLog.info("running_swiftformat").emit();
        
        auto runner = new SwiftFormatRunner();
        auto res = runner.format(
            target.sources.dup,
            _config.swiftformat.configFile,
            _config.swiftformat.checkOnly,
            _config.swiftformat.inPlace
        );
        
        if (res.status != 0)
        {
            structuredLog.warning("swiftformat_had_issues_").field("detail", "Issues: " ~ res.output).emit();
            result.hadWarnings = true;
            result.warnings = [res.output];
        }
        else
            structuredLog.info("code_formatted_successfully").emit();
        
        return result;
    }
    
    override protected CompiledLanguageResult runLinter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!SwiftLintRunner.isAvailable())
        {
            structuredLog.warning("swiftlint_not_available_skipping").emit();
            return result;
        }
        
        structuredLog.info("running_swiftlint").emit();
        
        auto runner = new SwiftLintRunner();
        auto res = runner.lint(
            target.sources.dup,
            _config.swiftlint.configFile,
            _config.swiftlint.strict,
            _config.swiftlint.enableRules,
            _config.swiftlint.disableRules
        );
        
        if (res.status != 0)
        {
            result.hadLintIssues = true;
            foreach (line; res.output.split("\n"))
            {
                if (line.canFind("warning:"))
                    result.lintIssues ~= line;
                else if (line.canFind("error:"))
                    result.lintIssues ~= line;
            }
        }
        
        return result;
    }
    
    override protected string getOutputName(string name, TargetType type) const pure nothrow
    {
        string ext = "";
        string prefix = "";
        
        // Access libraryType via direct struct field access for pure compatibility
        auto libType = _config.build.libraryType;
        
        version(OSX)
        {
            if (type == TargetType.Library)
            {
                prefix = "lib";
                ext = libType == SwiftLibraryType.Static ? ".a" : ".dylib";
            }
        }
        else version(linux)
        {
            if (type == TargetType.Library)
            {
                prefix = "lib";
                ext = libType == SwiftLibraryType.Static ? ".a" : ".so";
            }
        }
        else version(Windows)
        {
            if (type == TargetType.Library)
                ext = libType == SwiftLibraryType.Static ? ".lib" : ".dll";
            else if (type == TargetType.Executable || type == TargetType.Test)
                ext = ".exe";
        }
        
        return prefix ~ name ~ ext;
    }
    
    // ===== Private Implementation =====
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config) @system
    {
        auto builder = SwiftBuilderFactory.create(_config);
        
        if (!builder.isAvailable())
            return errorResult("Swift builder '" ~ builder.name() ~ "' not available. Install from https://swift.org or Xcode.");
        
        structuredLog.debug_("using_swift_builder_").field("detail", "Using Swift builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        // Resolve dependencies if using SPM
        if (!_config.manifest.manifestPath.empty && !_config.skipUpdate)
        {
            if (!resolveDependencies())
                structuredLog.warning("failed_to_resolve_deps_continuing").emit();
        }
        
        auto compileResult = builder.build(target.sources, _config, target, config);
        
        if (!compileResult.success)
            return errorResult(compileResult.error);
        
        if (compileResult.warnings.length > 0)
            reportWarnings(compileResult.warnings);
        
        LanguageBuildResult result;
        result.success = true;
        result.outputs = compileResult.outputs;
        result.outputHash = compileResult.outputHash;
        
        // Generate documentation if enabled
        if (_config.documentation.enabled)
            generateDocumentation(target, config);
        
        // Generate XCFramework if enabled and library
        if (_config.xcframework.enabled && target.type == TargetType.Library)
            generateXCFramework(target, config);
        
        return result;
    }
    
    private SwiftConfig parseSwiftConfig(in Target target) @system
    {
        SwiftConfig config;
        
        auto json = parseTargetConfig(target);
        if (json != JSONValue.init)
        {
            try { config = SwiftConfig.fromJSON(json); }
            catch (Exception e)
                structuredLog.warning("failed_to_parse_swift_config_").field("detail", "Using defaults: " ~ e.msg).emit();
        }
        
        // Auto-detect Package.swift
        if (config.manifest.manifestPath.empty)
        {
            config.manifest.manifestPath = PackageManifestParser.findManifest(target.sources.dup);
            if (!config.manifest.manifestPath.empty)
            {
                config.packagePath = dirName(config.manifest.manifestPath);
                structuredLog.debug_("found_packageswift_").field("detail", "Found: " ~ config.manifest.manifestPath).emit();
            }
        }
        
        // Apply target flags
        if (!target.flags.empty)
            config.buildSettings.swiftFlags ~= target.flags;
        
        return config;
    }
    
    private bool resolveDependencies() @system
    {
        if (!SPMRunner.isAvailable())
        {
            structuredLog.warning("spm_not_available").emit();
            return false;
        }
        
        structuredLog.info("resolving_swift_deps").emit();
        
        auto runner = new SPMRunner(_config.packagePath);
        auto res = runner.resolve();
        
        if (res.status == 0)
        {
            structuredLog.info("deps_resolved_successfully").emit();
            return true;
        }
        
        structuredLog.error("failed_to_resolve_deps_").field("detail", "Output: " ~ res.output).emit();
        return false;
    }
    
    private void generateDocumentation(in Target target, in WorkspaceConfig config) @system
    {
        if (!DocCRunner.isAvailable())
        {
            structuredLog.warning("docc_not_available_skipping").emit();
            return;
        }
        
        structuredLog.info("generating_documentation").emit();
        
        auto runner = new DocCRunner();
        auto res = runner.generate(
            _config.manifest.manifestPath.empty ? target.sources[0] : _config.packagePath,
            _config.documentation.outputPath,
            _config.documentation.hostingBasePath
        );
        
        if (res.status != 0)
            structuredLog.warning("doc_generation_failed_").field("detail", "Failed: " ~ res.output).emit();
        else
            structuredLog.info("doc_generated_successfully").emit();
    }
    
    private void generateXCFramework(in Target target, in WorkspaceConfig config) @system
    {
        structuredLog.info("generating_xcframework").emit();
        
        auto runner = new XCFrameworkBuilder();
        auto res = runner.create(
            _config.product,
            _config.xcframework.outputPath,
            _config.xcframework.platforms
        );
        
        if (res.status != 0)
            structuredLog.warning("xcframework_failed_").field("detail", "Failed: " ~ res.output).emit();
        else
            structuredLog.info("xcframework_generated_successfully").emit();
    }
}
