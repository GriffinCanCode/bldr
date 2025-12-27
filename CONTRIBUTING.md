# Contributing to Builder

Thank you for your interest in contributing to Builder! This document provides guidelines and instructions for contributing.

## 📋 Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Documentation](#documentation)
- [Pull Request Process](#pull-request-process)
- [Language Support](#language-support)

## 🤝 Code of Conduct

This project adheres to a code of conduct that all contributors are expected to follow:

- Be respectful and inclusive
- Welcome newcomers and help them get started
- Focus on what is best for the community
- Show empathy towards other community members
- Accept constructive criticism gracefully

## 🚀 Getting Started

1. **Fork the repository**
   ```bash
   git clone https://github.com/GriffinCanCode/bldr.git
   cd bldr
   ```

2. **Build the project**
   ```bash
   make build
   ```

3. **Run tests**
   ```bash
   make test
   ```

4. **Generate documentation**
   ```bash
   make docs
   ```

## 🛠️ Development Setup

### Prerequisites

- **D Compiler**: DMD, LDC, or GDC (DMD 2.100+ recommended)
- **DUB**: D package manager
- **Make**: Build automation
- **Python 3**: For tooling and documentation generation

### Building

```bash
# Debug build
make debug

# Release build
make build

# With Thread Sanitizer (requires LDC)
make tsan
```

### Testing

```bash
# Run all tests
make test

# Run tests with coverage
make test-coverage

# Run tests in parallel
make test-parallel

# Run Thread Sanitizer tests
make test-tsan
```

## 📁 Project Structure

```
Builder/
├── source/              # Main source code
│   ├── analysis/       # Code analysis and dependency detection
│   ├── cli/            # Command-line interface
│   ├── config/         # Configuration parsing (Builderfile DSL)
│   ├── core/           # Core build system (graph, execution, caching)
│   ├── errors/         # Error handling and Result types
│   ├── languages/      # Language-specific handlers
│   │   ├── compiled/   # C++, Rust, D, Zig, Nim, Swift, etc.
│   │   ├── dotnet/     # C#, F#
│   │   ├── jvm/        # Java, Kotlin, Scala
│   │   ├── scripting/  # Python, Ruby, Go, Elixir, PHP, R, Lua
│   │   └── web/        # JavaScript, TypeScript
│   ├── tools/          # VS Code extension and tooling
│   └── utils/          # Utilities (SIMD, crypto, concurrency, etc.)
├── tests/              # Test suite
│   ├── unit/           # Unit tests
│   ├── integration/    # Integration tests
│   └── bench/          # Benchmarks
├── docs/               # Documentation
│   ├── api/            # Auto-generated API docs
│   ├── architecture/   # Architecture documentation
│   ├── development/    # Development guides
│   ├── security/       # Security documentation
│   └── user-guides/    # User guides and examples
├── examples/           # Example projects in various languages
└── tools/              # Build and development tools
```

## 💻 Coding Standards

### D Language Guidelines

1. **Memory Safety**
   ```d
   // Prefer @safe code
   @safe void myFunction() { ... }
   
   // Document @trusted blocks with detailed safety comments
   /// Safety: This function is @trusted because:
   /// 1. Reason one
   /// 2. Reason two
   /// 3. What could go wrong and why it won't
   @trusted void criticalFunction() { ... }
   ```

2. **Error Handling**
   ```d
   // Use Result<T, E> instead of exceptions
   Result!(BuildOutput, BuildError) build(Target target) {
       if (!target.isValid())
           return Result!(BuildOutput, BuildError).err(
               BuildError("Invalid target")
           );
       
       return Result!(BuildOutput, BuildError).ok(output);
   }
   ```

3. **Documentation**
   ```d
   /// Brief description of the function
   /// 
   /// Detailed explanation of what the function does, including
   /// any important behavior, caveats, or performance considerations.
   /// 
   /// Params:
   ///     param1 = Description of first parameter
   ///     param2 = Description of second parameter
   /// 
   /// Returns: Description of return value
   /// 
   /// Throws: Only if using exceptions (prefer Result types)
   /// 
   /// Examples:
   /// ---
   /// auto result = myFunction(42, "hello");
   /// assert(result.isOk());
   /// ---
   ReturnType myFunction(int param1, string param2) {
       // Implementation
   }
   ```

4. **Naming Conventions**
   - **Types**: `PascalCase` (e.g., `BuildTarget`, `LanguageHandler`)
   - **Functions/Variables**: `camelCase` (e.g., `buildTarget`, `parseConfig`)
   - **Constants**: `PascalCase` or `UPPER_SNAKE_CASE` for global constants
   - **Private Members**: Prefix with `_` (e.g., `_privateField`)

5. **Code Style**
   ```d
   // Use 4 spaces for indentation (no tabs)
   // Opening braces on same line
   void function() {
       if (condition) {
           doSomething();
       }
   }
   
   // Use trailing commas in multi-line arrays
   string[] items = [
       "first",
       "second",
       "third",
   ];
   ```

### Performance Guidelines

1. **SIMD Operations**: Use SIMD utilities in `utils/simd/` for performance-critical code
2. **Parallelization**: Use `ParallelExecutor` from `utils/concurrency/` for parallel tasks
3. **Caching**: Utilize `BuildCache` for expensive operations
4. **Memory**: Minimize allocations in hot paths

### Security Guidelines

1. **Input Validation**: Always validate user input and file paths
2. **Sandboxing**: Use `SafeExecutor` for running external commands
3. **Path Traversal**: Use `validatePath()` from `utils.security.validation`
4. **Temporary Files**: Use `TempDir` for secure temporary file handling

## 🧪 Testing

### Writing Tests

```d
/// Test description
unittest {
    // Arrange
    auto input = createTestInput();
    
    // Act
    auto result = functionUnderTest(input);
    
    // Assert
    assert(result.isOk());
    assert(result.unwrap() == expectedValue);
}
```

### Test Organization

- Place unit tests in the same file as the code being tested
- Place integration tests in `tests/integration/`
- Use descriptive test names
- Test both success and failure paths
- Include edge cases

### Running Specific Tests

```bash
# Run tests for a specific module
dub test -- --filter="module_name"

# Run benchmarks
make bench
```

## 📚 Documentation

### API Documentation

We use DDoc for API documentation:

```d
/// Summary of the class/function/module
/// 
/// Detailed description here. Can be multiple paragraphs.
/// 
/// Params:
///     name = Parameter description
/// 
/// Returns: Description of return value
```

Generate documentation:

```bash
make docs          # Generate API documentation
make docs-open     # Generate and open in browser
make docs-serve    # Serve on localhost:8000
```

### User Documentation

User-facing documentation goes in `docs/user-guides/`:

- Clear examples
- Step-by-step instructions
- Common pitfalls and solutions
- Links to related documentation

### Architecture Documentation

Technical architecture documentation goes in `docs/architecture/`:

- System design decisions
- Component interactions
- Performance characteristics
- Security considerations

## 🔄 Pull Request Process

1. **Create a feature branch**
   ```bash
   git checkout -b feature/my-awesome-feature
   ```

2. **Make your changes**
   - Follow coding standards
   - Add tests for new functionality
   - Update documentation
   - Document `@trusted` blocks with safety comments

3. **Run tests and checks**
   ```bash
   make test           # Run all tests
   make fmt            # Format code
   make docs           # Verify documentation builds
   ```

4. **Commit with clear messages**
   ```bash
   git commit -m "feat: Add awesome new feature
   
   - Detailed explanation of what changed
   - Why it changed
   - Any breaking changes"
   ```

   Use conventional commit prefixes:
   - `feat:` New feature
   - `fix:` Bug fix
   - `docs:` Documentation only
   - `test:` Adding/updating tests
   - `refactor:` Code refactoring
   - `perf:` Performance improvement
   - `chore:` Maintenance tasks

5. **Push and create PR**
   ```bash
   git push origin feature/my-awesome-feature
   ```

   In your PR description:
   - Describe what changed and why
   - Link to related issues
   - Include screenshots for UI changes
   - List any breaking changes
   - Mention if documentation was updated

6. **Code Review**
   - Address feedback promptly
   - Keep discussions constructive
   - Update your branch with main if needed

7. **Merge**
   - Squash commits if requested
   - Ensure CI passes
   - Wait for maintainer approval

## 🌍 Language Support

### Adding a New Language

1. **Create language module structure**
   ```
   source/languages/{category}/{language}/
   ├── core/
   │   ├── handler.d      # Main language handler
   │   └── config.d       # Configuration structures
   ├── builders/          # Build strategies
   ├── analysis/          # Dependency analysis
   ├── managers/          # Package managers
   └── tooling/           # Language-specific tools
   ```

2. **Implement `LanguageHandler` interface**
   ```d
   class MyLanguageHandler : LanguageHandler {
       Result!(BuildOutput, BuildError) build(
           in Target target,
           in WorkspaceConfig workspace
       ) {
           // Implementation
       }
   }
   ```

3. **Add language detection**
   - Update `analysis/detection/detector.d`
   - Add file patterns and detection logic

4. **Create example project**
   - Add example in `examples/{language}-project/`
   - Include README with setup instructions
   - Add Builderfile configuration

5. **Write tests**
   - Unit tests for handler
   - Integration tests for builds
   - Test various project structures

6. **Document**
   - API documentation with DDoc
   - User guide in `docs/user-guides/`
   - Update main README

## 🐛 Reporting Bugs

When reporting bugs, include:

1. **Description**: Clear description of the issue
2. **Steps to Reproduce**: Minimal steps to reproduce
3. **Expected Behavior**: What should happen
4. **Actual Behavior**: What actually happens
5. **Environment**:
   - Builder version
   - OS and version
   - D compiler and version
6. **Logs**: Relevant log output or error messages
7. **Minimal Example**: If possible, a minimal project that reproduces the issue

## 💡 Feature Requests

When requesting features:

1. **Use Case**: Describe your use case
2. **Proposed Solution**: How you envision it working
3. **Alternatives**: Other solutions you've considered
4. **Additional Context**: Any other relevant information

## 📞 Getting Help

- **Documentation**: Check `docs/` directory
- **Examples**: See `examples/` directory
- **Issues**: Search existing issues on GitHub
- **Discussions**: GitHub Discussions for questions

## 🏆 Recognition

Contributors are recognized in:
- Release notes
- Contributors section of README
- Annual contributor highlights

## 📄 License

By contributing, you agree that your contributions will be licensed under the project's license (see LICENSE file).

---

**Thank you for contributing to Builder! 🎉**

