module languages.compiled.cpp.analysis.modules;

import std.algorithm : canFind, filter, map, sort, startsWith;
import std.array : array, join;
import std.file : exists, isFile, readText;
import std.path : baseName, buildPath, dirName, extension;
import std.regex : matchAll, matchFirst, regex;
import std.string : strip, toLower;
import infrastructure.utils.logging : structuredLog;

/// C++20 module information extracted from source
struct ModuleInfo
{
    string name;              // Module name (e.g., "std.io", "mylib.core")
    string partitionName;     // Partition name if any (e.g., "impl" for module foo:impl)
    bool isExported;          // Is this an exported module interface?
    bool isPartition;         // Is this a module partition?
    bool isHeaderUnit;        // Is this being compiled as a header unit?
    string[] imports;         // Imported modules
    string[] headerImports;   // Header unit imports (import <header>)
    string sourcePath;        // Source file path
}

/// Analyze a C++ source file for module declarations
ModuleInfo analyzeModuleSource(string sourcePath) @system
{
    ModuleInfo info;
    info.sourcePath = sourcePath;
    
    if (!exists(sourcePath) || !isFile(sourcePath))
        return info;
    
    try
    {
        auto content = readText(sourcePath);
        
        // Match module declaration: export module foo; or module foo;
        auto moduleDecl = regex(`^\s*(export\s+)?module\s+([a-zA-Z_][a-zA-Z0-9_.]*)(:[a-zA-Z_][a-zA-Z0-9_]*)?\s*;`, "m");
        auto moduleMatch = matchFirst(content, moduleDecl);
        
        if (!moduleMatch.empty)
        {
            info.isExported = moduleMatch[1].length > 0;
            info.name = moduleMatch[2];
            if (moduleMatch[3].length > 1) // Skip the ':' prefix
            {
                info.partitionName = moduleMatch[3][1..$];
                info.isPartition = true;
            }
        }
        
        // Match module imports: import foo; or import foo:bar;
        auto importDecl = regex(`^\s*import\s+([a-zA-Z_][a-zA-Z0-9_.]*)(:[a-zA-Z_][a-zA-Z0-9_]*)?\s*;`, "m");
        foreach (m; matchAll(content, importDecl))
        {
            string importName = m[1];
            if (m[2].length > 1)
                importName ~= m[2];
            info.imports ~= importName;
        }
        
        // Match header unit imports: import <header>; or import "header";
        auto headerImport = regex(`^\s*import\s+[<"]([^>"]+)[>"]\s*;`, "m");
        foreach (m; matchAll(content, headerImport))
            info.headerImports ~= m[1];
        
        // Check file extension for header unit hint
        auto ext = extension(sourcePath).toLower;
        if (ext == ".h" || ext == ".hpp" || ext == ".hxx")
            info.isHeaderUnit = true;
    }
    catch (Exception e)
    {
        structuredLog.warning("failed_to_analyze_module_source_").field("detail", "Failed to analyze module source " ~ sourcePath ~ ": " ~ e.msg).emit();
    }
    
    return info;
}

/// Check if a source file is a C++20 module interface unit
bool isModuleInterface(string sourcePath) @system
{
    auto ext = extension(sourcePath).toLower;
    
    // Common module interface extensions
    if (ext == ".cppm" || ext == ".ixx" || ext == ".mpp" || ext == ".mxx")
        return true;
    
    // Check content for export module declaration
    if (ext == ".cpp" || ext == ".cxx" || ext == ".cc")
    {
        auto info = analyzeModuleSource(sourcePath);
        return info.isExported && info.name.length > 0;
    }
    
    return false;
}

/// Get module interface extensions recognized by each compiler
string[] getModuleExtensions(string compilerType) pure @safe
{
    // Common extensions supported by all
    string[] common = [".cppm", ".ixx", ".mpp", ".mxx"];
    
    switch (compilerType.toLower)
    {
        case "gcc", "g++":
            return common ~ [".c++m"];
        case "clang", "clang++":
            return common ~ [".ccm", ".cxxm"];
        case "msvc", "cl", "cl.exe":
            return common;  // MSVC uses .ixx primarily
        default:
            return common;
    }
}

/// Generate compiler flags for module compilation
struct ModuleCompilerFlags
{
    string[] interfaceFlags;    // Flags to compile module interface
    string[] consumeFlags;      // Flags to consume a module
    string[] headerUnitFlags;   // Flags to compile header unit
    string bmiOutputFlag;       // Flag to specify BMI output path
    string bmiInputFlag;        // Flag to specify BMI input path
}

