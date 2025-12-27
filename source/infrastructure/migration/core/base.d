module infrastructure.migration.core.base;

import std.file : readText, exists;
import std.path : baseName;
import infrastructure.errors;
import infrastructure.migration.core.common;

/// Interface for build system migrators
/// Each build system implements this to provide migration capabilities
interface IMigrator
{
    /// Get the name of the source build system
    string systemName() const pure nothrow @safe;
    
    /// Get common file names for this build system
    string[] defaultFileNames() const pure nothrow @safe;
    
    /// Check if a file is likely from this build system
    bool canMigrate(string filePath) const @safe;
    
    /// Parse and migrate a build file
    BuildResult!MigrationResult migrate(string inputPath) @system;
    
    /// Get human-readable description
    string description() const pure nothrow @safe;
    
    /// Get list of supported features
    string[] supportedFeatures() const pure nothrow @safe;
    
    /// Get list of known limitations
    string[] limitations() const pure nothrow @safe;
}

/// Base class providing common functionality for migrators
abstract class BaseMigrator : IMigrator
{
    /// Helper to read and validate input file
    protected BuildResult!string readInputFile(string filePath) @system
    {
        import infrastructure.errors : fileReadError;
        
        if (!exists(filePath))
        {
            auto error = fileReadError(filePath, "File does not exist", 
                "reading build file for migration");
            error.addSuggestion("Check the file path is correct");
            error.addSuggestion("Ensure the file exists in the specified location");
            return BuildResult!string.err(error);
        }
        
        try
        {
            string content = readText(filePath);
            return BuildResult!string.ok(content);
        }
        catch (Exception e)
        {
            auto error = fileReadError(filePath, e.msg, "reading build file for migration");
            return BuildResult!string.err(error);
        }
    }
    
    /// Helper to create migration error
    protected BuildError migrationError(string message, string filePath, string context = "") @system
    {
        import infrastructure.errors : ErrorCode;
        
        auto builder = Errors.parse(filePath, message, Migration.Failed);
        if (context.length > 0)
            builder = builder.withContext("migration_context", context);
        return builder
            .withSuggestion("Check the input file syntax is valid for " ~ systemName())
            .withSuggestion("Review migration limitations using 'bldr migrate --help'")
            .withLocation(__FILE__, __LINE__)
            .build();
    }
    
    /// Helper to create result with warnings
    protected BuildResult!MigrationResult createResult(
        MigrationTarget[] targets,
        MigrationWarning[] warnings = [],
        string[string] globalConfig = null
    ) @system
    {
        MigrationResult result;
        result.targets = targets;
        result.warnings = warnings;
        result.globalConfig = globalConfig;
        result.success = !result.hasErrors();
        return BuildResult!MigrationResult.ok(result);
    }
}

/// Factory for creating migrators
struct MigratorFactory
{
    /// Create migrator by system name
    static IMigrator create(string systemName) @system
    {
        import std.string : toLower;
        import infrastructure.migration.registry.registry : getMigratorRegistry;
        
        auto registry = getMigratorRegistry();
        return registry.create(systemName.toLower());
    }
    
    /// Get all available migrator names
    static string[] availableSystems() @system
    {
        import infrastructure.migration.registry.registry : getMigratorRegistry;
        
        auto registry = getMigratorRegistry();
        return registry.availableSystems();
    }
    
    /// Auto-detect build system from file
    static IMigrator autoDetect(string filePath) @system
    {
        import std.path : baseName;
        import infrastructure.migration.registry.registry : getMigratorRegistry;
        
        auto registry = getMigratorRegistry();
        auto fileName = baseName(filePath);
        
        foreach (migrator; registry.allMigrators())
        {
            if (migrator.canMigrate(filePath))
                return migrator;
        }
        
        return null;
    }
}

