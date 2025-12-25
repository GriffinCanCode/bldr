module languages.compiled.cpp.builders.modules;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join;
import std.conv : to;
import std.file : exists, mkdirRecurse;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.process : execute;
import std.string : replace, toLower;

import languages.compiled.cpp.core.config;
import languages.compiled.cpp.analysis.modules : CppModuleInfo = ModuleInfo, analyzeModuleSource, 
    sortModulesByDependency, isModuleInterface, getModuleFlags, getBMIOutputPath, isModuleSupportedVersion;
import infrastructure.toolchain : Tool, Toolchain;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.utils.logging.logger : Logger;
import engine.caching.modules.bmi;

/// Build compiler flags from CppConfig
private string[] buildCompilerFlags(in CppConfig config, bool isCpp) pure @safe
{
    string[] flags;
    
    // Standard version
    if (isCpp)
    {
        final switch (config.cppStandard) with (CppStandard)
        {
            case Cpp98: flags ~= "-std=c++98"; break;
            case Cpp03: flags ~= "-std=c++03"; break;
            case Cpp11: flags ~= "-std=c++11"; break;
            case Cpp14: flags ~= "-std=c++14"; break;
            case Cpp17: flags ~= "-std=c++17"; break;
            case Cpp20: flags ~= "-std=c++20"; break;
            case Cpp23: flags ~= "-std=c++23"; break;
            case Cpp26: flags ~= "-std=c++2c"; break;
            case GnuCpp98: flags ~= "-std=gnu++98"; break;
            case GnuCpp03: flags ~= "-std=gnu++03"; break;
            case GnuCpp11: flags ~= "-std=gnu++11"; break;
            case GnuCpp14: flags ~= "-std=gnu++14"; break;
            case GnuCpp17: flags ~= "-std=gnu++17"; break;
            case GnuCpp20: flags ~= "-std=gnu++20"; break;
            case GnuCpp23: flags ~= "-std=gnu++23"; break;
            case GnuCpp26: flags ~= "-std=gnu++2c"; break;
        }
    }
    
    // Optimization level
    final switch (config.optLevel) with (OptLevel)
    {
        case O0: flags ~= "-O0"; break;
        case O1: flags ~= "-O1"; break;
        case O2: flags ~= "-O2"; break;
        case O3: flags ~= "-O3"; break;
        case Os: flags ~= "-Os"; break;
        case Ofast: flags ~= "-Ofast"; break;
        case Og: flags ~= "-Og"; break;
    }
    
    // Debug info
    if (config.debugInfo) flags ~= "-g";
    
    // PIC
    if (config.pic || config.outputType == OutputType.SharedLib)
        flags ~= "-fPIC";
    
    // Include dirs and defines
    foreach (inc; config.includeDirs) flags ~= "-I" ~ inc;
    foreach (def; config.defines) flags ~= "-D" ~ def;
    flags ~= config.compilerFlags;
    
    return flags;
}

/// Result from module compilation
struct ModuleCompileResult
{
    bool success;
    string error;
    string bmiPath;           // Path to generated BMI
    string objectPath;        // Path to object file (if any)
    string[] warnings;
    bool fromCache;
}

/// C++20 module builder with BMI caching
final class ModuleBuilder
{
    private Toolchain toolchain;
    private BMICache bmiCache;
    private string compilerPath;
    private string compilerVersion;
    private string compilerType;
    
    this(Toolchain tc, BMICache cache = null) @system
    {
        this.toolchain = tc;
        this.bmiCache = cache is null ? new BMICache() : cache;
        
        auto comp = tc.compiler();
        if (comp !is null)
        {
            this.compilerPath = comp.path;
            this.compilerVersion = comp.version_.toString();
            this.compilerType = comp.name;
        }
    }
    
