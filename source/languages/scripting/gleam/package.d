module languages.scripting.gleam;

/// Gleam Language Support
///
/// Gleam is a friendly language for building type-safe systems that scale.
/// It compiles to Erlang (BEAM VM) and JavaScript.
///
/// Architecture:
/// ```
/// gleam/
/// ├── core/           # Core handler and configuration
/// └── package.d       # Module aggregation
/// ```
///
/// Features:
/// - **Build**: gleam build for compilation
/// - **Test**: gleam test for running tests
/// - **Check**: gleam check for type checking
/// - **Format**: gleam format for code formatting
/// - **Documentation**: gleam docs for generating docs
/// - **Targets**: Erlang (BEAM) and JavaScript targets
/// - **Package Management**: Hex packages via gleam add
///
/// Usage:
/// ```d
/// import languages.scripting.gleam;
/// 
/// auto handler = new GleamHandler();
/// auto result = handler.build(target, config);
/// ```

public import languages.scripting.gleam.core;

