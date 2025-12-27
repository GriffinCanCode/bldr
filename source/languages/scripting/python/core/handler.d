module languages.scripting.python.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import languages.base.base;
import languages.base.mixins;
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
class PythonHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"python";
    mixin ConfigParsingMixin!(PyConfig, "parsePyConfig", ["python", "pyConfig"]);
    mixin OutputResolutionMixin!(PyConfig, "parsePyConfig");
    mixin BuildOrchestrationMixin!(PyConfig, "parsePyConfig", string);
    
    private string setupBuildContext(PyConfig pyConfig, in WorkspaceConfig config)
    {
        return setupPythonEnvironment(pyConfig, config.root);
    }
    
    private void enhanceConfigFromProject(
        ref PyConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        if (target.sources.empty)
            return;
        
        string sourceDir = dirName(target.sources[0]);
        
        if (config.packageManager == PyPackageManager.Auto)
        {
            config.packageManager = PackageManagerFactory.detectFromProject(sourceDir);
            structuredLog.debug_("detected_package_manager_").field("detail", "Detected package manager: " ~ config.packageManager.to!string).emit();
        }
        
        if (config.venv.enabled && config.venv.tool == VirtualEnvConfig.Tool.Auto)
        {
            config.venv.tool = VirtualEnv.detectProjectType(sourceDir);
        }
        
        if (config.requirementsFiles.empty)
        {
            auto depFiles = DependencyAnalyzer.findDependencyFiles(sourceDir);
            if (!depFiles.empty)
            {
                structuredLog.debug_("found_dependency_files_").field("detail", "Found dependency files: " ~ depFiles.join(", ")).emit();
                config.requirementsFiles = depFiles;
            }
        }
    }
    
    private LanguageBuildResult buildExecutable(
        in Target target,
        in WorkspaceConfig config,
        PyConfig pyConfig,
        string pythonCmd
    )
    {
        LanguageBuildResult result;
        
        // Handle empty sources gracefully - Python is interpreted, no sources = nothing to do
        if (target.sources.empty)
        {
            structuredLog.warning("no_source_files_for_python_target_").field("detail", "No source files for Python target '" ~ target.name ~ "', skipping build").emit();
            result.success = true;
            result.outputHash = "";
            return result;
        }
        
        if (pyConfig.installDeps && !installDependencies(pyConfig, config.root, pythonCmd))
        {
            result.error = "Failed to install dependencies";
            return result;
        }

        if (pyConfig.autoFormat && pyConfig.formatter != PyFormatter.None)
        {
            structuredLog.info("autoformatting_code").emit();
            auto fmtResult = Formatter.format(target.sources, pyConfig.formatter, pythonCmd, false);
            if (!fmtResult.success)
                structuredLog.warning("formatting_failed_continuing_anyway").emit();
        }

        if (pyConfig.autoLint && pyConfig.linter != PyLinter.None)
        {
            structuredLog.info("autolinting_code").emit();
            lintWithCaching(target.sources, pyConfig, target.name, pythonCmd);
        }

        if (pyConfig.typeCheck.enabled)
        {
            structuredLog.info("running_type_checking").emit();
            auto typeResult = typeCheckWithCaching(target.sources, pyConfig, target.name, pythonCmd);
            
            if (!typeResult.success)
            {
                result.error = typeResult.error;
                return result;
            }
        }

        // Python is interpreted - validation is optional, not blocking
        // For Script mode, just check syntax and continue even with warnings
        PyValidationResult validationResult;
        bool validationRan = false;
        
        try
        {
            validationResult = PyValidator.validate(target.sources);
            validationRan = true;
            
            if (!validationResult.success)
            {
                // Script mode: warn but continue for interpreted language
                if (pyConfig.mode == PyBuildMode.Script)
                {
                    structuredLog.warning("python_validation_issues_continuing_for_").field("detail", "Python validation issues (continuing for script mode): " ~ validationResult.firstError()).emit();
                }
                else
                {
                    // Other modes: fail on validation error
                    result.error = validationResult.firstError();
                    return result;
                }
            }
        }
        catch (Exception e)
        {
            // Validator not available or failed - warn but don't block for interpreted language
            structuredLog.warning("python_validator_unavailable_skipping_sy").field("detail", "Python validator unavailable, skipping syntax check: " ~ e.msg).emit();
        }

        // For Script mode, skip wrapper generation - just run the script directly
        if (pyConfig.mode == PyBuildMode.Script)
        {
            // Script mode: sources are already executable, no wrapper needed
            result.success = true;
            result.outputs = target.sources.dup;
            result.outputHash = FastHash.hashStrings(target.sources);
            
            if (pyConfig.compileBytecode)
                compileToBytecodeWithCaching(target.sources, pyConfig, target.name, pythonCmd);
            
            return result;
        }

        // Application/Package modes: generate wrapper if we have valid entry point info
        auto outputs = getOutputs(target, config);
        if (!outputs.empty && !target.sources.empty)
        {
            auto outputPath = outputs[0];
            auto mainFile = target.sources[0];
            
            // Use validation result if available, otherwise create minimal entry point info
            WrapperConfig wrapperConfig;
            wrapperConfig.mainFile = mainFile;
            wrapperConfig.outputPath = outputPath;
            wrapperConfig.projectRoot = config.root.empty ? "." : config.root;
            
            if (validationRan && !validationResult.files.empty)
            {
                auto mainFileResult = validationResult.files[0];
                wrapperConfig.hasMain = mainFileResult.hasMain;
                wrapperConfig.hasMainGuard = mainFileResult.hasMainGuard;
                wrapperConfig.isExecutable = mainFileResult.isExecutable;
            }
            else
            {
                // Fallback: assume it's a basic script
                wrapperConfig.hasMain = false;
                wrapperConfig.hasMainGuard = false;
                wrapperConfig.isExecutable = false;
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
            }
            catch (Exception e)
            {
                result.error = "Invalid output directory: " ~ e.msg;
                return result;
            }

            try
            {
                PyWrapperGenerator.generate(wrapperConfig);
            }
            catch (Exception e)
            {
                // For interpreted languages, wrapper generation failure is not fatal
                structuredLog.warning("failed_to_generate_wrapper_").field("detail", "Failed to generate wrapper: " ~ e.msg ~ " (sources remain runnable)").emit();
            }
        }

        if (pyConfig.compileBytecode)
            compileToBytecodeWithCaching(target.sources, pyConfig, target.name, pythonCmd);

        result.success = true;
        result.outputs = outputs;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult buildLibrary(
        in Target target,
        in WorkspaceConfig config,
        PyConfig pyConfig,
        string pythonCmd
    )
    {
        LanguageBuildResult result;
        
        // Handle empty sources gracefully for interpreted language
        if (target.sources.empty)
        {
            structuredLog.warning("no_source_files_for_python_library_").field("detail", "No source files for Python library '" ~ target.name ~ "', skipping build").emit();
            result.success = true;
            result.outputs = [];
            result.outputHash = "";
            return result;
        }
        
        if (pyConfig.installDeps && !installDependencies(pyConfig, config.root, pythonCmd))
        {
            result.error = "Failed to install dependencies";
            return result;
        }
        
        if (pyConfig.typeCheck.enabled)
        {
            structuredLog.info("running_type_checking").emit();
            auto typeResult = TypeChecker.check(target.sources, pyConfig.typeCheck, pythonCmd);
            
            if (typeResult.hasErrors)
            {
                result.error = "Type checking failed:\n" ~ typeResult.errors.join("\n");
                return result;
            }
        }
        
        // Validation for libraries - soft fail for interpreted language
        try
        {
            auto validationResult = PyValidator.validate(target.sources);
            if (!validationResult.success)
            {
                // For Script mode libraries, just warn
                if (pyConfig.mode == PyBuildMode.Script)
                {
                    structuredLog.warning("python_library_validation_issues_").field("detail", "Python library validation issues: " ~ validationResult.firstError()).emit();
                }
                else
                {
                    result.error = validationResult.firstError();
                    return result;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("python_validator_unavailable_skipping_sy").field("detail", "Python validator unavailable, skipping syntax check: " ~ e.msg).emit();
        }
        
        if (pyConfig.generateStubs)
            generateStubs(target.sources, pythonCmd);
        
        result.success = true;
        result.outputs = target.sources.dup;
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runTests(
        in Target target,
        in WorkspaceConfig config,
        PyConfig pyConfig,
        string pythonCmd
    )
    {
        LanguageBuildResult result;
        
        auto runner = pyConfig.test.runner;
        if (runner == PyTestRunner.Auto)
            runner = detectTestRunner(target, pythonCmd);
        
        final switch (runner)
        {
            case PyTestRunner.Auto:
                runner = PyTestRunner.Pytest;
                goto case PyTestRunner.Pytest;
                
            case PyTestRunner.Pytest:
                if (!PyTools.isPytestAvailable(pythonCmd))
                {
                    result.error = "pytest not available (install: pip install pytest)";
                    return result;
                }
                result = runPytest(target, pyConfig, pythonCmd);
                break;
                
            case PyTestRunner.Unittest:
                result = runUnittest(target, pyConfig, pythonCmd);
                break;
                
            case PyTestRunner.Nose2:
                result = runNose2(target, pyConfig, pythonCmd);
                break;
                
            case PyTestRunner.Tox:
                result = runTox(target, pyConfig);
                break;
                
            case PyTestRunner.None:
                result.success = true;
                break;
        }
        
        return result;
    }
    
    // ===== Helper methods =====
    
    private string setupPythonEnvironment(PyConfig config, string projectRoot)
    {
        string pythonCmd = "python3";
        
        if (!config.pythonVersion.interpreterPath.empty)
            pythonCmd = config.pythonVersion.interpreterPath;
        
        if (config.venv.enabled)
        {
            string venvPath = VirtualEnv.ensureVenv(config.venv, projectRoot, pythonCmd);
            
            if (!venvPath.empty)
                pythonCmd = VirtualEnv.getVenvPython(venvPath);
        }
        
        return pythonCmd;
    }
    
    private bool installDependencies(PyConfig config, string projectRoot, string pythonCmd)
    {
        if (!config.requirementsFiles.empty)
        {
            structuredLog.info("installing_dependencies").emit();
            auto installer = PackageManagerFactory.create(config.packageManager);
            foreach (reqFile; config.requirementsFiles)
            {
                auto result = installer.installFromFile(reqFile);
                if (!result.success)
                    return false;
            }
            return true;
        }
        return true;
    }
    
    private PyTestRunner detectTestRunner(in Target target, string pythonCmd)
    {
        if (PyTools.isPytestAvailable(pythonCmd))
            return PyTestRunner.Pytest;
        return PyTestRunner.Unittest;
    }
    
    private LanguageBuildResult runPytest(in Target target, PyConfig config, string pythonCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = [pythonCmd, "-m", "pytest"];
        cmd ~= config.test.pytestArgs;
            cmd ~= target.sources;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "pytest failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runUnittest(in Target target, PyConfig config, string pythonCmd)
    {
        LanguageBuildResult result;
        
        string[] cmd = [pythonCmd, "-m", "unittest"];
        cmd ~= config.test.unittestArgs;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "unittest failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private LanguageBuildResult runNose2(in Target target, PyConfig config, string pythonCmd)
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
    
    private LanguageBuildResult runTox(in Target target, PyConfig config)
    {
        LanguageBuildResult result;
        
        string[] cmd = ["tox"];
        cmd ~= config.test.toxArgs;
        
        auto res = execute(cmd);
        result.success = (res.status == 0);
        if (!result.success)
            result.error = "tox failed";
        result.outputHash = FastHash.hashStrings(target.sources);
        
        return result;
    }
    
    private void lintWithCaching(const string[] sources, PyConfig config, string targetId, string pythonCmd)
    {
        string[string] metadata;
        metadata["pythonVersion"] = PyTools.getPythonVersion(pythonCmd);
        metadata["linter"] = config.linter.to!string;
        
        foreach (source; sources)
        {
            auto actionId = ActionId(targetId, ActionType.Custom, FastHash.hashFile(source), "lint:" ~ source);
            
            if (getCache().isCached(actionId, [source], metadata))
            {
                structuredLog.debug_("__cached_lint_").field("detail", "  [Cached] Lint: " ~ source).emit();
                continue;
            }
            
            auto lintResult = Linter.lint([source], config.linter, pythonCmd);
            bool success = lintResult.success;
            
            getCache().update(actionId, [source], [], metadata, success);
            
            if (!success && lintResult.hasIssues())
            {
                structuredLog.warning("lint_issues_in_").field("detail", "Lint issues in " ~ source ~ ":").emit();
                if (!lintResult.errors.empty)
                {
                    foreach (error; lintResult.errors[0 .. min(3, $)])
                        structuredLog.warning("__error_").field("detail", "  Error: " ~ error).emit();
                }
                if (!lintResult.warnings.empty)
                {
                    foreach (warning; lintResult.warnings[0 .. min(3, $)])
                        structuredLog.warning("__warning_").field("detail", "  Warning: " ~ warning).emit();
                }
            }
        }
    }
    
    private struct TypeCheckResult
    {
        bool success;
        string error;
    }
    
    private TypeCheckResult typeCheckWithCaching(const string[] sources, PyConfig config, string targetId, string pythonCmd)
    {
        TypeCheckResult result;
        result.success = true;
        
        string[string] metadata;
        metadata["pythonVersion"] = PyTools.getPythonVersion(pythonCmd);
        metadata["typeChecker"] = config.typeCheck.checker.to!string;
        
        auto actionId = ActionId(targetId, ActionType.Custom, FastHash.hashStrings(sources), "typecheck");
        actionId.inputHash = FastHash.hashStrings(sources);
        
        if (getCache().isCached(actionId, sources, metadata))
        {
            structuredLog.debug_("__cached_type_checking").emit();
            return result;
        }
        
        auto typeResult = TypeChecker.check(sources, config.typeCheck, pythonCmd);
        bool success = !typeResult.hasErrors;
        
        getCache().update(actionId, sources, [], metadata, success);
        
        if (!success)
            result.error = "Type checking failed:\n" ~ typeResult.errors.join("\n");
        
        result.success = success;
        return result;
    }
    
    private void compileToBytecodeWithCaching(const string[] sources, PyConfig config, string targetId, string pythonCmd)
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
                structuredLog.debug_("__cached_bytecode_").field("detail", "  [Cached] Bytecode: " ~ source).emit();
                continue;
            }
            
            auto cmd = [pythonCmd, "-m", "py_compile", source];
            auto res = execute(cmd);
            bool success = (res.status == 0);
            
            getCache().update(actionId, [source], outputs, metadata, success);
            
            if (!success)
                structuredLog.warning("failed_to_compile_").field("detail", "Failed to compile " ~ source ~ " to bytecode").emit();
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
    
    /// Analyze imports in Python source files
    override Import[] analyzeImports(in string[] sources) @system
    {
        import std.file : readText, exists, isFile;
        
        auto spec = getLanguageSpec(TargetLanguage.Python);
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
                // Silently skip unreadable files
            }
        }
        
        return allImports;
    }
}
