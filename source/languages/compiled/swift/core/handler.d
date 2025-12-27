module languages.compiled.swift.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import languages.base.base;
import languages.compiled.swift.config;
import languages.compiled.swift.analysis.manifest;
import languages.compiled.swift.managers.spm;
import languages.compiled.swift.managers.toolchain;
import languages.compiled.swift.tooling;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Advanced Swift build handler with SPM, Xcode, and cross-compilation support
class SwiftHandler : BaseLanguageHandler
{
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_swift_target_").field("detail", "Building Swift target: " ~ target.name).emit();
        
        // Parse Swift configuration
        SwiftConfig swiftConfig = parseSwiftConfig(target);
        
        // Validate Swift toolchain
        if (!ensureSwiftAvailable(swiftConfig))
        {
            result.error = "Swift toolchain not available. Install from https://swift.org";
            return result;
        }
        
        // Auto-detect Package.swift if present
        if (swiftConfig.manifest.manifestPath.empty || !exists(swiftConfig.manifest.manifestPath))
        {
            auto manifestPath = PackageManifestParser.findManifest(target.sources.dup);
            if (!manifestPath.empty)
            {
                structuredLog.debug_("found_packageswift_").field("detail", "Found Package.swift: " ~ manifestPath).emit();
                swiftConfig.manifest.manifestPath = manifestPath;
                swiftConfig.packagePath = dirName(manifestPath);
                
                // Parse manifest
                auto manifest = PackageManifestParser.parse(manifestPath);
                if (manifest.isValid)
                {
                    swiftConfig.manifest = manifest.manifest;
                }
            }
        }
        
        // Run SwiftLint if requested
        if (swiftConfig.swiftlint.enabled)
        {
            auto lintResult = runSwiftLint(target, swiftConfig, config);
            if (lintResult.hadLintIssues && swiftConfig.swiftlint.strict)
            {
                structuredLog.warning("swiftlint_found_issues").emit();
                foreach (issue; lintResult.lintIssues)
                {
                    structuredLog.warning("__").field("detail", "  " ~ issue).emit();
                }
                
                if (lintResult.hadLintErrors)
                {
                    result.error = "SwiftLint errors in strict mode";
                    return result;
                }
            }
        }
        
