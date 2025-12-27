module languages.scripting.ruby.tooling.info;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import infrastructure.utils.logging;

/// Ruby tool availability checking and execution
class RubyTools
{
    /// Check if Ruby is available
    static bool isRubyAvailable()
    {
        auto res = execute(["ruby", "--version"]);
        return res.status == 0;
    }
    
    /// Get Ruby version
    static string getRubyVersion()
    {
        auto res = execute(["ruby", "--version"]);
        if (res.status == 0)
        {
            // Parse "ruby 3.3.0 (2023-12-25 revision ...) [platform]"
            auto parts = res.output.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "unknown";
    }
    
    /// Check if Bundler is available
    static bool isBundlerAvailable()
    {
        auto res = execute(["bundle", "--version"]);
        return res.status == 0;
    }
    
    /// Check if Rake is available
    static bool isRakeAvailable()
    {
        auto res = execute(["rake", "--version"]);
        return res.status == 0;
    }
    
    /// Check if RSpec is available
    static bool isRSpecAvailable()
    {
        auto res = execute(["rspec", "--version"]);
        return res.status == 0;
    }
    
    /// Check if IRB is available
    static bool isIRBAvailable()
    {
        auto res = execute(["irb", "--version"]);
        return res.status == 0;
    }
    
    /// Check if YARD is available
    static bool isYARDAvailable()
    {
        auto res = execute(["yard", "--version"]);
        return res.status == 0;
    }
    
    /// Check if RDoc is available
    static bool isRDocAvailable()
    {
        auto res = execute(["rdoc", "--version"]);
        return res.status == 0;
    }
    
    /// Check if RuboCop is available
    static bool isRuboCopAvailable()
    {
        auto res = execute(["rubocop", "--version"]);
        return res.status == 0;
    }
    
    /// Check if StandardRB is available
    static bool isStandardAvailable()
    {
        auto res = execute(["standardrb", "--version"]);
        return res.status == 0;
    }
    
    /// Check if gem is installed
    static bool isGemInstalled(string gemName)
    {
        auto res = execute(["gem", "list", "-i", gemName]);
        return res.status == 0 && res.output.strip == "true";
    }
    
    /// Get gem version
    static string getGemVersion(string gemName)
    {
        auto res = execute(["gem", "list", gemName, "--exact", "--remote"]);
        if (res.status == 0)
        {
            // Parse "gem_name (version1, version2)"
            auto match = res.output.indexOf("(");
            if (match > 0)
            {
                auto endMatch = res.output.indexOf(")", match);
                if (endMatch > match)
                {
                    auto versions = res.output[match+1..endMatch];
                    auto parts = versions.split(",");
                    if (!parts.empty)
                        return parts[0].strip;
                }
            }
        }
        return "unknown";
    }
}

/// Rake task execution
class RakeTool
{
    private string projectRoot;
    
    this(string projectRoot = ".")
    {
        this.projectRoot = projectRoot;
    }
    
    /// Run Rake task
    auto runTask(string task, string[] args = [])
    {
        string[] cmd = ["rake", task];
        cmd ~= args;
        
        structuredLog.info("running_rake_task_").field("detail", "Running Rake task: " ~ task).emit();
        
        return execute(cmd, null, Config.none, size_t.max, projectRoot);
    }
    
    /// List available Rake tasks
    string[] listTasks()
    {
        auto res = execute(["rake", "-T"], null, Config.none, size_t.max, projectRoot);
        if (res.status != 0)
            return [];
        
        string[] tasks;
        foreach (line; res.output.lineSplitter)
        {
            // Parse lines like "rake task_name  # Description"
            if (line.startsWith("rake "))
            {
                auto parts = line[5..$].split;
                if (!parts.empty)
                    tasks ~= parts[0];
            }
        }
        return tasks;
    }
    
    /// Check if Rakefile exists
    bool hasRakefile() const
    {
        return exists(buildPath(projectRoot, "Rakefile")) ||
               exists(buildPath(projectRoot, "rakefile")) ||
               exists(buildPath(projectRoot, "Rakefile.rb"));
    }
    
    /// Run default task
    auto runDefault()
    {
        return runTask("default");
    }
    
