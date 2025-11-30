module tests.unit.migration.emitter;

import std.stdio;
import std.string;
import std.algorithm;
import infrastructure.migration.emission.emitter;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage;

/// Test basic Builderfile emission
unittest
{
    MigrationTarget target;
    target.name = "hello";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.Cpp;
    target.sources = ["main.cpp"];
    target.flags = ["-O2"];
    
    MigrationResult result;
    result.targets = [target];
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("target(\"hello\")") >= 0);
    assert(output.indexOf("type: executable") >= 0);
    assert(output.indexOf("language: cpp") >= 0);
    assert(output.indexOf("sources: [\"main.cpp\"]") >= 0);
    assert(output.indexOf("flags: [\"-O2\"]") >= 0);
}

/// Test multiple targets emission
unittest
{
    MigrationTarget target1;
    target1.name = "app";
    target1.type = TargetType.Executable;
    target1.language = TargetLanguage.Go;
    target1.sources = ["main.go"];
    
    MigrationTarget target2;
    target2.name = "lib";
    target2.type = TargetType.Library;
    target2.language = TargetLanguage.Go;
    target2.sources = ["lib.go"];
    
    MigrationResult result;
    result.targets = [target1, target2];
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("target(\"app\")") >= 0);
    assert(output.indexOf("target(\"lib\")") >= 0);
    assert(output.indexOf("language: go") >= 0);
}

/// Test dependencies emission
unittest
{
    MigrationTarget target;
    target.name = "app";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.Python;
    target.sources = ["main.py"];
    target.dependencies = ["lib1", "lib2"];
    
    MigrationResult result;
    result.targets = [target];
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("deps: [") >= 0);
    assert(output.indexOf("\"lib1\"") >= 0);
    assert(output.indexOf("\"lib2\"") >= 0);
}

/// Test metadata emission as comments
unittest
{
    MigrationTarget target;
    target.name = "test";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.Rust;
    target.sources = ["main.rs"];
    target.metadata["linkopts"] = "-lpthread";
    target.metadata["features"] = "c++17";
    
    MigrationResult result;
    result.targets = [target];
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("// Additional metadata:") >= 0);
    assert(output.indexOf("// linkopts: -lpthread") >= 0);
    assert(output.indexOf("// features: c++17") >= 0);
}

/// Test warnings emission
unittest
{
    MigrationTarget target;
    target.name = "app";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.Java;
    target.sources = ["Main.java"];
    
    MigrationResult result;
    result.targets = [target];
    result.addWarning(MigrationWarning(WarningLevel.Warning, 
        "Test warning", "context"));
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("// Migration Summary") >= 0);
    assert(output.indexOf("// WARNINGS:") >= 0);
    assert(output.indexOf("//   - Test warning") >= 0);
}

/// Test environment variables emission
unittest
{
    MigrationTarget target;
    target.name = "app";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.Python;
    target.sources = ["main.py"];
    target.env["PATH"] = "/usr/bin";
    target.env["HOME"] = "/home/user";
    
    MigrationResult result;
    result.targets = [target];
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("env: {") >= 0);
    assert(output.indexOf("\"PATH\"") >= 0 || output.indexOf("\"HOME\"") >= 0);
}

/// Test output path emission
unittest
{
    MigrationTarget target;
    target.name = "myapp";
    target.type = TargetType.Executable;
    target.language = TargetLanguage.Cpp;
    target.sources = ["main.cpp"];
    target.output = "bin/myapp";
    
    MigrationResult result;
    result.targets = [target];
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("output: \"bin/myapp\"") >= 0);
}

/// Test header comment generation
unittest
{
    MigrationResult result;
    result.success = true;
    
    auto emitter = BuilderfileEmitter();
    string output = emitter.emit(result);
    
    assert(output.indexOf("// Builderfile") >= 0);
    assert(output.indexOf("// Auto-generated by Builder migration tool") >= 0);
    assert(output.indexOf("// Review and adjust as needed") >= 0);
}


