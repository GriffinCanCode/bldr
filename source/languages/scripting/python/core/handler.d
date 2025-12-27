module languages.scripting.python.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.json;
import languages.scripting.base;
import languages.scripting.python.core.config;
import languages.scripting.python.managers;
import languages.scripting.python.tooling;
import languages.scripting.python.analysis;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.python.pycheck;
import infrastructure.utils.python.pywrap;
import infrastructure.utils.security : execute;
import std.process : Config;
import engine.caching.actions.action : ActionId, ActionType;

/// Python build handler - comprehensive and modular with action-level caching
/// Extends BaseScriptingHandler for common scripting language infrastructure
class PythonHandler : BaseScriptingHandler
{
    // Store parsed config for use across methods
    private PyConfig _currentConfig;
    private string _currentInterpreterCmd;
    
    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT METHOD IMPLEMENTATIONS
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected string languageId() const pure nothrow @safe => "python";
    
    override protected string[] configKeys() const pure nothrow @safe => ["python", "pyConfig"];
    
    override protected TargetLanguage targetLanguage() const pure nothrow @safe => TargetLanguage.Python;
    
    override protected EnvironmentSetupResult setupEnvironment(JSONValue config, string projectRoot) @system
    {
        // Parse to PyConfig for structured access
        PyConfig pyConfig = PyConfig.fromJSON(config);
        _currentConfig = pyConfig;
        
        string pythonCmd = "python3";
        
        if (!pyConfig.pythonVersion.interpreterPath.empty)
            pythonCmd = pyConfig.pythonVersion.interpreterPath;
        
        if (pyConfig.venv.enabled)
        {
            string venvPath = VirtualEnv.ensureVenv(pyConfig.venv, projectRoot, pythonCmd);
            if (!venvPath.empty)
                pythonCmd = VirtualEnv.getVenvPython(venvPath);
        }
        
        _currentInterpreterCmd = pythonCmd;
        return EnvironmentSetupResult.ok(pythonCmd);
    }
    
