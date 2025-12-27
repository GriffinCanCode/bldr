module languages.jvm.java.tooling.detection;

import std.process;
import std.string;
import std.file;
import std.path;
import std.algorithm;
import infrastructure.utils.logging : structuredLog;

/// Tool detection utilities for Java ecosystem
class JavaToolDetection
{
    /// Check if javac is available
    static bool isJavacAvailable()
    {
        try
        {
            auto result = execute(["javac", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if jar tool is available
    static bool isJarAvailable()
    {
        try
        {
            auto result = execute(["jar", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Maven is available
    static bool isMavenAvailable()
    {
        try
        {
            auto result = execute(["mvn", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Gradle is available
    static bool isGradleAvailable()
    {
        try
        {
            auto result = execute(["gradle", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Gradle wrapper exists
    static bool hasGradleWrapper(string projectDir)
    {
        string gradlew = buildPath(projectDir, "gradlew");
        version(Windows)
            gradlew = buildPath(projectDir, "gradlew.bat");
        
        return exists(gradlew) && isFile(gradlew);
    }
    
    /// Check if Maven wrapper exists
    static bool hasMavenWrapper(string projectDir)
    {
        string mvnw = buildPath(projectDir, "mvnw");
        version(Windows)
            mvnw = buildPath(projectDir, "mvnw.cmd");
        
        return exists(mvnw) && isFile(mvnw);
    }
    
    /// Check if pom.xml exists
    static bool hasPomXml(string projectDir)
    {
        return exists(buildPath(projectDir, "pom.xml"));
    }
    
    /// Check if build.gradle or build.gradle.kts exists
    static bool hasBuildGradle(string projectDir)
    {
        return exists(buildPath(projectDir, "build.gradle")) ||
               exists(buildPath(projectDir, "build.gradle.kts"));
    }
    
    /// Check if settings.gradle exists (multi-module project)
    static bool hasSettingsGradle(string projectDir)
    {
        return exists(buildPath(projectDir, "settings.gradle")) ||
               exists(buildPath(projectDir, "settings.gradle.kts"));
    }
    
    /// Check if module-info.java exists (Java 9+ modules)
    static bool hasModuleInfo(string projectDir)
    {
        import std.file : dirEntries, SpanMode;
        
        try
        {
            foreach (entry; dirEntries(projectDir, "module-info.java", SpanMode.depth))
                return true;
        }
        catch (Exception e)
        {
            // Directory may not exist or not be accessible
        }
        
        return false;
    }
    
    /// Check if JUnit is available (in classpath or Maven/Gradle)
    static bool isJUnitAvailable(string projectDir)
    {
        // Check Maven dependencies
        if (hasPomXml(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "pom.xml"));
                if (content.canFind("junit-jupiter") || content.canFind("junit"))
                    return true;
            }
            catch (Exception e)
            {
                // File may not be readable
            }
        }
        
        // Check Gradle dependencies
        if (hasBuildGradle(projectDir))
        {
            try
            {
                string buildFile = buildPath(projectDir, "build.gradle");
                if (!exists(buildFile))
                    buildFile = buildPath(projectDir, "build.gradle.kts");
                
                auto content = readText(buildFile);
                if (content.canFind("junit"))
                    return true;
            }
            catch (Exception e)
            {
                // File may not be readable
            }
        }
        
        return false;
    }
    
    /// Check if TestNG is available
    static bool isTestNGAvailable(string projectDir)
    {
        if (hasPomXml(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "pom.xml"));
                return content.canFind("testng");
            }
            catch (Exception e)
            {
                // File may not be readable
            }
        }
        
        if (hasBuildGradle(projectDir))
        {
            try
            {
                string buildFile = buildPath(projectDir, "build.gradle");
                if (!exists(buildFile))
                    buildFile = buildPath(projectDir, "build.gradle.kts");
                
                auto content = readText(buildFile);
                return content.canFind("testng");
            }
            catch (Exception e)
            {
                // File may not be readable
            }
        }
        
        return false;
    }
    
    /// Check if SpotBugs is available
    static bool isSpotBugsAvailable()
    {
        try
        {
            auto result = execute(["spotbugs", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if PMD is available
    static bool isPMDAvailable()
    {
        try
        {
            auto result = execute(["pmd", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Checkstyle is available
    static bool isCheckstyleAvailable()
    {
        try
        {
            auto result = execute(["checkstyle", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if google-java-format is available
    static bool isGoogleJavaFormatAvailable()
    {
        try
        {
            auto result = execute(["google-java-format", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if GraalVM native-image is available
    static bool isNativeImageAvailable()
    {
        try
        {
            auto result = execute(["native-image", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Get java command path
    static string getJavaCommand()
    {
        string javaHome = environment.get("JAVA_HOME", "");
        if (!javaHome.empty)
        {
            version(Windows)
                return buildPath(javaHome, "bin", "java.exe");
            else
                return buildPath(javaHome, "bin", "java");
        }
        
        return "java";
    }
    
    /// Get javac command path
    static string getJavacCommand()
    {
        string javaHome = environment.get("JAVA_HOME", "");
        if (!javaHome.empty)
        {
            version(Windows)
                return buildPath(javaHome, "bin", "javac.exe");
            else
                return buildPath(javaHome, "bin", "javac");
        }
        
        return "javac";
    }
    
    /// Get jar command path
    static string getJarCommand()
    {
        string javaHome = environment.get("JAVA_HOME", "");
        if (!javaHome.empty)
        {
            version(Windows)
                return buildPath(javaHome, "bin", "jar.exe");
            else
                return buildPath(javaHome, "bin", "jar");
        }
        
        return "jar";
    }
    
    /// Detect if Lombok is being used
    static bool usesLombok(string projectDir)
    {
        if (hasPomXml(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "pom.xml"));
                return content.canFind("lombok");
            }
            catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_detect_java_project_info_").field("detail", "Failed to detect Java project info: " ~ e.msg).emit();
        }
        }
        
        if (hasBuildGradle(projectDir))
        {
            try
            {
                string buildFile = buildPath(projectDir, "build.gradle");
                if (!exists(buildFile))
                    buildFile = buildPath(projectDir, "build.gradle.kts");
                
                auto content = readText(buildFile);
                return content.canFind("lombok");
            }
            catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_detect_java_project_info_").field("detail", "Failed to detect Java project info: " ~ e.msg).emit();
        }
        }
        
        return false;
    }
    
    /// Detect Spring Boot project
    static bool isSpringBootProject(string projectDir)
    {
        if (hasPomXml(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "pom.xml"));
                return content.canFind("spring-boot-starter");
            }
            catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_detect_java_project_info_").field("detail", "Failed to detect Java project info: " ~ e.msg).emit();
        }
        }
        
        if (hasBuildGradle(projectDir))
        {
            try
            {
                string buildFile = buildPath(projectDir, "build.gradle");
                if (!exists(buildFile))
                    buildFile = buildPath(projectDir, "build.gradle.kts");
                
                auto content = readText(buildFile);
                return content.canFind("spring-boot");
            }
            catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_detect_java_project_info_").field("detail", "Failed to detect Java project info: " ~ e.msg).emit();
        }
        }
        
        return false;
    }
}