/// Get module-related compiler flags based on compiler type
ModuleCompilerFlags getModuleFlags(string compilerType, string compilerVersion = "") pure @safe
{
    ModuleCompilerFlags flags;
    
    switch (compilerType.toLower)
    {
        case "gcc", "g++":
            flags.interfaceFlags = ["-fmodules-ts", "-x", "c++-module"];
            flags.consumeFlags = ["-fmodules-ts"];
            flags.headerUnitFlags = ["-fmodules-ts", "-x", "c++-system-header"];
            flags.bmiOutputFlag = "-fmodule-output=";
            flags.bmiInputFlag = "-fmodule-file=";
            break;
            
        case "clang", "clang++":
            flags.interfaceFlags = ["-fmodules", "--precompile"];
            flags.consumeFlags = ["-fmodules"];
            flags.headerUnitFlags = ["-fmodules", "-xc++-header"];
            flags.bmiOutputFlag = "-o";
            flags.bmiInputFlag = "-fmodule-file=";
            break;
            
        case "msvc", "cl", "cl.exe":
            flags.interfaceFlags = ["/interface", "/TP"];
            flags.consumeFlags = ["/module:search"];
            flags.headerUnitFlags = ["/exportHeader"];
            flags.bmiOutputFlag = "/ifcOutput";
            flags.bmiInputFlag = "/reference";
            break;
            
        default:
            // Assume GCC-like
            flags.interfaceFlags = ["-fmodules-ts"];
            flags.consumeFlags = ["-fmodules-ts"];
            flags.bmiOutputFlag = "-fmodule-output=";
            flags.bmiInputFlag = "-fmodule-file=";
    }
    
    return flags;
}

/// Topologically sort modules by dependencies
/// Returns modules in compilation order (dependencies first)
string[] sortModulesByDependency(ModuleInfo[] modules) @system
{
    // Build dependency graph
    string[][string] deps;
    ModuleInfo[string] byName;
    
    foreach (ref mod; modules)
    {
        string fullName = mod.isPartition ? mod.name ~ ":" ~ mod.partitionName : mod.name;
        byName[fullName] = mod;
        deps[fullName] = mod.imports.filter!(i => byName.keys.canFind(i)).array;
    }
    
    // Kahn's algorithm for topological sort
    string[] result;
    bool[string] visited;
    bool[string] inStack;
    
    void visit(string name)
    {
        if (name in visited) return;
        if (name in inStack)
        {
            structuredLog.warning("circular_module_dependency_detected_").field("detail", "Circular module dependency detected: " ~ name).emit();
            return;
        }
        
        inStack[name] = true;
        foreach (dep; deps.get(name, []))
            visit(dep);
        inStack.remove(name);
        
        visited[name] = true;
        if (auto mod = name in byName)
            result ~= mod.sourcePath;
    }
    
    foreach (name; byName.keys.array.sort())
        visit(name);
    
    return result;
}

/// Determine BMI output path for a module
string getBMIOutputPath(
    string moduleName,
    string outputDir,
    string compilerType
) pure @safe
{
    import std.string : replace;
    
    // Convert module name to filename (replace . with /)
    string filename = moduleName.replace(".", "_").replace(":", "_");
    
    // Get appropriate extension
    string ext;
    switch (compilerType.toLower)
    {
        case "gcc", "g++": ext = ".gcm"; break;
        case "clang", "clang++": ext = ".pcm"; break;
        case "msvc", "cl", "cl.exe": ext = ".ifc"; break;
        default: ext = ".bmi";
    }
    
    return buildPath(outputDir, filename ~ ext);
}

/// Check if C++20 modules are supported by compiler version
bool isModuleSupportedVersion(string compilerType, string version_) @safe
{
    import std.conv : to;
    
    // Parse major version
    int major = 0;
    try
    {
        auto dotPos = version_.indexOf('.');
        if (dotPos > 0)
            major = version_[0..dotPos].to!int;
        else if (version_.length > 0)
            major = version_[0..1].to!int;
    }
    catch (Exception) { return false; }
    
    switch (compilerType.toLower)
    {
        case "gcc", "g++":
            return major >= 11;  // GCC 11+ has basic module support
        case "clang", "clang++":
            return major >= 16;  // Clang 16+ has decent module support
        case "msvc", "cl", "cl.exe":
            return true;  // MSVC 19.28+ (VS 2019 16.10+)
        default:
            return false;
    }
}

private ptrdiff_t indexOf(string s, char c) pure @safe
{
    foreach (i, ch; s)
        if (ch == c) return i;
    return -1;
}