    /// Compile a C++20 module interface unit with BMI caching
    ModuleCompileResult compileModuleInterface(
        string sourcePath,
        string outputDir,
        in CppConfig config,
        scope const(string[]) compiledBMIs = []
    ) @system
    {
        ModuleCompileResult result;
        
        // Analyze module to get name and dependencies
        auto moduleInfo = analyzeModuleSource(sourcePath);
        if (moduleInfo.name.length == 0)
        {
            result.error = "Not a valid module interface: " ~ sourcePath;
            return result;
        }
        
        string moduleName = moduleInfo.isPartition 
            ? moduleInfo.name ~ ":" ~ moduleInfo.partitionName 
            : moduleInfo.name;
        
        Logger.debugLog("Compiling module interface: " ~ moduleName);
        
        // Build compiler flags
        auto baseFlags = buildCompilerFlags(config, true);
        auto moduleFlags = getModuleFlags(compilerType);
        
        // Create BMI cache key
        auto key = createBMIKey(
            moduleName,
            sourcePath,
            compilerPath,
            compilerVersion,
            baseFlags,
            moduleInfo.isPartition ? ModuleType.Partition : ModuleType.Interface
        );
        
        // Check BMI cache
        if (bmiCache.isCached(key))
        {
            auto pathResult = bmiCache.getBMIPath(key);
            if (pathResult.isOk)
            {
                Logger.debugLog("  [BMI Cached] " ~ moduleName);
                result.success = true;
                result.bmiPath = pathResult.unwrap();
                result.fromCache = true;
                return result;
            }
        }
        
        // Determine output paths
        string bmiPath = getBMIOutputPath(moduleName, outputDir, compilerType);
        string objPath = buildPath(outputDir, baseName(sourcePath).stripExtension ~ ".o");
        
        // Ensure output directory exists
        auto bmiDir = dirName(bmiPath);
        if (!exists(bmiDir)) mkdirRecurse(bmiDir);
        
        // Build compile command based on compiler
        string[] cmd = [getCompilerCommand()];
        cmd ~= baseFlags;
        cmd ~= moduleFlags.interfaceFlags;
        
        // Add dependency BMIs
        foreach (bmi; compiledBMIs)
            cmd ~= moduleFlags.bmiInputFlag ~ bmi;
        
        // Add source and output
        cmd ~= sourcePath;
        
        // Compiler-specific output handling
        if (compilerType.toLower.canFind("clang"))
        {
            // Clang: --precompile outputs .pcm, separate compile for .o
            cmd ~= ["-o", bmiPath];
        }
        else if (compilerType.toLower.canFind("msvc") || compilerType.toLower.canFind("cl"))
        {
            // MSVC: /ifcOutput for BMI, /Fo for object
            cmd ~= ["/ifcOutput", bmiPath, "/Fo" ~ objPath];
        }
        else
        {
            // GCC: -fmodule-output= for BMI, -o for object
            cmd ~= moduleFlags.bmiOutputFlag ~ bmiPath;
            cmd ~= ["-c", "-o", objPath];
        }
        
        Logger.debugLog("  Command: " ~ cmd.join(" "));
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Module compilation failed: " ~ res.output;
            return result;
        }
        
        // Store in BMI cache
        bmiCache.store(
            key,
            bmiPath,
            sourcePath,
            moduleInfo.imports,
            ["compiler": compilerType, "version": compilerVersion]
        );
        
        result.success = true;
        result.bmiPath = bmiPath;
        result.objectPath = exists(objPath) ? objPath : "";
        
        if (res.output.length > 0)
            result.warnings ~= res.output;
        
