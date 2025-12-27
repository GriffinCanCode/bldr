module languages.scripting.perl.core.handler;

import std.stdio;
import std.algorithm;
import std.array;
import std.string : lineSplitter, indexOf;
import std.regex;
import std.file : exists, isFile, readText;
import languages.base.base;
import languages.base.mixins;
import languages.scripting.perl.core.config;
import languages.scripting.perl.services;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig;
import engine.runtime.shutdown.shutdown : ShutdownCoordinator;

/// Thin orchestration layer for Perl builds
/// Delegates all work to specialized services
final class PerlHandler : BaseLanguageHandler
{
    private ActionCache actionCache;
    private IPerlConfigService configService;
    private IPerlDependencyService dependencyService;
    private IPerlQualityService qualityService;
    private IPerlBuildService buildService;
    private IPerlTestService testService;
    private IPerlDocumentationService documentationService;
    
    this()
    {
        // Initialize action cache
        auto cacheConfig = ActionCacheConfig.fromEnvironment();
        actionCache = new ActionCache(".builder-cache/actions/perl", cacheConfig);
        
        // Note: BuildServices handles cache cleanup via shutdown coordinator
        
        // Initialize services
        configService = new PerlConfigService();
        dependencyService = new PerlDependencyService();
        qualityService = new PerlQualityService();
        buildService = new PerlBuildService();
        testService = new PerlTestService();
        documentationService = new PerlDocumentationService();
    }
    
    ~this()
    {
        import core.memory : GC;
        if (actionCache && !GC.inFinalizer())
        {
            try
            {
                actionCache.close();
            }
            catch (Exception) {}
        }
    }
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        structuredLog.debug_("building_perl_target_").field("detail", "Building Perl target: " ~ target.name).emit();
        
        // Parse configuration
        auto perlConfig = configService.parse(target, config);
        
        // Execute build pipeline based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                return buildExecutable(target, config, perlConfig);
                
            case TargetType.Library:
                return buildLibrary(target, config, perlConfig);
                
            case TargetType.Test:
                return runTests(target, config, perlConfig);
                
            case TargetType.Custom:
            case TargetType.Shell:
                return buildCustom(target, config, perlConfig);
        }
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    )
    {
        // Install dependencies
        if (perlConfig.installDeps && !perlConfig.modules.empty)
        {
            if (!dependencyService.install(perlConfig, config.root, actionCache))
            {
                LanguageBuildResult result;
                result.error = "Failed to install dependencies";
                return result;
            }
        }
        
        // Format code
        if (perlConfig.format.autoFormat)
        {
            qualityService.formatCode(target.sources, perlConfig);
        }
        
        // Lint with Perl::Critic
        if (perlConfig.format.formatter == PerlFormatter.PerlCritic ||
            perlConfig.format.formatter == PerlFormatter.Both)
        {
            auto lintResult = qualityService.lintCode(target.sources, perlConfig, actionCache);
            if (!lintResult.success && perlConfig.format.failOnCritic)
            {
                return lintResult;
            }
        }
        
        // Syntax check
        string[] syntaxErrors;
        if (!qualityService.checkSyntax(target.sources, perlConfig, syntaxErrors, actionCache))
        {
            LanguageBuildResult result;
            result.error = "Syntax errors:\n" ~ syntaxErrors.join("\n");
            return result;
        }
        
        // Build executable
        return buildService.buildExecutable(target, config, perlConfig);
    }
    
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    )
    {
        // Install dependencies
        if (perlConfig.installDeps && !perlConfig.modules.empty)
        {
            if (!dependencyService.install(perlConfig, config.root, actionCache))
            {
                LanguageBuildResult result;
                result.error = "Failed to install dependencies";
                return result;
            }
        }
        
        // Syntax check
        string[] syntaxErrors;
        if (!qualityService.checkSyntax(target.sources, perlConfig, syntaxErrors, actionCache))
        {
            LanguageBuildResult result;
            result.error = "Syntax errors:\n" ~ syntaxErrors.join("\n");
            return result;
        }
        
        // Build library
        LanguageBuildResult result;
        
        if (perlConfig.mode == PerlBuildMode.CPAN)
        {
            result = buildService.buildCPAN(target, config, perlConfig, actionCache);
        }
        else
        {
            result = buildService.buildLibrary(target, config, perlConfig);
        }
        
        // Generate documentation
        if (result.success && perlConfig.documentation.generator != PerlDocGenerator.None)
        {
            documentationService.generate(target.sources, perlConfig, config.root, actionCache);
        }
        
        return result;
    }
    
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    )
    {
        return testService.run(target, perlConfig, config.root, actionCache);
    }
    
    private LanguageBuildResult buildCustom(
        in Target target,
        in WorkspaceConfig config,
        in PerlConfig perlConfig
    )
    {
        import infrastructure.utils.files.hash : FastHash;
        
        // Syntax check only
        string[] syntaxErrors;
        if (!qualityService.checkSyntax(target.sources, perlConfig, syntaxErrors, actionCache))
        {
            LanguageBuildResult result;
            result.error = "Syntax errors:\n" ~ syntaxErrors.join("\n");
            return result;
        }
        
        LanguageBuildResult result;
        result.success = true;
        result.outputHash = FastHash.hashStrings(target.sources);
        return result;
    }
    
    override Import[] analyzeImports(in string[] sources)
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
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source ~ ": " ~ e.msg).emit();
            }
        }
        
        return allImports;
    }
    
    private Import[] parsePerlImports(string filepath, string content)
    {
        Import[] imports;
        
        // Match: use Module; or require Module;
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
        // Core modules
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
        
        // Relative imports (single-word or lowercase start)
        import std.uni : isLower;
        if (moduleName.indexOf("::") < 0 || (moduleName.length > 0 && isLower(moduleName[0])))
            return ImportKind.Relative;
        
        // External (CPAN modules)
        return ImportKind.External;
    }
}
