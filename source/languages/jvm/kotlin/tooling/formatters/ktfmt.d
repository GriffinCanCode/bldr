module languages.jvm.kotlin.tooling.formatters.ktfmt;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.kotlin.tooling.formatters.base;
import languages.jvm.kotlin.core.config;
import infrastructure.utils.logging;

/// ktfmt formatter implementation (Google style)
class KtFmtFormatter : KotlinFormatter_
{
    override FormatResult format(string[] sources, FormatterConfig config)
    {
        FormatResult result;
        
        structuredLog.info("formatting_kotlin_code_with_ktfmt").emit();
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            auto cmd = ["ktfmt"];
            
            // Style
            if (config.ktfmtGoogleStyle)
                cmd ~= ["--google-style"];
            else if (config.ktfmtDropboxStyle)
                cmd ~= ["--dropbox-style"];
            
            cmd ~= [source];
            
            auto res = execute(cmd);
            
            if (res.status == 0)
            {
                result.filesFormatted++;
            }
            else
            {
                result.error ~= "Failed to format " ~ source ~ "\n";
            }
        }
        
        result.success = result.filesFormatted == sources.length;
        
        return result;
    }
    
    override FormatResult check(string[] sources, FormatterConfig config)
    {
        FormatResult result;
        
        structuredLog.info("checking_kotlin_code_style_with_ktfmt").emit();
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            auto cmd = ["ktfmt"];
            
            // Dry run
            cmd ~= ["--dry-run"];
            
            // Style
            if (config.ktfmtGoogleStyle)
                cmd ~= ["--google-style"];
            else if (config.ktfmtDropboxStyle)
                cmd ~= ["--dropbox-style"];
            
            cmd ~= [source];
            
            auto res = execute(cmd);
            
            if (res.status == 0)
            {
                result.filesChecked++;
            }
            else
            {
                result.violations ~= source ~ ": needs formatting";
            }
        }
        
        result.success = result.violations.empty;
        result.filesChecked = cast(int)sources.length;
        
        if (!result.success)
        {
            result.error = "Files need formatting";
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        return staticIsAvailable();
    }
    
    static bool staticIsAvailable()
    {
        auto result = execute(["ktfmt", "--version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "ktfmt";
    }
}

