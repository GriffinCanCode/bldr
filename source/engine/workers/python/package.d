module engine.workers.python;

/// Python Persistent Worker
/// 
/// Keeps Python tooling warm for faster analysis.
/// Speedup: 3-20x depending on tool
/// 
/// Supports:
/// - mypy: Type checker (biggest benefit - stub loading)
/// - ruff: Ultra-fast linter (Rust-based)
/// - pylint: Traditional linter  
/// - black: Code formatter
/// - pytest: Test runner

public import engine.workers.python.worker;


