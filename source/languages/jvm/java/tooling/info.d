module languages.jvm.java.tooling.info;

import std.process;
import std.string;
import std.algorithm;
import std.array;
import std.regex;
import std.conv;
import languages.jvm.java.core.config;
import infrastructure.utils.logging : structuredLog;

/// Java/JVM version and capability detection
class JavaInfo
{
    /// Get Java version from command
    static JavaVersion getVersion(string javaCmd = "java")
    {
        try
        {
            auto result = execute([javaCmd, "-version"]);
            string output = result.status == 0 ? result.output : "";
            if (output.empty && result.status != 0)
                output = result.output; // stderr for older Java versions
            
            return parseVersionFromOutput(output);
        }
        catch (Exception)
        {
            return JavaVersion.init;
        }
    }
    
    /// Get javac version
    static JavaVersion getCompilerVersion(string javacCmd = "javac")
    {
        try
        {
            auto result = execute([javacCmd, "-version"]);
            string output = result.status == 0 ? result.output : "";
            return parseVersionFromOutput(output);
        }
        catch (Exception)
        {
            return JavaVersion.init;
        }
    }
    
    /// Parse version from java -version output
    private static JavaVersion parseVersionFromOutput(string output)
    {
        // Match patterns like:
        // "1.8.0_292"
        // "11.0.12"
        // "17.0.1"
        // "21"
        
        auto versionRegex = regex(`(\d+)\.(\d+)\.(\d+)(?:_(\d+))?|version "(\d+)"`, "m");
        auto match = matchFirst(output, versionRegex);
        
        if (!match.empty)
        {
            if (!match[1].empty)
            {
                JavaVersion v;
                v.major = match[1].to!int;
                if (v.major == 1 && !match[2].empty)
                    v.major = match[2].to!int; // Handle "1.8" format
                if (!match[2].empty && match[1].to!int != 1)
                    v.minor = match[2].to!int;
                if (!match[3].empty)
                    v.patch = match[3].to!int;
                return v;
            }
            else if (!match[5].empty)
            {
                JavaVersion v;
                v.major = match[5].to!int;
                return v;
            }
        }
        
        // Fallback: try simple number extraction
        auto simpleRegex = regex(`\b(\d+)(?:\.(\d+))?(?:\.(\d+))?\b`);
        auto simpleMatch = matchFirst(output, simpleRegex);
        if (!simpleMatch.empty)
        {
            JavaVersion v;
            v.major = simpleMatch[1].to!int;
            if (simpleMatch.length > 2 && !simpleMatch[2].empty)
                v.minor = simpleMatch[2].to!int;
            if (simpleMatch.length > 3 && !simpleMatch[3].empty)
                v.patch = simpleMatch[3].to!int;
            
            // Handle legacy 1.x format
            if (v.major == 1 && v.minor > 0)
                v.major = v.minor;
            
            return v;
        }
        
        return JavaVersion.init;
    }
    
    /// Detect JVM vendor
    static string getVendor(string javaCmd = "java")
    {
        try
        {
            auto result = execute([javaCmd, "-version"]);
            string output = result.output;
            
            if (output.canFind("OpenJDK"))
                return "OpenJDK";
            if (output.canFind("Oracle"))
                return "Oracle";
            if (output.canFind("GraalVM"))
                return "GraalVM";
            if (output.canFind("Azul"))
                return "Azul Zulu";
            if (output.canFind("Amazon"))
                return "Amazon Corretto";
            if (output.canFind("IBM"))
                return "IBM";
            if (output.canFind("Microsoft"))
                return "Microsoft";
            if (output.canFind("Liberica"))
                return "BellSoft Liberica";
            if (output.canFind("SAP"))
                return "SAP Machine";
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging.logger : Logger;
            structuredLog.debug_("failed_to_get_java_info_").field("detail", "Failed to get Java info: " ~ e.msg).emit();
        }
        
        return "Unknown";
    }
    
    /// Check if GraalVM is being used
    static bool isGraalVM(string javaCmd = "java")
    {
        return getVendor(javaCmd) == "GraalVM";
    }
    
    /// Get JAVA_HOME environment variable
    static string getJavaHome()
    {
        return environment.get("JAVA_HOME", "");
    }
    
    /// Detect if Java supports modules (Java 9+)
    static bool supportsModules(JavaVersion ver)
    {
        return ver.supportsModules();
    }
    