    override protected SyntaxValidationResult validateSyntax(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        // For empty sources, nothing to validate
        if (sources.empty)
            return SyntaxValidationResult.ok();
        
        try
        {
            auto validationResult = PyValidator.validate(sources);
            
            if (!validationResult.success)
            {
                // Script mode: warn but continue
                if (_currentConfig.mode == PyBuildMode.Script)
                {
                    structuredLog.warning("python_validation_issues_continuing_for_")
                        .field("detail", "Python validation issues (continuing for script mode): " ~ validationResult.firstError())
                        .emit();
                    return SyntaxValidationResult.ok();
                }
                
                return SyntaxValidationResult.fail([validationResult.firstError()]);
            }
            
            return SyntaxValidationResult.ok();
        }
        catch (Exception e)
        {
            // Validator not available - warn but don't block for interpreted language
            structuredLog.warning("python_validator_unavailable_skipping_sy")
                .field("detail", "Python validator unavailable, skipping syntax check: " ~ e.msg)
                .emit();
            return SyntaxValidationResult.ok();
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // HOOK METHOD OVERRIDES
    // ═══════════════════════════════════════════════════════════════════════════
    
    override protected JSONValue parseConfig(in Target target) @system
    {
        PyConfig config;
        
        foreach (key; configKeys())
        {
            if (key in target.langConfig)
            {
                try
                {
                    auto json = parseJSON(target.langConfig[key]);
                    config = PyConfig.fromJSON(json);
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
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        if (_currentConfig.packageManager == PyPackageManager.Auto)
        {
            _currentConfig.packageManager = PackageManagerFactory.detectFromProject(sourceDir);
            structuredLog.debug_("detected_package_manager_")
                .field("detail", "Detected package manager: " ~ _currentConfig.packageManager.to!string)
                .emit();
        }
        
        if (_currentConfig.venv.enabled && _currentConfig.venv.tool == VirtualEnvConfig.Tool.Auto)
            _currentConfig.venv.tool = VirtualEnv.detectProjectType(sourceDir);
        
        if (_currentConfig.requirementsFiles.empty)
        {
            auto depFiles = DependencyAnalyzer.findDependencyFiles(sourceDir);
            if (!depFiles.empty)
            {
                structuredLog.debug_("found_dependency_files_")
                    .field("detail", "Found dependency files: " ~ depFiles.join(", "))
                    .emit();
                _currentConfig.requirementsFiles = depFiles;
            }
        }
    }
    
    override protected bool shouldInstallDeps(JSONValue config) const @system
        => _currentConfig.installDeps;
    
    override protected bool shouldAutoFormat(JSONValue config) const @system
        => _currentConfig.autoFormat && _currentConfig.formatter != PyFormatter.None;
    
    override protected bool shouldAutoLint(JSONValue config) const @system
        => _currentConfig.autoLint && _currentConfig.linter != PyLinter.None;
    
    override protected bool shouldTypeCheck(JSONValue config) const @system
        => _currentConfig.typeCheck.enabled;
    
    override protected DependencyInstallResult installDependencies(
        JSONValue config,
        string projectRoot,
        string interpreterCmd
    ) @system
    {
        if (_currentConfig.requirementsFiles.empty)
            return DependencyInstallResult.skipped();
        
        structuredLog.info("installing_dependencies").emit();
        auto installer = PackageManagerFactory.create(_currentConfig.packageManager);
        
        foreach (reqFile; _currentConfig.requirementsFiles)
        {
            auto result = installer.installFromFile(reqFile);
            if (!result.success)
                return DependencyInstallResult.fail("Failed to install from " ~ reqFile);
        }
        
        return DependencyInstallResult.ok();
    }
    
    override protected FormatStepResult runFormatter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto fmtResult = Formatter.format(sources, _currentConfig.formatter, interpreterCmd, false);
        return fmtResult.success ? FormatStepResult.ok() : FormatStepResult.fail("Formatting failed");
    }
    
    override protected LintStepResult runLinter(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto lintResult = Linter.lint(sources, _currentConfig.linter, interpreterCmd);
        
        if (!lintResult.success)
        {
            LintStepResult result;
            result.success = false;
            result.errors = lintResult.errors;
            result.warnings = lintResult.warnings;
            result.error = lintResult.hasIssues() ? 
                (lintResult.errors.empty ? lintResult.warnings[0] : lintResult.errors[0]) : "";
            return result;
        }
        
        LintStepResult result;
        result.success = true;
        result.warnings = lintResult.warnings;
        return result;
    }
    
    override protected TypeCheckStepResult runTypeChecker(
        in string[] sources,
        JSONValue config,
        string interpreterCmd
    ) @system
    {
        auto typeResult = TypeChecker.check(sources, _currentConfig.typeCheck, interpreterCmd);
        
        if (typeResult.hasErrors)
        {
            TypeCheckStepResult result;
            result.success = false;
            result.errors = typeResult.errors;
            result.error = typeResult.errors.empty ? "" : typeResult.errors[0];
            return result;
        }
        
        return TypeCheckStepResult.ok();
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
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            structuredLog.warning("no_source_files_for_python_target_")
                .field("detail", "No source files for Python target '" ~ target.name ~ "', skipping build")
                .emit();
            result.success = true;
            result.outputHash = "";
            return result;
        }
        
        // Script mode: sources are already executable
        if (_currentConfig.mode == PyBuildMode.Script)
        {
            result.success = true;
            result.outputs = target.sources.dup;
            result.outputHash = FastHash.hashStrings(target.sources);
            
            if (_currentConfig.compileBytecode)
                compileToBytecodeWithCaching(target.sources, target.name, interpreterCmd);
            
            return result;
        }
        
        // Application/Package modes: generate wrapper
        auto outputs = getOutputs(target, config);
        if (!outputs.empty && !target.sources.empty)
        {
            auto outputPath = outputs[0];
            auto mainFile = target.sources[0];
            
            // Get validation result for wrapper config
            PyValidationResult validationResult;
            try { validationResult = PyValidator.validate(target.sources); }
            catch (Exception) {}
            
            WrapperConfig wrapperConfig;
            wrapperConfig.mainFile = mainFile;
            wrapperConfig.outputPath = outputPath;
            wrapperConfig.projectRoot = config.root.empty ? "." : config.root;
            
            if (!validationResult.files.empty)
            {
                auto mainFileResult = validationResult.files[0];
                wrapperConfig.hasMain = mainFileResult.hasMain;
                wrapperConfig.hasMainGuard = mainFileResult.hasMainGuard;
                wrapperConfig.isExecutable = mainFileResult.isExecutable;
            }
            
            try
            {
                auto outputDir = dirName(outputPath);
                if (exists(outputDir) && !isDir(outputDir))
                {
                    result.error = "Output directory path component is a file: " ~ outputDir;
                    return result;
                }
                if (!exists(outputDir))
                    mkdirRecurse(outputDir);
                
                PyWrapperGenerator.generate(wrapperConfig);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_generate_wrapper_")
                    .field("detail", "Failed to generate wrapper: " ~ e.msg ~ " (sources remain runnable)")
                    .emit();
            }
        }
        
        if (_currentConfig.compileBytecode)
            compileToBytecodeWithCaching(target.sources, target.name, interpreterCmd);
        
        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    override protected LanguageBuildResult buildLibraryImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        LanguageBuildResult result;
        
        if (target.sources.empty)
        {
            structuredLog.warning("no_source_files_for_python_library_")
                .field("detail", "No source files for Python library '" ~ target.name ~ "', skipping build")
                .emit();
            result.success = true;
            result.outputs = [];
            result.outputHash = "";
            return result;
        }
        
        if (_currentConfig.generateStubs)
            generateStubs(target.sources, interpreterCmd);
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    override protected LanguageBuildResult runTestsImpl(
        in Target target,
        in WorkspaceConfig config,
        JSONValue langConfig,
        string interpreterCmd
    ) @system
    {
        auto runner = _currentConfig.test.runner;
        if (runner == PyTestRunner.Auto)
            runner = detectTestRunner(target, interpreterCmd);
        
        final switch (runner)
        {
            case PyTestRunner.Auto:
                runner = PyTestRunner.Pytest;
                goto case PyTestRunner.Pytest;
                
            case PyTestRunner.Pytest:
                if (!PyTools.isPytestAvailable(interpreterCmd))
                {
                    LanguageBuildResult result;
                    result.error = "pytest not available (install: pip install pytest)";
                    return result;
                }
                return runPytest(target, interpreterCmd);
                
            case PyTestRunner.Unittest:
                return runUnittest(target, interpreterCmd);
                
            case PyTestRunner.Nose2:
                return runNose2(target, interpreterCmd);
                
            case PyTestRunner.Tox:
                return runTox(target);
                
            case PyTestRunner.None:
                LanguageBuildResult result;
                result.success = true;
                return result;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════════
    // PYTHON-SPECIFIC HELPER METHODS
    // ═══════════════════════════════════════════════════════════════════════════
    
    private PyTestRunner detectTestRunner(in Target target, string pythonCmd)
    {
        if (PyTools.isPytestAvailable(pythonCmd))
            return PyTestRunner.Pytest;
        return PyTestRunner.Unittest;
    }
    
    private LanguageBuildResult runPytest(in Target target, string pythonCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = [pythonCmd, "-m", "pytest"];
        cmd ~= _currentConfig.test.pytestArgs;
        cmd ~= target.sources;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "pytest failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runUnittest(in Target target, string pythonCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = [pythonCmd, "-m", "unittest"];
        cmd ~= _currentConfig.test.unittestArgs;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "unittest failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runNose2(in Target target, string pythonCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = [pythonCmd, "-m", "nose2"];
        cmd ~= target.sources;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "nose2 failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runTox(in Target target)
    {
        LanguageBuildResult result;
        
        string[] cmd = ["tox"];
        cmd ~= _currentConfig.test.toxArgs;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "tox failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private void compileToBytecodeWithCaching(const string[] sources, string targetId, string pythonCmd)
    {
        string[string] metadata;
        metadata["pythonVersion"] = PyTools.getPythonVersion(pythonCmd);
        
        foreach (source; sources)
        {
            auto actionId = ActionId(targetId, ActionType.Compile, FastHash.hashFile(source), source);
            actionId.inputHash = FastHash.hashFile(source);
            
            string outputFile = source ~ "c";
            string[] outputs = [outputFile];
            
            if (getCache().isCached(actionId, [source], metadata))
            {
                structuredLog.debug_("__cached_bytecode_")
                    .field("detail", "  [Cached] Bytecode: " ~ source)
                    .emit();
                continue;
            }
            
            auto cmd = [pythonCmd, "-m", "py_compile", source];
            auto res = execute(cmd);
            bool success = (res.status == 0);
            
            getCache().update(actionId, [source], outputs, metadata, success);
            
            if (!success)
                structuredLog.warning("failed_to_compile_")
                    .field("detail", "Failed to compile " ~ source ~ " to bytecode")
                    .emit();
        }
    }
    
    private void generateStubs(const string[] sources, string pythonCmd)
    {
        structuredLog.info("generating_stub_files").emit();
        
        auto cmd = [pythonCmd, "-m", "mypy.stubgen"] ~ sources;
        auto res = execute(cmd);
        
        if (res.status != 0)
            structuredLog.warning("failed_to_generate_stubs_install_mypy_fo").emit();
    }
}
