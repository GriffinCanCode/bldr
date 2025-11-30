module tests.unit.migration.registry;

import std.stdio;
import std.algorithm;
import infrastructure.migration.registry.registry;
import infrastructure.migration.core.base;

/// Test registry singleton
unittest
{
    auto registry1 = getMigratorRegistry();
    auto registry2 = getMigratorRegistry();
    
    assert(registry1 is registry2); // Same instance
}

/// Test system availability
unittest
{
    auto registry = getMigratorRegistry();
    
    assert(registry.isSupported("bazel"));
    assert(registry.isSupported("cmake"));
    assert(registry.isSupported("maven"));
    assert(registry.isSupported("gradle"));
    assert(registry.isSupported("make"));
    assert(registry.isSupported("cargo"));
    assert(registry.isSupported("npm"));
    assert(registry.isSupported("gomod"));
    assert(registry.isSupported("dub"));
    assert(registry.isSupported("sbt"));
    assert(registry.isSupported("meson"));
    
    assert(!registry.isSupported("nonexistent"));
}

/// Test migrator creation
unittest
{
    auto registry = getMigratorRegistry();
    
    auto bazel = registry.create("bazel");
    assert(bazel !is null);
    assert(bazel.systemName() == "bazel");
    
    auto cmake = registry.create("cmake");
    assert(cmake !is null);
    assert(cmake.systemName() == "cmake");
    
    auto invalid = registry.create("nonexistent");
    assert(invalid is null);
}

/// Test available systems listing
unittest
{
    auto registry = getMigratorRegistry();
    auto systems = registry.availableSystems();
    
    assert(systems.length >= 11); // At least 11 systems
    assert(systems.canFind("bazel"));
    assert(systems.canFind("cmake"));
    assert(systems.canFind("maven"));
}

/// Test all migrators retrieval
unittest
{
    auto registry = getMigratorRegistry();
    auto migrators = registry.allMigrators();
    
    assert(migrators.length >= 11);
    
    foreach (migrator; migrators)
    {
        assert(migrator !is null);
        assert(migrator.systemName().length > 0);
        assert(migrator.defaultFileNames().length > 0);
    }
}

/// Test factory creation
unittest
{
    auto bazel = MigratorFactory.create("bazel");
    assert(bazel !is null);
    assert(bazel.systemName() == "bazel");
    
    auto cmake = MigratorFactory.create("cmake");
    assert(cmake !is null);
    assert(cmake.systemName() == "cmake");
}

/// Test factory available systems
unittest
{
    auto systems = MigratorFactory.availableSystems();
    assert(systems.length >= 11);
    assert(systems.canFind("bazel"));
    assert(systems.canFind("cmake"));
}

/// Test case insensitivity
unittest
{
    auto registry = getMigratorRegistry();
    
    auto bazel1 = registry.create("bazel");
    auto bazel2 = registry.create("BAZEL");
    auto bazel3 = registry.create("Bazel");
    
    assert(bazel1 !is null);
    assert(bazel2 !is null);
    assert(bazel3 !is null);
    
    assert(bazel1.systemName() == bazel2.systemName());
    assert(bazel2.systemName() == bazel3.systemName());
}


