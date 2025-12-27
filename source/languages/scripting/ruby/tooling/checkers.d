module languages.scripting.ruby.tooling.checkers;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import infrastructure.utils.logging;

/// Type check result
struct TypeCheckResult
{
    bool success;
    string[] errors;
    string[] warnings;
    string output;
    
    bool hasErrors() const
    {
        return !errors.empty;
    }
    
    bool hasWarnings() const
    {
        return !warnings.empty;
    }
}

/// Type checker interface
interface TypeChecker
{
    /// Check types in source files
    TypeCheckResult check(const(string[]) sources, TypeCheckConfig config);
    
    /// Check if type checker is available
    bool isAvailable();
    
    /// Get type checker name
    string name() const;
    
    /// Get version
    string getVersion();
}

/// Type checker factory
class TypeCheckerFactory
{
    /// Create type checker based on configuration
    static TypeChecker create(RubyTypeChecker type)
    {
        final switch (type)
        {
            case RubyTypeChecker.Auto:
                return detectBest();
            case RubyTypeChecker.Sorbet:
                return new SorbetChecker();
            case RubyTypeChecker.RBS:
                return new RBSChecker();
            case RubyTypeChecker.Steep:
                return new SteepChecker();
            case RubyTypeChecker.None:
                return new NullTypeChecker();
        }
    }
    
    /// Detect best available type checker
    static TypeChecker detectBest()
    {
        // Priority: Sorbet > Steep > RBS
        
        auto sorbet = new SorbetChecker();
        if (sorbet.isAvailable())
        {
            structuredLog.debug_("detected_sorbet_for_type_checking").emit();
            return sorbet;
        }
        
        auto steep = new SteepChecker();
        if (steep.isAvailable())
        {
            structuredLog.debug_("detected_steep_for_type_checking").emit();
            return steep;
        }
        
        auto rbs = new RBSChecker();
        if (rbs.isAvailable())
        {
            structuredLog.debug_("detected_rbs_for_type_checking").emit();
            return rbs;
        }
        
        structuredLog.debug_("no_type_checker_available").emit();
        return new NullTypeChecker();
    }
}

