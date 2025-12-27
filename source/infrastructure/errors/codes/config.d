module infrastructure.errors.codes.config;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Configuration and validation error codes (16000-16999)
/// Covers workspace configuration, target definitions, and schema validation
enum Config : int
{
    /// Generic config error
    Error = 16000,
    /// Invalid workspace configuration
    InvalidWorkspace = 16001,
    /// Invalid target configuration
    InvalidTarget = 16002,
    /// Invalid input value
    InvalidInput = 16003,
    /// Schema validation failed
    SchemaValidationFailed = 16004,
    /// Deprecated field used
    DeprecatedField = 16005,
    /// Required field missing
    RequiredFieldMissing = 16006,
    /// Duplicate target name
    DuplicateTarget = 16007,
    /// Configuration conflict
    Conflict = 16008,
    /// Invalid environment variable
    InvalidEnvVar = 16009,
    /// Invalid platform specification
    InvalidPlatform = 16010,
    /// Invalid constraint expression
    InvalidConstraint = 16011,
    /// Circular workspace reference
    CircularWorkspace = 16012,
    /// Workspace not found
    WorkspaceNotFound = 16013,
    /// Builderspace not found
    BuilderspaceNotFound = 16014,
    /// Invalid toolchain config
    InvalidToolchain = 16015,
    /// Invalid output path
    InvalidOutputPath = 16016,
    /// Invalid input path
    InvalidInputPath = 16017,
    /// Invalid dependency specification
    InvalidDependency = 16018,
    /// Unknown target type
    UnknownTargetType = 16019,
    /// Feature flag invalid
    InvalidFeatureFlag = 16020,
    /// Profile not found
    ProfileNotFound = 16021,
    /// Override conflict
    OverrideConflict = 16022,
    /// Invalid label syntax
    InvalidLabel = 16023,
    /// Invalid visibility
    InvalidVisibility = 16024,
}

/// Namespace for config error utilities
struct ConfigErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Config; }
    
    static Recoverability recoverabilityOf(Config) pure nothrow @nogc
    {
        return Recoverability.User; // All config errors are user-fixable
    }
    
    static string messageOf(Config code) pure nothrow @safe
    {
        final switch (code)
        {
            case Config.Error:                  return "Configuration error";
            case Config.InvalidWorkspace:       return "Invalid workspace configuration";
            case Config.InvalidTarget:          return "Invalid target configuration";
            case Config.InvalidInput:           return "Invalid input";
            case Config.SchemaValidationFailed: return "Schema validation failed";
            case Config.DeprecatedField:        return "Deprecated field used";
            case Config.RequiredFieldMissing:   return "Required field missing";
            case Config.DuplicateTarget:        return "Duplicate target name";
            case Config.Conflict:               return "Configuration conflict";
            case Config.InvalidEnvVar:          return "Invalid environment variable";
            case Config.InvalidPlatform:        return "Invalid platform specification";
            case Config.InvalidConstraint:      return "Invalid constraint expression";
            case Config.CircularWorkspace:      return "Circular workspace reference";
            case Config.WorkspaceNotFound:      return "Workspace not found";
            case Config.BuilderspaceNotFound:   return "Builderspace not found";
            case Config.InvalidToolchain:       return "Invalid toolchain configuration";
            case Config.InvalidOutputPath:      return "Invalid output path";
            case Config.InvalidInputPath:       return "Invalid input path";
            case Config.InvalidDependency:      return "Invalid dependency specification";
            case Config.UnknownTargetType:      return "Unknown target type";
            case Config.InvalidFeatureFlag:     return "Invalid feature flag";
            case Config.ProfileNotFound:        return "Profile not found";
            case Config.OverrideConflict:       return "Override conflict";
            case Config.InvalidLabel:           return "Invalid label syntax";
            case Config.InvalidVisibility:      return "Invalid visibility";
        }
    }
}

