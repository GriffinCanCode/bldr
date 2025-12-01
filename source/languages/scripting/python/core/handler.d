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
import infrastructure.utils.logging.logger;
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
            Logger.debugLog("Detected package manager: " ~ config.packageManager.to!string);
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
                Logger.debugLog("Found dependency files: " ~ depFiles.join(", "));
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
        
        if (pyConfig.installDeps && !installDependencies(pyConfig, config.root, pythonCmd))
        {
            result.error = "Failed to install dependencies";
            return result;
        }

        if (pyConfig.autoFormat && pyConfig.formatter != PyFormatter.None)
        {
            Logger.info("Auto-formatting code");
            auto fmtResult = Formatter.format(target.sources, pyConfig.formatter, pythonCmd, false);
            if (!fmtResult.success)
                Logger.warning("Formatting failed, continuing anyway");
        }

        if (pyConfig.autoLint && pyConfig.linter != PyLinter.None)
        {
            Logger.info("Auto-linting code");
            lintWithCaching(target.sources, pyConfig, target.name, pythonCmd);
        }

        if (pyConfig.typeCheck.enabled)
        {
            Logger.info("Running type checking");
            auto typeResult = typeCheckWithCaching(target.sources, pyConfig, target.name, pythonCmd);
            
            if (!typeResult.success)
            {
                result.error = typeResult.error;
                return result;
            }
        }

        auto validationResult = PyValidator.validate(target.sources);
        if (!validationResult.success)
        {
            result.error = validationResult.firstError();
            return result;
        }

        auto outputs = getOutputs(target, config);
        if (!outputs.empty && !target.sources.empty)
        {
            auto outputPath = outputs[0];
            auto mainFile = target.sources[0];
            auto mainFileResult = validationResult.files[0];
            
            WrapperConfig wrapperConfig;
            wrapperConfig.mainFile = mainFile;
            wrapperConfig.outputPath = outputPath;
            wrapperConfig.projectRoot = config.root.empty ? "." : config.root;
            wrapperConfig.hasMain = mainFileResult.hasMain;
            wrapperConfig.hasMainGuard = mainFileResult.hasMainGuard;
            wrapperConfig.isExecutable = mainFileResult.isExecutable;
            
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
            catch (Throwable e)
            {
                result.error = "Critical error creating output directory: " ~ e.msg;
                return result;
            }

            try
            {
                PyWrapperGenerator.generate(wrapperConfig);
            }
            catch (Throwable e)
            {
                result.error = "Failed to generate wrapper: " ~ e.msg;
                return result;
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
        
        if (pyConfig.installDeps && !installDependencies(pyConfig, config.root, pythonCmd))
            {
                result.error = "Failed to install dependencies";
                return result;
            }
        
        if (pyConfig.typeCheck.enabled)
        {
            Logger.info("Running type checking");
            auto typeResult = TypeChecker.check(target.sources, pyConfig.typeCheck, pythonCmd);
            
            if (typeResult.hasErrors)
            {
                result.error = "Type checking failed:\n" ~ typeResult.errors.join("\n");
                return result;
            }
        }
        
        auto validationResult = PyValidator.validate(target.sources);
        if (!validationResult.success)
        {
            result.error = validationResult.firstError();
            return result;
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
            Logger.info("Installing dependencies");
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
                Logger.debugLog("  [Cached] Lint: " ~ source);
                continue;
            }
            
            auto lintResult = Linter.lint([source], config.linter, pythonCmd);
            bool success = lintResult.success;
            
            getCache().update(actionId, [source], [], metadata, success);
            
            if (!success && lintResult.hasIssues())
            {
                Logger.warning("Lint issues in " ~ source ~ ":");
                if (!lintResult.errors.empty)
                {
                    foreach (error; lintResult.errors[0 .. min(3, $)])
                        Logger.warning("  Error: " ~ error);
                }
                if (!lintResult.warnings.empty)
                {
                    foreach (warning; lintResult.warnings[0 .. min(3, $)])
                        Logger.warning("  Warning: " ~ warning);
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
            Logger.debugLog("  [Cached] Type checking");
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
                Logger.debugLog("  [Cached] Bytecode: " ~ source);
                continue;
            }
            
            auto cmd = [pythonCmd, "-m", "py_compile", source];
            auto res = execute(cmd);
            bool success = (res.status == 0);
            
            getCache().update(actionId, [source], outputs, metadata, success);
            
            if (!success)
                Logger.warning("Failed to compile " ~ source ~ " to bytecode");
        }
    }
    
    private void generateStubs(const string[] sources, string pythonCmd)
    {
        Logger.info("Generating stub files");
        
        auto cmd = [pythonCmd, "-m", "mypy.stubgen"] ~ sources;
        auto res = execute(cmd);
        
        if (res.status != 0)
            Logger.warning("Failed to generate stubs (install mypy for stub generation)");
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
