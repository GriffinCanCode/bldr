module languages.scripting.ruby.analysis.dependencies;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import infrastructure.utils.logging;

/// Gemfile parser for dependency analysis
class GemfileParser
{
    static GemSpec[] parse(string gemfilePath)
    {
        GemSpec[] gems;
        
        if (!exists(gemfilePath))
            return gems;
        
        try
        {
            auto content = readText(gemfilePath);
            foreach (line; content.lineSplitter)
            {
                auto stripped = line.strip;
                
                // Skip comments and empty lines
                if (stripped.empty || stripped.startsWith("#"))
                    continue;
                
                // Parse gem declarations
                if (stripped.startsWith("gem "))
                {
                    auto gem = parseGemLine(stripped);
                    if (!gem.name.empty)
                        gems ~= gem;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_gemfile_").field("detail", "Failed to parse Gemfile: " ~ e.msg).emit();
        }
        
        return gems;
    }
    
    private static GemSpec parseGemLine(string line)
    {
        GemSpec gem;
        
        // Remove "gem " prefix
        line = line[4..$].strip;
        
        // Handle different formats:
        // gem 'name'
        // gem 'name', 'version'
        // gem 'name', version: 'x'
        // gem 'name', git: 'url'
        // gem 'name', group: :development
        
        // Simple regex-like parsing
        string[] parts;
        bool inQuote = false;
        string current;
        
        foreach (ch; line)
        {
            if (ch == '\'' || ch == '"')
            {
                if (inQuote)
                {
                    if (!current.empty)
                        parts ~= current;
                    current = "";
                }
                inQuote = !inQuote;
            }
            else if (ch == ',' && !inQuote)
            {
                if (!current.empty)
                    parts ~= current;
                current = "";
            }
            else if (!inQuote && (ch == ' ' || ch == '\t'))
            {
                continue; // Skip whitespace outside quotes
            }
            else
            {
                current ~= ch;
            }
        }
        
        if (!current.empty)
            parts ~= current;
        
        if (parts.empty)
            return gem;
        
        // First part is always the gem name
        gem.name = parts[0].strip("'\"");
        
        // Parse additional parts
        if (parts.length > 1)
        {
            foreach (part; parts[1..$])
            {
                auto trimmed = part.strip;
                
                // Check for key-value pairs
                if (trimmed.canFind(":"))
                {
                    auto kv = trimmed.split(":");
                    if (kv.length == 2)
                    {
                        auto key = kv[0].strip;
                        auto value = kv[1].strip("'\" \t");
                        
                        switch (key)
                        {
                            case "version":
                            case "versions":
                                gem.version_ = value;
                                break;
                            case "git":
                            case "github":
                            case "path":
                                gem.source = value;
                                break;
                            case "group":
                            case "groups":
                                gem.group = value;
                                break;
                            case "platform":
                            case "platforms":
                                gem.platform = value;
                                break;
                            case "require":
                                gem.required = value != "false";
                                break;
                            default:
                                break;
                        }
                    }
                }
                else if (!trimmed.startsWith(":"))
                {
                    // Assume it's a version constraint
                    gem.version_ = trimmed.strip("'\"");
                }
            }
        }
        
        return gem;
    }
}

/// Gemfile.lock parser
class GemfileLockParser
{
    struct LockInfo
    {
        string[string] versions; // gem name -> version
        string[] platforms;
        string bundlerVersion;
        string rubyVersion;
    }
    
    static LockInfo parse(string lockfilePath)
    {
        LockInfo info;
        
        if (!exists(lockfilePath))
            return info;
        
        try
        {
            auto content = readText(lockfilePath);
            string currentSection;
            
            foreach (line; content.lineSplitter)
            {
                auto trimmed = line.strip;
                
                if (trimmed.empty)
                    continue;
                
                // Section headers (no indentation)
                if (!line.startsWith(" ") && !line.startsWith("\t"))
                {
                    currentSection = trimmed;
                    continue;
                }
                
                // Parse based on section
                if (currentSection == "GEM")
                {
                    // Indented gem entries: "    gem_name (version)"
                    if (line.startsWith("    ") && line.canFind("(") && line.canFind(")"))
                    {
                        auto gemLine = line.strip;
                        auto openParen = gemLine.indexOf("(");
                        auto closeParen = gemLine.indexOf(")");
                        
                        if (openParen > 0 && closeParen > openParen)
                        {
                            auto name = gemLine[0..openParen].strip;
                            auto version_ = gemLine[openParen+1..closeParen].strip;
                            info.versions[name] = version_;
                        }
                    }
                }
                else if (currentSection == "PLATFORMS")
                {
                    info.platforms ~= trimmed;
                }
                else if (currentSection == "BUNDLED WITH")
                {
                    info.bundlerVersion = trimmed;
                }
                else if (currentSection == "RUBY VERSION")
                {
                    info.rubyVersion = trimmed.split[0].strip("ruby ");
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_gemfilelock_").field("detail", "Failed to parse Gemfile.lock: " ~ e.msg).emit();
        }
        
        return info;
    }
}


