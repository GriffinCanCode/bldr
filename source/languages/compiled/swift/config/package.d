module languages.compiled.swift.config;

/// Swift Configuration Modules
/// 
/// Grouped configuration pattern for maintainability.
/// Each module handles one aspect of Swift configuration.

import std.json;
import std.string;
import std.algorithm;
import std.array;
import std.conv;

public import languages.compiled.swift.config.build;
public import languages.compiled.swift.config.dependency;
public import languages.compiled.swift.config.quality;
public import languages.compiled.swift.config.test;

/// Unified Swift configuration
/// Composes specialized config groups
struct SwiftConfig
{
    SwiftBuildConfig_ build;
    SwiftDependencyConfig dependencies;
    SwiftQualityConfig quality;
    SwiftTestConfig testing;
    
    // Convenience accessors for common patterns
    ref SwiftProjectType projectType() return { return build.projectType; }
    SwiftProjectType projectType() const { return build.projectType; }
    ref SPMBuildMode mode() return { return build.mode; }
    SPMBuildMode mode() const { return build.mode; }
    ref SwiftBuildConfig buildConfig() return { return build.buildConfig; }
    SwiftBuildConfig buildConfig() const { return build.buildConfig; }
    ref SwiftToolchain toolchain() return { return build.toolchain; }
    ref SwiftVersion swiftVersion() return { return build.swiftVersion; }
    ref SwiftLanguageVersion languageVersion() return { return build.languageVersion; }
    SwiftLanguageVersion languageVersion() const { return build.languageVersion; }
    ref SwiftLibraryType libraryType() return { return build.libraryType; }
    SwiftLibraryType libraryType() const { return build.libraryType; }
    ref string product() return { return build.product; }
    string product() const { return build.product; }
    ref string target() return { return build.target; }
    string target() const { return build.target; }
    ref string packagePath() return { return build.packagePath; }
    string packagePath() const { return build.packagePath; }
    ref string buildPath() return { return build.buildPath; }
    string buildPath() const { return build.buildPath; }
    ref string scratchPath() return { return build.scratchPath; }
    string scratchPath() const { return build.scratchPath; }
    string customConfig() const { return build.customConfig; }
    ref bool skipUpdate() return { return build.skipUpdate; }
    bool skipUpdate() const { return build.skipUpdate; }
    ref bool xcodeIntegration() return { return build.xcodeIntegration; }
    ref bool verbose() return { return build.verbose; }
    bool verbose() const { return build.verbose; }
    ref bool veryVerbose() return { return build.veryVerbose; }
    bool veryVerbose() const { return build.veryVerbose; }
    ref int jobs() return { return build.jobs; }
    int jobs() const { return build.jobs; }
    ref bool disableSandbox() return { return build.disableSandbox; }
    bool disableSandbox() const { return build.disableSandbox; }
    ref bool disableAutomaticResolution() return { return build.disableAutomaticResolution; }
    bool disableAutomaticResolution() const { return build.disableAutomaticResolution; }
    ref bool forceResolvedVersions() return { return build.forceResolvedVersions; }
    bool forceResolvedVersions() const { return build.forceResolvedVersions; }
    ref bool staticSwiftStdlib() return { return build.staticSwiftStdlib; }
    bool staticSwiftStdlib() const { return build.staticSwiftStdlib; }
    ref string arch() return { return build.arch; }
    string arch() const { return build.arch; }
    ref string triple() return { return build.triple; }
    string triple() const { return build.triple; }
    ref string sdk() return { return build.sdk; }
    string sdk() const { return build.sdk; }
    ref string swiftcPath() return { return build.swiftcPath; }
    string swiftcPath() const { return build.swiftcPath; }
    ref bool enableLibraryEvolution() return { return build.enableLibraryEvolution; }
    bool enableLibraryEvolution() const { return build.enableLibraryEvolution; }
    ref bool emitModuleInterface() return { return build.emitModuleInterface; }
    bool emitModuleInterface() const { return build.emitModuleInterface; }
    ref bool enableTestability() return { return build.enableTestability; }
    bool enableTestability() const { return build.enableTestability; }
    ref bool batchMode() return { return build.batchMode; }
    bool batchMode() const { return build.batchMode; }
    ref bool indexWhileBuilding() return { return build.indexWhileBuilding; }
    bool indexWhileBuilding() const { return build.indexWhileBuilding; }
    ref bool incrementalCompilation() return { return build.incrementalCompilation; }
    bool incrementalCompilation() const { return build.incrementalCompilation; }
    ref bool wholeModuleOptimization() return { return build.wholeModuleOptimization; }
    bool wholeModuleOptimization() const { return build.wholeModuleOptimization; }
    ref bool debugInfo() return { return build.debugInfo; }
    bool debugInfo() const { return build.debugInfo; }
    ref string xcodeScheme() return { return build.xcodeScheme; }
    string xcodeScheme() const { return build.xcodeScheme; }
    ref PlatformTarget[] platforms() return { return build.platforms; }
    const(PlatformTarget[]) platforms() const { return build.platforms; }
    ref BuildSettings buildSettings() return { return build.buildSettings; }
    const(BuildSettings) buildSettings() const { return build.buildSettings; }
    ref SwiftOptimization optimization() return { return build.optimization; }
    SwiftOptimization optimization() const { return build.optimization; }
    ref string[string] env() return { return build.env; }
    const(string[string]) env() const { return build.env; }
    ref CrossCompilationConfig crossCompilation() return { return build.crossCompilation; }
    ref XCFrameworkConfig xcframework() return { return build.xcframework; }
    