    /// Run tests via Rake
    auto runTests()
    {
        return runTask("test");
    }
    
    /// Run specs via Rake
    auto runSpecs()
    {
        return runTask("spec");
    }
}

/// Documentation generation
class DocGenerator
{
    /// Generate YARD documentation
    static bool generateYARD(const(string[]) sources, DocConfig config)
    {
        if (!RubyTools.isYARDAvailable())
        {
            structuredLog.error("yard_not_available_install_gem_install_y").emit();
            return false;
        }
        
        string[] cmd = ["yard", "doc"];
        
        // Output directory
        if (!config.outputDir.empty)
        {
            cmd ~= ["--output-dir", config.outputDir];
        }
        
        // Markup format
        if (!config.yard.markup.empty)
        {
            cmd ~= ["--markup", config.yard.markup];
        }
        
        // Template
        if (!config.yard.template_.empty && config.yard.template_ != "default")
        {
            cmd ~= ["--template", config.yard.template_];
        }
        
        // Visibility
        if (config.yard.private_)
            cmd ~= "--private";
        
        if (!config.yard.protected_)
            cmd ~= "--no-protected";
        
        // Additional files
        if (!config.yard.files.empty)
        {
            cmd ~= "-";
            cmd ~= config.yard.files;
        }
        
        // Source files
        if (!sources.empty)
            cmd ~= sources;
        
        structuredLog.info("generating_yard_documentation").emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("yard_documentation_generation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("yard_documentation_generated_successfull").emit();
        return true;
    }
    
    /// Generate RDoc documentation
    static bool generateRDoc(const(string[]) sources, DocConfig config)
    {
        if (!RubyTools.isRDocAvailable())
        {
            structuredLog.error("rdoc_not_available").emit();
            return false;
        }
        
        string[] cmd = ["rdoc"];
        
        // Output directory
        if (!config.outputDir.empty)
        {
            cmd ~= ["--output", config.outputDir];
        }
        
        // Source files
        if (!sources.empty)
            cmd ~= sources;
        else
            cmd ~= "."; // Generate for entire project
        
        structuredLog.info("generating_rdoc_documentation").emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("rdoc_documentation_generation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("rdoc_documentation_generated_successfull").emit();
        return true;
    }
    
    /// Generate documentation based on configuration
    static bool generate(const(string[]) sources, DocConfig config)
    {
        bool success = true;
        
        final switch (config.generator)
        {
            case RubyDocGenerator.Auto:
                // Prefer YARD if available
                if (RubyTools.isYARDAvailable())
                    return generateYARD(sources, config);
                else
                    return generateRDoc(sources, config);
            
            case RubyDocGenerator.YARD:
                return generateYARD(sources, config);
            
            case RubyDocGenerator.RDoc:
                return generateRDoc(sources, config);
            
            case RubyDocGenerator.Both:
                success = generateYARD(sources, config);
                success = generateRDoc(sources, config) && success;
                return success;
            
            case RubyDocGenerator.None:
                return true;
        }
    }
}

/// IRB (Interactive Ruby) utilities
class IRBTool
{
    /// Launch IRB with preloaded files
    static auto launch(string[] preload = [])
    {
        string[] cmd = ["irb"];
        
        foreach (file; preload)
        {
            if (exists(file))
                cmd ~= ["-r", file];
        }
        
        structuredLog.info("launching_irb").emit();
        
        return spawnProcess(cmd);
    }
    
    /// Run Ruby code in IRB
    static auto evaluate(string code)
    {
        auto res = execute(["irb", "-e", code]);
        return res.output;
    }
}

/// Ruby syntax checker
class SyntaxChecker
{
    /// Check Ruby syntax
    static bool check(const(string[]) sources, out string[] errors)
    {
        bool allValid = true;
        
        foreach (source; sources)
        {
            if (!exists(source))
            {
                errors ~= "File not found: " ~ source;
                allValid = false;
                continue;
            }
            
            auto res = execute(["ruby", "-c", source]);
            
            if (res.status != 0)
            {
                errors ~= "Syntax error in " ~ source ~ ": " ~ res.output;
                allValid = false;
            }
        }
        
        return allValid;
    }
    
    /// Check single file syntax
    static bool checkFile(string source, out string error)
    {
        if (!exists(source))
        {
            error = "File not found: " ~ source;
            return false;
        }
        
        auto res = execute(["ruby", "-c", source]);
        
        if (res.status != 0)
        {
            error = res.output;
            return false;
        }
        
        return true;
    }
}

/// Ruby require/load path utilities
class LoadPathUtil
{
    /// Get Ruby load path
    static string[] getLoadPath()
    {
        auto res = execute(["ruby", "-e", "puts $LOAD_PATH"]);
        if (res.status != 0)
            return [];
        
        return res.output.lineSplitter.map!(s => s.strip).array;
    }
    
    /// Add to load path
    static string[] buildLoadPathArgs(string[] paths)
    {
        string[] args;
        foreach (path; paths)
        {
            args ~= ["-I", path];
        }
        return args;
    }
}

/// Gem specification utilities
class GemspecUtil
{
    /// Find gemspec files in directory
    static string[] findGemspecs(string dir)
    {
        string[] gemspecs;
        
        if (!exists(dir))
            return gemspecs;
        
        try
        {
            foreach (entry; dirEntries(dir, "*.gemspec", SpanMode.shallow))
            {
                if (entry.isFile)
                    gemspecs ~= entry.name;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_search_for_gemspecs_").field("detail", "Failed to search for gemspecs: " ~ e.msg).emit();
        }
        
        return gemspecs;
    }
    
    /// Parse basic info from gemspec
    static string getGemName(string gemspecFile)
    {
        if (!exists(gemspecFile))
            return "";
        
        try
        {
            auto content = readText(gemspecFile);
            
            // Look for: s.name = "gem_name" or spec.name = "gem_name"
            foreach (line; content.lineSplitter)
            {
                auto trimmed = line.strip;
                if (trimmed.canFind(".name") && trimmed.canFind("="))
                {
                    auto parts = trimmed.split("=");
                    if (parts.length >= 2)
                    {
                        auto name = parts[1].strip.strip("'\"");
                        return name;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_gemspec_").field("detail", "Failed to parse gemspec: " ~ e.msg).emit();
        }
        
        return "";
    }
}

/// Ruby project structure detection
class ProjectDetector
{
    /// Check if directory is a Rails project
    static bool isRailsProject(string dir)
    {
        return exists(buildPath(dir, "config", "application.rb")) &&
               exists(buildPath(dir, "config", "environment.rb")) &&
               exists(buildPath(dir, "Gemfile"));
    }
    
    /// Check if directory is a gem project
    static bool isGemProject(string dir)
    {
        auto gemspecs = GemspecUtil.findGemspecs(dir);
        return !gemspecs.empty;
    }
    
    /// Check if directory uses Bundler
    static bool usesBundler(string dir)
    {
        return exists(buildPath(dir, "Gemfile"));
    }
    
    /// Check if directory has tests
    static bool hasTests(string dir)
    {
        return exists(buildPath(dir, "test")) ||
               exists(buildPath(dir, "spec"));
    }
    
    /// Check if uses RSpec
    static bool usesRSpec(string dir)
    {
        return exists(buildPath(dir, "spec")) &&
               exists(buildPath(dir, ".rspec"));
    }
    
    /// Check if uses Minitest
    static bool usesMinitest(string dir)
    {
        return exists(buildPath(dir, "test"));
    }
    
    /// Detect project type
    static RubyBuildMode detectProjectType(string dir)
    {
        if (isRailsProject(dir))
            return RubyBuildMode.Rails;
        
        if (isGemProject(dir))
            return RubyBuildMode.Gem;
        
        // Check for Rack config
        if (exists(buildPath(dir, "config.ru")))
            return RubyBuildMode.Rack;
        
        // Check for CLI-style bin directory
        auto binDir = buildPath(dir, "bin");
        if (exists(binDir))
        {
            try
            {
                auto files = dirEntries(binDir, SpanMode.shallow);
                if (!files.empty)
                    return RubyBuildMode.CLI;
            }
            catch (Exception e) {}
        }
        
        // Check if it's a library (has lib/ directory)
        if (exists(buildPath(dir, "lib")))
            return RubyBuildMode.Library;
        
        // Default to script
        return RubyBuildMode.Script;
    }
}


