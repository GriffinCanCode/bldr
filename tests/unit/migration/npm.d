module tests.unit.migration.npm;

import std.stdio;
import std.file;
import std.path;
import std.json;
import infrastructure.migration.systems.npm;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;

/// Test npm migrator system name
unittest
{
    auto migrator = new NpmMigrator();
    assert(migrator.systemName() == "npm");
}

/// Test npm default file names
unittest
{
    auto migrator = new NpmMigrator();
    auto names = migrator.defaultFileNames();
    
    assert(names.length == 1);
    assert(names[0] == "package.json");
}

/// Test npm canMigrate
unittest
{
    auto migrator = new NpmMigrator();
    
    assert(migrator.canMigrate("package.json"));
    assert(migrator.canMigrate("/path/to/package.json"));
    assert(!migrator.canMigrate("BUILD"));
    assert(!migrator.canMigrate("pom.xml"));
}

/// Test npm migration with JavaScript project
unittest
{
    auto migrator = new NpmMigrator();
    
    JSONValue pkg = parseJSON(`{
        "name": "my-app",
        "main": "index.js",
        "scripts": {
            "build": "webpack",
            "test": "jest"
        }
    }`);
    
    string tempFile = tempDir() ~ "/test_package_" ~ __LINE__.to!string ~ ".json";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, pkg.toJSON());
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.success);
    assert(migration.targets.length >= 1);
    assert(migration.targets[0].name == "my-app");
    assert(migration.targets[0].language == TargetLanguage.JavaScript);
}

/// Test npm migration with TypeScript project
unittest
{
    auto migrator = new NpmMigrator();
    
    JSONValue pkg = parseJSON(`{
        "name": "ts-app",
        "main": "index.ts",
        "devDependencies": {
            "typescript": "^4.0.0"
        }
    }`);
    
    string tempFile = tempDir() ~ "/test_package_" ~ __LINE__.to!string ~ ".json";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, pkg.toJSON());
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    assert(migration.targets[0].language == TargetLanguage.TypeScript);
}

/// Test npm migration with test script
unittest
{
    auto migrator = new NpmMigrator();
    
    JSONValue pkg = parseJSON(`{
        "name": "app-with-tests",
        "main": "index.js",
        "scripts": {
            "test": "mocha"
        }
    }`);
    
    string tempFile = tempDir() ~ "/test_package_" ~ __LINE__.to!string ~ ".json";
    scope(exit) if (exists(tempFile)) remove(tempFile);
    
    write(tempFile, pkg.toJSON());
    
    auto result = migrator.migrate(tempFile);
    
    assert(result.isOk);
    auto migration = result.unwrap();
    
    // Should have created a test target
    bool hasTestTarget = false;
    foreach (target; migration.targets)
    {
        if (target.type == TargetType.Test)
        {
            hasTestTarget = true;
            break;
        }
    }
    assert(hasTestTarget);
}


