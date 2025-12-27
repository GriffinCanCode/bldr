module languages.jvm.scala.tooling.info;

import std.process;
import std.string;
import std.regex;
import std.algorithm;
import std.array;
import std.conv;
import languages.jvm.scala.core.config;
import infrastructure.utils.logging : structuredLog;

/// Scala runtime and compiler information
struct ScalaInfo
{
    ScalaVersionInfo versionInfo;
    string javaVersion;
    string javaHome;
    bool isScala3;
    string[] enabledFeatures;
    string scalacPath;
    string scalaPath;
}

/// Scala capability detection and version information
class ScalaInfoDetector
{
    /// Get comprehensive Scala information
    static ScalaInfo getInfo()
    {
        ScalaInfo info;
        
        info.versionInfo = detectVersion();
        info.isScala3 = info.versionInfo.isScala3();
        info.javaVersion = getJavaVersion();
        info.javaHome = getJavaHome();
        info.scalacPath = detectScalacPath();
        info.scalaPath = detectScalaPath();
        
        return info;
    }
    
    /// Detect Scala version from scalac
    static ScalaVersionInfo detectVersion()
    {
        ScalaVersionInfo versionInfo;
        versionInfo.major = 2;
        versionInfo.minor = 13;
        versionInfo.patch = 0;
        
        try
        {
            auto result = execute(["scalac", "-version"]);
            if (result.status == 0)
            {
                // Parse output like "Scala compiler version 2.13.10" or "Scala compiler version 3.3.0"
                auto match = matchFirst(result.output, regex(`version\s+([\d.]+)`));
                if (!match.empty)
                {
                    versionInfo = ScalaVersionInfo.parse(match[1]);
                }
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_get_scala_version_").field("detail", "Failed to get Scala version: " ~ e.msg).emit();
        }
        
        return versionInfo;
    }
    
    /// Get Java version
    static string getJavaVersion()
    {
        try
        {
            auto result = execute(["java", "-version"]);
            auto output = result.status == 0 ? result.output : "";
            
            // Java version might be in stderr
            if (output.empty)
            {
                result = execute(["java", "-version"]);
                output = result.output;
            }
            
            auto match = matchFirst(output, regex(`version\s+"([^"]+)"`));
            if (!match.empty)
                return match[1];
            
            match = matchFirst(output, regex(`openjdk version\s+"([^"]+)"`));
            if (!match.empty)
                return match[1];
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_get_scala_version_").field("detail", "Failed to get Scala version: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Get Java home directory
    static string getJavaHome()
    {
        return environment.get("JAVA_HOME", "");
    }
    
    /// Detect scalac binary path
    static string detectScalacPath()
    {
        try
        {
            version(Windows)
            {
                auto result = execute(["where", "scalac"]);
                if (result.status == 0 && !result.output.empty)
                    return result.output.strip.split("\n")[0];
            }
            else
            {
                auto result = execute(["which", "scalac"]);
                if (result.status == 0 && !result.output.empty)
                    return result.output.strip;
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_get_scala_version_").field("detail", "Failed to get Scala version: " ~ e.msg).emit();
        }
        
        return "scalac";
    }
    
    /// Detect scala binary path
    static string detectScalaPath()
    {
        try
        {
            version(Windows)
            {
                auto result = execute(["where", "scala"]);
                if (result.status == 0 && !result.output.empty)
                    return result.output.strip.split("\n")[0];
            }
            else
            {
                auto result = execute(["which", "scala"]);
                if (result.status == 0 && !result.output.empty)
                    return result.output.strip;
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_get_scala_version_").field("detail", "Failed to get Scala version: " ~ e.msg).emit();
        }
        
        return "scala";
    }
    
    /// Check if specific Scala version is available
    static bool hasVersion(ScalaVersionInfo required)
    {
        auto current = detectVersion();
        return current.major == required.major && 
               current.minor >= required.minor;
    }
    
    /// Check if Scala 3 features are available
    static bool hasScala3Features()
    {
        auto versionInfo = detectVersion();
        return versionInfo.isScala3();
    }
    
    /// Get supported Scala language features
    static string[] getSupportedFeatures(ScalaVersionInfo versionInfo)
    {
        string[] features;
        
        // Scala 2 features
        if (versionInfo.major == 2)
        {
            features ~= "implicits";
            features ~= "higherKinds";
            features ~= "existentials";
            
            if (versionInfo.minor >= 12)
            {
                features ~= "implicitConversions";
                features ~= "postfixOps";
                features ~= "reflectiveCalls";
            }
            
            if (versionInfo.minor >= 13)
            {
                features ~= "dynamics";
                features ~= "macros";
            }
        }
        
        // Scala 3 features
        if (versionInfo.major >= 3)
        {
            features ~= "given";
            features ~= "extensionMethods";
            features ~= "opaqueTypes";
            features ~= "unionTypes";
            features ~= "intersectionTypes";
            features ~= "matchTypes";
            features ~= "contextFunctions";
            features ~= "polymorphicFunctionTypes";
            features ~= "dependentFunctionTypes";
            features ~= "kindPolymorphism";
        }
        
        return features;
    }
    
    /// Get compiler option recommendations
    static string[] getRecommendedCompilerOptions(ScalaVersionInfo versionInfo)
    {
        string[] options;
        
        // Common options
        options ~= "-deprecation";
        options ~= "-feature";
        options ~= "-unchecked";
        
        if (versionInfo.major == 2)
        {
            // Scala 2 specific
            options ~= "-Xlint";
            options ~= "-Ywarn-dead-code";
            options ~= "-Ywarn-unused";
            options ~= "-Ywarn-value-discard";
            
            if (versionInfo.minor >= 13)
            {
                options ~= "-Xlint:adapted-args";
                options ~= "-Xlint:nullary-unit";
                options ~= "-Xlint:inaccessible";
                options ~= "-Xlint:infer-any";
            }
        }
        else if (versionInfo.major >= 3)
        {
            // Scala 3 specific
            options ~= "-explain";
            options ~= "-explain-types";
            options ~= "-new-syntax";
            options ~= "-rewrite";
        }
        
        return options;
    }
    
    /// Get optimization options
    static string[] getOptimizationOptions(OptimizationLevel level, ScalaVersionInfo versionInfo)
    {
        string[] options;
        
        final switch (level)
        {
            case OptimizationLevel.None:
                return options;
            
            case OptimizationLevel.Basic:
                if (versionInfo.major == 2)
                {
                    options ~= "-opt:l:inline";
                    options ~= "-opt-inline-from:**";
                }
                break;
            
            case OptimizationLevel.Aggressive:
                if (versionInfo.major == 2)
                {
                    options ~= "-opt:l:inline";
                    options ~= "-opt:l:method";
                    options ~= "-opt:l:project";
                    options ~= "-opt-inline-from:**";
                    options ~= "-opt-warnings";
                }
                break;
        }
        
        return options;
    }
    
    /// Check compatibility with target JVM version
    static bool isJvmVersionCompatible(string jvmTarget, ScalaVersionInfo scalaVersion)
    {
        // Scala 2.12+ requires Java 8+
        if (scalaVersion.major == 2 && scalaVersion.minor >= 12)
        {
            return jvmTarget >= "1.8";
        }
        
        // Scala 3 requires Java 8+
        if (scalaVersion.major >= 3)
        {
            return jvmTarget >= "1.8";
        }
        
        return true;
    }
    
    /// Get memory recommendations for compilation
    static string[] getMemoryOptions(size_t sourceFilesCount)
    {
        string[] options;
        
        // Base JVM options
        if (sourceFilesCount < 100)
        {
            options ~= "-Xms512m";
            options ~= "-Xmx1g";
        }
        else if (sourceFilesCount < 500)
        {
            options ~= "-Xms1g";
            options ~= "-Xmx2g";
        }
        else
        {
            options ~= "-Xms2g";
            options ~= "-Xmx4g";
        }
        
        // Improve compilation performance
        options ~= "-XX:+UseParallelGC";
        options ~= "-XX:ReservedCodeCacheSize=256m";
        
        return options;
    }
}

