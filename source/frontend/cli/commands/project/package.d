module frontend.cli.commands.project;

/// Project Management Commands
/// 
/// This package contains commands for project initialization,
/// configuration, and migration:
/// 
/// - init: Initialize a new Builder project with Builderfile and Builderspace
/// - wizard: Interactive wizard for project setup and configuration
/// - migrate: Migrate from other build systems (Bazel, Make, CMake, etc.)
/// - migrate-wizard: Interactive guided migration with explanations

public import frontend.cli.commands.project.init;
public import frontend.cli.commands.project.wizard;
public import frontend.cli.commands.project.migrate;
public import frontend.cli.commands.project.migration_wizard;

