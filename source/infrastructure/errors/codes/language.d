module infrastructure.errors.codes.language;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Language handler error codes (7000-7999)
/// Covers compilation, syntax, and language-specific tooling
enum Language : int
{
    /// Syntax error in source code
    SyntaxError = 7000,
    /// Compilation failed
    CompilationFailed = 7001,
    /// Validation failed
    ValidationFailed = 7002,
    /// Language not supported
    UnsupportedLanguage = 7003,
    /// Compiler not found
    MissingCompiler = 7004,
    /// Macro expansion failed
    MacroExpansionFailed = 7005,
    /// Failed to load macro
    MacroLoadFailed = 7006,
    /// Linker error
    LinkerError = 7007,
    /// Semantic error
    SemanticError = 7008,
    /// Type error
    TypeError = 7009,
    /// Runtime error during codegen
    CodegenError = 7010,
    /// Missing include/import path
    MissingIncludePath = 7011,
    /// Preprocessor error
    PreprocessorError = 7012,
    /// Template instantiation error
    TemplateError = 7013,
    /// ABI compatibility error
    ABIError = 7014,
    /// Feature not supported by language version
    FeatureNotSupported = 7015,
    /// Deprecated language feature
    DeprecatedFeature = 7016,
    /// Standard library not found
    StdlibNotFound = 7017,
    /// Language plugin error
    LanguagePluginError = 7018,
    /// Code formatting failed
    FormatError = 7019,
    /// Lint check failed
    LintError = 7020,
    /// Static analysis error
    StaticAnalysisError = 7021,
}

/// Namespace for language error utilities
struct LanguageErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Language; }
    
    static Recoverability recoverabilityOf(Language code) pure nothrow @nogc
    {
        switch (code)
        {
            case Language.SyntaxError:
            case Language.SemanticError:
            case Language.TypeError:
            case Language.UnsupportedLanguage:
            case Language.MissingCompiler:
            case Language.MissingIncludePath:
            case Language.DeprecatedFeature:
            case Language.LintError:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Language code) pure nothrow @safe
    {
        final switch (code)
        {
            case Language.SyntaxError:         return "Syntax error";
            case Language.CompilationFailed:   return "Compilation failed";
            case Language.ValidationFailed:    return "Validation failed";
            case Language.UnsupportedLanguage: return "Unsupported language";
            case Language.MissingCompiler:     return "Compiler not found";
            case Language.MacroExpansionFailed: return "Macro expansion failed";
            case Language.MacroLoadFailed:     return "Failed to load macro";
            case Language.LinkerError:         return "Linker error";
            case Language.SemanticError:       return "Semantic error";
            case Language.TypeError:           return "Type error";
            case Language.CodegenError:        return "Code generation error";
            case Language.MissingIncludePath:  return "Missing include path";
            case Language.PreprocessorError:   return "Preprocessor error";
            case Language.TemplateError:       return "Template instantiation error";
            case Language.ABIError:            return "ABI compatibility error";
            case Language.FeatureNotSupported: return "Feature not supported";
            case Language.DeprecatedFeature:   return "Deprecated feature used";
            case Language.StdlibNotFound:      return "Standard library not found";
            case Language.LanguagePluginError: return "Language plugin error";
            case Language.FormatError:         return "Code formatting failed";
            case Language.LintError:           return "Lint check failed";
            case Language.StaticAnalysisError: return "Static analysis error";
        }
    }
}

