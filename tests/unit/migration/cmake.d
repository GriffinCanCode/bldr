module tests.unit.migration.cmake;

import std.stdio;
import std.file;
import std.path;
import std.conv;
import infrastructure.migration.systems.cmake;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;

/// Test CMake migrator system name
unittest
{
    auto migrator = new CMakeMigrator();
    assert(migrator.systemName() == "cmake");
}

/// Test CMake default file names
unittest
{
    auto migrator = new CMakeMigrator();
    auto names = migrator.defaultFileNames();
    
    assert(names.length == 1);
    assert(names[0] == "CMakeLists.txt");
}

/// Test CMake canMigrate
unittest
{
    auto migrator = new CMakeMigrator();
    
    assert(migrator.canMigrate("CMakeLists.txt"));
    assert(migrator.canMigrate("cmakelists.txt")); // Case insensitive
    assert(migrator.canMigrate("/path/to/CMakeLists.txt"));
    assert(!migrator.canMigrate("BUILD"));
    assert(!migrator.canMigrate("pom.xml"));
}

/// Test CMake migration with add_executable
unittest
{
    auto migrator = new CMakeMigrator();
    
    string cmakeContent = `
cmake_minimum_required(VERSION 3.10)
project(Hello)

add_executable(hello main.cpp utils.cpp)
`;
    
    string tempFile = tempDir() ~ "/test_CMakeLists_" ~ __LINE__.to!string ~ ".txt";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    std.file.write(tempFile, cmakeContent);
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.success);
    assert(migration.targets.length == 1);
    assert(migration.targets[0].name == "hello");
    assert(migration.targets[0].type == TargetType.Executable);
}

/// Test CMake migration with add_library
unittest
{
    auto migrator = new CMakeMigrator();
    
    string cmakeContent = `
add_library(mylib STATIC lib.cpp lib.h)
`;
    
    string tempFile = tempDir() ~ "/test_CMakeLists_" ~ __LINE__.to!string ~ ".txt";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    std.file.write(tempFile, cmakeContent);
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.targets.length == 1);
    assert(migration.targets[0].name == "mylib");
    assert(migration.targets[0].type == TargetType.Library);
}

/// Test CMake migration with target_link_libraries
unittest
{
    auto migrator = new CMakeMigrator();
    
    string cmakeContent = `
add_executable(app main.cpp)
add_library(utils utils.cpp)
target_link_libraries(app utils)
`;
    
    string tempFile = tempDir() ~ "/test_CMakeLists_" ~ __LINE__.to!string ~ ".txt";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    std.file.write(tempFile, cmakeContent);
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.targets.length == 2);
    
    // Find app target
    foreach (target; migration.targets)
    {
        if (target.name == "app")
        {
            assert(target.dependencies.length > 0);
            break;
        }
    }
}