    ref PackageManifest manifest() return { return dependencies.manifest; }
    ref Dependency[] deps() return { return dependencies.dependencies; }
    
    ref SwiftLintConfig swiftlint() return { return quality.swiftlint; }
    const(SwiftLintConfig) swiftlint() const { return quality.swiftlint; }
    ref SwiftFormatConfig swiftformat() return { return quality.swiftformat; }
    const(SwiftFormatConfig) swiftformat() const { return quality.swiftformat; }
    ref DocCConfig documentation() return { return quality.documentation; }
    
    ref SwiftSanitizer sanitizer() return { return testing.sanitizer; }
    SwiftSanitizer sanitizer() const { return testing.sanitizer; }
    ref SwiftCoverage coverage() return { return testing.coverage; }
    SwiftCoverage coverage() const { return testing.coverage; }
    
    /// Parse from JSON (required by ConfigParsingMixin)
    static SwiftConfig fromJSON(JSONValue json) @system
    {
        SwiftConfig config;
        
        // Project type
        if (auto projectType = "projectType" in json)
        {
            immutable typeStr = projectType.str.toLower;
            switch (typeStr)
            {
                case "executable": config.build.projectType = SwiftProjectType.Executable; break;
                case "library": config.build.projectType = SwiftProjectType.Library; break;
                case "systemmodule", "system": config.build.projectType = SwiftProjectType.SystemModule; break;
                case "test": config.build.projectType = SwiftProjectType.Test; break;
                case "macro": config.build.projectType = SwiftProjectType.Macro; break;
                case "plugin": config.build.projectType = SwiftProjectType.Plugin; break;
                default: config.build.projectType = SwiftProjectType.Executable; break;
            }
        }
        
        // Build mode
        if (auto mode = "mode" in json)
        {
            immutable modeStr = mode.str.toLower;
            switch (modeStr)
            {
                case "build": config.build.mode = SPMBuildMode.Build; break;
                case "run": config.build.mode = SPMBuildMode.Run; break;
                case "test": config.build.mode = SPMBuildMode.Test; break;
                case "check": config.build.mode = SPMBuildMode.Check; break;
                case "clean": config.build.mode = SPMBuildMode.Clean; break;
                case "generate-xcodeproj": config.build.mode = SPMBuildMode.GenerateXcodeproj; break;
                case "custom": config.build.mode = SPMBuildMode.Custom; break;
                default: config.build.mode = SPMBuildMode.Build; break;
            }
        }
        
        // Build configuration
        if (auto buildConfig = "buildConfig" in json)
        {
            immutable configStr = buildConfig.str.toLower;
            switch (configStr)
            {
                case "debug": config.build.buildConfig = SwiftBuildConfig.Debug; break;
                case "release": config.build.buildConfig = SwiftBuildConfig.Release; break;
                case "custom": 
                    config.build.buildConfig = SwiftBuildConfig.Custom;
                    if (auto custom = "customConfig" in json)
                        config.build.customConfig = custom.str;
                    break;
                default: config.build.buildConfig = SwiftBuildConfig.Release; break;
            }
        }
        
        // Toolchain
        if (auto toolchain = "toolchain" in json)
        {
            immutable tcStr = toolchain.str.toLower;
            switch (tcStr)
            {
                case "system": config.build.toolchain = SwiftToolchain.System; break;
                case "xcode": config.build.toolchain = SwiftToolchain.Xcode; break;
                case "custom": config.build.toolchain = SwiftToolchain.Custom; break;
                case "snapshot": config.build.toolchain = SwiftToolchain.Snapshot; break;
                default: config.build.toolchain = SwiftToolchain.System; break;
            }
        }
        
        // Swift version
        if (auto swiftVersion = "swiftVersion" in json)
        {
            if (swiftVersion.type == JSONType.string)
            {
                immutable parts = swiftVersion.str.split(".");
                if (parts.length >= 1) config.build.swiftVersion.major = parts[0].to!int;
                if (parts.length >= 2) config.build.swiftVersion.minor = parts[1].to!int;
                if (parts.length >= 3) config.build.swiftVersion.patch = parts[2].to!int;
            }
            else if (swiftVersion.type == JSONType.object)
            {
                if (auto major = "major" in *swiftVersion)
                    config.build.swiftVersion.major = cast(int)major.integer;
                if (auto minor = "minor" in *swiftVersion)
                    config.build.swiftVersion.minor = cast(int)minor.integer;
                if (auto patch = "patch" in *swiftVersion)
                    config.build.swiftVersion.patch = cast(int)patch.integer;
                if (auto toolchainPath = "toolchainPath" in *swiftVersion)
                    config.build.swiftVersion.toolchainPath = toolchainPath.str;
                if (auto useXcode = "useXcode" in *swiftVersion)
                    config.build.swiftVersion.useXcode = useXcode.type == JSONType.true_;
                if (auto snapshot = "snapshot" in *swiftVersion)
                    config.build.swiftVersion.snapshot = snapshot.str;
            }
        }
        
        // Language version
        if (auto langVersion = "languageVersion" in json)
        {
            immutable langStr = langVersion.str.replace(".", "_");
            switch (langStr)
            {
                case "4": config.build.languageVersion = SwiftLanguageVersion.Swift4; break;
                case "4_2": config.build.languageVersion = SwiftLanguageVersion.Swift4_2; break;
                case "5": config.build.languageVersion = SwiftLanguageVersion.Swift5; break;
                case "5_1": config.build.languageVersion = SwiftLanguageVersion.Swift5_1; break;
                case "5_2": config.build.languageVersion = SwiftLanguageVersion.Swift5_2; break;
                case "5_3": config.build.languageVersion = SwiftLanguageVersion.Swift5_3; break;
                case "5_4": config.build.languageVersion = SwiftLanguageVersion.Swift5_4; break;
                case "5_5": config.build.languageVersion = SwiftLanguageVersion.Swift5_5; break;
                case "5_6": config.build.languageVersion = SwiftLanguageVersion.Swift5_6; break;
                case "5_7": config.build.languageVersion = SwiftLanguageVersion.Swift5_7; break;
                case "5_8": config.build.languageVersion = SwiftLanguageVersion.Swift5_8; break;
                case "5_9": config.build.languageVersion = SwiftLanguageVersion.Swift5_9; break;
                case "5_10": config.build.languageVersion = SwiftLanguageVersion.Swift5_10; break;
                case "6": config.build.languageVersion = SwiftLanguageVersion.Swift6; break;
                default: config.build.languageVersion = SwiftLanguageVersion.Swift5_10; break;
            }
        }
        
        // Library type
        if (auto libType = "libraryType" in json)
        {
            immutable libStr = libType.str.toLower;
            switch (libStr)
            {
                case "auto": config.build.libraryType = SwiftLibraryType.Auto; break;
                case "static": config.build.libraryType = SwiftLibraryType.Static; break;
                case "dynamic": config.build.libraryType = SwiftLibraryType.Dynamic; break;
                default: config.build.libraryType = SwiftLibraryType.Auto; break;
            }
        }
        
        // Optimization
        if (auto opt = "optimization" in json)
        {
            immutable optStr = opt.str.toLower;
            switch (optStr)
            {
                case "none": config.build.optimization = SwiftOptimization.None; break;
                case "speed": config.build.optimization = SwiftOptimization.Speed; break;
                case "size": config.build.optimization = SwiftOptimization.Size; break;
                case "unchecked": config.build.optimization = SwiftOptimization.Unchecked; break;
                default: config.build.optimization = SwiftOptimization.Speed; break;
            }
        }
        
        // Sanitizer
        if (auto sanitizer = "sanitizer" in json)
        {
            immutable sanStr = sanitizer.str.toLower;
            switch (sanStr)
            {
                case "none": config.testing.sanitizer = SwiftSanitizer.None; break;
                case "address": config.testing.sanitizer = SwiftSanitizer.Address; break;
                case "thread": config.testing.sanitizer = SwiftSanitizer.Thread; break;
                case "undefined": config.testing.sanitizer = SwiftSanitizer.Undefined; break;
                default: config.testing.sanitizer = SwiftSanitizer.None; break;
            }
        }
        
        // Coverage
        if (auto coverage = "coverage" in json)
        {
            immutable covStr = coverage.str.toLower;
            switch (covStr)
            {
                case "none": config.testing.coverage = SwiftCoverage.None; break;
                case "generate": config.testing.coverage = SwiftCoverage.Generate; break;
                case "show": config.testing.coverage = SwiftCoverage.Show; break;
                default: config.testing.coverage = SwiftCoverage.None; break;
            }
        }
        
        // String fields
        if (auto product = "product" in json) config.build.product = product.str;
        if (auto target = "target" in json) config.build.target = target.str;
        if (auto buildPath = "buildPath" in json) config.build.buildPath = buildPath.str;
        if (auto scratchPath = "scratchPath" in json) config.build.scratchPath = scratchPath.str;
        if (auto packagePath = "packagePath" in json) config.build.packagePath = packagePath.str;
        if (auto arch = "arch" in json) config.build.arch = arch.str;
        if (auto triple = "triple" in json) config.build.triple = triple.str;
        if (auto sdk = "sdk" in json) config.build.sdk = sdk.str;
        if (auto xcodeScheme = "xcodeScheme" in json) config.build.xcodeScheme = xcodeScheme.str;
        if (auto xcodeConfiguration = "xcodeConfiguration" in json) config.build.xcodeConfiguration = xcodeConfiguration.str;
        if (auto swiftcPath = "swiftcPath" in json) config.build.swiftcPath = swiftcPath.str;
        
        // Numeric fields
        if (auto jobs = "jobs" in json) config.build.jobs = cast(int)jobs.integer;
        
        // Boolean fields
        if (auto verbose = "verbose" in json) config.build.verbose = verbose.type == JSONType.true_;
        if (auto veryVerbose = "veryVerbose" in json) config.build.veryVerbose = veryVerbose.type == JSONType.true_;
        if (auto debugInfo = "debugInfo" in json) config.build.debugInfo = debugInfo.type == JSONType.true_;
        if (auto enableTestability = "enableTestability" in json) config.build.enableTestability = enableTestability.type == JSONType.true_;
        if (auto wholeModuleOptimization = "wholeModuleOptimization" in json) 
            config.build.wholeModuleOptimization = wholeModuleOptimization.type == JSONType.true_;
        if (auto incrementalCompilation = "incrementalCompilation" in json)
            config.build.incrementalCompilation = incrementalCompilation.type == JSONType.true_;
        if (auto indexWhileBuilding = "indexWhileBuilding" in json)
            config.build.indexWhileBuilding = indexWhileBuilding.type == JSONType.true_;
        if (auto batchMode = "batchMode" in json) config.build.batchMode = batchMode.type == JSONType.true_;
        if (auto staticSwiftStdlib = "staticSwiftStdlib" in json)
            config.build.staticSwiftStdlib = staticSwiftStdlib.type == JSONType.true_;
        if (auto disableSandbox = "disableSandbox" in json)
            config.build.disableSandbox = disableSandbox.type == JSONType.true_;
        if (auto skipUpdate = "skipUpdate" in json) config.build.skipUpdate = skipUpdate.type == JSONType.true_;
        if (auto disableAutomaticResolution = "disableAutomaticResolution" in json)
            config.build.disableAutomaticResolution = disableAutomaticResolution.type == JSONType.true_;
        if (auto forceResolvedVersions = "forceResolvedVersions" in json)
            config.build.forceResolvedVersions = forceResolvedVersions.type == JSONType.true_;
        if (auto enableLibraryEvolution = "enableLibraryEvolution" in json)
            config.build.enableLibraryEvolution = enableLibraryEvolution.type == JSONType.true_;
        if (auto emitModuleInterface = "emitModuleInterface" in json)
            config.build.emitModuleInterface = emitModuleInterface.type == JSONType.true_;
        if (auto enableBareSlashRegex = "enableBareSlashRegex" in json)
            config.build.enableBareSlashRegex = enableBareSlashRegex.type == JSONType.true_;
        if (auto xcodeIntegration = "xcodeIntegration" in json)
            config.build.xcodeIntegration = xcodeIntegration.type == JSONType.true_;
        if (auto generateXcodeProject = "generateXcodeProject" in json)
            config.build.generateXcodeProject = generateXcodeProject.type == JSONType.true_;
        
        // Array fields
        if (auto upcomingFeatures = "upcomingFeatures" in json)
            config.build.upcomingFeatures = upcomingFeatures.array.map!(e => e.str).array;
        if (auto experimentalFeatures = "experimentalFeatures" in json)
            config.build.experimentalFeatures = experimentalFeatures.array.map!(e => e.str).array;
        
        // Platform targets
        if (auto platforms = "platforms" in json)
        {
            foreach (ref platform; platforms.array)
            {
                PlatformTarget pt;
                if (auto name = "platform" in platform)
                {
                    immutable platStr = name.str.toLower;
                    switch (platStr)
                    {
                        case "macos": pt.platform = SwiftPlatform.macOS; break;
                        case "ios": pt.platform = SwiftPlatform.iOS; break;
                        case "iossimulator": pt.platform = SwiftPlatform.iOSSimulator; break;
                        case "tvos": pt.platform = SwiftPlatform.tvOS; break;
                        case "watchos": pt.platform = SwiftPlatform.watchOS; break;
                        case "linux": pt.platform = SwiftPlatform.Linux; break;
                        case "windows": pt.platform = SwiftPlatform.Windows; break;
                        case "android": pt.platform = SwiftPlatform.Android; break;
                        default: pt.platform = SwiftPlatform.macOS; break;
                    }
                }
                if (auto minVersion = "minVersion" in platform) pt.minVersion = minVersion.str;
                if (auto sdkPath = "sdkPath" in platform) pt.sdkPath = sdkPath.str;
                if (auto arch = "arch" in platform) pt.arch = arch.str;
                
                config.build.platforms ~= pt;
            }
        }
        
        // Build settings
        if (auto buildSettings = "buildSettings" in json)
        {
            if (auto cFlags = "cFlags" in *buildSettings)
                config.build.buildSettings.cFlags = cFlags.array.map!(e => e.str).array;
            if (auto cxxFlags = "cxxFlags" in *buildSettings)
                config.build.buildSettings.cxxFlags = cxxFlags.array.map!(e => e.str).array;
            if (auto swiftFlags = "swiftFlags" in *buildSettings)
                config.build.buildSettings.swiftFlags = swiftFlags.array.map!(e => e.str).array;
            if (auto linkerFlags = "linkerFlags" in *buildSettings)
                config.build.buildSettings.linkerFlags = linkerFlags.array.map!(e => e.str).array;
            if (auto defines = "defines" in *buildSettings)
                config.build.buildSettings.defines = defines.array.map!(e => e.str).array;
            if (auto headerSearchPaths = "headerSearchPaths" in *buildSettings)
                config.build.buildSettings.headerSearchPaths = headerSearchPaths.array.map!(e => e.str).array;
            if (auto linkedLibraries = "linkedLibraries" in *buildSettings)
                config.build.buildSettings.linkedLibraries = linkedLibraries.array.map!(e => e.str).array;
            if (auto linkedFrameworks = "linkedFrameworks" in *buildSettings)
                config.build.buildSettings.linkedFrameworks = linkedFrameworks.array.map!(e => e.str).array;
            if (auto unsafeFlags = "unsafeFlags" in *buildSettings)
                config.build.buildSettings.unsafeFlags = unsafeFlags.type == JSONType.true_;
        }
        
        // SwiftLint configuration
        if (auto swiftlint = "swiftlint" in json)
        {
            if (auto enabled = "enabled" in *swiftlint)
                config.quality.swiftlint.enabled = enabled.type == JSONType.true_;
            if (auto configFile = "configFile" in *swiftlint)
                config.quality.swiftlint.configFile = configFile.str;
            if (auto strict = "strict" in *swiftlint)
                config.quality.swiftlint.strict = strict.type == JSONType.true_;
            if (auto mode = "mode" in *swiftlint)
                config.quality.swiftlint.mode = mode.str;
            if (auto enableRules = "enableRules" in *swiftlint)
                config.quality.swiftlint.enableRules = enableRules.array.map!(e => e.str).array;
            if (auto disableRules = "disableRules" in *swiftlint)
                config.quality.swiftlint.disableRules = disableRules.array.map!(e => e.str).array;
            if (auto includePaths = "includePaths" in *swiftlint)
                config.quality.swiftlint.includePaths = includePaths.array.map!(e => e.str).array;
            if (auto excludePaths = "excludePaths" in *swiftlint)
                config.quality.swiftlint.excludePaths = excludePaths.array.map!(e => e.str).array;
            if (auto reporter = "reporter" in *swiftlint)
                config.quality.swiftlint.reporter = reporter.str;
            if (auto quiet = "quiet" in *swiftlint)
                config.quality.swiftlint.quiet = quiet.type == JSONType.true_;
            if (auto forceExclude = "forceExclude" in *swiftlint)
                config.quality.swiftlint.forceExclude = forceExclude.type == JSONType.true_;
            if (auto autocorrect = "autocorrect" in *swiftlint)
                config.quality.swiftlint.autocorrect = autocorrect.type == JSONType.true_;
        }
        
        // SwiftFormat configuration
        if (auto swiftformat = "swiftformat" in json)
        {
            if (auto enabled = "enabled" in *swiftformat)
                config.quality.swiftformat.enabled = enabled.type == JSONType.true_;
            if (auto configFile = "configFile" in *swiftformat)
                config.quality.swiftformat.configFile = configFile.str;
            if (auto checkOnly = "checkOnly" in *swiftformat)
                config.quality.swiftformat.checkOnly = checkOnly.type == JSONType.true_;
            if (auto inPlace = "inPlace" in *swiftformat)
                config.quality.swiftformat.inPlace = inPlace.type == JSONType.true_;
            if (auto rules = "rules" in *swiftformat)
                config.quality.swiftformat.rules = rules.array.map!(e => e.str).array;
            if (auto indentWidth = "indentWidth" in *swiftformat)
                config.quality.swiftformat.indentWidth = cast(int)indentWidth.integer;
            if (auto useTabs = "useTabs" in *swiftformat)
                config.quality.swiftformat.useTabs = useTabs.type == JSONType.true_;
            if (auto lineLength = "lineLength" in *swiftformat)
                config.quality.swiftformat.lineLength = cast(int)lineLength.integer;
            if (auto respectsExistingLineBreaks = "respectsExistingLineBreaks" in *swiftformat)
                config.quality.swiftformat.respectsExistingLineBreaks = respectsExistingLineBreaks.type == JSONType.true_;
        }
        
        // Testing configuration
        if (auto testing = "testing" in json)
        {
            if (auto filter = "filter" in *testing)
                config.testing.filter = filter.array.map!(e => e.str).array;
            if (auto skip = "skip" in *testing)
                config.testing.skip = skip.array.map!(e => e.str).array;
            if (auto enableCodeCoverage = "enableCodeCoverage" in *testing)
                config.testing.enableCodeCoverage = enableCodeCoverage.type == JSONType.true_;
            if (auto parallel = "parallel" in *testing)
                config.testing.parallel = parallel.type == JSONType.true_;
            if (auto numWorkers = "numWorkers" in *testing)
                config.testing.numWorkers = cast(int)numWorkers.integer;
            if (auto repeat = "repeat" in *testing)
                config.testing.repeat = cast(int)repeat.integer;
            if (auto testProduct = "testProduct" in *testing)
                config.testing.testProduct = testProduct.str;
            if (auto xctestArgs = "xctestArgs" in *testing)
                config.testing.xctestArgs = xctestArgs.array.map!(e => e.str).array;
            if (auto enableTestDiscovery = "enableTestDiscovery" in *testing)
                config.testing.enableTestDiscovery = enableTestDiscovery.type == JSONType.true_;
            if (auto experimentalTestOutput = "experimentalTestOutput" in *testing)
                config.testing.experimentalTestOutput = experimentalTestOutput.type == JSONType.true_;
        }
        
        // Documentation configuration
        if (auto documentation = "documentation" in json)
        {
            if (auto enabled = "enabled" in *documentation)
                config.quality.documentation.enabled = enabled.type == JSONType.true_;
            if (auto outputPath = "outputPath" in *documentation)
                config.quality.documentation.outputPath = outputPath.str;
            if (auto hostingBasePath = "hostingBasePath" in *documentation)
                config.quality.documentation.hostingBasePath = hostingBasePath.str;
            if (auto transformForStaticHosting = "transformForStaticHosting" in *documentation)
                config.quality.documentation.transformForStaticHosting = transformForStaticHosting.type == JSONType.true_;
            if (auto symbolGraphOptions = "symbolGraphOptions" in *documentation)
                config.quality.documentation.symbolGraphOptions = symbolGraphOptions.array.map!(e => e.str).array;
            if (auto experimentalFeatures = "experimentalFeatures" in *documentation)
                config.quality.documentation.experimentalFeatures = experimentalFeatures.type == JSONType.true_;
            if (auto enableDiagnostics = "enableDiagnostics" in *documentation)
                config.quality.documentation.enableDiagnostics = enableDiagnostics.type == JSONType.true_;
        }
        
        // XCFramework configuration
        if (auto xcframework = "xcframework" in json)
        {
            if (auto enabled = "enabled" in *xcframework)
                config.build.xcframework.enabled = enabled.type == JSONType.true_;
            if (auto outputPath = "outputPath" in *xcframework)
                config.build.xcframework.outputPath = outputPath.str;
            if (auto frameworkName = "frameworkName" in *xcframework)
                config.build.xcframework.frameworkName = frameworkName.str;
            if (auto allowInternalDistribution = "allowInternalDistribution" in *xcframework)
                config.build.xcframework.allowInternalDistribution = allowInternalDistribution.type == JSONType.true_;
            
            if (auto platforms = "platforms" in *xcframework)
            {
                foreach (ref platformVal; platforms.array)
                {
                    immutable platStr = platformVal.str.toLower;
                    SwiftPlatform plat;
                    switch (platStr)
                    {
                        case "macos": plat = SwiftPlatform.macOS; break;
                        case "ios": plat = SwiftPlatform.iOS; break;
                        case "iossimulator": plat = SwiftPlatform.iOSSimulator; break;
                        case "tvos": plat = SwiftPlatform.tvOS; break;
                        case "watchos": plat = SwiftPlatform.watchOS; break;
                        default: plat = SwiftPlatform.macOS; break;
                    }
                    config.build.xcframework.platforms ~= plat;
                }
            }
        }
        
        // Cross-compilation configuration
        if (auto crossCompilation = "crossCompilation" in json)
        {
            if (auto targetTriple = "targetTriple" in *crossCompilation)
                config.build.crossCompilation.targetTriple = targetTriple.str;
            if (auto sdkPath = "sdkPath" in *crossCompilation)
                config.build.crossCompilation.sdkPath = sdkPath.str;
            if (auto arch = "arch" in *crossCompilation)
                config.build.crossCompilation.arch = arch.str;
            if (auto flags = "flags" in *crossCompilation)
                config.build.crossCompilation.flags = flags.array.map!(e => e.str).array;
        }
        
        // Environment variables
        if (auto env = "env" in json)
        {
            foreach (string key, ref value; env.object)
                config.build.env[key] = value.str;
        }
        
        return config;
    }
}

