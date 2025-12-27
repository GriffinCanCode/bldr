module languages.jvm.scala.managers.mill;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.process;
import std.regex;
import infrastructure.utils.logging;
import languages.jvm.scala.core.config;

/// Mill build operations
class MillOps
{
    /// Execute Mill command
    static auto executeMill(string[] args, string workingDir = ".")
    {
        return execute(["mill"] ~ args, null, Config.none, size_t.max, workingDir);
    }
    
    /// Compile project
    static bool compile(string projectDir, string moduleName = "")
    {
        structuredLog.info("compiling_mill_project").emit();
        
        string[] args;
        if (moduleName.empty)
            args = ["compile"];
        else
            args = [moduleName ~ ".compile"];
        
        auto result = executeMill(args, projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("mill_compilation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Run tests
    static bool test(string projectDir, string moduleName = "")
    {
        structuredLog.info("running_mill_tests").emit();
        
        string[] args;
        if (moduleName.empty)
            args = ["test"];
        else
            args = [moduleName ~ ".test"];
        
        auto result = executeMill(args, projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("mill_tests_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Clean build
    static bool clean(string projectDir)
    {
        structuredLog.info("cleaning_mill_project").emit();
        
        auto result = executeMill(["clean"], projectDir);
        return result.status == 0;
    }
    
    /// Create assembly (fat JAR)
    static bool assembly(string projectDir, string moduleName = "")
    {
        structuredLog.info("creating_assembly_jar").emit();
        
        string[] args;
        if (moduleName.empty)
            args = ["assembly"];
        else
            args = [moduleName ~ ".assembly"];
        
        auto result = executeMill(args, projectDir);
        
        if (result.status != 0)
        {
            structuredLog.error("mill_assembly_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ result.output).emit();
            return false;
        }
        
        return true;
    }
    
    /// Get Mill version
    static string getVersion()
    {
        auto result = execute(["mill", "version"]);
        if (result.status == 0)
        {
            auto match = matchFirst(result.output, regex(`Mill version\s+([\d.]+)`));
            if (!match.empty)
                return match[1];
        }
        return "";
    }
}

