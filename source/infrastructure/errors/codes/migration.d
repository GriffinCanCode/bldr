module infrastructure.errors.codes.migration;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Migration error codes (17000-17999)
/// Covers migration from other build systems
enum Migration : int
{
    /// Generic migration failure
    Failed = 17000,
    /// Source build system not detected
    SourceNotDetected = 17001,
    /// Unsupported source format
    UnsupportedFormat = 17002,
    /// Feature not migratable
    FeatureNotMigratable = 17003,
    /// Partial migration
    PartialMigration = 17004,
    /// Target conflict during migration
    TargetConflict = 17005,
    /// Dependency migration failed
    DependencyMigrationFailed = 17006,
    /// Script migration failed
    ScriptMigrationFailed = 17007,
    /// Custom rule migration failed
    CustomRuleFailed = 17008,
    /// Migration rollback failed
    RollbackFailed = 17009,
    /// Migration validation failed
    ValidationFailed = 17010,
    /// Legacy format deprecated
    LegacyFormatDeprecated = 17011,
    /// Migration path not found
    PathNotFound = 17012,
    /// Migration interrupted
    Interrupted = 17013,
    /// Complex macro migration
    ComplexMacroMigration = 17014,
    /// Generated file conflict
    GeneratedFileConflict = 17015,
}

/// Namespace for migration error utilities
struct MigrationErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Migration; }
    
    static Recoverability recoverabilityOf(Migration code) pure nothrow @nogc
    {
        switch (code)
        {
            case Migration.Interrupted:
            case Migration.RollbackFailed:
                return Recoverability.Transient;
            case Migration.SourceNotDetected:
            case Migration.UnsupportedFormat:
            case Migration.FeatureNotMigratable:
            case Migration.TargetConflict:
            case Migration.PathNotFound:
            case Migration.LegacyFormatDeprecated:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Migration code) pure nothrow @safe
    {
        final switch (code)
        {
            case Migration.Failed:                   return "Migration failed";
            case Migration.SourceNotDetected:        return "Source build system not detected";
            case Migration.UnsupportedFormat:        return "Unsupported source format";
            case Migration.FeatureNotMigratable:     return "Feature cannot be migrated";
            case Migration.PartialMigration:         return "Partial migration completed";
            case Migration.TargetConflict:           return "Target conflict during migration";
            case Migration.DependencyMigrationFailed: return "Dependency migration failed";
            case Migration.ScriptMigrationFailed:    return "Script migration failed";
            case Migration.CustomRuleFailed:         return "Custom rule migration failed";
            case Migration.RollbackFailed:           return "Migration rollback failed";
            case Migration.ValidationFailed:         return "Migration validation failed";
            case Migration.LegacyFormatDeprecated:   return "Legacy format deprecated";
            case Migration.PathNotFound:             return "Migration path not found";
            case Migration.Interrupted:              return "Migration interrupted";
            case Migration.ComplexMacroMigration:    return "Complex macro requires manual migration";
            case Migration.GeneratedFileConflict:    return "Generated file conflict";
        }
    }
}

