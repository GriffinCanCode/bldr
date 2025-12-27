module languages.compiled.d.tooling.tools;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import infrastructure.utils.logging;

/// D formatter (dfmt) integration
final class DFormatter
{
    /// Check if dfmt is available
    static bool isAvailable() nothrow
    {
        try
        {
            const res = execute(["dfmt", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Get dfmt version
    static string getVersion() nothrow
    {
        try
        {
            const res = execute(["dfmt", "--version"]);
            if (res.status == 0)
            {
                return res.output.strip();
            }
        }
        catch (Exception e)
        {
        }
        return "unknown";
    }
    
    /// Format D source files
    static auto format(scope const(string)[] sources, string configFile = "", bool checkOnly = false)
    {
        import std.array : array;
        
        string[] cmd = ["dfmt", checkOnly ? "--check" : "--inplace"];
        if (!configFile.empty && exists(configFile))
            cmd ~= "--config=" ~ configFile;
        cmd ~= sources;
        
        return execute(cmd);
    }
    
    /// Format a single file
    static auto formatFile(string source, string configFile = "", bool checkOnly = false)
    {
        return format([source], configFile, checkOnly);
    }
    
    /// Format directory recursively
    static auto formatDirectory(string dir, string configFile = "", bool checkOnly = false)
    {
        import std.range : array;
        
        auto sources = dirEntries(dir, "*.d", SpanMode.breadth)
            .filter!(entry => isFile(entry))
            .map!(entry => entry.name)
            .array;
        
        if (sources.empty)
        {
            return execute(["echo", "No .d files found in directory"]);
        }
        
        return format(sources, configFile, checkOnly);
    }
}

/// D static analyzer (dscanner) integration
final class DScanner
{
    /// Check if dscanner is available
    static bool isAvailable() nothrow
    {
        try
        {
            const res = execute(["dscanner", "--version"]);
            return res.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Get dscanner version
    static string getVersion() nothrow
    {
        try
        {
            const res = execute(["dscanner", "--version"]);
            if (res.status == 0)
            {
                return res.output.strip();
            }
        }
        catch (Exception e)
        {
        }
        return "unknown";
    }
    
    /// Run linter on source files
    static auto lint(
        scope const(string)[] sources,
        string configFile = "",
        bool styleCheck = true,
        bool syntaxCheck = true,
        string reportFormat = "stylish"
    )
    {
        string[] cmd = ["dscanner", "--styleCheck"];
        if (!configFile.empty && exists(configFile))
            cmd ~= "--config=" ~ configFile;
        if (!reportFormat.empty)
            cmd ~= "--reportFormat=" ~ reportFormat;
        cmd ~= sources;
        
        return execute(cmd);
    }
    
    /// Syntax check
    static auto syntaxCheck(scope const(string)[] sources)
    {
        import std.range : chain, only;
        auto cmd = chain(only("dscanner", "--syntaxCheck"), sources);
        return execute(cmd.array);
    }
    
    /// Generate ctags
    static auto generateCtags(scope const(string)[] sources, string outputFile = "tags")
    {
        import std.range : chain, only;
        auto cmd = chain(only("dscanner", "--ctags"), sources);
        
        const res = execute(cmd.array);
        
        if (res.status == 0 && !outputFile.empty)
        {
            try
            {
                std.file.write(outputFile, res.output);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_write_ctags_file_").field("detail", "Failed to write ctags file: " ~ e.msg).emit();
            }
        }
        
        return res;
    }
    
    /// Generate etags
    static auto generateEtags(scope const(string)[] sources, string outputFile = "TAGS")
    {
        import std.range : chain, only;
        auto cmd = chain(only("dscanner", "--etags"), sources);
        
        const res = execute(cmd.array);
        
        if (res.status == 0 && !outputFile.empty)
        {
            try
            {
                std.file.write(outputFile, res.output);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_write_etags_file_").field("detail", "Failed to write etags file: " ~ e.msg).emit();
            }
        }
        
        return res;
    }
    
    /// Find symbol definition
    static auto findSymbol(scope const(string)[] sources, string symbolName)
    {
        import std.range : chain, only;
        auto cmd = chain(only("dscanner", "--symbol", symbolName), sources);
        return execute(cmd.array);
    }
    
    /// List all imports in files
    static auto listImports(scope const(string)[] sources)
    {
        import std.range : chain, only;
        auto cmd = chain(only("dscanner", "--imports"), sources);
        return execute(cmd.array);
    }
    
    /// Detect code duplicates
    static auto detectDuplicates(scope const(string)[] sources)
    {
        import std.range : chain, only;
        auto cmd = chain(only("dscanner", "--sloc"), sources);
        return execute(cmd.array);
    }
}

/// DUB test runner
final class DubTest
{
    /// Run DUB tests
    static auto runTests(
        string projectDir,
        string compiler = "",
        bool verbose = false,
        string filter = ""
    )
    {
        import std.range : chain, only;
        
        // Set working directory
        if (projectDir.empty)
        {
            projectDir = getcwd();
        }
        
        string[] cmd = ["dub", "test"];
        if (!compiler.empty)
            cmd ~= "--compiler=" ~ compiler;
        if (verbose)
            cmd ~= "--verbose";
        if (!filter.empty)
            cmd ~= "--" ~ filter;
        
        return execute(cmd, null, std.process.Config.none, size_t.max, projectDir);
    }
    
    /// Run DUB tests with coverage
    static auto runTestsWithCoverage(
        string projectDir,
        string compiler = "",
        bool verbose = false
    )
    {
        import std.range : chain, only;
        
        if (projectDir.empty)
        {
            projectDir = getcwd();
        }
        
        string[] cmd = ["dub", "test", "--build=unittest-cov"];
        if (!compiler.empty)
            cmd ~= "--compiler=" ~ compiler;
        if (verbose)
            cmd ~= "--verbose";
        
        return execute(cmd, null, std.process.Config.none, size_t.max, projectDir);
    }
}

/// D documentation generator
final class DDoc
{
    /// Generate documentation using DMD/LDC
    static auto generateDocs(
        scope const(string)[] sources,
        string outputDir = "docs",
        string compiler = "dmd",
        scope const(string)[] importPaths = []
    )
    {
        import std.range : chain, only;
        
        // Create output directory
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        auto cmd = chain(
            only(compiler, "-D", "-Dd" ~ outputDir),
            importPaths.map!(p => "-I" ~ p),
            sources
        );
        
        return execute(cmd.array);
    }
    
    /// Generate JSON description
    static auto generateJSON(
        scope const(string)[] sources,
        string outputFile = "output.json",
        string compiler = "dmd",
        scope const(string)[] importPaths = []
    )
    {
        import std.range : chain, only;
        
        auto cmd = chain(
            only(compiler, "-X", "-Xf" ~ outputFile),
            importPaths.map!(p => "-I" ~ p),
            sources
        );
        
        return execute(cmd.array);
    }
}