/// Sorbet type checker (Stripe, gradual typing)
class SorbetChecker : TypeChecker
{
    override TypeCheckResult check(const(string[]) sources, TypeCheckConfig config)
    {
        TypeCheckResult result;
        
        string[] cmd = ["srb", "tc"];
        
        // Apply Sorbet-specific configuration
        if (!config.sorbet.configFile.empty && exists(config.sorbet.configFile))
        {
            cmd ~= ["--config", config.sorbet.configFile];
        }
        
        // Strictness level
        if (!config.sorbet.level.empty)
        {
            // Sorbet uses typed: annotations in files, not CLI flags
            // But we can use --typed for global level
            if (config.sorbet.level != "false")
            {
                cmd ~= ["--typed", config.sorbet.level];
            }
        }
        
        // Ignore paths
        foreach (ignorePath; config.sorbet.ignore)
        {
            cmd ~= ["--ignore", ignorePath];
        }
        
        // Add source directories (Sorbet typically runs on entire project)
        if (!sources.empty)
        {
            // Get unique directories
            auto dirs = sources.map!(s => dirName(s)).array.sort.uniq.array;
            foreach (dir; dirs)
            {
                if (exists(dir))
                    cmd ~= dir;
            }
        }
        else
        {
            cmd ~= "."; // Check entire project
        }
        
        structuredLog.info("running_sorbet_type_checker").emit();
        
        auto res = execute(cmd);
        
        result.output = res.output;
        result.success = res.status == 0;
        
        // Parse output for errors and warnings
        parseOutput(res.output, result);
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["srb", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "Sorbet";
    }
    
    override string getVersion()
    {
        auto res = execute(["srb", "--version"]);
        if (res.status == 0)
        {
            // Parse "Sorbet typechecker X.Y.Z"
            auto parts = res.output.strip.split;
            if (parts.length >= 3)
                return parts[2];
        }
        return "unknown";
    }
    
    /// Initialize Sorbet in project
    static bool initialize(string projectRoot)
    {
        structuredLog.info("initializing_sorbet").emit();
        
        // Create sorbet directory structure
        auto sorbetDir = buildPath(projectRoot, "sorbet");
        if (!exists(sorbetDir))
            mkdirRecurse(sorbetDir);
        
        // Run sorbet init
        auto res = execute(["srb", "init"], null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("failed_to_initialize_sorbet_").field("detail", "Failed to initialize Sorbet: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("sorbet_initialized_successfully").emit();
        return true;
    }
    
    /// Generate RBI files
    static bool generateRBI(string projectRoot)
    {
        structuredLog.info("generating_sorbet_rbi_files").emit();
        
        auto res = execute(["srb", "rbi", "gems"], null, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.warning("failed_to_generate_rbi_files_").field("detail", "Failed to generate RBI files: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    private void parseOutput(string output, ref TypeCheckResult result)
    {
        foreach (line; output.lineSplitter)
        {
            if (line.canFind("error:") || line.canFind("Error:"))
            {
                result.errors ~= line;
            }
            else if (line.canFind("warning:") || line.canFind("Warning:"))
            {
                result.warnings ~= line;
            }
        }
    }
}

/// RBS type checker (Ruby 3.0+ built-in type signatures)
class RBSChecker : TypeChecker
{
    override TypeCheckResult check(const(string[]) sources, TypeCheckConfig config)
    {
        TypeCheckResult result;
        
        // RBS validates type signature files (.rbs)
        string[] cmd = ["rbs", "validate"];
        
        // Specify RBS directory
        if (!config.rbs.dir.empty && exists(config.rbs.dir))
        {
            cmd ~= ["--dir", config.rbs.dir];
        }
        
        structuredLog.info("validating_rbs_type_signatures").emit();
        
        auto res = execute(cmd);
        
        result.output = res.output;
        result.success = res.status == 0;
        
        parseOutput(res.output, result);
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["rbs", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "RBS";
    }
    
    override string getVersion()
    {
        auto res = execute(["rbs", "--version"]);
        if (res.status == 0)
        {
            // Parse "rbs X.Y.Z"
            auto parts = res.output.strip.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "unknown";
    }
    
    /// Generate RBS signatures from Ruby code
    static bool generate(string[] sources, string outputDir)
    {
        structuredLog.info("generating_rbs_signatures").emit();
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Use rbs prototype to generate signatures
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string[] cmd = ["rbs", "prototype", "rb", source];
            auto res = execute(cmd);
            
            if (res.status == 0)
            {
                // Write RBS file
                auto rbsFile = buildPath(outputDir, baseName(source).stripExtension ~ ".rbs");
                try
                {
                    std.file.write(rbsFile, res.output);
                    structuredLog.debug_("generated_").field("detail", "Generated " ~ rbsFile).emit();
                }
                catch (Exception e)
                {
                    structuredLog.warning("failed_to_write_").field("detail", "Failed to write " ~ rbsFile ~ ": " ~ e.msg).emit();
                }
            }
        }
        
        return true;
    }
    
    private void parseOutput(string output, ref TypeCheckResult result)
    {
        foreach (line; output.lineSplitter)
        {
            if (line.canFind("error"))
            {
                result.errors ~= line;
            }
            else if (line.canFind("warning"))
            {
                result.warnings ~= line;
            }
        }
    }
}

/// Steep type checker (RBS-based type checking)
class SteepChecker : TypeChecker
{
    override TypeCheckResult check(const(string[]) sources, TypeCheckConfig config)
    {
        TypeCheckResult result;
        
        string[] cmd = ["steep", "check"];
        
        // Steep uses Steepfile for configuration
        if (!config.steep.configFile.empty && !exists(config.steep.configFile))
        {
            structuredLog.warning("steepfile_not_found_").field("detail", "Steepfile not found: " ~ config.steep.configFile).emit();
        }
        
        // Add source paths
        if (!sources.empty)
        {
            cmd ~= sources;
        }
        
        structuredLog.info("running_steep_type_checker").emit();
        
        auto res = execute(cmd);
        
        result.output = res.output;
        result.success = res.status == 0;
        
        parseOutput(res.output, result);
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["steep", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "Steep";
    }
    
    override string getVersion()
    {
        auto res = execute(["steep", "--version"]);
        if (res.status == 0)
        {
            // Parse "Steep X.Y.Z"
            auto parts = res.output.strip.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "unknown";
    }
    
    /// Initialize Steep in project
    static bool initialize(string projectRoot)
    {
        structuredLog.info("initializing_steep").emit();
        
        // Create Steepfile
        auto steepfile = buildPath(projectRoot, "Steepfile");
        if (exists(steepfile))
        {
            structuredLog.info("steepfile_already_exists").emit();
            return true;
        }
        
        // Generate basic Steepfile
        string content = `# Steepfile
target :lib do
  signature "sig"
  check "lib"
end

target :test do
  signature "sig", "sig-private"
  check "test"
end
`;
        
        try
        {
            std.file.write(steepfile, content);
            structuredLog.info("created_steepfile").emit();
            return true;
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_create_steepfile_").field("detail", "Failed to create Steepfile: " ~ e.msg).emit();
            return false;
        }
    }
    
    private void parseOutput(string output, ref TypeCheckResult result)
    {
        foreach (line; output.lineSplitter)
        {
            if (line.canFind("[error]") || line.canFind("Error:"))
            {
                result.errors ~= line;
            }
            else if (line.canFind("[warning]") || line.canFind("Warning:"))
            {
                result.warnings ~= line;
            }
        }
    }
}

/// Null type checker (no-op)
class NullTypeChecker : TypeChecker
{
    override TypeCheckResult check(const(string[]) sources, TypeCheckConfig config)
    {
        TypeCheckResult result;
        result.success = true;
        return result;
    }
    
    override bool isAvailable()
    {
        return true;
    }
    
    override string name() const
    {
        return "None";
    }
    
    override string getVersion()
    {
        return "N/A";
    }
}

/// Type checking utilities
class TypeCheckUtil
{
    /// Check if project has type signatures
    static bool hasTypeSignatures(string projectRoot)
    {
        // Check for Sorbet
        if (exists(buildPath(projectRoot, "sorbet")))
            return true;
        
        // Check for RBS
        if (exists(buildPath(projectRoot, "sig")))
            return true;
        
        // Check for Steepfile
        if (exists(buildPath(projectRoot, "Steepfile")))
            return true;
        
        return false;
    }
    
    /// Detect type checking system from project
    static RubyTypeChecker detectFromProject(string projectRoot)
    {
        // Check for Sorbet
        if (exists(buildPath(projectRoot, "sorbet", "config")))
            return RubyTypeChecker.Sorbet;
        
        // Check for Steep
        if (exists(buildPath(projectRoot, "Steepfile")))
            return RubyTypeChecker.Steep;
        
        // Check for RBS
        if (exists(buildPath(projectRoot, "sig")))
        {
            // Could be RBS or Steep (Steep uses RBS)
            if (exists(buildPath(projectRoot, "Steepfile")))
                return RubyTypeChecker.Steep;
            return RubyTypeChecker.RBS;
        }
        
        return RubyTypeChecker.None;
    }
}


