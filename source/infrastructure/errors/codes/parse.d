module infrastructure.errors.codes.parse;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Parse and syntax error codes (2000-2999)
/// Covers configuration file parsing, JSON/TOML/YAML, and DSL syntax
enum Parse : int
{
    /// Generic parse failure
    Failed = 2000,
    /// Invalid JSON syntax
    InvalidJson = 2001,
    /// Invalid Builderfile format
    InvalidBuildFile = 2002,
    /// Required field missing in config
    MissingField = 2003,
    /// Field value doesn't match expected type/format
    InvalidFieldValue = 2004,
    /// Invalid glob pattern syntax
    InvalidGlob = 2005,
    /// Generic invalid configuration
    InvalidConfiguration = 2006,
    /// Invalid TOML syntax
    InvalidToml = 2007,
    /// Invalid YAML syntax  
    InvalidYaml = 2008,
    /// Unexpected token
    UnexpectedToken = 2009,
    /// Unterminated string literal
    UnterminatedString = 2010,
    /// Invalid escape sequence
    InvalidEscape = 2011,
    /// Duplicate key in map/object
    DuplicateKey = 2012,
    /// Value out of range
    ValueOutOfRange = 2013,
    /// Invalid number format
    InvalidNumber = 2014,
    /// Invalid date/time format
    InvalidDateTime = 2015,
    /// Unknown field in strict mode
    UnknownField = 2016,
    /// Invalid regex pattern
    InvalidRegex = 2017,
    /// Invalid path format
    InvalidPath = 2018,
    /// Invalid URL format
    InvalidUrl = 2019,
    /// Invalid version string
    InvalidVersion = 2020,
    /// Encoding error (non-UTF8)
    EncodingError = 2021,
}

/// Namespace for parse error utilities
struct ParseErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Parse; }
    
    static Recoverability recoverabilityOf(Parse) pure nothrow @nogc
    {
        return Recoverability.User; // All parse errors are user-fixable
    }
    
    static string messageOf(Parse code) pure nothrow @safe
    {
        final switch (code)
        {
            case Parse.Failed:            return "Failed to parse configuration";
            case Parse.InvalidJson:       return "Invalid JSON syntax";
            case Parse.InvalidBuildFile:  return "Invalid Builderfile";
            case Parse.MissingField:      return "Required field missing";
            case Parse.InvalidFieldValue: return "Invalid field value";
            case Parse.InvalidGlob:       return "Invalid glob pattern";
            case Parse.InvalidConfiguration: return "Invalid configuration";
            case Parse.InvalidToml:       return "Invalid TOML syntax";
            case Parse.InvalidYaml:       return "Invalid YAML syntax";
            case Parse.UnexpectedToken:   return "Unexpected token";
            case Parse.UnterminatedString: return "Unterminated string literal";
            case Parse.InvalidEscape:     return "Invalid escape sequence";
            case Parse.DuplicateKey:      return "Duplicate key";
            case Parse.ValueOutOfRange:   return "Value out of range";
            case Parse.InvalidNumber:     return "Invalid number format";
            case Parse.InvalidDateTime:   return "Invalid date/time format";
            case Parse.UnknownField:      return "Unknown field";
            case Parse.InvalidRegex:      return "Invalid regex pattern";
            case Parse.InvalidPath:       return "Invalid path format";
            case Parse.InvalidUrl:        return "Invalid URL format";
            case Parse.InvalidVersion:    return "Invalid version string";
            case Parse.EncodingError:     return "Encoding error";
        }
    }
}

