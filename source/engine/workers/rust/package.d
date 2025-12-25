module engine.workers.rust;

/// Rust Persistent Worker
/// 
/// Keeps cargo/rustc warm for incremental compilation.
/// Speedup: 3-15x by avoiding:
/// - rustc initialization
/// - cargo workspace analysis
/// - incremental state loading
/// 
/// Supports:
/// - cargo build - full package build
/// - cargo check - type checking only
/// - rustc - direct single-file compilation
/// - clippy - linting

public import engine.workers.rust.worker;


