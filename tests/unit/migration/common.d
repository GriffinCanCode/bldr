module tests.unit.migration.common;

import std.stdio;
import infrastructure.migration.core.common;
import infrastructure.config.schema.schema : TargetType, TargetLanguage, Target;

/// Test MigrationTarget creation and conversion
unittest
{
    MigrationTarget mtarget;
    mtarget.name = "test-app";
    mtarget.type = TargetType.Executable;
    mtarget.language = TargetLanguage.Cpp;
    mtarget.sources = ["main.cpp", "utils.cpp"];
    mtarget.dependencies = ["lib1", "lib2"];
    mtarget.flags = ["-O2", "-Wall"];
    mtarget.includes = ["include/"];
    mtarget.output = "test-app";
    
    assert(mtarget.name == "test-app");
    assert(mtarget.type == TargetType.Executable);
    assert(mtarget.language == TargetLanguage.Cpp);
    assert(mtarget.sources.length == 2);
    assert(mtarget.dependencies.length == 2);
    assert(mtarget.flags.length == 2);
    
    // Test conversion to Target
    Target target = mtarget.toTarget();
    assert(target.name == "test-app");
    assert(target.type == TargetType.Executable);
    assert(target.language == TargetLanguage.Cpp);
    assert(target.sources.length == 2);
    assert(target.deps.length == 2);
}

/// Test MigrationWarning creation
unittest
{
    MigrationWarning warning = MigrationWarning(
        WarningLevel.Warning,
        "Test warning message",
        "context"
    );
    
    assert(warning.level == WarningLevel.Warning);
    assert(warning.message == "Test warning message");
    assert(warning.context == "context");
    assert(warning.suggestions.length == 0);
    
    warning.addSuggestion("Fix this");
    warning.addSuggestion("Or that");
    assert(warning.suggestions.length == 2);
}

/// Test MigrationResult error checking
unittest
{
    MigrationResult result;
    result.success = true;
    
    assert(!result.hasErrors());
    assert(!result.hasWarnings());
    assert(result.errors().length == 0);
    
    // Add info
    result.addInfo("Info message", "context");
    assert(!result.hasErrors());
    assert(!result.hasWarnings());
    
    // Add warning
    result.addWarning(MigrationWarning(WarningLevel.Warning, "Warning", "ctx"));
    assert(!result.hasErrors());
    assert(result.hasWarnings());
    
    // Add error
    result.addError("Error message", "error context");
    assert(result.hasErrors());
    assert(result.success == false);
    assert(result.errors().length == 1);
}

/// Test MigrationResult with targets
unittest
{
    MigrationTarget target1;
    target1.name = "app1";
    target1.type = TargetType.Executable;
    target1.language = TargetLanguage.Python;
    
    MigrationTarget target2;
    target2.name = "lib1";
    target2.type = TargetType.Library;
    target2.language = TargetLanguage.Python;
    
    MigrationResult result;
    result.targets = [target1, target2];
    result.success = true;
    
    assert(result.targets.length == 2);
    assert(result.targets[0].name == "app1");
    assert(result.targets[1].name == "lib1");
}

/// Test WarningLevel enum
unittest
{
    assert(WarningLevel.Info != WarningLevel.Warning);
    assert(WarningLevel.Warning != WarningLevel.Error);
}


