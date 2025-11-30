module tests.unit.migration.bazel;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.conv;
import infrastructure.migration.systems.bazel;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;

/// Test Bazel migrator system name
unittest
{
    auto migrator = new BazelMigrator();
    assert(migrator.systemName() == "bazel");
}

/// Test Bazel default file names
unittest
{
    auto migrator = new BazelMigrator();
    auto names = migrator.defaultFileNames();
    
    assert(names.length == 2);
    assert(names[0] == "BUILD");
    assert(names[1] == "BUILD.bazel");
}

/// Test Bazel canMigrate
unittest
{
    auto migrator = new BazelMigrator();
    
    assert(migrator.canMigrate("BUILD"));
    assert(migrator.canMigrate("BUILD.bazel"));
    assert(migrator.canMigrate("/path/to/BUILD"));
    assert(migrator.canMigrate("/path/to/BUILD.bazel"));
    assert(!migrator.canMigrate("CMakeLists.txt"));
    assert(!migrator.canMigrate("pom.xml"));
}

/// Test Bazel description
unittest
{
    auto migrator = new BazelMigrator();
    auto desc = migrator.description();
    
    assert(desc.length > 0);
    assert(desc.indexOf("Bazel") >= 0 || desc.indexOf("BUILD") >= 0);
}

/// Test Bazel supported features
unittest
{
    auto migrator = new BazelMigrator();
    auto features = migrator.supportedFeatures();
    
    assert(features.length > 0);
}

/// Test Bazel limitations
unittest
{
    auto migrator = new BazelMigrator();
    auto limitations = migrator.limitations();
    
    assert(limitations.length > 0);
}

/// Test Bazel migration with simple cc_binary
unittest
{
    auto migrator = new BazelMigrator();
    
    string buildContent = `
cc_binary(
    name = "hello",
    srcs = ["main.cpp"],
    copts = ["-std=c++17"],
)
`;
    
    // Create temp file
    string tempFile = tempDir() ~ "/test_BUILD_" ~ __LINE__.to!string;
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    std.file.write(tempFile, buildContent);
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.success);
    assert(migration.targets.length == 1);
    assert(migration.targets[0].name == "hello");
    assert(migration.targets[0].type == TargetType.Executable);
    assert(migration.targets[0].language == TargetLanguage.Cpp);
}

/// Test Bazel migration with cc_library
unittest
{
    auto migrator = new BazelMigrator();
    
    string buildContent = `
cc_library(
    name = "mylib",
    srcs = ["lib.cpp"],
    hdrs = ["lib.h"],
)
`;
    
    string tempFile = tempDir() ~ "/test_BUILD_" ~ __LINE__.to!string;
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, buildContent);
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.targets.length == 1);
    assert(migration.targets[0].name == "mylib");
    assert(migration.targets[0].type == TargetType.Library);
}

/// Test Bazel migration with Python rules
unittest
{
    auto migrator = new BazelMigrator();
    
    string buildContent = `
py_binary(
    name = "script",
    srcs = ["script.py"],
    deps = [":pylib"],
)
`;
    
    string tempFile = tempDir() ~ "/test_BUILD_" ~ __LINE__.to!string;
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, buildContent);
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.targets.length == 1);
    assert(migration.targets[0].name == "script");
    assert(migration.targets[0].language == TargetLanguage.Python);
}

/// Test Bazel migration with non-existent file
unittest
{
    auto migrator = new BazelMigrator();
    
    auto result = migrator.migrate("/nonexistent/BUILD");
    
    assert(result.isErr);
}


