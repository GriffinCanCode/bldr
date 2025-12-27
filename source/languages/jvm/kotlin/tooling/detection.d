module languages.jvm.kotlin.tooling.detection;

import std.process;
import std.string;
import std.algorithm;
import std.regex;
import infrastructure.utils.logging;

/// Kotlin compiler and tool detection
class KotlinDetection
{
    /// Check if kotlinc is available
    static bool hasKotlinC()
    {
        auto result = execute(["kotlinc", "-version"]);
        return result.status == 0;
    }
    
    /// Check if kotlin-native is available
    static bool hasKotlinNative()
    {
        auto result = execute(["kotlinc-native", "-version"]);
        return result.status == 0;
    }
    
    /// Check if kotlin-js is available
    static bool hasKotlinJS()
    {
        auto result = execute(["kotlinc-js", "-version"]);
        return result.status == 0;
    }
    
    /// Check if Gradle is available
    static bool hasGradle()
    {
        auto result = execute(["gradle", "--version"]);
        return result.status == 0;
    }
    
    /// Check if Maven is available
    static bool hasMaven()
    {
        auto result = execute(["mvn", "--version"]);
        return result.status == 0;
    }
    
    /// Check if ktlint is available
    static bool hasKtLint()
    {
        auto result = execute(["ktlint", "--version"]);
        return result.status == 0;
    }
    
    /// Check if ktfmt is available
    static bool hasKtFmt()
    {
        auto result = execute(["ktfmt", "--version"]);
        return result.status == 0;
    }
    
    /// Check if detekt is available
    static bool hasDetekt()
    {
        auto result = execute(["detekt", "--version"]);
        return result.status == 0;
    }
    
    /// Get Kotlin compiler version
    static string getKotlinVersion()
    {
        auto result = execute(["kotlinc", "-version"]);
        if (result.status == 0)
        {
            auto match = matchFirst(result.output, regex(`(\d+\.\d+\.\d+)`));
            if (!match.empty)
                return match[1];
        }
        return "";
    }
    
    /// Get Gradle version
    static string getGradleVersion()
    {
        auto result = execute(["gradle", "--version"]);
        if (result.status == 0)
        {
            auto match = matchFirst(result.output, regex(`Gradle ([\d.]+)`));
            if (!match.empty)
                return match[1];
        }
        return "";
    }
    
    /// Get Maven version
    static string getMavenVersion()
    {
        auto result = execute(["mvn", "--version"]);
        if (result.status == 0)
        {
            auto match = matchFirst(result.output, regex(`Apache Maven ([\d.]+)`));
            if (!match.empty)
                return match[1];
        }
        return "";
    }
    
    /// Get Java version (for JVM compilation)
    static string getJavaVersion()
    {
        auto result = execute(["java", "-version"]);
        if (result.status == 0)
        {
            auto match = matchFirst(result.output, regex(`version "([^"]+)"`));
            if (!match.empty)
                return match[1];
        }
        return "";
    }
    
    /// Check all available tools and log
    static void detectAll()
    {
        structuredLog.info("detecting_kotlin_tools").emit();
        
        if (hasKotlinC())
            structuredLog.info("__kotlinc_").field("detail", "  kotlinc: " ~ getKotlinVersion()).emit();
        else
            structuredLog.warning("__kotlinc_not_found").emit();
        
        if (hasKotlinNative())
            structuredLog.info("__kotlinnative_available").emit();
        else
            structuredLog.debug_("__kotlinnative_not_found").emit();
        
        if (hasKotlinJS())
            structuredLog.info("__kotlinjs_available").emit();
        else
            structuredLog.debug_("__kotlinjs_not_found").emit();
        
        if (hasGradle())
            structuredLog.info("__gradle_").field("detail", "  Gradle: " ~ getGradleVersion()).emit();
        else
            structuredLog.debug_("__gradle_not_found").emit();
        
        if (hasMaven())
            structuredLog.info("__maven_").field("detail", "  Maven: " ~ getMavenVersion()).emit();
        else
            structuredLog.debug_("__maven_not_found").emit();
        
        if (hasKtLint())
            structuredLog.info("__ktlint_available").emit();
        else
            structuredLog.debug_("__ktlint_not_found").emit();
        
        if (hasDetekt())
            structuredLog.info("__detekt_available").emit();
        else
            structuredLog.debug_("__detekt_not_found").emit();
        
        structuredLog.info("__java_").field("detail", "  Java: " ~ getJavaVersion()).emit();
    }
}

