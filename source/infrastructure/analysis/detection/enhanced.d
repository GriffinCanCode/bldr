module infrastructure.analysis.detection.enhanced;

import std.path : buildPath, baseName;
import std.file : exists;
import std.algorithm : canFind;
import std.range : empty;
import infrastructure.analysis.detection.detector;
import infrastructure.analysis.manifests;
import infrastructure.config.schema.schema : TargetLanguage;
import infrastructure.utils.logging;

/// Enhanced project detector that uses manifest parsing
class EnhancedProjectDetector
{
    private ProjectDetector baseDetector;
    private string projectDir;
    
    this(string projectDir)
    {
        this.projectDir = projectDir;
        this.baseDetector = new ProjectDetector(projectDir);
    }
    
    /// Detect project with enhanced manifest information
    EnhancedProjectMetadata detectEnhanced()
    {
        // Run base detection
        auto baseMetadata = baseDetector.detect();
        
        EnhancedProjectMetadata enhanced;
        enhanced.base = baseMetadata;
        
        // Try to parse manifests for each detected language
        foreach (langInfo; baseMetadata.languages)
        {
            if (!langInfo.manifestFiles.empty)
            {
                // Parse first manifest file
                auto manifestPath = langInfo.manifestFiles[0];
                auto parser = createParserForFile(manifestPath);
                
                if (parser !is null)
                {
                    auto result = parser.parse(manifestPath);
                    if (result.isOk)
                    {
                        enhanced.manifestInfo[langInfo.language] = result.unwrap();
                        structuredLog.debug_("parsed_manifest_").field("detail", "Parsed manifest: " ~ manifestPath).emit();
                    }
                }
            }
        }
        
        return enhanced;
    }
    
    private IManifestParser createParserForFile(string filePath)
    {
        string name = baseName(filePath);
        
        if (name == "package.json")
            return new NpmManifestParser();
        else if (name == "Cargo.toml")
            return new CargoManifestParser();
        else if (name == "pyproject.toml" || name == "setup.py" || name.canFind("requirements"))
            return new PythonManifestParser();
        else if (name == "go.mod")
            return new GoManifestParser();
        else if (name == "pom.xml")
            return new MavenManifestParser();
        else if (name == "composer.json")
            return new ComposerManifestParser();
        
        return null;
    }
}

/// Enhanced metadata with manifest information
struct EnhancedProjectMetadata
{
    ProjectMetadata base;               /// Base metadata from file scanning
    ManifestInfo[TargetLanguage] manifestInfo; /// Parsed manifest data per language
}

