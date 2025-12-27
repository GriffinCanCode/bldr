module languages.jvm.kotlin.tooling.formatters.ktlint;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.kotlin.tooling.formatters.base;
import languages.jvm.kotlin.core.config;
import infrastructure.utils.logging;

/// ktlint formatter implementation
class KtLintFormatter : KotlinFormatter_
{
    override FormatResult format(string[] sources, FormatterConfig config)
    {
        FormatResult result;
        
        structuredLog.info("formatting_kotlin_code_with_ktlint").emit();
        
        auto cmd = ["ktlint"];
        
        // Format flag
        cmd ~= ["-F"];
        
        // Android style
        if (config.ktlintAndroidStyle)
            cmd ~= ["--android"];
        
        // Experimental rules
        if (config.ktlintExperimental)
            cmd ~= ["--experimental"];
        
        // Config file
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["--editorconfig", config.configFile];
        
        // Add source files/patterns
        cmd ~= sources;
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.filesFormatted = cast(int)sources.length;
        
        if (!result.success)
        {
            result.error = res.output;
        }
        
        return result;
    }
    
    override FormatResult check(string[] sources, FormatterConfig config)
    {
        FormatResult result;
        
        structuredLog.info("checking_kotlin_code_style_with_ktlint").emit();
        
        auto cmd = ["ktlint"];
        
        // Android style
        if (config.ktlintAndroidStyle)
            cmd ~= ["--android"];
        
        // Experimental rules
        if (config.ktlintExperimental)
            cmd ~= ["--experimental"];
        
        // Config file
        if (!config.configFile.empty && exists(config.configFile))
            cmd ~= ["--editorconfig", config.configFile];
        
        // Add source files/patterns
        cmd ~= sources;
        
        auto res = execute(cmd);
        
        result.success = res.status == 0;
        result.filesChecked = cast(int)sources.length;
        
        if (!result.success)
        {
            // Parse violations from output
            result.violations = res.output.splitLines()
                .filter!(line => !line.empty)
                .array;
            result.error = "Style violations found";
        }
        
        return result;
    }
    
    override bool isAvailable()
    {
        return staticIsAvailable();
    }
    
    static bool staticIsAvailable()
    {
        auto result = execute(["ktlint", "--version"]);
        return result.status == 0;
    }
    
    override string name() const
    {
        return "ktlint";
    }
}

