module languages.scripting.ruby.tooling.formatters.rubocop;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.tooling.formatters.base;
import infrastructure.utils.logging;

/// RuboCop formatter/linter
class RuboCopFormatter : Formatter
{
    override FormatResult format(const(string[]) sources, FormatConfig config, bool autoCorrect = false)
    {
        FormatResult result;
        
        string[] cmd = ["rubocop"];
        
        // Auto-correct mode
        if (autoCorrect || config.autoCorrect)
        {
            cmd ~= "-A"; // Auto-correct all offenses (safe + unsafe)
            result.autoFixed = true;
        }
        
        // Configuration file
        if (!config.configFile.empty && exists(config.configFile))
        {
            cmd ~= ["-c", config.configFile];
        }
        
        // Display cop names
        if (config.displayCopNames)
        {
            cmd ~= "--display-cop-names";
        }
        
        // RuboCop-specific options
        if (config.rubocop.rails)
        {
            cmd ~= "--rails";
        }
        
        if (config.rubocop.displayStyleGuide)
        {
            cmd ~= "--display-style-guide";
        }
        
        if (config.rubocop.extraDetails)
        {
            cmd ~= "--extra-details";
        }
        
        if (config.rubocop.parallel)
        {
            cmd ~= "--parallel";
        }
        
        // Only specific cops
        if (!config.rubocop.only.empty)
        {
            cmd ~= ["--only", config.rubocop.only.join(",")];
        }
        
        // Except specific cops
        if (!config.rubocop.except.empty)
        {
            cmd ~= ["--except", config.rubocop.except.join(",")];
        }
        
        // Format output as JSON for easier parsing
        cmd ~= "--format";
        cmd ~= "json";
        
        // Add source files/directories
        if (!sources.empty)
            cmd ~= sources;
        
        structuredLog.info("running_rubocop").field("detail", "Running RuboCop" ~ (autoCorrect ? " with auto-correct" : "")).emit();
        
        auto res = execute(cmd);
        
        result.output = res.output;
        
        // RuboCop returns:
        // 0 = no offenses
        // 1 = offenses found
        // 2 = error
        result.success = res.status == 0 || res.status == 1;
        
        if (res.status == 2)
        {
            result.errors ~= "RuboCop encountered an error";
        }
        
        // Parse JSON output
        parseJSONOutput(res.output, result);
        
        // If auto-correcting and failed on warnings, might still be acceptable
        if (config.failOnWarning && result.hasWarnings)
        {
            result.success = false;
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["rubocop", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "RuboCop";
    }
    
    override string getVersion()
    {
        auto res = execute(["rubocop", "--version"]);
        if (res.status == 0)
        {
            auto parts = res.output.strip.split;
            if (parts.length >= 2)
                return parts[1];
        }
        return "unknown";
    }
    
    /// Initialize RuboCop configuration
    static bool initialize(string projectRoot)
    {
        structuredLog.info("initializing_rubocop_configuration").emit();
        
        auto configFile = buildPath(projectRoot, ".rubocop.yml");
        if (exists(configFile))
        {
            structuredLog.info("rubocopyml_already_exists").emit();
            return true;
        }
        
        // Generate basic configuration
        string content = `# RuboCop configuration
AllCops:
  NewCops: enable
  TargetRubyVersion: 3.0

Style/StringLiterals:
  Enabled: true
  EnforcedStyle: double_quotes

Style/FrozenStringLiteralComment:
  Enabled: false

Metrics/MethodLength:
  Max: 20

Metrics/BlockLength:
  Exclude:
    - 'spec/**/*'
    - 'test/**/*'
`;
        
        try
        {
            std.file.write(configFile, content);
            structuredLog.info("created_rubocopyml").emit();
            return true;
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_create_rubocopyml_").field("detail", "Failed to create .rubocop.yml: " ~ e.msg).emit();
            return false;
        }
    }
    
    private void parseJSONOutput(string output, ref FormatResult result)
    {
        import std.json;
        
        try
        {
            auto json = parseJSON(output);
            
            if ("summary" in json)
            {
                auto summary = json["summary"];
                if ("offense_count" in summary)
                {
                    result.offenseCount = cast(int)summary["offense_count"].integer;
                }
            }
            
            if ("files" in json)
            {
                foreach (fileJson; json["files"].array)
                {
                    auto filePath = fileJson["path"].str;
                    
                    if ("offenses" in fileJson)
                    {
                        foreach (offense; fileJson["offenses"].array)
                        {
                            auto severity = offense["severity"].str;
                            auto message = offense["message"].str;
                            auto copName = offense["cop_name"].str;
                            
                            int line = 0;
                            if ("location" in offense)
                            {
                                auto location = offense["location"];
                                if ("line" in location)
                                    line = cast(int)location["line"].integer;
                            }
                            
                            auto offenseStr = filePath ~ ":" ~ line.to!string ~ ": " ~ 
                                            severity ~ ": " ~ message ~ " (" ~ copName ~ ")";
                            
                            if (severity == "error" || severity == "fatal")
                            {
                                result.errors ~= offenseStr;
                            }
                            else if (severity == "warning")
                            {
                                result.warnings ~= offenseStr;
                            }
                            else
                            {
                                result.offenses ~= offenseStr;
                            }
                        }
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_rubocop_json_output_").field("detail", "Failed to parse RuboCop JSON output: " ~ e.msg).emit();
            
            // Fallback: parse as plain text
            foreach (line; output.lineSplitter)
            {
                if (line.canFind(":"))
                {
                    if (line.canFind("error") || line.canFind("Error"))
                        result.errors ~= line;
                    else if (line.canFind("warning") || line.canFind("Warning"))
                        result.warnings ~= line;
                    else if (line.canFind("convention") || line.canFind("refactor"))
                        result.offenses ~= line;
                }
            }
        }
    }
}