    /// Detect available Java features based on version
    static string[] getAvailableFeatures(JavaVersion ver)
    {
        string[] features;
        
        if (ver.major >= 8)
            features ~= ["Lambdas", "Streams", "Default Methods"];
        if (ver.major >= 9)
            features ~= ["Modules", "JShell", "Process API"];
        if (ver.major >= 10)
            features ~= ["Local Variable Type Inference (var)"];
        if (ver.major >= 11)
            features ~= ["HTTP Client", "Single-File Launch"];
        if (ver.major >= 12)
            features ~= ["Switch Expressions (Preview)"];
        if (ver.major >= 14)
            features ~= ["Records (Preview)", "Pattern Matching (Preview)"];
        if (ver.major >= 15)
            features ~= ["Text Blocks", "Sealed Classes (Preview)"];
        if (ver.major >= 16)
            features ~= ["Records", "Pattern Matching"];
        if (ver.major >= 17)
            features ~= ["Sealed Classes"];
        if (ver.major >= 18)
            features ~= ["Simple Web Server"];
        if (ver.major >= 19)
            features ~= ["Virtual Threads (Preview)"];
        if (ver.major >= 21)
            features ~= ["Virtual Threads", "Sequenced Collections", "Pattern Matching for switch"];
        
        return features;
    }
    
    /// Check if Java version is LTS (Long Term Support)
    static bool isLTS(int major)
    {
        return major == 8 || major == 11 || major == 17 || major == 21;
    }
    
    /// Get recommended Java version for new projects
    static int getRecommendedVersion()
    {
        return 21; // Current LTS as of 2023+
    }
    
    /// Validate Java version meets minimum requirement
    static bool meetsMinimumVersion(JavaVersion current, JavaVersion required)
    {
        if (current.major < required.major)
            return false;
        if (current.major > required.major)
            return true;
        if (current.minor < required.minor)
            return false;
        if (current.minor > required.minor)
            return true;
        return current.patch >= required.patch;
    }
    
    /// Get Maven version
    static string getMavenVersion()
    {
        try
        {
            auto result = execute(["mvn", "-version"]);
            if (result.status == 0)
            {
                auto match = matchFirst(result.output, regex(`Apache Maven ([\d.]+)`));
                if (!match.empty)
                    return match[1];
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging.logger : Logger;
            structuredLog.debug_("failed_to_get_java_info_").field("detail", "Failed to get Java info: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Get Gradle version
    static string getGradleVersion()
    {
        try
        {
            auto result = execute(["gradle", "--version"]);
            if (result.status == 0)
            {
                auto match = matchFirst(result.output, regex(`Gradle ([\d.]+)`));
                if (!match.empty)
                    return match[1];
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging.logger : Logger;
            structuredLog.debug_("failed_to_get_java_info_").field("detail", "Failed to get Java info: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Get JVM arguments
    static string[] getJVMArgs()
    {
        string javaToolOptions = environment.get("JAVA_TOOL_OPTIONS", "");
        string javaOpts = environment.get("JAVA_OPTS", "");
        
        string[] args;
        if (!javaToolOptions.empty)
            args ~= javaToolOptions.split();
        if (!javaOpts.empty)
            args ~= javaOpts.split();
        
        return args;
    }
    
    /// Detect class file version from .class file
    static int detectClassFileVersion(string classFile)
    {
        import std.stdio : File;
        import std.file : exists;
        
        try
        {
            if (!exists(classFile))
                return 0;
            
            auto file = File(classFile, "rb");
            ubyte[8] header;
            file.rawRead(header);
            
            // Java class file format: magic (4 bytes) + minor (2 bytes) + major (2 bytes)
            if (header[0..4] != [0xCA, 0xFE, 0xBA, 0xBE])
                return 0;
            
            int major = (header[6] << 8) | header[7];
            
            // Convert class file version to Java version
            // Java 8 = 52, Java 11 = 55, Java 17 = 61, Java 21 = 65
            if (major >= 45)
                return major - 44;
            
            return 0;
        }
        catch (Exception)
        {
            return 0;
        }
    }
    
    /// Get maximum heap size
    static string getMaxHeapSize(string javaCmd = "java")
    {
        try
        {
            auto result = execute([javaCmd, "-XX:+PrintFlagsFinal", "-version"]);
            if (result.status == 0)
            {
                auto match = matchFirst(result.output, regex(`MaxHeapSize\s*=\s*(\d+)`));
                if (!match.empty)
                {
                    long bytes = match[1].to!long;
                    enum double BYTES_PER_GB = 1024.0 * 1024.0 * 1024.0;
                    return format("%.1f GB", bytes / BYTES_PER_GB);
                }
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging.logger : Logger;
            structuredLog.debug_("failed_to_get_java_info_").field("detail", "Failed to get Java info: " ~ e.msg).emit();
        }
        
        return "Unknown";
    }
}

