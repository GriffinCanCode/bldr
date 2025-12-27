module languages.scripting.ruby.tooling.formatters.base;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import infrastructure.utils.logging;

/// Format/lint result
struct FormatResult
{
    bool success;
    string[] errors;
    string[] warnings;
    string[] offenses; // Style violations
    string output;
    int offenseCount;
    bool autoFixed;
    
    bool hasErrors() const
    {
        return !errors.empty;
    }
    
    bool hasWarnings() const
    {
        return !warnings.empty;
    }
    
    bool hasOffenses() const
    {
        return !offenses.empty || offenseCount > 0;
    }
}

/// Formatter/Linter interface
interface Formatter
{
    /// Format/lint source files
    FormatResult format(const(string[]) sources, FormatConfig config, bool autoCorrect = false);
    
    /// Check if formatter is available
    bool isAvailable();
    
    /// Get formatter name
    string name() const;
    
    /// Get version
    string getVersion();
}

/// Formatter factory
class FormatterFactory
{
    /// Create formatter based on configuration
    static Formatter create(RubyFormatter type)
    {
        final switch (type)
        {
            case RubyFormatter.Auto:
                return detectBest();
            case RubyFormatter.RuboCop:
                import languages.scripting.ruby.tooling.formatters.rubocop;
                return new RuboCopFormatter();
            case RubyFormatter.Standard:
                import languages.scripting.ruby.tooling.formatters.standard;
                return new StandardFormatter();
            case RubyFormatter.Reek:
                return new ReekFormatter();
            case RubyFormatter.None:
                return new NullFormatter();
        }
    }
    
    /// Detect best available formatter
    static Formatter detectBest()
    {
        // Priority: StandardRB > RuboCop > Reek
        
        import languages.scripting.ruby.tooling.formatters.standard;
        auto standard = new StandardFormatter();
        if (standard.isAvailable())
        {
            structuredLog.debug_("detected_standardrb_for_formatting").emit();
            return standard;
        }
        
        import languages.scripting.ruby.tooling.formatters.rubocop;
        auto rubocop = new RuboCopFormatter();
        if (rubocop.isAvailable())
        {
            structuredLog.debug_("detected_rubocop_for_formatting").emit();
            return rubocop;
        }
        
        auto reek = new ReekFormatter();
        if (reek.isAvailable())
        {
            structuredLog.debug_("detected_reek_for_code_smell_detection").emit();
            return reek;
        }
        
        structuredLog.debug_("no_ruby_formatter_available").emit();
        return new NullFormatter();
    }
}

/// Reek code smell detector
class ReekFormatter : Formatter
{
    override FormatResult format(const(string[]) sources, FormatConfig config, bool autoCorrect = false)
    {
        FormatResult result;
        
        // Reek doesn't auto-correct, only detects code smells
        string[] cmd = ["reek"];
        
        // Add configuration file if specified
        if (!config.configFile.empty && exists(config.configFile))
        {
            cmd ~= ["-c", config.configFile];
        }
        
        // Add source files
        if (!sources.empty)
            cmd ~= sources;
        
        structuredLog.info("running_reek_code_smell_detection").emit();
        
        auto res = execute(cmd);
        
        result.output = res.output;
        result.success = res.status == 0;
        
        // Parse output
        parseOutput(res.output, result);
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["reek", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "Reek";
    }
    
    override string getVersion()
    {
        auto res = execute(["reek", "--version"]);
        if (res.status == 0)
        {
            auto parts = res.output.strip.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "unknown";
    }
    
    private void parseOutput(string output, ref FormatResult result)
    {
        foreach (line; output.lineSplitter)
        {
            if (line.canFind("warning:") || line.canFind("["))
            {
                result.warnings ~= line;
                result.offenseCount++;
            }
        }
    }
}

/// Null formatter (no-op)
class NullFormatter : Formatter
{
    override FormatResult format(const(string[]) sources, FormatConfig config, bool autoCorrect = false)
    {
        FormatResult result;
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


