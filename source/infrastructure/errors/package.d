module infrastructure.errors;

/// Modular error handling system for Builder
/// 
/// This package provides a sophisticated, type-safe error handling system with:
/// - Result<T, E> monad for explicit error handling
/// - Hierarchical error types with codes and categories
/// - Error context chains for debugging
/// - Rich formatting with colors and suggestions
/// - Recovery strategies for transient errors
/// 
/// Usage:
///   import errors;
///   
///   // Using Result type
///   BuildResult!string parse(string file) {
///       try {
///           auto content = readText(file);
///           return Ok!(string, BuildError)(content);
///       } catch (Exception e) {
///           return Err!(string, BuildError)(ioError(file, e.msg));
///       }
///   }
///   
///   // Chaining operations
///   auto result = parse("Builderfile")
///       .map(content => parseJson(content))
///       .andThen(json => validate(json));
///   
///   if (result.isErr) {
///       writeln(format(result.unwrapErr()));
///   }

public import infrastructure.errors.handling.result;
public import infrastructure.errors.codes;
public import infrastructure.errors.handling.extensions;
public import infrastructure.errors.types.types;
public import infrastructure.errors.types.context;
public import infrastructure.errors.types.network;
public import infrastructure.errors.formatting.format;
public import infrastructure.errors.handling.recovery;
public import infrastructure.errors.handling.aggregate;
public import infrastructure.errors.helpers;
public import infrastructure.errors.utils.snippets;
public import infrastructure.errors.utils.fuzzy;

// Note: adaptation.adapt is not publicly exported to avoid circular dependency
// with infrastructure.config.schema.schema. Import directly if needed:
// import infrastructure.errors.adaptation.adapt;

