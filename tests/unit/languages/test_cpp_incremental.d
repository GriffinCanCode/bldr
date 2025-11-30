module tests.unit.languages.test_cpp_incremental;

import std.file;
import std.path;
import std.algorithm;
import std.conv;
import std.stdio;
import std.uuid;
import languages.compiled.cpp.analysis.incremental;
import tests.harness;
import tests.fixtures;
import infrastructure.errors;

// Helper to generate random UUID
private string randomUUID()
{
    import std.random;
    import std.format;
    
    return format("%08x-%04x-%04x-%04x-%012x",
                 uniform!uint(),
                 uniform!ushort(),
                 uniform!ushort(),
                 uniform!ushort(),
                 uniform!ulong() & 0xFFFF_FFFF_FFFF);
}

/// Test C++ dependency analyzer
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m C++ - Dependency Analyzer");
    
    auto tempDir = scoped(new TempDir("test-cpp-deps"));
    auto testDir = tempDir.getPath();
    
    // Create test files
    std.file.write(buildPath(testDir, "main.cpp"), 
        "#include \"header.h\"\n#include <iostream>\nint main() {}");
    std.file.write(buildPath(testDir, "header.h"), 
        "#ifndef HEADER_H\n#define HEADER_H\nvoid func();\n#endif");
    std.file.write(buildPath(testDir, "utils.h"), 
        "#ifndef UTILS_H\n#define UTILS_H\nvoid util();\n#endif");
    
    auto analyzer = new CppDependencyAnalyzer([testDir]);
    
    auto mainPath = buildPath(testDir, "main.cpp");
    auto headerPath = buildPath(testDir, "header.h");
    
    auto result = analyzer.analyzeDependencies(mainPath);
    Assert.isTrue(result.isOk, "Should analyze dependencies");
    
    auto deps = result.unwrap();
    Assert.isTrue(deps.length > 0, "Should find dependencies");
    Assert.isTrue(deps.canFind(headerPath), "Should find header.h");
    Assert.isFalse(deps.canFind("iostream"), "Should not include system headers");
    
    writeln("\x1b[32m  ✓ Dependency analyzer passed\x1b[0m");
}

/// Test C++ external dependency detection
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m C++ - External Dependency Detection");
    
    auto analyzer = new CppDependencyAnalyzer();
    
    // Standard library headers
    Assert.isTrue(analyzer.isExternalDependency("iostream"),
              "iostream should be external");
    Assert.isTrue(analyzer.isExternalDependency("vector"),
              "vector should be external");
    Assert.isTrue(analyzer.isExternalDependency("string.h"),
              "string.h should be external");
    
    // Local headers
    Assert.isFalse(analyzer.isExternalDependency("myheader.h"),
               "myheader.h should not be external");
    Assert.isFalse(analyzer.isExternalDependency("utils/helper.h"),
               "utils/helper.h should not be external");
               
    writeln("\x1b[32m  ✓ External detection passed\x1b[0m");
}

/// Test C++ affected sources detection
unittest
{
    writeln("\x1b[36m[TEST]\x1b[0m C++ - Affected Sources Detection");
    
    auto tempDir = scoped(new TempDir("test-cpp-affected"));
    auto testDir = tempDir.getPath();
    
    // Create source files with dependencies
    std.file.write(buildPath(testDir, "main.cpp"),
        "#include \"shared.h\"\nint main() {}");
    std.file.write(buildPath(testDir, "utils.cpp"),
        "#include \"shared.h\"\nvoid util() {}");
    std.file.write(buildPath(testDir, "other.cpp"),
        "#include \"other.h\"\nvoid other() {}");
    std.file.write(buildPath(testDir, "shared.h"),
        "void shared();");
    std.file.write(buildPath(testDir, "other.h"),
        "void other_func();");
    
    auto analyzer = new CppDependencyAnalyzer([testDir]);
    
    auto sharedHeader = buildPath(testDir, "shared.h");
    auto mainCpp = buildPath(testDir, "main.cpp");
    auto utilsCpp = buildPath(testDir, "utils.cpp");
    auto otherCpp = buildPath(testDir, "other.cpp");
    
    auto allSources = [mainCpp, utilsCpp, otherCpp];
    
    auto affected = CppIncrementalHelper.findAffectedSources(
        sharedHeader,
        allSources,
        analyzer
    );
    
    Assert.isTrue(affected.canFind(mainCpp),
              "main.cpp should be affected by shared.h");
    Assert.isTrue(affected.canFind(utilsCpp),
              "utils.cpp should be affected by shared.h");
    Assert.isFalse(affected.canFind(otherCpp),
               "other.cpp should not be affected by shared.h");
               
    writeln("\x1b[32m  ✓ Affected sources detection passed\x1b[0m");
}
