module tests.unit.migration.integration;

import std.stdio;
import std.file;
import std.path;
import infrastructure.migration;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;

/// Test end-to-end migration flow
unittest
{
    auto migrator = MigratorFactory.create("bazel");
    assert(migrator !is null);
    
    string buildContent = `
cc_binary(
    name = "myapp",
    srcs = ["main.cpp"],
)
`;
    
    string tempFile = tempDir() ~ "/test_BUILD_integration_" ~ __LINE__.to!string;
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, buildContent);
    
    // Migrate
    auto result = migrator.migrate(tempFile);
    assert(result.isOk);
    
    auto migration = result.unwrap();
    assert(migration.success);
    
    // Emit
    auto emitter = BuilderfileEmitter();
    string builderfile = emitter.emit(migration);
    
    assert(builderfile.length > 0);
    assert(builderfile.indexOf("target(\"myapp\")") >= 0);
    assert(builderfile.indexOf("type: executable") >= 0);
}

/// Test auto-detection
unittest
{
    // Create BUILD file
    string buildFile = tempDir() ~ "/test_BUILD_autodetect_" ~ __LINE__.to!string;
    scope(exit) if (exists(buildFile)) remove(buildFile);
    
    write(buildFile, `cc_binary(name = "app", srcs = ["main.cpp"])`);
    
    auto migrator = MigratorFactory.autoDetect(buildFile);
    assert(migrator !is null);
    assert(migrator.systemName() == "bazel");
    
    // Create CMakeLists.txt file
    string cmakeFile = tempDir() ~ "/CMakeLists_autodetect_" ~ __LINE__.to!string ~ ".txt";
    scope(exit) if (exists(cmakeFile)) remove(cmakeFile);
    
    write(cmakeFile, `add_executable(app main.cpp)`);
    
    auto cmakeMigrator = MigratorFactory.autoDetect(cmakeFile);
    assert(cmakeMigrator !is null);
    assert(cmakeMigrator.systemName() == "cmake");
}

/// Test migration with warnings
unittest
{
    auto migrator = MigratorFactory.create("cmake");
    
    string cmakeContent = `
add_executable(app main.cpp)
target_compile_options(app PRIVATE -Wall)
`;
    
    string tempFile = tempDir() ~ "/test_CMake_warnings_" ~ __LINE__.to!string ~ ".txt";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, cmakeContent);
    
    auto result = migrator.migrate(tempFile);
    assert(result.isOk);
    
    auto migration = result.unwrap();
    
    // Emit with warnings
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(migration);
    
    assert(output.length > 0);
}

/// Test factory with all systems
unittest
{
    string[] systems = ["bazel", "cmake", "maven", "gradle", "make", 
                        "cargo", "npm", "gomod", "dub", "sbt", "meson"];
    
    foreach (system; systems)
    {
        auto migrator = MigratorFactory.create(system);
        assert(migrator !is null, "Failed to create migrator for: " ~ system);
        assert(migrator.systemName() == system);
        assert(migrator.defaultFileNames().length > 0);
        assert(migrator.description().length > 0);
    }
}

/// Test complete workflow: migrate + emit + validate
unittest
{
    import std.algorithm : canFind;
    
    auto migrator = new NpmMigrator();
    
    string pkgJson = `{
        "name": "test-app",
        "main": "index.js",
        "scripts": {
            "build": "webpack"
        }
    }`;
    
    string tempFile = tempDir() ~ "/test_package_workflow_" ~ __LINE__.to!string ~ ".json";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, pkgJson);
    
    // Step 1: Migrate
    auto migrateResult = migrator.migrate(tempFile);
    assert(migrateResult.isOk);
    
    auto migration = migrateResult.unwrap();
    assert(migration.success);
    assert(migration.targets.length > 0);
    
    // Step 2: Emit
    auto emitter = BuilderfileEmitter();
    string builderfile = emitter.emit(migration);
    
    // Step 3: Validate output
    assert(builderfile.canFind("Builderfile"));
    assert(builderfile.canFind("target("));
    assert(builderfile.canFind("type:"));
    assert(builderfile.canFind("language:"));
    
    // Write to file (optional)
    string outputFile = tempDir() ~ "/test_Builderfile_" ~ __LINE__.to!string;
    scope(exit) if (exists(outputFile)) remove(outputFile);
    
    write(outputFile, builderfile);
    assert(exists(outputFile));
}