        // Run SwiftFormat if requested
        if (swiftConfig.swiftformat.enabled)
        {
            runSwiftFormat(target, swiftConfig);
        }
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, swiftConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, swiftConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, swiftConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, swiftConfig);
                break;
        }
        
        // Generate documentation if requested
        if (result.success && swiftConfig.documentation.enabled)
        {
            generateDocumentation(target, swiftConfig, config);
        }
        
        // Generate XCFramework if requested
        if (result.success && swiftConfig.xcframework.enabled && 
            target.type == TargetType.Library)
        {
            generateXCFramework(target, swiftConfig, config);
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        SwiftConfig swiftConfig = parseSwiftConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            // Adjust extension based on platform
            version(OSX)
            {
                if (target.type == TargetType.Library)
                {
                    if (swiftConfig.libraryType == SwiftLibraryType.Static)
                        outputs ~= buildPath(config.options.outputDir, "lib" ~ name ~ ".a");
                    else
                        outputs ~= buildPath(config.options.outputDir, "lib" ~ name ~ ".dylib");
                }
                else
                {
                    outputs ~= buildPath(config.options.outputDir, name);
                }
            }
            else version(linux)
            {
                if (target.type == TargetType.Library)
                {
                    if (swiftConfig.libraryType == SwiftLibraryType.Static)
                        outputs ~= buildPath(config.options.outputDir, "lib" ~ name ~ ".a");
                    else
                        outputs ~= buildPath(config.options.outputDir, "lib" ~ name ~ ".so");
                }
                else
                {
                    outputs ~= buildPath(config.options.outputDir, name);
                }
            }
            else version(Windows)
            {
                if (target.type == TargetType.Library)
                {
                    if (swiftConfig.libraryType == SwiftLibraryType.Static)
                        outputs ~= buildPath(config.options.outputDir, name ~ ".lib");
                    else
                        outputs ~= buildPath(config.options.outputDir, name ~ ".dll");
                }
                else
                {
                    outputs ~= buildPath(config.options.outputDir, name ~ ".exe");
                }
            }
            else
            {
                outputs ~= buildPath(config.options.outputDir, name);
            }
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Swift);
        if (spec is null)
            return [];
        
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = spec.scanImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source).emit();
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, SwiftConfig swiftConfig)
    {
        LanguageBuildResult result;
        
        // Set project type to executable
        if (swiftConfig.projectType != SwiftProjectType.Executable)
            swiftConfig.projectType = SwiftProjectType.Executable;
        
        // Auto-detect entry point if not specified
        if (swiftConfig.product.empty && !target.sources.empty)
        {
            // Look for main.swift
            foreach (source; target.sources)
            {
                if (baseName(source) == "main.swift")
                {
                    swiftConfig.product = stripExtension(baseName(source));
                    break;
                }
            }
            
            // Fallback to target name
            if (swiftConfig.product.empty)
                swiftConfig.product = target.name.split(":")[$ - 1];
        }
        
        // Build with selected tooling
        return compileTarget(target, config, swiftConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, SwiftConfig swiftConfig)
    {
        LanguageBuildResult result;
        
        // Set project type to library
        if (swiftConfig.projectType != SwiftProjectType.Library)
            swiftConfig.projectType = SwiftProjectType.Library;
        
        // Ensure product name is set
        if (swiftConfig.product.empty)
            swiftConfig.product = target.name.split(":")[$ - 1];
        
        return compileTarget(target, config, swiftConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, SwiftConfig swiftConfig)
    {
        LanguageBuildResult result;
        
        // Set mode to test
        swiftConfig.mode = SPMBuildMode.Test;
        
        // Use debug configuration for tests
        if (swiftConfig.buildConfig == SwiftBuildConfig.Release)
            swiftConfig.buildConfig = SwiftBuildConfig.Debug;
        
        // Enable testability
        swiftConfig.enableTestability = true;
        
        return compileTarget(target, config, swiftConfig);
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, SwiftConfig swiftConfig)
    {
        LanguageBuildResult result;
        
        swiftConfig.mode = SPMBuildMode.Custom;
        
        return compileTarget(target, config, swiftConfig);
    }
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config, SwiftConfig swiftConfig)
    {
        LanguageBuildResult result;
        
        // Create builder
        auto builder = SwiftBuilderFactory.create(swiftConfig);
        
        if (!builder.isAvailable())
        {
            result.error = "Swift builder '" ~ builder.name() ~ "' is not available. " ~
                          "Install Swift from https://swift.org or Xcode.";
            return result;
        }
        
        structuredLog.debug_("using_swift_builder_").field("detail", "Using Swift builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        // Resolve dependencies if using SPM
        if (!swiftConfig.manifest.manifestPath.empty && !swiftConfig.skipUpdate)
        {
            if (!resolveDependencies(swiftConfig))
            {
                structuredLog.warning("failed_to_resolve_dependencies_continuin").emit();
            }
        }
        
        // Compile
        auto compileResult = builder.build(target.sources, swiftConfig, target, config);
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report warnings
        if (compileResult.warnings.length > 0)
        {
            structuredLog.warning("compilation_warnings").emit();
            foreach (warn; compileResult.warnings)
            {
                structuredLog.warning("__").field("detail", "  " ~ warn).emit();
            }
        }
        
        result.success = true;
        result.outputs = compileResult.outputs;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    private SwiftConfig parseSwiftConfig(in Target target)
    {
        SwiftConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("swift" in target.langConfig)
            configKey = "swift";
        else if ("swiftConfig" in target.langConfig)
            configKey = "swiftConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = SwiftConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_swift_config_using_defau").field("detail", "Failed to parse Swift config, using defaults: " ~ e.msg).emit();
            }
        }
        
        // Auto-detect Package.swift if not specified
        if (config.manifest.manifestPath.empty)
        {
            config.manifest.manifestPath = PackageManifestParser.findManifest(target.sources.dup);
            if (!config.manifest.manifestPath.empty)
            {
                config.packagePath = dirName(config.manifest.manifestPath);
                structuredLog.debug_("found_packageswift_").field("detail", "Found Package.swift: " ~ config.manifest.manifestPath).emit();
            }
        }
        
        // Apply target flags to Swift flags
        if (!target.flags.empty)
        {
            config.buildSettings.swiftFlags ~= target.flags;
        }
        
        return config;
    }
    
    private bool ensureSwiftAvailable(SwiftConfig config)
    {
        // Check if swift command is available
        return SwiftToolchainManager.isSwiftAvailable();
    }
    
    private bool resolveDependencies(SwiftConfig config)
    {
        if (!SPMRunner.isAvailable())
        {
            structuredLog.warning("swift_package_manager_not_available").emit();
            return false;
        }
        
        structuredLog.info("resolving_swift_package_dependencies").emit();
        
        auto runner = new SPMRunner(config.packagePath);
        
        // Run swift package resolve
        auto res = runner.resolve();
        
        if (res.status == 0)
        {
            structuredLog.info("dependencies_resolved_successfully").emit();
            return true;
        }
        else
        {
            structuredLog.error("failed_to_resolve_dependencies").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
    }
    
    private SwiftLintResult runSwiftLint(in Target target, SwiftConfig config, in WorkspaceConfig workspace)
    {
        SwiftLintResult result;
        
        if (!SwiftLintRunner.isAvailable())
        {
            structuredLog.warning("swiftlint_not_available_skipping").emit();
            result.success = true;
            return result;
        }
        
        structuredLog.info("running_swiftlint").emit();
        
        auto runner = new SwiftLintRunner();
        auto res = runner.lint(
            target.sources.dup,
            config.swiftlint.configFile,
            config.swiftlint.strict,
            config.swiftlint.enableRules,
            config.swiftlint.disableRules
        );
        
        if (res.status != 0)
        {
            result.hadLintIssues = true;
            
            // Parse SwiftLint output
            foreach (line; res.output.split("\n"))
            {
                if (line.canFind("warning:"))
                {
                    result.lintIssues ~= line;
                }
                else if (line.canFind("error:"))
                {
                    result.hadLintErrors = true;
                    result.lintIssues ~= line;
                }
            }
        }
        
        result.success = true;
        return result;
    }
    
    private void runSwiftFormat(in Target target, SwiftConfig config)
    {
        if (!SwiftFormatRunner.isAvailable())
        {
            structuredLog.warning("swiftformat_not_available_skipping").emit();
            return;
        }
        
        structuredLog.info("running_swiftformat").emit();
        
        auto runner = new SwiftFormatRunner();
        auto res = runner.format(
            target.sources.dup,
            config.swiftformat.configFile,
            config.swiftformat.checkOnly,
            config.swiftformat.inPlace
        );
        
        if (res.status != 0)
        {
            structuredLog.warning("swiftformat_had_issues_").field("detail", "SwiftFormat had issues: " ~ res.output).emit();
        }
        else
        {
            structuredLog.info("code_formatted_successfully").emit();
        }
    }
    
    private void generateDocumentation(in Target target, SwiftConfig config, in WorkspaceConfig workspace)
    {
        if (!DocCRunner.isAvailable())
        {
            structuredLog.warning("swiftdocc_not_available_skipping_documen").emit();
            return;
        }
        
        structuredLog.info("generating_documentation").emit();
        
        auto runner = new DocCRunner();
        auto res = runner.generate(
            config.manifest.manifestPath.empty ? target.sources[0] : config.packagePath,
            config.documentation.outputPath,
            config.documentation.hostingBasePath
        );
        
        if (res.status != 0)
        {
            structuredLog.warning("documentation_generation_failed_").field("detail", "Documentation generation failed: " ~ res.output).emit();
        }
        else
        {
            structuredLog.info("documentation_generated_successfully").emit();
        }
    }
    
    private void generateXCFramework(in Target target, SwiftConfig config, in WorkspaceConfig workspace)
    {
        structuredLog.info("generating_xcframework").emit();
        
        auto runner = new XCFrameworkBuilder();
        auto res = runner.create(
            config.product,
            config.xcframework.outputPath,
            config.xcframework.platforms
        );
        
        if (res.status != 0)
        {
            structuredLog.warning("xcframework_generation_failed_").field("detail", "XCFramework generation failed: " ~ res.output).emit();
        }
        else
        {
            structuredLog.info("xcframework_generated_successfully").emit();
        }
    }
}

/// SwiftLint result
struct SwiftLintResult
{
    bool success;
    bool hadLintIssues;
    bool hadLintErrors;
    string[] lintIssues;
}

