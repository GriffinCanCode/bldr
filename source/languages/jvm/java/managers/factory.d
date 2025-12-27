module languages.jvm.java.managers.factory;

import std.file;
import std.path;
import std.range;
import languages.jvm.java.core.config;
import languages.jvm.java.tooling.detection;
import languages.jvm.java.managers.maven;
import languages.jvm.java.managers.gradle;

/// Factory for detecting and selecting build tools
class BuildToolFactory
{
    /// Auto-detect build tool from project structure
    static JavaBuildTool detectBuildTool(string projectDir)
    {
        // Check for Maven
        if (JavaToolDetection.hasPomXml(projectDir))
            return JavaBuildTool.Maven;
        
        // Check for Gradle
        if (JavaToolDetection.hasBuildGradle(projectDir))
            return JavaBuildTool.Gradle;
        
        // Check for Ant (build.xml)
        if (exists(buildPath(projectDir, "build.xml")))
            return JavaBuildTool.Ant;
        
        // Default to direct compilation
        return JavaBuildTool.Direct;
    }
    
    /// Check if build tool wrapper exists
    static bool hasWrapper(JavaBuildTool tool, string projectDir)
    {
        final switch (tool)
        {
            case JavaBuildTool.Maven:
                return JavaToolDetection.hasMavenWrapper(projectDir);
            case JavaBuildTool.Gradle:
                return JavaToolDetection.hasGradleWrapper(projectDir);
            case JavaBuildTool.Auto:
            case JavaBuildTool.Direct:
            case JavaBuildTool.Ant:
            case JavaBuildTool.None:
                return false;
        }
    }
    
    /// Determine if wrapper should be used
    static bool shouldUseWrapper(JavaBuildTool tool, string projectDir)
    {
        // Prefer wrapper if available (better reproducibility)
        return hasWrapper(tool, projectDir);
    }
    
    /// Get Maven metadata
    static MavenMetadata getMavenMetadata(string projectDir)
    {
        string pomPath = buildPath(projectDir, "pom.xml");
        if (exists(pomPath))
            return MavenMetadata.fromFile(pomPath);
        
        return MavenMetadata.init;
    }
    
    /// Get Gradle metadata
    static GradleMetadata getGradleMetadata(string projectDir)
    {
        string buildFile = buildPath(projectDir, "build.gradle.kts");
        if (!exists(buildFile))
            buildFile = buildPath(projectDir, "build.gradle");
        
        if (exists(buildFile))
            return GradleMetadata.fromFile(buildFile);
        
        return GradleMetadata.init;
    }
    
    /// Detect if project is multi-module
    static bool isMultiModule(JavaBuildTool tool, string projectDir)
    {
        final switch (tool)
        {
            case JavaBuildTool.Maven:
                auto meta = getMavenMetadata(projectDir);
                return meta.isMultiModule();
            
            case JavaBuildTool.Gradle:
                return JavaToolDetection.hasSettingsGradle(projectDir);
            
            case JavaBuildTool.Auto:
                // Try both
                if (JavaToolDetection.hasPomXml(projectDir))
                {
                    auto meta = getMavenMetadata(projectDir);
                    return meta.isMultiModule();
                }
                return JavaToolDetection.hasSettingsGradle(projectDir);
            
            case JavaBuildTool.Direct:
            case JavaBuildTool.Ant:
            case JavaBuildTool.None:
                return false;
        }
    }
    
    /// Enhance Java config from project structure
    static void enhanceConfigFromProject(ref JavaConfig config, string projectDir)
    {
        // Auto-detect build tool if set to Auto
        if (config.buildTool == JavaBuildTool.Auto)
        {
            config.buildTool = detectBuildTool(projectDir);
        }
        
        // Extract version information from build files
        final switch (config.buildTool)
        {
            case JavaBuildTool.Maven:
                auto meta = getMavenMetadata(projectDir);
                if (config.sourceVersion.major == 0)
                {
                    string javaVer = meta.getJavaVersion();
                    config.sourceVersion = JavaVersion.parse(javaVer);
                    config.targetVersion = config.sourceVersion;
                }
                
                // Detect main class
                if (config.packaging.mainClass.empty)
                    config.packaging.mainClass = meta.getMainClass();
                
                // Detect Spring Boot
                if (meta.usesSpringBoot())
                {
                    // Spring Boot projects typically use fat JARs
                    if (config.mode == JavaBuildMode.JAR)
                        config.mode = JavaBuildMode.FatJAR;
                }
                break;
            
            case JavaBuildTool.Gradle:
                auto meta = getGradleMetadata(projectDir);
                if (config.sourceVersion.major == 0)
                {
                    string javaVer = meta.getJavaVersion();
                    config.sourceVersion = JavaVersion.parse(javaVer);
                    config.targetVersion = config.sourceVersion;
                }
                
                // Detect Spring Boot
                if (meta.usesSpringBoot())
                {
                    if (config.mode == JavaBuildMode.JAR)
                        config.mode = JavaBuildMode.FatJAR;
                }
                
                // Detect Android
                if (meta.isAndroid())
                {
                    // Android projects need special handling
                    // Note: Android packaging would need additional config
                }
                break;
            
            case JavaBuildTool.Auto:
            case JavaBuildTool.Direct:
            case JavaBuildTool.Ant:
            case JavaBuildTool.None:
                // Use defaults
                if (config.sourceVersion.major == 0)
                {
                    config.sourceVersion = JavaVersion(11);
                    config.targetVersion = JavaVersion(11);
                }
                break;
        }
        
        // Detect module system usage
        if (config.modules.moduleName.empty && JavaToolDetection.hasModuleInfo(projectDir))
        {
            config.modules.enabled = true;
            // Parse module name from module-info.java
            config.modules.moduleName = detectModuleName(projectDir);
        }
        
        // Detect annotation processors
        if (!config.processors.enabled)
        {
            if (JavaToolDetection.usesLombok(projectDir))
            {
                config.processors.enabled = true;
                config.processors.lombok = true;
            }
        }
    }
    
    /// Detect module name from module-info.java
    private static string detectModuleName(string projectDir)
    {
        import std.file : dirEntries, SpanMode;
        import std.regex;
        
        try
        {
            foreach (entry; dirEntries(projectDir, "module-info.java", SpanMode.depth))
            {
                string content = readText(entry);
                auto match = matchFirst(content, regex(`module\s+([\w.]+)`));
                if (!match.empty)
                    return match[1];
            }
        }
        catch (Exception e)
        {
            import infrastructure.utils.logging : structuredLog;
            structuredLog.debug_("module_name_extraction_failed").field("error", e.msg).emit();
        }
        
        return "";
    }
}

