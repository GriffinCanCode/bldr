module languages.jvm.kotlin.tooling.formatters.intellij;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.jvm.kotlin.tooling.formatters.base;
import languages.jvm.kotlin.core.config;
import infrastructure.utils.logging;

/// IntelliJ IDEA formatter (requires IntelliJ CLI or ktlint with IntelliJ style)
class IntelliJFormatter : KotlinFormatter_
{
    override FormatResult format(string[] sources, FormatterConfig config)
    {
        FormatResult result;
        
        structuredLog.warning("intellij_formatter_requires_manual_ide_i").emit();
        
        // Fallback to ktlint if available
        import languages.jvm.kotlin.tooling.formatters.ktlint;
        if (KtLintFormatter.staticIsAvailable())
        {
            auto ktlint = new KtLintFormatter();
            return ktlint.format(sources, config);
        }
        
        result.success = false;
        result.error = "IntelliJ formatter not available. Install ktlint or use IntelliJ IDE.";
        
        return result;
    }
    
    override FormatResult check(string[] sources, FormatterConfig config)
    {
        FormatResult result;
        
        // Fallback to ktlint if available
        import languages.jvm.kotlin.tooling.formatters.ktlint;
        if (KtLintFormatter.staticIsAvailable())
        {
            auto ktlint = new KtLintFormatter();
            return ktlint.check(sources, config);
        }
        
        result.success = false;
        result.error = "IntelliJ formatter not available";
        
        return result;
    }
    
    override bool isAvailable()
    {
        // Check if ktlint is available as fallback
        import languages.jvm.kotlin.tooling.formatters.ktlint;
        return KtLintFormatter.staticIsAvailable();
    }
    
    override string name() const
    {
        return "IntelliJ";
    }
}