        return result;
    }
    
    /// Compile a header unit with BMI caching
    ModuleCompileResult compileHeaderUnit(
        string headerPath,
        string outputDir,
        in CppConfig config
    ) @system
    {
        ModuleCompileResult result;
        
        Logger.debugLog("Compiling header unit: " ~ headerPath);
        
        auto baseFlags = buildCompilerFlags(config, true);
        auto moduleFlags = getModuleFlags(compilerType);
        
        // Create BMI key for header unit
        auto key = createHeaderUnitKey(
            headerPath,
            compilerPath,
            compilerVersion,
            baseFlags
        );
        
        // Check cache
        if (bmiCache.isCached(key))
        {
            auto pathResult = bmiCache.getBMIPath(key);
            if (pathResult.isOk)
            {
                Logger.debugLog("  [BMI Cached] Header unit: " ~ baseName(headerPath));
                result.success = true;
                result.bmiPath = pathResult.unwrap();
                result.fromCache = true;
                return result;
            }
        }
        
        // Determine output path
        string bmiPath = getBMIOutputPath(
            "header:" ~ baseName(headerPath).replace(".", "_"),
            outputDir,
            compilerType
        );
        
        auto bmiDir = dirName(bmiPath);
        if (!exists(bmiDir)) mkdirRecurse(bmiDir);
        
        // Build command
        string[] cmd = [getCompilerCommand()];
        cmd ~= baseFlags;
        cmd ~= moduleFlags.headerUnitFlags;
        cmd ~= headerPath;
        cmd ~= ["-o", bmiPath];
        
        Logger.debugLog("  Command: " ~ cmd.join(" "));
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Header unit compilation failed: " ~ res.output;
            return result;
        }
        
        // Store in cache
        bmiCache.store(key, bmiPath, headerPath);
        
        result.success = true;
        result.bmiPath = bmiPath;
        
        if (res.output.length > 0)
            result.warnings ~= res.output;
        
        return result;
    }
    
    /// Compile a source file that consumes modules
    ModuleCompileResult compileWithModules(
        string sourcePath,
        string outputDir,
        in CppConfig config,
        scope const(string[]) bmiPaths
    ) @system
    {
        ModuleCompileResult result;
        
        Logger.debugLog("Compiling with modules: " ~ sourcePath);
        
        auto baseFlags = buildCompilerFlags(config, true);
        auto moduleFlags = getModuleFlags(compilerType);
        
        string objPath = buildPath(outputDir, baseName(sourcePath).stripExtension ~ ".o");
        
        auto objDir = dirName(objPath);
        if (!exists(objDir)) mkdirRecurse(objDir);
        
        // Build command
        string[] cmd = [getCompilerCommand()];
        cmd ~= baseFlags;
        cmd ~= moduleFlags.consumeFlags;
        
        // Add BMI references
        foreach (bmi; bmiPaths)
            cmd ~= moduleFlags.bmiInputFlag ~ bmi;
        
        cmd ~= ["-c", sourcePath, "-o", objPath];
        
        Logger.debugLog("  Command: " ~ cmd.join(" "));
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Compilation failed: " ~ res.output;
            return result;
        }
        
        result.success = true;
        result.objectPath = objPath;
        
        if (res.output.length > 0)
            result.warnings ~= res.output;
        
        return result;
    }
    
    /// Build all modules and sources in correct order
    /// Returns object files for linking
    string[] buildModuleProject(
        scope const(string[]) sources,
        string outputDir,
        in CppConfig config
    ) @system
    {
        // Separate sources by type
        string[] moduleInterfaces;
        string[] regularSources;
        CppModuleInfo[] moduleInfos;
        
        foreach (source; sources)
        {
            if (isModuleInterface(source))
            {
                moduleInterfaces ~= source;
                moduleInfos ~= analyzeModuleSource(source);
            }
            else
                regularSources ~= source;
        }
        
        // Sort module interfaces by dependency order
        string[] sortedModules = sortModulesByDependency(moduleInfos);
        
        // Compile modules in order
        string[] bmiPaths;
        string[] objectFiles;
        
        foreach (moduleSrc; sortedModules)
        {
            auto result = compileModuleInterface(moduleSrc, outputDir, config, bmiPaths);
            if (!result.success)
            {
                Logger.error("Module compilation failed: " ~ result.error);
                return [];
            }
            
            bmiPaths ~= result.bmiPath;
            if (result.objectPath.length > 0)
                objectFiles ~= result.objectPath;
        }
        
        // Compile regular sources with module references
        foreach (source; regularSources)
        {
            auto result = compileWithModules(source, outputDir, config, bmiPaths);
            if (!result.success)
            {
                Logger.error("Source compilation failed: " ~ result.error);
                return [];
            }
            objectFiles ~= result.objectPath;
        }
        
        return objectFiles;
    }
    
    /// Get BMI cache for external access
    BMICache getCache() @safe => bmiCache;
    
    /// Flush BMI cache to disk
    void flushCache() @system => bmiCache.flush();
    
    /// Check if modules are supported by current compiler
    bool isModuleSupported() @safe
    {
        return isModuleSupportedVersion(compilerType, compilerVersion);
    }
    
private:
    string getCompilerCommand() @safe
    {
        if (compilerPath.canFind("gcc") && !compilerPath.canFind("g++"))
            return compilerPath.replace("gcc", "g++");
        if (compilerPath.canFind("clang") && !compilerPath.canFind("clang++"))
            return compilerPath.replace("clang", "clang++");
        return compilerPath;
    }
}

