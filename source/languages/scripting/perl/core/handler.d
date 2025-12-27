module languages.scripting.perl.core.handler;

import std.stdio;
import std.algorithm;
import std.array;
import std.string : lineSplitter, indexOf;
import std.regex;
import std.file : exists, isFile, readText;
import std.json;
import std.path;
import languages.scripting.base;
import languages.scripting.perl.core.config;
import languages.scripting.perl.services;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig;

/// Perl build handler with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
final class PerlHandler : BaseScriptingHandler
{
    private PerlConfig _currentConfig;
    private IPerlConfigService configService;
    private IPerlDependencyService dependencyService;
    private IPerlQualityService qualityService;
    private IPerlBuildService buildService;
    private IPerlTestService testService;
    private IPerlDocumentationService documentationService;
    
    this()
    {
        configService = new PerlConfigService();
        dependencyService = new PerlDependencyService();
        qualityService = new PerlQualityService();
        buildService = new PerlBuildService();
        testService = new PerlTestService();
        documentationService = new PerlDocumentationService();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "perl";
    
    override protected string[] configKeys() const pure nothrow @safe => ["perl", "perlConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.Perl;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        // Perl uses system perl by default
        return EnvironmentSetupResult.ok("perl");
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        string[] syntaxErrors;
        if (!qualityService.checkSyntax(sources, _currentConfig, syntaxErrors, getCache()))
            return SyntaxValidationResult.fail(syntaxErrors.empty ? ["Syntax check failed"] : syntaxErrors);
        
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        // Use the specialized config service
        auto workspace = WorkspaceConfig.init;
        _currentConfig = configService.parse(target, workspace);
        return JSONValue.init; // Perl uses its own config parsing
    }
    
    override protected bool shouldInstallDeps(JSONValue config) const @system
        => _currentConfig.installDeps && !_currentConfig.modules.empty;
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.format.autoFormat;
    
    override protected bool shouldAutoLint(JSONValue config) const @system
        => _currentConfig.format.formatter == PerlFormatter.PerlCritic ||
           _currentConfig.format.formatter == PerlFormatter.Both;
    
    override protected bool shouldFailOnLintError(JSONValue config) const @system
        => _currentConfig.format.failOnCritic;
    
    override protected DependencyInstallResult installDependencies(
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        if (!dependencyService.install(_currentConfig, projectRoot, getCache()))
            return DependencyInstallResult.fail("Failed to install dependencies");
        
        return DependencyInstallResult.ok();
    }
    
    override protected FormatStepResult runFormatter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        qualityService.formatCode(sources, _currentConfig);
        return FormatStepResult.ok();
    }
    
    override protected LintStepResult runLinter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto lintResult = qualityService.lintCode(sources, _currentConfig, getCache());
        
        if (!lintResult.success)
        {
            LintStepResult result;
            result.success = false;
            result.error = lintResult.error;
            return result;
        }
        
        return LintStepResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // BUILD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected LanguageBuildResult buildExecutableImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        return buildService.buildExecutable(target, config, _currentConfig);
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        LanguageBuildResult result;
        
        if (_currentConfig.mode == PerlBuildMode.CPAN)
            result = buildService.buildCPAN(target, config, _currentConfig, getCache());
        else
            result = buildService.buildLibrary(target, config, _currentConfig);
        
        // Generate documentation
        if (result.success && _currentConfig.documentation.generator != PerlDocGenerator.None)
            documentationService.generate(target.sources, _currentConfig, config.root, getCache());
        
        return result;
    }
    
    override protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        return testService.run(target, _currentConfig, config.root, getCache());
    }
    
    override protected LanguageBuildResult buildCustomImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        // For custom targets, just do syntax check
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // IMPORT ANALYSIS (PERL-SPECIFIC)
    // ═══════════════════════════════════════════════════════════════════════════
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = parsePerlImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_in_")
                    .field("detail", "Failed to analyze imports in " ~ source ~ ": " ~ e.msg)
                    .emit();
            }
        }
        
        return allImports;
    }
    
    private Import[] parsePerlImports(string filepath, string content)
    {
        Import[] imports;
        
        auto useRegex = regex(`^\s*(?:use|require)\s+([A-Za-z_]\w*(?:::\w+)*)\s*`, "m");
        
        size_t lineNum = 1;
        foreach (line; lineSplitter(content))
        {
            auto matches = matchFirst(line, useRegex);
            if (!matches.empty && matches.length >= 2)
            {
                Import imp;
                imp.moduleName = matches[1];
                imp.kind = determineImportKind(matches[1]);
                imp.location = SourceLocation(filepath, lineNum, 0);
                imports ~= imp;
            }
            lineNum++;
        }
        
        return imports;
    }
    
    private ImportKind determineImportKind(string moduleName)
    {
        const string[] coreModules = [
            "strict", "warnings", "base", "parent", "Carp", "Data::Dumper",
            "File::Spec", "File::Basename", "File::Path", "Cwd",
            "Getopt::Long", "Getopt::Std", "Time::HiRes", "Scalar::Util",
            "List::Util", "Test::More", "Test2::V0"
        ];
        
        foreach (core; coreModules)
        {
            if (moduleName == core)
                return ImportKind.External;
        }
        
        import std.uni : isLower;
        if (moduleName.indexOf("::") < 0 || (moduleName.length > 0 && isLower(moduleName[0])))
            return ImportKind.Relative;
        
        return ImportKind.External;
    }
}
