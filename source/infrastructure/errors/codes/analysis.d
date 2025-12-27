module infrastructure.errors.codes.analysis;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Dependency analysis error codes (3000-3999)
/// Covers import resolution, dependency cycles, and static analysis
enum Analysis : int
{
    /// Generic analysis failure
    Failed = 3000,
    /// Failed to resolve import/include
    ImportResolutionFailed = 3001,
    /// Circular dependency detected
    CircularDependency = 3002,
    /// Required dependency not found
    MissingDependency = 3003,
    /// Invalid import syntax or path
    InvalidImport = 3004,
    /// Multiple definitions of same symbol
    DuplicateDefinition = 3005,
    /// Reference to undefined symbol
    UndefinedReference = 3006,
    /// Type mismatch in dependency
    TypeMismatch = 3007,
    /// Version constraint cannot be satisfied
    VersionConflict = 3008,
    /// Ambiguous import resolution
    AmbiguousImport = 3009,
    /// Private symbol accessed from outside
    PrivateAccess = 3010,
    /// Deprecated dependency used
    DeprecatedDependency = 3011,
    /// Package not found in registry
    PackageNotFound = 3012,
    /// Module not found
    ModuleNotFound = 3013,
    /// Symbol not exported
    SymbolNotExported = 3014,
    /// Analysis timeout
    AnalysisTimeout = 3015,
    /// Incremental analysis failed
    IncrementalFailed = 3016,
    /// AST parse error
    AstParseError = 3017,
}

/// Namespace for analysis error utilities
struct AnalysisErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Analysis; }
    
    static Recoverability recoverabilityOf(Analysis code) pure nothrow @nogc
    {
        switch (code)
        {
            case Analysis.AnalysisTimeout:
            case Analysis.IncrementalFailed:
                return Recoverability.Transient;
            default:
                return Recoverability.User;
        }
    }
    
    static string messageOf(Analysis code) pure nothrow @safe
    {
        final switch (code)
        {
            case Analysis.Failed:               return "Dependency analysis failed";
            case Analysis.ImportResolutionFailed: return "Failed to resolve import";
            case Analysis.CircularDependency:   return "Circular dependency detected";
            case Analysis.MissingDependency:    return "Dependency not found";
            case Analysis.InvalidImport:        return "Invalid import statement";
            case Analysis.DuplicateDefinition:  return "Duplicate definition";
            case Analysis.UndefinedReference:   return "Undefined reference";
            case Analysis.TypeMismatch:         return "Type mismatch";
            case Analysis.VersionConflict:      return "Version conflict";
            case Analysis.AmbiguousImport:      return "Ambiguous import";
            case Analysis.PrivateAccess:        return "Private symbol access";
            case Analysis.DeprecatedDependency: return "Deprecated dependency";
            case Analysis.PackageNotFound:      return "Package not found";
            case Analysis.ModuleNotFound:       return "Module not found";
            case Analysis.SymbolNotExported:    return "Symbol not exported";
            case Analysis.AnalysisTimeout:      return "Analysis timed out";
            case Analysis.IncrementalFailed:    return "Incremental analysis failed";
            case Analysis.AstParseError:        return "AST parse error";
        }
    }
}

