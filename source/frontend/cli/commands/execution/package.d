module frontend.cli.commands.execution;

/// Build Execution and Analysis Commands
/// 
/// This package contains commands for building, testing, querying,
/// and analyzing the build graph:
/// 
/// - discover: Preview dynamic dependency discovery without building
/// - query: Query the build graph and configuration
/// - test: Execute tests with advanced filtering and reporting
/// - infer: Infer build configuration from source code
/// - verify: Verify build determinism with automatic two-build comparison
/// - resolve: Resolve package dependencies using PubGrub solver

public import frontend.cli.commands.execution.discover;
public import frontend.cli.commands.execution.query;
public import frontend.cli.commands.execution.test;
public import frontend.cli.commands.execution.infer;
public import frontend.cli.commands.execution.verify;
public import frontend.cli.commands.execution.resolve;
