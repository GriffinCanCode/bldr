module infrastructure.analysis.manifests.types;

import infrastructure.config.schema.schema : TargetType, TargetLanguage;
import infrastructure.errors;

/// Parsed manifest information
struct ManifestInfo
{
    string name;              /// Package/project name
    string version_;          /// Version string
    string[] entryPoints;     /// Main entry points
    string[] sources;         /// Source file patterns
    string[] tests;           /// Test file patterns
    Dependency[] dependencies;/// Direct dependencies
    Script[string] scripts;   /// Build/run scripts
    TargetLanguage language;  /// Detected language
    TargetType suggestedType; /// Suggested target type
    string[string] metadata;  /// Additional metadata
}

/// Dependency information
struct Dependency
{
    string name;              /// Dependency name
    string version_;          /// Version/version range
    DependencyType type;      /// Dependency type
    bool optional;            /// Whether optional
}

/// Dependency types
enum DependencyType
{
    Runtime,    /// Runtime dependency
    Development,/// Dev dependency
    Peer,       /// Peer dependency
    Build,      /// Build-time only
    Optional    /// Optional dependency
}

/// Script information
struct Script
{
    string name;              /// Script name
    string command;           /// Command to run
    TargetType suggestedType; /// Suggested Builder target type
}

/// Manifest parser interface
interface IManifestParser
{
    /// Parse manifest file
    BuildResult!ManifestInfo parse(string filePath) @system;
    
    /// Check if parser can handle this file
    bool canParse(string filePath) const @safe;
    
    /// Get parser name
    string name() const pure nothrow @safe;
}

