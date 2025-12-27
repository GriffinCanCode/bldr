module languages.jvm.scala.tooling.detection;

import std.process;
import std.string;
import std.file;
import std.path;
import std.algorithm;
import std.regex;
import std.array;
import languages.jvm.scala.core.config;
import infrastructure.utils.logging : structuredLog;

/// Tool detection utilities for Scala ecosystem
class ScalaToolDetection
{
    /// Check if scalac is available
    static bool isScalacAvailable()
    {
        try
        {
            auto result = execute(["scalac", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if scala REPL is available
    static bool isScalaAvailable()
    {
        try
        {
            auto result = execute(["scala", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if sbt is available
    static bool isSBTAvailable()
    {
        try
        {
            auto result = execute(["sbt", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Mill is available
    static bool isMillAvailable()
    {
        try
        {
            auto result = execute(["mill", "version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Scala CLI is available
    static bool isScalaCLIAvailable()
    {
        try
        {
            auto result = execute(["scala-cli", "version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Bloop is available
    static bool isBloopAvailable()
    {
        try
        {
            auto result = execute(["bloop", "about"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if Coursier is available
    static bool isCoursierAvailable()
    {
        try
        {
            auto result = execute(["cs", "version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if scalafmt is available
    static bool isScalafmtAvailable()
    {
        try
        {
            auto result = execute(["scalafmt", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if scalafix is available
    static bool isScalafixAvailable()
    {
        try
        {
            auto result = execute(["scalafix", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if build.sbt exists
    static bool hasBuildSbt(string projectDir)
    {
        return exists(buildPath(projectDir, "build.sbt"));
    }
    
    /// Check if project directory exists (sbt multi-project)
    static bool hasProjectDir(string projectDir)
    {
        return exists(buildPath(projectDir, "project")) && 
               isDir(buildPath(projectDir, "project"));
    }
    
    /// Check if build.sc exists (Mill)
    static bool hasBuildSc(string projectDir)
    {
        return exists(buildPath(projectDir, "build.sc"));
    }
    
    /// Check if .bloop directory exists
    static bool hasBloopConfig(string projectDir)
    {
        return exists(buildPath(projectDir, ".bloop")) &&
               isDir(buildPath(projectDir, ".bloop"));
    }
    
    /// Check if pom.xml exists (Maven with Scala)
    static bool hasPomXml(string projectDir)
    {
        string pomPath = buildPath(projectDir, "pom.xml");
        if (!exists(pomPath))
            return false;
        
        try
        {
            auto content = readText(pomPath);
            return content.canFind("scala-maven-plugin") || 
                   content.canFind("scala-library");
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Check if build.gradle exists (Gradle with Scala)
    static bool hasBuildGradle(string projectDir)
    {
        string gradlePath = buildPath(projectDir, "build.gradle");
        string gradleKtsPath = buildPath(projectDir, "build.gradle.kts");
        
        if (exists(gradlePath))
        {
            try
            {
                auto content = readText(gradlePath);
                return content.canFind("scala") || content.canFind("org.scala-lang");
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        if (exists(gradleKtsPath))
        {
            try
            {
                auto content = readText(gradleKtsPath);
                return content.canFind("scala") || content.canFind("org.scala-lang");
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        return false;
    }
    
    /// Check if .scalafmt.conf exists
    static bool hasScalafmtConfig(string projectDir)
    {
        return exists(buildPath(projectDir, ".scalafmt.conf"));
    }
    
    /// Check if .scalafix.conf exists
    static bool hasScalafixConfig(string projectDir)
    {
        return exists(buildPath(projectDir, ".scalafix.conf"));
    }
    
    /// Detect Scala version from project
    static ScalaVersionInfo detectScalaVersion(string projectDir)
    {
        ScalaVersionInfo versionInfo;
        versionInfo.major = 2;
        versionInfo.minor = 13;
        versionInfo.patch = 0;
        
        // Try build.sbt
        if (hasBuildSbt(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sbt"));
                auto match = matchFirst(content, regex(`scalaVersion\s*:=\s*"([\d.]+)"`));
                if (!match.empty)
                    return ScalaVersionInfo.parse(match[1]);
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        // Try build.sc (Mill)
        if (hasBuildSc(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sc"));
                auto match = matchFirst(content, regex(`scalaVersion\s*=\s*"([\d.]+)"`));
                if (!match.empty)
                    return ScalaVersionInfo.parse(match[1]);
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        // Try pom.xml
        if (hasPomXml(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "pom.xml"));
                auto match = matchFirst(content, regex(`<scala\.version>([\d.]+)</scala\.version>`));
                if (!match.empty)
                    return ScalaVersionInfo.parse(match[1]);
                
                // Try scala-library dependency
                match = matchFirst(content, regex(`<artifactId>scala-library</artifactId>\s*<version>([\d.]+)</version>`));
                if (!match.empty)
                    return ScalaVersionInfo.parse(match[1]);
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        return versionInfo;
    }
    
    /// Auto-detect best build tool
    static ScalaBuildTool detectBuildTool(string projectDir)
    {
        // Check for build files in priority order
        if (hasBuildSbt(projectDir) && isSBTAvailable())
            return ScalaBuildTool.SBT;
        
        if (hasBuildSc(projectDir) && isMillAvailable())
            return ScalaBuildTool.Mill;
        
        if (hasPomXml(projectDir))
            return ScalaBuildTool.Maven;
        
        if (hasBuildGradle(projectDir))
            return ScalaBuildTool.Gradle;
        
        if (hasBloopConfig(projectDir) && isBloopAvailable())
            return ScalaBuildTool.Bloop;
        
        if (isScalaCLIAvailable())
            return ScalaBuildTool.ScalaCLI;
        
        if (isScalacAvailable())
            return ScalaBuildTool.Direct;
        
        return ScalaBuildTool.None;
    }
    
    /// Detect if project uses Scala.js
    static bool usesScalaJS(string projectDir)
    {
        if (hasBuildSbt(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sbt"));
                if (content.canFind("scalaJSProjects") || content.canFind("enablePlugins(ScalaJSPlugin)"))
                    return true;
                
                // Check project plugins
                string pluginsPath = buildPath(projectDir, "project", "plugins.sbt");
                if (exists(pluginsPath))
                {
                    auto pluginContent = readText(pluginsPath);
                    if (pluginContent.canFind("sbt-scalajs"))
                        return true;
                }
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        if (hasBuildSc(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sc"));
                if (content.canFind("ScalaJSModule") || content.canFind("scalajs"))
                    return true;
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        return false;
    }
    
    /// Detect if project uses Scala Native
    static bool usesScalaNative(string projectDir)
    {
        if (hasBuildSbt(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sbt"));
                if (content.canFind("enablePlugins(ScalaNativePlugin)"))
                    return true;
                
                // Check project plugins
                string pluginsPath = buildPath(projectDir, "project", "plugins.sbt");
                if (exists(pluginsPath))
                {
                    auto pluginContent = readText(pluginsPath);
                    if (pluginContent.canFind("sbt-scala-native"))
                        return true;
                }
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        if (hasBuildSc(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sc"));
                if (content.canFind("ScalaNativeModule") || content.canFind("scalanative"))
                    return true;
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        return false;
    }
    
    /// Detect if sbt-assembly plugin is used
    static bool usesSbtAssembly(string projectDir)
    {
        string pluginsPath = buildPath(projectDir, "project", "plugins.sbt");
        if (exists(pluginsPath))
        {
            try
            {
                auto content = readText(pluginsPath);
                return content.canFind("sbt-assembly");
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        return false;
    }
    
    /// Detect if sbt-native-packager is used
    static bool usesSbtNativePackager(string projectDir)
    {
        string pluginsPath = buildPath(projectDir, "project", "plugins.sbt");
        if (exists(pluginsPath))
        {
            try
            {
                auto content = readText(pluginsPath);
                return content.canFind("sbt-native-packager");
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        return false;
    }
    
    /// Detect if project uses GraalVM native-image
    static bool usesGraalNative(string projectDir)
    {
        return usesSbtNativePackager(projectDir);
    }
    
    /// Detect test framework
    static ScalaTestFramework detectTestFramework(string projectDir)
    {
        // Check dependencies in build files
        if (hasBuildSbt(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sbt"));
                if (content.canFind("scalatest"))
                    return ScalaTestFramework.ScalaTest;
                if (content.canFind("specs2"))
                    return ScalaTestFramework.Specs2;
                if (content.canFind("munit"))
                    return ScalaTestFramework.MUnit;
                if (content.canFind("utest"))
                    return ScalaTestFramework.UTest;
                if (content.canFind("scalacheck"))
                    return ScalaTestFramework.ScalaCheck;
                if (content.canFind("zio-test"))
                    return ScalaTestFramework.ZIOTest;
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        if (hasBuildSc(projectDir))
        {
            try
            {
                auto content = readText(buildPath(projectDir, "build.sc"));
                if (content.canFind("scalatest"))
                    return ScalaTestFramework.ScalaTest;
                if (content.canFind("specs2"))
                    return ScalaTestFramework.Specs2;
                if (content.canFind("munit"))
                    return ScalaTestFramework.MUnit;
                if (content.canFind("utest"))
                    return ScalaTestFramework.UTest;
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        // Check for test source files
        string testDir = buildPath(projectDir, "src", "test", "scala");
        if (exists(testDir) && isDir(testDir))
        {
            try
            {
                foreach (entry; dirEntries(testDir, "*.scala", SpanMode.depth))
                {
                    auto content = readText(entry);
                    if (content.canFind("extends AnyFunSuite") || 
                        content.canFind("extends FlatSpec"))
                        return ScalaTestFramework.ScalaTest;
                    if (content.canFind("extends Specification"))
                        return ScalaTestFramework.Specs2;
                    if (content.canFind("extends munit"))
                        return ScalaTestFramework.MUnit;
                }
            }
            catch (Exception e)
            {
                import infrastructure.utils.logging : structuredLog;
                structuredLog.debug_("failed_to_detect_scala_project_info_").field("detail", "Failed to detect Scala project info: " ~ e.msg).emit();
            }
        }
        
        return ScalaTestFramework.Auto;
    }
    
    /// Check if project is multi-module (sbt)
    static bool isMultiModuleProject(string projectDir)
    {
        if (!hasBuildSbt(projectDir))
            return false;
        
        try
        {
            auto content = readText(buildPath(projectDir, "build.sbt"));
            // Look for project definitions
            return content.canFind("lazy val") && 
                   (content.canFind(".dependsOn") || content.canFind(".aggregate"));
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    /// Get scala command path
    static string getScalaCommand()
    {
        string scalaHome = environment.get("SCALA_HOME", "");
        if (!scalaHome.empty)
        {
            version(Windows)
                return buildPath(scalaHome, "bin", "scala.bat");
            else
                return buildPath(scalaHome, "bin", "scala");
        }
        
        return "scala";
    }
    
    /// Get scalac command path
    static string getScalacCommand()
    {
        string scalaHome = environment.get("SCALA_HOME", "");
        if (!scalaHome.empty)
        {
            version(Windows)
                return buildPath(scalaHome, "bin", "scalac.bat");
            else
                return buildPath(scalaHome, "bin", "scalac");
        }
        
        return "scalac";
    }
    
    /// Get sbt version
    static string getSbtVersion()
    {
        try
        {
            auto result = execute(["sbt", "sbtVersion"]);
            if (result.status == 0)
            {
                auto match = matchFirst(result.output, regex(`\[info\]\s+([\d.]+)`));
                if (!match.empty)
                    return match[1];
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_get_version_info_").field("detail", "Failed to get version info: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Get scalac version
    static string getScalacVersion()
    {
        try
        {
            auto result = execute(["scalac", "-version"]);
            if (result.status == 0)
            {
                auto match = matchFirst(result.output, regex(`version\s+([\d.]+)`));
                if (!match.empty)
                    return match[1];
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_get_version_info_").field("detail", "Failed to get version info: " ~ e.msg).emit();
        }
        
        return "";
    }
    
    /// Get Mill version
    static string getMillVersion()
    {
        try
        {
            auto result = execute(["mill", "version"]);
            if (result.status == 0)
            {
                auto match = matchFirst(result.output, regex(`Mill version\s+([\d.]+)`));
                if (!match.empty)
                    return match[1];
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("failed_to_get_version_info_").field("detail", "Failed to get version info: " ~ e.msg).emit();
        }
        
        return "";
    }
}

