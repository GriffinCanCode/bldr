module languages.scripting.lua.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import languages.scripting.base;
import languages.scripting.lua.core.config;
import languages.scripting.lua.tooling.detection;
import languages.scripting.lua.tooling.builders;
import languages.scripting.lua.managers.luarocks;
import languages.scripting.lua.tooling.detection : isLuaRocksAvailable;
import languages.scripting.lua.tooling.formatters;
import languages.scripting.lua.tooling.checkers;
import languages.scripting.lua.tooling.testers;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.process : isCommandAvailable;
import infrastructure.utils.security : execute;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// Lua language build handler with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class LuaHandler : BaseScriptingHandler
{
    private LuaConfig _currentConfig;
    private ActionCache _luaActionCache;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "lua";
    
    override protected string[] configKeys() const pure nothrow @safe => ["lua", "luaConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.Lua;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        LuaConfig luaConfig = LuaConfig.fromJSON(config);
        _currentConfig = luaConfig;
        
        // Auto-detect runtime if needed
        if (luaConfig.runtime == LuaRuntime.Auto)
        {
            luaConfig.runtime = detectRuntime();
            _currentConfig.runtime = luaConfig.runtime;
            structuredLog.debug_("autodetected_runtime_")
                .field("detail", "Auto-detected runtime: " ~ runtimeToString(luaConfig.runtime))
                .emit();
        }
        
        string luaCmd = getLuaInterpreter(luaConfig);
        if (luaCmd.empty)
            return EnvironmentSetupResult.fail("No Lua interpreter found");
        
        return EnvironmentSetupResult.ok(luaCmd);
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        string compiler = getLuaCompiler(_currentConfig);
        
        if (compiler.empty)
        {
            structuredLog.warning("no_lua_compiler_for_syntax_check").emit();
            return SyntaxValidationResult.ok();
        }
        
        string[] allErrors;
        
        foreach (source; sources)
        {
            auto cmd = [compiler, "-p", source];
            auto res = execute(cmd);
            
            if (res.status != 0)
                allErrors ~= "Syntax error in " ~ source ~ ": " ~ res.output;
        }
        
        if (!allErrors.empty)
            return SyntaxValidationResult.fail(allErrors);
        
        return SyntaxValidationResult.ok();
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        LuaConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = LuaConfig.fromJSON(json);
                    _currentConfig = config;
                    return json;
                }
                catch (Exception e)
                {
                    structuredLog.warning("config_parse_fallback").field("key", key).emit();
                }
            }
        }
        
        _currentConfig = config;
        return JSONValue.init;
    }
    
    override protected void enhanceConfigFromProject(
        ref JSONValue config,
        in Target target,
        in WorkspaceConfig workspace
    ) @system
    {
        // Validate configuration
        auto validation = validateConfig(_currentConfig, target);
        if (!validation.empty)
            structuredLog.warning("configuration_validation_failed_")
                .field("detail", "Configuration validation failed: " ~ validation)
                .emit();
    }
    
    override protected bool shouldInstallDeps(JSONValue config) const @system
        => _currentConfig.installDeps || _currentConfig.luarocks.autoInstall;
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.format.autoFormat;
    
    override protected bool shouldAutoLint(JSONValue config) const @system
        => _currentConfig.lint.enabled;
    
    override protected bool shouldFailOnLintError(JSONValue config) const @system
        => _currentConfig.lint.failOnWarning;
    
    override protected DependencyInstallResult installDependencies(
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        if (!_currentConfig.luarocks.enabled)
            return DependencyInstallResult.skipped();
        
        if (!isLuaRocksAvailable())
            return DependencyInstallResult.fail("LuaRocks is not installed or not in PATH");
        
        auto manager = new LuaRocksManager(_currentConfig.luarocks);
        
        // Check for rockspec file
        string rockspecFile = findRockspec(projectRoot);
        
        if (!rockspecFile.empty)
        {
            structuredLog.info("installing_dependencies_from_rockspec_")
                .field("detail", "Installing dependencies from rockspec: " ~ rockspecFile)
                .emit();
            auto result = manager.installDependencies(rockspecFile);
            if (!result.success)
                return DependencyInstallResult.fail(result.error);
        }
        else if (!_currentConfig.luarocks.dependencies.empty)
        {
            structuredLog.info("installing_")
                .field("detail", "Installing " ~ _currentConfig.luarocks.dependencies.length.to!string ~ " rocks")
                .emit();
            
            foreach (rock; _currentConfig.luarocks.dependencies)
            {
                auto rockResult = manager.installRock(rock);
                if (!rockResult.success)
                    return DependencyInstallResult.fail("Failed to install rock '" ~ rock ~ "': " ~ rockResult.error);
                
                structuredLog.info("installed_rock_")
                    .field("detail", "Installed rock: " ~ rock)
                    .emit();
            }
        }
        
        return DependencyInstallResult.ok();
    }
    
    override protected FormatStepResult runFormatter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto formatter = FormatterFactory.create(_currentConfig.format.formatter, _currentConfig);
        
        if (!formatter.isAvailable())
            return FormatStepResult.fail("Formatter not available");
        
        auto fmtResult = formatter.format(sources, _currentConfig);
        return fmtResult.success ? FormatStepResult.ok() : FormatStepResult.fail(fmtResult.error);
    }
    
    override protected LintStepResult runLinter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto checker = CheckerFactory.create(_currentConfig.lint.linter, _currentConfig);
        
        if (!checker.isAvailable())
            return LintStepResult.fail(["Linter not available"]);
        
        auto checkResult = checker.check(sources, _currentConfig);
        
        if (!checkResult.success)
        {
            LintStepResult result;
            result.success = false;
            result.error = checkResult.error;
            return result;
        }
        
        return LintStepResult.ok();
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            
            final switch (_currentConfig.mode)
            {
                case LuaBuildMode.Script:
                    outputs ~= buildPath(config.options.outputDir, name);
                    break;
                case LuaBuildMode.Bytecode:
                    if (!_currentConfig.bytecode.outputFile.empty)
                        outputs ~= buildPath(config.options.outputDir, _currentConfig.bytecode.outputFile);
                    else
                        outputs ~= buildPath(config.options.outputDir, name ~ ".luac");
                    break;
                case LuaBuildMode.Library:
                    outputs ~= buildPath(config.options.outputDir, name ~ ".lua");
                    break;
                case LuaBuildMode.Rock:
                    outputs ~= buildPath(config.options.outputDir, name ~ "-rock");
                    break;
                case LuaBuildMode.Application:
                    outputs ~= buildPath(config.options.outputDir, name);
                    break;
            }
        }
        
        return outputs;
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
        auto builder = selectBuilder(_currentConfig);
        builder.setActionCache(getCache());
        auto buildResult = builder.build(target.sources, _currentConfig, target, config);
        
        LanguageBuildResult result;
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        return result;
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        if (_currentConfig.mode == LuaBuildMode.Script)
            _currentConfig.mode = LuaBuildMode.Library;
        
        auto builder = selectBuilder(_currentConfig);
        builder.setActionCache(getCache());
        auto buildResult = builder.build(target.sources, _currentConfig, target, config);
        
        LanguageBuildResult result;
        result.success = buildResult.success;
        result.error = buildResult.error;
        result.outputs = buildResult.outputs;
        result.outputHash = buildResult.outputHash;
        
        return result;
    }
    
    override protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        if (_currentConfig.test.framework == LuaTestFramework.Auto)
        {
            _currentConfig.test.framework = detectTestFramework(target);
            structuredLog.debug_("autodetected_test_framework_")
                .field("detail", "Auto-detected test framework: " ~ testFrameworkToString(_currentConfig.test.framework))
                .emit();
        }
        
        auto tester = TesterFactory.create(_currentConfig.test.framework, _currentConfig);
        
        if (!tester.isAvailable())
        {
            LanguageBuildResult result;
            result.error = "Test framework '" ~ testFrameworkToString(_currentConfig.test.framework) ~ 
                          "' is not available. Please install it.";
            return result;
        }
        
        auto testResult = tester.runTests(target.sources, _currentConfig, target, config);
        
        LanguageBuildResult result;
        result.success = testResult.success;
        result.error = testResult.error;
        result.outputHash = testResult.outputHash;
        
        return result;
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // LUA-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private string validateConfig(LuaConfig config, const Target target) @system
    {
        import std.format : format;
        
        if (target.sources.empty)
            return "No source files specified";
        
        foreach (source; target.sources)
        {
            if (!exists(source))
                return format("Source file not found: %s", source);
        }
        
        if (config.runtime == LuaRuntime.LuaJIT && config.luajit.enabled)
        {
            if (!isCommandAvailable("luajit"))
                return "LuaJIT runtime selected but luajit command not found";
        }
        
        if (config.mode == LuaBuildMode.Bytecode)
        {
            if (!isCommandAvailable("luac") && !config.luajit.bytecode)
                return "Bytecode mode requires luac compiler";
        }
        
        if (config.mode == LuaBuildMode.Rock)
        {
            if (!config.luarocks.enabled)
                return "Rock mode requires LuaRocks to be enabled";
            if (!isCommandAvailable("luarocks"))
                return "LuaRocks is not installed";
        }
        
        return "";
    }
    
    private string findRockspec(string projectRoot) @system
    {
        try
        {
            auto entries = dirEntries(projectRoot, "*.rockspec", SpanMode.shallow);
            foreach (entry; entries)
            {
                if (entry.isFile)
                    return entry.name;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_search_for_rockspec_")
                .field("detail", "Failed to search for rockspec: " ~ e.msg)
                .emit();
        }
        
        return "";
    }
    
    private string getLuaInterpreter(LuaConfig config) @system
    {
        if (config.luajit.enabled && isCommandAvailable("luajit"))
            return "luajit";
        
        if (isCommandAvailable("lua"))
            return "lua";
        
        final switch (config.runtime)
        {
            case LuaRuntime.Auto:
            case LuaRuntime.System:
                if (isCommandAvailable("lua")) return "lua";
                break;
            case LuaRuntime.Lua51:
                if (isCommandAvailable("lua5.1")) return "lua5.1";
                break;
            case LuaRuntime.Lua52:
                if (isCommandAvailable("lua5.2")) return "lua5.2";
                break;
            case LuaRuntime.Lua53:
                if (isCommandAvailable("lua5.3")) return "lua5.3";
                break;
            case LuaRuntime.Lua54:
                if (isCommandAvailable("lua5.4")) return "lua5.4";
                break;
            case LuaRuntime.LuaJIT:
                if (isCommandAvailable("luajit")) return "luajit";
                break;
        }
        
        return "";
    }
    
    private string getLuaCompiler(LuaConfig config) @system
    {
        if (config.luajit.enabled && isCommandAvailable("luajit"))
            return "luajit";
        
        if (isCommandAvailable("luac"))
            return "luac";
        
        final switch (config.runtime)
        {
            case LuaRuntime.Auto:
            case LuaRuntime.System:
                if (isCommandAvailable("luac")) return "luac";
                break;
            case LuaRuntime.Lua51:
                if (isCommandAvailable("luac5.1")) return "luac5.1";
                break;
            case LuaRuntime.Lua52:
                if (isCommandAvailable("luac5.2")) return "luac5.2";
                break;
            case LuaRuntime.Lua53:
                if (isCommandAvailable("luac5.3")) return "luac5.3";
                break;
            case LuaRuntime.Lua54:
                if (isCommandAvailable("luac5.4")) return "luac5.4";
                break;
            case LuaRuntime.LuaJIT:
                if (isCommandAvailable("luajit")) return "luajit";
                break;
        }
        
        return "";
    }
    
    private LuaBuilder selectBuilder(LuaConfig config) @system
        => BuilderFactory.create(config.mode, config, _luaActionCache);
    
    private LuaTestFramework detectTestFramework(const Target target) @system
    {
        if (isCommandAvailable("busted"))
            return LuaTestFramework.Busted;
        
        foreach (source; target.sources)
        {
            if (exists(source) && isFile(source))
            {
                try
                {
                    auto content = readText(source);
                    if (content.canFind("require") && content.canFind("luaunit"))
                        return LuaTestFramework.LuaUnit;
                }
                catch (Exception) {}
            }
        }
        
        return isCommandAvailable("busted") ? LuaTestFramework.Busted : LuaTestFramework.LuaUnit;
    }
    
    private string runtimeToString(LuaRuntime runtime) @system pure nothrow
    {
        final switch (runtime)
        {
            case LuaRuntime.Auto: return "auto";
            case LuaRuntime.Lua51: return "Lua 5.1";
            case LuaRuntime.Lua52: return "Lua 5.2";
            case LuaRuntime.Lua53: return "Lua 5.3";
            case LuaRuntime.Lua54: return "Lua 5.4";
            case LuaRuntime.LuaJIT: return "LuaJIT";
            case LuaRuntime.System: return "System Lua";
        }
    }
    
    private string testFrameworkToString(LuaTestFramework framework) @system pure nothrow
    {
        final switch (framework)
        {
            case LuaTestFramework.Auto: return "auto";
            case LuaTestFramework.Busted: return "Busted";
            case LuaTestFramework.LuaUnit: return "LuaUnit";
            case LuaTestFramework.Telescope: return "Telescope";
            case LuaTestFramework.TestMore: return "TestMore";
            case LuaTestFramework.None: return "none";
        }
    }
}
