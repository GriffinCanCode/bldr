module languages.scripting.ruby.tooling.formatters.standard;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.tooling.formatters.base;
import infrastructure.utils.logging;

/// StandardRB formatter (opinionated, zero-config)
class StandardFormatter : Formatter
{
    override FormatResult format(const(string[]) sources, FormatConfig config, bool autoCorrect = false)
    {
        FormatResult result;
        
        string[] cmd = ["standardrb"];
        
        // Auto-fix mode
        if (autoCorrect || config.autoCorrect)
        {
            cmd ~= "--fix";
            result.autoFixed = true;
        }
        
        // Configuration file (StandardRB uses .standard.yml, less common than RuboCop)
        if (!config.configFile.empty && exists(config.configFile))
        {
            cmd ~= ["--config", config.configFile];
        }
        
        // Format as JSON for better parsing
        cmd ~= "--format";
        cmd ~= "json";
        
        // Add source files
        if (!sources.empty)
            cmd ~= sources;
        
        structuredLog.info("running_standardrb").field("detail", "Running StandardRB" ~ (autoCorrect ? " with auto-fix" : "")).emit();
        
        auto res = execute(cmd);
        
        result.output = res.output;
        
        // StandardRB returns:
        // 0 = no offenses or successfully fixed
        // 1 = offenses found
        result.success = res.status == 0 || (autoCorrect && res.status == 1);
        
        // Parse JSON output (StandardRB uses same format as RuboCop)
        parseJSONOutput(res.output, result);
        
        return result;
    }
    
    override bool isAvailable()
    {
        auto res = execute(["standardrb", "--version"]);
        return res.status == 0;
    }
    
    override string name() const
    {
        return "StandardRB";
    }
    
    override string getVersion()
    {
        auto res = execute(["standardrb", "--version"]);
        if (res.status == 0)
        {
            // Parse "X.Y.Z"
            return res.output.strip;
        }
        return "unknown";
    }
    
    /// Initialize StandardRB configuration
    static bool initialize(string projectRoot)
    {
        structuredLog.info("standardrb_uses_zero_configuration_by_de").emit();
        structuredLog.info("to_customize_create_standardyml").emit();
        
        auto configFile = buildPath(projectRoot, ".standard.yml");
        if (exists(configFile))
        {
            structuredLog.info("standardyml_already_exists").emit();
            return true;
        }
        
        // StandardRB is zero-config, but allow minimal customization
        string content = `# StandardRB configuration
# StandardRB is opinionated and requires minimal configuration
# See: https://github.com/standardrb/standard

# Ignore paths
ignore:
  - 'vendor/**/*'
  - 'db/schema.rb'

# Ruby version (optional)
# ruby_version: 3.0
`;
        
        try
        {
            std.file.write(configFile, content);
            structuredLog.info("created_standardyml").emit();
            return true;
        }
        catch (Exception e)
        {
            structuredLog.error("failed_to_create_standardyml_").field("detail", "Failed to create .standard.yml: " ~ e.msg).emit();
            return false;
        }
    }
    
    private void parseJSONOutput(string output, ref FormatResult result)
    {
        import std.json;
        import std.conv : to;
        
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
                            auto copName = "cop_name" in offense ? offense["cop_name"].str : "Standard";
                            
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
            structuredLog.warning("failed_to_parse_standardrb_json_output_").field("detail", "Failed to parse StandardRB JSON output: " ~ e.msg).emit();
            
            // Fallback: parse as plain text
            foreach (line; output.lineSplitter)
            {
                if (line.canFind(":") && (line.canFind("error") || line.canFind("warning")))
                {
                    if (line.canFind("error") || line.canFind("Error"))
                        result.errors ~= line;
                    else
                        result.warnings ~= line;
                }
            }
        }
    }
}


