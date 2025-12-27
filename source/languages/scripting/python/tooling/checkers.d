module languages.scripting.python.tooling.checkers;

import std.process : Config;
import infrastructure.utils.security : execute;  // SECURITY: Auto-migrated
import std.file;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.python.core.config;
import languages.scripting.python.tooling.results;
import languages.scripting.python.tooling.detection;
import infrastructure.utils.logging;

/// Type checking utilities
class PyCheckers
{
    /// Type check Python code with mypy
    static ToolResult typeCheckMypy(string[] sources, string pythonCmd = "python3", string[] extraArgs = [])
    {
        ToolResult result;
        
        if (!ToolDetection.isMypyAvailable(pythonCmd))
        {
            result.warnings ~= "mypy not available (install: pip install mypy)";
            result.success = true;
            return result;
        }
        
        string[] cmd = [pythonCmd, "-m", "mypy"] ~ extraArgs ~ sources;
        
        structuredLog.debug_("running_mypy_").field("detail", "Running mypy: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        result.output = res.output;
        
        if (res.status != 0)
        {
            foreach (line; res.output.lineSplitter)
            {
                auto trimmed = line.strip;
                if (!trimmed.empty)
                {
                    if (trimmed.canFind("error:"))
                        result.errors ~= trimmed;
                    else if (trimmed.canFind("warning:") || trimmed.canFind("note:"))
                        result.warnings ~= trimmed;
                }
            }
            result.success = result.errors.empty; // Fail only on errors, not warnings
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
    
    /// Type check Python code with pyright
    static ToolResult typeCheckPyright(string[] sources, string[] extraArgs = [])
    {
        ToolResult result;
        
        if (!ToolDetection.isPyrightAvailable())
        {
            result.warnings ~= "pyright not available (install: npm install -g pyright)";
            result.success = true;
            return result;
        }
        
        string[] cmd = ["pyright"] ~ extraArgs ~ sources;
        
        structuredLog.debug_("running_pyright_").field("detail", "Running pyright: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        result.output = res.output;
        
        if (res.status != 0)
        {
            foreach (line; res.output.lineSplitter)
            {
                auto trimmed = line.strip;
                if (!trimmed.empty)
                {
                    if (trimmed.canFind("error") && !trimmed.canFind("0 errors"))
                        result.errors ~= trimmed;
                    else if (trimmed.canFind("warning"))
                        result.warnings ~= trimmed;
                }
            }
            result.success = result.errors.empty;
        }
        else
        {
            result.success = true;
        }
        
        return result;
    }
}

/// Type checker factory and utilities
class TypeChecker
{
    /// Run type checking with configured checker
    static TypeCheckResult check(const string[] sources, TypeCheckConfig config, string pythonCmd = "python3")
    {
        if (!config.enabled)
        {
            TypeCheckResult result;
            result.success = true;
            return result;
        }
        
        final switch (config.checker)
        {
            case PyTypeChecker.Auto:
                return checkAuto(sources, config, pythonCmd);
            case PyTypeChecker.Mypy:
                return checkMypy(sources, config, pythonCmd);
            case PyTypeChecker.Pyright:
                return checkPyright(sources, config);
            case PyTypeChecker.Pytype:
                return checkPytype(sources, config, pythonCmd);
            case PyTypeChecker.Pyre:
                return checkPyre(sources, config);
            case PyTypeChecker.None:
                TypeCheckResult result;
                result.success = true;
                return result;
        }
    }
    
    /// Auto-detect and use best available type checker
    private static TypeCheckResult checkAuto(const string[] sources, TypeCheckConfig config, string pythonCmd)
    {
        // Priority: pyright (fastest) > mypy (most complete) > pytype > pyre
        
        if (ToolDetection.isPyrightAvailable())
        {
            structuredLog.debug_("using_pyright_for_type_checking").emit();
            return checkPyright(sources, config);
        }
        
        if (ToolDetection.isMypyAvailable(pythonCmd))
        {
            structuredLog.debug_("using_mypy_for_type_checking").emit();
            return checkMypy(sources, config, pythonCmd);
        }
        
        if (ToolDetection.isPytypeAvailable(pythonCmd))
        {
            structuredLog.debug_("using_pytype_for_type_checking").emit();
            return checkPytype(sources, config, pythonCmd);
        }
        
        // No type checker available
        TypeCheckResult result;
        result.success = true;
        result.warnings ~= "No type checker available, skipping type checking";
        structuredLog.warning("no_type_checker_available_install_mypy_p").emit();
        
        return result;
    }
    
    /// Type check with mypy
    private static TypeCheckResult checkMypy(const string[] sources, TypeCheckConfig config, string pythonCmd)
    {
        TypeCheckResult result;
        
        string[] cmd = [pythonCmd, "-m", "mypy"];
        
        // Add configuration options
        if (config.strict)
            cmd ~= "--strict";
        
        if (config.ignoreMissingImports)
            cmd ~= "--ignore-missing-imports";
        
        if (config.warnUnusedIgnores)
            cmd ~= "--warn-unused-ignores";
        
        if (config.disallowUntypedDefs)
            cmd ~= "--disallow-untyped-defs";
        
        if (config.disallowUntypedCalls)
            cmd ~= "--disallow-untyped-calls";
        
        if (config.checkUntypedDefs)
            cmd ~= "--check-untyped-defs";
        
        // Add config file if specified
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["--config-file", config.configFile];
        
        // Add sources
        cmd ~= sources;
        
        structuredLog.info("running_mypy_type_checking").emit();
        
        auto res = execute(cmd);
        
        // Parse mypy output
        foreach (line; res.output.lineSplitter)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;
            
            if (trimmed.canFind("error:"))
            {
                result.errors ~= trimmed;
                result.hasErrors = true;
            }
            else if (trimmed.canFind("warning:"))
            {
                result.warnings ~= trimmed;
                result.hasWarnings = true;
            }
            else if (trimmed.canFind("note:"))
            {
                result.notes ~= trimmed;
            }
        }
        
        result.success = res.status == 0;
        
        if (!result.success)
        {
            structuredLog.warning("mypy_found_type_errors").emit();
        }
        else if (result.hasWarnings)
        {
            structuredLog.info("mypy_type_checking_passed_with_warnings").emit();
        }
        else
        {
            structuredLog.info("mypy_type_checking_passed").emit();
        }
        
        return result;
    }
    
    /// Type check with pyright
    private static TypeCheckResult checkPyright(const string[] sources, TypeCheckConfig config)
    {
        TypeCheckResult result;
        
        string[] cmd = ["pyright"];
        
        // Add sources
        cmd ~= sources;
        
        structuredLog.info("running_pyright_type_checking").emit();
        
        auto res = execute(cmd);
        
        // Parse pyright output (JSON mode would be better, but text for simplicity)
        foreach (line; res.output.lineSplitter)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;
            
            if (trimmed.canFind("error") && !trimmed.canFind("0 errors"))
            {
                result.errors ~= trimmed;
                result.hasErrors = true;
            }
            else if (trimmed.canFind("warning"))
            {
                result.warnings ~= trimmed;
                result.hasWarnings = true;
            }
            else if (trimmed.canFind("information"))
            {
                result.notes ~= trimmed;
            }
        }
        
        result.success = res.status == 0;
        
        if (!result.success)
        {
            structuredLog.warning("pyright_found_type_errors").emit();
        }
        else if (result.hasWarnings)
        {
            structuredLog.info("pyright_type_checking_passed_with_warnin").emit();
        }
        else
        {
            structuredLog.info("pyright_type_checking_passed").emit();
        }
        
        return result;
    }
    
    /// Type check with pytype
    private static TypeCheckResult checkPytype(const string[] sources, TypeCheckConfig config, string pythonCmd)
    {
        TypeCheckResult result;
        
        string[] cmd = [pythonCmd, "-m", "pytype"];
        
        // Add sources
        cmd ~= sources;
        
        structuredLog.info("running_pytype_type_checking").emit();
        
        auto res = execute(cmd);
        
        // Parse pytype output
        foreach (line; res.output.lineSplitter)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;
            
            if (trimmed.canFind("[error]"))
            {
                result.errors ~= trimmed;
                result.hasErrors = true;
            }
            else if (trimmed.canFind("[warning]"))
            {
                result.warnings ~= trimmed;
                result.hasWarnings = true;
            }
        }
        
        result.success = res.status == 0;
        
        if (!result.success)
        {
            structuredLog.warning("pytype_found_type_errors").emit();
        }
        else
        {
            structuredLog.info("pytype_type_checking_passed").emit();
        }
        
        return result;
    }
    
    /// Type check with pyre
    private static TypeCheckResult checkPyre(const string[] sources, TypeCheckConfig config)
    {
        TypeCheckResult result;
        
        string[] cmd = ["pyre", "check"];
        
        structuredLog.info("running_pyre_type_checking").emit();
        
        auto res = execute(cmd);
        
        // Parse pyre output
        foreach (line; res.output.lineSplitter)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;
            
            if (trimmed.canFind("Error"))
            {
                result.errors ~= trimmed;
                result.hasErrors = true;
            }
        }
        
        result.success = res.status == 0;
        
        if (!result.success)
        {
            structuredLog.warning("pyre_found_type_errors").emit();
        }
        else
        {
            structuredLog.info("pyre_type_checking_passed").emit();
        }
        
        return result;
    }
}

